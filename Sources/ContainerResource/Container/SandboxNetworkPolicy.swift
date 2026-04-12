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

import ContainerizationExtras
import Foundation

public enum SandboxNetworkPolicyAction: String, Codable, Sendable, Equatable {
    case allow
    case deny
}

public enum SandboxNetworkAuditMode: String, Codable, Sendable, Equatable {
    case disabled
    case denied
    case all
}

public enum SandboxNetworkPolicyDirection: String, Codable, Sendable, Equatable {
    case ingress
    case egress
}

public enum SandboxNetworkPolicyEndpoint: Codable, Sendable, Equatable {
    case ipv4CIDR(CIDRv4)
    case ipv4Host(IPAddress)

    public var isIPv4: Bool {
        switch self {
        case .ipv4CIDR:
            return true
        case .ipv4Host(let address):
            guard case .v4 = address else {
                return false
            }
            return true
        }
    }
}

public struct SandboxNetworkPortRange: Codable, Sendable, Equatable {
    public let lower: UInt16
    public let upper: UInt16

    public init(lower: UInt16, upper: UInt16) {
        self.lower = lower
        self.upper = upper
    }

    public static func single(_ port: UInt16) -> Self {
        Self(lower: port, upper: port)
    }

    public var isValid: Bool {
        lower > 0 && lower <= upper
    }
}

public struct SandboxNetworkPolicyRule: Codable, Sendable, Equatable {
    public let id: String
    public let action: SandboxNetworkPolicyAction
    public let protocols: [PublishProtocol]
    public let endpoints: [SandboxNetworkPolicyEndpoint]
    public let ports: [SandboxNetworkPortRange]

    public init(
        id: String,
        action: SandboxNetworkPolicyAction,
        protocols: [PublishProtocol],
        endpoints: [SandboxNetworkPolicyEndpoint],
        ports: [SandboxNetworkPortRange]
    ) {
        self.id = id
        self.action = action
        self.protocols = protocols
        self.endpoints = endpoints
        self.ports = ports
    }
}

public struct SandboxNetworkPolicy: Codable, Sendable, Equatable {
    public let sandboxID: String
    public let generation: UInt64
    public let ingressACL: [SandboxNetworkPolicyRule]
    public let egressACL: [SandboxNetworkPolicyRule]
    public let defaultAction: SandboxNetworkPolicyAction
    public let auditMode: SandboxNetworkAuditMode

    public init(
        sandboxID: String,
        generation: UInt64,
        ingressACL: [SandboxNetworkPolicyRule],
        egressACL: [SandboxNetworkPolicyRule],
        defaultAction: SandboxNetworkPolicyAction,
        auditMode: SandboxNetworkAuditMode
    ) {
        self.sandboxID = sandboxID
        self.generation = generation
        self.ingressACL = ingressACL
        self.egressACL = egressACL
        self.defaultAction = defaultAction
        self.auditMode = auditMode
    }

    public var rules: [SandboxNetworkPolicyRule] {
        ingressACL + egressACL
    }
}

public enum SandboxNetworkPolicyApplyResult: String, Codable, Sendable, Equatable {
    case stored
    case removed
}

public struct SandboxNetworkPolicyState: Codable, Sendable, Equatable {
    public let sandboxID: String
    public let networkID: String
    public let ipv4Address: IPAddress
    public let macAddress: MACAddress?
    public let generation: UInt64
    public let policy: SandboxNetworkPolicy
    public let renderedHostRuleIdentifiers: [String]
    public let lastApplyResult: SandboxNetworkPolicyApplyResult

    public init(
        sandboxID: String,
        networkID: String,
        ipv4Address: IPAddress,
        macAddress: MACAddress?,
        generation: UInt64,
        policy: SandboxNetworkPolicy,
        renderedHostRuleIdentifiers: [String],
        lastApplyResult: SandboxNetworkPolicyApplyResult
    ) {
        self.sandboxID = sandboxID
        self.networkID = networkID
        self.ipv4Address = ipv4Address
        self.macAddress = macAddress
        self.generation = generation
        self.policy = policy
        self.renderedHostRuleIdentifiers = renderedHostRuleIdentifiers
        self.lastApplyResult = lastApplyResult
    }
}

public enum MacOSGuestNetworkPolicyStore {
    public static let filename = "macos-guest-network-policy.json"

    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(filename)
    }

    public static func load(from root: URL) throws -> SandboxNetworkPolicyState? {
        let policyURL = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: policyURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: policyURL)
        return try JSONDecoder().decode(SandboxNetworkPolicyState.self, from: data)
    }

    public static func save(_ state: SandboxNetworkPolicyState, in root: URL) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL(root: root))
    }

    public static func remove(from root: URL) throws {
        let policyURL = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: policyURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: policyURL)
    }
}
