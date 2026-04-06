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

import NIO
import Testing

@testable import SocketForwarder

extension SocketForwarderStressTests {
    @Test
    func testRapidConnectDisconnect() async throws {
        let requestCount = 96
        let maxConcurrentClients = 8

        try await withEventLoopGroup { eventLoopGroup in
            let serverAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let server = TCPEchoServer(serverAddress: serverAddress, eventLoopGroup: eventLoopGroup)
            let serverChannel = try await server.run().get()
            let actualServerAddress = try #require(serverChannel.localAddress)

            let proxyAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let forwarder = try TCPForwarder(
                proxyAddress: proxyAddress,
                serverAddress: actualServerAddress,
                eventLoopGroup: eventLoopGroup
            )
            let forwarderResult = try await forwarder.run().get()
            let actualProxyAddress = try #require(forwarderResult.proxyAddress)

            try await withForwarderCleanup(
                serverChannel: serverChannel,
                forwarderResult: forwarderResult
            ) {
                try await runThrowingTasks(
                    count: requestCount,
                    maxConcurrentTasks: maxConcurrentClients
                ) { _ in
                    do {
                        let channel = try await ClientBootstrap(group: eventLoopGroup)
                            .connectTimeout(.seconds(2))
                            .connect(to: actualProxyAddress)
                            .get()

                        try await channel.close()
                    } catch {
                        // Going to ignore connection errors as we are intentionally stressing it.
                    }
                }
            }
        }
    }
}
