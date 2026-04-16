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

public struct K8sNetworkPolicyControllerConfig: Codable, Sendable, Equatable {
    public let nodeName: String
    public let networkID: String
    public let kubeconfigPath: String?
    public let requiredEgressAllows: [ExplicitEgressAllowRequirement]

    public init(
        nodeName: String,
        networkID: String = "default",
        kubeconfigPath: String? = nil,
        requiredEgressAllows: [ExplicitEgressAllowRequirement] = []
    ) {
        self.nodeName = nodeName
        self.networkID = networkID
        self.kubeconfigPath = kubeconfigPath
        self.requiredEgressAllows = requiredEgressAllows
    }
}

public struct EndpointIdentity: Codable, Sendable, Hashable {
    public let namespace: String
    public let podName: String
    public let podUID: String
    public let nodeName: String
    public let sandboxID: String
    public let ipv4Address: IPv4Address
    public let labels: [String: String]
    public let namespaceLabels: [String: String]

    public init(
        namespace: String,
        podName: String,
        podUID: String,
        nodeName: String,
        sandboxID: String,
        ipv4Address: IPv4Address,
        labels: [String: String] = [:],
        namespaceLabels: [String: String] = [:]
    ) {
        self.namespace = namespace
        self.podName = podName
        self.podUID = podUID
        self.nodeName = nodeName
        self.sandboxID = sandboxID
        self.ipv4Address = ipv4Address
        self.labels = labels
        self.namespaceLabels = namespaceLabels
    }
}

public struct IPv4Address: Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.parse(rawValue) != nil else {
            throw PolicyCompilationFailure("invalid IPv4 address \(rawValue)")
        }
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    fileprivate var numericValue: UInt32 {
        Self.parse(rawValue)!
    }

    private static func parse(_ rawValue: String) -> UInt32? {
        let octets = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return nil
        }

        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else {
                return nil
            }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}

public struct IPv4CIDR: Codable, Sendable, Hashable, CustomStringConvertible {
    public let address: IPv4Address
    public let prefixLength: UInt8

    public init(_ rawValue: String) throws {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = UInt8(parts[1]), prefix <= 32 else {
            throw PolicyCompilationFailure("invalid IPv4 CIDR \(rawValue)")
        }
        self.address = try IPv4Address(String(parts[0]))
        self.prefixLength = prefix
    }

    public init(address: IPv4Address, prefixLength: UInt8) throws {
        guard prefixLength <= 32 else {
            throw PolicyCompilationFailure("invalid IPv4 CIDR prefix \(prefixLength)")
        }
        self.address = address
        self.prefixLength = prefixLength
    }

    public var description: String {
        "\(address.rawValue)/\(prefixLength)"
    }

    public func contains(_ candidate: IPv4Address) -> Bool {
        guard prefixLength > 0 else {
            return true
        }
        let mask = UInt32.max << UInt32(32 - prefixLength)
        return (address.numericValue & mask) == (candidate.numericValue & mask)
    }
}

public struct LabelSelector: Codable, Sendable, Hashable {
    public let matchLabels: [String: String]

    public init(matchLabels: [String: String] = [:]) {
        self.matchLabels = matchLabels
    }

    public func matches(_ labels: [String: String]) -> Bool {
        matchLabels.allSatisfy { key, value in
            labels[key] == value
        }
    }
}

public enum NetworkPolicyDirection: String, Codable, Sendable, Hashable {
    case ingress
    case egress
}

public enum NetworkPolicyProtocol: String, Codable, Sendable, Hashable, CaseIterable {
    case tcp
    case udp
}

public enum NetworkPolicyAction: String, Codable, Sendable, Hashable {
    case allow
    case deny
}

public struct NumericPortSelector: Codable, Sendable, Hashable {
    public let protocolName: NetworkPolicyProtocol
    public let port: UInt16

    public init(_ protocolName: NetworkPolicyProtocol, port: UInt16) throws {
        guard port > 0 else {
            throw PolicyCompilationFailure("network policy port must be greater than zero")
        }
        self.protocolName = protocolName
        self.port = port
    }
}

public enum CompiledPolicyPeer: Codable, Sendable, Hashable {
    case any
    case ipv4Host(IPv4Address)
    case ipv4CIDR(IPv4CIDR)

    public func contains(_ address: IPv4Address) -> Bool {
        switch self {
        case .any:
            true
        case .ipv4Host(let host):
            host == address
        case .ipv4CIDR(let cidr):
            cidr.contains(address)
        }
    }
}

public struct NetworkPolicyPeer: Codable, Sendable, Hashable {
    public let podSelector: LabelSelector?
    public let namespaceSelector: LabelSelector?
    public let ipBlock: IPv4CIDR?

    public init(
        podSelector: LabelSelector? = nil,
        namespaceSelector: LabelSelector? = nil,
        ipBlock: IPv4CIDR? = nil
    ) {
        self.podSelector = podSelector
        self.namespaceSelector = namespaceSelector
        self.ipBlock = ipBlock
    }
}

public struct NetworkPolicyRule: Codable, Sendable, Hashable {
    public let peers: [NetworkPolicyPeer]
    public let ports: [NumericPortSelector]

    public init(peers: [NetworkPolicyPeer] = [], ports: [NumericPortSelector] = []) {
        self.peers = peers
        self.ports = ports
    }
}

public struct NetworkPolicyResource: Codable, Sendable, Hashable {
    public let namespace: String
    public let name: String
    public let uid: String
    public let podSelector: LabelSelector
    public let policyTypes: Set<NetworkPolicyDirection>
    public let ingress: [NetworkPolicyRule]
    public let egress: [NetworkPolicyRule]

    public init(
        namespace: String,
        name: String,
        uid: String,
        podSelector: LabelSelector,
        policyTypes: Set<NetworkPolicyDirection> = [],
        ingress: [NetworkPolicyRule] = [],
        egress: [NetworkPolicyRule] = []
    ) {
        self.namespace = namespace
        self.name = name
        self.uid = uid
        self.podSelector = podSelector
        self.policyTypes = policyTypes
        self.ingress = ingress
        self.egress = egress
    }

    public func selects(_ endpoint: EndpointIdentity) -> Bool {
        namespace == endpoint.namespace && podSelector.matches(endpoint.labels)
    }

    public func selects(direction: NetworkPolicyDirection) -> Bool {
        if policyTypes.contains(direction) {
            return true
        }
        if !policyTypes.isEmpty {
            return false
        }

        switch direction {
        case .ingress:
            return true
        case .egress:
            return !egress.isEmpty
        }
    }
}

public struct ExplicitEgressAllowRequirement: Codable, Sendable, Hashable {
    public let id: String
    public let reason: String
    public let peer: CompiledPolicyPeer
    public let ports: [NumericPortSelector]

    public init(
        id: String,
        reason: String,
        peer: CompiledPolicyPeer,
        ports: [NumericPortSelector]
    ) {
        self.id = id
        self.reason = reason
        self.peer = peer
        self.ports = ports
    }
}

public struct ExplicitEgressAllowRequirementStatus: Codable, Sendable, Hashable {
    public let requirement: ExplicitEgressAllowRequirement
    public let satisfiedByRuleIDs: [String]

    public init(requirement: ExplicitEgressAllowRequirement, satisfiedByRuleIDs: [String]) {
        self.requirement = requirement
        self.satisfiedByRuleIDs = satisfiedByRuleIDs
    }

    public var isSatisfied: Bool {
        !satisfiedByRuleIDs.isEmpty
    }
}

public struct CompiledACLRule: Codable, Sendable, Hashable {
    public let id: String
    public let policyNamespace: String
    public let policyName: String
    public let direction: NetworkPolicyDirection
    public let action: NetworkPolicyAction
    public let peer: CompiledPolicyPeer
    public let port: NumericPortSelector?

    public init(
        id: String,
        policyNamespace: String,
        policyName: String,
        direction: NetworkPolicyDirection,
        action: NetworkPolicyAction,
        peer: CompiledPolicyPeer,
        port: NumericPortSelector?
    ) {
        self.id = id
        self.policyNamespace = policyNamespace
        self.policyName = policyName
        self.direction = direction
        self.action = action
        self.peer = peer
        self.port = port
    }

    public func satisfies(_ requirement: ExplicitEgressAllowRequirement) -> Bool {
        guard direction == .egress, action == .allow else {
            return false
        }

        let peerMatches =
            switch (peer, requirement.peer) {
            case (.any, _):
                true
            case (.ipv4Host(let host), .ipv4Host(let requiredHost)):
                host == requiredHost
            case (.ipv4CIDR(let cidr), .ipv4Host(let requiredHost)):
                cidr.contains(requiredHost)
            case (.ipv4CIDR(let cidr), .ipv4CIDR(let requiredCIDR)):
                cidr == requiredCIDR
            case (.ipv4Host(let host), .ipv4CIDR(let requiredCIDR)):
                requiredCIDR.contains(host)
            case (_, .any):
                false
            }
        guard peerMatches else {
            return false
        }

        guard let port else {
            return true
        }
        return requirement.ports.contains(port)
    }
}

public struct CompiledEndpointPolicy: Codable, Sendable, Hashable {
    public let endpoint: EndpointIdentity
    public let generation: UInt64
    public let ingressDefaultAction: NetworkPolicyAction
    public let egressDefaultAction: NetworkPolicyAction
    public let ingressACL: [CompiledACLRule]
    public let egressACL: [CompiledACLRule]
    public let egressAllowRequirements: [ExplicitEgressAllowRequirementStatus]

    public init(
        endpoint: EndpointIdentity,
        generation: UInt64,
        ingressDefaultAction: NetworkPolicyAction,
        egressDefaultAction: NetworkPolicyAction,
        ingressACL: [CompiledACLRule],
        egressACL: [CompiledACLRule],
        egressAllowRequirements: [ExplicitEgressAllowRequirementStatus]
    ) {
        self.endpoint = endpoint
        self.generation = generation
        self.ingressDefaultAction = ingressDefaultAction
        self.egressDefaultAction = egressDefaultAction
        self.ingressACL = ingressACL
        self.egressACL = egressACL
        self.egressAllowRequirements = egressAllowRequirements
    }

    public var requiresApply: Bool {
        ingressDefaultAction == .deny || egressDefaultAction == .deny
    }
}

public struct CompiledNetworkPolicySet: Codable, Sendable, Hashable {
    public let generation: UInt64
    public let endpointPolicies: [CompiledEndpointPolicy]

    public init(generation: UInt64, endpointPolicies: [CompiledEndpointPolicy]) {
        self.generation = generation
        self.endpointPolicies = endpointPolicies
    }
}

public struct PolicyCompilationInput: Codable, Sendable, Hashable {
    public let generation: UInt64
    public let nodeName: String
    public let endpoints: [EndpointIdentity]
    public let policies: [NetworkPolicyResource]
    public let requiredEgressAllows: [ExplicitEgressAllowRequirement]

    public init(
        generation: UInt64,
        nodeName: String,
        endpoints: [EndpointIdentity],
        policies: [NetworkPolicyResource],
        requiredEgressAllows: [ExplicitEgressAllowRequirement] = []
    ) {
        self.generation = generation
        self.nodeName = nodeName
        self.endpoints = endpoints
        self.policies = policies
        self.requiredEgressAllows = requiredEgressAllows
    }
}

public struct PolicyCompilationFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

public enum NetworkPolicyCompiler {
    public static func compile(_ input: PolicyCompilationInput) throws -> CompiledNetworkPolicySet {
        guard input.generation > 0 else {
            throw PolicyCompilationFailure("network policy generation must be greater than zero")
        }
        guard !input.nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolicyCompilationFailure("network policy node name cannot be empty")
        }

        let localEndpoints = input.endpoints.filter { $0.nodeName == input.nodeName }
        let endpointPolicies = localEndpoints.map { endpoint in
            compileEndpointPolicy(endpoint, input: input, allEndpoints: input.endpoints)
        }
        return CompiledNetworkPolicySet(generation: input.generation, endpointPolicies: endpointPolicies)
    }

    private static func compileEndpointPolicy(
        _ endpoint: EndpointIdentity,
        input: PolicyCompilationInput,
        allEndpoints: [EndpointIdentity]
    ) -> CompiledEndpointPolicy {
        let selectedPolicies = input.policies.filter { $0.selects(endpoint) }
        let ingressPolicies = selectedPolicies.filter { $0.selects(direction: .ingress) }
        let egressPolicies = selectedPolicies.filter { $0.selects(direction: .egress) }

        let ingressACL = compileACL(
            direction: .ingress,
            policies: ingressPolicies,
            ownerEndpoint: endpoint,
            allEndpoints: allEndpoints
        )
        let egressACL = compileACL(
            direction: .egress,
            policies: egressPolicies,
            ownerEndpoint: endpoint,
            allEndpoints: allEndpoints
        )
        let egressStatuses =
            egressPolicies.isEmpty
            ? []
            : input.requiredEgressAllows.map { requirement in
                ExplicitEgressAllowRequirementStatus(
                    requirement: requirement,
                    satisfiedByRuleIDs: egressACL.filter { $0.satisfies(requirement) }.map(\.id)
                )
            }

        return CompiledEndpointPolicy(
            endpoint: endpoint,
            generation: input.generation,
            ingressDefaultAction: ingressPolicies.isEmpty ? .allow : .deny,
            egressDefaultAction: egressPolicies.isEmpty ? .allow : .deny,
            ingressACL: ingressACL,
            egressACL: egressACL,
            egressAllowRequirements: egressStatuses
        )
    }

    private static func compileACL(
        direction: NetworkPolicyDirection,
        policies: [NetworkPolicyResource],
        ownerEndpoint: EndpointIdentity,
        allEndpoints: [EndpointIdentity]
    ) -> [CompiledACLRule] {
        var rules: [CompiledACLRule] = []

        for policy in policies.sorted(by: policySort) {
            let policyRules =
                switch direction {
                case .ingress:
                    policy.ingress
                case .egress:
                    policy.egress
                }
            for (ruleIndex, policyRule) in policyRules.enumerated() {
                let peers = resolvePeers(
                    policyRule.peers,
                    policy: policy,
                    ownerEndpoint: ownerEndpoint,
                    allEndpoints: allEndpoints
                )
                let ports = policyRule.ports.map(Optional.some).ifEmpty([nil])

                for peer in peers {
                    for port in ports {
                        rules.append(
                            CompiledACLRule(
                                id: [
                                    policy.namespace,
                                    policy.name,
                                    direction.rawValue,
                                    String(ruleIndex),
                                    String(rules.count),
                                ].joined(separator: "/"),
                                policyNamespace: policy.namespace,
                                policyName: policy.name,
                                direction: direction,
                                action: .allow,
                                peer: peer,
                                port: port
                            )
                        )
                    }
                }
            }
        }

        return rules
    }

    private static func resolvePeers(
        _ peers: [NetworkPolicyPeer],
        policy: NetworkPolicyResource,
        ownerEndpoint: EndpointIdentity,
        allEndpoints: [EndpointIdentity]
    ) -> [CompiledPolicyPeer] {
        guard !peers.isEmpty else {
            return [.any]
        }

        var compiledPeers: [CompiledPolicyPeer] = []
        for peer in peers {
            if let ipBlock = peer.ipBlock {
                compiledPeers.append(.ipv4CIDR(ipBlock))
            }

            let selectedEndpoints = allEndpoints.filter { candidate in
                guard candidate.nodeName == ownerEndpoint.nodeName else {
                    return false
                }

                if let namespaceSelector = peer.namespaceSelector {
                    guard namespaceSelector.matches(candidate.namespaceLabels) else {
                        return false
                    }
                } else if peer.ipBlock == nil {
                    guard candidate.namespace == policy.namespace else {
                        return false
                    }
                }

                if let podSelector = peer.podSelector {
                    guard podSelector.matches(candidate.labels) else {
                        return false
                    }
                }

                return peer.podSelector != nil || peer.namespaceSelector != nil
            }
            compiledPeers.append(contentsOf: selectedEndpoints.map { .ipv4Host($0.ipv4Address) })
        }

        return Array(Set(compiledPeers)).sorted(by: peerSort)
    }

    private static func policySort(_ lhs: NetworkPolicyResource, _ rhs: NetworkPolicyResource) -> Bool {
        if lhs.namespace != rhs.namespace {
            return lhs.namespace < rhs.namespace
        }
        return lhs.name < rhs.name
    }

    private static func peerSort(_ lhs: CompiledPolicyPeer, _ rhs: CompiledPolicyPeer) -> Bool {
        String(describing: lhs) < String(describing: rhs)
    }
}

public struct PolicyGenerationDecision: Sendable, Equatable {
    public let policyToApply: CompiledNetworkPolicySet?
    public let retainedPolicy: CompiledNetworkPolicySet?
    public let failedGeneration: UInt64?
    public let failureReason: String?

    public var retainedPreviousSuccessfulGeneration: Bool {
        retainedPolicy != nil && failedGeneration != nil
    }
}

public enum PolicyGenerationRetainer {
    public static func decision(
        previousSuccess: CompiledNetworkPolicySet?,
        attemptedGeneration: UInt64,
        result: Result<CompiledNetworkPolicySet, PolicyCompilationFailure>
    ) -> PolicyGenerationDecision {
        switch result {
        case .success(let compiled):
            return PolicyGenerationDecision(
                policyToApply: compiled,
                retainedPolicy: nil,
                failedGeneration: nil,
                failureReason: nil
            )
        case .failure(let failure):
            return PolicyGenerationDecision(
                policyToApply: nil,
                retainedPolicy: previousSuccess,
                failedGeneration: attemptedGeneration,
                failureReason: failure.message
            )
        }
    }
}

extension Array {
    fileprivate func ifEmpty(_ fallback: [Element]) -> [Element] {
        isEmpty ? fallback : self
    }
}
