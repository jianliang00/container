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

    @Test
    func compilesIPv6LocalNetworkAndLinuxPeerIndependentlyFromIPv4() throws {
        let nodes = [
            makeNode(
                name: "mac-a",
                podCIDRs: ["fd42:10:244:25::9/64", "10.250.25.0/24"],
                internalIP: "192.0.2.9",
                internalIPv6: "FD31::9",
                operatingSystem: "darwin"
            ),
            try makeDualStackManagedNode(
                name: "linux-a",
                podCIDRs: ["10.250.2.0/24", "fd42:10:244:2::7/64"],
                publicIP: "198.18.55.20",
                publicIPv6: "FD31::20",
                vtepMAC: "02:11:22:33:44:55",
                vtepMACIPv6: "02:11:22:33:44:66",
                operatingSystem: "linux"
            ),
            try makeDualStackManagedNode(
                name: "windows-a",
                podCIDRs: ["10.250.8.0/24", "fd42:10:244:8::/64"],
                publicIP: "198.51.100.140",
                publicIPv6: "fd31::140",
                vtepMAC: "0e:2a:aa:bb:cc:dd",
                vtepMACIPv6: "0e:2a:aa:bb:cc:ee",
                operatingSystem: "windows"
            ),
        ]

        let result = try FlannelPeerCompiler.compile(
            nodes: nodes,
            localNodeName: "mac-a",
            networkConfig: makeDualStackNetworkConfig()
        )

        #expect(result.localNetwork?.podCIDR == "10.250.25.0/24")
        #expect(result.peers.map(\.nodeName) == ["linux-a", "windows-a"])
        #expect(result.localIPv6Network?.podCIDR == "fd42:10:244:25::/64")
        #expect(result.localIPv6Network?.subnetBase == "fd42:10:244:25::")
        #expect(result.localIPv6Network?.internalIPv6 == "fd31::9")
        #expect(result.ipv6Peers.map(\.nodeName) == ["linux-a"])
        #expect(result.ipv6Peers.first?.podCIDR == "fd42:10:244:2::/64")
        #expect(result.ipv6Peers.first?.publicIPv6 == "fd31::20")
        #expect(result.ipv6Peers.first?.vtepMAC == "02:11:22:33:44:66")
        #expect(
            result.issues.contains {
                $0.id == "node/windows-a/ipv6-unsupported" && $0.severity == .warning
            }
        )
    }

    @Test
    func missingIPv6AnnotationsFailClosedWithoutDiscardingIPv4Peer() throws {
        var remote = try makeManagedNode(
            name: "linux-a",
            podCIDR: "10.250.2.0/24",
            publicIP: "198.18.55.20",
            vtepMAC: "02:11:22:33:44:55",
            operatingSystem: "linux"
        )
        remote.spec.podCIDRs = ["10.250.2.0/24", "fd42:10:244:2::/64"]
        let result = try FlannelPeerCompiler.compile(
            nodes: [
                makeNode(name: "mac-a", podCIDRs: ["10.250.25.0/24", "fd42:10:244:25::/64"]),
                remote,
            ],
            localNodeName: "mac-a",
            networkConfig: makeDualStackNetworkConfig()
        )

        #expect(result.peers.map(\.nodeName) == ["linux-a"])
        #expect(result.ipv6Peers.isEmpty)
        #expect(
            result.issues.contains {
                $0.id == "node/linux-a/public-ipv6" && $0.severity == .error
            }
        )

        let keys = try FlannelAnnotationKeys(prefix: "flannel.alpha.coreos.com")
        remote.metadata.annotations?[keys.publicIPv6] = "fd31::20"
        let missingBackend = try FlannelPeerCompiler.compile(
            nodes: [
                makeNode(name: "mac-a", podCIDRs: ["10.250.25.0/24", "fd42:10:244:25::/64"]),
                remote,
            ],
            localNodeName: "mac-a",
            networkConfig: makeDualStackNetworkConfig()
        )
        #expect(missingBackend.ipv6Peers.isEmpty)
        #expect(
            missingBackend.issues.contains {
                $0.id == "node/linux-a/backend-v6-data" && $0.severity == .pending
            }
        )
    }

    @Test
    func rejectsInvalidIPv6CIDRTopologyAndMissingClusterNetwork() throws {
        let outside = try makeDualStackManagedNode(
            name: "outside",
            podCIDRs: ["10.250.2.0/24", "fd01::/64"],
            publicIP: "198.18.55.20",
            publicIPv6: "fd31::20",
            vtepMAC: "02:11:22:33:44:55",
            vtepMACIPv6: "02:11:22:33:44:66"
        )
        let result = try FlannelPeerCompiler.compile(
            nodes: [
                makeNode(name: "mac-a", podCIDRs: ["10.250.25.0/24", "fd42:10:244:25::/64"]),
                outside,
            ],
            localNodeName: "mac-a",
            networkConfig: makeDualStackNetworkConfig()
        )

        #expect(result.ipv6Peers.isEmpty)
        #expect(result.issues.contains { $0.id == "node/outside/ipv6-pod-cidr" })

        #expect(
            throws: FlannelVXLANError.invalidNetworkConfig(
                "IPv6Network must be a valid IPv6 CIDR when EnableIPv6 is true"
            )
        ) {
            try FlannelPeerCompiler.compile(
                nodes: [],
                localNodeName: "mac-a",
                networkConfig: FlannelNetworkConfig(
                    network: "10.250.0.0/16",
                    enableIPv6: true,
                    backend: FlannelVXLANBackendConfig(vni: 4096, port: 4789)
                )
            )
        }
    }

    @Test
    func canonicalizesAndComparesNonOctetIPv6Prefixes() throws {
        let cluster = try #require(FlannelIPv6.parseCIDR("fd42:10:244:127f::1/57"))
        let inside = try #require(FlannelIPv6.parseCIDR("fd42:10:244:1266::9/64"))
        let outside = try #require(FlannelIPv6.parseCIDR("fd42:10:244:1280::/57"))

        #expect(cluster.string == "fd42:10:244:1200::/57")
        #expect(cluster.contains(inside))
        #expect(!cluster.contains(outside))
        #expect(!cluster.overlaps(outside))
        #expect(FlannelIPv6.parseAddress("fe80::1")?.isUsableUnderlayAddress == false)
        #expect(FlannelIPv6.parseAddress("::1")?.isUsableUnderlayAddress == false)
        #expect(FlannelIPv6.parseAddress("::ffff:192.0.2.9")?.isUsableUnderlayAddress == false)
        #expect(FlannelIPv6.parseAddress("fd31::1")?.isUsableUnderlayAddress == true)
    }

    @Test
    func rejectsIPv6VNIAndRemoteCIDROverlaps() throws {
        let nodes = [
            makeNode(name: "mac-a", podCIDRs: ["10.250.25.0/24", "fd42:10:244:25::/64"]),
            try makeDualStackManagedNode(
                name: "wrong-vni",
                podCIDRs: ["10.250.4.0/24", "fd42:10:244:4::/64"],
                publicIP: "198.18.55.4",
                publicIPv6: "fd31::4",
                vtepMAC: "02:00:00:00:00:04",
                vtepMACIPv6: "02:00:00:00:10:04",
                vni: 4097
            ),
            try makeDualStackManagedNode(
                name: "overlap-a",
                podCIDRs: ["10.250.6.0/24", "fd42:10:244:6::/64"],
                publicIP: "198.18.55.6",
                publicIPv6: "fd31::6",
                vtepMAC: "02:00:00:00:00:06",
                vtepMACIPv6: "02:00:00:00:10:06"
            ),
            try makeDualStackManagedNode(
                name: "overlap-b",
                podCIDRs: ["10.250.7.0/24", "fd42:10:244:6:8000::/65"],
                publicIP: "198.18.55.7",
                publicIPv6: "fd31::7",
                vtepMAC: "02:00:00:00:00:07",
                vtepMACIPv6: "02:00:00:00:10:07"
            ),
        ]

        let result = try FlannelPeerCompiler.compile(
            nodes: nodes,
            localNodeName: "mac-a",
            networkConfig: makeDualStackNetworkConfig()
        )

        #expect(result.ipv6Peers.isEmpty)
        #expect(result.issues.contains { $0.id == "node/wrong-vni/ipv6-vni" })
        #expect(result.issues.contains { $0.id.contains("ipv6-pod-cidr-overlap") })
    }

    @Test
    func decodesLegacyIPv4OnlyCompilationWithoutIPv6Fields() throws {
        let compilation = try JSONDecoder().decode(
            FlannelPeerCompilation.self,
            from: Data(#"{"peers":[],"issues":[]}"#.utf8)
        )

        #expect(compilation.localNetwork == nil)
        #expect(compilation.peers.isEmpty)
        #expect(compilation.localIPv6Network == nil)
        #expect(compilation.ipv6Peers.isEmpty)
    }
}

private func makeNetworkConfig() -> FlannelNetworkConfig {
    FlannelNetworkConfig(
        network: "10.250.0.0/16",
        backend: FlannelVXLANBackendConfig(vni: 4096, port: 4789)
    )
}

private func makeDualStackNetworkConfig() -> FlannelNetworkConfig {
    FlannelNetworkConfig(
        network: "10.250.0.0/16",
        ipv6Network: "fd42:10:244::/56",
        enableIPv6: true,
        backend: FlannelVXLANBackendConfig(vni: 4096, port: 4789)
    )
}

private func makeNode(
    name: String,
    podCIDRs: [String],
    annotations: [String: String]? = nil,
    internalIP: String? = nil,
    internalIPv6: String? = nil,
    operatingSystem: String? = nil
) -> FlannelNode {
    let addresses = [
        internalIP.map { FlannelNodeAddress(type: "InternalIP", address: $0) },
        internalIPv6.map { FlannelNodeAddress(type: "InternalIP", address: $0) },
    ].compactMap { $0 }
    return FlannelNode(
        metadata: FlannelObjectMeta(
            name: name,
            labels: operatingSystem.map { ["kubernetes.io/os": $0] },
            annotations: annotations
        ),
        spec: FlannelNodeSpec(podCIDR: podCIDRs.first, podCIDRs: podCIDRs),
        status: addresses.isEmpty ? nil : FlannelNodeStatus(addresses: addresses)
    )
}

private func makeDualStackManagedNode(
    name: String,
    podCIDRs: [String],
    publicIP: String,
    publicIPv6: String,
    vtepMAC: String,
    vtepMACIPv6: String,
    vni: Int = 4096,
    operatingSystem: String? = nil,
    prefix: String = "flannel.alpha.coreos.com"
) throws -> FlannelNode {
    let keys = try FlannelAnnotationKeys(prefix: prefix)
    let backendData = try JSONEncoder().encode(FlannelBackendLeaseData(vni: vni, vtepMAC: vtepMAC))
    let backendV6Data = try JSONEncoder().encode(FlannelBackendLeaseData(vni: vni, vtepMAC: vtepMACIPv6))
    return makeNode(
        name: name,
        podCIDRs: podCIDRs,
        annotations: [
            keys.kubeSubnetManager: "true",
            keys.backendType: "vxlan",
            keys.publicIP: publicIP,
            keys.backendData: String(decoding: backendData, as: UTF8.self),
            keys.publicIPv6: publicIPv6,
            keys.backendV6Data: String(decoding: backendV6Data, as: UTF8.self),
        ],
        operatingSystem: operatingSystem
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
