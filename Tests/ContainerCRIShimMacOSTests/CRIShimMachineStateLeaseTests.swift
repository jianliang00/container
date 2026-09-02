//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerKit
import ContainerResource
import Darwin
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimMachineStateLeaseTests {
    @Test(arguments: [false, true])
    func reservedLeaseRecoversCrashBeforeLifecycleBarrierPublication(removeLock: Bool) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let acquisition = try acquireLease(
            fixture: fixture,
            persistenceID: "workload-incomplete-barrier",
            sandboxID: "sandbox-incomplete-barrier",
            podUID: "pod-incomplete-barrier",
            storageGeneration: 8
        )
        let storage = URL(
            fileURLWithPath: fixture.policy.normalizedStorageRoot,
            isDirectory: true
        ).appendingPathComponent(acquisition.lease.persistenceID, isDirectory: true)
        try FileManager.default.removeItem(
            at: storage.appendingPathComponent(MacOSSidecarLifecycleBarrierProtocol.attestationFileName)
        )
        if removeLock {
            try FileManager.default.removeItem(
                at: storage.appendingPathComponent(MacOSSidecarLifecycleBarrierProtocol.lockFileName)
            )
        }

        try CRIShimMachineStateLeaseStore.release(
            policy: fixture.policy,
            expected: acquisition.lease
        )

        #expect(
            try CRIShimMachineStateLeaseStore.load(
                policy: fixture.policy,
                persistenceID: acquisition.lease.persistenceID
            ) == nil
        )
        #expect(
            try readLifecycleAttestation(
                policy: fixture.policy,
                persistenceID: acquisition.lease.persistenceID
            ).state == .retired
        )
    }

    @Test
    func preparedLifecycleBarrierRequiresDelayedChildExitAndRetiresItsNonce() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let acquisition = try acquireLease(
            fixture: fixture,
            persistenceID: "workload-child",
            sandboxID: "sandbox-child",
            podUID: "pod-child",
            storageGeneration: 8
        )
        let started = try CRIShimMachineStateLeaseStore.markRuntimeCreationStarted(
            policy: fixture.policy,
            expected: acquisition.lease
        )
        let launchStarted = try CRIShimMachineStateLeaseStore.markSidecarLaunchMayHaveStarted(
            policy: fixture.policy,
            expected: started
        )
        let barrier = try #require(launchStarted.sidecarLifecycleBarrier)
        let lockPath = URL(
            fileURLWithPath: fixture.policy.normalizedStorageRoot,
            isDirectory: true
        ).appendingPathComponent("workload-child/\(MacOSSidecarLifecycleBarrierProtocol.lockFileName)").path

        let readyPath = fixture.root.appendingPathComponent("child-lock-ready").path
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            "import fcntl, os, sys, time; f = open(sys.argv[1], 'r+'); fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); open(sys.argv[2], 'w').close(); time.sleep(300)",
            lockPath,
            readyPath,
        ]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: readyPath) {
            usleep(10_000)
        }
        guard FileManager.default.fileExists(atPath: readyPath), child.isRunning else {
            Issue.record("child process failed to acquire the lifecycle lock")
            return
        }

        let cleanupLock = try CRIShimMachineStateSidecarLifecycleLock(
            binding: launchStarted,
            barrier: barrier,
            policy: fixture.policy,
            expectedOwnerUID: geteuid()
        )
        #expect(throws: CRIShimError.self) {
            try cleanupLock.retireAndAcquireExitProof()
        }

        child.terminate()
        child.waitUntilExit()
        let prepared = try readLifecycleAttestation(
            policy: fixture.policy,
            persistenceID: "workload-child"
        )
        #expect(prepared.state == .prepared)
        #expect(prepared.processID == 0)
        try cleanupLock.retireAndAcquireExitProof()
        #expect(try readLifecycleAttestation(policy: fixture.policy, persistenceID: "workload-child").state == .retired)

        #expect(throws: (any Error).self) {
            _ = try MacOSSidecarLifecycleLock(
                protocolVersion: barrier.protocolVersion,
                persistenceID: launchStarted.persistenceID,
                sandboxID: launchStarted.sandboxID,
                bootNonce: barrier.bootNonce,
                storageDirectory: URL(
                    fileURLWithPath: fixture.policy.normalizedStorageRoot,
                    isDirectory: true
                ).appendingPathComponent(launchStarted.persistenceID, isDirectory: true).path
            )
        }

        var wrongNonce = barrier
        wrongNonce.bootNonce = UUID().uuidString.lowercased()
        #expect(throws: CRIShimError.self) {
            _ = try CRIShimMachineStateSidecarLifecycleLock(
                binding: launchStarted,
                barrier: wrongNonce,
                policy: fixture.policy,
                expectedOwnerUID: geteuid()
            )
        }
        withExtendedLifetime(cleanupLock) {}
    }

    @Test
    func legacyLeaseSchemaRemainsReadableWithoutLifecycleAttestation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacy = CRIShimMachineStateLease(
            schemaVersion: 1,
            persistenceID: "legacy-workload",
            podUID: "legacy-pod",
            sandboxID: "legacy-sandbox",
            restoreStateID: nil,
            restoreStateGeneration: nil,
            storageGeneration: 1,
            admissionState: nil,
            sidecarLifecycleBarrier: nil
        )
        let leaseURL = URL(fileURLWithPath: fixture.policy.normalizedLeaseRoot, isDirectory: true)
            .appendingPathComponent("legacy-workload.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(legacy).write(to: leaseURL)
        #expect(chmod(leaseURL.path, mode_t(0o600)) == 0)

        #expect(
            try CRIShimMachineStateLeaseStore.load(
                policy: fixture.policy,
                persistenceID: legacy.persistenceID
            ) == legacy
        )
    }

    @Test
    func admissionLockSerializesReconciliationAcrossServiceProcesses() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let first = try CRIShimMachineStateLeaseStore.acquireAdmissionLock(
                policy: fixture.policy,
                persistenceID: "workload-locked"
            )
            do {
                _ = try CRIShimMachineStateLeaseStore.acquireAdmissionLock(
                    policy: fixture.policy,
                    persistenceID: "workload-locked"
                )
                Issue.record("concurrent machine-state admission unexpectedly acquired the lock")
            } catch let error as CRIShimError {
                #expect(error.description.contains("another admission in progress"))
            }
            withExtendedLifetime(first) {}
        }

        let successor = try CRIShimMachineStateLeaseStore.acquireAdmissionLock(
            policy: fixture.policy,
            persistenceID: "workload-locked"
        )
        withExtendedLifetime(successor) {}
    }

    @Test
    func reconciliationReleasesOnlyLeasesWithNoMetadataOrRuntimeEvidence() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadataStore = try CRIShimMetadataStore(
            rootURL: fixture.root.appendingPathComponent("metadata", isDirectory: true)
        )
        let orphan = try acquireLease(
            fixture: fixture,
            persistenceID: ".workload-orphan",
            sandboxID: "sandbox-orphan",
            podUID: "pod-orphan",
            storageGeneration: 8
        )
        let runtimeBacked = try acquireLease(
            fixture: fixture,
            persistenceID: "workload-runtime",
            sandboxID: "sandbox-runtime",
            podUID: "pod-runtime",
            storageGeneration: 9
        )
        let metadataBacked = try acquireLease(
            fixture: fixture,
            persistenceID: "workload-metadata",
            sandboxID: "sandbox-metadata",
            podUID: "pod-metadata",
            storageGeneration: 10
        )
        try metadataStore.upsertSandbox(
            CRIShimSandboxMetadata(
                id: metadataBacked.lease.sandboxID,
                podUID: metadataBacked.lease.podUID,
                runtimeHandler: "macos",
                sandboxImage: "example.com/macos/sandbox:latest",
                state: .ready,
                createdAt: Date(),
                updatedAt: Date()
            )
        )

        let result = try CRIShimMachineStateLeaseReconciler().reconcile(
            policy: fixture.policy,
            metadataStore: metadataStore,
            runtimeSnapshots: [try makeRuntimeSandboxSnapshot(id: runtimeBacked.lease.sandboxID)]
        )

        #expect(result.released == [orphan.lease])
        #expect(result.retainedForRuntime == [runtimeBacked.lease])
        #expect(result.retainedForMetadata == [metadataBacked.lease])
        #expect(result.retainedForUncertainRuntime.isEmpty)
        #expect(
            try CRIShimMachineStateLeaseStore.list(policy: fixture.policy)
                == [metadataBacked.lease, runtimeBacked.lease]
        )
    }

    @Test
    func reconciliationRetainsLeaseWhenRuntimeInventoryContainsUnidentifiedEntry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadataStore = try CRIShimMetadataStore(
            rootURL: fixture.root.appendingPathComponent("metadata", isDirectory: true)
        )
        let lease = try acquireLease(
            fixture: fixture,
            persistenceID: "workload-uncertain",
            sandboxID: "sandbox-uncertain",
            podUID: "pod-uncertain",
            storageGeneration: 8
        )
        let unidentified = SandboxSnapshot(
            configuration: nil,
            status: .unknown,
            networks: [],
            containers: [],
            workloads: []
        )

        let result = try CRIShimMachineStateLeaseReconciler().reconcile(
            policy: fixture.policy,
            metadataStore: metadataStore,
            runtimeSnapshots: [unidentified]
        )

        #expect(result.released.isEmpty)
        #expect(result.retainedForUncertainRuntime == [lease.lease])
        try CRIShimMachineStateLeaseStore.requireActive(policy: fixture.policy, expected: lease.lease)
    }

    @Test
    func reconciliationNeverReleasesLeaseAfterRuntimeCreationCouldHaveStarted() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadataStore = try CRIShimMetadataStore(
            rootURL: fixture.root.appendingPathComponent("metadata", isDirectory: true)
        )
        let acquisition = try acquireLease(
            fixture: fixture,
            persistenceID: "workload-started",
            sandboxID: "sandbox-started",
            podUID: "pod-started",
            storageGeneration: 8
        )
        #expect(acquisition.lease.admissionState == .reserved)
        let started = try CRIShimMachineStateLeaseStore.markRuntimeCreationStarted(
            policy: fixture.policy,
            expected: acquisition.lease
        )
        #expect(started.admissionState == .runtimeCreationStarted)

        let result = try CRIShimMachineStateLeaseReconciler().reconcile(
            policy: fixture.policy,
            metadataStore: metadataStore,
            runtimeSnapshots: []
        )

        #expect(result.released.isEmpty)
        #expect(result.retainedForUncertainRuntime == [started])
        #expect(try CRIShimMachineStateLeaseStore.list(policy: fixture.policy) == [started])
        #expect(throws: CRIShimError.self) {
            try CRIShimMachineStateLeaseStore.release(
                policy: fixture.policy,
                expected: acquisition.lease
            )
        }
    }

    @Test
    func reconciliationReleasesOnlyAfterRuntimeDeletionIsDurablyConfirmed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadataStore = try CRIShimMetadataStore(
            rootURL: fixture.root.appendingPathComponent("metadata", isDirectory: true)
        )
        let acquisition = try acquireLease(
            fixture: fixture,
            persistenceID: "workload-deleted",
            sandboxID: "sandbox-deleted",
            podUID: "pod-deleted",
            storageGeneration: 8
        )
        let started = try CRIShimMachineStateLeaseStore.markRuntimeCreationStarted(
            policy: fixture.policy,
            expected: acquisition.lease
        )
        let barrier = try #require(started.sidecarLifecycleBarrier)
        let lifecycleLock = try CRIShimMachineStateSidecarLifecycleLock(
            binding: started,
            barrier: barrier,
            policy: fixture.policy,
            expectedOwnerUID: geteuid()
        )
        try lifecycleLock.retireAndAcquireExitProof()
        let deleted = try CRIShimMachineStateLeaseStore.markRuntimeDeletionConfirmed(
            policy: fixture.policy,
            expected: started
        )

        let result = try CRIShimMachineStateLeaseReconciler().reconcile(
            policy: fixture.policy,
            metadataStore: metadataStore,
            runtimeSnapshots: []
        )

        #expect(result.released == [deleted])
        #expect(try CRIShimMachineStateLeaseStore.list(policy: fixture.policy).isEmpty)
        withExtendedLifetime(lifecycleLock) {}
    }

    @Test
    func leaseCoverageRejectsMachineStateMetadataWithoutLease() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadataStore = try CRIShimMetadataStore(
            rootURL: fixture.root.appendingPathComponent("metadata", isDirectory: true)
        )
        try metadataStore.upsertSandbox(
            CRIShimSandboxMetadata(
                id: "sandbox-unleased",
                podUID: "pod-unleased",
                runtimeHandler: "macos",
                sandboxImage: "example.com/macos/sandbox:latest",
                annotations: [
                    CRIShimMachineStateAnnotation.enabled: "true",
                    CRIShimMachineStateAnnotation.persistenceID: "workload-unleased",
                    CRIShimMachineStateAnnotation.storageGeneration: "8",
                ],
                state: .ready,
                createdAt: Date(),
                updatedAt: Date()
            )
        )

        #expect(throws: CRIShimError.self) {
            try validateMachineStateLeaseCoverage(
                metadataStore: metadataStore,
                runtimeSnapshots: [],
                leases: []
            )
        }
    }

    @Test
    func concurrentSameOwnerAcquisitionIsAtomicAndIdempotent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let machineState = makeMachineState(storageGeneration: 8)

        let results = try await withThrowingTaskGroup(of: CRIShimMachineStateLeaseAcquisition.self) { group in
            for sandboxID in ["sandbox-a", "sandbox-b"] {
                group.addTask {
                    try CRIShimMachineStateLeaseStore.acquire(
                        policy: fixture.policy,
                        machineState: machineState,
                        podUID: "pod-uid-a",
                        proposedSandboxID: sandboxID
                    )
                }
            }
            var values: [CRIShimMachineStateLeaseAcquisition] = []
            for try await result in group {
                values.append(result)
            }
            return values
        }

        #expect(results.count == 2)
        #expect(results.filter(\.created).count == 1)
        #expect(Set(results.map(\.lease.sandboxID)).count == 1)
        #expect(results.allSatisfy { $0.lease.podUID == "pod-uid-a" })
        #expect(results.allSatisfy { $0.lease.storageGeneration == 8 })
    }

    @Test
    func differentPodOrStorageGenerationCannotTakeOverExistingBinding() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try CRIShimMachineStateLeaseStore.acquire(
            policy: fixture.policy,
            machineState: makeMachineState(storageGeneration: 8),
            podUID: "pod-uid-a",
            proposedSandboxID: "sandbox-a"
        )

        for candidate in [
            (podUID: "pod-uid-b", storageGeneration: UInt64(8)),
            (podUID: "pod-uid-a", storageGeneration: UInt64(9)),
        ] {
            do {
                _ = try CRIShimMachineStateLeaseStore.acquire(
                    policy: fixture.policy,
                    machineState: makeMachineState(storageGeneration: candidate.storageGeneration),
                    podUID: candidate.podUID,
                    proposedSandboxID: "sandbox-other"
                )
                Issue.record("different lease owner unexpectedly acquired the binding")
            } catch let error as CRIShimError {
                #expect(error.description.contains("fenced by another pod or storage generation"))
            }
        }

        var wrongOwner = first.lease
        wrongOwner.sandboxID = "sandbox-other"
        #expect(throws: CRIShimError.self) {
            try CRIShimMachineStateLeaseStore.release(policy: fixture.policy, expected: wrongOwner)
        }

        try CRIShimMachineStateLeaseStore.release(policy: fixture.policy, expected: first.lease)
        let next = try CRIShimMachineStateLeaseStore.acquire(
            policy: fixture.policy,
            machineState: makeMachineState(storageGeneration: 9),
            podUID: "pod-uid-b",
            proposedSandboxID: "sandbox-b"
        )
        #expect(next.created)
        #expect(next.lease.sandboxID == "sandbox-b")
    }

    @Test
    func leaseBindsSavedAndWritableDiskGenerations() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let machineState = makeMachineState(storageGeneration: 8)

        let acquisition = try CRIShimMachineStateLeaseStore.acquire(
            policy: fixture.policy,
            machineState: machineState,
            podUID: "pod-uid-a",
            proposedSandboxID: "sandbox-a"
        )
        try CRIShimMachineStateLeaseStore.requireActive(
            policy: fixture.policy,
            expected: acquisition.lease
        )

        #expect(acquisition.lease.restoreStateID == "snapshot-7")
        #expect(acquisition.lease.restoreStateGeneration == 7)
        #expect(acquisition.lease.storageGeneration == 8)
        let leaseURL = URL(fileURLWithPath: fixture.policy.normalizedLeaseRoot)
            .appendingPathComponent("workload-42.json")
        var value = stat()
        #expect(lstat(leaseURL.path, &value) == 0)
        #expect((value.st_mode & S_IFMT) == S_IFREG)
        #expect((value.st_mode & mode_t(0o777)) == mode_t(0o600))
        #expect(value.st_uid == geteuid())

        var differentSandbox = acquisition.lease
        differentSandbox.sandboxID = "sandbox-b"
        #expect(throws: CRIShimError.self) {
            try CRIShimMachineStateLeaseStore.requireActive(
                policy: fixture.policy,
                expected: differentSandbox
            )
        }
        try CRIShimMachineStateLeaseStore.release(
            policy: fixture.policy,
            expected: acquisition.lease
        )
        #expect(throws: CRIShimError.self) {
            try CRIShimMachineStateLeaseStore.requireActive(
                policy: fixture.policy,
                expected: acquisition.lease
            )
        }
    }

    private func makeFixture() throws -> (root: URL, policy: MachineStateConfig) {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalPath =
            temporaryPath == "/var" || temporaryPath.hasPrefix("/var/")
                || temporaryPath == "/tmp" || temporaryPath.hasPrefix("/tmp/")
            ? "/private\(temporaryPath)"
            : temporaryPath
        let root = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .appendingPathComponent("CRIShimMachineStateLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        guard chmod(root.path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let policy = MachineStateConfig(
            enabled: true,
            storageRoot: root.appendingPathComponent("state").path,
            controlSocketRoot: root.appendingPathComponent("control").path,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: [root.appendingPathComponent("nbd").path],
            leaseRoot: root.appendingPathComponent("leases").path
        )
        try CRIShimMachineStateDirectories.prepare(policy: policy)
        try prepareStorageDirectory(policy: policy, persistenceID: "workload-42")
        return (root, policy)
    }

    private func makeMachineState(
        storageGeneration: UInt64,
        persistenceID: String = "workload-42"
    ) -> ContainerConfiguration.MacOSGuestOptions.MachineState {
        .init(
            persistenceID: persistenceID,
            storageDirectory: "/state/\(persistenceID)",
            controlSocketPath: "/private/control/\(persistenceID).sock",
            restoreStateID: "snapshot-7",
            restoreStateGeneration: 7,
            storageGeneration: storageGeneration
        )
    }

    private func acquireLease(
        fixture: (root: URL, policy: MachineStateConfig),
        persistenceID: String,
        sandboxID: String,
        podUID: String,
        storageGeneration: UInt64
    ) throws -> CRIShimMachineStateLeaseAcquisition {
        try prepareStorageDirectory(policy: fixture.policy, persistenceID: persistenceID)
        return try CRIShimMachineStateLeaseStore.acquire(
            policy: fixture.policy,
            machineState: makeMachineState(
                storageGeneration: storageGeneration,
                persistenceID: persistenceID
            ),
            podUID: podUID,
            proposedSandboxID: sandboxID
        )
    }

    private func prepareStorageDirectory(
        policy: MachineStateConfig,
        persistenceID: String
    ) throws {
        let directory = URL(
            fileURLWithPath: policy.normalizedStorageRoot,
            isDirectory: true
        ).appendingPathComponent(persistenceID, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeLifecycleAttestation(
        policy: MachineStateConfig,
        lease: CRIShimMachineStateLease,
        processID: Int32,
        state: MacOSSidecarLifecycleAttestationState
    ) throws {
        let barrier = try #require(lease.sidecarLifecycleBarrier)
        let directory = URL(
            fileURLWithPath: policy.normalizedStorageRoot,
            isDirectory: true
        ).appendingPathComponent(lease.persistenceID, isDirectory: true)
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(directoryFD) }
        let lockFD = openat(
            directoryFD,
            MacOSSidecarLifecycleBarrierProtocol.lockFileName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard lockFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(lockFD) }
        var value = stat()
        guard fstat(lockFD, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try MacOSSidecarLifecycleLock.persistAttestation(
            MacOSSidecarLifecycleAttestation(
                protocolVersion: barrier.protocolVersion,
                persistenceID: lease.persistenceID,
                sandboxID: lease.sandboxID,
                bootNonce: barrier.bootNonce,
                processID: processID,
                lockDevice: UInt64(value.st_dev),
                lockInode: UInt64(value.st_ino),
                state: state
            ),
            directoryFD: directoryFD,
            ownerUID: geteuid()
        )
    }

    private func readLifecycleAttestation(
        policy: MachineStateConfig,
        persistenceID: String
    ) throws -> MacOSSidecarLifecycleAttestation {
        let directory = URL(
            fileURLWithPath: policy.normalizedStorageRoot,
            isDirectory: true
        ).appendingPathComponent(persistenceID, isDirectory: true)
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(directoryFD) }
        return try MacOSSidecarLifecycleLock.readAttestation(
            directoryFD: directoryFD,
            expectedOwnerUID: geteuid()
        )
    }

    private func makeRuntimeSandboxSnapshot(id: String) throws -> SandboxSnapshot {
        let imageJSON = """
            {
              "reference": "example.com/macos/sandbox:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:sandbox",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/usr/bin/true",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        var configuration = ContainerConfiguration(id: id, image: image, process: process)
        configuration.runtimeHandler = "container-runtime-macos"
        return SandboxSnapshot(
            configuration: SandboxConfiguration(containerConfiguration: configuration),
            status: .stopped,
            networks: [],
            containers: [],
            workloads: []
        )
    }
}
