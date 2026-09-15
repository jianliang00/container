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

import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

/// Track when long running work exits, and notify the caller via a callback.
public actor ExitMonitor {
    /// A callback that receives the client identifier and exit code.
    public typealias ExitCallback = @Sendable (String, ExitStatus) async throws -> Void

    /// Recover from a failed wait and return a terminal status only when exit
    /// can be established independently.
    public typealias WaitFailureCallback = @Sendable (String) async throws -> ExitStatus?

    /// A function that waits for work to complete, returning an exit code.
    public typealias WaitHandler = @Sendable () async throws -> ExitStatus

    /// Create a new monitor.
    ///
    /// - Parameters:
    ///   - log: The destination for log messages.
    public init(log: Logger? = nil) {
        self.log = log
    }

    private var exitCallbacks: [String: ExitCallback] = [:]
    private var runningTasks: [String: Task<Void, Never>] = [:]
    private let log: Logger?

    /// Remove tracked work from the monitor.
    ///
    /// - Parameters:
    ///   - id: The client identifier for the tracked work.
    public func stopTracking(id: String) async {
        if let task = self.runningTasks[id] {
            task.cancel()
        }
        exitCallbacks.removeValue(forKey: id)
        runningTasks.removeValue(forKey: id)
    }

    /// Register long running work so that the monitor invokes
    /// a callback when the work completes.
    ///
    /// - Parameters:
    ///   - id: The client identifier for the work.
    ///   - onExit: The callback to invoke when the work completes.
    public func registerProcess(id: String, onExit: @escaping ExitCallback) async throws {
        guard self.exitCallbacks[id] == nil else {
            throw ContainerizationError(.invalidState, message: "ExitMonitor already setup for process \(id)")
        }
        self.exitCallbacks[id] = onExit
    }

    /// Await the completion of previously registered item of work.
    ///
    /// - Parameters:
    ///   - id: The client identifier for the work.
    ///   - waitingOn: A function that waits for the work to complete,
    ///     and then returns an exit code.
    ///   - onWaitFailure: An optional recovery callback for runtimes that can
    ///     independently establish whether the work is still running.
    public func track(
        id: String,
        waitingOn: @escaping WaitHandler,
        onWaitFailure: WaitFailureCallback? = nil
    ) async throws {
        guard let onExit = self.exitCallbacks[id] else {
            throw ContainerizationError(.invalidState, message: "ExitMonitor not setup for process \(id)")
        }
        guard self.runningTasks[id] == nil else {
            throw ContainerizationError(.invalidState, message: "already have a running task tracking process \(id)")
        }
        self.runningTasks[id] = Task {
            while !Task.isCancelled {
                let exitStatus: ExitStatus?
                do {
                    exitStatus = try await waitingOn()
                } catch {
                    guard !Task.isCancelled else { return }
                    self.log?.error("WaitHandler for \(id) threw error \(String(describing: error))")
                    guard let onWaitFailure else {
                        try? await onExit(id, ExitStatus(exitCode: -1))
                        return
                    }
                    do {
                        exitStatus = try await onWaitFailure(id)
                    } catch {
                        self.log?.error("Wait failure recovery for \(id) failed: \(error)")
                        do {
                            try await Task.sleep(for: .seconds(2))
                        } catch {
                            return
                        }
                        continue
                    }
                    guard exitStatus != nil else {
                        do {
                            try await Task.sleep(for: .seconds(2))
                        } catch {
                            return
                        }
                        continue
                    }
                }
                guard !Task.isCancelled, let exitStatus else { return }
                while !Task.isCancelled {
                    do {
                        try await onExit(id, exitStatus)
                        return
                    } catch {
                        self.log?.error("Exit callback for \(id) failed: \(error)")
                        do {
                            try await Task.sleep(for: .seconds(2))
                        } catch {
                            return
                        }
                    }
                }
            }
        }
    }
}
