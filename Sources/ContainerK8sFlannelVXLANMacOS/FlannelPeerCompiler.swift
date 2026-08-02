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
        return FlannelPeerCompilation(localNetwork: localNetwork, peers: peers, issues: issues.sorted())
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
