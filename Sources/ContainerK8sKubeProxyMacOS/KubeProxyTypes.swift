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

public struct KubeProxyMacOSConfig: Codable, Sendable, Equatable {
    public static let defaultStatusPath = "/var/lib/container/kube-proxy-macos/status.json"

    public var kubeconfig: String
    public var nodeName: String
    public var syncPeriodSeconds: Int
    public var dualStackEnabled: Bool
    public var statusPath: String?
    public var pf: KubeProxyPFConfig

    public init(
        kubeconfig: String,
        nodeName: String,
        syncPeriodSeconds: Int = 5,
        dualStackEnabled: Bool = false,
        statusPath: String? = nil,
        pf: KubeProxyPFConfig = KubeProxyPFConfig()
    ) {
        self.kubeconfig = kubeconfig
        self.nodeName = nodeName
        self.syncPeriodSeconds = syncPeriodSeconds
        self.dualStackEnabled = dualStackEnabled
        self.statusPath = statusPath
        self.pf = pf
    }

    private enum CodingKeys: String, CodingKey {
        case kubeconfig
        case nodeName
        case syncPeriodSeconds
        case dualStackEnabled
        case statusPath
        case pf
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kubeconfig = try container.decode(String.self, forKey: .kubeconfig)
        nodeName = try container.decode(String.self, forKey: .nodeName)
        syncPeriodSeconds = try container.decodeIfPresent(Int.self, forKey: .syncPeriodSeconds) ?? 5
        dualStackEnabled = try container.decodeIfPresent(Bool.self, forKey: .dualStackEnabled) ?? false
        statusPath = try container.decodeIfPresent(String.self, forKey: .statusPath)
        pf = try container.decodeIfPresent(KubeProxyPFConfig.self, forKey: .pf) ?? KubeProxyPFConfig()
    }

    public static func load(from url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> KubeProxyMacOSConfig {
        let data = try Data(contentsOf: url)
        let config = try decoder.decode(KubeProxyMacOSConfig.self, from: data)
        try config.validate()
        return config
    }

    public func validate() throws {
        guard !kubeconfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KubeProxyMacOSError.invalidConfiguration("kubeconfig is required")
        }
        guard !nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KubeProxyMacOSError.invalidConfiguration("nodeName is required")
        }
        guard syncPeriodSeconds > 0 else {
            throw KubeProxyMacOSError.invalidConfiguration("syncPeriodSeconds must be greater than zero")
        }
        if let statusPath {
            guard statusPath == Self.defaultStatusPath else {
                throw KubeProxyMacOSError.invalidConfiguration(
                    "statusPath must be \(Self.defaultStatusPath)"
                )
            }
        }
        try pf.validate()
        if dualStackEnabled {
            guard pf.runtimeStatePath != nil, pf.readyStatePath != nil else {
                throw KubeProxyMacOSError.invalidConfiguration(
                    "dualStackEnabled requires pf.runtimeStatePath and pf.readyStatePath"
                )
            }
        }
    }
}

public struct KubeProxyPFConfig: Codable, Sendable, Equatable {
    public var anchorName: String
    public var configPath: String
    public var anchorsPath: String
    public var pfctlPath: String
    public var egressInterface: String?
    public var masqueradeIPv6PodTraffic: Bool?
    public var ipv6EgressInterface: String?
    public var ipv6EgressSourceAddress: String?
    public var vmnetCIDR: String?
    public var runtimeStatePath: String?
    public var readyStatePath: String?

    public init(
        anchorName: String = "com.apple.container.kube-proxy",
        configPath: String = "/etc/pf.conf",
        anchorsPath: String = "/etc/pf.anchors",
        pfctlPath: String = "/sbin/pfctl",
        egressInterface: String? = nil,
        masqueradeIPv6PodTraffic: Bool? = nil,
        ipv6EgressInterface: String? = nil,
        ipv6EgressSourceAddress: String? = nil,
        vmnetCIDR: String? = "192.168.64.0/24",
        runtimeStatePath: String? = nil,
        readyStatePath: String? = nil
    ) {
        self.anchorName = anchorName
        self.configPath = configPath
        self.anchorsPath = anchorsPath
        self.pfctlPath = pfctlPath
        self.egressInterface = egressInterface
        self.masqueradeIPv6PodTraffic = masqueradeIPv6PodTraffic
        self.ipv6EgressInterface = ipv6EgressInterface
        self.ipv6EgressSourceAddress = ipv6EgressSourceAddress
        self.vmnetCIDR = vmnetCIDR
        self.runtimeStatePath = runtimeStatePath
        self.readyStatePath = readyStatePath
    }

    public var configuredEgressInterface: String? {
        guard let value = egressInterface?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
    public var configuredIPv6EgressInterface: String? {
        guard let value = ipv6EgressInterface?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
    public var configuredIPv6EgressSourceAddress: String? {
        guard let value = ipv6EgressSourceAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
    public var resolvedMasqueradeIPv6PodTraffic: Bool { masqueradeIPv6PodTraffic ?? true }
    public var resolvedVmnetCIDR: String { vmnetCIDR ?? "192.168.64.0/24" }
    public var ipv6AnchorName: String { "\(anchorName).ipv6" }

    public func validate() throws {
        guard anchorName.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw KubeProxyMacOSError.invalidConfiguration("pf.anchorName is not a valid PF anchor name")
        }
        for (name, path) in [
            ("pf.configPath", configPath),
            ("pf.anchorsPath", anchorsPath),
            ("pf.pfctlPath", pfctlPath),
        ] {
            guard path.hasPrefix("/") else {
                throw KubeProxyMacOSError.invalidConfiguration("\(name) must be an absolute path")
            }
        }
        if let configuredEgressInterface {
            guard configuredEgressInterface.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw KubeProxyMacOSError.invalidConfiguration("pf.egressInterface is not a valid interface name")
            }
        }
        guard
            masqueradeIPv6PodTraffic != false
                || (ipv6EgressInterface == nil && ipv6EgressSourceAddress == nil)
        else {
            throw KubeProxyMacOSError.invalidConfiguration(
                "pf.masqueradeIPv6PodTraffic=false cannot be combined with pf.ipv6EgressInterface or pf.ipv6EgressSourceAddress"
            )
        }
        if let configuredIPv6EgressInterface {
            guard configuredIPv6EgressInterface.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw KubeProxyMacOSError.invalidConfiguration("pf.ipv6EgressInterface is not a valid interface name")
            }
        }
        if let configuredIPv6EgressSourceAddress {
            guard KubeProxyIPv6CIDR.canonicalize("\(configuredIPv6EgressSourceAddress)/128") != nil else {
                throw KubeProxyMacOSError.invalidConfiguration(
                    "pf.ipv6EgressSourceAddress is not a valid IPv6 address"
                )
            }
        }
        guard KubeProxyIPv4CIDR.canonicalize(resolvedVmnetCIDR) != nil else {
            throw KubeProxyMacOSError.invalidConfiguration("pf.vmnetCIDR is not a valid IPv4 CIDR")
        }

        let runtimeStatePath = runtimeStatePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let readyStatePath = readyStatePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if runtimeStatePath != nil || readyStatePath != nil {
            guard let runtimeStatePath, runtimeStatePath.hasPrefix("/") else {
                throw KubeProxyMacOSError.invalidConfiguration("pf.runtimeStatePath must be an absolute path")
            }
            guard let readyStatePath, readyStatePath.hasPrefix("/") else {
                throw KubeProxyMacOSError.invalidConfiguration("pf.readyStatePath must be an absolute path")
            }
        }
    }
}

public enum KubeProxyMacOSError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidKubeconfig(String)
    case unsupported(String)
    case applyFailed(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            "invalid kube-proxy macOS config: \(message)"
        case .invalidKubeconfig(let message):
            "invalid kubeconfig: \(message)"
        case .unsupported(let message):
            "unsupported kube-proxy macOS input: \(message)"
        case .applyFailed(let message):
            "failed to apply kube-proxy macOS rules: \(message)"
        }
    }
}

enum KubeProxyPodIngressRouteTransitionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(KubeProxyAddressFamily)
    case unavailableAfterWithdrawal(KubeProxyAddressFamily)

    var description: String {
        switch self {
        case .unavailable(let family):
            "local \(family.rawValue) PodCIDR route is not directly connected"
        case .unavailableAfterWithdrawal(let family):
            "local \(family.rawValue) PodCIDR route is not directly connected; managed PF rules were withdrawn"
        }
    }
}

public enum KubeProxyProtocol: String, Codable, Sendable, Hashable, Comparable {
    case tcp = "TCP"
    case udp = "UDP"

    public static func < (lhs: KubeProxyProtocol, rhs: KubeProxyProtocol) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var pfName: String {
        switch self {
        case .tcp: "tcp"
        case .udp: "udp"
        }
    }
}

public enum KubeProxyAddressFamily: String, Codable, Sendable, Hashable, Comparable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"

    public static func < (lhs: KubeProxyAddressFamily, rhs: KubeProxyAddressFamily) -> Bool {
        switch (lhs, rhs) {
        case (.ipv4, .ipv6):
            true
        case (.ipv6, .ipv4), (.ipv4, .ipv4), (.ipv6, .ipv6):
            false
        }
    }

    public var pfName: String {
        switch self {
        case .ipv4: "inet"
        case .ipv6: "inet6"
        }
    }

    public var tableNameComponent: String {
        switch self {
        case .ipv4: "v4"
        case .ipv6: "v6"
        }
    }
}

public enum KubeProxyIntOrString: Codable, Sendable, Hashable {
    case int(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        self = .string(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

public struct KubeProxyObjectMeta: Codable, Sendable, Hashable {
    public var namespace: String?
    public var name: String?
    public var uid: String?
    public var labels: [String: String]?

    public init(namespace: String? = nil, name: String? = nil, uid: String? = nil, labels: [String: String]? = nil) {
        self.namespace = namespace
        self.name = name
        self.uid = uid
        self.labels = labels
    }
}

public struct KubeProxyServiceList: Codable, Sendable, Hashable {
    public var items: [KubeProxyService]

    public init(items: [KubeProxyService]) {
        self.items = items
    }
}

public struct KubeProxyService: Codable, Sendable, Hashable {
    public var metadata: KubeProxyObjectMeta
    public var spec: KubeProxyServiceSpec?

    public init(metadata: KubeProxyObjectMeta, spec: KubeProxyServiceSpec?) {
        self.metadata = metadata
        self.spec = spec
    }
}

public struct KubeProxyServiceSpec: Codable, Sendable, Hashable {
    public var type: String?
    public var clusterIP: String?
    public var clusterIPs: [String]?
    public var ipFamilies: [String]?
    public var internalTrafficPolicy: KubeProxyInternalTrafficPolicy?
    public var ports: [KubeProxyServicePort]

    public init(
        type: String? = nil,
        clusterIP: String? = nil,
        clusterIPs: [String]? = nil,
        ipFamilies: [String]? = nil,
        internalTrafficPolicy: KubeProxyInternalTrafficPolicy? = nil,
        ports: [KubeProxyServicePort] = []
    ) {
        self.type = type
        self.clusterIP = clusterIP
        self.clusterIPs = clusterIPs
        self.ipFamilies = ipFamilies
        self.internalTrafficPolicy = internalTrafficPolicy
        self.ports = ports
    }
}

public enum KubeProxyInternalTrafficPolicy: String, Codable, Sendable, Hashable {
    case cluster = "Cluster"
    case local = "Local"
}

public struct KubeProxyServicePort: Codable, Sendable, Hashable {
    public var name: String?
    public var protocolName: KubeProxyProtocol?
    public var port: Int
    public var targetPort: KubeProxyIntOrString?

    enum CodingKeys: String, CodingKey {
        case name
        case protocolName = "protocol"
        case port
        case targetPort
    }

    public init(
        name: String? = nil,
        protocolName: KubeProxyProtocol? = nil,
        port: Int,
        targetPort: KubeProxyIntOrString? = nil
    ) {
        self.name = name
        self.protocolName = protocolName
        self.port = port
        self.targetPort = targetPort
    }
}

public struct KubeProxyEndpointSliceList: Codable, Sendable, Hashable {
    public var items: [KubeProxyEndpointSlice]

    public init(items: [KubeProxyEndpointSlice]) {
        self.items = items
    }
}

public struct KubeProxyEndpointSlice: Codable, Sendable, Hashable {
    public var metadata: KubeProxyObjectMeta
    public var addressType: String
    public var endpoints: [KubeProxyEndpoint]
    public var ports: [KubeProxyEndpointPort]

    private enum CodingKeys: String, CodingKey {
        case metadata
        case addressType
        case endpoints
        case ports
    }

    public init(
        metadata: KubeProxyObjectMeta,
        addressType: String = "IPv4",
        endpoints: [KubeProxyEndpoint],
        ports: [KubeProxyEndpointPort]
    ) {
        self.metadata = metadata
        self.addressType = addressType
        self.endpoints = endpoints
        self.ports = ports
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            metadata: try container.decode(KubeProxyObjectMeta.self, forKey: .metadata),
            addressType: try container.decode(String.self, forKey: .addressType),
            endpoints: try container.decodeIfPresent([KubeProxyEndpoint].self, forKey: .endpoints) ?? [],
            ports: try container.decodeIfPresent([KubeProxyEndpointPort].self, forKey: .ports) ?? []
        )
    }
}

public struct KubeProxyEndpoint: Codable, Sendable, Hashable {
    public var addresses: [String]
    public var conditions: KubeProxyEndpointConditions?
    public var nodeName: String?

    public init(addresses: [String], conditions: KubeProxyEndpointConditions? = nil, nodeName: String? = nil) {
        self.addresses = addresses
        self.conditions = conditions
        self.nodeName = nodeName
    }
}

public struct KubeProxyEndpointConditions: Codable, Sendable, Hashable {
    public var ready: Bool?
    public var serving: Bool?
    public var terminating: Bool?

    public init(ready: Bool? = nil, serving: Bool? = nil, terminating: Bool? = nil) {
        self.ready = ready
        self.serving = serving
        self.terminating = terminating
    }

    public var isUsable: Bool {
        terminating != true && ready != false && serving != false
    }
}

public struct KubeProxyEndpointPort: Codable, Sendable, Hashable {
    public var name: String?
    public var protocolName: KubeProxyProtocol?
    public var port: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case protocolName = "protocol"
        case port
    }

    public init(name: String? = nil, protocolName: KubeProxyProtocol? = nil, port: Int?) {
        self.name = name
        self.protocolName = protocolName
        self.port = port
    }
}

public struct KubeProxySnapshot: Codable, Sendable, Hashable {
    public var services: [KubeProxyService]
    public var endpointSlices: [KubeProxyEndpointSlice]

    public init(services: [KubeProxyService] = [], endpointSlices: [KubeProxyEndpointSlice] = []) {
        self.services = services
        self.endpointSlices = endpointSlices
    }
}

public struct KubeProxyBackend: Codable, Sendable, Hashable, Comparable {
    public var family: KubeProxyAddressFamily
    public var ip: String
    public var port: Int

    public init(family: KubeProxyAddressFamily = .ipv4, ip: String, port: Int) {
        self.family = family
        self.ip = ip
        self.port = port
    }

    public static func < (lhs: KubeProxyBackend, rhs: KubeProxyBackend) -> Bool {
        if lhs.family != rhs.family {
            return lhs.family < rhs.family
        }
        if lhs.ip != rhs.ip {
            return lhs.ip < rhs.ip
        }
        return lhs.port < rhs.port
    }

    enum CodingKeys: String, CodingKey {
        case family
        case ip
        case port
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            family: try container.decodeIfPresent(KubeProxyAddressFamily.self, forKey: .family) ?? .ipv4,
            ip: try container.decode(String.self, forKey: .ip),
            port: try container.decode(Int.self, forKey: .port)
        )
    }
}

public struct KubeProxyServiceRule: Codable, Sendable, Hashable, Comparable {
    public var namespace: String
    public var serviceName: String
    public var portName: String?
    public var protocolName: KubeProxyProtocol
    public var family: KubeProxyAddressFamily
    public var clusterIP: String
    public var servicePort: Int
    public var backends: [KubeProxyBackend]

    public init(
        namespace: String,
        serviceName: String,
        portName: String? = nil,
        protocolName: KubeProxyProtocol,
        family: KubeProxyAddressFamily = .ipv4,
        clusterIP: String,
        servicePort: Int,
        backends: [KubeProxyBackend]
    ) {
        self.namespace = namespace
        self.serviceName = serviceName
        self.portName = portName
        self.protocolName = protocolName
        self.family = family
        self.clusterIP = clusterIP
        self.servicePort = servicePort
        self.backends = backends
    }

    public static func < (lhs: KubeProxyServiceRule, rhs: KubeProxyServiceRule) -> Bool {
        let lhsKey = [
            lhs.namespace,
            lhs.serviceName,
            lhs.portName ?? "",
            lhs.protocolName.rawValue,
            lhs.family.rawValue,
            lhs.clusterIP,
            "\(lhs.servicePort)",
        ]
        let rhsKey = [
            rhs.namespace,
            rhs.serviceName,
            rhs.portName ?? "",
            rhs.protocolName.rawValue,
            rhs.family.rawValue,
            rhs.clusterIP,
            "\(rhs.servicePort)",
        ]
        return lhsKey.lexicographicallyPrecedes(rhsKey)
    }

    enum CodingKeys: String, CodingKey {
        case namespace
        case serviceName
        case portName
        case protocolName
        case family
        case clusterIP
        case servicePort
        case backends
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            namespace: try container.decode(String.self, forKey: .namespace),
            serviceName: try container.decode(String.self, forKey: .serviceName),
            portName: try container.decodeIfPresent(String.self, forKey: .portName),
            protocolName: try container.decode(KubeProxyProtocol.self, forKey: .protocolName),
            family: try container.decodeIfPresent(KubeProxyAddressFamily.self, forKey: .family) ?? .ipv4,
            clusterIP: try container.decode(String.self, forKey: .clusterIP),
            servicePort: try container.decode(Int.self, forKey: .servicePort),
            backends: try container.decode([KubeProxyBackend].self, forKey: .backends)
        )
    }
}

public struct KubeProxyRuleSet: Codable, Sendable, Hashable {
    public var generation: Int
    public var rules: [KubeProxyServiceRule]
    public var issues: [KubeProxyCompileIssue]

    public init(generation: Int = 0, rules: [KubeProxyServiceRule] = [], issues: [KubeProxyCompileIssue] = []) {
        self.generation = generation
        self.rules = rules
        self.issues = issues
    }
}

extension KubeProxyRuleSet {
    func selecting(families: Set<KubeProxyAddressFamily>) -> KubeProxyRuleSet {
        KubeProxyRuleSet(
            generation: generation,
            rules: rules.filter { families.contains($0.family) },
            issues: issues
        )
    }
}

public struct KubeProxyCompileIssue: Codable, Sendable, Hashable, Comparable {
    public var id: String
    public var message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }

    public static func < (lhs: KubeProxyCompileIssue, rhs: KubeProxyCompileIssue) -> Bool {
        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }
        return lhs.message < rhs.message
    }
}
