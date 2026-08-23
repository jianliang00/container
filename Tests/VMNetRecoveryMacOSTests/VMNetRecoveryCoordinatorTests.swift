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

import ContainerCRIShimMacOS
import ContainerResource
import Foundation
import Logging
import Testing

@testable import container_vmnet_recovery_macos

struct VMNetRecoveryCoordinatorTests {
    @Test
    func disabledModeDoesNotVerifyOrReboot() async throws {
        try await withTestContext(mode: .disabled) { context in
            let recorder = RecoveryCallRecorder()
            let result = try await context.coordinator(recorder: recorder).reconcileOnce()

            #expect(result == .disabled)
            #expect(await recorder.rebootCount == 0)
            #expect(await recorder.observeCount == 0)
            #expect(await recorder.verifyInputs.isEmpty)
        }
    }

    @Test
    func missingStateIsVerifiedBeforeHealthyBaselineIsCreated() async throws {
        try await withTestContext { context in
            let recorder = RecoveryCallRecorder(verificationInstanceID: "instance-a")
            let result = try await context.coordinator(recorder: recorder).reconcileOnce()
            let state = try #require(try context.store.load())

            #expect(result == .initialized(networkInstanceID: "instance-a"))
            #expect(state.phase == .healthy)
            #expect(state.networkInstanceID == "instance-a")
            #expect(state.bootSessionID == "boot-a")
            #expect(await recorder.verifyInputs == [nil])
            #expect(await recorder.rebootCount == 0)
        }
    }

    @Test
    func healthyGenerationChangeWithoutPodsFencesAndReboots() async throws {
        try await withTestContext { context in
            _ = try context.store.recordHealthyObservation(
                networkName: context.networkName,
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a",
                now: context.now.addingTimeInterval(-10)
            )
            let recorder = RecoveryCallRecorder(observationInstanceID: "instance-b")

            let result = try await context.coordinator(recorder: recorder).reconcileOnce()
            let state = try #require(try context.store.load())

            #expect(result == .rebootRequested)
            #expect(state.phase == .rebootRequested)
            #expect(state.networkInstanceID == "instance-b")
            #expect(state.failureReason == "vmnet network instance changed without host reboot")
            #expect(await recorder.observeCount == 1)
            #expect(await recorder.rebootCount == 1)
        }
    }

    @Test
    func healthyProbeFailuresFenceOnlyAfterConfiguredThreshold() async throws {
        try await withTestContext(healthyProbeFailureThreshold: 3) { context in
            _ = try context.store.recordHealthyObservation(
                networkName: context.networkName,
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a",
                now: context.now.addingTimeInterval(-10)
            )
            let recorder = RecoveryCallRecorder(observationError: TestVerificationError.notReady)
            let coordinator = context.coordinator(recorder: recorder)

            let first = try await coordinator.reconcileOnce()
            let second = try await coordinator.reconcileOnce()
            #expect(first == .waitingForHealthyProbe(attempt: 1, reason: "notReady"))
            #expect(second == .waitingForHealthyProbe(attempt: 2, reason: "notReady"))
            #expect(try context.store.load()?.phase == .healthy)
            #expect(await recorder.rebootCount == 0)

            #expect(try await coordinator.reconcileOnce() == .rebootRequested)
            let state = try #require(try context.store.load())
            #expect(state.phase == .rebootRequested)
            #expect(state.failureReason == "vmnet helper status probe failed repeatedly")
            #expect(await recorder.observeCount == 3)
            #expect(await recorder.rebootCount == 1)
        }
    }

    @Test
    func pendingRuntimeRequestBecomesAuthoritativeFenceBeforeReboot() async throws {
        try await withTestContext { context in
            _ = try context.store.recordHealthyObservation(
                networkName: context.networkName,
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a",
                now: context.now.addingTimeInterval(-10)
            )
            let requestPath = try #require(context.config.resolvedVMNetRecoveryConfig.requestPath)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: requestPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try VMNetRecoveryRequestStore(path: requestPath).submit(
                networkName: context.networkName,
                networkInstanceID: "instance-a",
                failureReason: "helper disconnected",
                bootSessionID: "boot-a",
                now: context.now
            )
            let recorder = RecoveryCallRecorder()

            #expect(try await context.coordinator(recorder: recorder).reconcileOnce() == .rebootRequested)
            let state = try #require(try context.store.load())
            #expect(state.phase == .rebootRequested)
            #expect(state.rebootAttempts == 1)
            #expect(await recorder.rebootCount == 1)
            #expect(try !VMNetRecoveryRequestStore(path: requestPath).hasPendingRequest())
        }
    }

    @Test
    func pendingRequestFromAnotherBootSessionFailsClosed() async throws {
        try await withTestContext { context in
            try context.submitRequest(bootSessionID: "boot-old", observedAt: context.now)
            let recorder = RecoveryCallRecorder()

            let result = try await context.coordinator(recorder: recorder).reconcileOnce()
            guard case .blocked(let reason) = result else {
                Issue.record("expected a request from another boot session to block recovery")
                return
            }
            #expect(reason.contains("boot session mismatch"))
            #expect(try context.store.load() == nil)
            #expect(try context.requestStore.hasPendingRequest())
            #expect(await recorder.rebootCount == 0)
        }
    }

    @Test
    func stalePendingRequestFailsClosed() async throws {
        try await withTestContext { context in
            try context.submitRequest(
                bootSessionID: "boot-a",
                observedAt: context.now.addingTimeInterval(-901)
            )
            let recorder = RecoveryCallRecorder()

            let result = try await context.coordinator(recorder: recorder).reconcileOnce()
            guard case .blocked(let reason) = result else {
                Issue.record("expected a stale request to block recovery")
                return
            }
            #expect(reason.contains("too old"))
            #expect(try context.store.load() == nil)
            #expect(try context.requestStore.hasPendingRequest())
            #expect(await recorder.rebootCount == 0)
        }
    }

    @Test
    func fencedStateRequestsOnlyOneRebootPerBootSession() async throws {
        try await withTestContext { context in
            try context.seedFence()
            let recorder = RecoveryCallRecorder()
            let coordinator = context.coordinator(recorder: recorder)

            #expect(try await coordinator.reconcileOnce() == .rebootRequested)
            #expect(try await coordinator.reconcileOnce() == .waitingForReboot)
            #expect(await recorder.rebootCount == 1)
            #expect(try context.store.load()?.phase == .rebootRequested)
            #expect(try context.store.load()?.rebootAttempts == 1)
        }
    }

    @Test
    func rebootRequestRetriesAfterIntervalAndStopsAtBudget() async throws {
        try await withTestContext(maxRebootAttempts: 2, minimumRebootIntervalSeconds: 120) { context in
            try context.seedFence()
            let recorder = RecoveryCallRecorder()

            #expect(try await context.coordinator(recorder: recorder).reconcileOnce() == .rebootRequested)
            #expect(
                try await context.coordinator(
                    now: context.now.addingTimeInterval(121),
                    recorder: recorder
                ).reconcileOnce() == .rebootRequested
            )
            let result = try await context.coordinator(
                now: context.now.addingTimeInterval(242),
                recorder: recorder
            ).reconcileOnce()
            guard case .blocked(let reason) = result else {
                Issue.record("expected reboot retry budget to block recovery")
                return
            }
            #expect(reason.contains("budget"))
            #expect(await recorder.rebootCount == 2)
            #expect(try context.store.load()?.rebootAttempts == 2)
        }
    }

    @Test
    func newBootAndNewHelperGenerationCompleteVerification() async throws {
        try await withTestContext { context in
            try context.seedFence()
            _ = try context.store.requestReboot(
                networkName: context.networkName,
                currentBootSessionID: "boot-a",
                maxAttempts: 2,
                minimumInterval: 0,
                maximumRequestAge: 900,
                now: context.now
            )
            let recorder = RecoveryCallRecorder(verificationInstanceID: "instance-b")
            let coordinator = context.coordinator(
                bootSessionID: "boot-b",
                now: context.now.addingTimeInterval(10),
                recorder: recorder
            )

            #expect(try await coordinator.reconcileOnce() == .recovered(networkInstanceID: "instance-b"))
            let state = try #require(try context.store.load())
            #expect(state.phase == .healthy)
            #expect(state.networkInstanceID == "instance-b")
            #expect(state.bootSessionID == "boot-b")
            #expect(state.rebootAttempts == 1)
            #expect(await recorder.verifyInputs == ["instance-a"])
            #expect(await recorder.rebootCount == 0)
        }
    }

    @Test
    func manualRebootCanRecoverDirectlyFromFence() async throws {
        try await withTestContext { context in
            try context.seedFence()
            let recorder = RecoveryCallRecorder(verificationInstanceID: "instance-b")
            let coordinator = context.coordinator(
                bootSessionID: "boot-b",
                now: context.now.addingTimeInterval(10),
                recorder: recorder
            )

            #expect(try await coordinator.reconcileOnce() == .recovered(networkInstanceID: "instance-b"))
            #expect(await recorder.rebootCount == 0)
            #expect(try context.store.load()?.phase == .healthy)
        }
    }

    @Test
    func failedVerificationRemainsFencedUntilAValidRetry() async throws {
        try await withTestContext { context in
            try context.seedFence()
            let failingRecorder = RecoveryCallRecorder(verificationError: TestVerificationError.notReady)
            let first = context.coordinator(
                bootSessionID: "boot-b",
                now: context.now.addingTimeInterval(10),
                recorder: failingRecorder
            )

            let result = try await first.reconcileOnce()
            guard case .waitingForVerification = result else {
                Issue.record("expected a waiting verification result")
                return
            }
            #expect(try context.store.load()?.phase == .verifying)

            let succeedingRecorder = RecoveryCallRecorder(verificationInstanceID: "instance-b")
            let retry = context.coordinator(
                bootSessionID: "boot-b",
                now: context.now.addingTimeInterval(20),
                recorder: succeedingRecorder
            )
            #expect(try await retry.reconcileOnce() == .recovered(networkInstanceID: "instance-b"))
            #expect(try context.store.load()?.phase == .healthy)
        }
    }

    @Test
    func sameHelperGenerationCannotCompleteVerification() async throws {
        try await withTestContext { context in
            try context.seedFence()
            let recorder = RecoveryCallRecorder(verificationInstanceID: "instance-a")
            let coordinator = context.coordinator(
                bootSessionID: "boot-b",
                now: context.now.addingTimeInterval(10),
                recorder: recorder
            )

            let result = try await coordinator.reconcileOnce()
            guard case .waitingForVerification(let reason) = result else {
                Issue.record("expected a waiting verification result")
                return
            }
            #expect(reason.contains("network instance mismatch"))
            #expect(try context.store.load()?.phase == .verifying)
        }
    }

    @Test
    func rebootBudgetBlocksASecondFailureInsideAttemptWindow() async throws {
        try await withTestContext(maxRebootAttempts: 1) { context in
            try context.seedFence()
            _ = try context.store.requestReboot(
                networkName: context.networkName,
                currentBootSessionID: "boot-a",
                maxAttempts: 1,
                minimumInterval: 0,
                maximumRequestAge: 900,
                now: context.now
            )
            _ = try context.store.beginVerification(
                networkName: context.networkName,
                currentBootSessionID: "boot-b",
                now: context.now.addingTimeInterval(10)
            )
            _ = try context.store.completeVerification(
                networkName: context.networkName,
                networkInstanceID: "instance-b",
                currentBootSessionID: "boot-b",
                now: context.now.addingTimeInterval(20)
            )
            _ = try context.store.recordFence(
                networkName: context.networkName,
                networkInstanceID: "instance-b",
                failureReason: "second failure",
                bootSessionID: "boot-b",
                attemptWindow: 3600,
                now: context.now.addingTimeInterval(30)
            )

            let recorder = RecoveryCallRecorder()
            let coordinator = context.coordinator(
                bootSessionID: "boot-b",
                now: context.now.addingTimeInterval(40),
                recorder: recorder
            )
            let result = try await coordinator.reconcileOnce()
            guard case .blocked(let reason) = result else {
                Issue.record("expected a blocked result")
                return
            }
            #expect(reason.contains("budget"))
            #expect(await recorder.rebootCount == 0)
        }
    }

    @Test
    func healthyStateFromPreviousBootIsReverifiedBeforeAdmission() async throws {
        try await withTestContext { context in
            _ = try context.store.recordHealthyObservation(
                networkName: context.networkName,
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a",
                now: context.now
            )
            let recorder = RecoveryCallRecorder(verificationInstanceID: "instance-b")
            let coordinator = context.coordinator(
                bootSessionID: "boot-b",
                now: context.now.addingTimeInterval(10),
                recorder: recorder
            )

            #expect(try await coordinator.reconcileOnce() == .recovered(networkInstanceID: "instance-b"))
            #expect(try context.store.load()?.bootSessionID == "boot-b")
            #expect(await recorder.verifyInputs == ["instance-a"])
        }
    }
}

private enum TestVerificationError: Error, Sendable {
    case notReady
}

private actor RecoveryCallRecorder {
    private(set) var rebootCount = 0
    private(set) var observeCount = 0
    private(set) var verifyInputs: [String?] = []
    let observationInstanceID: String
    let observationError: TestVerificationError?
    let verificationInstanceID: String
    let verificationError: TestVerificationError?

    init(
        observationInstanceID: String = "instance-a",
        observationError: TestVerificationError? = nil,
        verificationInstanceID: String = "instance-b",
        verificationError: TestVerificationError? = nil
    ) {
        self.observationInstanceID = observationInstanceID
        self.observationError = observationError
        self.verificationInstanceID = verificationInstanceID
        self.verificationError = verificationError
    }

    func reboot() {
        rebootCount += 1
    }

    func observe() throws -> VMNetRecoveryVerification {
        observeCount += 1
        if let observationError {
            throw observationError
        }
        return VMNetRecoveryVerification(networkInstanceID: observationInstanceID)
    }

    func verify(failedNetworkInstanceID: String?) throws -> VMNetRecoveryVerification {
        verifyInputs.append(failedNetworkInstanceID)
        if let verificationError {
            throw verificationError
        }
        return VMNetRecoveryVerification(networkInstanceID: verificationInstanceID)
    }
}

private struct RecoveryTestContext {
    let root: URL
    let config: CRIShimConfig
    let networkName = "kubernetes-pod"
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    var store: VMNetRecoveryStateStore {
        VMNetRecoveryStateStore(path: config.resolvedVMNetRecoveryConfig.statePath!)
    }

    var requestStore: VMNetRecoveryRequestStore {
        VMNetRecoveryRequestStore(path: config.resolvedVMNetRecoveryConfig.requestPath!)
    }

    func submitRequest(bootSessionID: String, observedAt: Date) throws {
        try FileManager.default.createDirectory(
            at: requestStore.requestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try requestStore.submit(
            networkName: networkName,
            networkInstanceID: "instance-a",
            failureReason: "helper disconnected",
            bootSessionID: bootSessionID,
            now: observedAt
        )
    }

    func seedFence() throws {
        _ = try store.recordHealthyObservation(
            networkName: networkName,
            networkInstanceID: "instance-a",
            bootSessionID: "boot-a",
            now: now.addingTimeInterval(-10)
        )
        _ = try store.recordFence(
            networkName: networkName,
            networkInstanceID: "instance-a",
            failureReason: "helper disconnected",
            bootSessionID: "boot-a",
            attemptWindow: 3600,
            now: now
        )
    }

    func coordinator(
        bootSessionID: String = "boot-a",
        now: Date? = nil,
        recorder: RecoveryCallRecorder
    ) -> VMNetRecoveryCoordinator {
        let reconciliationTime = now ?? self.now
        return VMNetRecoveryCoordinator(
            config: config,
            dependencies: VMNetRecoveryCoordinatorDependencies(
                currentBootSessionID: { bootSessionID },
                now: { reconciliationTime },
                reboot: { await recorder.reboot() },
                observe: { _ in
                    try await recorder.observe()
                },
                verify: { _, failedNetworkInstanceID in
                    try await recorder.verify(failedNetworkInstanceID: failedNetworkInstanceID)
                }
            ),
            log: Logger(label: "com.apple.container.vmnet-recovery-tests")
        )
    }
}

private func withTestContext(
    mode: ContainerConfiguration.MacOSGuestOptions.VMNetDisconnectRecovery = .rebootNode,
    maxRebootAttempts: Int = 2,
    minimumRebootIntervalSeconds: Int = 120,
    healthyProbeFailureThreshold: Int = 3,
    _ body: (RecoveryTestContext) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VMNetRecoveryCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let statePath = root.appendingPathComponent("recovery.json").path
    let config = CRIShimConfig(
        podNetwork: PodNetworkConfig(
            enabled: true,
            vmnetDisconnectRecovery: mode,
            networkName: "kubernetes-pod",
            vmnetRecovery: VMNetRecoveryConfig(
                statePath: statePath,
                requestPath: root.appendingPathComponent("requests/fence.json").path,
                requestWriterUID: Int(geteuid()),
                maxRebootAttempts: maxRebootAttempts,
                minimumRebootIntervalSeconds: minimumRebootIntervalSeconds,
                attemptWindowSeconds: 3600,
                maximumRequestAgeSeconds: 900,
                verificationTimeoutSeconds: 300,
                pollIntervalSeconds: 1,
                healthyProbeFailureThreshold: healthyProbeFailureThreshold
            )
        )
    )
    try await body(RecoveryTestContext(root: root, config: config))
}
