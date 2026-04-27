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

public enum CRIShimConfigDefaults {
    public static let fileName = "container-cri-shim-macos-config.json"
    public static let systemConfigURL = URL(fileURLWithPath: "/etc/container/\(fileName)")
    public static let legacySystemConfigURL = URL(fileURLWithPath: "/etc/\(fileName)")
    public static let stateDirectoryURL = URL(fileURLWithPath: "/var/lib/container/cri-shim-macos")
    public static let userConfigURL = URL(
        fileURLWithPath: ("~/.config/container/\(fileName)" as NSString).expandingTildeInPath
    )

    public static var defaultSearchURLs: [URL] {
        [
            systemConfigURL,
            legacySystemConfigURL,
            userConfigURL,
        ]
    }
}

public struct CRIShimConfigLoadResult: Equatable, Sendable {
    public var config: CRIShimConfig
    public var sourceURL: URL

    public init(config: CRIShimConfig, sourceURL: URL) {
        self.config = config
        self.sourceURL = sourceURL
    }
}

public struct CRIShimConfigLoadError: Error, Equatable, CustomStringConvertible, Sendable {
    public var searchedPaths: [String]

    public init(searchedPaths: [String]) {
        self.searchedPaths = searchedPaths
    }

    public var description: String {
        "CRI shim config file not found; searched: " + searchedPaths.joined(separator: ", ")
    }
}

public struct CRIShimConfig: Codable, Equatable, Sendable {
    public var runtimeEndpoint: String?
    public var stateDirectory: String?
    public var streaming: StreamingConfig?
    public var cni: CNIConfig?
    public var defaults: RuntimeProfile?
    public var runtimeHandlers: [String: RuntimeProfile]
    public var networkPolicy: NetworkPolicyConfig?
    public var kubeProxy: KubeProxyConfig?

    public init(
        runtimeEndpoint: String? = nil,
        stateDirectory: String? = nil,
        streaming: StreamingConfig? = nil,
        cni: CNIConfig? = nil,
        defaults: RuntimeProfile? = nil,
        runtimeHandlers: [String: RuntimeProfile] = [:],
        networkPolicy: NetworkPolicyConfig? = nil,
        kubeProxy: KubeProxyConfig? = nil
    ) {
        self.runtimeEndpoint = runtimeEndpoint
        self.stateDirectory = stateDirectory
        self.streaming = streaming
        self.cni = cni
        self.defaults = defaults
        self.runtimeHandlers = runtimeHandlers
        self.networkPolicy = networkPolicy
        self.kubeProxy = kubeProxy
    }

    enum CodingKeys: String, CodingKey {
        case runtimeEndpoint
        case stateDirectory
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
        stateDirectory = try container.decodeIfPresent(String.self, forKey: .stateDirectory)
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
        try container.encodeIfPresent(stateDirectory, forKey: .stateDirectory)
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

    public static func loadFromSearchPath(
        _ searchURLs: [URL] = CRIShimConfigDefaults.defaultSearchURLs,
        fileManager: FileManager = .default,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> CRIShimConfigLoadResult {
        for url in searchURLs {
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            return try CRIShimConfigLoadResult(
                config: load(from: url, decoder: decoder),
                sourceURL: url
            )
        }

        throw CRIShimConfigLoadError(searchedPaths: searchURLs.map(\.path))
    }

    public var normalizedRuntimeEndpoint: String? {
        runtimeEndpoint?.removingUnixScheme
    }

    public var normalizedStateDirectory: String {
        guard let stateDirectory = stateDirectory?.trimmed, !stateDirectory.isEmpty else {
            return CRIShimConfigDefaults.stateDirectoryURL.path
        }
        return stateDirectory
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
    public var networkBackend: String?
    public var guiEnabled: Bool?
    public var resources: RuntimeResources?

    public init(
        sandboxImage: String? = nil,
        workloadPlatform: WorkloadPlatform? = nil,
        network: String? = nil,
        networkBackend: String? = nil,
        guiEnabled: Bool? = nil,
        resources: RuntimeResources? = nil
    ) {
        self.sandboxImage = sandboxImage
        self.workloadPlatform = workloadPlatform
        self.network = network
        self.networkBackend = networkBackend
        self.guiEnabled = guiEnabled
        self.resources = resources
    }
}

public struct RuntimeResources: Codable, Equatable, Sendable {
    public static let defaultMacOSMemoryInBytes: UInt64 = 8 * 1024 * 1024 * 1024

    public var cpus: Int?
    public var memoryInBytes: UInt64?

    public init(cpus: Int? = nil, memoryInBytes: UInt64? = nil) {
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
    }

    public static var macOSDefault: RuntimeResources {
        RuntimeResources(cpus: 4, memoryInBytes: defaultMacOSMemoryInBytes)
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
