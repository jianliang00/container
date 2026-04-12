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
import NIO
import Testing

@testable import SocketForwarder

extension SocketForwarderStressTests {
    @Test
    func testTCPForwarderPolicyDeniesConnectionBeforeBackendConnect() async throws {
        let recorder = ForwarderPolicyRecorder(decision: .deny)

        try await withEventLoopGroup { eventLoopGroup in
            let serverAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let server = TCPEchoServer(serverAddress: serverAddress, eventLoopGroup: eventLoopGroup)
            let serverChannel = try await server.run().get()
            let actualServerAddress = try #require(serverChannel.localAddress)

            let proxyAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let forwarder = try TCPForwarder(
                proxyAddress: proxyAddress,
                serverAddress: actualServerAddress,
                eventLoopGroup: eventLoopGroup,
                policyEvaluator: recorder.evaluate
            )
            let forwarderResult = try await forwarder.run().get()
            let actualProxyAddress = try #require(forwarderResult.proxyAddress)

            try await withForwarderCleanup(
                serverChannel: serverChannel,
                forwarderResult: forwarderResult
            ) {
                let clientChannel = try await ClientBootstrap(group: eventLoopGroup)
                    .connectTimeout(.seconds(2))
                    .connect(to: actualProxyAddress)
                    .get()
                try await clientChannel.close().get()
            }

            let evaluations = recorder.evaluations()
            #expect(evaluations.count == 1)
            #expect(evaluations.first?.proto == .tcp)
            #expect(evaluations.first?.destinationAddress == actualServerAddress)
        }
    }

    @Test
    func testUDPForwarderPolicyDropsDeniedDatagramBeforeBackendWrite() async throws {
        let recorder = ForwarderPolicyRecorder(decision: .deny)

        try await withEventLoopGroup { eventLoopGroup in
            let serverAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let server = UDPEchoServer(serverAddress: serverAddress, eventLoopGroup: eventLoopGroup)
            let serverChannel = try await server.run().get()
            let actualServerAddress = try #require(serverChannel.localAddress)

            let proxyAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let forwarder = try UDPForwarder(
                proxyAddress: proxyAddress,
                serverAddress: actualServerAddress,
                eventLoopGroup: eventLoopGroup,
                policyEvaluator: recorder.evaluate
            )
            let forwarderResult = try await forwarder.run().get()
            let actualProxyAddress = try #require(forwarderResult.proxyAddress)

            try await withForwarderCleanup(
                serverChannel: serverChannel,
                forwarderResult: forwarderResult
            ) {
                let clientChannel = try await DatagramBootstrap(group: eventLoopGroup)
                    .connect(to: actualProxyAddress)
                    .get()
                let remoteAddress = try #require(clientChannel.remoteAddress)
                let data = ByteBufferAllocator().buffer(string: "denied")
                try await clientChannel.writeAndFlush(
                    AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: data)
                ).get()
                try await clientChannel.close().get()
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            let evaluations = recorder.evaluations()
            #expect(evaluations.count == 1)
            #expect(evaluations.first?.proto == .udp)
            #expect(evaluations.first?.destinationAddress == actualServerAddress)
        }
    }
}

private final class ForwarderPolicyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvaluations: [SocketForwarderPolicyEvaluation] = []
    private let decision: SocketForwarderPolicyDecision

    init(decision: SocketForwarderPolicyDecision) {
        self.decision = decision
    }

    func evaluate(_ evaluation: SocketForwarderPolicyEvaluation) -> SocketForwarderPolicyDecision {
        lock.withLock {
            recordedEvaluations.append(evaluation)
        }
        return decision
    }

    func evaluations() -> [SocketForwarderPolicyEvaluation] {
        lock.withLock {
            recordedEvaluations
        }
    }
}
