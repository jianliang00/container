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

import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

// MARK: - Collection capacity hints
// Dictionary(minimumCapacity:) and reserveCapacity() are used in this file to
// pre-allocate storage when the final collection size is known from the input.
// This avoids incremental reallocation overhead in hot-path parser methods.

public struct Utility {
    static let publishedPortCountLimit = 64
    static let runtimeLinux = "container-runtime-linux"
    static let runtimeMacOS = "container-runtime-macos"
    static let defaultMacOSGuestAgentPort: UInt32 = 27000
    static let defaultContainerOS = "linux"

    public struct MacOSGuestNetworkingOverride: Sendable {
        public let networks: [AttachmentConfiguration]
        public let dns: ContainerConfiguration.DNSConfiguration?

        public init(
            networks: [AttachmentConfiguration] = [],
            dns: ContainerConfiguration.DNSConfiguration? = nil
        ) {
            self.networks = networks
            self.dns = dns
        }
    }
    public static func createContainerID(name: String?) -> String {
        guard let name else {
            return UUID().uuidString.lowercased()
        }
        return name
    }

    public static func isInfraImage(name: String, builderImage: String, initImage: String) -> Bool {
        for infraImage in [builderImage, initImage] {
            if name == infraImage {
                return true
            }
        }
        return false
    }

    public static func trimDigest(digest: String) -> String {
        var hex = digest
        if let colonIndex = digest.firstIndex(of: ":") {
            hex = String(digest[digest.index(after: colonIndex)...])
        }
        return String(hex.prefix(12))
    }

    public static func validEntityName(_ name: String) throws {
        let pattern = #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#
        let regex = try Regex(pattern)
        if try regex.firstMatch(in: name) == nil {
            throw ContainerizationError(.invalidArgument, message: "invalid entity name \(name)")
        }
    }

    public static func validMACAddress(_ macAddress: String) throws {
        let pattern = #"^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$"#
        let regex = try Regex(pattern)
        if try regex.firstMatch(in: macAddress) == nil {
            throw ContainerizationError(.invalidArgument, message: "invalid MAC address format \(macAddress), expected format: XX:XX:XX:XX:XX:XX")
        }
    }

    public static func containerConfigFromFlags(
        id: String,
        image: String,
        arguments: [String],
        process: Flags.Process,
        management: Flags.Management,
        resource: Flags.Resource,
        registry: Flags.Registry,
        imageFetch: Flags.ImageFetch,
        macOSGuestNetworking: MacOSGuestNetworkingOverride? = nil,
        containerSystemConfig: ContainerSystemConfig,
        progressUpdate: @escaping ProgressUpdateHandler,
        log: Logger
    ) async throws -> (ContainerConfiguration, Kernel?, String?) {
        let explicitlyResolvedPlatform = try DefaultPlatform.resolve(
            platform: management.platform,
            os: management.os,
            arch: management.arch,
            log: log
        )
        var requestedPlatform =
            explicitlyResolvedPlatform
            ?? Parser.platform(os: defaultContainerOS, arch: Platform.current.architecture)
        let canAutoDetectPlatformFromImage =
            explicitlyResolvedPlatform == nil && management.runtime == nil

        var prefetchedImage: ClientImage?
        if canAutoDetectPlatformFromImage {
            let img = try await ClientImage.fetch(
                reference: image,
                platform: nil,
                scheme: try RequestScheme(registry.scheme),
                containerSystemConfig: containerSystemConfig,
                progressUpdate: progressUpdate,
                maxConcurrentDownloads: imageFetch.maxConcurrentDownloads
            )
            if let autoDetectedPlatform = try await self.autoDetectPlatformOverride(for: img) {
                requestedPlatform = autoDetectedPlatform
            }
            prefetchedImage = img
        }

        let runtimeHandler = try resolveRuntimeHandler(platform: requestedPlatform, explicitRuntime: management.runtime)
        let isMacOSRuntime = runtimeHandler == runtimeMacOS

        if isMacOSRuntime {
            guard Platform.current.architecture == "arm64" else {
                throw ContainerizationError(.unsupported, message: "macOS guest runtime requires an arm64 host")
            }
            guard requestedPlatform.os == "darwin", requestedPlatform.architecture == "arm64" else {
                throw ContainerizationError(.invalidArgument, message: "macOS guest images must target darwin/arm64, got \(requestedPlatform)")
            }
            if management.kernel != nil {
                throw ContainerizationError(.unsupported, message: "--kernel is not supported for --os darwin")
            }
            if management.initImage != nil {
                throw ContainerizationError(.unsupported, message: "--init-image is not supported for --os darwin")
            }
            if !management.publishSockets.isEmpty {
                throw ContainerizationError(.unsupported, message: "--publish-socket is not supported for --os darwin")
            }
            if management.rosetta {
                throw ContainerizationError(.unsupported, message: "--rosetta is not supported for --os darwin")
            }
        } else if management.gui {
            throw ContainerizationError(.unsupported, message: "--gui requires --os darwin")
        }
        let scheme = try RequestScheme(registry.scheme)

        await progressUpdate([
            .setDescription("Fetching image"),
            .setItemsName("blobs"),
        ])
        let taskManager = ProgressTaskCoordinator()
        let fetchTask = await taskManager.startTask()
        let img: ClientImage
        if let prefetchedImage {
            img = try await ensureImageHasPlatform(
                prefetchedImage,
                reference: image,
                platform: requestedPlatform,
                scheme: scheme,
                containerSystemConfig: containerSystemConfig,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressUpdate),
                maxConcurrentDownloads: imageFetch.maxConcurrentDownloads
            )
        } else {
            img = try await ClientImage.fetch(
                reference: image,
                platform: requestedPlatform,
                scheme: scheme,
                containerSystemConfig: containerSystemConfig,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressUpdate),
                maxConcurrentDownloads: imageFetch.maxConcurrentDownloads
            )
        }

        if !isMacOSRuntime {
            // Unpack a fetched image before use for Linux runtime.
            await progressUpdate([
                .setDescription("Unpacking image"),
                .setItemsName("entries"),
            ])
            let unpackTask = await taskManager.startTask()
            try await img.getCreateSnapshot(
                platform: requestedPlatform,
                progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressUpdate))
        }

        let kernel: Kernel?
        if isMacOSRuntime {
            kernel = nil
        } else {
            await progressUpdate([
                .setDescription("Fetching kernel"),
                .setItemsName("binary"),
            ])

            kernel = try await self.getKernel(
                management: management,
                containerSystemConfig: containerSystemConfig,
                progressUpdate: progressUpdate
            )

            // Pull and unpack the initial filesystem for Linux runtime.
            await progressUpdate([
                .setDescription("Fetching init image"),
                .setItemsName("blobs"),
            ])
            let fetchInitTask = await taskManager.startTask()
            let initImageRef = management.initImage ?? containerSystemConfig.vminit.image
            let initImage = try await ClientImage.fetch(
                reference: initImageRef, platform: .current, scheme: scheme,
                containerSystemConfig: containerSystemConfig,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchInitTask, from: progressUpdate),
                maxConcurrentDownloads: imageFetch.maxConcurrentDownloads)

            await progressUpdate([
                .setDescription("Unpacking init image"),
                .setItemsName("entries"),
            ])
            let unpackInitTask = await taskManager.startTask()
            _ = try await initImage.getCreateSnapshot(
                platform: .current,
                progressUpdate: ProgressTaskCoordinator.handler(for: unpackInitTask, from: progressUpdate))
        }

        await taskManager.finish()

        let imageConfig = try await img.config(for: requestedPlatform).config
        let description = img.description
        let pc = try Parser.process(
            arguments: arguments,
            processFlags: process,
            managementFlags: management,
            config: imageConfig
        )

        var config = ContainerConfiguration(id: id, image: description, process: pc)
        config.platform = requestedPlatform
        config.runtimeHandler = runtimeHandler

        config.resources = try Parser.resources(
            cpus: resource.cpus,
            memory: resource.memory,
            defaultCPUs: containerSystemConfig.container.cpus,
            defaultMemory: containerSystemConfig.container.memory
        )
        if isMacOSRuntime, resource.memory == nil {
            // macOS guest images commonly need substantially more memory than the global
            // container default (1 GiB) to boot the guest-agent reliably.
            config.resources.memoryInBytes = max(config.resources.memoryInBytes, 8192.mib())
        }

        let tmpfs = try Parser.tmpfsMounts(management.tmpFs)
        let volumesOrFs = try Parser.volumes(management.volumes)
        let mountsOrFs = try Parser.mounts(management.mounts)

        var resolvedMounts: [Filesystem] = []
        resolvedMounts.append(contentsOf: tmpfs)

        // Resolve volumes and filesystems
        for item in (volumesOrFs + mountsOrFs) {
            switch item {
            case .filesystem(let fs):
                resolvedMounts.append(fs)
            case .volume(let parsed):
                let volume = try await getOrCreateVolume(parsed: parsed, log: log)
                let volumeMount = Filesystem.volume(
                    name: parsed.name,
                    format: volume.format,
                    source: volume.source,
                    destination: parsed.destination,
                    options: parsed.options
                )
                resolvedMounts.append(volumeMount)
            }
        }

        config.mounts = resolvedMounts

        if let shmSizeStr = management.shmSize {
            let measurement = try Measurement.parse(parsing: shmSizeStr)
            let bytes = measurement.converted(to: .bytes)
            config.shmSize = UInt64(bytes.value)
        }

        config.virtualization = management.virtualization
        let resolvedMacOSGuestNetworking =
            isMacOSRuntime
            ? try resolveMacOSGuestNetworking(
                containerID: id,
                management: management,
                override: macOSGuestNetworking,
                dnsDomain: containerSystemConfig.dns.domain
            )
            : nil

        if isMacOSRuntime {
            config.networks = resolvedMacOSGuestNetworking?.networks ?? []
        } else {
            // Parse network specifications with properties
            let parsedNetworks = try management.networks.map { try Parser.network($0) }
            if management.networks.contains(ClientNetwork.noNetworkName) {
                guard management.networks.count == 1 else {
                    throw ContainerizationError(.unsupported, message: "no other networks may be created along with network \(ClientNetwork.noNetworkName)")
                }
                config.networks = []
            } else {
                let networkClient = NetworkClient()
                let builtinNetworkId = try await networkClient.builtin?.id
                config.networks = try getAttachmentConfigurations(
                    containerId: config.id,
                    builtinNetworkId: builtinNetworkId,
                    networks: parsedNetworks,
                    dnsDomain: containerSystemConfig.dns.domain
                )
                for attachmentConfiguration in config.networks {
                    _ = try await networkClient.get(id: attachmentConfiguration.network)
                }
            }
        }

        if isMacOSRuntime {
            config.dns = resolvedMacOSGuestNetworking?.dns
        } else if management.dnsDisabled {
            config.dns = nil
        } else {
            let domain = management.dns.domain ?? containerSystemConfig.dns.domain
            config.dns = .init(
                nameservers: management.dns.nameservers,
                domain: domain,
                searchDomains: management.dns.searchDomains,
                options: management.dns.options
            )
        }

        if isMacOSRuntime {
            config.rosetta = false
        } else {
            config.rosetta = management.rosetta || (Platform.current.architecture == "arm64" && requestedPlatform.architecture == "amd64")
        }

        if management.rosetta && Platform.current.architecture != "arm64" {
            throw ContainerizationError(.unsupported, message: "--rosetta flag requires an arm64 host")
        }

        config.labels = try Parser.labels(management.labels)

        config.publishedPorts = try Parser.publishPorts(management.publishPorts)
        guard config.publishedPorts.count <= publishedPortCountLimit else {
            throw ContainerizationError(.invalidArgument, message: "cannot exceed more than \(publishedPortCountLimit) port publish descriptors")
        }
        guard !config.publishedPorts.hasOverlaps() else {
            throw ContainerizationError(.invalidArgument, message: "host ports for different publish port specs may not overlap")
        }

        if isMacOSRuntime {
            try validateMacOSPublishedPorts(config.publishedPorts)
            config.publishedSockets = []
        } else {
            // Parse --publish-socket arguments and add to container configuration
            // to enable socket forwarding from container to host.
            config.publishedSockets = try Parser.publishSockets(management.publishSockets)
        }

        config.ssh = management.ssh
        config.readOnly = management.readOnly
        config.useInit = management.useInit

        let caps = try Parser.capabilities(capAdd: management.capAdd, capDrop: management.capDrop)
        config.capAdd = caps.capAdd
        config.capDrop = caps.capDrop
        config.stopSignal = imageConfig?.stopSignal

        if isMacOSRuntime {
            config.macosGuest = .init(
                snapshotEnabled: false,
                guiEnabled: management.gui,
                agentPort: defaultMacOSGuestAgentPort,
                networkBackend: resolvedMacOSGuestNetworking == nil ? .virtualizationNAT : .vmnetShared
            )
        }

        return (config, kernel, management.initImage)
    }

    static func resolveMacOSGuestNetworking(
        containerID: String,
        management: Flags.Management,
        override: MacOSGuestNetworkingOverride?,
        dnsDomain: String? = nil
    ) throws -> (networks: [AttachmentConfiguration], dns: ContainerConfiguration.DNSConfiguration?)? {
        if let override {
            guard !management.dnsDisabled else {
                return (override.networks, nil)
            }

            if let dns = override.dns {
                return (override.networks, sanitizeMacOSGuestDNS(dns))
            }

            try validateMacOSGuestDNSOptions(management.dns.options)
            let domain = management.dns.domain ?? dnsDomain
            return (
                override.networks,
                .init(
                    nameservers: management.dns.nameservers,
                    domain: domain,
                    searchDomains: management.dns.searchDomains,
                    options: []
                )
            )
        }

        let hasExplicitDNS =
            !management.dns.nameservers.isEmpty
            || management.dns.domain != nil
            || !management.dns.searchDomains.isEmpty
            || !management.dns.options.isEmpty
        let requiresHostVisibleNetworking = !management.publishPorts.isEmpty

        guard !management.networks.isEmpty || hasExplicitDNS || requiresHostVisibleNetworking else {
            return nil
        }

        guard management.networks.count <= 1 else {
            throw ContainerizationError(
                .unsupported,
                message: "--os darwin currently supports at most one --network attachment"
            )
        }

        let parsedNetworks = try management.networks.map { try Parser.network($0) }
        if parsedNetworks.contains(where: { $0.name == ClientNetwork.noNetworkName }) {
            throw ContainerizationError(
                .unsupported,
                message: "--network \(ClientNetwork.noNetworkName) is not supported for --os darwin"
            )
        }

        let attachments = try getAttachmentConfigurations(
            containerId: containerID,
            builtinNetworkId: ClientNetwork.defaultNetworkName,
            networks: parsedNetworks,
            dnsDomain: dnsDomain
        )

        guard !management.dnsDisabled else {
            return (attachments, nil)
        }

        try validateMacOSGuestDNSOptions(management.dns.options)
        let domain = management.dns.domain ?? dnsDomain
        return (
            attachments,
            .init(
                nameservers: management.dns.nameservers,
                domain: domain,
                searchDomains: management.dns.searchDomains,
                options: []
            )
        )
    }

    private static func validateMacOSGuestDNSOptions(_ options: [String]) throws {
        guard options.isEmpty else {
            throw ContainerizationError(
                .unsupported,
                message: "--dns-option is not supported for --os darwin"
            )
        }
    }

    private static func sanitizeMacOSGuestDNS(
        _ dns: ContainerConfiguration.DNSConfiguration
    ) -> ContainerConfiguration.DNSConfiguration {
        .init(
            nameservers: dns.nameservers,
            domain: dns.domain,
            searchDomains: dns.searchDomains,
            options: []
        )
    }

    static func resolveRuntimeHandler(
        platform: ContainerizationOCI.Platform,
        explicitRuntime: String?
    ) throws -> String {
        let inferred = try inferRuntimeHandler(for: platform)
        guard let explicitRuntime else {
            return inferred
        }
        guard explicitRuntime == inferred else {
            throw ContainerizationError(
                .invalidArgument,
                message: "--runtime \(explicitRuntime) conflicts with platform \(platform); expected \(inferred)"
            )
        }
        return explicitRuntime
    }

    static func inferRuntimeHandler(for platform: ContainerizationOCI.Platform) throws -> String {
        switch platform.os {
        case "linux":
            return runtimeLinux
        case "darwin":
            return runtimeMacOS
        default:
            throw ContainerizationError(
                .unsupported,
                message: "unsupported platform OS \(platform.os); expected linux or darwin"
            )
        }
    }

    static func ensureImageHasPlatform(
        _ image: ClientImage,
        reference: String,
        platform: ContainerizationOCI.Platform,
        scheme: RequestScheme,
        containerSystemConfig: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?,
        maxConcurrentDownloads: Int
    ) async throws -> ClientImage {
        do {
            _ = try await image.config(for: platform)
            return image
        } catch let error as ContainerizationError {
            guard error.isCode(.notFound) || error.isCode(.unsupported) else {
                throw error
            }
        }
        return try await ClientImage.fetch(
            reference: reference,
            platform: platform,
            scheme: scheme,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: progressUpdate,
            maxConcurrentDownloads: maxConcurrentDownloads
        )
    }

    static func autoDetectPlatformOverride(for image: ClientImage) async throws -> ContainerizationOCI.Platform? {
        let platforms = try await image.availablePlatformsForRuntimeAutoDetect()
        return try autoDetectedPlatformOverrideIfNeeded(availablePlatforms: platforms)
    }

    static func autoDetectedPlatformOverrideIfNeeded(
        availablePlatforms: [ContainerizationOCI.Platform]
    ) throws -> ContainerizationOCI.Platform? {
        var seen = Set<ContainerizationOCI.Platform>()
        let uniquePlatforms = availablePlatforms.filter { seen.insert($0).inserted }

        guard let darwinArm64 = uniquePlatforms.first(where: { $0.os == "darwin" && $0.architecture == "arm64" }) else {
            return nil
        }

        let availableOSes = Set(uniquePlatforms.map(\.os))
        if availableOSes.count > 1 {
            let values = availableOSes.sorted().joined(separator: ", ")
            throw ContainerizationError(
                .invalidArgument,
                message: "image contains multiple operating systems (\(values)); please specify --platform or --os"
            )
        }

        return darwinArm64
    }

    static func validateMacOSPublishedPorts(_ publishedPorts: [PublishPort]) throws {
        for publishedPort in publishedPorts {
            guard case .v4 = publishedPort.hostAddress else {
                throw ContainerizationError(
                    .unsupported,
                    message: "--publish for --os darwin currently supports IPv4 host bindings only"
                )
            }
        }
    }

    static func getAttachmentConfigurations(
        containerId: String,
        builtinNetworkId: String?,
        networks: [Parser.ParsedNetwork],
        dnsDomain: String?,
    ) throws -> [AttachmentConfiguration] {
        // Validate MAC addresses if provided
        for network in networks {
            if let mac = network.macAddress {
                try validMACAddress(mac)
            }
        }

        // make an FQDN for the first interface
        let fqdn: String?
        if !containerId.contains(".") {
            // add default domain if it exists, and container ID is unqualified
            if let dnsDomain {
                fqdn = "\(containerId).\(dnsDomain)."
            } else {
                fqdn = nil
            }
        } else {
            // use container ID directly if fully qualified
            fqdn = "\(containerId)."
        }

        guard networks.isEmpty else {
            // Check if this is only the default network with properties (e.g., MAC address)
            let isOnlyDefaultNetwork = networks.count == 1 && networks[0].name == builtinNetworkId

            // networks may only be specified for macOS 26+ (except for default network with properties)
            if !isOnlyDefaultNetwork {
                guard #available(macOS 26, *) else {
                    throw ContainerizationError(.invalidArgument, message: "non-default network configuration requires macOS 26 or newer")
                }
            }

            // attach the first network using the fqdn, and the rest using just the container ID
            return try networks.enumerated().map { item in
                let macAddress = try item.element.macAddress.map { try MACAddress($0) }
                let mtu = item.element.mtu ?? 1280
                guard item.offset == 0 else {
                    return AttachmentConfiguration(
                        network: item.element.name,
                        options: AttachmentOptions(hostname: containerId, macAddress: macAddress, mtu: mtu)
                    )
                }
                return AttachmentConfiguration(
                    network: item.element.name,
                    options: AttachmentOptions(hostname: fqdn ?? containerId, macAddress: macAddress, mtu: mtu)
                )
            }
        }

        // if no networks specified, attach to the default network
        guard let builtinNetworkId else {
            throw ContainerizationError(.invalidState, message: "builtin network is not present")
        }
        return [AttachmentConfiguration(network: builtinNetworkId, options: AttachmentOptions(hostname: fqdn ?? containerId, macAddress: nil, mtu: 1280))]
    }

    private static func getKernel(
        management: Flags.Management,
        containerSystemConfig: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler? = nil
    ) async throws -> Kernel {
        // For the image itself we'll take the user input and try with it as we can do userspace
        // emulation for x86, but for the kernel we need it to match the hosts architecture.
        let s: SystemPlatform = .current
        if let userKernel = management.kernel {
            guard FileManager.default.fileExists(atPath: userKernel) else {
                throw ContainerizationError(.notFound, message: "kernel file not found at path \(userKernel)")
            }
            let p = URL(filePath: userKernel)
            return .init(path: p, platform: s)
        }
        do {
            return try await ClientKernel.getDefaultKernel(for: s)
        } catch let error as ContainerizationError {
            guard error.isCode(.notFound) else {
                throw error
            }
            try await installRecommendedKernelIfConfirmed(
                platform: s,
                kernelConfig: containerSystemConfig.kernel,
                progressUpdate: progressUpdate
            )
            return try await ClientKernel.getDefaultKernel(for: s)
        }
    }

    private static func installRecommendedKernelIfConfirmed(
        platform: SystemPlatform,
        kernelConfig: KernelConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws {
        let url = kernelConfig.url.absoluteString
        let path = kernelConfig.binaryPath

        await progressUpdate?([
            .setDescription("Waiting for kernel install confirmation"),
            .setItemsName("binary"),
        ])

        print("No default kernel configured.")
        print("Install the recommended default kernel from [\(url)]? [Y/n]: ", terminator: "")
        guard let read = readLine(strippingNewline: true) else {
            throw ContainerizationError(.internalError, message: "failed to read user input")
        }

        let answer = read.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard answer.isEmpty || answer == "y" || answer == "yes" else {
            throw ContainerizationError(
                .notFound,
                message:
                    "default kernel not configured for architecture \(platform.architecture), please use the `container system kernel set --recommended` command to configure it"
            )
        }

        await progressUpdate?([
            .setDescription("Installing kernel"),
            .setItemsName("binary"),
        ])
        try await ClientKernel.installKernelFromTar(
            tarFile: url,
            kernelFilePath: path,
            platform: platform,
            progressUpdate: progressUpdate,
            expectedDigest: kernelConfig.digest,
            force: true
        )
    }

    /// Parses key-value pairs from command line arguments.
    ///
    /// Supports formats like "key=value" and standalone keys (treated as "key=").
    /// - Parameter pairs: Array of strings in "key=value" format
    /// - Returns: Dictionary mapping keys to values
    public static func parseKeyValuePairs(_ pairs: [String]) -> [String: String] {
        var result: [String: String] = Dictionary(minimumCapacity: pairs.count)
        for pair in pairs {
            let components = pair.split(separator: "=", maxSplits: 1)
            if components.count == 2 {
                result[String(components[0])] = String(components[1])
            } else {
                result[pair] = ""
            }
        }
        return result
    }

    /// Gets an existing volume or creates it if it doesn't exist.
    /// Shows a warning for named volumes when auto-creating.
    private static func getOrCreateVolume(parsed: ParsedVolume, log: Logger) async throws -> VolumeConfiguration {
        let labels = parsed.isAnonymous ? [VolumeConfiguration.anonymousLabel: ""] : [:]

        let volume: VolumeConfiguration
        var wasCreated = false
        do {
            volume = try await ClientVolume.create(
                name: parsed.name,
                driver: "local",
                driverOpts: [:],
                labels: labels
            )
            wasCreated = true
        } catch let error as VolumeError {
            guard case .volumeAlreadyExists = error else {
                throw error
            }
            // Volume already exists, just inspect it
            volume = try await ClientVolume.inspect(parsed.name)
        } catch let error as ContainerizationError {
            // Handle XPC-wrapped volumeAlreadyExists error
            guard error.message.contains("already exists") else {
                throw error
            }
            volume = try await ClientVolume.inspect(parsed.name)
        }

        if wasCreated && !parsed.isAnonymous {
            log.warning("named volume was automatically created", metadata: ["volume": "\(parsed.name)"])
        }

        return volume
    }
}
