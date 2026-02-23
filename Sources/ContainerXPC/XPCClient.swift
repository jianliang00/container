//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

#if os(macOS)
import ContainerizationError
import Foundation

public final class XPCClient: Sendable {
    private nonisolated(unsafe) let connection: xpc_connection_t
    private let q: DispatchQueue?
    private let service: String

    public init(service: String, queue: DispatchQueue? = nil) {
        let connection = xpc_connection_create_mach_service(service, queue, 0)
        self.connection = connection
        self.q = queue
        self.service = service

        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_set_target_queue(connection, self.q)
        xpc_connection_activate(connection)
    }

    public init(connection: xpc_connection_t, label: String, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.q = queue
        self.service = label

        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_set_target_queue(connection, self.q)
        xpc_connection_activate(connection)
    }

    deinit {
        self.close()
    }
}

extension XPCClient {
    /// Close the underlying XPC connection.
    public func close() {
        xpc_connection_cancel(connection)
    }

    /// Returns the pid of process to which we have a connection.
    /// Note: `xpc_connection_get_pid` returns 0 if no activity
    /// has taken place on the connection prior to it being called.
    public func remotePid() -> pid_t {
        xpc_connection_get_pid(self.connection)
    }

    /// Send the provided message to the service.
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
        let route = message.string(key: XPCMessage.routeKey) ?? "nil"
        return try await withCheckedThrowingContinuation { cont in
            // The XPC reply callback may never fire on timeout, so we gate completion
            // manually instead of relying on task-group cancellation semantics.
            final class CompletionState: @unchecked Sendable {
                let lock = NSLock()
                var completed = false
                var timeoutTask: Task<Void, Never>?
            }
            let state = CompletionState()

            let finish: @Sendable (Result<XPCMessage, Error>) -> Void = { result in
                var shouldResume = false
                var task: Task<Void, Never>?
                state.lock.lock()
                if !state.completed {
                    state.completed = true
                    shouldResume = true
                    task = state.timeoutTask
                    state.timeoutTask = nil
                }
                state.lock.unlock()

                guard shouldResume else {
                    return
                }
                task?.cancel()
                cont.resume(with: result)
            }

            xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                do {
                    finish(.success(try self.parseReply(reply)))
                } catch {
                    finish(.failure(error))
                }
            }

            guard let responseTimeout else {
                return
            }

            state.timeoutTask = Task {
                do {
                    try await Task.sleep(for: responseTimeout)
                } catch {
                    return
                }
                finish(
                    .failure(
                        ContainerizationError(
                            .internalError,
                            message: "XPC timeout for request to \(self.service)/\(route)"
                        )))
            }
        }
    }

    private func parseReply(_ reply: xpc_object_t) throws -> XPCMessage {
        switch xpc_get_type(reply) {
        case XPC_TYPE_ERROR:
            var code = ContainerizationError.Code.invalidState
            if reply.connectionError {
                code = .interrupted
            }
            throw ContainerizationError(
                code,
                message: "XPC connection error: \(reply.errorDescription ?? "unknown")"
            )
        case XPC_TYPE_DICTIONARY:
            let message = XPCMessage(object: reply)
            // check errors from our protocol
            try message.error()
            return message
        default:
            fatalError("unhandled xpc object type: \(xpc_get_type(reply))")
        }
    }
}

#endif
