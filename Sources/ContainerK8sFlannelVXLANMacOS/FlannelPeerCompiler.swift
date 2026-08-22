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

public enum FlannelPeerCompiler {
    public static func compile(
        nodes: [FlannelNode],
        localNodeName: String,
        networkConfig: FlannelNetworkConfig,
        annotationPrefix: String = "flannel.alpha.coreos.com",
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> FlannelPeerCompilation {
        let keys = try FlannelAnnotationKeys(prefix: annotationPrefix)
        guard let clusterNetwork = FlannelIPv4.parseCIDR(networkConfig.network) else {
            throw FlannelVXLANError.invalidNetworkConfig("Network must be a valid IPv4 CIDR")
        }
        let clusterIPv6Network: FlannelIPv6.CIDR?
        if networkConfig.enableIPv6 {
            guard let value = networkConfig.ipv6Network,
                let parsed = FlannelIPv6.parseCIDR(value)
            else {
                throw FlannelVXLANError.invalidNetworkConfig(
                    "IPv6Network must be a valid IPv6 CIDR when EnableIPv6 is true"
                )
            }
            clusterIPv6Network = parsed
        } else {
            clusterIPv6Network = nil
        }

        var issues: [FlannelCompileIssue] = []
        let localNetwork = compileLocalNetwork(
            nodes: nodes,
            localNodeName: localNodeName,
            clusterNetwork: clusterNetwork,
            issues: &issues
        )
        var candidates: [(peer: FlannelPeer, cidr: FlannelIPv4.CIDR)] = []

        for node in nodes.sorted(by: nodeOrder) {
            guard node.metadata.name != localNodeName else {
                continue
            }
            let annotations = node.metadata.annotations ?? [:]
            guard annotations[keys.kubeSubnetManager] == "true" else {
                continue
            }

            guard let nodeName = node.metadata.name, !nodeName.isEmpty else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/<unknown>/name",
                        severity: .error,
                        message: "ignored a managed Node without metadata.name"
                    ))
                continue
            }
            guard annotations[keys.backendType] == "vxlan" else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/backend-type",
                        severity: .warning,
                        message: "ignored managed Node \(nodeName) whose backend type is not vxlan"
                    ))
                continue
            }
            guard let podCIDR = ipv4PodCIDR(for: node) else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/pod-cidr",
                        severity: .error,
                        message: "ignored Node \(nodeName) without a valid IPv4 PodCIDR"
                    ))
                continue
            }
            guard clusterNetwork.contains(podCIDR) else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/pod-cidr",
                        severity: .error,
                        message: "ignored Node \(nodeName) because PodCIDR \(podCIDR.string) is outside \(clusterNetwork.string)"
                    ))
                continue
            }
            if let localCIDR = localNetwork.flatMap({ FlannelIPv4.parseCIDR($0.podCIDR) }), localCIDR.overlaps(podCIDR) {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/pod-cidr-overlap",
                        severity: .error,
                        message: "ignored Node \(nodeName) because PodCIDR \(podCIDR.string) overlaps the local PodCIDR"
                    ))
                continue
            }
            guard let publicIP = annotations[keys.publicIP], FlannelIPv4.parseAddress(publicIP) != nil else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/public-ip",
                        severity: .error,
                        message: "ignored Node \(nodeName) without a valid Flannel public IPv4 address"
                    ))
                continue
            }
            guard let backendData = annotations[keys.backendData], !backendData.isEmpty else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/backend-data",
                        severity: .pending,
                        message: "waiting for Node \(nodeName) to publish VXLAN backend data"
                    ))
                continue
            }

            let leaseData: FlannelBackendLeaseData
            do {
                leaseData = try decoder.decode(FlannelBackendLeaseData.self, from: Data(backendData.utf8))
            } catch {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/backend-data",
                        severity: .error,
                        message: "ignored Node \(nodeName) with invalid VXLAN backend data: \(error)"
                    ))
                continue
            }
            guard leaseData.vni == networkConfig.backend.vni else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/vni",
                        severity: .error,
                        message: "ignored Node \(nodeName) with VNI \(leaseData.vni); expected \(networkConfig.backend.vni)"
                    ))
                continue
            }
            guard !leaseData.vtepMAC.isEmpty else {
                // Windows publishes an empty VtepMAC before HCN creates its DR MAC.
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/vtep-mac",
                        severity: .pending,
                        message: "waiting for Node \(nodeName) to publish its VXLAN VTEP MAC"
                    ))
                continue
            }
            guard let vtepMAC = FlannelVTEPMAC.normalize(leaseData.vtepMAC) else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/vtep-mac",
                        severity: .error,
                        message: "ignored Node \(nodeName) with an invalid VXLAN VTEP MAC"
                    ))
                continue
            }

            candidates.append(
                (
                    peer: FlannelPeer(
                        nodeName: nodeName,
                        operatingSystem: node.metadata.labels?["kubernetes.io/os"],
                        podCIDR: podCIDR.string,
                        subnetBase: podCIDR.baseAddress,
                        publicIP: publicIP,
                        vni: leaseData.vni,
                        vtepMAC: vtepMAC
                    ),
                    cidr: podCIDR
                ))
        }

        let rejectedNodes = overlappingNodes(in: candidates, issues: &issues)
        let peers =
            candidates
            .map(\.peer)
            .filter { !rejectedNodes.contains($0.nodeName) }
            .sorted()
        let ipv6Compilation = compileIPv6(
            nodes: nodes,
            localNodeName: localNodeName,
            clusterNetwork: clusterIPv6Network,
            networkConfig: networkConfig,
            keys: keys,
            decoder: decoder,
            issues: &issues
        )
        return FlannelPeerCompilation(
            localNetwork: localNetwork,
            peers: peers,
            localIPv6Network: ipv6Compilation.localNetwork,
            ipv6Peers: ipv6Compilation.peers,
            issues: issues.sorted()
        )
    }

    private static func compileLocalNetwork(
        nodes: [FlannelNode],
        localNodeName: String,
        clusterNetwork: FlannelIPv4.CIDR,
        issues: inout [FlannelCompileIssue]
    ) -> FlannelLocalNodeNetwork? {
        guard let node = nodes.first(where: { $0.metadata.name == localNodeName }) else {
            issues.append(
                FlannelCompileIssue(
                    id: "node/\(localNodeName)/missing",
                    severity: .error,
                    message: "local Node \(localNodeName) was not returned by the Kubernetes API"
                ))
            return nil
        }
        guard let podCIDR = ipv4PodCIDR(for: node) else {
            issues.append(
                FlannelCompileIssue(
                    id: "node/\(localNodeName)/pod-cidr",
                    severity: .pending,
                    message: "waiting for local Node \(localNodeName) to receive an IPv4 PodCIDR"
                ))
            return nil
        }
        guard clusterNetwork.contains(podCIDR) else {
            issues.append(
                FlannelCompileIssue(
                    id: "node/\(localNodeName)/pod-cidr",
                    severity: .error,
                    message: "local PodCIDR \(podCIDR.string) is outside \(clusterNetwork.string)"
                ))
            return nil
        }
        return FlannelLocalNodeNetwork(
            nodeName: localNodeName,
            podCIDR: podCIDR.string,
            subnetBase: podCIDR.baseAddress,
            internalIP: node.status?.internalIPv4
        )
    }

    private static func ipv4PodCIDR(for node: FlannelNode) -> FlannelIPv4.CIDR? {
        var candidates = node.spec.podCIDRs ?? []
        if let podCIDR = node.spec.podCIDR, !candidates.contains(podCIDR) {
            candidates.append(podCIDR)
        }
        return candidates.lazy.compactMap(FlannelIPv4.parseCIDR).first
    }

    private static func compileIPv6(
        nodes: [FlannelNode],
        localNodeName: String,
        clusterNetwork: FlannelIPv6.CIDR?,
        networkConfig: FlannelNetworkConfig,
        keys: FlannelAnnotationKeys,
        decoder: JSONDecoder,
        issues: inout [FlannelCompileIssue]
    ) -> (localNetwork: FlannelLocalNodeIPv6Network?, peers: [FlannelIPv6Peer]) {
        guard let clusterNetwork else {
            return (nil, [])
        }

        let localNetwork = compileLocalIPv6Network(
            nodes: nodes,
            localNodeName: localNodeName,
            clusterNetwork: clusterNetwork,
            issues: &issues
        )
        var candidates: [(peer: FlannelIPv6Peer, cidr: FlannelIPv6.CIDR)] = []

        for node in nodes.sorted(by: nodeOrder) {
            guard node.metadata.name != localNodeName else {
                continue
            }
            let annotations = node.metadata.annotations ?? [:]
            guard annotations[keys.kubeSubnetManager] == "true",
                let nodeName = node.metadata.name,
                !nodeName.isEmpty
            else {
                continue
            }

            if node.metadata.labels?["kubernetes.io/os"]?.lowercased() == "windows" {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/ipv6-unsupported",
                        severity: .warning,
                        message: "ignored IPv6 for Windows Node \(nodeName) because Flannel VXLAN dual-stack is unsupported on Windows"
                    ))
                continue
            }
            guard annotations[keys.backendType] == "vxlan" else {
                continue
            }

            let podCIDRs = ipv6PodCIDRs(for: node)
            guard podCIDRs.count == 1, let podCIDR = podCIDRs.first else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/ipv6-pod-cidr",
                        severity: .error,
                        message: podCIDRs.isEmpty
                            ? "ignored Node \(nodeName) without a valid IPv6 PodCIDR"
                            : "ignored Node \(nodeName) with multiple IPv6 PodCIDRs"
                    ))
                continue
            }
            guard clusterNetwork.contains(podCIDR) else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/ipv6-pod-cidr",
                        severity: .error,
                        message: "ignored Node \(nodeName) because IPv6 PodCIDR \(podCIDR.string) is outside \(clusterNetwork.string)"
                    ))
                continue
            }
            if let localCIDR = localNetwork.flatMap({ FlannelIPv6.parseCIDR($0.podCIDR) }),
                localCIDR.overlaps(podCIDR)
            {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/ipv6-pod-cidr-overlap",
                        severity: .error,
                        message: "ignored Node \(nodeName) because IPv6 PodCIDR \(podCIDR.string) overlaps the local IPv6 PodCIDR"
                    ))
                continue
            }
            guard let rawPublicIPv6 = annotations[keys.publicIPv6],
                let publicIPv6 = FlannelIPv6.parseAddress(rawPublicIPv6),
                publicIPv6.isUsableUnderlayAddress
            else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/public-ipv6",
                        severity: .error,
                        message: "ignored Node \(nodeName) without a usable Flannel public IPv6 address"
                    ))
                continue
            }
            guard let backendData = annotations[keys.backendV6Data], !backendData.isEmpty else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/backend-v6-data",
                        severity: .pending,
                        message: "waiting for Node \(nodeName) to publish IPv6 VXLAN backend data"
                    ))
                continue
            }

            let leaseData: FlannelBackendLeaseData
            do {
                leaseData = try decoder.decode(FlannelBackendLeaseData.self, from: Data(backendData.utf8))
            } catch {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/backend-v6-data",
                        severity: .error,
                        message: "ignored Node \(nodeName) with invalid IPv6 VXLAN backend data: \(error)"
                    ))
                continue
            }
            guard leaseData.vni == networkConfig.backend.vni else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/ipv6-vni",
                        severity: .error,
                        message: "ignored Node \(nodeName) with IPv6 VNI \(leaseData.vni); expected \(networkConfig.backend.vni)"
                    ))
                continue
            }
            guard !leaseData.vtepMAC.isEmpty else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/ipv6-vtep-mac",
                        severity: .pending,
                        message: "waiting for Node \(nodeName) to publish its IPv6 VXLAN VTEP MAC"
                    ))
                continue
            }
            guard let vtepMAC = FlannelVTEPMAC.normalize(leaseData.vtepMAC) else {
                issues.append(
                    FlannelCompileIssue(
                        id: "node/\(nodeName)/ipv6-vtep-mac",
                        severity: .error,
                        message: "ignored Node \(nodeName) with an invalid IPv6 VXLAN VTEP MAC"
                    ))
                continue
            }

            candidates.append(
                (
                    peer: FlannelIPv6Peer(
                        nodeName: nodeName,
                        operatingSystem: node.metadata.labels?["kubernetes.io/os"],
                        podCIDR: podCIDR.string,
                        subnetBase: podCIDR.baseAddress,
                        publicIPv6: publicIPv6.string,
                        vni: leaseData.vni,
                        vtepMAC: vtepMAC
                    ),
                    cidr: podCIDR
                ))
        }

        let rejectedNodes = overlappingIPv6Nodes(in: candidates, issues: &issues)
        return (
            localNetwork,
            candidates.map(\.peer).filter { !rejectedNodes.contains($0.nodeName) }.sorted()
        )
    }

    private static func compileLocalIPv6Network(
        nodes: [FlannelNode],
        localNodeName: String,
        clusterNetwork: FlannelIPv6.CIDR,
        issues: inout [FlannelCompileIssue]
    ) -> FlannelLocalNodeIPv6Network? {
        guard let node = nodes.first(where: { $0.metadata.name == localNodeName }) else {
            issues.append(
                FlannelCompileIssue(
                    id: "node/\(localNodeName)/ipv6-missing",
                    severity: .error,
                    message: "local Node \(localNodeName) was not returned by the Kubernetes API for IPv6"
                ))
            return nil
        }
        let podCIDRs = ipv6PodCIDRs(for: node)
        guard podCIDRs.count == 1, let podCIDR = podCIDRs.first else {
            issues.append(
                FlannelCompileIssue(
                    id: "node/\(localNodeName)/ipv6-pod-cidr",
                    severity: podCIDRs.isEmpty ? .pending : .error,
                    message: podCIDRs.isEmpty
                        ? "waiting for local Node \(localNodeName) to receive an IPv6 PodCIDR"
                        : "local Node \(localNodeName) has multiple IPv6 PodCIDRs"
                ))
            return nil
        }
        guard clusterNetwork.contains(podCIDR) else {
            issues.append(
                FlannelCompileIssue(
                    id: "node/\(localNodeName)/ipv6-pod-cidr",
                    severity: .error,
                    message: "local IPv6 PodCIDR \(podCIDR.string) is outside \(clusterNetwork.string)"
                ))
            return nil
        }
        return FlannelLocalNodeIPv6Network(
            nodeName: localNodeName,
            podCIDR: podCIDR.string,
            subnetBase: podCIDR.baseAddress,
            internalIPv6: node.status?.internalIPv6
        )
    }

    private static func ipv6PodCIDRs(for node: FlannelNode) -> [FlannelIPv6.CIDR] {
        var candidates = node.spec.podCIDRs ?? []
        if let podCIDR = node.spec.podCIDR, !candidates.contains(podCIDR) {
            candidates.append(podCIDR)
        }
        return Array(Set(candidates.compactMap(FlannelIPv6.parseCIDR))).sorted { $0.string < $1.string }
    }

    private static func overlappingIPv6Nodes(
        in candidates: [(peer: FlannelIPv6Peer, cidr: FlannelIPv6.CIDR)],
        issues: inout [FlannelCompileIssue]
    ) -> Set<String> {
        var rejected: Set<String> = []
        guard candidates.count > 1 else {
            return rejected
        }

        for leftIndex in 0..<(candidates.count - 1) {
            for rightIndex in (leftIndex + 1)..<candidates.count {
                let left = candidates[leftIndex]
                let right = candidates[rightIndex]
                guard left.cidr.overlaps(right.cidr) else {
                    continue
                }
                rejected.insert(left.peer.nodeName)
                rejected.insert(right.peer.nodeName)
                issues.append(
                    FlannelCompileIssue(
                        id: "nodes/\(left.peer.nodeName),\(right.peer.nodeName)/ipv6-pod-cidr-overlap",
                        severity: .error,
                        message: "ignored Nodes \(left.peer.nodeName) and \(right.peer.nodeName) with overlapping IPv6 PodCIDRs"
                    ))
            }
        }
        return rejected
    }

    private static func overlappingNodes(
        in candidates: [(peer: FlannelPeer, cidr: FlannelIPv4.CIDR)],
        issues: inout [FlannelCompileIssue]
    ) -> Set<String> {
        var rejected: Set<String> = []
        guard candidates.count > 1 else {
            return rejected
        }

        for leftIndex in 0..<(candidates.count - 1) {
            for rightIndex in (leftIndex + 1)..<candidates.count {
                let left = candidates[leftIndex]
                let right = candidates[rightIndex]
                guard left.cidr.overlaps(right.cidr) else {
                    continue
                }
                rejected.insert(left.peer.nodeName)
                rejected.insert(right.peer.nodeName)
                issues.append(
                    FlannelCompileIssue(
                        id: "nodes/\(left.peer.nodeName),\(right.peer.nodeName)/pod-cidr-overlap",
                        severity: .error,
                        message: "ignored Nodes \(left.peer.nodeName) and \(right.peer.nodeName) with overlapping PodCIDRs"
                    ))
            }
        }
        return rejected
    }

    private static func nodeOrder(_ lhs: FlannelNode, _ rhs: FlannelNode) -> Bool {
        (lhs.metadata.name ?? "") < (rhs.metadata.name ?? "")
    }
}
