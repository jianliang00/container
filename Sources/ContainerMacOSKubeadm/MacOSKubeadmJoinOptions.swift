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

import Darwin
import Foundation

public enum MacOSKubeadmNetworkMode: String, CaseIterable, Sendable, Equatable {
    case full
    case compat

    public var usesPodNetworking: Bool {
        self == .full
    }

    public var runtimeHandler: String {
        switch self {
        case .full:
            return "macos"
        case .compat:
            return "macos-compat"
        }
    }

    public var runtimeClassName: String {
        runtimeHandler
    }

    public var networkBackend: String {
        switch self {
        case .full:
            return "vmnetShared"
        case .compat:
            return "virtualizationNAT"
        }
    }

    public var networkName: String {
        switch self {
        case .full:
            return "kubernetes-pod"
        case .compat:
            return "default"
        }
    }

    public var nodeNetworkLabelValue: String {
        rawValue
    }
}

public enum MacOSKubeadmVMNetDisconnectRecovery: String, CaseIterable, Sendable, Equatable {
    case disabled
    case monitor
    case stopSandbox = "stop-sandbox"
}

public struct MacOSKubeadmRuntimeClassProfile: Sendable, Equatable {
    public var name: String
    public var handler: String
    public var sandboxImage: String
    public var networkMode: MacOSKubeadmNetworkMode
    public var guiEnabled: Bool

    public init(
        name: String,
        handler: String? = nil,
        sandboxImage: String,
        networkMode: MacOSKubeadmNetworkMode,
        guiEnabled: Bool = false
    ) {
        self.name = name
        self.handler = handler ?? name
        self.sandboxImage = sandboxImage
        self.networkMode = networkMode
        self.guiEnabled = guiEnabled
    }

    public var manifestFileName: String {
        "runtimeclass-\(name).yaml"
    }
}

public struct MacOSKubeadmJoinOptions: Sendable, Equatable {
    public var apiServer: URL
    public var nodeName: String
    public var token: String
    public var discoveryTokenCACertHashes: [String]
    public var certificateAuthorityPEM: String?
    public var kubeProxyToken: String?
    public var flannelToken: String?
    public var clusterName: String
    public var clusterDNS: String
    public var clusterDomain: String
    public var sandboxImage: String
    public var runtimeClasses: [MacOSKubeadmRuntimeClassProfile]
    public var networkMode: MacOSKubeadmNetworkMode
    public var enableDualStack: Bool
    public var vmnetDisconnectRecovery: MacOSKubeadmVMNetDisconnectRecovery
    public var masqueradeIPv6PodTraffic: Bool?
    public var ipv6EgressInterface: String?
    public var ipv6EgressSourceAddress: String?
    public var nodeIPAddresses: [String]
    public var flannelConfigMapNamespace: String
    public var flannelConfigMapName: String
    public var flannelUnderlayInterface: String?
    public var containerServiceUserID: Int
    public var installRoot: String
    public var startServices: Bool
    public var dryRun: Bool
    public var debug: Bool

    public init(
        apiServer: URL,
        nodeName: String,
        token: String,
        discoveryTokenCACertHashes: [String],
        certificateAuthorityPEM: String? = nil,
        kubeProxyToken: String? = nil,
        flannelToken: String? = nil,
        clusterName: String = "kubernetes",
        clusterDNS: String = "10.96.0.10",
        clusterDomain: String = "cluster.local",
        sandboxImage: String = "localhost/macos-sandbox:latest",
        runtimeClasses: [MacOSKubeadmRuntimeClassProfile] = [],
        networkMode: MacOSKubeadmNetworkMode = .full,
        enableDualStack: Bool = false,
        vmnetDisconnectRecovery: MacOSKubeadmVMNetDisconnectRecovery = .disabled,
        masqueradeIPv6PodTraffic: Bool? = nil,
        ipv6EgressInterface: String? = nil,
        ipv6EgressSourceAddress: String? = nil,
        nodeIPAddresses: [String] = [],
        flannelConfigMapNamespace: String = "kube-flannel",
        flannelConfigMapName: String = "kube-flannel-cfg",
        flannelUnderlayInterface: String? = nil,
        containerServiceUserID: Int = 0,
        installRoot: String = "/",
        startServices: Bool = true,
        dryRun: Bool = false,
        debug: Bool = false
    ) {
        self.apiServer = apiServer
        self.nodeName = nodeName
        self.token = token
        self.discoveryTokenCACertHashes = discoveryTokenCACertHashes
        self.certificateAuthorityPEM = certificateAuthorityPEM
        self.kubeProxyToken = kubeProxyToken
        self.flannelToken = flannelToken
        self.clusterName = clusterName
        self.clusterDNS = clusterDNS
        self.clusterDomain = clusterDomain
        self.sandboxImage = sandboxImage
        self.runtimeClasses = runtimeClasses
        self.networkMode = networkMode
        self.enableDualStack = enableDualStack
        self.vmnetDisconnectRecovery = vmnetDisconnectRecovery
        self.masqueradeIPv6PodTraffic = masqueradeIPv6PodTraffic
        self.ipv6EgressInterface = ipv6EgressInterface
        self.ipv6EgressSourceAddress = ipv6EgressSourceAddress
        self.nodeIPAddresses = nodeIPAddresses
        self.flannelConfigMapNamespace = flannelConfigMapNamespace
        self.flannelConfigMapName = flannelConfigMapName
        self.flannelUnderlayInterface = flannelUnderlayInterface
        self.containerServiceUserID = containerServiceUserID
        self.installRoot = installRoot
        self.startServices = startServices
        self.dryRun = dryRun
        self.debug = debug
    }
}

extension MacOSKubeadmJoinOptions {
    public func validateNodeNetworkConfiguration() throws {
        let hasCustomFlannelConfiguration =
            flannelConfigMapNamespace != "kube-flannel"
            || flannelConfigMapName != "kube-flannel-cfg"
            || flannelUnderlayInterface != nil
        guard !hasCustomFlannelConfiguration || networkMode.usesPodNetworking else {
            throw MacOSKubeadmError.invalidInput(
                "Flannel options require --network-mode full"
            )
        }

        guard isDNSLabel(flannelConfigMapNamespace) else {
            throw MacOSKubeadmError.invalidInput(
                "--flannel-config-map-namespace must be a valid DNS label"
            )
        }
        guard isDNSSubdomain(flannelConfigMapName) else {
            throw MacOSKubeadmError.invalidInput(
                "--flannel-config-map-name must be a valid DNS subdomain"
            )
        }
        if let flannelUnderlayInterface {
            guard isValidInterfaceName(flannelUnderlayInterface) else {
                throw MacOSKubeadmError.invalidInput(
                    "--flannel-underlay-interface must be a valid interface name"
                )
            }
        }

        let parsedNodeIPs = try nodeIPAddresses.map { value in
            guard let parsed = parseNodeIPAddress(value) else {
                throw MacOSKubeadmError.invalidInput(
                    "--node-ip must be a valid usable unicast IP address"
                )
            }
            return parsed
        }
        guard Set(parsedNodeIPs).count == parsedNodeIPs.count else {
            throw MacOSKubeadmError.invalidInput("--node-ip values must be unique")
        }

        if enableDualStack {
            guard parsedNodeIPs.isEmpty || parsedNodeIPs.count == 2 else {
                throw MacOSKubeadmError.invalidInput(
                    "dual-stack --node-ip requires one IPv4 address followed by one IPv6 address"
                )
            }
            if parsedNodeIPs.count == 2 {
                guard parsedNodeIPs[0].isIPv4, parsedNodeIPs[1].isIPv6 else {
                    throw MacOSKubeadmError.invalidInput(
                        "dual-stack --node-ip values must be ordered IPv4,IPv6"
                    )
                }
            }
        } else {
            guard parsedNodeIPs.count <= 1 else {
                throw MacOSKubeadmError.invalidInput(
                    "multiple --node-ip values require --enable-dual-stack"
                )
            }
            if networkMode.usesPodNetworking, let nodeIP = parsedNodeIPs.first {
                guard nodeIP.isIPv4 else {
                    throw MacOSKubeadmError.invalidInput(
                        "full-mode IPv4 Pod networking requires an IPv4 --node-ip"
                    )
                }
            }
        }
    }

    public func validateIPv6EgressConfiguration() throws {
        let hasExplicitConfiguration =
            masqueradeIPv6PodTraffic != nil
            || ipv6EgressInterface != nil
            || ipv6EgressSourceAddress != nil
        guard !hasExplicitConfiguration || enableDualStack else {
            throw MacOSKubeadmError.invalidInput(
                "IPv6 egress options require --enable-dual-stack"
            )
        }
        guard !hasExplicitConfiguration || networkMode == .full else {
            throw MacOSKubeadmError.invalidInput(
                "IPv6 egress options require --network-mode full"
            )
        }
        guard
            masqueradeIPv6PodTraffic != false
                || (ipv6EgressInterface == nil && ipv6EgressSourceAddress == nil)
        else {
            throw MacOSKubeadmError.invalidInput(
                "--disable-ipv6-masquerade cannot be combined with --ipv6-egress-interface or --ipv6-egress-source-address"
            )
        }
        if let ipv6EgressInterface {
            guard isValidInterfaceName(ipv6EgressInterface) else {
                throw MacOSKubeadmError.invalidInput(
                    "--ipv6-egress-interface must be a valid interface name"
                )
            }
        }
        if let ipv6EgressSourceAddress {
            guard let address = parseIPv6EgressSourceAddress(ipv6EgressSourceAddress) else {
                throw MacOSKubeadmError.invalidInput(
                    "--ipv6-egress-source-address must be a valid IPv6 address"
                )
            }
            guard isUsableIPv6EgressSourceAddress(address) else {
                throw MacOSKubeadmError.invalidInput(
                    "--ipv6-egress-source-address must be a usable unicast IPv6 address"
                )
            }
        }
    }

    public var defaultRuntimeClass: MacOSKubeadmRuntimeClassProfile {
        MacOSKubeadmRuntimeClassProfile(
            name: networkMode.runtimeClassName,
            handler: networkMode.runtimeHandler,
            sandboxImage: sandboxImage,
            networkMode: networkMode
        )
    }

    public var effectiveRuntimeClasses: [MacOSKubeadmRuntimeClassProfile] {
        [defaultRuntimeClass] + runtimeClasses
    }

    public var rootPrefix: String {
        let trimmed = installRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return ""
        }
        return "/" + trimmed
    }

    public func rooted(_ absolutePath: String) -> String {
        precondition(absolutePath.hasPrefix("/"), "path must be absolute")
        guard !rootPrefix.isEmpty else {
            return absolutePath
        }
        return rootPrefix + absolutePath
    }
}

private func parseIPv6EgressSourceAddress(_ value: String) -> in6_addr? {
    guard !value.contains("%") else {
        return nil
    }
    var address = in6_addr()
    guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
        return nil
    }
    return address
}

private enum ParsedNodeIPAddress: Hashable {
    case ipv4([UInt8])
    case ipv6([UInt8])

    var isIPv4: Bool {
        if case .ipv4 = self {
            return true
        }
        return false
    }

    var isIPv6: Bool {
        if case .ipv6 = self {
            return true
        }
        return false
    }
}

private func parseNodeIPAddress(_ value: String) -> ParsedNodeIPAddress? {
    guard !value.isEmpty,
        value == value.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.contains("%")
    else {
        return nil
    }

    var ipv4 = in_addr()
    if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
        var address = ipv4
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard isUsableIPv4NodeAddress(bytes) else {
            return nil
        }
        return .ipv4(bytes)
    }

    guard let ipv6 = parseIPv6EgressSourceAddress(value), isUsableIPv6EgressSourceAddress(ipv6) else {
        return nil
    }
    var address = ipv6
    return .ipv6(withUnsafeBytes(of: &address) { Array($0) })
}

private func isUsableIPv4NodeAddress(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 4 else {
        return false
    }
    return bytes != [0, 0, 0, 0]
        && bytes != [255, 255, 255, 255]
        && bytes[0] != 127
        && !(bytes[0] == 169 && bytes[1] == 254)
        && !(224...239).contains(bytes[0])
}

private func isValidInterfaceName(_ value: String) -> Bool {
    value.utf8.count < Int(IFNAMSIZ)
        && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
}

private func isDNSLabel(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 63 else {
        return false
    }
    return value.range(
        of: #"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"#,
        options: .regularExpression
    ) != nil
}

private func isDNSSubdomain(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 253 else {
        return false
    }
    return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
        isDNSLabel(String($0))
    }
}

private func isUsableIPv6EgressSourceAddress(_ address: in6_addr) -> Bool {
    var address = address
    let bytes = withUnsafeBytes(of: &address) { Array($0) }
    return !bytes.allSatisfy { $0 == 0 }
        && bytes != Array(repeating: 0, count: 15) + [1]
        && !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        && bytes[0] != 0xff
        && !(bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff)
}
