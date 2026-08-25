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

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct FlannelVXLANMacOSConfig: Codable, Sendable, Equatable {
    public static let defaultOwnershipStatePath = "/var/lib/container/flannel-vxlan/ownership.json"
    public static let defaultStatusPath = "/var/lib/container/flannel-vxlan/status.json"
    public static let defaultStateManifestPath = "/private/var/lib/container/flannel-vxlan/state-manifest.json"
    public static let defaultControlSocketPath = "/var/run/container-flannel-vxlan-macos.sock"
    public static let defaultDaemonLifetimeLockPath = "/var/run/container-flannel-vxlan-daemon.lock"
    public static let defaultForwardingAdvisoryLockPath = "/var/run/container-flannel-vxlan-forwarding.lock"

    public static var defaultPersistentStatePaths: [String] {
        let ownershipURL = URL(fileURLWithPath: defaultOwnershipStatePath)
        return [
            ownershipURL.path,
            ownershipURL.deletingLastPathComponent().appendingPathComponent("network-ownership.json").path,
            ownershipURL.deletingLastPathComponent().appendingPathComponent("host-ipv6-gateway-ownership.json").path,
            ownershipURL.deletingLastPathComponent().appendingPathComponent("forwarding-ownership.json").path,
            ownershipURL.deletingLastPathComponent().appendingPathComponent("ready.json").path,
            defaultStatusPath,
        ]
    }

    public var kubeconfig: String
    public var nodeKubeconfig: String
    public var nodeName: String
    public var containerServiceUserID: Int
    public var configMapNamespace: String
    public var configMapName: String
    public var networkConfigKey: String
    public var annotationPrefix: String
    public var vtepMACPath: String
    public var dualStackEnabled: Bool
    public var runtimeStatePath: String
    public var readyStatePath: String
    public var statusPath: String?
    public var ownershipStatePath: String
    public var networkName: String
    public var networkPlugin: String
    public var networkVariant: String
    public var underlayInterface: String?
    public var syncPeriodSeconds: Int

    public var networkOwnershipStatePath: String {
        URL(fileURLWithPath: ownershipStatePath)
            .deletingLastPathComponent()
            .appendingPathComponent("network-ownership.json")
            .path
    }

    public var hostIPv6GatewayOwnershipStatePath: String {
        URL(fileURLWithPath: ownershipStatePath)
            .deletingLastPathComponent()
            .appendingPathComponent("host-ipv6-gateway-ownership.json")
            .path
    }

    public var forwardingOwnershipStatePath: String {
        URL(fileURLWithPath: ownershipStatePath)
            .deletingLastPathComponent()
            .appendingPathComponent("forwarding-ownership.json")
            .path
    }

    public var vtepMACIPv6Path: String {
        URL(fileURLWithPath: vtepMACPath)
            .deletingLastPathComponent()
            .appendingPathComponent("vtep-mac-v6")
            .path
    }

    public var withdrawalStatePaths: [String] {
        [
            ownershipStatePath,
            hostIPv6GatewayOwnershipStatePath,
            forwardingOwnershipStatePath,
            readyStatePath,
        ]
    }

    public var managedStatePaths: FlannelManagedStatePaths {
        FlannelManagedStatePaths(
            dataplaneOwnership: ownershipStatePath,
            networkOwnership: networkOwnershipStatePath,
            hostIPv6GatewayOwnership: hostIPv6GatewayOwnershipStatePath,
            forwardingOwnership: forwardingOwnershipStatePath,
            ready: readyStatePath,
            statusPath: statusPath
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kubeconfig
        case nodeKubeconfig
        case nodeName
        case containerServiceUserID
        case configMapNamespace
        case configMapName
        case networkConfigKey
        case annotationPrefix
        case vtepMACPath
        case dualStackEnabled
        case runtimeStatePath
        case readyStatePath
        case statusPath
        case ownershipStatePath
        case networkName
        case networkPlugin
        case networkVariant
        case underlayInterface
        case syncPeriodSeconds
    }

    public init(
        kubeconfig: String,
        nodeKubeconfig: String = "/etc/kubernetes/kubelet.conf",
        nodeName: String,
        containerServiceUserID: Int = 0,
        configMapNamespace: String = "kube-flannel",
        configMapName: String = "kube-flannel-cfg",
        networkConfigKey: String = "net-conf.json",
        annotationPrefix: String = "flannel.alpha.coreos.com",
        vtepMACPath: String = "/var/lib/container/flannel-vxlan/vtep-mac",
        dualStackEnabled: Bool = false,
        runtimeStatePath: String = "/var/lib/container/cri-shim-macos/pod-network.json",
        readyStatePath: String = "/var/lib/container/flannel-vxlan/ready.json",
        statusPath: String? = nil,
        ownershipStatePath: String = FlannelVXLANMacOSConfig.defaultOwnershipStatePath,
        networkName: String = "kubernetes-pod",
        networkPlugin: String = "container-network-vmnet",
        networkVariant: String = "reserved",
        underlayInterface: String? = nil,
        syncPeriodSeconds: Int = 5
    ) {
        self.kubeconfig = kubeconfig
        self.nodeKubeconfig = nodeKubeconfig
        self.nodeName = nodeName
        self.containerServiceUserID = containerServiceUserID
        self.configMapNamespace = configMapNamespace
        self.configMapName = configMapName
        self.networkConfigKey = networkConfigKey
        self.annotationPrefix = annotationPrefix
        self.vtepMACPath = vtepMACPath
        self.dualStackEnabled = dualStackEnabled
        self.runtimeStatePath = runtimeStatePath
        self.readyStatePath = readyStatePath
        self.statusPath = statusPath
        self.ownershipStatePath = ownershipStatePath
        self.networkName = networkName
        self.networkPlugin = networkPlugin
        self.networkVariant = networkVariant
        self.underlayInterface = underlayInterface
        self.syncPeriodSeconds = syncPeriodSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kubeconfig: try container.decode(String.self, forKey: .kubeconfig),
            nodeKubeconfig: try container.decodeIfPresent(String.self, forKey: .nodeKubeconfig)
                ?? "/etc/kubernetes/kubelet.conf",
            nodeName: try container.decode(String.self, forKey: .nodeName),
            containerServiceUserID: try container.decodeIfPresent(Int.self, forKey: .containerServiceUserID) ?? 0,
            configMapNamespace: try container.decodeIfPresent(String.self, forKey: .configMapNamespace) ?? "kube-flannel",
            configMapName: try container.decodeIfPresent(String.self, forKey: .configMapName) ?? "kube-flannel-cfg",
            networkConfigKey: try container.decodeIfPresent(String.self, forKey: .networkConfigKey) ?? "net-conf.json",
            annotationPrefix: try container.decodeIfPresent(String.self, forKey: .annotationPrefix) ?? "flannel.alpha.coreos.com",
            vtepMACPath: try container.decodeIfPresent(String.self, forKey: .vtepMACPath)
                ?? "/var/lib/container/flannel-vxlan/vtep-mac",
            dualStackEnabled: try container.decodeIfPresent(Bool.self, forKey: .dualStackEnabled) ?? false,
            runtimeStatePath: try container.decodeIfPresent(String.self, forKey: .runtimeStatePath)
                ?? "/var/lib/container/cri-shim-macos/pod-network.json",
            readyStatePath: try container.decodeIfPresent(String.self, forKey: .readyStatePath)
                ?? "/var/lib/container/flannel-vxlan/ready.json",
            statusPath: try container.decodeIfPresent(String.self, forKey: .statusPath),
            ownershipStatePath: try container.decodeIfPresent(String.self, forKey: .ownershipStatePath)
                ?? Self.defaultOwnershipStatePath,
            networkName: try container.decodeIfPresent(String.self, forKey: .networkName) ?? "kubernetes-pod",
            networkPlugin: try container.decodeIfPresent(String.self, forKey: .networkPlugin)
                ?? "container-network-vmnet",
            networkVariant: try container.decodeIfPresent(String.self, forKey: .networkVariant) ?? "reserved",
            underlayInterface: try container.decodeIfPresent(String.self, forKey: .underlayInterface),
            syncPeriodSeconds: try container.decodeIfPresent(Int.self, forKey: .syncPeriodSeconds) ?? 5
        )
    }

    public static func load(from url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> FlannelVXLANMacOSConfig {
        let config = try decoder.decode(FlannelVXLANMacOSConfig.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    public func validate() throws {
        for (name, value) in [
            ("kubeconfig", kubeconfig),
            ("nodeKubeconfig", nodeKubeconfig),
            ("nodeName", nodeName),
            ("configMapNamespace", configMapNamespace),
            ("configMapName", configMapName),
            ("networkConfigKey", networkConfigKey),
            ("networkName", networkName),
            ("networkPlugin", networkPlugin),
            ("networkVariant", networkVariant),
        ] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FlannelVXLANError.invalidConfiguration("\(name) is required")
            }
        }
        guard kubeconfig.hasPrefix("/") else {
            throw FlannelVXLANError.invalidConfiguration("kubeconfig must be an absolute path")
        }
        guard nodeKubeconfig.hasPrefix("/") else {
            throw FlannelVXLANError.invalidConfiguration("nodeKubeconfig must be an absolute path")
        }
        guard containerServiceUserID >= 0 else {
            throw FlannelVXLANError.invalidConfiguration("containerServiceUserID must be non-negative")
        }
        for (name, path) in [
            ("vtepMACPath", vtepMACPath),
            ("runtimeStatePath", runtimeStatePath),
            ("readyStatePath", readyStatePath),
            ("ownershipStatePath", ownershipStatePath),
        ] where !path.hasPrefix("/") {
            throw FlannelVXLANError.invalidConfiguration("\(name) must be an absolute path")
        }
        if let statusPath {
            guard statusPath == Self.defaultStatusPath else {
                throw FlannelVXLANError.invalidConfiguration(
                    "statusPath must be \(Self.defaultStatusPath)"
                )
            }
        }
        guard (1...300).contains(syncPeriodSeconds) else {
            throw FlannelVXLANError.invalidConfiguration("syncPeriodSeconds must be between 1 and 300")
        }
        if dualStackEnabled, syncPeriodSeconds > 5 {
            throw FlannelVXLANError.invalidConfiguration(
                "dual-stack syncPeriodSeconds must be at most 5 so the first VM can wait for its host IPv6 gateway"
            )
        }
        try validateFilePathLayout()
        guard !networkName.contains("/"), !networkName.contains(where: { $0.isWhitespace }) else {
            throw FlannelVXLANError.invalidConfiguration("networkName must not contain slashes or whitespace")
        }
        if let underlayInterface {
            guard !underlayInterface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                underlayInterface.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
            else {
                throw FlannelVXLANError.invalidConfiguration("underlayInterface is not a valid interface name")
            }
        }
        _ = try FlannelAnnotationKeys(prefix: annotationPrefix)
    }

    public func validateConfigurationFilePath(_ configPath: String) throws {
        guard configPath.hasPrefix("/") else {
            throw FlannelVXLANError.invalidConfiguration("configPath must be an absolute path")
        }
        try validateFilePathLayout(additionalExclusivePaths: [("configPath", configPath)])
    }

    public func validateControlSocketPath(
        _ controlSocketPath: String,
        configurationFilePath configPath: String
    ) throws {
        guard controlSocketPath.hasPrefix("/") else {
            throw FlannelVXLANError.invalidConfiguration("controlSocketPath must be an absolute path")
        }
        guard configPath.hasPrefix("/") else {
            throw FlannelVXLANError.invalidConfiguration("configPath must be an absolute path")
        }
        try validateFilePathLayout(
            additionalExclusivePaths: [
                ("controlSocketPath", controlSocketPath),
                ("configPath", configPath),
            ]
        )
    }

    public static func canonicalFilePath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    public static func filePathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let canonicalLHS = canonicalFilePath(lhs)
        let canonicalRHS = canonicalFilePath(rhs)
        return canonicalLHS == canonicalRHS
            || isAncestorFilePath(canonicalLHS, of: canonicalRHS)
            || isAncestorFilePath(canonicalRHS, of: canonicalLHS)
    }

    private static func validateDistinctFilePaths(_ paths: [(String, String)]) throws {
        for (index, candidate) in paths.enumerated() {
            for existing in paths[..<index] where filePathsOverlap(candidate.1, existing.1) {
                throw FlannelVXLANError.invalidConfiguration(
                    "\(candidate.0) and \(existing.0) must resolve to separate files"
                )
            }
        }
    }

    private func validateFilePathLayout(
        additionalExclusivePaths: [(String, String)] = []
    ) throws {
        let exclusivePaths = additionalExclusivePaths + exclusiveFilePaths
        try Self.validateDistinctFilePaths(exclusivePaths)
        for credential in credentialFilePaths {
            for exclusivePath in exclusivePaths where Self.filePathsOverlap(credential.1, exclusivePath.1) {
                throw FlannelVXLANError.invalidConfiguration(
                    "\(credential.0) and \(exclusivePath.0) must resolve to separate files"
                )
            }
        }
    }

    private var credentialFilePaths: [(String, String)] {
        [
            ("kubeconfig", kubeconfig),
            ("nodeKubeconfig", nodeKubeconfig),
        ]
    }

    private var exclusiveFilePaths: [(String, String)] {
        var paths = [
            ("vtepMACPath", vtepMACPath),
            ("vtepMACIPv6Path", vtepMACIPv6Path),
            ("runtimeStatePath", runtimeStatePath),
            ("readyStatePath", readyStatePath),
            ("ownershipStatePath", ownershipStatePath),
            ("networkOwnershipStatePath", networkOwnershipStatePath),
            ("hostIPv6GatewayOwnershipStatePath", hostIPv6GatewayOwnershipStatePath),
            ("forwardingOwnershipStatePath", forwardingOwnershipStatePath),
            ("stateManifestPath", Self.defaultStateManifestPath),
            ("daemonLifetimeLockPath", Self.defaultDaemonLifetimeLockPath),
            ("forwardingAdvisoryLockPath", Self.defaultForwardingAdvisoryLockPath),
        ]
        if let statusPath {
            paths.append(("statusPath", statusPath))
        }
        return paths
    }

    private static func isAncestorFilePath(_ candidate: String, of path: String) -> Bool {
        if candidate == "/" {
            return path.hasPrefix("/")
        }
        return path.hasPrefix(candidate + "/")
    }
}

public enum FlannelVXLANError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidNetworkConfig(String)
    case invalidNode(String)
    case kubernetesAPI(String)
    case kubernetesAPIStatus(code: Int, path: String, message: String)
    case persistence(String)
    case runtime(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            "invalid macOS Flannel VXLAN configuration: \(message)"
        case .invalidNetworkConfig(let message):
            "invalid Flannel network configuration: \(message)"
        case .invalidNode(let message):
            "invalid Flannel node: \(message)"
        case .kubernetesAPI(let message):
            "Kubernetes API error: \(message)"
        case .kubernetesAPIStatus(let code, let path, let message):
            "Kubernetes API error: \(path) returned \(code): \(message)"
        case .persistence(let message):
            "Flannel VXLAN persistence error: \(message)"
        case .runtime(let message):
            "Flannel VXLAN runtime error: \(message)"
        }
    }

    public var isKubernetesNotFound: Bool {
        if case .kubernetesAPIStatus(code: 404, path: _, message: _) = self {
            return true
        }
        return false
    }
}

public struct FlannelNetworkConfig: Codable, Sendable, Hashable {
    public var network: String
    public var ipv6Network: String?
    public var enableIPv4: Bool
    public var enableIPv6: Bool
    public var backend: FlannelVXLANBackendConfig

    public init(
        network: String,
        ipv6Network: String? = nil,
        enableIPv4: Bool = true,
        enableIPv6: Bool = false,
        backend: FlannelVXLANBackendConfig
    ) {
        self.network = network
        self.ipv6Network = ipv6Network
        self.enableIPv4 = enableIPv4
        self.enableIPv6 = enableIPv6
        self.backend = backend
    }
}

public struct FlannelVXLANBackendConfig: Codable, Sendable, Hashable {
    public static let encapsulationOverhead = 50

    public var type: String
    public var vni: Int
    public var port: Int
    public var mtu: Int?
    public var directRouting: Bool
    public var gbp: Bool
    public var learning: Bool

    public init(
        type: String = "vxlan",
        vni: Int,
        port: Int,
        mtu: Int? = nil,
        directRouting: Bool = false,
        gbp: Bool = false,
        learning: Bool = false
    ) {
        self.type = type
        self.vni = vni
        self.port = port
        self.mtu = mtu
        self.directRouting = directRouting
        self.gbp = gbp
        self.learning = learning
    }

    public var isWindowsCompatible: Bool {
        vni == 4096 && port == 4789 && !directRouting && !gbp
    }

    public func validateWindowsCompatibility() throws {
        guard vni == 4096 else {
            throw FlannelVXLANError.invalidNetworkConfig("Windows Flannel requires VNI 4096")
        }
        guard port == 4789 else {
            throw FlannelVXLANError.invalidNetworkConfig("Windows Flannel requires UDP port 4789")
        }
        guard !directRouting else {
            throw FlannelVXLANError.invalidNetworkConfig("Windows Flannel does not support DirectRouting")
        }
        guard !gbp else {
            throw FlannelVXLANError.invalidNetworkConfig("Windows Flannel does not support GBP")
        }
    }

    public func innerMTU(underlayMTU: Int) throws -> Int {
        let outerMTU = mtu ?? underlayMTU
        guard outerMTU > Self.encapsulationOverhead else {
            throw FlannelVXLANError.invalidNetworkConfig("VXLAN MTU must be greater than 50")
        }
        return outerMTU - Self.encapsulationOverhead
    }
}

public struct FlannelAnnotationKeys: Sendable, Hashable {
    public var prefix: String
    public var kubeSubnetManager: String
    public var backendData: String
    public var backendV6Data: String
    public var backendType: String
    public var publicIP: String
    public var publicIPv6: String
    public var publicIPOverwrite: String
    public var publicIPv6Overwrite: String

    public init(prefix input: String) throws {
        var normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let slashCount = normalized.filter { $0 == "/" }.count
        guard slashCount <= 1 else {
            throw FlannelVXLANError.invalidConfiguration("annotationPrefix can contain at most one slash")
        }
        if slashCount == 0 {
            normalized += "/"
        } else if !normalized.hasSuffix("/") && !normalized.hasSuffix("-") {
            normalized += "-"
        }

        let pattern = #"^(?:[a-z0-9_-]+\.)+[a-z0-9_-]+/(?:[a-z0-9_-]+-)?$"#
        guard normalized.range(of: pattern, options: .regularExpression) != nil else {
            throw FlannelVXLANError.invalidConfiguration("annotationPrefix must use Flannel's fqdn/name format")
        }

        self.prefix = normalized
        self.kubeSubnetManager = normalized + "kube-subnet-manager"
        self.backendData = normalized + "backend-data"
        self.backendV6Data = normalized + "backend-v6-data"
        self.backendType = normalized + "backend-type"
        self.publicIP = normalized + "public-ip"
        self.publicIPv6 = normalized + "public-ipv6"
        self.publicIPOverwrite = normalized + "public-ip-overwrite"
        self.publicIPv6Overwrite = normalized + "public-ipv6-overwrite"
    }
}

public struct FlannelObjectMeta: Codable, Sendable, Hashable {
    public var namespace: String?
    public var name: String?
    public var uid: String?
    public var resourceVersion: String?
    public var labels: [String: String]?
    public var annotations: [String: String]?

    public init(
        namespace: String? = nil,
        name: String? = nil,
        uid: String? = nil,
        resourceVersion: String? = nil,
        labels: [String: String]? = nil,
        annotations: [String: String]? = nil
    ) {
        self.namespace = namespace
        self.name = name
        self.uid = uid
        self.resourceVersion = resourceVersion
        self.labels = labels
        self.annotations = annotations
    }
}

public struct FlannelNodeList: Codable, Sendable, Hashable {
    public var items: [FlannelNode]

    public init(items: [FlannelNode]) {
        self.items = items
    }
}

public struct FlannelNode: Codable, Sendable, Hashable {
    public var metadata: FlannelObjectMeta
    public var spec: FlannelNodeSpec
    public var status: FlannelNodeStatus?

    public init(metadata: FlannelObjectMeta, spec: FlannelNodeSpec, status: FlannelNodeStatus? = nil) {
        self.metadata = metadata
        self.spec = spec
        self.status = status
    }
}

public struct FlannelNodeSpec: Codable, Sendable, Hashable {
    public var podCIDR: String?
    public var podCIDRs: [String]?

    public init(podCIDR: String? = nil, podCIDRs: [String]? = nil) {
        self.podCIDR = podCIDR
        self.podCIDRs = podCIDRs
    }
}

public struct FlannelNodeStatus: Codable, Sendable, Hashable {
    public var addresses: [FlannelNodeAddress]?
    public var conditions: [FlannelNodeCondition]?

    public init(addresses: [FlannelNodeAddress]? = nil, conditions: [FlannelNodeCondition]? = nil) {
        self.addresses = addresses
        self.conditions = conditions
    }

    public var internalIPv4: String? {
        addresses?.first { address in
            address.type == "InternalIP" && FlannelIPv4.parseAddress(address.address) != nil
        }?.address
    }

    public var internalIPv6: String? {
        addresses?.lazy.compactMap { address -> String? in
            guard address.type == "InternalIP",
                let parsed = FlannelIPv6.parseAddress(address.address),
                parsed.isUsableUnderlayAddress
            else {
                return nil
            }
            return parsed.string
        }.first
    }

    public var isReady: Bool? {
        guard let condition = conditions?.first(where: { $0.type == "Ready" }) else {
            return nil
        }
        return condition.status == "True"
    }
}

public struct FlannelNodeAddress: Codable, Sendable, Hashable {
    public var type: String
    public var address: String

    public init(type: String, address: String) {
        self.type = type
        self.address = address
    }
}

public struct FlannelNodeCondition: Codable, Sendable, Hashable {
    public var type: String
    public var status: String

    public init(type: String, status: String) {
        self.type = type
        self.status = status
    }
}

public struct FlannelConfigMap: Codable, Sendable, Hashable {
    public var metadata: FlannelObjectMeta
    public var data: [String: String]?

    public init(metadata: FlannelObjectMeta, data: [String: String]? = nil) {
        self.metadata = metadata
        self.data = data
    }
}

public struct FlannelBackendLeaseData: Codable, Sendable, Hashable {
    public var vni: Int
    public var vtepMAC: String

    enum CodingKeys: String, CodingKey {
        case vni = "VNI"
        case vtepMAC = "VtepMAC"
    }

    public init(vni: Int, vtepMAC: String) {
        self.vni = vni
        self.vtepMAC = vtepMAC
    }
}

public struct FlannelLocalNodeNetwork: Codable, Sendable, Hashable {
    public var nodeName: String
    public var podCIDR: String
    public var subnetBase: String
    public var internalIP: String?

    public init(nodeName: String, podCIDR: String, subnetBase: String, internalIP: String? = nil) {
        self.nodeName = nodeName
        self.podCIDR = podCIDR
        self.subnetBase = subnetBase
        self.internalIP = internalIP
    }
}

public struct FlannelPeer: Codable, Sendable, Hashable, Comparable {
    public var nodeName: String
    public var operatingSystem: String?
    public var podCIDR: String
    public var subnetBase: String
    public var publicIP: String
    public var vni: Int
    public var vtepMAC: String

    public init(
        nodeName: String,
        operatingSystem: String? = nil,
        podCIDR: String,
        subnetBase: String,
        publicIP: String,
        vni: Int,
        vtepMAC: String
    ) {
        self.nodeName = nodeName
        self.operatingSystem = operatingSystem
        self.podCIDR = podCIDR
        self.subnetBase = subnetBase
        self.publicIP = publicIP
        self.vni = vni
        self.vtepMAC = vtepMAC
    }

    public static func < (lhs: FlannelPeer, rhs: FlannelPeer) -> Bool {
        if lhs.podCIDR != rhs.podCIDR {
            return lhs.podCIDR < rhs.podCIDR
        }
        return lhs.nodeName < rhs.nodeName
    }
}

public struct FlannelLocalNodeIPv6Network: Codable, Sendable, Hashable {
    public var nodeName: String
    public var podCIDR: String
    public var subnetBase: String
    public var internalIPv6: String?

    public init(nodeName: String, podCIDR: String, subnetBase: String, internalIPv6: String? = nil) {
        self.nodeName = nodeName
        self.podCIDR = podCIDR
        self.subnetBase = subnetBase
        self.internalIPv6 = internalIPv6
    }
}

public struct FlannelIPv6Peer: Codable, Sendable, Hashable, Comparable {
    public var nodeName: String
    public var operatingSystem: String?
    public var podCIDR: String
    public var subnetBase: String
    public var publicIPv6: String
    public var vni: Int
    public var vtepMAC: String

    public init(
        nodeName: String,
        operatingSystem: String? = nil,
        podCIDR: String,
        subnetBase: String,
        publicIPv6: String,
        vni: Int,
        vtepMAC: String
    ) {
        self.nodeName = nodeName
        self.operatingSystem = operatingSystem
        self.podCIDR = podCIDR
        self.subnetBase = subnetBase
        self.publicIPv6 = publicIPv6
        self.vni = vni
        self.vtepMAC = vtepMAC
    }

    public static func < (lhs: FlannelIPv6Peer, rhs: FlannelIPv6Peer) -> Bool {
        if lhs.podCIDR != rhs.podCIDR {
            return lhs.podCIDR < rhs.podCIDR
        }
        return lhs.nodeName < rhs.nodeName
    }
}

public enum FlannelCompileIssueSeverity: String, Codable, Sendable, Hashable, Comparable {
    case pending
    case warning
    case error

    public static func < (lhs: FlannelCompileIssueSeverity, rhs: FlannelCompileIssueSeverity) -> Bool {
        let rank: [FlannelCompileIssueSeverity: Int] = [.pending: 0, .warning: 1, .error: 2]
        return rank[lhs, default: 0] < rank[rhs, default: 0]
    }
}

public struct FlannelCompileIssue: Codable, Sendable, Hashable, Comparable {
    public var id: String
    public var severity: FlannelCompileIssueSeverity
    public var message: String

    public init(id: String, severity: FlannelCompileIssueSeverity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }

    public static func < (lhs: FlannelCompileIssue, rhs: FlannelCompileIssue) -> Bool {
        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }
        if lhs.severity != rhs.severity {
            return lhs.severity < rhs.severity
        }
        return lhs.message < rhs.message
    }
}

public struct FlannelPeerCompilation: Codable, Sendable, Hashable {
    public var localNetwork: FlannelLocalNodeNetwork?
    public var peers: [FlannelPeer]
    public var localIPv6Network: FlannelLocalNodeIPv6Network?
    public var ipv6Peers: [FlannelIPv6Peer]
    public var issues: [FlannelCompileIssue]

    private enum CodingKeys: String, CodingKey {
        case localNetwork
        case peers
        case localIPv6Network
        case ipv6Peers
        case issues
    }

    public init(
        localNetwork: FlannelLocalNodeNetwork? = nil,
        peers: [FlannelPeer] = [],
        localIPv6Network: FlannelLocalNodeIPv6Network? = nil,
        ipv6Peers: [FlannelIPv6Peer] = [],
        issues: [FlannelCompileIssue] = []
    ) {
        self.localNetwork = localNetwork
        self.peers = peers
        self.localIPv6Network = localIPv6Network
        self.ipv6Peers = ipv6Peers
        self.issues = issues
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            localNetwork: try container.decodeIfPresent(FlannelLocalNodeNetwork.self, forKey: .localNetwork),
            peers: try container.decodeIfPresent([FlannelPeer].self, forKey: .peers) ?? [],
            localIPv6Network: try container.decodeIfPresent(
                FlannelLocalNodeIPv6Network.self,
                forKey: .localIPv6Network
            ),
            ipv6Peers: try container.decodeIfPresent([FlannelIPv6Peer].self, forKey: .ipv6Peers) ?? [],
            issues: try container.decodeIfPresent([FlannelCompileIssue].self, forKey: .issues) ?? []
        )
    }
}

public enum FlannelReadyState: String, Codable, Sendable, Hashable {
    case starting
    case waitingForConfiguration
    case waitingForLocalNode
    case waitingForPodCIDR
    case waitingForVTEPMAC
    case reconcilingPeers
    case ready
    case degraded
    case stopped
}

public struct FlannelNodeAnnotationPatch: Sendable, Equatable {
    public var values: [String: String]
    public var removals: Set<String>

    public init(values: [String: String] = [:], removals: Set<String> = []) {
        self.values = values
        self.removals = removals
    }

    public func validate() throws {
        guard Set(values.keys).isDisjoint(with: removals) else {
            throw FlannelVXLANError.invalidConfiguration("an annotation cannot be set and removed in one patch")
        }
        guard values.keys.allSatisfy({ !$0.isEmpty }) && removals.allSatisfy({ !$0.isEmpty }) else {
            throw FlannelVXLANError.invalidConfiguration("annotation keys cannot be empty")
        }
    }
}

public enum FlannelVTEPMAC {
    public static func normalize(_ value: String) -> String? {
        let components = value.lowercased().split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard components.count == 6 else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        for component in components {
            guard component.count == 2, let byte = UInt8(component, radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        guard bytes[0] & 0x01 == 0, bytes.contains(where: { $0 != 0 }) else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func isLocallyAdministeredUnicast(_ value: String) -> Bool {
        guard let normalized = normalize(value), let first = UInt8(normalized.prefix(2), radix: 16) else {
            return false
        }
        return first & 0x03 == 0x02
    }
}

enum FlannelIPv4 {
    struct CIDR: Sendable, Hashable {
        var network: UInt32
        var prefixLength: Int

        var string: String {
            "\(format(network))/\(prefixLength)"
        }

        var baseAddress: String {
            format(network)
        }

        func contains(_ other: CIDR) -> Bool {
            prefixLength <= other.prefixLength && network == other.network & mask(prefixLength)
        }

        func overlaps(_ other: CIDR) -> Bool {
            let commonPrefix = min(prefixLength, other.prefixLength)
            return network & mask(commonPrefix) == other.network & mask(commonPrefix)
        }
    }

    static func parseCIDR(_ value: String) -> CIDR? {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
            let address = parseAddress(String(components[0])),
            let prefixLength = Int(components[1]),
            (0...32).contains(prefixLength)
        else {
            return nil
        }
        return CIDR(network: address & mask(prefixLength), prefixLength: prefixLength)
    }

    static func parseAddress(_ value: String) -> UInt32? {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return nil
        }

        var address: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet), String(byte) == octet else {
                return nil
            }
            address = address << 8 | UInt32(byte)
        }
        return address
    }

    private static func mask(_ prefixLength: Int) -> UInt32 {
        prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength)
    }

    private static func format(_ address: UInt32) -> String {
        [24, 16, 8, 0]
            .map { String((address >> UInt32($0)) & 0xff) }
            .joined(separator: ".")
    }
}

enum FlannelIPv6 {
    struct Address: Sendable, Hashable {
        fileprivate var bytes: [UInt8]

        var string: String {
            FlannelIPv6.format(bytes) ?? "<invalid>"
        }

        var isUnspecified: Bool {
            bytes.allSatisfy { $0 == 0 }
        }

        var isMulticast: Bool {
            bytes.first == 0xff
        }

        var isLoopback: Bool {
            bytes.count == 16 && bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }

        var isLinkLocal: Bool {
            bytes.count == 16 && bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        }

        var isIPv4Mapped: Bool {
            bytes.count == 16
                && bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff
                && bytes[11] == 0xff
        }

        var isUsableUnderlayAddress: Bool {
            !isUnspecified && !isMulticast && !isLoopback && !isLinkLocal && !isIPv4Mapped
        }
    }

    struct CIDR: Sendable, Hashable {
        var network: Address
        var prefixLength: Int

        var string: String {
            "\(network.string)/\(prefixLength)"
        }

        var baseAddress: String {
            network.string
        }

        func contains(_ other: CIDR) -> Bool {
            prefixLength <= other.prefixLength
                && FlannelIPv6.prefixMatches(network.bytes, other.network.bytes, prefixLength: prefixLength)
        }

        func overlaps(_ other: CIDR) -> Bool {
            FlannelIPv6.prefixMatches(
                network.bytes,
                other.network.bytes,
                prefixLength: min(prefixLength, other.prefixLength)
            )
        }
    }

    static func parseCIDR(_ value: String) -> CIDR? {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
            let address = parseAddress(String(components[0])),
            let prefixLength = Int(components[1]),
            (0...128).contains(prefixLength)
        else {
            return nil
        }
        return CIDR(
            network: Address(bytes: masked(address.bytes, prefixLength: prefixLength)),
            prefixLength: prefixLength
        )
    }

    static func parseAddress(_ value: String) -> Address? {
        var address = in6_addr()
        let parsed = value.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else {
            return nil
        }
        return Address(bytes: withUnsafeBytes(of: &address) { Array($0) })
    }

    private static func masked(_ bytes: [UInt8], prefixLength: Int) -> [UInt8] {
        var result = bytes
        let completeBytes = prefixLength / 8
        let remainingBits = prefixLength % 8
        if remainingBits > 0 {
            result[completeBytes] &= UInt8.max << UInt8(8 - remainingBits)
        }
        let firstClearedByte = completeBytes + (remainingBits > 0 ? 1 : 0)
        if firstClearedByte < result.count {
            for index in firstClearedByte..<result.count {
                result[index] = 0
            }
        }
        return result
    }

    private static func prefixMatches(_ lhs: [UInt8], _ rhs: [UInt8], prefixLength: Int) -> Bool {
        guard lhs.count == 16, rhs.count == 16 else {
            return false
        }
        let completeBytes = prefixLength / 8
        guard lhs.prefix(completeBytes).elementsEqual(rhs.prefix(completeBytes)) else {
            return false
        }
        let remainingBits = prefixLength % 8
        guard remainingBits > 0 else {
            return true
        }
        let mask = UInt8.max << UInt8(8 - remainingBits)
        return lhs[completeBytes] & mask == rhs[completeBytes] & mask
    }

    private static func format(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else {
            return nil
        }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { destination in
            destination.copyBytes(from: bytes)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        return String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
