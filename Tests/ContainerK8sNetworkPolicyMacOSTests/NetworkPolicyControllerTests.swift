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
import Testing

@testable import ContainerK8sNetworkPolicyMacOS

struct NetworkPolicyControllerTests {
    @Test
    func reconcilesAddUpdateDeleteAndRestartThroughFakeAdapter() async throws {
        let config = K8sNetworkPolicyControllerConfig(
            nodeName: "node-a",
            networkID: "macvmnet"
        )
        let namespace = K8sNetworkPolicyNamespaceMetadata(name: "app", labels: ["name": "app"])
        let frontendPod = K8sNetworkPolicyPodMetadata(
            namespace: "app",
            name: "frontend",
            uid: "pod-frontend",
            nodeName: "node-a",
            sandboxID: "sandbox-frontend",
            labels: ["role": "frontend"]
        )
        let apiPod = K8sNetworkPolicyPodMetadata(
            namespace: "app",
            name: "api",
            uid: "pod-api",
            nodeName: "node-a",
            sandboxID: "sandbox-api",
            labels: ["role": "api"]
        )
        let cni = [
            K8sNetworkPolicyCNIEndpointMetadata(
                sandboxID: "sandbox-frontend",
                networkID: "macvmnet",
                nodeName: "node-a",
                ipv4Address: try IPv4Address("10.244.0.10"),
                macAddress: try MACAddress("02:42:ac:11:00:10")
            ),
            K8sNetworkPolicyCNIEndpointMetadata(
                sandboxID: "sandbox-api",
                networkID: "macvmnet",
                nodeName: "node-a",
                ipv4Address: try IPv4Address("10.244.0.20"),
                macAddress: try MACAddress("02:42:ac:11:00:20")
            ),
        ]

        let initialPolicy = NetworkPolicyResource(
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
        let initialSnapshot = K8sNetworkPolicyControllerSnapshot(
            generation: 1,
            namespaces: [namespace],
            pods: [frontendPod, apiPod],
            cniMetadata: cni,
            policies: [initialPolicy]
        )

        let initialResult = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: initialSnapshot
        )
        #expect(initialResult.plan.applyStates.count == 1)
        #expect(initialResult.plan.removedSandboxIDs.isEmpty)

        let adapter = K8sNetworkPolicyFakeAdapter()
        try await adapter.execute(initialResult.plan)
        #expect(adapter.appliedPoliciesBySandboxID.keys.sorted() == ["sandbox-api"])

        let restartResult = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: initialSnapshot,
            currentState: K8sNetworkPolicyControllerState(
                appliedPoliciesBySandboxID: adapter.appliedPoliciesBySandboxID
            )
        )
        #expect(restartResult.plan.isEmpty)

        let updatedPolicy = NetworkPolicyResource(
            namespace: "app",
            name: "allow-frontend-to-api",
            uid: "policy-1",
            podSelector: LabelSelector(matchLabels: ["role": "api"]),
            policyTypes: [.ingress, .egress],
            ingress: [
                NetworkPolicyRule(
                    peers: [
                        NetworkPolicyPeer(podSelector: LabelSelector(matchLabels: ["role": "frontend"]))
                    ],
                    ports: [
                        try NumericPortSelector(.tcp, port: 8443)
                    ]
                ),
                NetworkPolicyRule(
                    peers: [
                        NetworkPolicyPeer(ipBlock: try IPv4CIDR("10.244.0.0/24"))
                    ],
                    ports: [
                        try NumericPortSelector(.udp, port: 8443)
                    ]
                ),
            ],
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
        let updatedSnapshot = K8sNetworkPolicyControllerSnapshot(
            generation: 2,
            namespaces: [namespace],
            pods: [frontendPod, apiPod],
            cniMetadata: cni,
            policies: [updatedPolicy]
        )

        let updateResult = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: updatedSnapshot,
            currentState: K8sNetworkPolicyControllerState(
                appliedPoliciesBySandboxID: adapter.appliedPoliciesBySandboxID
            )
        )
        #expect(updateResult.plan.applyStates.count == 1)
        #expect(updateResult.plan.removedSandboxIDs.isEmpty)
        try await adapter.execute(updateResult.plan)
        let updatedState = try #require(adapter.appliedPoliciesBySandboxID["sandbox-api"])
        #expect(updatedState.generation == 2)
        #expect(updatedState.policy.ingressACL.count == 2)
        #expect(updatedState.policy.egressACL.count == 1)

        let deletedSnapshot = K8sNetworkPolicyControllerSnapshot(
            generation: 3,
            namespaces: [namespace],
            pods: [frontendPod],
            cniMetadata: [
                cni[0]
            ],
            policies: [updatedPolicy]
        )
        let deleteResult = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: deletedSnapshot,
            currentState: K8sNetworkPolicyControllerState(
                appliedPoliciesBySandboxID: adapter.appliedPoliciesBySandboxID
            )
        )
        #expect(deleteResult.plan.applyStates.isEmpty)
        #expect(deleteResult.plan.removedSandboxIDs == ["sandbox-api"])
    }

    @Test
    func controllerDoesNotInjectImplicitDnsGatewayOrApiserverAllows() throws {
        let config = K8sNetworkPolicyControllerConfig(
            nodeName: "node-a",
            networkID: "macvmnet"
        )
        let namespace = K8sNetworkPolicyNamespaceMetadata(name: "app")
        let pod = K8sNetworkPolicyPodMetadata(
            namespace: "app",
            name: "api",
            uid: "pod-api",
            nodeName: "node-a",
            sandboxID: "sandbox-api",
            labels: ["role": "api"]
        )
        let cni = K8sNetworkPolicyCNIEndpointMetadata(
            sandboxID: "sandbox-api",
            networkID: "macvmnet",
            nodeName: "node-a",
            ipv4Address: try IPv4Address("10.244.0.20")
        )
        let dnsPolicy = NetworkPolicyResource(
            namespace: "app",
            name: "explicit-dns-only",
            uid: "policy-1",
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
        let snapshot = K8sNetworkPolicyControllerSnapshot(
            generation: 9,
            namespaces: [namespace],
            pods: [pod],
            cniMetadata: [cni],
            policies: [dnsPolicy]
        )

        let result = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: snapshot
        )

        let compiledPolicy = try #require(result.plan.compiledPolicySet.endpointPolicies.first)
        #expect(compiledPolicy.egressDefaultAction == .deny)
        #expect(compiledPolicy.egressAllowRequirements.isEmpty)

        let appliedState = try #require(result.plan.applyStates.first)
        #expect(appliedState.policy.egressACL.map(\.id) == ["app/explicit-dns-only/egress/0/0"])
        #expect(appliedState.policy.egressACL.allSatisfy { !$0.id.contains("gateway") && !$0.id.contains("apiserver") })
    }

    @Test
    func unresolvedEndpointStaysOutOfTheDesiredPolicySetUntilCNIArrives() throws {
        let config = K8sNetworkPolicyControllerConfig(
            nodeName: "node-a",
            networkID: "macvmnet"
        )
        let namespace = K8sNetworkPolicyNamespaceMetadata(name: "app")
        let pod = K8sNetworkPolicyPodMetadata(
            namespace: "app",
            name: "api",
            uid: "pod-api",
            nodeName: "node-a",
            sandboxID: "sandbox-api",
            labels: ["role": "api"]
        )
        let policy = NetworkPolicyResource(
            namespace: "app",
            name: "allow-api",
            uid: "policy-1",
            podSelector: LabelSelector(matchLabels: ["role": "api"]),
            policyTypes: [.ingress],
            ingress: []
        )

        let snapshot = K8sNetworkPolicyControllerSnapshot(
            generation: 1,
            namespaces: [namespace],
            pods: [pod],
            cniMetadata: [],
            policies: [policy]
        )

        let index = K8sNetworkPolicyStateIndex(
            namespaces: snapshot.namespaces,
            pods: snapshot.pods,
            cniMetadata: snapshot.cniMetadata,
            policies: snapshot.policies
        )
        #expect(index.endpointStates.count == 1)
        #expect(!index.unresolvedEndpointStates.isEmpty)

        let result = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: snapshot
        )
        #expect(result.plan.operations.isEmpty)
        #expect(result.plan.compiledPolicySet.endpointPolicies.isEmpty)
    }
}
