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

import ContainerKit
import ContainerResource
import ContainerizationExtras
import Foundation

public struct K8sNetworkPolicyNamespaceMetadata: Codable, Sendable, Hashable {
    public let name: String
    public let labels: [String: String]

    public init(name: String, labels: [String: String] = [:]) {
        self.name = name
        self.labels = labels
    }
}

public struct K8sNetworkPolicyPodMetadata: Codable, Sendable, Hashable {
    public let namespace: String
    public let name: String
    public let uid: String
    public let nodeName: String
    public let sandboxID: String
    public let labels: [String: String]

    public init(
        namespace: String,
        name: String,
        uid: String,
        nodeName: String,
        sandboxID: String,
        labels: [String: String] = [:]
    ) {
        self.namespace = namespace
        self.name = name
        self.uid = uid
        self.nodeName = nodeName
        self.sandboxID = sandboxID
        self.labels = labels
    }
}

public struct K8sNetworkPolicyCNIEndpointMetadata: Codable, Sendable, Hashable {
    public let sandboxID: String
    public let networkID: String
    public let nodeName: String
    public let ipv4Address: IPv4Address
    public let macAddress: MACAddress?

    public init(
        sandboxID: String,
        networkID: String,
        nodeName: String,
        ipv4Address: IPv4Address,
        macAddress: MACAddress? = nil
    ) {
        self.sandboxID = sandboxID
        self.networkID = networkID
        self.nodeName = nodeName
        self.ipv4Address = ipv4Address
        self.macAddress = macAddress
    }
}

public struct K8sNetworkPolicyEndpointState: Codable, Sendable, Hashable {
    public let pod: K8sNetworkPolicyPodMetadata
    public let namespace: K8sNetworkPolicyNamespaceMetadata?
    public let cni: K8sNetworkPolicyCNIEndpointMetadata?

    public init(
        pod: K8sNetworkPolicyPodMetadata,
        namespace: K8sNetworkPolicyNamespaceMetadata?,
        cni: K8sNetworkPolicyCNIEndpointMetadata?
    ) {
        self.pod = pod
        self.namespace = namespace
        self.cni = cni
    }

    public var readinessIssues: [String] {
        var issues: [String] = []

        if namespace == nil {
            issues.append("missing namespace metadata for \(pod.namespace)/\(pod.name)")
        }
        if cni == nil {
            issues.append("missing CNI metadata for sandbox \(pod.sandboxID)")
        }
        if let cni, cni.nodeName != pod.nodeName {
            issues.append("sandbox \(pod.sandboxID) CNI metadata targets node \(cni.nodeName) instead of \(pod.nodeName)")
        }
        if let cni, cni.sandboxID != pod.sandboxID {
            issues.append("sandbox \(pod.sandboxID) CNI metadata belongs to \(cni.sandboxID)")
        }

        return issues
    }

    public var resolvedEndpoint: K8sNetworkPolicyResolvedEndpoint? {
        guard readinessIssues.isEmpty, let namespace, let cni else {
            return nil
        }

        return K8sNetworkPolicyResolvedEndpoint(
            identity: EndpointIdentity(
                namespace: pod.namespace,
                podName: pod.name,
                podUID: pod.uid,
                nodeName: pod.nodeName,
                sandboxID: pod.sandboxID,
                ipv4Address: cni.ipv4Address,
                labels: pod.labels,
                namespaceLabels: namespace.labels
            ),
            networkID: cni.networkID,
            macAddress: cni.macAddress
        )
    }
}

public struct K8sNetworkPolicyResolvedEndpoint: Codable, Sendable, Hashable {
    public let identity: EndpointIdentity
    public let networkID: String
    public let macAddress: MACAddress?

    public init(identity: EndpointIdentity, networkID: String, macAddress: MACAddress?) {
        self.identity = identity
        self.networkID = networkID
        self.macAddress = macAddress
    }
}

public struct K8sNetworkPolicyStateIndex: Codable, Sendable, Hashable {
    public let namespacesByName: [String: K8sNetworkPolicyNamespaceMetadata]
    public let podsByUID: [String: K8sNetworkPolicyPodMetadata]
    public let cniMetadataBySandboxID: [String: K8sNetworkPolicyCNIEndpointMetadata]
    public let policiesByUID: [String: NetworkPolicyResource]

    public init(
        namespaces: [K8sNetworkPolicyNamespaceMetadata] = [],
        pods: [K8sNetworkPolicyPodMetadata] = [],
        cniMetadata: [K8sNetworkPolicyCNIEndpointMetadata] = [],
        policies: [NetworkPolicyResource] = []
    ) {
        self.namespacesByName = Dictionary(uniqueKeysWithValues: namespaces.map { ($0.name, $0) })
        self.podsByUID = Dictionary(uniqueKeysWithValues: pods.map { ($0.uid, $0) })
        self.cniMetadataBySandboxID = Dictionary(uniqueKeysWithValues: cniMetadata.map { ($0.sandboxID, $0) })
        self.policiesByUID = Dictionary(uniqueKeysWithValues: policies.map { ($0.uid, $0) })
    }

    public var endpointStates: [K8sNetworkPolicyEndpointState] {
        podsByUID.values.sorted(by: Self.podSort).map { pod in
            K8sNetworkPolicyEndpointState(
                pod: pod,
                namespace: namespacesByName[pod.namespace],
                cni: cniMetadataBySandboxID[pod.sandboxID]
            )
        }
    }

    public var readyResolvedEndpoints: [K8sNetworkPolicyResolvedEndpoint] {
        endpointStates.compactMap(\.resolvedEndpoint).sorted(by: Self.resolvedEndpointSort)
    }

    public var readyEndpointIdentities: [EndpointIdentity] {
        readyResolvedEndpoints.map(\.identity)
    }

    public var unresolvedEndpointStates: [K8sNetworkPolicyEndpointState] {
        endpointStates.filter { !$0.readinessIssues.isEmpty }
    }

    private static func podSort(_ lhs: K8sNetworkPolicyPodMetadata, _ rhs: K8sNetworkPolicyPodMetadata) -> Bool {
        if lhs.namespace != rhs.namespace {
            return lhs.namespace < rhs.namespace
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.uid < rhs.uid
    }

    private static func resolvedEndpointSort(
        _ lhs: K8sNetworkPolicyResolvedEndpoint,
        _ rhs: K8sNetworkPolicyResolvedEndpoint
    ) -> Bool {
        if lhs.identity.namespace != rhs.identity.namespace {
            return lhs.identity.namespace < rhs.identity.namespace
        }
        if lhs.identity.podName != rhs.identity.podName {
            return lhs.identity.podName < rhs.identity.podName
        }
        return lhs.identity.podUID < rhs.identity.podUID
    }
}

public struct K8sNetworkPolicyControllerSnapshot: Codable, Sendable, Hashable {
    public let generation: UInt64
    public let namespaces: [K8sNetworkPolicyNamespaceMetadata]
    public let pods: [K8sNetworkPolicyPodMetadata]
    public let cniMetadata: [K8sNetworkPolicyCNIEndpointMetadata]
    public let policies: [NetworkPolicyResource]

    public init(
        generation: UInt64,
        namespaces: [K8sNetworkPolicyNamespaceMetadata] = [],
        pods: [K8sNetworkPolicyPodMetadata] = [],
        cniMetadata: [K8sNetworkPolicyCNIEndpointMetadata] = [],
        policies: [NetworkPolicyResource] = []
    ) {
        self.generation = generation
        self.namespaces = namespaces
        self.pods = pods
        self.cniMetadata = cniMetadata
        self.policies = policies
    }
}

public struct K8sNetworkPolicyControllerState: Codable, Sendable, Equatable {
    public let appliedPoliciesBySandboxID: [String: SandboxNetworkPolicyState]

    public init(appliedPoliciesBySandboxID: [String: SandboxNetworkPolicyState] = [:]) {
        self.appliedPoliciesBySandboxID = appliedPoliciesBySandboxID
    }
}

public enum K8sNetworkPolicyPlanOperation: Codable, Sendable, Equatable {
    case apply(SandboxNetworkPolicyState)
    case remove(sandboxID: String)
}

public struct K8sNetworkPolicyReconcilePlan: Codable, Sendable, Equatable {
    public let generation: UInt64
    public let compiledPolicySet: CompiledNetworkPolicySet
    public let operations: [K8sNetworkPolicyPlanOperation]

    public init(
        generation: UInt64,
        compiledPolicySet: CompiledNetworkPolicySet,
        operations: [K8sNetworkPolicyPlanOperation]
    ) {
        self.generation = generation
        self.compiledPolicySet = compiledPolicySet
        self.operations = operations
    }

    public var applyStates: [SandboxNetworkPolicyState] {
        operations.compactMap {
            guard case .apply(let state) = $0 else {
                return nil
            }
            return state
        }
    }

    public var removedSandboxIDs: [String] {
        operations.compactMap {
            guard case .remove(let sandboxID) = $0 else {
                return nil
            }
            return sandboxID
        }
    }

    public var isEmpty: Bool {
        operations.isEmpty
    }
}

public struct K8sNetworkPolicyReconcileResult: Codable, Sendable, Equatable {
    public let plan: K8sNetworkPolicyReconcilePlan
    public let nextState: K8sNetworkPolicyControllerState

    public init(plan: K8sNetworkPolicyReconcilePlan, nextState: K8sNetworkPolicyControllerState) {
        self.plan = plan
        self.nextState = nextState
    }
}

public protocol K8sNetworkPolicyAdapter: Sendable {
    func apply(_ state: SandboxNetworkPolicyState) async throws -> SandboxNetworkPolicyState
    func remove(sandboxID: String) async throws
    func inspect(sandboxID: String) async throws -> SandboxNetworkPolicyState?
}

extension K8sNetworkPolicyAdapter {
    @discardableResult
    public func execute(
        _ plan: K8sNetworkPolicyReconcilePlan,
        currentState: K8sNetworkPolicyControllerState = .init()
    ) async throws -> K8sNetworkPolicyControllerState {
        var appliedPoliciesBySandboxID = currentState.appliedPoliciesBySandboxID
        for operation in plan.operations {
            switch operation {
            case .apply(let state):
                let applied = try await apply(state)
                appliedPoliciesBySandboxID[applied.sandboxID] = applied
            case .remove(let sandboxID):
                try await remove(sandboxID: sandboxID)
                appliedPoliciesBySandboxID.removeValue(forKey: sandboxID)
            }
        }
        return K8sNetworkPolicyControllerState(appliedPoliciesBySandboxID: appliedPoliciesBySandboxID)
    }
}

public struct ContainerKitK8sNetworkPolicyAdapter: K8sNetworkPolicyAdapter {
    public var kit: ContainerKit

    public init(kit: ContainerKit = ContainerKit()) {
        self.kit = kit
    }

    public func apply(_ state: SandboxNetworkPolicyState) async throws -> SandboxNetworkPolicyState {
        try await kit.applySandboxPolicy(state.policy)
    }

    public func remove(sandboxID: String) async throws {
        try await kit.removeSandboxPolicy(sandboxID: sandboxID)
    }

    public func inspect(sandboxID: String) async throws -> SandboxNetworkPolicyState? {
        try await kit.inspectSandboxPolicy(sandboxID: sandboxID)
    }
}

public final class K8sNetworkPolicyFakeAdapter: K8sNetworkPolicyAdapter, @unchecked Sendable {
    public private(set) var appliedPoliciesBySandboxID: [String: SandboxNetworkPolicyState]
    public private(set) var appliedOrder: [String]
    public private(set) var removedSandboxIDs: [String]

    public init(appliedPoliciesBySandboxID: [String: SandboxNetworkPolicyState] = [:]) {
        self.appliedPoliciesBySandboxID = appliedPoliciesBySandboxID
        self.appliedOrder = []
        self.removedSandboxIDs = []
    }

    public func apply(_ state: SandboxNetworkPolicyState) async throws -> SandboxNetworkPolicyState {
        appliedPoliciesBySandboxID[state.sandboxID] = state
        appliedOrder.append(state.sandboxID)
        return state
    }

    public func remove(sandboxID: String) async throws {
        appliedPoliciesBySandboxID.removeValue(forKey: sandboxID)
        removedSandboxIDs.append(sandboxID)
    }

    public func inspect(sandboxID: String) async throws -> SandboxNetworkPolicyState? {
        appliedPoliciesBySandboxID[sandboxID]
    }

    @discardableResult
    public func execute(
        _ plan: K8sNetworkPolicyReconcilePlan,
        currentState: K8sNetworkPolicyControllerState = .init()
    ) async throws -> K8sNetworkPolicyControllerState {
        if !currentState.appliedPoliciesBySandboxID.isEmpty {
            appliedPoliciesBySandboxID = currentState.appliedPoliciesBySandboxID
        }
        for operation in plan.operations {
            switch operation {
            case .apply(let state):
                _ = try await apply(state)
            case .remove(let sandboxID):
                try await remove(sandboxID: sandboxID)
            }
        }
        return K8sNetworkPolicyControllerState(appliedPoliciesBySandboxID: appliedPoliciesBySandboxID)
    }
}

public enum K8sNetworkPolicyController {
    public static func reconcile(
        config: K8sNetworkPolicyControllerConfig,
        snapshot: K8sNetworkPolicyControllerSnapshot,
        currentState: K8sNetworkPolicyControllerState = .init()
    ) throws -> K8sNetworkPolicyReconcileResult {
        let index = K8sNetworkPolicyStateIndex(
            namespaces: snapshot.namespaces,
            pods: snapshot.pods,
            cniMetadata: snapshot.cniMetadata,
            policies: snapshot.policies
        )

        let compilationInput = PolicyCompilationInput(
            generation: snapshot.generation,
            nodeName: config.nodeName,
            endpoints: index.readyEndpointIdentities,
            policies: snapshot.policies,
            requiredEgressAllows: config.requiredEgressAllows
        )
        let compiled = try NetworkPolicyCompiler.compile(compilationInput)
        let desiredStates = try desiredStates(
            compiled: compiled,
            index: index,
            networkID: config.networkID
        )
        let plan = reconcilePlan(
            generation: compiled.generation,
            compiled: compiled,
            desiredStates: desiredStates,
            currentState: currentState
        )
        let nextState = K8sNetworkPolicyControllerState(appliedPoliciesBySandboxID: desiredStates)
        return K8sNetworkPolicyReconcileResult(plan: plan, nextState: nextState)
    }

    public static func desiredStates(
        compiled: CompiledNetworkPolicySet,
        index: K8sNetworkPolicyStateIndex,
        networkID: String
    ) throws -> [String: SandboxNetworkPolicyState] {
        var states: [String: SandboxNetworkPolicyState] = [:]
        states.reserveCapacity(compiled.endpointPolicies.count)

        for policy in compiled.endpointPolicies {
            guard policy.requiresApply else {
                continue
            }
            guard let resolved = index.readyResolvedEndpoints.first(where: { $0.identity.sandboxID == policy.endpoint.sandboxID }) else {
                continue
            }
            let sandboxPolicy = try policy.renderedSandboxPolicy()
            states[policy.endpoint.sandboxID] = SandboxNetworkPolicyState(
                sandboxID: policy.endpoint.sandboxID,
                networkID: resolved.networkID.isEmpty ? networkID : resolved.networkID,
                ipv4Address: try IPAddress(policy.endpoint.ipv4Address.description),
                macAddress: resolved.macAddress,
                generation: policy.generation,
                policy: sandboxPolicy,
                renderedHostRuleIdentifiers: sandboxPolicy.rules.map(\.id),
                lastApplyResult: .stored
            )
        }

        return states
    }

    public static func reconcilePlan(
        generation: UInt64,
        compiled: CompiledNetworkPolicySet,
        desiredStates: [String: SandboxNetworkPolicyState],
        currentState: K8sNetworkPolicyControllerState
    ) -> K8sNetworkPolicyReconcilePlan {
        var operations: [K8sNetworkPolicyPlanOperation] = []

        for sandboxID in currentState.appliedPoliciesBySandboxID.keys.sorted() where desiredStates[sandboxID] == nil {
            operations.append(.remove(sandboxID: sandboxID))
        }

        for sandboxID in desiredStates.keys.sorted() {
            guard let desired = desiredStates[sandboxID] else {
                continue
            }
            if currentState.appliedPoliciesBySandboxID[sandboxID] != desired {
                operations.append(.apply(desired))
            }
        }

        return K8sNetworkPolicyReconcilePlan(
            generation: generation,
            compiledPolicySet: compiled,
            operations: operations
        )
    }
}
