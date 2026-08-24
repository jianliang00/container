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

import Foundation

public struct FlannelWithdrawalOutcome: Codable, Sendable, Equatable {
    public var succeeded: Bool
    public var message: String

    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded
        self.message = message
    }
}

public actor FlannelDaemonLifecycle {
    public enum State: String, Sendable, Equatable {
        case idle
        case reconciling
        case withdrawn
        case cleaned
    }

    public typealias ReconcileOperation = @Sendable () async throws -> Void
    public typealias CleanupOperation = @Sendable () async throws -> FlannelCleanupResult

    private let reconcileOperation: ReconcileOperation
    private let cleanupOperation: CleanupOperation
    private var reconcileTask: Task<Void, Never>?
    private var withdrawalTask: Task<FlannelWithdrawalOutcome, Never>?
    private var stateValue: State = .idle

    public init(controller: FlannelVXLANController) {
        self.reconcileOperation = {
            try await controller.runForever()
        }
        self.cleanupOperation = {
            try await controller.shutdown()
        }
    }

    public init(
        reconcile: @escaping ReconcileOperation,
        cleanup: @escaping CleanupOperation
    ) {
        self.reconcileOperation = reconcile
        self.cleanupOperation = cleanup
    }

    public var state: State {
        stateValue
    }

    public func start(
        onReconcileExit: @escaping @Sendable (Error) -> Void = { error in
            fputs("container-flannel-vxlan-macos: reconcile loop exited: \(error)\n", stderr)
        }
    ) {
        guard stateValue == .idle, reconcileTask == nil else {
            return
        }
        stateValue = .reconciling
        let operation = reconcileOperation
        reconcileTask = Task {
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                onReconcileExit(error)
            }
        }
    }

    public func withdraw() async -> FlannelWithdrawalOutcome {
        if stateValue == .cleaned {
            return FlannelWithdrawalOutcome(succeeded: true, message: "dataplane already withdrawn")
        }

        await stopReconciliation()
        stateValue = .withdrawn

        if let withdrawalTask {
            return await withdrawalTask.value
        }
        let cleanup = cleanupOperation
        let task = Task<FlannelWithdrawalOutcome, Never> {
            do {
                let result = try await cleanup()
                return FlannelWithdrawalOutcome(
                    succeeded: true,
                    message: "withdrawn routes=\(result.removedRoutes.count) "
                        + "tunnelStopped=\(result.stoppedTunnel) "
                        + "forwardingRestored=\(result.restoredForwardingFamilies.count)"
                )
            } catch {
                return FlannelWithdrawalOutcome(succeeded: false, message: String(describing: error))
            }
        }
        withdrawalTask = task
        let outcome = await task.value
        withdrawalTask = nil
        if outcome.succeeded {
            stateValue = .cleaned
        }
        return outcome
    }

    public func terminateWhenClean(
        retryDelay: Duration = .seconds(1),
        onCleanupError: @escaping @Sendable (String) -> Void = { message in
            fputs("container-flannel-vxlan-macos: withdrawal failed, retaining dataplane for retry: \(message)\n", stderr)
        }
    ) async {
        while true {
            let outcome = await withdraw()
            guard !outcome.succeeded else {
                return
            }
            onCleanupError(outcome.message)
            // A cancelled termination task must still retain the controller
            // and retry at a bounded rate until withdrawal completes.
            _ = await Task.detached {
                try? await Task.sleep(for: retryDelay)
            }.value
        }
    }

    private func stopReconciliation() async {
        guard let task = reconcileTask else {
            return
        }
        task.cancel()
        await task.value
        reconcileTask = nil
    }
}
