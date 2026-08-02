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

import Darwin
import Foundation
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelDaemonLifecycleTests {
    @Test
    func failedWithdrawalStopsReconcileRetainsLifecycleAndCanBeRetried() async throws {
        let operations = LifecycleOperations(cleanupFailures: 1)
        let lifecycle = FlannelDaemonLifecycle(
            reconcile: {
                try await operations.reconcile()
            },
            cleanup: {
                try await operations.cleanup()
            }
        )
        await lifecycle.start()
        try await waitUntil { await operations.reconcileStarts == 1 }

        let first = await lifecycle.withdraw()
        #expect(!first.succeeded)
        #expect(await lifecycle.state == .withdrawn)
        #expect(await operations.reconcileCancellations == 1)
        #expect(await operations.cleanupCalls == 1)

        let second = await lifecycle.withdraw()
        #expect(second.succeeded)
        #expect(await lifecycle.state == .cleaned)
        #expect(await operations.reconcileStarts == 1)
        #expect(await operations.cleanupCalls == 2)
    }

    @Test
    func terminationRetriesCleanupWithoutRestartingReconcile() async throws {
        let operations = LifecycleOperations(cleanupFailures: 2)
        let lifecycle = FlannelDaemonLifecycle(
            reconcile: {
                try await operations.reconcile()
            },
            cleanup: {
                try await operations.cleanup()
            }
        )
        await lifecycle.start()
        try await waitUntil { await operations.reconcileStarts == 1 }

        await lifecycle.terminateWhenClean(retryDelay: .zero, onCleanupError: { _ in })

        #expect(await lifecycle.state == .cleaned)
        #expect(await operations.cleanupCalls == 3)
        #expect(await operations.reconcileCancellations == 1)
        #expect(await operations.reconcileStarts == 1)
    }

    @Test
    func rootOnlyControlSocketReturnsCleanupAcknowledgement() async throws {
        let socketPath = "/tmp/flannel-control-\(UUID().uuidString).sock"
        let outcomes = ControlOutcomes()
        let server = FlannelControlServer(socketPath: socketPath, requiredPeerUID: geteuid())
        try server.start {
            await outcomes.next()
        }
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let first = try FlannelControlClient.requestWithdrawal(socketPath: socketPath)
        #expect(!first.succeeded)
        #expect(first.message == "injected cleanup failure")
        let second = try FlannelControlClient.requestWithdrawal(socketPath: socketPath)
        #expect(second.succeeded)
        #expect(second.message == "withdrawn")
        #expect(await outcomes.calls == 2)
    }
}

private actor LifecycleOperations {
    private(set) var reconcileStarts = 0
    private(set) var reconcileCancellations = 0
    private(set) var cleanupCalls = 0
    private var cleanupFailures: Int

    init(cleanupFailures: Int) {
        self.cleanupFailures = cleanupFailures
    }

    func reconcile() async throws {
        reconcileStarts += 1
        do {
            while true {
                try await Task.sleep(for: .seconds(60))
            }
        } catch is CancellationError {
            reconcileCancellations += 1
            throw CancellationError()
        }
    }

    func cleanup() throws -> FlannelCleanupResult {
        cleanupCalls += 1
        if cleanupFailures > 0 {
            cleanupFailures -= 1
            throw FlannelVXLANError.runtime("injected cleanup failure")
        }
        return FlannelCleanupResult(
            removedRoutes: ["10.250.2.0/24"],
            stoppedTunnel: true,
            removedNodeAnnotations: true,
            nodeAnnotationAttempts: 1
        )
    }
}

private actor ControlOutcomes {
    private(set) var calls = 0

    func next() -> FlannelWithdrawalOutcome {
        calls += 1
        if calls == 1 {
            return FlannelWithdrawalOutcome(succeeded: false, message: "injected cleanup failure")
        }
        return FlannelWithdrawalOutcome(succeeded: true, message: "withdrawn")
    }
}

private func waitUntil(
    attempts: Int = 100,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw FlannelVXLANError.runtime("condition was not satisfied")
}
