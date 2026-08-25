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

struct VMNetRecoveryCoordinatorStatusTests {
    @Test
    func rebootSnapshotIsPublishedAfterAuthorityIsCountedAndBeforeShutdown() async throws {
        try await withCoordinatorStatusTestContext { context in
            try context.seedFence()
            let statusStore = CoordinatorStatusTestStore()
            let observation = RebootStatusObservation()
            let coordinator = context.coordinator(
                statusStore: statusStore,
                reboot: {
                    await observation.capture(
                        status: statusStore.currentStatus,
                        authority: try? context.stateStore.load()
                    )
                }
            )

            let result = try await coordinator.reconcileOnce()
            let captured = try #require(await observation.value)

            #expect(result == .rebootRequested)
            #expect(captured.status?.phase == .rebootRequested)
            #expect(captured.status?.rebootCommandResult == .requested)
            #expect(captured.status?.authorityPhase == .rebootRequested)
            #expect(captured.status?.rebootAttempts == 1)
            #expect(captured.authority?.phase == .rebootRequested)
            #expect(captured.authority?.rebootAttempts == 1)
        }
    }

    @Test
    func statusLoadAndSaveFailuresDoNotChangeRebootOrRecoveryAuthority() async throws {
        try await withCoordinatorStatusTestContext { context in
            try context.seedFence()
            let statusStore = CoordinatorStatusTestStore(failing: [.load, .save])
            let rebootCalls = AsyncCallCounter()
            let coordinator = context.coordinator(
                statusStore: statusStore,
                reboot: { await rebootCalls.increment() }
            )

            #expect(try await coordinator.reconcileOnce() == .rebootRequested)
            let authority = try #require(try context.stateStore.load())
            #expect(authority.phase == .rebootRequested)
            #expect(authority.rebootAttempts == 1)
            #expect(await rebootCalls.value == 1)
            #expect(statusStore.loadCalls > 0)
            #expect(statusStore.saveCalls > 0)
        }

        try await withCoordinatorStatusTestContext { context in
            try context.seedFence()
            let statusStore = CoordinatorStatusTestStore(failing: [.load, .save])
            let coordinator = context.coordinator(
                statusStore: statusStore,
                bootSessionID: "boot-b",
                verify: { _ in VMNetRecoveryVerification(networkInstanceID: "instance-b") }
            )

            #expect(
                try await coordinator.reconcileOnce()
                    == .recovered(networkInstanceID: "instance-b")
            )
            let authority = try #require(try context.stateStore.load())
            #expect(authority.phase == .healthy)
            #expect(authority.networkInstanceID == "instance-b")
            #expect(authority.bootSessionID == "boot-b")
            #expect(statusStore.loadCalls > 0)
            #expect(statusStore.saveCalls > 0)
        }
    }

    @Test
    func statusRemoveFailureDuringShutdownDoesNotChangeRebootAuthority() async throws {
        try await withCoordinatorStatusTestContext { context in
            try context.seedFence()
            let removalObserved = AsyncOneShotSignal()
            let rebootObserved = AsyncOneShotSignal()
            let statusStore = CoordinatorStatusTestStore(
                failing: [.load, .save, .remove],
                onRemove: { Task { await removalObserved.fire() } }
            )
            let coordinator = context.coordinator(
                statusStore: statusStore,
                reboot: { await rebootObserved.fire() }
            )
            let task = Task {
                try await coordinator.run()
            }

            await rebootObserved.wait()
            task.cancel()
            await removalObserved.wait()
            do {
                try await task.value
                Issue.record("expected the cancelled coordinator loop to throw")
            } catch is CancellationError {
                // Expected after the loop reaches its cancellation-aware sleep.
            } catch {
                Issue.record("unexpected coordinator loop error: \(error)")
            }

            let authority = try #require(try context.stateStore.load())
            #expect(authority.phase == .rebootRequested)
            #expect(authority.rebootAttempts == 1)
            #expect(statusStore.loadCalls > 0)
            #expect(statusStore.saveCalls > 0)
            #expect(statusStore.removeCalls > 0)
        }
    }

    @Test
    func rebootFailurePublishesCommandFailedAfterAuthorityRequest() async throws {
        try await withCoordinatorStatusTestContext { context in
            try context.seedFence()
            let statusStore = CoordinatorStatusTestStore()
            let coordinator = context.coordinator(
                statusStore: statusStore,
                reboot: { throw CoordinatorStatusTestError.rebootFailed }
            )

            do {
                _ = try await coordinator.reconcileOnce()
                Issue.record("expected the reboot command to fail")
            } catch CoordinatorStatusTestError.rebootFailed {
                // Expected.
            } catch {
                Issue.record("unexpected reboot error: \(error)")
            }

            let status = try #require(statusStore.currentStatus)
            let authority = try #require(try context.stateStore.load())
            #expect(status.state == .failed)
            #expect(status.phase == .failed)
            #expect(status.errorCode == "rebootCommandFailed")
            #expect(status.rebootCommandResult == .failed)
            #expect(status.authorityPhase == .rebootRequested)
            #expect(status.rebootAttempts == 1)
            #expect(status.counters.rebootCommandsFailed == 1)
            #expect(authority.phase == .rebootRequested)
            #expect(authority.rebootAttempts == 1)
        }
    }

    @Test
    func criAdmissionIgnoresRecoveryStatusContent() async throws {
        try await withCoordinatorStatusTestContext { context in
            _ = try context.stateStore.recordHealthyObservation(
                networkName: context.networkName,
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a",
                now: context.now
            )
            let statusPath = try #require(context.config.resolvedVMNetRecoveryConfig.statusPath)
            try Data("corrupt-status".utf8).write(to: URL(fileURLWithPath: statusPath))

            let healthyAdmission = CRIShimVMNetRecoveryController(
                config: context.config,
                bootSessionID: "boot-a"
            )
            try healthyAdmission.requireAdmission()

            _ = try context.stateStore.recordFence(
                networkName: context.networkName,
                networkInstanceID: "instance-a",
                failureReason: "helper disconnected",
                bootSessionID: "boot-a",
                attemptWindow: 3600,
                now: context.now.addingTimeInterval(1)
            )
            try Data(#"{"state":"ready"}"#.utf8).write(to: URL(fileURLWithPath: statusPath))

            let fencedAdmission = CRIShimVMNetRecoveryController(
                config: context.config,
                bootSessionID: "boot-a"
            )
            #expect(throws: (any Error).self) {
                try fencedAdmission.requireAdmission()
            }
        }
    }
}

private enum CoordinatorStatusTestError: Error, Sendable {
    case persistence
    case rebootFailed
}

private final class CoordinatorStatusTestStore: VMNetRecoveryStatusStoring, @unchecked Sendable {
    enum Operation: Hashable, Sendable {
        case load
        case save
        case remove
    }

    private let lock = NSLock()
    private let failing: Set<Operation>
    private let onRemove: @Sendable () -> Void
    private var status: VMNetRecoveryStatus?
    private var loads = 0
    private var saves = 0
    private var removes = 0

    init(
        failing: Set<Operation> = [],
        onRemove: @escaping @Sendable () -> Void = {}
    ) {
        self.failing = failing
        self.onRemove = onRemove
    }

    var currentStatus: VMNetRecoveryStatus? {
        withLock { status }
    }

    var loadCalls: Int {
        withLock { loads }
    }

    var saveCalls: Int {
        withLock { saves }
    }

    var removeCalls: Int {
        withLock { removes }
    }

    func load() throws -> VMNetRecoveryStatus? {
        try withLock {
            loads += 1
            if failing.contains(.load) {
                throw CoordinatorStatusTestError.persistence
            }
            return status
        }
    }

    func save(_ status: VMNetRecoveryStatus) throws {
        try withLock {
            saves += 1
            if failing.contains(.save) {
                throw CoordinatorStatusTestError.persistence
            }
            self.status = status
        }
    }

    func remove() throws {
        onRemove()
        try withLock {
            removes += 1
            if failing.contains(.remove) {
                throw CoordinatorStatusTestError.persistence
            }
            status = nil
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private actor RebootStatusObservation {
    struct Value: Sendable {
        var status: VMNetRecoveryStatus?
        var authority: VMNetRecoveryStateV1?
    }

    private(set) var value: Value?

    func capture(status: VMNetRecoveryStatus?, authority: VMNetRecoveryStateV1?) {
        value = Value(status: status, authority: authority)
    }
}

private actor AsyncCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor AsyncOneShotSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        guard !fired else {
            return
        }
        fired = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !fired else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct CoordinatorStatusTestContext: Sendable {
    let root: URL
    let config: CRIShimConfig
    let networkName = "kubernetes-pod"
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    var stateStore: VMNetRecoveryStateStore {
        VMNetRecoveryStateStore(path: config.resolvedVMNetRecoveryConfig.statePath!)
    }

    func seedFence() throws {
        _ = try stateStore.recordHealthyObservation(
            networkName: networkName,
            networkInstanceID: "instance-a",
            bootSessionID: "boot-a",
            now: now.addingTimeInterval(-10)
        )
        _ = try stateStore.recordFence(
            networkName: networkName,
            networkInstanceID: "instance-a",
            failureReason: "helper disconnected",
            bootSessionID: "boot-a",
            attemptWindow: 3600,
            now: now
        )
    }

    func coordinator(
        statusStore: CoordinatorStatusTestStore,
        bootSessionID: String = "boot-a",
        reboot: @escaping @Sendable () async throws -> Void = {},
        observe: @escaping @Sendable () async throws -> VMNetRecoveryVerification = {
            VMNetRecoveryVerification(networkInstanceID: "instance-a")
        },
        verify: @escaping @Sendable (String?) async throws -> VMNetRecoveryVerification = { _ in
            VMNetRecoveryVerification(networkInstanceID: "instance-b")
        }
    ) -> VMNetRecoveryCoordinator {
        VMNetRecoveryCoordinator(
            config: config,
            dependencies: VMNetRecoveryCoordinatorDependencies(
                currentBootSessionID: { bootSessionID },
                now: { now },
                reboot: reboot,
                observe: { _ in try await observe() },
                verify: { _, failedNetworkInstanceID in
                    try await verify(failedNetworkInstanceID)
                }
            ),
            statusRecorder: VMNetRecoveryStatusRecorder(
                store: statusStore,
                coordinatorInstanceID: "00000000-0000-4000-8000-000000000001",
                now: { now }
            ),
            log: Logger(label: "com.apple.container.vmnet-recovery-status-tests")
        )
    }
}

private func withCoordinatorStatusTestContext(
    _ body: (CoordinatorStatusTestContext) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VMNetRecoveryCoordinatorStatusTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let config = CRIShimConfig(
        podNetwork: PodNetworkConfig(
            enabled: true,
            vmnetDisconnectRecovery: .rebootNode,
            networkName: "kubernetes-pod",
            vmnetRecovery: VMNetRecoveryConfig(
                nodeName: "mac-status-test",
                statePath: root.appendingPathComponent("state.json").path,
                requestPath: root.appendingPathComponent("requests/fence.json").path,
                statusPath: root.appendingPathComponent("status.json").path,
                requestWriterUID: Int(geteuid()),
                maxRebootAttempts: 2,
                minimumRebootIntervalSeconds: 120,
                attemptWindowSeconds: 3600,
                maximumRequestAgeSeconds: 900,
                verificationTimeoutSeconds: 300,
                pollIntervalSeconds: 1,
                healthyProbeFailureThreshold: 3
            )
        )
    )
    try await body(CoordinatorStatusTestContext(root: root, config: config))
}
