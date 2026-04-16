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

import Testing

@testable import ContainerK8sNetworkPolicyMacOS

struct NetworkPolicyCompilerTests {
    @Test
    func compilesSimpleIngressPolicyForSelectedEndpoint() throws {
        let endpoints = try makeEndpoints()
        let policy = NetworkPolicyResource(
            namespace: "app",
            name: "allow-frontend-to-api",
            uid: "policy-1",
            podSelector: LabelSelector(matchLabels: ["role": "api"]),
            policyTypes: [.ingress],
            ingress: [
                NetworkPolicyRule(
                    peers: [
                        NetworkPolicyPeer(podSelector: LabelSelector(matchLabels: ["role": "frontend"]))
                    ],
                    ports: [
                        try NumericPortSelector(.tcp, port: 8443)
                    ]
                )
            ]
        )

        let compiled = try NetworkPolicyCompiler.compile(
            PolicyCompilationInput(
                generation: 1,
                nodeName: "node-a",
                endpoints: endpoints,
                policies: [policy]
            )
        )

        let apiPolicy = try #require(compiled.endpointPolicies.first { $0.endpoint.podName == "api" })
        #expect(apiPolicy.generation == 1)
        #expect(apiPolicy.ingressDefaultAction == .deny)
        #expect(apiPolicy.egressDefaultAction == .allow)
        #expect(apiPolicy.requiresApply)
        #expect(apiPolicy.ingressACL.count == 1)
        #expect(apiPolicy.ingressACL[0].direction == .ingress)
        #expect(apiPolicy.ingressACL[0].peer == .ipv4Host(try IPv4Address("10.244.0.10")))
        #expect(apiPolicy.ingressACL[0].port == (try NumericPortSelector(.tcp, port: 8443)))

        let frontendPolicy = try #require(compiled.endpointPolicies.first { $0.endpoint.podName == "frontend" })
        #expect(frontendPolicy.ingressDefaultAction == .allow)
        #expect(frontendPolicy.egressDefaultAction == .allow)
        #expect(!frontendPolicy.requiresApply)
    }

    @Test
    func compilesSimpleEgressPolicyAndReportsExplicitAllowRequirements() throws {
        let endpoints = try makeEndpoints()
        let dnsRequirement = ExplicitEgressAllowRequirement(
            id: "dns",
            reason: "cluster DNS must be explicitly allowed when egress is isolated",
            peer: .ipv4Host(try IPv4Address("10.96.0.10")),
            ports: [
                try NumericPortSelector(.udp, port: 53)
            ]
        )
        let apiRequirement = ExplicitEgressAllowRequirement(
            id: "apiserver",
            reason: "Kubernetes API access must be explicitly allowed when egress is isolated",
            peer: .ipv4Host(try IPv4Address("10.96.0.1")),
            ports: [
                try NumericPortSelector(.tcp, port: 443)
            ]
        )
        let policy = NetworkPolicyResource(
            namespace: "app",
            name: "allow-api-egress",
            uid: "policy-2",
            podSelector: LabelSelector(matchLabels: ["role": "api"]),
            policyTypes: [.egress],
            egress: [
                NetworkPolicyRule(
                    peers: [
                        NetworkPolicyPeer(ipBlock: try IPv4CIDR("10.96.0.10/32"))
                    ],
                    ports: [
                        try NumericPortSelector(.udp, port: 53)
                    ]
                )
            ]
        )

        let compiled = try NetworkPolicyCompiler.compile(
            PolicyCompilationInput(
                generation: 2,
                nodeName: "node-a",
                endpoints: endpoints,
                policies: [policy],
                requiredEgressAllows: [dnsRequirement, apiRequirement]
            )
        )

        let apiPolicy = try #require(compiled.endpointPolicies.first { $0.endpoint.podName == "api" })
        #expect(apiPolicy.ingressDefaultAction == .allow)
        #expect(apiPolicy.egressDefaultAction == .deny)
        #expect(apiPolicy.egressACL.count == 1)
        #expect(apiPolicy.egressACL[0].direction == .egress)
        #expect(apiPolicy.egressACL[0].peer == .ipv4CIDR(try IPv4CIDR("10.96.0.10/32")))
        #expect(apiPolicy.egressACL[0].port == (try NumericPortSelector(.udp, port: 53)))

        let dnsStatus = try #require(apiPolicy.egressAllowRequirements.first { $0.requirement.id == "dns" })
        #expect(dnsStatus.isSatisfied)
        let apiStatus = try #require(apiPolicy.egressAllowRequirements.first { $0.requirement.id == "apiserver" })
        #expect(!apiStatus.isSatisfied)
    }

    @Test
    func failedGenerationDecisionRetainsPreviousSuccessfulPolicy() throws {
        let previous = CompiledNetworkPolicySet(generation: 7, endpointPolicies: [])

        let decision = PolicyGenerationRetainer.decision(
            previousSuccess: previous,
            attemptedGeneration: 8,
            result: .failure(PolicyCompilationFailure("unsupported named port web"))
        )

        #expect(decision.policyToApply == nil)
        #expect(decision.retainedPolicy == previous)
        #expect(decision.failedGeneration == 8)
        #expect(decision.failureReason == "unsupported named port web")
        #expect(decision.retainedPreviousSuccessfulGeneration)
    }

    private func makeEndpoints() throws -> [EndpointIdentity] {
        [
            EndpointIdentity(
                namespace: "app",
                podName: "frontend",
                podUID: "pod-frontend",
                nodeName: "node-a",
                sandboxID: "sandbox-frontend",
                ipv4Address: try IPv4Address("10.244.0.10"),
                labels: ["role": "frontend"],
                namespaceLabels: ["name": "app"]
            ),
            EndpointIdentity(
                namespace: "app",
                podName: "api",
                podUID: "pod-api",
                nodeName: "node-a",
                sandboxID: "sandbox-api",
                ipv4Address: try IPv4Address("10.244.0.20"),
                labels: ["role": "api"],
                namespaceLabels: ["name": "app"]
            ),
            EndpointIdentity(
                namespace: "app",
                podName: "remote",
                podUID: "pod-remote",
                nodeName: "node-b",
                sandboxID: "sandbox-remote",
                ipv4Address: try IPv4Address("10.244.1.30"),
                labels: ["role": "frontend"],
                namespaceLabels: ["name": "app"]
            ),
        ]
    }
}
