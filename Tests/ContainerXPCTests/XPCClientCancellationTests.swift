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
import Foundation
import Synchronization
import Testing

@testable import ContainerXPC

struct XPCClientCancellationTests {
    @Test func cancellationClosesTransportWhileWaitingForReply() async throws {
        let started = AsyncStream<Void>.makeStream()
        let reply = Mutex<(@Sendable (Result<XPCMessage, Error>) -> Void)?>(nil)
        let request = Task {
            try await XPCClient.withConnectionCancellation(
                operation: {
                    try await XPCClient.awaitReply(responseTimeout: nil, service: "images", route: "pull") { finish in
                        reply.withLock { $0 = finish }
                        started.continuation.yield(())
                    }
                },
                close: {
                    let finish = reply.withLock { $0 }
                    finish?(.failure(CancellationError()))
                }
            )
        }
        for await _ in started.stream { break }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        // A transport reply racing with cancellation must not resume twice.
        let lateReply = reply.withLock { $0 }
        lateReply?(.failure(CancellationError()))
    }

    @Test func successfulRequestDoesNotCloseTransport() async throws {
        let closed = Mutex(false)
        let result = try await XPCClient.withConnectionCancellation(
            operation: { 42 }, close: { closed.withLock { $0 = true } }
        )
        #expect(result == 42)
        #expect(!closed.withLock { $0 })
    }

    @Test func alreadyCancelledRequestDoesNotSend() async throws {
        let sent = Mutex(false)
        let closed = Mutex(false)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await XPCClient.withConnectionCancellation(
                operation: { sent.withLock { $0 = true } },
                close: { closed.withLock { $0 = true } }
            )
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(!sent.withLock { $0 })
        #expect(closed.withLock { $0 })
    }
}
#endif
