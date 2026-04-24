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
import Testing

@testable import ContainerK8sNetworkPolicyMacOS

struct NetworkPolicyControllerTests {
    @Test
    func watchEventsDriveIncrementalReconcilePlans() async throws {
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
        let frontendCNI = K8sNetworkPolicyCNIEndpointMetadata(
            sandboxID: "sandbox-frontend",
            networkID: "macvmnet",
            nodeName: "node-a",
            ipv4Address: try IPv4Address("10.244.0.10"),
            macAddress: try MACAddress("02:42:ac:11:00:10")
        )
        let apiCNI = K8sNetworkPolicyCNIEndpointMetadata(
            sandboxID: "sandbox-api",
            networkID: "macvmnet",
            nodeName: "node-a",
            ipv4Address: try IPv4Address("10.244.0.20"),
            macAddress: try MACAddress("02:42:ac:11:00:20")
        )
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

        var watchState = K8sNetworkPolicyWatchState()
        watchState.apply(.upsertNamespace(namespace))
        watchState.apply(.upsertPod(frontendPod))
        watchState.apply(.upsertPod(apiPod))
        watchState.apply(.upsertCNIEndpoint(frontendCNI))
        watchState.apply(.upsertCNIEndpoint(apiCNI))
        let initialSnapshot = watchState.apply(.upsertNetworkPolicy(initialPolicy))

        let initialResult = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: initialSnapshot
        )
        #expect(initialSnapshot.generation == 6)
        #expect(initialResult.plan.applyStates.map(\.sandboxID) == ["sandbox-api"])

        let adapter = K8sNetworkPolicyFakeAdapter()
        let appliedInitialState = try await adapter.execute(initialResult.plan)
        #expect(appliedInitialState.appliedPoliciesBySandboxID.keys.sorted() == ["sandbox-api"])

        let duplicateSnapshot = watchState.apply(.upsertNetworkPolicy(initialPolicy))
        #expect(duplicateSnapshot.generation == initialSnapshot.generation)

        let updatedPolicy = NetworkPolicyResource(
            namespace: "app",
            name: "allow-frontend-to-api",
            uid: "policy-1",
            podSelector: LabelSelector(matchLabels: ["role": "api"]),
            policyTypes: [.ingress, .egress],
            ingress: initialPolicy.ingress,
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
        let updateSnapshot = watchState.apply(.upsertNetworkPolicy(updatedPolicy))
        let updateResult = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: updateSnapshot,
            currentState: K8sNetworkPolicyControllerState(
                appliedPoliciesBySandboxID: adapter.appliedPoliciesBySandboxID
            )
        )
        #expect(updateSnapshot.generation == 7)
        #expect(updateResult.plan.applyStates.map(\.sandboxID) == ["sandbox-api"])
        let appliedUpdateState = try await adapter.execute(updateResult.plan)
        #expect(appliedUpdateState.appliedPoliciesBySandboxID["sandbox-api"]?.generation == 7)
        #expect(adapter.appliedPoliciesBySandboxID["sandbox-api"]?.generation == 7)

        let deleteSnapshot = watchState.apply(.deletePod(uid: "pod-api"))
        let deleteResult = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: deleteSnapshot,
            currentState: K8sNetworkPolicyControllerState(
                appliedPoliciesBySandboxID: adapter.appliedPoliciesBySandboxID
            )
        )
        #expect(deleteSnapshot.generation == 8)
        #expect(deleteResult.plan.removedSandboxIDs == ["sandbox-api"])
        try await adapter.execute(deleteResult.plan)

        let relistSnapshot = watchState.replace(
            with: K8sNetworkPolicyControllerSnapshot(
                generation: 100,
                namespaces: [namespace],
                pods: [frontendPod, apiPod],
                cniMetadata: [frontendCNI, apiCNI],
                policies: [updatedPolicy]
            ))
        let relistResult = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: relistSnapshot,
            currentState: K8sNetworkPolicyControllerState(
                appliedPoliciesBySandboxID: adapter.appliedPoliciesBySandboxID
            )
        )
        #expect(relistSnapshot.generation == 100)
        #expect(relistResult.plan.applyStates.map(\.sandboxID) == ["sandbox-api"])
    }

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

    @Test
    func runnerPersistsAppliedStateAndSkipsDuplicateAfterRestart() async throws {
        let config = sampleControllerConfig()
        let snapshot = try sampleControllerSnapshot(generation: 11)
        let store = InMemoryK8sNetworkPolicyControllerStateStore()

        let firstAdapter = K8sNetworkPolicyFakeAdapter()
        let firstRunner = K8sNetworkPolicyControllerRunner(
            config: config,
            adapter: firstAdapter,
            stateStore: store
        )
        let firstRun = try await firstRunner.runOnce(snapshot: snapshot)
        #expect(firstRun.reconcileResult.plan.applyStates.map(\.sandboxID) == ["sandbox-api"])
        #expect(firstRun.appliedState.appliedPoliciesBySandboxID.keys.sorted() == ["sandbox-api"])

        let secondAdapter = K8sNetworkPolicyFakeAdapter()
        let secondRunner = K8sNetworkPolicyControllerRunner(
            config: config,
            adapter: secondAdapter,
            stateStore: store
        )
        let secondRun = try await secondRunner.runOnce(snapshot: snapshot)
        #expect(secondRun.reconcileResult.plan.isEmpty)
        #expect(secondAdapter.appliedOrder.isEmpty)
        #expect(secondRun.appliedState.appliedPoliciesBySandboxID.keys.sorted() == ["sandbox-api"])
    }

    @Test
    func runnerRemovesPersistedStateWhenEndpointDisappears() async throws {
        let config = sampleControllerConfig()
        let initialSnapshot = try sampleControllerSnapshot(generation: 21)
        let store = InMemoryK8sNetworkPolicyControllerStateStore()

        let initialRunner = K8sNetworkPolicyControllerRunner(
            config: config,
            adapter: K8sNetworkPolicyFakeAdapter(),
            stateStore: store
        )
        let initialRun = try await initialRunner.runOnce(snapshot: initialSnapshot)
        #expect(initialRun.appliedState.appliedPoliciesBySandboxID.keys.sorted() == ["sandbox-api"])

        let deleteSnapshot = try sampleControllerSnapshot(generation: 22, includeAPIPod: false)
        let deleteAdapter = K8sNetworkPolicyFakeAdapter()
        let deleteRunner = K8sNetworkPolicyControllerRunner(
            config: config,
            adapter: deleteAdapter,
            stateStore: store
        )
        let deleteRun = try await deleteRunner.runOnce(snapshot: deleteSnapshot)
        #expect(deleteRun.reconcileResult.plan.removedSandboxIDs == ["sandbox-api"])
        #expect(deleteAdapter.removedSandboxIDs == ["sandbox-api"])
        #expect(deleteRun.appliedState.appliedPoliciesBySandboxID.isEmpty)
        #expect((try store.load()).appliedPoliciesBySandboxID.isEmpty)
    }

    @Test
    func fileStateStoreLoadsMissingAsEmptyAndPersistsState() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-networkpolicy-state-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        defer {
            try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
        }

        let store = FileK8sNetworkPolicyControllerStateStore(url: stateURL)
        #expect(try store.load().appliedPoliciesBySandboxID.isEmpty)

        let runner = K8sNetworkPolicyControllerRunner(
            config: sampleControllerConfig(),
            adapter: K8sNetworkPolicyFakeAdapter(),
            stateStore: store
        )
        let run = try await runner.runOnce(snapshot: try sampleControllerSnapshot(generation: 31))
        #expect(run.appliedState.appliedPoliciesBySandboxID.keys.sorted() == ["sandbox-api"])
        #expect(try store.load() == run.appliedState)
    }

    private func sampleControllerConfig() -> K8sNetworkPolicyControllerConfig {
        K8sNetworkPolicyControllerConfig(
            nodeName: "node-a",
            networkID: "macvmnet"
        )
    }

    private func sampleControllerSnapshot(
        generation: UInt64,
        includeAPIPod: Bool = true
    ) throws -> K8sNetworkPolicyControllerSnapshot {
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
        let frontendCNI = K8sNetworkPolicyCNIEndpointMetadata(
            sandboxID: "sandbox-frontend",
            networkID: "macvmnet",
            nodeName: "node-a",
            ipv4Address: try IPv4Address("10.244.0.10"),
            macAddress: try MACAddress("02:42:ac:11:00:10")
        )
        let apiCNI = K8sNetworkPolicyCNIEndpointMetadata(
            sandboxID: "sandbox-api",
            networkID: "macvmnet",
            nodeName: "node-a",
            ipv4Address: try IPv4Address("10.244.0.20"),
            macAddress: try MACAddress("02:42:ac:11:00:20")
        )
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

        return K8sNetworkPolicyControllerSnapshot(
            generation: generation,
            namespaces: [namespace],
            pods: includeAPIPod ? [frontendPod, apiPod] : [frontendPod],
            cniMetadata: includeAPIPod ? [frontendCNI, apiCNI] : [frontendCNI],
            policies: [policy]
        )
    }
}
