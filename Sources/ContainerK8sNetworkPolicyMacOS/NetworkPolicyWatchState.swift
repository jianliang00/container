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

public enum K8sNetworkPolicyWatchEvent: Codable, Sendable, Hashable {
    case upsertNamespace(K8sNetworkPolicyNamespaceMetadata)
    case deleteNamespace(name: String)
    case upsertPod(K8sNetworkPolicyPodMetadata)
    case deletePod(uid: String)
    case upsertCNIEndpoint(K8sNetworkPolicyCNIEndpointMetadata)
    case deleteCNIEndpoint(sandboxID: String)
    case upsertNetworkPolicy(NetworkPolicyResource)
    case deleteNetworkPolicy(uid: String)
}

public struct K8sNetworkPolicyWatchState: Codable, Sendable, Hashable {
    public private(set) var generation: UInt64
    public private(set) var namespacesByName: [String: K8sNetworkPolicyNamespaceMetadata]
    public private(set) var podsByUID: [String: K8sNetworkPolicyPodMetadata]
    public private(set) var cniMetadataBySandboxID: [String: K8sNetworkPolicyCNIEndpointMetadata]
    public private(set) var policiesByUID: [String: NetworkPolicyResource]

    public init(
        generation: UInt64 = 0,
        namespaces: [K8sNetworkPolicyNamespaceMetadata] = [],
        pods: [K8sNetworkPolicyPodMetadata] = [],
        cniMetadata: [K8sNetworkPolicyCNIEndpointMetadata] = [],
        policies: [NetworkPolicyResource] = []
    ) {
        self.generation = generation
        self.namespacesByName = Dictionary(uniqueKeysWithValues: namespaces.map { ($0.name, $0) })
        self.podsByUID = Dictionary(uniqueKeysWithValues: pods.map { ($0.uid, $0) })
        self.cniMetadataBySandboxID = Dictionary(uniqueKeysWithValues: cniMetadata.map { ($0.sandboxID, $0) })
        self.policiesByUID = Dictionary(uniqueKeysWithValues: policies.map { ($0.uid, $0) })
    }

    public init(snapshot: K8sNetworkPolicyControllerSnapshot) {
        self.init(
            generation: snapshot.generation,
            namespaces: snapshot.namespaces,
            pods: snapshot.pods,
            cniMetadata: snapshot.cniMetadata,
            policies: snapshot.policies
        )
    }

    public var snapshot: K8sNetworkPolicyControllerSnapshot {
        K8sNetworkPolicyControllerSnapshot(
            generation: generation,
            namespaces: namespacesByName.values.sorted(by: namespaceSort),
            pods: podsByUID.values.sorted(by: podSort),
            cniMetadata: cniMetadataBySandboxID.values.sorted(by: cniMetadataSort),
            policies: policiesByUID.values.sorted(by: networkPolicySort)
        )
    }

    @discardableResult
    public mutating func replace(with snapshot: K8sNetworkPolicyControllerSnapshot) -> K8sNetworkPolicyControllerSnapshot {
        self = K8sNetworkPolicyWatchState(snapshot: snapshot)
        return self.snapshot
    }

    @discardableResult
    public mutating func apply(_ event: K8sNetworkPolicyWatchEvent) -> K8sNetworkPolicyControllerSnapshot {
        if applyMutation(event) {
            generation += 1
        }
        return snapshot
    }

    private mutating func applyMutation(_ event: K8sNetworkPolicyWatchEvent) -> Bool {
        switch event {
        case .upsertNamespace(let namespace):
            return upsert(namespace, keyedBy: \.name, into: &namespacesByName)
        case .deleteNamespace(let name):
            return namespacesByName.removeValue(forKey: name) != nil
        case .upsertPod(let pod):
            return upsert(pod, keyedBy: \.uid, into: &podsByUID)
        case .deletePod(let uid):
            return podsByUID.removeValue(forKey: uid) != nil
        case .upsertCNIEndpoint(let endpoint):
            return upsert(endpoint, keyedBy: \.sandboxID, into: &cniMetadataBySandboxID)
        case .deleteCNIEndpoint(let sandboxID):
            return cniMetadataBySandboxID.removeValue(forKey: sandboxID) != nil
        case .upsertNetworkPolicy(let policy):
            return upsert(policy, keyedBy: \.uid, into: &policiesByUID)
        case .deleteNetworkPolicy(let uid):
            return policiesByUID.removeValue(forKey: uid) != nil
        }
    }
}

private func upsert<Value: Equatable>(
    _ value: Value,
    keyedBy keyPath: KeyPath<Value, String>,
    into dictionary: inout [String: Value]
) -> Bool {
    let key = value[keyPath: keyPath]
    if dictionary[key] == value {
        return false
    }
    dictionary[key] = value
    return true
}

private func namespaceSort(
    _ lhs: K8sNetworkPolicyNamespaceMetadata,
    _ rhs: K8sNetworkPolicyNamespaceMetadata
) -> Bool {
    lhs.name < rhs.name
}

private func podSort(_ lhs: K8sNetworkPolicyPodMetadata, _ rhs: K8sNetworkPolicyPodMetadata) -> Bool {
    if lhs.namespace != rhs.namespace {
        return lhs.namespace < rhs.namespace
    }
    if lhs.name != rhs.name {
        return lhs.name < rhs.name
    }
    return lhs.uid < rhs.uid
}

private func cniMetadataSort(
    _ lhs: K8sNetworkPolicyCNIEndpointMetadata,
    _ rhs: K8sNetworkPolicyCNIEndpointMetadata
) -> Bool {
    lhs.sandboxID < rhs.sandboxID
}

private func networkPolicySort(_ lhs: NetworkPolicyResource, _ rhs: NetworkPolicyResource) -> Bool {
    if lhs.namespace != rhs.namespace {
        return lhs.namespace < rhs.namespace
    }
    if lhs.name != rhs.name {
        return lhs.name < rhs.name
    }
    return lhs.uid < rhs.uid
}
