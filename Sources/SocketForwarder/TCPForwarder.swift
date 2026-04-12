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

import Foundation
import Logging
import NIO
import NIOFoundationCompat

public struct TCPForwarder: SocketForwarder {
    private let proxyAddress: SocketAddress

    private let serverAddress: SocketAddress

    private let eventLoopGroup: any EventLoopGroup

    private let log: Logger?

    private let policyEvaluator: SocketForwarderPolicyEvaluator?

    public init(
        proxyAddress: SocketAddress,
        serverAddress: SocketAddress,
        eventLoopGroup: any EventLoopGroup,
        log: Logger? = nil,
        policyEvaluator: SocketForwarderPolicyEvaluator? = nil
    ) throws {
        self.proxyAddress = proxyAddress
        self.serverAddress = serverAddress
        self.eventLoopGroup = eventLoopGroup
        self.log = log
        self.policyEvaluator = policyEvaluator
    }

    public func run() throws -> EventLoopFuture<SocketForwarderResult> {
        self.log?.trace("frontend - creating listener")
        let tracker = ForwarderChannelTracker()

        let bootstrap = ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                if let policyEvaluator = self.policyEvaluator,
                    let sourceAddress = channel.remoteAddress
                {
                    let decision = policyEvaluator(
                        SocketForwarderPolicyEvaluation(
                            proto: .tcp,
                            sourceAddress: sourceAddress,
                            destinationAddress: self.serverAddress
                        )
                    )
                    guard decision.action == .allow else {
                        self.log?.trace("frontend - closing TCP connection denied by policy")
                        return channel.close()
                    }
                }
                tracker.register(channel)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ConnectHandler(serverAddress: self.serverAddress, log: log, channelTracker: tracker)
                    )
                }
            }

        return
            bootstrap
            .bind(to: self.proxyAddress)
            .map { SocketForwarderResult(channel: $0, tracker: tracker) }
    }
}
