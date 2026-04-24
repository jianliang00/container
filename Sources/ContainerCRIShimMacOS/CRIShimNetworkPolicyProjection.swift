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

import ContainerK8sNetworkPolicyMacOS
import ContainerKit
import ContainerResource
import Foundation

public enum CRIShimNetworkPolicyProjection {
    @discardableResult
    public static func applyCRIState(
        metadataSnapshot: CRIShimMetadataSnapshot,
        sandboxSnapshotsByID: [String: SandboxSnapshot],
        nodeName: String,
        to watchState: inout K8sNetworkPolicyWatchState
    ) throws -> K8sNetworkPolicyControllerSnapshot {
        let nodeName = try requiredTrimmed(nodeName, field: "networkPolicy.nodeName")
        let activeSandboxes = metadataSnapshot.sandboxes
            .filter { isActiveSandbox($0) }
            .sorted { $0.id < $1.id }

        let activeSandboxIDs = Set(activeSandboxes.map(\.id))
        for existingEndpoint in watchState.cniMetadataBySandboxID.values
        where existingEndpoint.nodeName == nodeName && !activeSandboxIDs.contains(existingEndpoint.sandboxID) {
            watchState.apply(.deleteCNIEndpoint(sandboxID: existingEndpoint.sandboxID))
        }

        for sandbox in activeSandboxes {
            if let pod = makePodMetadata(sandbox: sandbox, nodeName: nodeName) {
                watchState.apply(.upsertPod(pod))
            }

            if let endpoint = try makeCNIEndpointMetadata(
                sandbox: sandbox,
                sandboxSnapshot: sandboxSnapshotsByID[sandbox.id],
                nodeName: nodeName
            ) {
                watchState.apply(.upsertCNIEndpoint(endpoint))
            } else {
                watchState.apply(.deleteCNIEndpoint(sandboxID: sandbox.id))
            }
        }

        return watchState.snapshot
    }

    public static func makePodMetadata(
        sandbox: CRIShimSandboxMetadata,
        nodeName: String
    ) -> K8sNetworkPolicyPodMetadata? {
        guard
            let namespace = optionalTrimmed(sandbox.namespace),
            let name = optionalTrimmed(sandbox.name),
            let uid = optionalTrimmed(sandbox.podUID),
            let nodeName = optionalTrimmed(nodeName)
        else {
            return nil
        }

        return K8sNetworkPolicyPodMetadata(
            namespace: namespace,
            name: name,
            uid: uid,
            nodeName: nodeName,
            sandboxID: sandbox.id,
            labels: sandbox.labels
        )
    }

    public static func makeCNIEndpointMetadata(
        sandbox: CRIShimSandboxMetadata,
        sandboxSnapshot: SandboxSnapshot?,
        nodeName: String
    ) throws -> K8sNetworkPolicyCNIEndpointMetadata? {
        guard
            let attachment = preferredAttachment(
                forNetwork: optionalTrimmed(sandbox.network),
                in: sandboxSnapshot
            )
        else {
            return nil
        }

        return K8sNetworkPolicyCNIEndpointMetadata(
            sandboxID: sandbox.id,
            networkID: attachment.network,
            nodeName: try requiredTrimmed(nodeName, field: "networkPolicy.nodeName"),
            ipv4Address: try ContainerK8sNetworkPolicyMacOS.IPv4Address(attachment.ipv4Address.address.description),
            macAddress: attachment.macAddress
        )
    }

    private static func preferredAttachment(
        forNetwork network: String?,
        in sandboxSnapshot: SandboxSnapshot?
    ) -> ContainerResource.Attachment? {
        guard let sandboxSnapshot else {
            return nil
        }
        if let network, let attachment = sandboxSnapshot.networks.first(where: { $0.network == network }) {
            return attachment
        }
        return sandboxSnapshot.networks.first
    }

    private static func isActiveSandbox(_ sandbox: CRIShimSandboxMetadata) -> Bool {
        switch sandbox.state {
        case .pending, .ready, .running:
            return true
        case .stopped, .released:
            return false
        }
    }

    private static func optionalTrimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func requiredTrimmed(_ value: String, field: String) throws -> String {
        guard let trimmed = optionalTrimmed(value) else {
            throw CRIShimError.invalidArgument("\(field) is required")
        }
        return trimmed
    }
}
