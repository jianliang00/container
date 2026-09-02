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
import Foundation
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
    func verboseStatusDistinguishesEnabledVMStateFromUnsupportedCRIWorkloadRestore() throws {
        var metadata = readyMetadata()
        metadata.annotations = [
            CRIShimMachineStateAnnotation.enabled: "true",
            CRIShimMachineStateAnnotation.persistenceID: "stable-workload",
        ]

        let info = makeCRIPodSandboxStatusInfo(metadata, sandboxSnapshot: nil)
        let encoded = try #require(info["machineState"])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        let restore = try #require(object["restore"] as? [String: Any])
        let unsupportedReason = try #require(restore["unsupportedReason"] as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["protocolVersion"] as? Int == 2)
        #expect(object["persistenceID"] as? String == "stable-workload")
        #expect(restore["supported"] as? Bool == false)
        #expect(restore["status"] as? String == "notRequested")
        #expect(unsupportedReason["code"] as? String == "criWorkloadAdoptionUnavailable")
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
