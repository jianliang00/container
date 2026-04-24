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
import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimNetworkPolicyProjectionTests {
    @Test
    func projectsActiveCRISandboxAndCNIStateIntoEndpointIndex() throws {
        let sandbox = makeSandboxMetadata(state: .ready)
        let snapshot = try makeSandboxSnapshot(
            network: "default",
            address: "192.168.64.10/24",
            gateway: "192.168.64.1"
        )
        var watchState = K8sNetworkPolicyWatchState(
            namespaces: [
                K8sNetworkPolicyNamespaceMetadata(name: "app")
            ])

        let projected = try CRIShimNetworkPolicyProjection.applyCRIState(
            metadataSnapshot: CRIShimMetadataSnapshot(sandboxes: [sandbox]),
            sandboxSnapshotsByID: ["sandbox-api": snapshot],
            nodeName: "node-a",
            to: &watchState
        )

        let pod = try #require(projected.pods.first)
        #expect(pod.namespace == "app")
        #expect(pod.name == "api")
        #expect(pod.uid == "pod-api")
        #expect(pod.nodeName == "node-a")
        #expect(pod.sandboxID == "sandbox-api")
        #expect(pod.labels == ["role": "api"])

        let endpoint = try #require(projected.cniMetadata.first)
        #expect(endpoint.sandboxID == "sandbox-api")
        #expect(endpoint.networkID == "default")
        #expect(endpoint.nodeName == "node-a")
        #expect(endpoint.ipv4Address.description == "192.168.64.10")
    }

    @Test
    func deletesStaleLocalCNIEndpointWhenSandboxIsNoLongerActive() throws {
        let staleEndpoint = K8sNetworkPolicyCNIEndpointMetadata(
            sandboxID: "sandbox-api",
            networkID: "default",
            nodeName: "node-a",
            ipv4Address: try ContainerK8sNetworkPolicyMacOS.IPv4Address("192.168.64.10")
        )
        var watchState = K8sNetworkPolicyWatchState(cniMetadata: [staleEndpoint])

        let projected = try CRIShimNetworkPolicyProjection.applyCRIState(
            metadataSnapshot: CRIShimMetadataSnapshot(sandboxes: [makeSandboxMetadata(state: .stopped)]),
            sandboxSnapshotsByID: [:],
            nodeName: "node-a",
            to: &watchState
        )

        #expect(projected.cniMetadata.isEmpty)
    }

    @Test
    func leavesEndpointUnresolvedUntilCNIStateArrives() throws {
        let sandbox = makeSandboxMetadata(state: .pending)
        var watchState = K8sNetworkPolicyWatchState()

        let projected = try CRIShimNetworkPolicyProjection.applyCRIState(
            metadataSnapshot: CRIShimMetadataSnapshot(sandboxes: [sandbox]),
            sandboxSnapshotsByID: [:],
            nodeName: "node-a",
            to: &watchState
        )

        #expect(projected.pods.map(\.uid) == ["pod-api"])
        #expect(projected.cniMetadata.isEmpty)
    }
}

private func makeSandboxMetadata(state: CRIShimSandboxMetadata.State) -> CRIShimSandboxMetadata {
    CRIShimSandboxMetadata(
        id: "sandbox-api",
        podUID: "pod-api",
        namespace: "app",
        name: "api",
        runtimeHandler: "macos",
        sandboxImage: "example.com/macos/sandbox:latest",
        network: "default",
        labels: ["role": "api"],
        state: state,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeSandboxSnapshot(
    network: String,
    address: String,
    gateway: String
) throws -> SandboxSnapshot {
    SandboxSnapshot(
        status: .running,
        networks: [
            Attachment(
                network: network,
                hostname: "api",
                ipv4Address: try CIDRv4(address),
                ipv4Gateway: try ContainerizationExtras.IPv4Address(gateway),
                ipv6Address: nil,
                macAddress: try MACAddress("02:42:ac:11:00:20")
            )
        ],
        containers: []
    )
}
