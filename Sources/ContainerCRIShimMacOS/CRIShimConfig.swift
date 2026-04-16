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

public struct CRIShimConfig: Codable, Equatable, Sendable {
    public var runtimeEndpoint: String?
    public var streaming: StreamingConfig?
    public var cni: CNIConfig?
    public var defaults: RuntimeProfile?
    public var runtimeHandlers: [String: RuntimeProfile]
    public var networkPolicy: NetworkPolicyConfig?
    public var kubeProxy: KubeProxyConfig?

    public init(
        runtimeEndpoint: String? = nil,
        streaming: StreamingConfig? = nil,
        cni: CNIConfig? = nil,
        defaults: RuntimeProfile? = nil,
        runtimeHandlers: [String: RuntimeProfile] = [:],
        networkPolicy: NetworkPolicyConfig? = nil,
        kubeProxy: KubeProxyConfig? = nil
    ) {
        self.runtimeEndpoint = runtimeEndpoint
        self.streaming = streaming
        self.cni = cni
        self.defaults = defaults
        self.runtimeHandlers = runtimeHandlers
        self.networkPolicy = networkPolicy
        self.kubeProxy = kubeProxy
    }

    enum CodingKeys: String, CodingKey {
        case runtimeEndpoint
        case streaming
        case cni
        case defaults
        case runtimeHandlers
        case networkPolicy
        case kubeProxy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeEndpoint = try container.decodeIfPresent(String.self, forKey: .runtimeEndpoint)
        streaming = try container.decodeIfPresent(StreamingConfig.self, forKey: .streaming)
        cni = try container.decodeIfPresent(CNIConfig.self, forKey: .cni)
        defaults = try container.decodeIfPresent(RuntimeProfile.self, forKey: .defaults)
        runtimeHandlers = try container.decodeIfPresent([String: RuntimeProfile].self, forKey: .runtimeHandlers) ?? [:]
        networkPolicy = try container.decodeIfPresent(NetworkPolicyConfig.self, forKey: .networkPolicy)
        kubeProxy = try container.decodeIfPresent(KubeProxyConfig.self, forKey: .kubeProxy)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(runtimeEndpoint, forKey: .runtimeEndpoint)
        try container.encodeIfPresent(streaming, forKey: .streaming)
        try container.encodeIfPresent(cni, forKey: .cni)
        try container.encodeIfPresent(defaults, forKey: .defaults)
        try container.encode(runtimeHandlers, forKey: .runtimeHandlers)
        try container.encodeIfPresent(networkPolicy, forKey: .networkPolicy)
        try container.encodeIfPresent(kubeProxy, forKey: .kubeProxy)
    }

    public static func load(from url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> CRIShimConfig {
        let data = try Data(contentsOf: url)
        return try decoder.decode(CRIShimConfig.self, from: data)
    }

    public var normalizedRuntimeEndpoint: String? {
        runtimeEndpoint?.removingUnixScheme
    }
}

public struct StreamingConfig: Codable, Equatable, Sendable {
    public var address: String?
    public var port: Int?

    public init(address: String? = nil, port: Int? = nil) {
        self.address = address
        self.port = port
    }
}

public struct CNIConfig: Codable, Equatable, Sendable {
    public var binDir: String?
    public var confDir: String?
    public var plugin: String?

    public init(binDir: String? = nil, confDir: String? = nil, plugin: String? = nil) {
        self.binDir = binDir
        self.confDir = confDir
        self.plugin = plugin
    }
}

public struct RuntimeProfile: Codable, Equatable, Sendable {
    public var sandboxImage: String?
    public var workloadPlatform: WorkloadPlatform?
    public var network: String?
    public var guiEnabled: Bool?

    public init(
        sandboxImage: String? = nil,
        workloadPlatform: WorkloadPlatform? = nil,
        network: String? = nil,
        guiEnabled: Bool? = nil
    ) {
        self.sandboxImage = sandboxImage
        self.workloadPlatform = workloadPlatform
        self.network = network
        self.guiEnabled = guiEnabled
    }
}

public struct WorkloadPlatform: Codable, Equatable, Sendable {
    public var os: String?
    public var architecture: String?

    public init(os: String? = nil, architecture: String? = nil) {
        self.os = os
        self.architecture = architecture
    }
}

public struct NetworkPolicyConfig: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var kubeconfig: String?
    public var nodeName: String?
    public var resyncSeconds: Int?

    public init(
        enabled: Bool? = nil,
        kubeconfig: String? = nil,
        nodeName: String? = nil,
        resyncSeconds: Int? = nil
    ) {
        self.enabled = enabled
        self.kubeconfig = kubeconfig
        self.nodeName = nodeName
        self.resyncSeconds = resyncSeconds
    }
}

public struct KubeProxyConfig: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var configPath: String?

    public init(enabled: Bool? = nil, configPath: String? = nil) {
        self.enabled = enabled
        self.configPath = configPath
    }
}
