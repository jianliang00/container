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

    public func matches(proto: PublishProtocol, endpoint: IPAddress, port: UInt16) -> Bool {
        guard protocols.contains(proto) else {
            return false
        }

        if !endpoints.isEmpty {
            guard endpoints.contains(where: { $0.contains(endpoint) }) else {
                return false
            }
        }

        if !ports.isEmpty {
            guard ports.contains(where: { $0.contains(port) }) else {
                return false
            }
        }

        return true
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

    public var validationIssues: [String] {
        var issues: [String] = []

        if sandboxID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("network policy sandbox id cannot be empty")
        }

        if generation == 0 {
            issues.append("network policy generation must be greater than zero")
        }

        var ids = Set<String>()
        for rule in rules {
            let ruleID = rule.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayRuleID = ruleID.isEmpty ? "<empty>" : ruleID

            if ruleID.isEmpty {
                issues.append("network policy rule id cannot be empty")
            } else if !ids.insert(ruleID).inserted {
                issues.append("duplicate network policy rule id \(ruleID)")
            }

            if rule.protocols.isEmpty {
                issues.append("network policy rule \(displayRuleID) must include at least one protocol")
            }

            let protocolNames = rule.protocols.map(\.rawValue)
            if Set(protocolNames).count != protocolNames.count {
                issues.append("network policy rule \(displayRuleID) contains duplicate protocols")
            }

            for endpoint in rule.endpoints where !endpoint.isIPv4 {
                issues.append("network policy rule \(displayRuleID) contains a non-IPv4 endpoint")
            }

            for port in rule.ports where !port.isValid {
                issues.append("network policy rule \(displayRuleID) contains an invalid port range")
            }
        }

        return issues
    }

    public func evaluate(
        direction: SandboxNetworkPolicyDirection,
        proto: PublishProtocol,
        endpoint: IPAddress,
        port: UInt16
    ) -> SandboxNetworkPolicyDecision {
        let rules =
            switch direction {
            case .ingress: ingressACL
            case .egress: egressACL
            }

        for rule in rules where rule.matches(proto: proto, endpoint: endpoint, port: port) {
            return SandboxNetworkPolicyDecision(action: rule.action, ruleID: rule.id)
        }

        return SandboxNetworkPolicyDecision(action: defaultAction, ruleID: nil)
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

public struct SandboxNetworkPolicyDecision: Codable, Sendable, Equatable {
    public let action: SandboxNetworkPolicyAction
    public let ruleID: String?

    public init(action: SandboxNetworkPolicyAction, ruleID: String?) {
        self.action = action
        self.ruleID = ruleID
    }
}

public enum SandboxNetworkAuditEnforcementSource: String, Codable, Sendable, Equatable {
    case publishedPort
    case hostPacket
}

public struct SandboxNetworkAuditEvent: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let sandboxID: String
    public let networkID: String
    public let policyGeneration: UInt64
    public let direction: SandboxNetworkPolicyDirection
    public let proto: PublishProtocol
    public let sourceIP: IPAddress
    public let sourcePort: UInt16?
    public let destinationIP: IPAddress
    public let destinationPort: UInt16?
    public let action: SandboxNetworkPolicyAction
    public let ruleID: String?
    public let enforcementSource: SandboxNetworkAuditEnforcementSource

    public init(
        timestamp: Date,
        sandboxID: String,
        networkID: String,
        policyGeneration: UInt64,
        direction: SandboxNetworkPolicyDirection,
        proto: PublishProtocol,
        sourceIP: IPAddress,
        sourcePort: UInt16?,
        destinationIP: IPAddress,
        destinationPort: UInt16?,
        action: SandboxNetworkPolicyAction,
        ruleID: String?,
        enforcementSource: SandboxNetworkAuditEnforcementSource
    ) {
        self.timestamp = timestamp
        self.sandboxID = sandboxID
        self.networkID = networkID
        self.policyGeneration = policyGeneration
        self.direction = direction
        self.proto = proto
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destinationIP = destinationIP
        self.destinationPort = destinationPort
        self.action = action
        self.ruleID = ruleID
        self.enforcementSource = enforcementSource
    }
}

extension SandboxNetworkPolicyEndpoint {
    public func contains(_ address: IPAddress) -> Bool {
        switch self {
        case .ipv4CIDR(let cidr):
            guard let ipv4 = address.ipv4 else {
                return false
            }
            return cidr.contains(ipv4)
        case .ipv4Host(let host):
            return host == address
        }
    }
}

extension SandboxNetworkPortRange {
    public func contains(_ port: UInt16) -> Bool {
        lower <= port && port <= upper
    }
}

public struct SandboxNetworkHostRule: Codable, Sendable, Equatable {
    public let id: String
    public let direction: SandboxNetworkPolicyDirection
    public let action: SandboxNetworkPolicyAction
    public let proto: PublishProtocol
    public let sandboxIPv4Address: IPAddress
    public let sandboxMACAddress: MACAddress?
    public let endpoint: SandboxNetworkPolicyEndpoint?
    public let portRange: SandboxNetworkPortRange?
    public let policyRuleID: String?
    public let isDefault: Bool

    public init(
        id: String,
        direction: SandboxNetworkPolicyDirection,
        action: SandboxNetworkPolicyAction,
        proto: PublishProtocol,
        sandboxIPv4Address: IPAddress,
        sandboxMACAddress: MACAddress?,
        endpoint: SandboxNetworkPolicyEndpoint?,
        portRange: SandboxNetworkPortRange?,
        policyRuleID: String?,
        isDefault: Bool
    ) {
        self.id = id
        self.direction = direction
        self.action = action
        self.proto = proto
        self.sandboxIPv4Address = sandboxIPv4Address
        self.sandboxMACAddress = sandboxMACAddress
        self.endpoint = endpoint
        self.portRange = portRange
        self.policyRuleID = policyRuleID
        self.isDefault = isDefault
    }
}

public struct SandboxNetworkHostRuleSet: Codable, Sendable, Equatable {
    public let sandboxID: String
    public let networkID: String
    public let generation: UInt64
    public let rules: [SandboxNetworkHostRule]

    public init(
        sandboxID: String,
        networkID: String,
        generation: UInt64,
        rules: [SandboxNetworkHostRule]
    ) {
        self.sandboxID = sandboxID
        self.networkID = networkID
        self.generation = generation
        self.rules = rules
    }
}

public enum SandboxNetworkHostRuleRenderer {
    public static func render(_ state: SandboxNetworkPolicyState) -> SandboxNetworkHostRuleSet {
        var rules: [SandboxNetworkHostRule] = []
        rules.append(contentsOf: renderACL(state, direction: .ingress, acl: state.policy.ingressACL))
        rules.append(contentsOf: renderACL(state, direction: .egress, acl: state.policy.egressACL))
        rules.append(contentsOf: renderDefaultRules(state, direction: .ingress))
        rules.append(contentsOf: renderDefaultRules(state, direction: .egress))
        return SandboxNetworkHostRuleSet(
            sandboxID: state.sandboxID,
            networkID: state.networkID,
            generation: state.generation,
            rules: rules
        )
    }

    private static func renderACL(
        _ state: SandboxNetworkPolicyState,
        direction: SandboxNetworkPolicyDirection,
        acl: [SandboxNetworkPolicyRule]
    ) -> [SandboxNetworkHostRule] {
        var rendered: [SandboxNetworkHostRule] = []
        for rule in acl {
            let endpoints = rule.endpoints.map(Optional.some).ifEmpty([nil])
            let ports = rule.ports.map(Optional.some).ifEmpty([nil])
            for proto in rule.protocols {
                for endpoint in endpoints {
                    for port in ports {
                        rendered.append(
                            SandboxNetworkHostRule(
                                id: makeRuleID(
                                    sandboxID: state.sandboxID,
                                    generation: state.generation,
                                    direction: direction,
                                    proto: proto,
                                    policyRuleID: rule.id,
                                    index: rendered.count
                                ),
                                direction: direction,
                                action: rule.action,
                                proto: proto,
                                sandboxIPv4Address: state.ipv4Address,
                                sandboxMACAddress: state.macAddress,
                                endpoint: endpoint,
                                portRange: port,
                                policyRuleID: rule.id,
                                isDefault: false
                            )
                        )
                    }
                }
            }
        }
        return rendered
    }

    private static func renderDefaultRules(
        _ state: SandboxNetworkPolicyState,
        direction: SandboxNetworkPolicyDirection
    ) -> [SandboxNetworkHostRule] {
        [PublishProtocol.tcp, .udp].map { proto in
            SandboxNetworkHostRule(
                id: makeRuleID(
                    sandboxID: state.sandboxID,
                    generation: state.generation,
                    direction: direction,
                    proto: proto,
                    policyRuleID: "default",
                    index: 0
                ),
                direction: direction,
                action: state.policy.defaultAction,
                proto: proto,
                sandboxIPv4Address: state.ipv4Address,
                sandboxMACAddress: state.macAddress,
                endpoint: nil,
                portRange: nil,
                policyRuleID: nil,
                isDefault: true
            )
        }
    }

    private static func makeRuleID(
        sandboxID: String,
        generation: UInt64,
        direction: SandboxNetworkPolicyDirection,
        proto: PublishProtocol,
        policyRuleID: String,
        index: Int
    ) -> String {
        let raw = "\(sandboxID)-g\(generation)-\(direction.rawValue)-\(proto.rawValue)-\(policyRuleID)-\(index)"
        return raw.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }.reduce(into: "") { $0.append($1) }
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
        try data.write(to: fileURL(root: root), options: .atomic)
    }

    public static func remove(from root: URL) throws {
        let policyURL = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: policyURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: policyURL)
    }
}

public enum MacOSGuestHostNetworkPolicyStore {
    public static let filename = "macos-guest-host-network-policy.json"

    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(filename)
    }

    public static func load(from root: URL) throws -> SandboxNetworkHostRuleSet? {
        let ruleSetURL = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: ruleSetURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: ruleSetURL)
        return try JSONDecoder().decode(SandboxNetworkHostRuleSet.self, from: data)
    }

    public static func save(_ ruleSet: SandboxNetworkHostRuleSet, in root: URL) throws {
        let data = try JSONEncoder().encode(ruleSet)
        try data.write(to: fileURL(root: root), options: .atomic)
    }

    public static func remove(from root: URL) throws {
        let ruleSetURL = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: ruleSetURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: ruleSetURL)
    }
}

extension Array {
    fileprivate func ifEmpty(_ fallback: @autoclosure () -> [Element]) -> [Element] {
        isEmpty ? fallback() : self
    }
}
