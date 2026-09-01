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

import ContainerResource
import Darwin
import Foundation
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimMachineStateLeaseTests {
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
        return (root, policy)
    }

    private func makeMachineState(
        storageGeneration: UInt64
    ) -> ContainerConfiguration.MacOSGuestOptions.MachineState {
        .init(
            persistenceID: "workload-42",
            storageDirectory: "/state/workload-42",
            controlSocketPath: "/private/control/workload-42.sock",
            restoreStateID: "snapshot-7",
            restoreStateGeneration: 7,
            storageGeneration: storageGeneration
        )
    }
}
