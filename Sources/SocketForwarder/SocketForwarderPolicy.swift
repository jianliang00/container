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

import NIO

public enum SocketForwarderProtocol: Sendable, Equatable {
    case tcp
    case udp
}

public enum SocketForwarderPolicyAction: Sendable, Equatable {
    case allow
    case deny
}

public struct SocketForwarderPolicyEvaluation: Sendable, Equatable {
    public let proto: SocketForwarderProtocol
    public let sourceAddress: SocketAddress
    public let destinationAddress: SocketAddress

    public init(
        proto: SocketForwarderProtocol,
        sourceAddress: SocketAddress,
        destinationAddress: SocketAddress
    ) {
        self.proto = proto
        self.sourceAddress = sourceAddress
        self.destinationAddress = destinationAddress
    }
}

public struct SocketForwarderPolicyDecision: Sendable, Equatable {
    public let action: SocketForwarderPolicyAction

    public init(action: SocketForwarderPolicyAction) {
        self.action = action
    }

    public static let allow = SocketForwarderPolicyDecision(action: .allow)
    public static let deny = SocketForwarderPolicyDecision(action: .deny)
}

public typealias SocketForwarderPolicyEvaluator = @Sendable (SocketForwarderPolicyEvaluation) -> SocketForwarderPolicyDecision
