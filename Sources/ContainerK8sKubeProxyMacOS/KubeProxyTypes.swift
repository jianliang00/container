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
    public var kubeconfig: String
    public var nodeName: String
    public var syncPeriodSeconds: Int
    public var pf: KubeProxyPFConfig

    public init(
        kubeconfig: String,
        nodeName: String,
        syncPeriodSeconds: Int = 5,
        pf: KubeProxyPFConfig = KubeProxyPFConfig()
    ) {
        self.kubeconfig = kubeconfig
        self.nodeName = nodeName
        self.syncPeriodSeconds = syncPeriodSeconds
        self.pf = pf
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
        try pf.validate()
    }
}

public struct KubeProxyPFConfig: Codable, Sendable, Equatable {
    public var anchorName: String
    public var configPath: String
    public var anchorsPath: String
    public var pfctlPath: String

    public init(
        anchorName: String = "com.apple.container.kube-proxy",
        configPath: String = "/etc/pf.conf",
        anchorsPath: String = "/etc/pf.anchors",
        pfctlPath: String = "/sbin/pfctl"
    ) {
        self.anchorName = anchorName
        self.configPath = configPath
        self.anchorsPath = anchorsPath
        self.pfctlPath = pfctlPath
    }

    public func validate() throws {
        guard !anchorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KubeProxyMacOSError.invalidConfiguration("pf.anchorName is required")
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
    public var ports: [KubeProxyServicePort]

    public init(
        type: String? = nil,
        clusterIP: String? = nil,
        clusterIPs: [String]? = nil,
        ipFamilies: [String]? = nil,
        ports: [KubeProxyServicePort] = []
    ) {
        self.type = type
        self.clusterIP = clusterIP
        self.clusterIPs = clusterIPs
        self.ipFamilies = ipFamilies
        self.ports = ports
    }
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
        if terminating == true {
            return false
        }
        if let ready {
            return ready
        }
        if let serving {
            return serving
        }
        return true
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
    public var ip: String
    public var port: Int

    public init(ip: String, port: Int) {
        self.ip = ip
        self.port = port
    }

    public static func < (lhs: KubeProxyBackend, rhs: KubeProxyBackend) -> Bool {
        if lhs.ip != rhs.ip {
            return lhs.ip < rhs.ip
        }
        return lhs.port < rhs.port
    }
}

public struct KubeProxyServiceRule: Codable, Sendable, Hashable, Comparable {
    public var namespace: String
    public var serviceName: String
    public var portName: String?
    public var protocolName: KubeProxyProtocol
    public var clusterIP: String
    public var servicePort: Int
    public var backends: [KubeProxyBackend]

    public init(
        namespace: String,
        serviceName: String,
        portName: String? = nil,
        protocolName: KubeProxyProtocol,
        clusterIP: String,
        servicePort: Int,
        backends: [KubeProxyBackend]
    ) {
        self.namespace = namespace
        self.serviceName = serviceName
        self.portName = portName
        self.protocolName = protocolName
        self.clusterIP = clusterIP
        self.servicePort = servicePort
        self.backends = backends
    }

    public static func < (lhs: KubeProxyServiceRule, rhs: KubeProxyServiceRule) -> Bool {
        let lhsKey = [lhs.namespace, lhs.serviceName, lhs.portName ?? "", lhs.protocolName.rawValue, lhs.clusterIP, "\(lhs.servicePort)"]
        let rhsKey = [rhs.namespace, rhs.serviceName, rhs.portName ?? "", rhs.protocolName.rawValue, rhs.clusterIP, "\(rhs.servicePort)"]
        return lhsKey.lexicographicallyPrecedes(rhsKey)
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
