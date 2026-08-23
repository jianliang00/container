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

#if os(macOS)
import Synchronization

/// Represents a long-lived connection to an XPC service on the client side.
///
/// Obtain one via `XPCClient.openSession()`. The disconnect handler is
/// installed at initialisation time, before the first `send()`, so there is
/// no window in which a server crash goes undetected.
public final class XPCClientSession: Sendable {
    private let client: XPCClient
    private let disconnectState = XPCClientSessionDisconnectState()

    init(client: XPCClient) {
        self.client = client
        client.setDisconnectHandler { [weak self] in
            guard let self else { return }
            let snapshot = self.disconnectState.disconnect()
            Task { for handler in snapshot { await handler() } }
        }
    }

    /// Register a handler to be called when the server disconnects.
    public func onDisconnect(_ handler: @Sendable @escaping () async -> Void) {
        if disconnectState.register(handler) {
            Task { await handler() }
        }
    }

    /// Send a message over the persistent connection.
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
        try await client.send(message, responseTimeout: responseTimeout)
    }

    /// Cancel the underlying connection.
    public func close() {
        disconnectState.close()
        client.close()
    }
}

final class XPCClientSessionDisconnectState: Sendable {
    typealias Handler = @Sendable () async -> Void

    private enum Phase: Sendable {
        case active([Handler])
        case disconnected
        case closed
    }

    private let phase = Mutex<Phase>(.active([]))

    /// Returns true when the disconnect was already observed and the caller
    /// must run the newly registered handler immediately.
    func register(_ handler: @escaping Handler) -> Bool {
        phase.withLock { phase in
            switch phase {
            case .active(var handlers):
                handlers.append(handler)
                phase = .active(handlers)
                return false
            case .disconnected:
                return true
            case .closed:
                return false
            }
        }
    }

    /// Records an unexpected disconnect once and returns the handlers that
    /// were registered before it happened.
    func disconnect() -> [Handler] {
        phase.withLock { phase in
            guard case .active(let handlers) = phase else {
                return []
            }
            phase = .disconnected
            return handlers
        }
    }

    /// Suppresses a disconnect that races with an intentional close. If the
    /// unexpected disconnect won the race, keep it sticky for late handlers.
    func close() {
        phase.withLock { phase in
            if case .active = phase {
                phase = .closed
            }
        }
    }
}

#endif
