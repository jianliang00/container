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
import Testing

@testable import ContainerK8sNetworkPolicyMacOS

struct SandboxNetworkPolicyRendererTests {
    @Test
    func rendersCompiledEndpointPolicyIntoSandboxPolicy() throws {
        let rendered = try CompiledSandboxNetworkPolicyRenderer.render(try makeCompiledEndpointPolicy())

        #expect(rendered.sandboxID == "sandbox-api")
        #expect(rendered.generation == 17)
        #expect(rendered.defaultAction == .deny)
        #expect(rendered.auditMode == .disabled)

        let ingressACL = rendered.ingressACL
        #expect(ingressACL.count == 2)

        let ingressRule = ingressACL[0]
        #expect(ingressRule.id == "app/allow-frontend-to-api/ingress/0/0")
        #expect(ingressRule.action == .allow)
        #expect(ingressRule.protocols == [.tcp, .udp])
        #expect(ingressRule.ports.isEmpty)
        #expect(ingressRule.endpoints == [.ipv4Host(try IPAddress("10.244.0.10"))])

        let ingressDefault = ingressACL[1]
        #expect(ingressDefault.id == "sandbox-api-g17-ingress-default-allow")
        #expect(ingressDefault.action == .allow)
        #expect(ingressDefault.protocols == [.tcp, .udp])
        #expect(ingressDefault.ports.isEmpty)
        #expect(ingressDefault.endpoints.isEmpty)

        let egressACL = rendered.egressACL
        #expect(egressACL.count == 1)

        let egressRule = egressACL[0]
        #expect(egressRule.id == "app/allow-dns/egress/0/0")
        #expect(egressRule.action == .allow)
        #expect(egressRule.protocols == [.udp])
        #expect(egressRule.endpoints == [.ipv4CIDR(try CIDRv4("10.96.0.10/32"))])
        #expect(egressRule.ports == [.single(53)])
    }

    @Test
    func rendersPolicySetIntoSandboxPolicies() throws {
        let compiledSet = CompiledNetworkPolicySet(
            generation: 17,
            endpointPolicies: [
                try makeCompiledEndpointPolicy(),
                CompiledEndpointPolicy(
                    endpoint: EndpointIdentity(
                        namespace: "app",
                        podName: "worker",
                        podUID: "pod-worker",
                        nodeName: "node-a",
                        sandboxID: "sandbox-worker",
                        ipv4Address: try IPv4Address("10.244.0.30"),
                        labels: ["role": "worker"],
                        namespaceLabels: ["name": "app"]
                    ),
                    generation: 17,
                    ingressDefaultAction: .allow,
                    egressDefaultAction: .allow,
                    ingressACL: [],
                    egressACL: [],
                    egressAllowRequirements: []
                ),
            ]
        )

        let rendered = try CompiledSandboxNetworkPolicyRenderer.render(compiledSet)
        #expect(rendered.count == 2)

        let workerPolicy = rendered[1]
        #expect(workerPolicy.sandboxID == "sandbox-worker")
        #expect(workerPolicy.defaultAction == .deny)
        #expect(workerPolicy.ingressACL.count == 1)
        #expect(workerPolicy.egressACL.count == 1)
    }

    private func makeCompiledEndpointPolicy() throws -> CompiledEndpointPolicy {
        CompiledEndpointPolicy(
            endpoint: EndpointIdentity(
                namespace: "app",
                podName: "api",
                podUID: "pod-api",
                nodeName: "node-a",
                sandboxID: "sandbox-api",
                ipv4Address: try IPv4Address("10.244.0.20"),
                labels: ["role": "api"],
                namespaceLabels: ["name": "app"]
            ),
            generation: 17,
            ingressDefaultAction: .allow,
            egressDefaultAction: .deny,
            ingressACL: [
                CompiledACLRule(
                    id: "app/allow-frontend-to-api/ingress/0/0",
                    policyNamespace: "app",
                    policyName: "allow-frontend-to-api",
                    direction: .ingress,
                    action: .allow,
                    peer: .ipv4Host(try IPv4Address("10.244.0.10")),
                    port: nil
                )
            ],
            egressACL: [
                CompiledACLRule(
                    id: "app/allow-dns/egress/0/0",
                    policyNamespace: "app",
                    policyName: "allow-dns",
                    direction: .egress,
                    action: .allow,
                    peer: .ipv4CIDR(try IPv4CIDR("10.96.0.10/32")),
                    port: try NumericPortSelector(.udp, port: 53)
                )
            ],
            egressAllowRequirements: []
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try dictionaryValue(JSONSerialization.jsonObject(with: data))
    }

    private func dictionaryValue(_ value: Any) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw RendererTestError.invalidJSON
        }
        return dictionary
    }

    private func arrayValue(_ value: Any?) throws -> [[String: Any]] {
        guard let array = value as? [[String: Any]] else {
            throw RendererTestError.invalidJSON
        }
        return array
    }

    private func portsValue(_ value: Any?) throws -> [[String: Any]] {
        guard let array = value as? [[String: Any]] else {
            throw RendererTestError.invalidJSON
        }
        return array
    }

    private func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private func stringArray(_ value: Any?) -> [String]? {
        value as? [String]
    }

    private func integerValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private enum RendererTestError: Error {
        case invalidJSON
    }
}
