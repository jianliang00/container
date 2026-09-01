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

import ContainerResource
import Foundation

public enum CRIShimConfigDefaults {
    public static let fileName = "container-cri-shim-macos-config.json"
    public static let systemConfigURL = URL(fileURLWithPath: "/etc/container/\(fileName)")
    public static let legacySystemConfigURL = URL(fileURLWithPath: "/etc/\(fileName)")
    public static let stateDirectoryURL = URL(fileURLWithPath: "/var/lib/container/cri-shim-macos")
    public static let machineStateStorageRootURL = URL(
        fileURLWithPath: "/var/lib/container/cri-shim-macos/machine-state/v1"
    )
    public static let machineStateControlSocketRootURL = URL(
        fileURLWithPath: "/var/run/container/machine-state/v1"
    )
    public static let vmnetRecoveryStateURL = URL(fileURLWithPath: "/var/lib/container/vmnet-recovery/state.json")
    public static let vmnetRecoveryRequestURL = URL(
        fileURLWithPath: "/var/lib/container/vmnet-recovery/requests/fence.json"
    )
    public static let vmnetRecoveryStatusURL = URL(
        fileURLWithPath: "/var/lib/container/vmnet-recovery/status.json"
    )
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
    public var podNetwork: PodNetworkConfig?
    public var machineState: MachineStateConfig?

    public init(
        runtimeEndpoint: String? = nil,
        stateDirectory: String? = nil,
        streaming: StreamingConfig? = nil,
        cni: CNIConfig? = nil,
        defaults: RuntimeProfile? = nil,
        runtimeHandlers: [String: RuntimeProfile] = [:],
        networkPolicy: NetworkPolicyConfig? = nil,
        kubeProxy: KubeProxyConfig? = nil,
        podNetwork: PodNetworkConfig? = nil,
        machineState: MachineStateConfig? = nil
    ) {
        self.runtimeEndpoint = runtimeEndpoint
        self.stateDirectory = stateDirectory
        self.streaming = streaming
        self.cni = cni
        self.defaults = defaults
        self.runtimeHandlers = runtimeHandlers
        self.networkPolicy = networkPolicy
        self.kubeProxy = kubeProxy
        self.podNetwork = podNetwork
        self.machineState = machineState
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
        case podNetwork
        case machineState
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
        podNetwork = try container.decodeIfPresent(PodNetworkConfig.self, forKey: .podNetwork)
        machineState = try container.decodeIfPresent(MachineStateConfig.self, forKey: .machineState)
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
        try container.encodeIfPresent(podNetwork, forKey: .podNetwork)
        try container.encodeIfPresent(machineState, forKey: .machineState)
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

public struct MachineStateConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var storageRoot: String?
    public var controlSocketRoot: String?
    public var nbdSocketAllowedRoots: [String]

    public init(
        enabled: Bool = false,
        storageRoot: String? = nil,
        controlSocketRoot: String? = nil,
        nbdSocketAllowedRoots: [String] = []
    ) {
        self.enabled = enabled
        self.storageRoot = storageRoot
        self.controlSocketRoot = controlSocketRoot
        self.nbdSocketAllowedRoots = nbdSocketAllowedRoots
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case storageRoot
        case controlSocketRoot
        case nbdSocketAllowedRoots
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        storageRoot = try container.decodeIfPresent(String.self, forKey: .storageRoot)
        controlSocketRoot = try container.decodeIfPresent(String.self, forKey: .controlSocketRoot)
        nbdSocketAllowedRoots = try container.decodeIfPresent([String].self, forKey: .nbdSocketAllowedRoots) ?? []
    }

    public var normalizedStorageRoot: String {
        guard let storageRoot, !storageRoot.trimmed.isEmpty else {
            return CRIShimConfigDefaults.machineStateStorageRootURL.path
        }
        return storageRoot.trimmed
    }

    public var normalizedControlSocketRoot: String {
        guard let controlSocketRoot, !controlSocketRoot.trimmed.isEmpty else {
            return CRIShimConfigDefaults.machineStateControlSocketRootURL.path
        }
        return controlSocketRoot.trimmed
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
    public var networkMTU: UInt32?
    public var guiEnabled: Bool?
    public var resources: RuntimeResources?

    public init(
        sandboxImage: String? = nil,
        workloadPlatform: WorkloadPlatform? = nil,
        network: String? = nil,
        networkBackend: String? = nil,
        networkMTU: UInt32? = nil,
        guiEnabled: Bool? = nil,
        resources: RuntimeResources? = nil
    ) {
        self.sandboxImage = sandboxImage
        self.workloadPlatform = workloadPlatform
        self.network = network
        self.networkBackend = networkBackend
        self.networkMTU = networkMTU
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

public struct PodNetworkConfig: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var dualStackEnabled: Bool
    public var vmnetDisconnectRecovery: ContainerConfiguration.MacOSGuestOptions.VMNetDisconnectRecovery
    public var networkName: String?
    public var runtimeStatePath: String?
    public var readyStatePath: String?
    public var vmnetRecovery: VMNetRecoveryConfig?

    public init(
        enabled: Bool? = nil,
        dualStackEnabled: Bool = false,
        vmnetDisconnectRecovery: ContainerConfiguration.MacOSGuestOptions.VMNetDisconnectRecovery = .disabled,
        networkName: String? = nil,
        runtimeStatePath: String? = nil,
        readyStatePath: String? = nil,
        vmnetRecovery: VMNetRecoveryConfig? = nil
    ) {
        self.enabled = enabled
        self.dualStackEnabled = dualStackEnabled
        self.vmnetDisconnectRecovery = vmnetDisconnectRecovery
        self.networkName = networkName
        self.runtimeStatePath = runtimeStatePath
        self.readyStatePath = readyStatePath
        self.vmnetRecovery = vmnetRecovery
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case dualStackEnabled
        case vmnetDisconnectRecovery
        case networkName
        case runtimeStatePath
        case readyStatePath
        case vmnetRecovery
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        dualStackEnabled = try container.decodeIfPresent(Bool.self, forKey: .dualStackEnabled) ?? false
        vmnetDisconnectRecovery =
            try container.decodeIfPresent(
                ContainerConfiguration.MacOSGuestOptions.VMNetDisconnectRecovery.self,
                forKey: .vmnetDisconnectRecovery
            ) ?? .disabled
        networkName = try container.decodeIfPresent(String.self, forKey: .networkName)
        runtimeStatePath = try container.decodeIfPresent(String.self, forKey: .runtimeStatePath)
        readyStatePath = try container.decodeIfPresent(String.self, forKey: .readyStatePath)
        vmnetRecovery = try container.decodeIfPresent(VMNetRecoveryConfig.self, forKey: .vmnetRecovery)
    }
}

public struct VMNetRecoveryConfig: Codable, Equatable, Sendable {
    public static let defaultMaxRebootAttempts = 2
    public static let defaultMinimumRebootIntervalSeconds = 120
    public static let defaultAttemptWindowSeconds = 3600
    public static let defaultMaximumRequestAgeSeconds = 900
    public static let defaultVerificationTimeoutSeconds = 300
    public static let defaultPollIntervalSeconds = 2
    public static let defaultHealthyProbeFailureThreshold = 3

    public var nodeName: String?
    public var statePath: String?
    public var requestPath: String?
    public var statusPath: String?
    public var requestWriterUID: Int
    public var maxRebootAttempts: Int
    public var minimumRebootIntervalSeconds: Int
    public var attemptWindowSeconds: Int
    public var maximumRequestAgeSeconds: Int
    public var verificationTimeoutSeconds: Int
    public var pollIntervalSeconds: Int
    public var healthyProbeFailureThreshold: Int

    public init(
        nodeName: String? = nil,
        statePath: String? = nil,
        requestPath: String? = nil,
        statusPath: String? = nil,
        requestWriterUID: Int = 0,
        maxRebootAttempts: Int = Self.defaultMaxRebootAttempts,
        minimumRebootIntervalSeconds: Int = Self.defaultMinimumRebootIntervalSeconds,
        attemptWindowSeconds: Int = Self.defaultAttemptWindowSeconds,
        maximumRequestAgeSeconds: Int = Self.defaultMaximumRequestAgeSeconds,
        verificationTimeoutSeconds: Int = Self.defaultVerificationTimeoutSeconds,
        pollIntervalSeconds: Int = Self.defaultPollIntervalSeconds,
        healthyProbeFailureThreshold: Int = Self.defaultHealthyProbeFailureThreshold
    ) {
        self.nodeName = nodeName
        self.statePath = statePath
        self.requestPath = requestPath
        self.statusPath = statusPath
        self.requestWriterUID = requestWriterUID
        self.maxRebootAttempts = maxRebootAttempts
        self.minimumRebootIntervalSeconds = minimumRebootIntervalSeconds
        self.attemptWindowSeconds = attemptWindowSeconds
        self.maximumRequestAgeSeconds = maximumRequestAgeSeconds
        self.verificationTimeoutSeconds = verificationTimeoutSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.healthyProbeFailureThreshold = healthyProbeFailureThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case nodeName
        case statePath
        case requestPath
        case statusPath
        case requestWriterUID
        case maxRebootAttempts
        case minimumRebootIntervalSeconds
        case attemptWindowSeconds
        case maximumRequestAgeSeconds
        case verificationTimeoutSeconds
        case pollIntervalSeconds
        case healthyProbeFailureThreshold
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName)
        statePath = try container.decodeIfPresent(String.self, forKey: .statePath)
        requestPath = try container.decodeIfPresent(String.self, forKey: .requestPath)
        statusPath = try container.decodeIfPresent(String.self, forKey: .statusPath)
        requestWriterUID = try container.decodeIfPresent(Int.self, forKey: .requestWriterUID) ?? 0
        maxRebootAttempts = try container.decodeIfPresent(Int.self, forKey: .maxRebootAttempts) ?? Self.defaultMaxRebootAttempts
        minimumRebootIntervalSeconds =
            try container.decodeIfPresent(Int.self, forKey: .minimumRebootIntervalSeconds)
            ?? Self.defaultMinimumRebootIntervalSeconds
        attemptWindowSeconds =
            try container.decodeIfPresent(Int.self, forKey: .attemptWindowSeconds)
            ?? Self.defaultAttemptWindowSeconds
        maximumRequestAgeSeconds =
            try container.decodeIfPresent(Int.self, forKey: .maximumRequestAgeSeconds)
            ?? Self.defaultMaximumRequestAgeSeconds
        verificationTimeoutSeconds =
            try container.decodeIfPresent(Int.self, forKey: .verificationTimeoutSeconds)
            ?? Self.defaultVerificationTimeoutSeconds
        pollIntervalSeconds =
            try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds)
            ?? Self.defaultPollIntervalSeconds
        healthyProbeFailureThreshold =
            try container.decodeIfPresent(Int.self, forKey: .healthyProbeFailureThreshold)
            ?? Self.defaultHealthyProbeFailureThreshold
    }
}

extension CRIShimConfig {
    public var resolvedVMNetRecoveryConfig: VMNetRecoveryConfig {
        var recovery = podNetwork?.vmnetRecovery ?? VMNetRecoveryConfig()
        if recovery.statePath?.trimmed.isEmpty != false {
            recovery.statePath = CRIShimConfigDefaults.vmnetRecoveryStateURL.path
        }
        if recovery.requestPath?.trimmed.isEmpty != false {
            recovery.requestPath = CRIShimConfigDefaults.vmnetRecoveryRequestURL.path
        }
        return recovery
    }
}
