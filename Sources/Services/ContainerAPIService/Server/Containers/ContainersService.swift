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

import CVersion
import ContainerAPIClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import SystemPackage

private struct SendableXPCEndpoint: @unchecked Sendable {
    let value: xpc_endpoint_t?
}

public actor ContainersService {
    private static let macOSRuntimeName = "container-runtime-macos"

    enum StartProcessResult: Sendable {
        case exec
        case initProcessStarted(networks: [Attachment])
    }

    struct ContainerState {
        var snapshot: ContainerSnapshot
        var client: RuntimeClient?
        var sandboxStartTask: Task<RuntimeClient, Error>?
        var bootstrapTask: Task<RuntimeClient, Error>?
        var processStartTasks: [String: Task<StartProcessResult, Error>] = [:]

        func getClient() throws -> RuntimeClient {
            guard let client else {
                var message = "no runtime client exists"
                if snapshot.status == .stopped {
                    message += ": container is stopped"
                }
                throw ContainerizationError(.invalidState, message: message)
            }
            return client
        }
    }

    private static let machServicePrefix = "com.apple.container"
    private static let launchdDomainString = try! ServiceManager.getDomainString()

    private let log: Logger
    private let debugHelpers: Bool
    private let containerRoot: URL
    private let pluginLoader: PluginLoader
    private let runtimePlugins: [Plugin]
    private let exitMonitor: ExitMonitor
    private let containerSystemConfig: ContainerSystemConfig

    private let lock: AsyncLock
    private var containers: [String: ContainerState]

    // FIXME: Find a better mechanism for services running on the APIServer to work with each other
    private weak var networksService: NetworksService?

    public init(
        appRoot: URL,
        pluginLoader: PluginLoader,
        containerSystemConfig: ContainerSystemConfig,
        log: Logger,
        debugHelpers: Bool = false
    ) throws {
        let containerRoot = appRoot.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        self.exitMonitor = ExitMonitor(log: log)
        self.lock = AsyncLock(log: log)
        self.containerRoot = containerRoot
        self.pluginLoader = pluginLoader
        self.containerSystemConfig = containerSystemConfig
        self.log = log
        self.debugHelpers = debugHelpers
        self.runtimePlugins = pluginLoader.findPlugins().filter { $0.hasType(.runtime) }
        self.containers = try Self.loadAtBoot(root: containerRoot, loader: pluginLoader, log: log)
        Task {
            await self.recoverSandboxStatesAtBoot()
        }
    }

    public func setNetworksService(_ service: NetworksService) async {
        self.networksService = service
    }

    static func loadAtBoot(root: URL, loader: PluginLoader, log: Logger) throws -> [String: ContainerState] {
        var directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        directories = directories.filter {
            $0.isDirectory
        }

        let runtimePlugins = loader.findPlugins().filter { $0.hasType(.runtime) }
        var results = [String: ContainerState]()
        for dir in directories {
            do {
                let (config, options) = try Self.getContainerConfiguration(at: dir)
                if options?.autoRemove ?? false {
                    log.info(
                        "reap auto-remove container",
                        metadata: [
                            "id": "\(config.id)"
                        ])

                    let label = Self.fullLaunchdServiceLabel(
                        runtimeName: config.runtimeHandler,
                        instanceId: config.id)

                    var status: Int32 = -1
                    try? ServiceManager.deregister(fullServiceLabel: label, status: &status)
                    if status != 0 {
                        log.warning(
                            "failed to deregister service",
                            metadata: [
                                "id": "\(config.id)",
                                "service": "\(label)",
                                "status": "\(status)",
                            ]
                        )
                    }

                    let bundle = ContainerResource.Bundle(path: dir)
                    try? bundle.delete()
                    continue
                }

                let state = ContainerState(
                    snapshot: .init(
                        configuration: config,
                        status: .stopped,
                        networks: [],
                        startedDate: nil
                    ),
                )
                results[config.id] = state
                guard runtimePlugins.first(where: { $0.name == config.runtimeHandler }) != nil else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to find runtime plugin \(config.runtimeHandler)"
                    )
                }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                log.warning(
                    "failed to load container",
                    metadata: [
                        "path": "\(dir.path)",
                        "error": "\(error)",
                    ])
            }
        }
        return results
    }

    /// List containers matching the given filters.
    public func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        let labelPatterns: [(key: String, regex: Regex<AnyRegexOutput>)] = try filters.labels.map { key, pattern in
            do {
                return (key: key, regex: try Regex(pattern))
            } catch {
                throw ContainerizationError(
                    .invalidArgument, message: "failed to compile regex '\(pattern)' for \(key)",
                    cause: error)
            }
        }

        return self.containers.values.compactMap { state -> ContainerSnapshot? in
            let snapshot = state.snapshot

            if !filters.ids.isEmpty {
                guard filters.ids.contains(snapshot.id) else {
                    return nil
                }
            }

            if let status = filters.status {
                guard snapshot.status == status else {
                    return nil
                }
            }

            for (key, regex) in labelPatterns {
                let label = snapshot.configuration.labels[key] ?? ""

                guard label.contains(regex) else {
                    return nil
                }
            }

            return snapshot
        }
    }

    /// Execute an operation with the current container list while maintaining atomicity
    /// This prevents race conditions where containers are created during the operation
    public func withContainerList<T: Sendable>(
        logMetadata: Logger.Metadata? = nil,
        _ operation: @Sendable @escaping ([ContainerSnapshot]) async throws -> T
    ) async throws -> T {
        try await lock.withLock(logMetadata: logMetadata) { context in
            let snapshots = await self.containers.values.map { $0.snapshot }
            return try await operation(snapshots)
        }
    }

    /// Calculate disk usage for containers
    /// - Returns: Tuple of (total count, active count, total size, reclaimable size)
    public func calculateDiskUsage() async -> (Int, Int, UInt64, UInt64) {
        await lock.withLock(logMetadata: ["acquirer": "\(#function)"]) { _ in
            var totalSize: UInt64 = 0
            var reclaimableSize: UInt64 = 0
            var activeCount = 0

            for (id, state) in await self.containers {
                let bundlePath = self.containerRoot.appendingPathComponent(id)
                let containerSize = FileManager.default.allocatedSize(of: bundlePath)
                totalSize += containerSize

                if state.snapshot.status == .running {
                    activeCount += 1
                } else {
                    // Stopped containers are reclaimable
                    reclaimableSize += containerSize
                }
            }

            return (await self.containers.count, activeCount, totalSize, reclaimableSize)
        }
    }

    /// Get set of image references used by containers (for disk usage calculation)
    /// - Returns: Set of image references currently in use
    public func getActiveImageReferences() async -> Set<String> {
        await lock.withLock(logMetadata: ["acquirer": "\(#function)"]) { _ in
            var imageRefs = Set<String>()
            for (_, state) in await self.containers {
                imageRefs.insert(state.snapshot.configuration.image.reference)
            }
            return imageRefs
        }
    }

    /// Create a new container from the provided id and configuration.
    public func create(
        configuration: ContainerConfiguration,
        kernel: Kernel?,
        options: ContainerCreateOptions,
        initImage: String? = nil,
        runtimeData: Data? = nil
    ) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(configuration.id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(configuration.id)",
                ]
            )
        }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(configuration.id)"]) { context in
            guard await self.containers[configuration.id] == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "container already exists: \(configuration.id)"
                )
            }

            var allHostnames = Set<String>()
            for container in await self.containers.values {
                for attachmentConfiguration in container.snapshot.configuration.networks {
                    allHostnames.insert(attachmentConfiguration.options.hostname)
                }
            }

            var conflictingHostnames = [String]()
            for attachmentConfiguration in configuration.networks {
                if allHostnames.contains(attachmentConfiguration.options.hostname) {
                    conflictingHostnames.append(attachmentConfiguration.options.hostname)
                }
            }

            guard conflictingHostnames.isEmpty else {
                throw ContainerizationError(
                    .exists,
                    message: "hostname(s) already exist: \(conflictingHostnames)"
                )
            }

            guard self.runtimePlugins.first(where: { $0.name == configuration.runtimeHandler }) != nil else {
                throw ContainerizationError(
                    .notFound,
                    message: "unable to locate runtime plugin \(configuration.runtimeHandler)"
                )
            }
            try Self.validateCreateInput(configuration: configuration, kernel: kernel)

            // Protect against a user providing a memory amount that will cause us to not be able
            // to boot. We can go lower, but this is a somewhat safe threshold. Containerization
            // also gives a little bit extra than the user asked for to account for guest agent overhead.
            //
            // NOTE: We could potentially leave this validation to the runtime service(s), as
            // it's possible there could be an implementation that can get away with a lower
            // amount and be perfectly safe.
            let minimumMemory: UInt64 = 200.mib()
            guard configuration.resources.memoryInBytes >= minimumMemory else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "minimum memory amount allowed is 200 MiB (got \(configuration.resources.memoryInBytes) bytes)"
                )
            }

            let path = self.containerRoot.appendingPathComponent(configuration.id)
            if configuration.runtimeHandler == Self.macOSRuntimeName {
                let runtimeConfig = RuntimeConfiguration(
                    path: path,
                    containerConfiguration: configuration,
                    options: options,
                    runtimeData: runtimeData
                )
                try runtimeConfig.writeRuntimeConfiguration()
            } else {
                guard let kernel else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "kernel cannot be empty for runtime \(configuration.runtimeHandler)"
                    )
                }

                let systemPlatform = kernel.platform
                // Fetch init image (custom or default)
                self.log.debug(
                    "ContainersService: get init block",
                    metadata: [
                        "id": "\(configuration.id)"
                    ]
                )
                let initFilesystem = try await self.getInitBlock(
                    for: systemPlatform.ociPlatform(),
                    imageRef: initImage
                )

                self.log.debug(
                    "create snapshot",
                    metadata: [
                        "id": "\(configuration.id)",
                        "ref": "\(configuration.image.reference)",
                    ]
                )
                let containerImage = ClientImage(description: configuration.image)
                let imageFs = try await options.rootFsOverride == nil ? containerImage.getCreateSnapshot(platform: configuration.platform) : nil

                self.log.debug(
                    "configure runtime",
                    metadata: [
                        "id": "\(configuration.id)",
                        "kernel": "\(kernel.path)",
                        "initfs": "\(initImage ?? self.containerSystemConfig.vminit.image)",
                    ])
                let runtimeConfig = RuntimeConfiguration(
                    path: path,
                    initialFilesystem: initFilesystem,
                    kernel: kernel,
                    containerConfiguration: configuration,
                    containerRootFilesystem: imageFs,
                    options: options,
                    runtimeData: runtimeData
                )

                try runtimeConfig.writeRuntimeConfiguration()
            }

            let snapshot = ContainerSnapshot(
                configuration: configuration,
                status: .stopped,
                networks: [],
                startedDate: nil
            )
            await self.setContainerState(configuration.id, ContainerState(snapshot: snapshot), context: context)
        }
    }

    nonisolated static func validateCreateInput(configuration: ContainerConfiguration, kernel: Kernel?) throws {
        if configuration.runtimeHandler == Self.macOSRuntimeName {
            guard configuration.platform.os == "darwin", configuration.platform.architecture == "arm64" else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "macOS runtime requires darwin/arm64 image platform, got \(configuration.platform)"
                )
            }
            do {
                _ = try MacOSGuestMountMapping.hostPathShares(from: configuration.mounts)
            } catch let error as MacOSGuestMountMapping.Error {
                throw ContainerizationError(.invalidArgument, message: error.localizedDescription)
            }
            return
        }

        guard kernel != nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel cannot be empty for runtime \(configuration.runtimeHandler)"
            )
        }
    }

    /// Bootstrap the init process of the container.
    public func bootstrap(
        id: String,
        stdio: [FileHandle?],
        dynamicEnv: [String: String] = [:],
        presentGUI: Bool = true,
        progressUpdateEndpoint: xpc_endpoint_t? = nil
    ) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "env": "\(dynamicEnv)",
                "present_gui": "\(presentGUI)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }
        let progressUpdateEndpoint = SendableXPCEndpoint(value: progressUpdateEndpoint)

        let (task, config, cleanupOnFailure) = try await self.lock.withLock(
            logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]
        ) { context -> (Task<RuntimeClient, Error>, ContainerConfiguration, Bool) in
            var state = try await self.getContainerState(id: id, context: context)

            let path = self.containerRoot.appendingPathComponent(id)
            let (config, _) = try Self.getContainerConfiguration(at: path)
            if let task = state.bootstrapTask {
                return (task, config, false)
            }
            if state.snapshot.configuration.runtimeHandler == Self.macOSRuntimeName,
                let task = state.sandboxStartTask
            {
                let task = Task {
                    let runtimeClient = try await task.value
                    try await runtimeClient.startWorkload(id)
                    return runtimeClient
                }
                state.bootstrapTask = task
                await self.setContainerState(id, state, context: context)
                return (task, config, false)
            }

            if let client = state.client {
                if state.snapshot.status == .running || config.runtimeHandler != Self.macOSRuntimeName {
                    return (Task { client }, config, false)
                }
                let task = Task {
                    try await client.startWorkload(id)
                    return client
                }
                state.bootstrapTask = task
                await self.setContainerState(id, state, context: context)
                return (task, config, false)
            }

            let task = Task {
                let runtimeClient = try await self.makeRuntimeClient(
                    id: id,
                    configuration: config,
                    existingClient: nil
                )
                if config.runtimeHandler == Self.macOSRuntimeName {
                    try await runtimeClient.bootstrap(
                        stdio: stdio,
                        presentGUI: presentGUI,
                        progressUpdateEndpoint: progressUpdateEndpoint.value
                    )
                } else {
                    let networkBootstrapInfos = try await self.networkBootstrapInfos(for: config)
                    try await runtimeClient.bootstrap(
                        stdio: stdio,
                        networkBootstrapInfos: networkBootstrapInfos,
                        dynamicEnv: dynamicEnv
                    )
                }
                return runtimeClient
            }

            state.bootstrapTask = task
            await self.setContainerState(id, state, context: context)
            return (task, config, true)
        }

        do {
            let runtimeClient = try await task.value
            try await self.lock.withLock { context in
                var state = try await self.getContainerState(id: id, context: context)
                let previousStatus = state.snapshot.status
                let sandboxSnapshot = try await runtimeClient.state()
                let runtimeStatus = Self.containerRuntimeStatus(from: sandboxSnapshot)
                let shouldRegisterExit = cleanupOnFailure || (previousStatus != .running && runtimeStatus == .running)
                if shouldRegisterExit {
                    try await self.registerContainerExitCallback(id: id)
                }
                if runtimeStatus == .running, previousStatus != .running {
                    try await self.trackContainerExit(id: id, client: runtimeClient)
                }
                state.snapshot.status = runtimeStatus
                state.snapshot.networks = sandboxSnapshot.networks
                state.snapshot.startedDate =
                    runtimeStatus == .running
                    ? (state.snapshot.startedDate ?? Date())
                    : nil
                state.client = runtimeClient
                state.sandboxStartTask = nil
                state.bootstrapTask = nil
                await self.setContainerState(id, state, context: context)
            }
        } catch {
            if cleanupOnFailure {
                await self.exitMonitor.stopTracking(id: id)
                await self.cleanUpFailedRuntimeService(id: id, configuration: config)
            }
            try? await self.lock.withLock { context in
                var state = try await self.getContainerState(id: id, context: context)
                state.bootstrapTask = nil
                await self.setContainerState(id, state, context: context)
            }

            throw error
        }
    }

    /// Start the sandbox guest without starting any workloads.
    public func startSandbox(
        id: String,
        presentGUI: Bool = true,
        progressUpdateEndpoint: xpc_endpoint_t? = nil
    ) async throws {
        self.log.debug("\(#function)")
        self.log.info(
            "container service startSandbox request",
            metadata: [
                "id": "\(id)",
                "present_gui": "\(presentGUI)",
            ])
        let progressUpdateEndpoint = SendableXPCEndpoint(value: progressUpdateEndpoint)

        let (task, config, cleanupOnFailure) = try await self.lock.withLock { context -> (Task<RuntimeClient, Error>, ContainerConfiguration, Bool) in
            var state = try await self.getContainerState(id: id, context: context)
            try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)

            let path = self.containerRoot.appendingPathComponent(id)
            let (config, _) = try Self.getContainerConfiguration(at: path)

            if let task = state.sandboxStartTask {
                return (task, config, false)
            }
            if let task = state.bootstrapTask {
                return (task, config, false)
            }

            let existingClient = state.client
            let task = Task {
                let runtimeClient = try await self.makeRuntimeClient(
                    id: id,
                    configuration: config,
                    existingClient: existingClient
                )
                try await runtimeClient.createSandbox()
                try await runtimeClient.startSandbox(
                    stdio: [nil, nil, nil],
                    presentGUI: presentGUI,
                    progressUpdateEndpoint: progressUpdateEndpoint.value
                )
                return runtimeClient
            }

            state.sandboxStartTask = task
            await self.setContainerState(id, state, context: context)
            return (task, config, existingClient == nil)
        }

        do {
            let runtimeClient = try await task.value
            let sandboxSnapshot = try await runtimeClient.state()
            try await self.lock.withLock { context in
                var state = try await self.getContainerState(id: id, context: context)
                let runtimeStatus = Self.containerRuntimeStatus(from: sandboxSnapshot)
                let shouldTrackExit = state.snapshot.status != .running && runtimeStatus == .running
                if shouldTrackExit {
                    try await self.registerContainerExitCallback(id: id)
                    try await self.trackContainerExit(id: id, client: runtimeClient)
                }
                state.client = runtimeClient
                state.sandboxStartTask = nil
                state.snapshot.status = runtimeStatus
                state.snapshot.networks = sandboxSnapshot.networks
                state.snapshot.startedDate =
                    runtimeStatus == .running
                    ? (state.snapshot.startedDate ?? Date())
                    : nil
                await self.setContainerState(id, state, context: context)
            }
        } catch {
            if cleanupOnFailure {
                await self.cleanUpFailedRuntimeService(id: id, configuration: config)
            }
            try? await self.lock.withLock { context in
                var state = try await self.getContainerState(id: id, context: context)
                state.sandboxStartTask = nil
                await self.setContainerState(id, state, context: context)
            }
            throw error
        }
    }

    /// Present the desktop window for a running macOS sandbox guest.
    public func showSandboxGUI(id: String) async throws {
        self.log.info("container service showSandboxGUI request", metadata: ["id": "\(id)"])
        let client = try await self.lock.withLock { context -> RuntimeClient in
            let state = try await self.getContainerState(id: id, context: context)
            try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
            return try state.getClient()
        }

        try await client.showGUI()
    }

    public func inspectSandbox(id: String) async throws -> SandboxSnapshot {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)

        if let task = state.bootstrapTask ?? state.sandboxStartTask {
            let client = try await task.value
            return try await client.state()
        }
        if let client = state.client {
            return try await client.state()
        }

        let path = self.containerRoot.appendingPathComponent(id)
        let (configuration, _) = try Self.getContainerConfiguration(at: path)
        return try Self.makePersistedSandboxSnapshot(
            root: path,
            configuration: configuration,
            containerStatus: state.snapshot.status,
            containerNetworks: state.snapshot.networks,
            startedDate: state.snapshot.startedDate
        )
    }

    public func createWorkload(
        id: String,
        configuration: WorkloadConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        let stagedContainerConfiguration =
            state.snapshot.status == .running
            ? nil
            : try await self.prepareSandboxConfigurationForWorkload(
                id: id,
                workloadConfiguration: configuration
            )
        let shouldReplacePreparedClient =
            state.client != nil
            && state.snapshot.status != .running
            && !configuration.mounts.isEmpty
        if shouldReplacePreparedClient {
            if let existingClient = state.client {
                // The macOS runtime owns the network allocation sessions. Release
                // them before replacing the helper so a persisted lease never
                // outlives the XPC session that owns the allocation.
                try await existingClient.releaseSandboxNetwork()
            }
            try? self.deregisterSandboxService(
                id: id,
                runtimeName: stagedContainerConfiguration?.runtimeHandler ?? state.snapshot.configuration.runtimeHandler
            )
            try await self.lock.withLock { context in
                var updated = try await self.getContainerState(id: id, context: context)
                updated.client = nil
                updated.snapshot.networks = []
                await self.setContainerState(id, updated, context: context)
            }
        }
        let client: RuntimeClient
        if let task = state.bootstrapTask ?? state.sandboxStartTask {
            client = try await task.value
        } else if let existingClient = shouldReplacePreparedClient ? nil : state.client {
            client = existingClient
        } else {
            let containerConfiguration: ContainerConfiguration
            if let stagedContainerConfiguration {
                containerConfiguration = stagedContainerConfiguration
            } else {
                let (loadedConfiguration, _) = try Self.getContainerConfiguration(
                    at: self.containerRoot.appendingPathComponent(id)
                )
                containerConfiguration = loadedConfiguration
            }
            let preparedClient = try await self.makeRuntimeClient(
                id: id,
                configuration: containerConfiguration,
                existingClient: nil
            )
            do {
                try await preparedClient.createSandbox()
            } catch {
                await self.cleanUpFailedRuntimeService(id: id, configuration: containerConfiguration)
                throw error
            }
            try await self.lock.withLock { context in
                var updated = try await self.getContainerState(id: id, context: context)
                if updated.client == nil {
                    updated.client = preparedClient
                    await self.setContainerState(id, updated, context: context)
                }
            }
            client = preparedClient
        }
        do {
            try await client.createWorkload(configuration, stdio: stdio)
        } catch {
            guard state.snapshot.status != .running else {
                throw error
            }
            let containerConfiguration: ContainerConfiguration
            if let stagedContainerConfiguration {
                containerConfiguration = stagedContainerConfiguration
            } else {
                let (loadedConfiguration, _) = try Self.getContainerConfiguration(
                    at: self.containerRoot.appendingPathComponent(id)
                )
                containerConfiguration = loadedConfiguration
            }
            try await client.startSandbox(
                stdio: [nil, nil, nil],
                presentGUI: containerConfiguration.macosGuest?.guiEnabled ?? true
            )
            let sandboxSnapshot = try await client.state()
            try await self.lock.withLock { context in
                var updated = try await self.getContainerState(id: id, context: context)
                updated.client = client
                updated.snapshot.status = Self.containerRuntimeStatus(from: sandboxSnapshot)
                updated.snapshot.networks = sandboxSnapshot.networks
                updated.snapshot.startedDate = updated.snapshot.startedDate ?? Date()
                await self.setContainerState(id, updated, context: context)
            }
            try await client.createWorkload(configuration, stdio: stdio)
        }
    }

    public func startWorkload(id: String, workloadID: String) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        let client = try state.getClient()
        try await client.startWorkload(workloadID)

        if workloadID == id {
            let shouldTrackExit = try await self.lock.withLock { context -> Bool in
                var updated = try await self.getContainerState(id: id, context: context)
                let shouldTrack = updated.snapshot.status != .running
                updated.snapshot.status = .running
                updated.snapshot.startedDate = updated.snapshot.startedDate ?? Date()
                await self.setContainerState(id, updated, context: context)
                return shouldTrack
            }
            if shouldTrackExit {
                try await self.registerContainerExitCallback(id: id)
                try await self.trackContainerExit(id: id, client: client)
            }
        }
    }

    public func attachWorkload(
        id: String,
        workloadID: String,
        attachmentID: String,
        options: WorkloadAttachOptions,
        stdio: [FileHandle?]
    ) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        let client = try state.getClient()
        try await client.attachWorkload(
            workloadID,
            attachmentID: attachmentID,
            options: options,
            stdio: stdio
        )
    }

    public func detachWorkloadAttachment(
        id: String,
        workloadID: String,
        attachmentID: String
    ) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        let client = try state.getClient()
        try await client.detachWorkloadAttachment(attachmentID, from: workloadID)
    }

    public func stopWorkload(
        id: String,
        workloadID: String,
        options: ContainerStopOptions = .default
    ) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        let client = try state.getClient()
        try await client.stopWorkload(workloadID, options: options)
    }

    public func removeWorkload(id: String, workloadID: String) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        let client = try state.getClient()
        try await client.removeWorkload(workloadID)
    }

    public func inspectWorkload(id: String, workloadID: String) async throws -> WorkloadSnapshot {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)

        if let task = state.bootstrapTask ?? state.sandboxStartTask {
            let client = try await task.value
            return try await client.inspectWorkload(workloadID)
        }
        if let client = state.client {
            return try await client.inspectWorkload(workloadID)
        }

        let path = self.containerRoot.appendingPathComponent(id)
        let (configuration, _) = try Self.getContainerConfiguration(at: path)
        let sandboxSnapshot = try Self.makePersistedSandboxSnapshot(
            root: path,
            configuration: configuration,
            containerStatus: state.snapshot.status,
            containerNetworks: state.snapshot.networks,
            startedDate: state.snapshot.startedDate
        )
        guard let snapshot = sandboxSnapshot.workloads.first(where: { $0.id == workloadID }) else {
            throw ContainerizationError(.notFound, message: "workload \(workloadID) not found")
        }
        return snapshot
    }

    public func sandboxLogPaths(id: String) async throws -> SandboxLogPaths {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        let root = self.containerRoot.appendingPathComponent(id)
        return Self.makeSandboxLogPaths(root: root)
    }

    public func prepareSandboxNetwork(sandboxID: String) async throws -> SandboxNetworkState {
        self.log.debug("\(#function)")

        let id = sandboxID
        let (config, existingClient) = try await self.lock.withLock { context -> (ContainerConfiguration, RuntimeClient?) in
            let state = try await self.getContainerState(id: id, context: context)
            try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
            let path = self.containerRoot.appendingPathComponent(id)
            let (configuration, _) = try Self.getContainerConfiguration(at: path)
            return (configuration, state.client)
        }

        let client = try await self.makeRuntimeClient(
            id: id,
            configuration: config,
            existingClient: existingClient
        )
        let networkState: SandboxNetworkState
        do {
            try await client.createSandbox()
            networkState = try await client.prepareSandboxNetwork()
        } catch {
            if existingClient == nil {
                await self.cleanUpFailedRuntimeService(id: id, configuration: config)
            }
            throw error
        }

        try await self.lock.withLock { context in
            var state = try await self.getContainerState(id: id, context: context)
            state.client = client
            state.snapshot.networks = networkState.attachments
            await self.setContainerState(id, state, context: context)
        }
        return networkState
    }

    public func inspectSandboxNetwork(sandboxID: String) async throws -> SandboxNetworkState {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: sandboxID)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        if let task = state.bootstrapTask ?? state.sandboxStartTask {
            do {
                let client = try await task.value
                return try await client.inspectSandboxNetwork()
            } catch {
                return try self.storedSandboxNetworkState(
                    id: sandboxID,
                    state: state,
                    fallbackError: error
                )
            }
        }
        if let client = state.client {
            do {
                return try await client.inspectSandboxNetwork()
            } catch {
                return try self.storedSandboxNetworkState(
                    id: sandboxID,
                    state: state,
                    fallbackError: error
                )
            }
        }

        return try self.storedSandboxNetworkState(id: sandboxID, state: state)
    }

    public func releaseSandboxNetwork(sandboxID: String) async throws {
        self.log.debug("\(#function)")

        let id = sandboxID
        let (config, existingClient) = try await self.lock.withLock { context -> (ContainerConfiguration, RuntimeClient?) in
            let state = try await self.getContainerState(id: id, context: context)
            try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
            let path = self.containerRoot.appendingPathComponent(id)
            let (configuration, _) = try Self.getContainerConfiguration(at: path)
            return (configuration, state.client)
        }

        let client = try await self.makeRuntimeClient(
            id: id,
            configuration: config,
            existingClient: existingClient
        )
        do {
            try await client.releaseSandboxNetwork()
        } catch {
            if existingClient == nil {
                await self.cleanUpFailedRuntimeService(id: id, configuration: config)
            }
            throw error
        }

        try await self.lock.withLock { context in
            var state = try await self.getContainerState(id: id, context: context)
            state.client = client
            state.snapshot.networks = []
            await self.setContainerState(id, state, context: context)
        }
    }

    private func storedSandboxNetworkState(
        id: String,
        state: ContainerState,
        fallbackError: Error? = nil
    ) throws -> SandboxNetworkState {
        let root = self.containerRoot.appendingPathComponent(id)
        let attachments = (try MacOSGuestNetworkLeaseStore.load(from: root))?.attachments ?? state.snapshot.networks
        guard !attachments.isEmpty || fallbackError == nil else {
            throw fallbackError!
        }
        if let fallbackError {
            self.log.debug(
                "using persisted sandbox network state after live inspect failed",
                metadata: [
                    "id": "\(id)",
                    "attachments": "\(attachments.count)",
                    "error": "\(fallbackError)",
                ]
            )
        }
        return SandboxNetworkState(attachments: attachments)
    }

    public func applySandboxPolicy(_ policy: SandboxNetworkPolicy) async throws -> SandboxNetworkPolicyState {
        self.log.debug("\(#function)")

        let id = policy.sandboxID
        let (config, existingClient) = try await self.lock.withLock { context -> (ContainerConfiguration, RuntimeClient?) in
            let state = try await self.getContainerState(id: id, context: context)
            try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
            let path = self.containerRoot.appendingPathComponent(id)
            let (configuration, _) = try Self.getContainerConfiguration(at: path)
            return (configuration, state.client)
        }

        let client = try await self.makeRuntimeClient(
            id: id,
            configuration: config,
            existingClient: existingClient
        )
        let policyState = try await client.applySandboxPolicy(policy)

        if existingClient == nil {
            try await self.lock.withLock { context in
                var state = try await self.getContainerState(id: id, context: context)
                state.client = client
                await self.setContainerState(id, state, context: context)
            }
        }
        return policyState
    }

    public func removeSandboxPolicy(sandboxID: String) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: sandboxID)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        if let client = state.client {
            try await client.removeSandboxPolicy()
            return
        }

        let root = self.containerRoot.appendingPathComponent(sandboxID)
        try MacOSGuestHostNetworkPolicyStore.remove(from: root)
        try MacOSGuestNetworkPolicyStore.remove(from: root)
    }

    public func inspectSandboxPolicy(sandboxID: String) async throws -> SandboxNetworkPolicyState? {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: sandboxID)
        try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)
        if let task = state.bootstrapTask ?? state.sandboxStartTask {
            let client = try await task.value
            return try await client.inspectSandboxPolicy()
        }
        if let client = state.client {
            return try await client.inspectSandboxPolicy()
        }

        let root = self.containerRoot.appendingPathComponent(sandboxID)
        return try MacOSGuestNetworkPolicyStore.load(from: root)
    }

    /// Create a new process in the container.
    public func createProcess(
        id: String,
        processID: String,
        config: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
                "command": "\(config.arguments.isEmpty ? "" : config.arguments[0])",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.createProcess(
            processID,
            config: config,
            stdio: stdio
        )
    }

    /// Start a process in a container. This can either be a process created via
    /// createProcess, or the init process of the container which requires
    /// id == processID.
    public func startProcess(id: String, processID: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        enum StartWork {
            case alreadyStarted
            case run(task: Task<StartProcessResult, Error>, client: RuntimeClient, isInit: Bool)
        }

        let work = try await self.lock.withLock(
            logMetadata: ["acquirer": "\(#function)", "id": "\(id)", "processId": "\(processID)"]
        ) { context -> StartWork in
            var state = try await self.getContainerState(id: id, context: context)

            let isInit = Self.isInitProcess(id: id, processID: processID)
            if state.snapshot.status == .running && isInit {
                return .alreadyStarted
            }

            let client = try state.getClient()
            if let task = state.processStartTasks[processID] {
                return .run(task: task, client: client, isInit: isInit)
            }

            let task = Task {
                try await client.startProcess(processID)

                guard isInit else {
                    return StartProcessResult.exec
                }

                let sandboxSnapshot = try await client.state()
                return .initProcessStarted(networks: sandboxSnapshot.networks)
            }
            state.processStartTasks[processID] = task
            await self.setContainerState(id, state, context: context)
            return .run(task: task, client: client, isInit: isInit)
        }

        switch work {
        case .alreadyStarted:
            return
        case .run(let task, let client, let isInit):
            do {
                let result = try await task.value
                let shouldTrackExit = try await self.lock.withLock { context -> Bool in
                    var state = try await self.getContainerState(id: id, context: context)
                    state.processStartTasks.removeValue(forKey: processID)
                    var shouldTrackExit = false
                    if case .initProcessStarted(let networks) = result {
                        shouldTrackExit = state.snapshot.status != .running
                        state.snapshot.status = .running
                        state.snapshot.networks = networks
                        state.snapshot.startedDate = Date()
                    }
                    await self.setContainerState(id, state, context: context)
                    return shouldTrackExit
                }
                if isInit, shouldTrackExit {
                    try await self.trackContainerExit(id: id, client: client)
                }
            } catch {
                try? await self.lock.withLock { context in
                    var state = try await self.getContainerState(id: id, context: context)
                    state.processStartTasks.removeValue(forKey: processID)
                    await self.setContainerState(id, state, context: context)
                }
                if isInit {
                    await self.exitMonitor.stopTracking(id: id)
                    try? await client.stop(options: ContainerStopOptions.default)
                }
                throw error
            }
        }
    }

    /// Send a signal to the container.
    public func kill(
        id: String,
        processID: String,
        signal: Int64,
        attachmentID: String? = nil
    ) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.kill(processID, signal: signal, attachmentID: attachmentID)

        if processID == id,
            let rawSignal = Int32(exactly: signal),
            Signal(rawValue: rawSignal) == .kill
        {
            try await handleContainerExit(id: id)
        }
    }

    public func kill(id: String, processID: String, signal: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
                "signal": "\(signal)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.kill(processID, signal: signal)

        // SIGKILL is guaranteed to terminate the target. When directed at the
        // container's init process, follow up with the same API-server cleanup
        // that `stop` performs.
        if processID == id, (try? Signal(signal)) == .kill {
            try await handleContainerExit(id: id)
        }
    }

    /// Stop all containers inside the sandbox, aborting any processes currently
    /// executing inside the container, before stopping the underlying sandbox.
    public func stop(id: String, options: ContainerStopOptions) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)

        // Stop should be idempotent.
        let client: RuntimeClient
        do {
            client = try state.getClient()
        } catch {
            return
        }

        var resolvedOptions = options
        if resolvedOptions.signal == nil, let stopSignal = state.snapshot.configuration.stopSignal {
            resolvedOptions.signal = stopSignal
        }

        do {
            try await client.stop(options: resolvedOptions)
        } catch let err as ContainerizationError {
            if err.code != .interrupted {
                throw err
            }
        }
        try await handleContainerExit(id: id)
    }

    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "port": "\(port)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "port": "\(port)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.dial(port)
    }

    /// Wait waits for the container's init process or exec to exit and returns the
    /// exit status.
    public func wait(id: String, processID: String) async throws -> ExitStatus {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.wait(processID)
    }

    /// Resize resizes the container's PTY if one exists.
    public func resize(
        id: String,
        processID: String,
        size: Terminal.Size,
        attachmentID: String? = nil
    ) async throws {
        log.trace(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.trace(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.resize(processID, size: size, attachmentID: attachmentID)
    }

    // Get the logs for the container.
    public func logs(id: String) async throws -> [FileHandle] {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // Logs doesn't care if the container is running or not, just that
        // the bundle is there, and that the files actually exist. We do
        // first try and get the container state so we get a nicer error message
        // (container foo not found) however.
        do {
            _ = try _getContainerState(id: id)
            let path = self.containerRoot.appendingPathComponent(id)
            let bundle = ContainerResource.Bundle(path: path)
            return [
                try FileHandle(forReadingFrom: bundle.containerLog),
                try FileHandle(forReadingFrom: bundle.bootlog),
            ]
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to open container logs: \(error)"
            )
        }
    }

    /// Copy a file or directory from the host into the container.
    public func copyIn(id: String, source: String, destination: String, mode: UInt32, createParents: Bool = true) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        try await client.copyIn(source: source, destination: destination, mode: mode, createParents: createParents)
    }

    /// Copy a file or directory from the container to the host.
    public func copyOut(id: String, source: String, destination: String, createParents: Bool = true) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        try await client.copyOut(source: source, destination: destination, createParents: createParents)
    }

    /// Get statistics for the container.
    public func stats(id: String) async throws -> ContainerStats {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.statistics()
    }

    /// Delete a container and its resources.
    public func delete(id: String, force: Bool) async throws {
        log.info(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "force": "\(force)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        switch state.snapshot.status {
        case .running:
            if !force {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(id) is \(state.snapshot.status) and can not be deleted"
                )
            }
            let opts = ContainerStopOptions(
                timeoutInSeconds: 5,
                signal: "SIGKILL"
            )
            let client = try state.getClient()
            try await client.stop(options: opts)
            try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                self.log.info(
                    "ContainersService: attempt cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
                try await self.cleanUp(id: id, context: context)
                self.log.info(
                    "ContainersService: successful cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
            }
        case .stopping:
            throw ContainerizationError(
                .invalidState,
                message: "container \(id) is \(state.snapshot.status) and can not be deleted"
            )
        default:
            try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                try await self.cleanUp(id: id, context: context)
            }
        }
    }

    public func containerDiskUsage(id: String) async throws -> UInt64 {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let containerPath = self.containerRoot.appendingPathComponent(id).path

        return FileManager.default.allocatedSize(of: URL(fileURLWithPath: containerPath))
    }

    public func exportRootfs(id: String, archive: URL) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .stopped else {
            throw ContainerizationError(.invalidState, message: "container is not stopped")
        }

        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let rootfs = bundle.containerRootfsBlock
        try EXT4.EXT4Reader(blockDevice: FilePath(rootfs)).export(archive: FilePath(archive))
    }

    private func handleContainerExit(id: String, code: ExitStatus? = nil) async throws {
        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { [self] context in
            try await handleContainerExit(id: id, code: code, context: context)
        }
    }

    private func handleContainerExit(id: String, code: ExitStatus?, context: AsyncLock.Context) async throws {
        if let code {
            self.log.info(
                "handling container exit",
                metadata: [
                    "id": "\(id)",
                    "rc": "\(code)",
                ])
        }

        var state: ContainerState
        do {
            state = try self.getContainerState(id: id, context: context)
            if state.snapshot.status == .stopped {
                return
            }
        } catch {
            // Was auto removed by the background thread, nothing for us to do.
            return
        }

        await self.exitMonitor.stopTracking(id: id)

        // Shutdown and deregister the runtime service
        self.log.info("shutting down runtime service", metadata: ["id": "\(id)"])

        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let config = try bundle.configuration
        let label = Self.fullLaunchdServiceLabel(
            runtimeName: config.runtimeHandler,
            instanceId: id
        )

        // Try to shutdown the client gracefully, but if the runtime service
        // is already dead (e.g., killed externally), we should still continue
        // with state cleanup.
        if let client = state.client {
            do {
                try await client.shutdown()
            } catch {
                self.log.error(
                    "failed to shutdown runtime service",
                    metadata: [
                        "id": "\(id)",
                        "error": "\(error)",
                    ])
            }
        }

        // Deregister the service, launchd will terminate the process.
        // This may also fail if the service was already deregistered or
        // the process was killed externally.
        do {
            try ServiceManager.deregister(fullServiceLabel: label)
            self.log.info("deregistered runtime service", metadata: ["id": "\(id)"])
        } catch {
            self.log.error(
                "failed to deregister runtime service",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }

        state.snapshot.status = .stopped
        state.snapshot.networks = []
        state.client = nil
        state.sandboxStartTask = nil
        state.bootstrapTask = nil
        await self.setContainerState(id, state, context: context)

        let options = try getContainerCreationOptions(id: id)
        if options.autoRemove {
            try await self.cleanUp(id: id, context: context)
        }
    }

    private static func fullLaunchdServiceLabel(runtimeName: String, instanceId: String) -> String {
        "\(Self.launchdDomainString)/\(Self.machServicePrefix).\(runtimeName).\(instanceId)"
    }

    private func makeRuntimeClient(
        id: String,
        configuration: ContainerConfiguration,
        existingClient: RuntimeClient?
    ) async throws -> RuntimeClient {
        if let existingClient {
            return existingClient
        }

        let path = self.containerRoot.appendingPathComponent(id)
        guard let plugin = self.runtimePlugins.first(where: { $0.name == configuration.runtimeHandler }) else {
            throw ContainerizationError(
                .notFound,
                message: "unable to locate runtime plugin \(configuration.runtimeHandler)"
            )
        }

        let label = Self.fullLaunchdServiceLabel(
            runtimeName: configuration.runtimeHandler,
            instanceId: id
        )
        if try !ServiceManager.isRegistered(fullServiceLabel: label) {
            try Self.registerService(
                plugin: plugin,
                loader: self.pluginLoader,
                configuration: configuration,
                path: path,
                debug: self.debugHelpers
            )
        }

        return try await RuntimeClient.create(
            id: id,
            runtime: configuration.runtimeHandler
        )
    }

    private func networkBootstrapInfos(for configuration: ContainerConfiguration) async throws -> [NetworkBootstrapInfo] {
        var infos: [NetworkBootstrapInfo] = []
        for attachment in configuration.networks {
            guard let plugin = try await self.networksService?.plugin(for: attachment.network) else {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to get plugin for network \(attachment.network)"
                )
            }
            infos.append(NetworkBootstrapInfo(plugin: plugin))
        }
        return infos
    }

    private func cleanUpFailedRuntimeService(
        id: String,
        configuration: ContainerConfiguration
    ) async {
        await self.exitMonitor.stopTracking(id: id)

        if configuration.runtimeHandler == Self.macOSRuntimeName,
            let client = try? await RuntimeClient.create(id: id, runtime: configuration.runtimeHandler)
        {
            // The network plugin owns an allocation only while this runtime's
            // XPC session is alive. Explicitly release before terminating the
            // helper, then discard any persisted projection of that lease.
            try? await client.releaseSandboxNetwork()
        }

        try? self.deregisterSandboxService(id: id, runtimeName: configuration.runtimeHandler)
        if configuration.runtimeHandler == Self.macOSRuntimeName {
            let root = self.containerRoot.appendingPathComponent(id)
            try? MacOSGuestNetworkLeaseStore.remove(from: root)
        }
    }

    private func deregisterSandboxService(id: String, runtimeName: String) throws {
        let label = Self.fullLaunchdServiceLabel(
            runtimeName: runtimeName,
            instanceId: id
        )
        try ServiceManager.deregister(fullServiceLabel: label)
    }

    private func prepareSandboxConfigurationForWorkload(
        id: String,
        workloadConfiguration: WorkloadConfiguration
    ) async throws -> ContainerConfiguration {
        let path = self.containerRoot.appendingPathComponent(id)
        var (containerConfiguration, _) = try Self.getContainerConfiguration(at: path)
        try Self.requireMacOSGuestControl(configuration: containerConfiguration)

        let mergedMounts = try MacOSGuestMountMapping.mergeHostPathMounts([
            containerConfiguration.mounts,
            workloadConfiguration.mounts,
        ])
        if !workloadConfiguration.mounts.isEmpty {
            containerConfiguration.mounts = mergedMounts
            let updatedConfiguration = containerConfiguration
            let bundle = ContainerResource.Bundle(path: path)
            try bundle.set(configuration: updatedConfiguration)
            let runtimeConfiguration = try RuntimeConfiguration.readRuntimeConfiguration(from: path)
            let updatedRuntimeConfiguration = RuntimeConfiguration(
                path: runtimeConfiguration.path,
                initialFilesystem: runtimeConfiguration.initialFilesystem,
                kernel: runtimeConfiguration.kernel,
                containerConfiguration: updatedConfiguration,
                containerRootFilesystem: runtimeConfiguration.containerRootFilesystem,
                options: runtimeConfiguration.options,
                runtimeData: runtimeConfiguration.runtimeData
            )
            try updatedRuntimeConfiguration.writeRuntimeConfiguration()
            try await self.lock.withLock { context in
                var state = try await self.getContainerState(id: id, context: context)
                state.snapshot.configuration = updatedConfiguration
                await self.setContainerState(id, state, context: context)
            }
        }

        return containerConfiguration
    }

    private static func requireMacOSGuestControl(configuration: ContainerConfiguration) throws {
        guard configuration.runtimeHandler == Self.macOSRuntimeName else {
            throw ContainerizationError(
                .unsupported,
                message: "sandbox/workload control APIs are currently only supported for macOS guest sandboxes"
            )
        }
    }

    private static func makePersistedSandboxSnapshot(
        root: URL,
        configuration: ContainerConfiguration,
        containerStatus: RuntimeStatus,
        containerNetworks: [Attachment],
        startedDate: Date?
    ) throws -> SandboxSnapshot {
        let networks = (try MacOSGuestNetworkLeaseStore.load(from: root))?.attachments ?? containerNetworks
        let workloads = try loadPersistedWorkloadSnapshots(root: root, configuration: configuration)
        let networkPolicy = try MacOSGuestNetworkPolicyStore.load(from: root)
        return SandboxSnapshot(
            configuration: SandboxConfiguration(containerConfiguration: configuration),
            status: containerStatus,
            networks: networks,
            containers: [
                ContainerSnapshot(
                    configuration: configuration,
                    status: containerStatus,
                    networks: networks,
                    startedDate: startedDate
                )
            ],
            workloads: workloads,
            networkPolicy: networkPolicy
        )
    }

    private static func loadPersistedWorkloadSnapshots(
        root: URL,
        configuration: ContainerConfiguration
    ) throws -> [WorkloadSnapshot] {
        let layout = MacOSSandboxLayout(root: root)
        var configurations: [WorkloadConfiguration] = [
            WorkloadConfiguration(
                id: configuration.id,
                processConfiguration: configuration.initProcess
            )
        ]

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: layout.workloadsDirectoryURL.path) {
            for candidate in try fileManager.contentsOfDirectory(
                at: layout.workloadsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let configURL = candidate.appendingPathComponent("config.json")
                guard fileManager.fileExists(atPath: configURL.path) else {
                    continue
                }
                let data = try Data(contentsOf: configURL)
                let workload = try JSONDecoder().decode(WorkloadConfiguration.self, from: data)
                if workload.id == configuration.id {
                    configurations[0] = workload
                } else {
                    configurations.append(workload)
                }
            }
        }

        return
            configurations
            .sorted(by: { $0.id < $1.id })
            .map { workload in
                WorkloadSnapshot(
                    configuration: workload,
                    status: .stopped,
                    stdoutLogPath: layout.workloadStdoutLogURL(id: workload.id).path,
                    stderrLogPath: layout.workloadStderrLogURL(id: workload.id).path
                )
            }
    }

    private static func makeSandboxLogPaths(root: URL) -> SandboxLogPaths {
        let layout = MacOSSandboxLayout(root: root)
        return SandboxLogPaths(
            eventLogPath: layout.stdioLogURL.path,
            bootLogPath: layout.bootLogURL.path,
            guestAgentLogPath: layout.guestAgentHostLogURL.path,
            guestAgentStderrLogPath: layout.guestAgentHostStderrLogURL.path,
            networkAuditLogPath: layout.networkAuditLogURL.path
        )
    }

    private func _cleanUp(id: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // Did the exit container handler win?
        if self.containers[id] == nil {
            return
        }

        // To be pedantic. This is only needed if something in the "launch
        // the init process" lifecycle fails before actually fork+exec'ing
        // the OCI runtime.
        await self.exitMonitor.stopTracking(id: id)
        let path = self.containerRoot.appendingPathComponent(id)

        // Try to get config for service deregistration
        // Don't fail if bundle is incomplete
        var config: ContainerConfiguration?
        let bundle = ContainerResource.Bundle(path: path)
        do {
            config = try bundle.configuration
        } catch {
            self.log.warning(
                "failed to read bundle configuration during cleanup for container",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }

        // Only try to deregister service if we have a valid config
        // TODO: Change this so we don't have to reread the config
        // possibly store the container ID to service label mapping
        if let config = config {
            let label = Self.fullLaunchdServiceLabel(
                runtimeName: config.runtimeHandler,
                instanceId: id
            )
            try? ServiceManager.deregister(fullServiceLabel: label)
        }

        // Always try to delete the bundle directory, even if it's incomplete
        do {
            try bundle.delete()
        } catch {
            self.log.warning(
                "failed to delete bundle for container",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }

        self.containers.removeValue(forKey: id)
    }

    private func cleanUp(id: String, context: AsyncLock.Context) async throws {
        try await self._cleanUp(id: id)
    }

    private func getContainerCreationOptions(id: String) throws -> ContainerCreateOptions {
        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let options: ContainerCreateOptions = try bundle.load(filename: "options.json")
        return options
    }

    private func getInitBlock(for platform: Platform, imageRef: String? = nil) async throws -> Filesystem {
        let ref = imageRef ?? containerSystemConfig.vminit.image
        let initImage = try await ClientImage.fetch(reference: ref, platform: platform, containerSystemConfig: containerSystemConfig)
        var fs = try await initImage.getCreateSnapshot(platform: platform)
        fs.options = ["ro"]
        return fs
    }

    private static func registerService(
        plugin: Plugin,
        loader: PluginLoader,
        configuration: ContainerConfiguration,
        path: URL,
        debug: Bool
    ) throws {
        let args = [
            "start",
            "--root", path.path,
            "--uuid", configuration.id,
            debug ? "--debug" : nil,
        ].compactMap { $0 }
        try loader.registerWithLaunchd(
            plugin: plugin,
            pluginStateRoot: path,
            args: args,
            instanceId: configuration.id
        )
    }

    private func recoverSandboxStatesAtBoot() async {
        let containerIDs = Array(self.containers.keys).sorted()
        guard !containerIDs.isEmpty else {
            return
        }

        for id in containerIDs {
            await self.recoverSandboxStateAtBoot(id: id)
        }
    }

    private func recoverSandboxStateAtBoot(id: String) async {
        let runtimeName: String
        let fullServiceLabel: String

        do {
            let state = try self._getContainerState(id: id)
            guard state.client == nil, state.bootstrapTask == nil else {
                return
            }
            runtimeName = state.snapshot.configuration.runtimeHandler
            fullServiceLabel = Self.fullLaunchdServiceLabel(
                runtimeName: runtimeName,
                instanceId: id
            )

            guard try ServiceManager.isRegistered(fullServiceLabel: fullServiceLabel) else {
                return
            }
        } catch {
            self.log.warning(
                "failed to determine boot recovery eligibility",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ]
            )
            return
        }

        do {
            let client = try await RuntimeClient.create(id: id, runtime: runtimeName)
            let sandboxSnapshot = try await client.state()
            let shouldTrackExit = try await self.lock.withLock { context -> Bool in
                var state = try await self.getContainerState(id: id, context: context)
                guard state.client == nil, state.bootstrapTask == nil else {
                    return false
                }

                state = Self.makeBootRecoveredState(
                    existing: state,
                    sandboxSnapshot: sandboxSnapshot,
                    client: client
                )
                await self.setContainerState(id, state, context: context)
                return sandboxSnapshot.status == .running
            }

            self.log.info(
                "recovered sandbox state at boot",
                metadata: [
                    "id": "\(id)",
                    "status": "\(sandboxSnapshot.status.rawValue)",
                    "networks": "\(sandboxSnapshot.networks.count)",
                ]
            )

            do {
                try await self.registerContainerExitCallback(id: id)
                guard shouldTrackExit else {
                    return
                }
                try await self.trackContainerExit(id: id, client: client)
            } catch {
                self.log.warning(
                    "failed to start exit tracking for recovered sandbox",
                    metadata: [
                        "id": "\(id)",
                        "error": "\(error)",
                    ]
                )
            }
        } catch {
            self.log.warning(
                "failed to recover sandbox state at boot",
                metadata: [
                    "id": "\(id)",
                    "runtime": "\(runtimeName)",
                    "error": "\(error)",
                ]
            )
        }
    }

    private func registerContainerExitCallback(id: String) async throws {
        try await self.exitMonitor.registerProcess(
            id: id,
            onExit: self.handleContainerExit
        )
    }

    private func trackContainerExit(id: String, client: RuntimeClient) async throws {
        let log = self.log
        let waitFunc: ExitMonitor.WaitHandler = {
            log.info("registering container \(id) with exit monitor")
            let code = try await client.wait(id)
            log.info("container \(id) finished in exit monitor, exit code \(code)")
            return code
        }
        try await self.exitMonitor.track(id: id, waitingOn: waitFunc)
    }

    static func makeBootRecoveredState(
        existing: ContainerState,
        sandboxSnapshot: SandboxSnapshot,
        client: RuntimeClient
    ) -> ContainerState {
        var recovered = existing
        recovered.snapshot.status = containerRuntimeStatus(from: sandboxSnapshot)
        recovered.snapshot.networks = sandboxSnapshot.networks
        if recovered.snapshot.status == .running {
            let containerID = sandboxSnapshot.configuration?.id ?? sandboxSnapshot.containers.first?.id
            let initStartedDate = containerID.flatMap { id in
                sandboxSnapshot.workloads.first(where: { $0.id == id })?.startedDate
            }
            recovered.snapshot.startedDate = recovered.snapshot.startedDate ?? initStartedDate ?? Date()
        } else {
            recovered.snapshot.startedDate = nil
        }
        recovered.client = client
        recovered.sandboxStartTask = nil
        recovered.bootstrapTask = nil
        return recovered
    }

    private static func containerRuntimeStatus(from sandboxSnapshot: SandboxSnapshot) -> RuntimeStatus {
        if sandboxSnapshot.status == .running {
            return .running
        }
        let containerID = sandboxSnapshot.configuration?.id ?? sandboxSnapshot.containers.first?.id
        if let containerID,
            let initWorkload = sandboxSnapshot.workloads.first(where: { $0.id == containerID })
        {
            return initWorkload.status
        }
        return sandboxSnapshot.status
    }

    private func setContainerState(_ id: String, _ state: ContainerState, context: AsyncLock.Context) async {
        self.containers[id] = state
    }

    private func getContainerState(id: String, context: AsyncLock.Context) throws -> ContainerState {
        try self._getContainerState(id: id)
    }

    private func _getContainerState(id: String) throws -> ContainerState {
        let state = self.containers[id]
        guard let state else {
            throw ContainerizationError(
                .notFound,
                message: "container with ID \(id) not found"
            )
        }
        return state
    }

    private static func isInitProcess(id: String, processID: String) -> Bool {
        id == processID
    }

    /// Get container configuration, either from existing bundle or from RuntimeConfiguration
    private static func getContainerConfiguration(at path: URL) throws -> (ContainerConfiguration, ContainerCreateOptions?) {
        let bundle = ContainerResource.Bundle(path: path)
        do {
            let config = try bundle.configuration
            let options: ContainerCreateOptions? = try? bundle.load(filename: "options.json")
            return (config, options)
        } catch {
            // Bundle doesn't exist or incomplete, try runtime configuration
            // This handles containers that were created but not started yet
            let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: path)
            guard let config = runtimeConfig.containerConfiguration else {
                throw ContainerizationError(.internalError, message: "runtime configuration missing container configuration")
            }
            return (config, runtimeConfig.options)
        }
    }
}

extension XPCMessage {
    func signal() throws -> String {
        guard let signal = self.string(key: .signal) else {
            throw ContainerizationError(.invalidArgument, message: "missing signal in xpc message")
        }
        return signal
    }

    func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: .stopOptions) else {
            throw ContainerizationError(.invalidArgument, message: "empty StopOptions")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: .snapshot, value: data)
    }

    func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: .stdin) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: .stdout) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: .stderr) {
            handles[2] = stderr
        }
        return handles
    }

    func setFileHandle(_ handle: FileHandle) {
        self.set(key: .fd, value: handle)
    }

    func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: .processConfig) else {
            throw ContainerizationError(.invalidArgument, message: "empty process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }

    func optionalAttachmentIdentifier() -> String? {
        self.string(key: .attachmentIdentifier)
    }

    func attachOptions() throws -> WorkloadAttachOptions {
        guard let data = self.dataNoCopy(key: .attachOptions) else {
            return .init()
        }
        return try JSONDecoder().decode(WorkloadAttachOptions.self, from: data)
    }
}
