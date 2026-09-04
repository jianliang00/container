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
import ContainerizationExtras
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimStatusMappingTests {
    @Test
    func networkInvalidationForcesReadySandboxToStopped() {
        let metadata = readyMetadata()
        let snapshot = SandboxSnapshot(
            status: .stopped,
            networks: [],
            containers: [],
            failureReason: .networkInvalidated
        )

        #expect(metadata.applying(sandboxSnapshot: snapshot).state == .stopped)
    }

    @Test
    func ordinaryStoppedSnapshotPreservesReadyUntilFirstWorkloadStarts() {
        let metadata = readyMetadata()
        let snapshot = SandboxSnapshot(
            status: .stopped,
            networks: [],
            containers: []
        )

        #expect(metadata.applying(sandboxSnapshot: snapshot).state == .ready)
    }

    @Test
    func ordinaryStoppedSnapshotPreservesIncompleteMachineStateAdmission() {
        var metadata = readyMetadata()
        metadata.state = .pending
        metadata.annotations[CRIShimMachineStateAnnotation.enabled] = "true"
        let snapshot = SandboxSnapshot(
            status: .stopped,
            networks: [],
            containers: []
        )

        #expect(metadata.applying(sandboxSnapshot: snapshot).state == .pending)
    }

    @Test
    func ordinaryStoppedSnapshotClosesIncompleteStandardAdmission() {
        var metadata = readyMetadata()
        metadata.state = .pending
        let snapshot = SandboxSnapshot(
            status: .stopped,
            networks: [],
            containers: []
        )

        #expect(metadata.applying(sandboxSnapshot: snapshot).state == .stopped)
    }

    @Test(arguments: [CRIShimSandboxMetadata.State.stopped, .released])
    func staleRunningSnapshotCannotRegressTerminalSandboxState(
        state: CRIShimSandboxMetadata.State
    ) {
        var metadata = readyMetadata()
        metadata.state = state
        metadata.networkAttachments = ["previous-network"]
        let snapshot = SandboxSnapshot(
            status: .running,
            networks: [],
            containers: [],
            workloads: []
        )

        let updated = metadata.applying(sandboxSnapshot: snapshot)

        #expect(updated.state == state)
        #expect(updated.networkAttachments == ["previous-network"])
    }

    @Test
    func verboseStatusReportsDurableRestoreGeneration() throws {
        var metadata = readyMetadata()
        metadata.annotations = [
            CRIShimMachineStateAnnotation.enabled: "true",
            CRIShimMachineStateAnnotation.persistenceID: "stable-workload",
            CRIShimMachineStateAnnotation.restoreStateID: "snapshot-7",
            CRIShimMachineStateAnnotation.restoreStateGeneration: "7",
            CRIShimMachineStateAnnotation.storageGeneration: "8",
        ]

        let info = makeCRIPodSandboxStatusInfo(metadata, sandboxSnapshot: nil)
        let encoded = try #require(info["machineState"])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        let restore = try #require(object["restore"] as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["protocolVersion"] as? Int == 2)
        #expect(object["persistenceID"] as? String == "stable-workload")
        #expect(object["storageGeneration"] as? Int == 8)
        #expect(restore["supported"] as? Bool == true)
        #expect(restore["status"] as? String == "requested")
        #expect(restore["stateID"] as? String == "snapshot-7")
        #expect(restore["stateGeneration"] as? Int == 7)
    }

    @Test
    func durableRestoreReceiptRequiresExactWorkloadAdoption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cri-restore-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateDirectory =
            root
            .appendingPathComponent("workload-42", isDirectory: true)
            .appendingPathComponent("MachineStates", isDirectory: true)
            .appendingPathComponent("snapshot-7", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let runtimeWorkloadID = "workload-42:container:0123456789abcdef01234567"
        let trustedFingerprint = "sha256:\(String(repeating: "c", count: 64))"
        let guestFingerprint = String(repeating: "d", count: 64)
        let processIncarnation = "sha256:\(String(repeating: "e", count: 64))"
        let adoptionWorkload = MacOSMachineStateAdoptionWorkload(
            runtimeWorkloadID: runtimeWorkloadID,
            guestProcessID: runtimeWorkloadID,
            trustedLaunchFingerprint: trustedFingerprint,
            guestLaunchFingerprint: guestFingerprint,
            processIncarnation: processIncarnation,
            storageGeneration: 7,
            processIdentifier: 42,
            lastPersistedEventSequence: 9
        )
        let adoption = MacOSMachineStateAdoptionManifest(
            checkpointID: "snapshot-7",
            persistenceID: "workload-42",
            sourcePodUID: "source-pod",
            sourceStorageGeneration: 7,
            workloads: [adoptionWorkload]
        )
        let receipt = MacOSMachineStateReceipt(
            pair: MacOSMachineStateDurablePair(
                pairID: String(repeating: "a", count: 64),
                persistenceID: "workload-42",
                stateID: "snapshot-7",
                stateGeneration: 7,
                diskSnapshot: .init(
                    snapshotID: "snapshot-7",
                    volumeID: "workload-42-g7",
                    snapshotRef: "rbd/workload-42@snapshot-7",
                    storageGeneration: 7,
                    operationID: "suspend-42",
                    operationSequence: 9,
                    ownerEpoch: 2
                ),
                compatibilityClass: "mac-arm64",
                adoptionManifestDigest: String(repeating: "b", count: 64)
            ),
            adoption: adoption,
            stateSizeBytes: 1024,
            committedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: stateDirectory.appendingPathComponent("manifest.json"))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = CRIShimSandboxMetadata(
            id: "cri-sandbox-1",
            runtimeSandboxID: "workload-42",
            podUID: "target-pod",
            runtimeHandler: "macos",
            sandboxImage: "example.com/macos/sandbox:latest",
            network: "default",
            annotations: [
                CRIShimMachineStateAnnotation.enabled: "true",
                CRIShimMachineStateAnnotation.persistenceID: "workload-42",
                CRIShimMachineStateAnnotation.restoreStateID: "snapshot-7",
                CRIShimMachineStateAnnotation.restoreStateGeneration: "7",
                CRIShimMachineStateAnnotation.restorePairID: String(repeating: "a", count: 64),
                CRIShimMachineStateAnnotation.restoreManifestDigest: String(repeating: "b", count: 64),
                CRIShimMachineStateAnnotation.restoreRequestID: "resume-42",
                CRIShimMachineStateAnnotation.storageGeneration: "8",
            ],
            networkLeaseID: "macvmnet://sandbox/workload-42",
            networkAttachments: ["default"],
            state: .ready,
            createdAt: now,
            updatedAt: now
        )
        let adoptionReceipt = WorkloadAdoptionReceipt(
            runtimeWorkloadID: runtimeWorkloadID,
            executionID: runtimeWorkloadID,
            trustedLaunchFingerprint: trustedFingerprint,
            guestLaunchFingerprint: guestFingerprint,
            processIncarnation: processIncarnation,
            sourceStorageGeneration: 7,
            storageGeneration: 8,
            processIdentifier: 42,
            eventSequence: 10,
            oldestAvailableEventSequence: 9,
            replayTruncated: false,
            state: "running"
        )
        let container = CRIShimContainerMetadata(
            id: "cri-container-1",
            sandboxID: metadata.id,
            runtimeWorkloadID: runtimeWorkloadID,
            name: "workload",
            image: "example.com/macos/workload:latest",
            runtimeHandler: "macos",
            state: .running,
            createdAt: now,
            adoptionReceipt: adoptionReceipt
        )
        let snapshot = SandboxSnapshot(
            status: .running,
            networks: [
                Attachment(
                    network: "default",
                    hostname: "workload-42",
                    ipv4Address: try CIDRv4("192.168.64.42/24"),
                    ipv4Gateway: try IPv4Address("192.168.64.1"),
                    ipv6Address: nil,
                    macAddress: nil
                )
            ],
            containers: []
        )
        let config = MachineStateConfig(enabled: true, storageRoot: root.path)

        let info = makeCRIPodSandboxStatusInfo(
            metadata,
            sandboxSnapshot: snapshot,
            containers: [container],
            machineStateConfig: config
        )
        let encoded = try #require(info[CRIShimRestoreInfoKey.receipt])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        #expect(object["status"] as? String == "adopted")
        #expect(object["runtimeSandboxID"] as? String == "workload-42")
        #expect(object["expectedWorkloadCount"] as? Int == 1)
        #expect(object["adoptedWorkloadCount"] as? Int == 1)

        let missingWorkloadInfo = makeCRIPodSandboxStatusInfo(
            metadata,
            sandboxSnapshot: snapshot,
            containers: [],
            machineStateConfig: config
        )
        let missingWorkloadEncoded = try #require(
            missingWorkloadInfo[CRIShimRestoreInfoKey.receipt]
        )
        let missingWorkloadObject = try #require(
            JSONSerialization.jsonObject(with: Data(missingWorkloadEncoded.utf8)) as? [String: Any]
        )
        #expect(missingWorkloadObject["status"] as? String == "restoring")

        var extraContainer = container
        extraContainer.id = "cri-container-extra"
        extraContainer.runtimeWorkloadID = "workload-42:container:extra"
        extraContainer.adoptionReceipt = nil
        let extraWorkloadInfo = makeCRIPodSandboxStatusInfo(
            metadata,
            sandboxSnapshot: snapshot,
            containers: [container, extraContainer],
            machineStateConfig: config
        )
        let extraWorkloadEncoded = try #require(
            extraWorkloadInfo[CRIShimRestoreInfoKey.receipt]
        )
        let extraWorkloadObject = try #require(
            JSONSerialization.jsonObject(with: Data(extraWorkloadEncoded.utf8)) as? [String: Any]
        )
        #expect(extraWorkloadObject["status"] as? String == "restoring")

        var mismatchedContainer = container
        mismatchedContainer.adoptionReceipt?.processIncarnation = "sha256:\(String(repeating: "f", count: 64))"
        let mismatchedInfo = makeCRIPodSandboxStatusInfo(
            metadata,
            sandboxSnapshot: snapshot,
            containers: [mismatchedContainer],
            machineStateConfig: config
        )
        let mismatchedEncoded = try #require(mismatchedInfo[CRIShimRestoreInfoKey.receipt])
        let mismatchedObject = try #require(
            JSONSerialization.jsonObject(with: Data(mismatchedEncoded.utf8)) as? [String: Any]
        )
        #expect(mismatchedObject["status"] as? String == "restoring")
        #expect(mismatchedObject["adoptedWorkloadCount"] as? Int == 0)
    }

    @Test
    func exitedStatusUsesPersistedRuntimeExitFacts() {
        let exitedAt = Date(timeIntervalSince1970: 1_700_000_100)
        var metadata = containerMetadata(state: .running)
        metadata.recordRuntimeExit(code: 137, at: exitedAt, observedAt: exitedAt)

        let status = makeCRIContainerStatus(metadata)

        #expect(status.state == .containerExited)
        #expect(status.exitCode == 137)
        #expect(status.finishedAt == makeNanoseconds(exitedAt))
        #expect(status.reason == "Error")
        #expect(!status.message.isEmpty)
    }

    @Test
    func exitedStatusWithoutRuntimeFactsIsExplicitUnknownFailure() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = containerMetadata(state: .exited, createdAt: createdAt)

        let status = makeCRIContainerStatus(metadata)

        #expect(status.state == .containerExited)
        #expect(status.exitCode == CRIShimContainerMetadata.unknownExitCode)
        #expect(status.finishedAt == makeNanoseconds(createdAt))
        #expect(status.finishedAt > 0)
        #expect(status.reason == CRIShimContainerMetadata.unknownExitReason)
        #expect(status.message == CRIShimContainerMetadata.unknownExitMessage)
    }

    @Test
    func exitedStatusReplacesEpochTerminalTimestamp() {
        var metadata = containerMetadata(
            state: .exited,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        metadata.exitedAt = Date(timeIntervalSince1970: 0)
        metadata.exitCode = 137
        metadata.exitStatusSource = .runtime
        metadata.exitTimeSource = .runtime

        let status = makeCRIContainerStatus(metadata)

        #expect(status.exitCode == 137)
        #expect(status.finishedAt > 0)
        #expect(status.reason == "Error")
    }

    @Test
    func stoppedSnapshotPersistsRealFailureOverUnknownMetadata() {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_050)
        let exitedAt = Date(timeIntervalSince1970: 1_700_000_100)
        var metadata = containerMetadata(state: .running)
        metadata.recordUnknownExit(at: observedAt)
        let snapshot = workloadSnapshot(exitCode: 137, exitedAt: exitedAt)

        let updated = metadata.applying(workloadSnapshot: snapshot, observedAt: observedAt)
        let status = makeCRIContainerStatus(updated)

        #expect(updated.exitStatusSource == .runtime)
        #expect(updated.exitTimeSource == .runtime)
        #expect(status.exitCode == 137)
        #expect(status.finishedAt == makeNanoseconds(exitedAt))
    }

    @Test
    func stoppedSnapshotWithoutTerminalFactsNeverMapsToSuccessOrEpoch() {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_050)
        let metadata = containerMetadata(state: .running)
        let snapshot = workloadSnapshot(exitCode: nil, exitedAt: nil)

        let updated = metadata.applying(workloadSnapshot: snapshot, observedAt: observedAt)
        let status = makeCRIContainerStatus(updated)

        #expect(status.exitCode == CRIShimContainerMetadata.unknownExitCode)
        #expect(status.finishedAt == makeNanoseconds(observedAt))
        #expect(updated.exitTimeSource == .observed)
        #expect(status.reason == CRIShimContainerMetadata.unknownExitReason)
        #expect(!status.message.isEmpty)
    }

    @Test
    func successfulExitCodeWithoutExitTimeMapsToUnknownFailure() {
        let observedAt = Date(timeIntervalSince1970: 1_780_000_901)
        let metadata = containerMetadata(
            state: .running,
            createdAt: Date(timeIntervalSince1970: 1_780_000_800)
        )
        let snapshot = workloadSnapshot(exitCode: 0, exitedAt: nil)

        let updated = metadata.applying(workloadSnapshot: snapshot, observedAt: observedAt)
        let status = makeCRIContainerStatus(updated)

        #expect(status.exitCode == CRIShimContainerMetadata.unknownExitCode)
        #expect(status.finishedAt == makeNanoseconds(observedAt))
        #expect(status.reason == CRIShimContainerMetadata.unknownExitReason)
        #expect(!status.message.isEmpty)
    }

    @Test
    func failureExitCodeWithoutExitTimeUsesObservationTime() {
        let observedAt = Date(timeIntervalSince1970: 1_780_000_902)
        let metadata = containerMetadata(state: .running)
        let snapshot = workloadSnapshot(exitCode: 137, exitedAt: nil)

        let updated = metadata.applying(workloadSnapshot: snapshot, observedAt: observedAt)
        let status = makeCRIContainerStatus(updated)

        #expect(status.exitCode == 137)
        #expect(status.finishedAt == makeNanoseconds(observedAt))
        #expect(status.reason == "Error")
        #expect(updated.exitTimeSource == .observed)
    }

    @Test
    func successfulSnapshotCannotOverwritePersistedRuntimeFailure() {
        let failureAt = Date(timeIntervalSince1970: 1_700_000_100)
        var metadata = containerMetadata(state: .running)
        metadata.recordRuntimeExit(code: 137, at: failureAt, observedAt: failureAt)

        let updated = metadata.applying(
            workloadSnapshot: workloadSnapshot(
                exitCode: 0,
                exitedAt: failureAt.addingTimeInterval(1)
            ),
            observedAt: failureAt.addingTimeInterval(1)
        )

        #expect(updated.exitCode == 137)
        #expect(updated.exitedAt == failureAt)
    }

    private func readyMetadata() -> CRIShimSandboxMetadata {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return CRIShimSandboxMetadata(
            id: "sandbox-1",
            runtimeHandler: "macos",
            sandboxImage: "example.com/macos/sandbox:latest",
            state: .ready,
            createdAt: now,
            updatedAt: now
        )
    }

    private func containerMetadata(
        state: CRIShimContainerMetadata.State,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> CRIShimContainerMetadata {
        CRIShimContainerMetadata(
            id: "container-1",
            sandboxID: "sandbox-1",
            name: "workload",
            image: "example.com/macos/workload:latest",
            runtimeHandler: "macos",
            state: state,
            createdAt: createdAt,
            startedAt: state == .created ? nil : createdAt
        )
    }

    private func workloadSnapshot(exitCode: Int32?, exitedAt: Date?) -> WorkloadSnapshot {
        WorkloadSnapshot(
            configuration: WorkloadConfiguration(
                id: "container-1",
                processConfiguration: ProcessConfiguration(
                    executable: "/bin/true",
                    arguments: [],
                    environment: []
                )
            ),
            status: .stopped,
            exitCode: exitCode,
            startedDate: Date(timeIntervalSince1970: 1_700_000_000),
            exitedAt: exitedAt
        )
    }

    private func makeNanoseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }
}
