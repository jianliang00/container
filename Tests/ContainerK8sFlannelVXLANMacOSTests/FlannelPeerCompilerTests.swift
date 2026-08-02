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
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelPeerCompilerTests {
    @Test
    func compilesLinuxAndWindowsPeersUsingDynamicAnnotationPrefix() throws {
        let prefix = "network.example.com/flannel"
        let nodes = [
            makeNode(
                name: "mac-a",
                podCIDRs: ["fd00::/64", "10.250.25.0/24"],
                internalIP: "192.0.2.9",
                operatingSystem: "darwin"
            ),
            try makeManagedNode(
                name: "linux-a",
                podCIDR: "10.250.2.0/24",
                publicIP: "198.18.55.20",
                vtepMAC: "02:11:22:33:44:55",
                operatingSystem: "linux",
                prefix: prefix
            ),
            try makeManagedNode(
                name: "windows-a",
                podCIDR: "10.250.8.0/24",
                publicIP: "198.51.100.140",
                vtepMAC: "0E-2A-AA-BB-CC-DD",
                operatingSystem: "windows",
                prefix: prefix
            ),
        ]

        let result = try FlannelPeerCompiler.compile(
            nodes: nodes,
            localNodeName: "mac-a",
            networkConfig: makeNetworkConfig(),
            annotationPrefix: prefix
        )

        #expect(result.issues.isEmpty)
        #expect(result.localNetwork?.podCIDR == "10.250.25.0/24")
        #expect(result.localNetwork?.subnetBase == "10.250.25.0")
        #expect(result.localNetwork?.internalIP == "192.0.2.9")
        #expect(result.peers.map(\.nodeName) == ["linux-a", "windows-a"])
        #expect(result.peers[0].vtepMAC == "02:11:22:33:44:55")
        #expect(result.peers[1].vtepMAC == "0e:2a:aa:bb:cc:dd")
        #expect(result.peers[1].operatingSystem == "windows")
    }

    @Test
    func treatsWindowsEmptyVTEPMACAsPending() throws {
        let nodes = [
            makeNode(name: "mac-a", podCIDRs: ["10.250.25.0/24"]),
            try makeManagedNode(
                name: "windows-a",
                podCIDR: "10.250.8.0/24",
                publicIP: "198.51.100.140",
                vtepMAC: "",
                operatingSystem: "windows"
            ),
        ]

        let result = try FlannelPeerCompiler.compile(
            nodes: nodes,
            localNodeName: "mac-a",
            networkConfig: makeNetworkConfig()
        )

        #expect(result.peers.isEmpty)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.severity == .pending)
        #expect(result.issues.first?.id == "node/windows-a/vtep-mac")
    }

    @Test
    func ignoresNodesNotManagedByFlannel() throws {
        let result = try FlannelPeerCompiler.compile(
            nodes: [
                makeNode(name: "mac-a", podCIDRs: ["10.250.25.0/24"]),
                makeNode(name: "unmanaged-mac", podCIDRs: ["10.250.24.0/24"]),
            ],
            localNodeName: "mac-a",
            networkConfig: makeNetworkConfig()
        )

        #expect(result.peers.isEmpty)
        #expect(result.issues.isEmpty)
    }

    @Test
    func rejectsVNIAndPodCIDRConflicts() throws {
        let nodes = [
            makeNode(name: "mac-a", podCIDRs: ["10.250.25.0/24"]),
            try makeManagedNode(
                name: "wrong-vni",
                podCIDR: "10.250.4.0/24",
                publicIP: "198.18.55.4",
                vtepMAC: "02:00:00:00:00:04",
                vni: 4097
            ),
            try makeManagedNode(
                name: "overlap-a",
                podCIDR: "10.250.6.0/24",
                publicIP: "198.18.55.6",
                vtepMAC: "02:00:00:00:00:06"
            ),
            try makeManagedNode(
                name: "overlap-b",
                podCIDR: "10.250.6.128/25",
                publicIP: "198.18.55.7",
                vtepMAC: "02:00:00:00:00:07"
            ),
        ]

        let result = try FlannelPeerCompiler.compile(
            nodes: nodes,
            localNodeName: "mac-a",
            networkConfig: makeNetworkConfig()
        )

        #expect(result.peers.isEmpty)
        #expect(result.issues.contains { $0.id == "node/wrong-vni/vni" && $0.severity == .error })
        #expect(result.issues.contains { $0.id.contains("pod-cidr-overlap") && $0.severity == .error })
    }

    @Test
    func decodesNodeAPIShapeUsedByCompiler() throws {
        let data = Data(
            #"{"items":[{"metadata":{"name":"linux-a","labels":{"kubernetes.io/os":"linux"},"annotations":{"flannel.alpha.coreos.com/kube-subnet-manager":"true"}},"spec":{"podCIDR":"10.250.2.0/24","podCIDRs":["10.250.2.0/24","fd00:2::/64"]},"status":{"addresses":[{"type":"InternalIP","address":"198.18.55.20"}],"conditions":[{"type":"Ready","status":"True"}]}}]}"#
                .utf8
        )

        let list = try JSONDecoder().decode(FlannelNodeList.self, from: data)

        #expect(list.items.first?.metadata.name == "linux-a")
        #expect(list.items.first?.status?.internalIPv4 == "198.18.55.20")
        #expect(list.items.first?.status?.isReady == true)
    }
}

private func makeNetworkConfig() -> FlannelNetworkConfig {
    FlannelNetworkConfig(
        network: "10.250.0.0/16",
        backend: FlannelVXLANBackendConfig(vni: 4096, port: 4789)
    )
}

private func makeNode(
    name: String,
    podCIDRs: [String],
    annotations: [String: String]? = nil,
    internalIP: String? = nil,
    operatingSystem: String? = nil
) -> FlannelNode {
    FlannelNode(
        metadata: FlannelObjectMeta(
            name: name,
            labels: operatingSystem.map { ["kubernetes.io/os": $0] },
            annotations: annotations
        ),
        spec: FlannelNodeSpec(podCIDR: podCIDRs.first, podCIDRs: podCIDRs),
        status: internalIP.map { FlannelNodeStatus(addresses: [FlannelNodeAddress(type: "InternalIP", address: $0)]) }
    )
}

private func makeManagedNode(
    name: String,
    podCIDR: String,
    publicIP: String,
    vtepMAC: String,
    vni: Int = 4096,
    operatingSystem: String? = nil,
    prefix: String = "flannel.alpha.coreos.com"
) throws -> FlannelNode {
    let keys = try FlannelAnnotationKeys(prefix: prefix)
    let backendData = try JSONEncoder().encode(FlannelBackendLeaseData(vni: vni, vtepMAC: vtepMAC))
    return makeNode(
        name: name,
        podCIDRs: [podCIDR],
        annotations: [
            keys.kubeSubnetManager: "true",
            keys.backendType: "vxlan",
            keys.publicIP: publicIP,
            keys.backendData: String(decoding: backendData, as: UTF8.self),
        ],
        operatingSystem: operatingSystem
    )
}
