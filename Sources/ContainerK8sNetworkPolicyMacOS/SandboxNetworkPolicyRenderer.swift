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

import ContainerResource
import ContainerizationExtras
import Foundation

public struct PolicyRenderingFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

public enum CompiledSandboxNetworkPolicyRenderer {
    public static func render(
        _ policy: CompiledEndpointPolicy,
        auditMode: SandboxNetworkAuditMode = .disabled
    ) throws -> SandboxNetworkPolicy {
        let ingressACL = try renderACL(
            policy.ingressACL,
            defaultDirection: .ingress,
            policy: policy
        )
        let egressACL = try renderACL(
            policy.egressACL,
            defaultDirection: .egress,
            policy: policy
        )

        return SandboxNetworkPolicy(
            sandboxID: policy.endpoint.sandboxID,
            generation: policy.generation,
            ingressACL: ingressACL,
            egressACL: egressACL,
            defaultAction: .deny,
            auditMode: auditMode
        )
    }

    public static func render(
        _ policySet: CompiledNetworkPolicySet,
        auditMode: SandboxNetworkAuditMode = .disabled
    ) throws -> [SandboxNetworkPolicy] {
        try policySet.endpointPolicies.map { try render($0, auditMode: auditMode) }
    }

    private static func renderACL(
        _ acl: [CompiledACLRule],
        defaultDirection: SandboxNetworkPolicyDirection,
        policy: CompiledEndpointPolicy
    ) throws -> [SandboxNetworkPolicyRule] {
        var rendered: [SandboxNetworkPolicyRule] = []
        rendered.reserveCapacity(acl.count + 1)

        for rule in acl {
            rendered.append(contentsOf: try rule.render())
        }

        if defaultAction(for: defaultDirection, policy: policy) == .allow {
            rendered.append(
                SandboxNetworkPolicyRule(
                    id: defaultRuleID(for: policy, direction: defaultDirection),
                    action: .allow,
                    protocols: [.tcp, .udp],
                    endpoints: [],
                    ports: []
                )
            )
        }

        return rendered
    }

    private static func defaultAction(
        for direction: SandboxNetworkPolicyDirection,
        policy: CompiledEndpointPolicy
    ) -> SandboxNetworkPolicyAction {
        switch direction {
        case .ingress:
            return SandboxNetworkPolicyAction(rawValue: policy.ingressDefaultAction.rawValue) ?? .deny
        case .egress:
            return SandboxNetworkPolicyAction(rawValue: policy.egressDefaultAction.rawValue) ?? .deny
        }
    }

    private static func defaultRuleID(
        for policy: CompiledEndpointPolicy,
        direction: SandboxNetworkPolicyDirection
    ) -> String {
        [
            policy.endpoint.sandboxID,
            "g\(policy.generation)",
            direction.rawValue,
            "default",
            "allow",
        ].joined(separator: "-")
    }
}

extension CompiledEndpointPolicy {
    public func renderedSandboxPolicy(
        auditMode: SandboxNetworkAuditMode = .disabled
    ) throws -> SandboxNetworkPolicy {
        try CompiledSandboxNetworkPolicyRenderer.render(self, auditMode: auditMode)
    }
}

extension CompiledACLRule {
    public func render() throws -> [SandboxNetworkPolicyRule] {
        let endpoints = try peer.renderedSandboxPolicyEndpoints()
        let action = SandboxNetworkPolicyAction(rawValue: action.rawValue) ?? .deny

        if let port {
            return [
                SandboxNetworkPolicyRule(
                    id: id,
                    action: action,
                    protocols: [try port.renderedSandboxProtocol()],
                    endpoints: endpoints,
                    ports: [SandboxNetworkPortRange.single(port.port)]
                )
            ]
        }

        return [
            SandboxNetworkPolicyRule(
                id: id,
                action: action,
                protocols: [.tcp, .udp],
                endpoints: endpoints,
                ports: []
            )
        ]
    }
}

extension CompiledPolicyPeer {
    fileprivate func renderedSandboxPolicyEndpoints() throws -> [SandboxNetworkPolicyEndpoint] {
        switch self {
        case .any:
            return []
        case .ipv4Host(let host):
            return [.ipv4Host(try IPAddress(host.description))]
        case .ipv4CIDR(let cidr):
            return [.ipv4CIDR(try CIDRv4(cidr.description))]
        }
    }
}

extension NumericPortSelector {
    fileprivate func renderedSandboxProtocol() throws -> PublishProtocol {
        switch protocolName {
        case .tcp:
            return .tcp
        case .udp:
            return .udp
        }
    }
}
