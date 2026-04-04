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
import ContainerPlugin
import ContainerResource
import ContainerSandboxServiceClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging

public actor ContainersService {
    private static let macOSRuntimeName = "container-runtime-macos"

    enum StartProcessResult: Sendable {
        case exec
        case initProcessStarted(networks: [Attachment])
    }

    struct ContainerState {
        var snapshot: ContainerSnapshot
        var client: SandboxClient?
        var sandboxStartTask: Task<SandboxClient, Error>?
        var bootstrapTask: Task<SandboxClient, Error>?
        var processStartTasks: [String: Task<StartProcessResult, Error>] = [:]

        func getClient() throws -> SandboxClient {
            guard let client else {
                var message = "no sandbox client exists"
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
    private let containerRoot: URL
    private let pluginLoader: PluginLoader
    private let runtimePlugins: [Plugin]
    private let exitMonitor: ExitMonitor

    private let lock = AsyncLock()
    private var containers: [String: ContainerState]

    public init(appRoot: URL, pluginLoader: PluginLoader, log: Logger) throws {
        let containerRoot = appRoot.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        self.exitMonitor = ExitMonitor(log: log)
        self.containerRoot = containerRoot
        self.pluginLoader = pluginLoader
        self.log = log
        self.runtimePlugins = pluginLoader.findPlugins().filter { $0.hasType(.runtime) }
        self.containers = try Self.loadAtBoot(root: containerRoot, loader: pluginLoader, log: log)
        Task {
            await self.recoverSandboxStatesAtBoot()
        }
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
                let config = try Self.getContainerConfiguration(at: dir)

                let state = ContainerState(
                    snapshot: .init(
                        configuration: config,
                        status: .stopped,
                        networks: [],
                        startedDate: nil
                    )
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
                log.warning("failed to load container at \(dir.path): \(error)")
            }
        }
        return results
    }

    /// List containers matching the given filters.
    public func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        self.log.debug("\(#function)")

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

            for (key, value) in filters.labels {
                guard snapshot.configuration.labels[key] == value else {
                    return nil
                }
            }

            return snapshot
        }
    }

    /// Execute an operation with the current container list while maintaining atomicity
    /// This prevents race conditions where containers are created during the operation
    public func withContainerList<T: Sendable>(_ operation: @Sendable @escaping ([ContainerSnapshot]) async throws -> T) async throws -> T {
        try await lock.withLock { context in
            let snapshots = await self.containers.values.map { $0.snapshot }
            return try await operation(snapshots)
        }
    }

    /// Calculate disk usage for containers
    /// - Returns: Tuple of (total count, active count, total size, reclaimable size)
    public func calculateDiskUsage() async -> (Int, Int, UInt64, UInt64) {
        await lock.withLock { _ in
            var totalSize: UInt64 = 0
            var reclaimableSize: UInt64 = 0
            var activeCount = 0

            for (id, state) in await self.containers {
                let bundlePath = self.containerRoot.appendingPathComponent(id)
                let containerSize = Self.calculateDirectorySize(at: bundlePath.path)
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
        await lock.withLock { _ in
            var imageRefs = Set<String>()
            for (_, state) in await self.containers {
                imageRefs.insert(state.snapshot.configuration.image.reference)
            }
            return imageRefs
        }
    }

    /// Calculate directory size using APFS-aware resource keys
    /// - Parameter path: Path to directory
    /// - Returns: Total allocated size in bytes
    private static nonisolated func calculateDirectorySize(at path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default

        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }

        var totalSize: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey]
                ),
                let fileSize = resourceValues.totalFileAllocatedSize
            else {
                continue
            }
            totalSize += UInt64(fileSize)
        }

        return totalSize
    }

    /// Create a new container from the provided id and configuration.
    public func create(configuration: ContainerConfiguration, kernel: Kernel?, options: ContainerCreateOptions, initImage: String? = nil) async throws {
        self.log.debug("\(#function)")

        try await self.lock.withLock { context in
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

            let path = self.containerRoot.appendingPathComponent(configuration.id)
            if configuration.runtimeHandler == Self.macOSRuntimeName {
                let runtimeConfig = RuntimeConfiguration(
                    path: path,
                    containerConfiguration: configuration,
                    options: options
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
                self.log.info("Using init image: \(initImage ?? ClientImage.initImageRef)")
                let initFilesystem = try await self.getInitBlock(for: systemPlatform.ociPlatform(), imageRef: initImage)

                let containerImage = ClientImage(description: configuration.image)
                let imageFs = try await containerImage.getCreateSnapshot(platform: configuration.platform)

                let runtimeConfig = RuntimeConfiguration(
                    path: path,
                    initialFilesystem: initFilesystem,
                    kernel: kernel,
                    containerConfiguration: configuration,
                    containerRootFilesystem: imageFs,
                    options: options
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
    public func bootstrap(id: String, stdio: [FileHandle?]) async throws {
        self.log.debug("\(#function)")

        let (task, config, cleanupOnFailure) = try await self.lock.withLock { context -> (Task<SandboxClient, Error>, ContainerConfiguration, Bool) in
            var state = try await self.getContainerState(id: id, context: context)

            let path = self.containerRoot.appendingPathComponent(id)
            let config = try Self.getContainerConfiguration(at: path)
            if let task = state.bootstrapTask {
                return (task, config, false)
            }
            if state.snapshot.configuration.runtimeHandler == Self.macOSRuntimeName,
                let task = state.sandboxStartTask
            {
                let task = Task {
                    let sandboxClient = try await task.value
                    try await sandboxClient.startWorkload(id)
                    return sandboxClient
                }
                state.bootstrapTask = task
                await self.setContainerState(id, state, context: context)
                return (task, config, false)
            }

            if let client = state.client {
                if state.snapshot.status == .running {
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
                let sandboxClient = try await self.makeSandboxClient(
                    id: id,
                    configuration: config,
                    existingClient: nil
                )
                try await sandboxClient.bootstrap(stdio: stdio)
                return sandboxClient
            }

            state.bootstrapTask = task
            await self.setContainerState(id, state, context: context)
            return (task, config, true)
        }

        do {
            let sandboxClient = try await task.value
            try await self.lock.withLock { context in
                var state = try await self.getContainerState(id: id, context: context)
                if state.client == nil {
                    try await self.registerContainerExitCallback(id: id)
                    try await self.trackContainerExit(id: id, client: sandboxClient)
                    let sandboxSnapshot = try await sandboxClient.state()
                    state.snapshot.status = Self.containerRuntimeStatus(from: sandboxSnapshot)
                    state.snapshot.networks = sandboxSnapshot.networks
                    state.snapshot.startedDate =
                        state.snapshot.status == .running
                        ? (state.snapshot.startedDate ?? Date())
                        : nil
                    state.client = sandboxClient
                }
                state.sandboxStartTask = nil
                state.bootstrapTask = nil
                await self.setContainerState(id, state, context: context)
            }
        } catch {
            if cleanupOnFailure {
                await self.exitMonitor.stopTracking(id: id)
                try? self.deregisterSandboxService(id: id, runtimeName: config.runtimeHandler)
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
    public func startSandbox(id: String) async throws {
        self.log.debug("\(#function)")

        let (task, config, cleanupOnFailure) = try await self.lock.withLock { context -> (Task<SandboxClient, Error>, ContainerConfiguration, Bool) in
            var state = try await self.getContainerState(id: id, context: context)
            try Self.requireMacOSGuestControl(configuration: state.snapshot.configuration)

            let path = self.containerRoot.appendingPathComponent(id)
            let config = try Self.getContainerConfiguration(at: path)

            if let task = state.sandboxStartTask {
                return (task, config, false)
            }
            if let task = state.bootstrapTask {
                return (task, config, false)
            }

            let existingClient = state.client
            let task = Task {
                let sandboxClient = try await self.makeSandboxClient(
                    id: id,
                    configuration: config,
                    existingClient: existingClient
                )
                try await sandboxClient.createSandbox()
                try await sandboxClient.startSandbox(stdio: [nil, nil, nil])
                return sandboxClient
            }

            state.sandboxStartTask = task
            await self.setContainerState(id, state, context: context)
            return (task, config, existingClient == nil)
        }

        do {
            let sandboxClient = try await task.value
            let sandboxSnapshot = try await sandboxClient.state()
            try await self.lock.withLock { context in
                var state = try await self.getContainerState(id: id, context: context)
                state.client = sandboxClient
                state.sandboxStartTask = nil
                state.snapshot.networks = sandboxSnapshot.networks
                await self.setContainerState(id, state, context: context)
            }
        } catch {
            if cleanupOnFailure {
                try? self.deregisterSandboxService(id: id, runtimeName: config.runtimeHandler)
            }
            try? await self.lock.withLock { context in
                var state = try await self.getContainerState(id: id, context: context)
                state.sandboxStartTask = nil
                await self.setContainerState(id, state, context: context)
            }
            throw error
        }
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
        let configuration = try Self.getContainerConfiguration(at: path)
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
        let client = try state.getClient()
        try await client.createWorkload(configuration, stdio: stdio)
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
        let configuration = try Self.getContainerConfiguration(at: path)
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

    /// Create a new process in the container.
    public func createProcess(
        id: String,
        processID: String,
        config: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        self.log.debug("\(#function)")

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
        self.log.debug("\(#function)")

        enum StartWork {
            case alreadyStarted
            case run(task: Task<StartProcessResult, Error>, client: SandboxClient, isInit: Bool)
        }

        let work = try await self.lock.withLock { context -> StartWork in
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

                try await self.trackContainerExit(id: id, client: client)

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
                try await self.lock.withLock { context in
                    var state = try await self.getContainerState(id: id, context: context)
                    state.processStartTasks.removeValue(forKey: processID)
                    if case .initProcessStarted(let networks) = result {
                        state.snapshot.status = .running
                        state.snapshot.networks = networks
                        state.snapshot.startedDate = Date()
                    }
                    await self.setContainerState(id, state, context: context)
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
    }

    /// Stop all containers inside the sandbox, aborting any processes currently
    /// executing inside the container, before stopping the underlying sandbox.
    public func stop(id: String, options: ContainerStopOptions) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)

        // Stop should be idempotent.
        let client: SandboxClient
        do {
            client = try state.getClient()
        } catch {
            return
        }

        do {
            try await client.stop(options: options)
        } catch let err as ContainerizationError {
            if err.code != .interrupted {
                throw err
            }
        }
        try await handleContainerExit(id: id)
    }

    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.dial(port)
    }

    /// Wait waits for the container's init process or exec to exit and returns the
    /// exit status.
    public func wait(id: String, processID: String) async throws -> ExitStatus {
        self.log.debug("\(#function)")

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
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.resize(processID, size: size, attachmentID: attachmentID)
    }

    // Get the logs for the container.
    public func logs(id: String) async throws -> [FileHandle] {
        self.log.debug("\(#function)")

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

    /// Get statistics for the container.
    public func stats(id: String) async throws -> ContainerStats {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.statistics()
    }

    /// Delete a container and its resources.
    public func delete(id: String, force: Bool) async throws {
        self.log.debug("\(#function)")
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
                signal: SIGKILL
            )
            let client = try state.getClient()
            try await client.stop(options: opts)
            try await self.lock.withLock { context in
                try await self.cleanUp(id: id, context: context)
            }
        case .stopping:
            throw ContainerizationError(
                .invalidState,
                message: "container \(id) is \(state.snapshot.status) and can not be deleted"
            )
        default:
            try await self.lock.withLock { context in
                try await self.cleanUp(id: id, context: context)
            }
        }
    }

    public func containerDiskUsage(id: String) async throws -> UInt64 {
        self.log.debug("\(#function)")

        let containerPath = self.containerRoot.appendingPathComponent(id).path

        return Self.calculateDirectorySize(at: containerPath)
    }

    private func handleContainerExit(id: String, code: ExitStatus? = nil) async throws {
        try await self.lock.withLock { [self] context in
            try await handleContainerExit(id: id, code: code, context: context)
        }
    }

    private func handleContainerExit(id: String, code: ExitStatus?, context: AsyncLock.Context) async throws {
        if let code {
            self.log.info("Handling container \(id) exit. Code \(code)")
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

        // Shutdown and deregister the sandbox service
        self.log.info("Shutting down sandbox service for \(id)")

        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let config = try bundle.configuration
        let label = Self.fullLaunchdServiceLabel(
            runtimeName: config.runtimeHandler,
            instanceId: id
        )

        // Try to shutdown the client gracefully, but if the sandbox service
        // is already dead (e.g., killed externally), we should still continue
        // with state cleanup.
        if let client = state.client {
            do {
                try await client.shutdown()
            } catch {
                self.log.error("Failed to shutdown sandbox service for \(id): \(error)")
            }
        }

        // Deregister the service, launchd will terminate the process.
        // This may also fail if the service was already deregistered or
        // the process was killed externally.
        do {
            try ServiceManager.deregister(fullServiceLabel: label)
            self.log.info("Deregistered sandbox service for \(id)")
        } catch {
            self.log.error("Failed to deregister sandbox service for \(id): \(error)")
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

    private func makeSandboxClient(
        id: String,
        configuration: ContainerConfiguration,
        existingClient: SandboxClient?
    ) async throws -> SandboxClient {
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
                path: path
            )
        }

        return try await SandboxClient.create(
            id: id,
            runtime: configuration.runtimeHandler
        )
    }

    private func deregisterSandboxService(id: String, runtimeName: String) throws {
        let label = Self.fullLaunchdServiceLabel(
            runtimeName: runtimeName,
            instanceId: id
        )
        try ServiceManager.deregister(fullServiceLabel: label)
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
            workloads: workloads
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
            guestAgentStderrLogPath: layout.guestAgentHostStderrLogURL.path
        )
    }

    private func _cleanUp(id: String) async throws {
        self.log.debug("\(#function)")

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
            self.log.warning("Unable to read bundle configuration during cleanup for container \(id): \(error)")
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
            self.log.warning("Failed to delete bundle for container \(id): \(error)")
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
        let ref = imageRef ?? ClientImage.initImageRef
        let initImage = try await ClientImage.fetch(reference: ref, platform: platform)
        var fs = try await initImage.getCreateSnapshot(platform: platform)
        fs.options = ["ro"]
        return fs
    }

    private static func registerService(
        plugin: Plugin,
        loader: PluginLoader,
        configuration: ContainerConfiguration,
        path: URL
    ) throws {
        let args = [
            "start",
            "--root", path.path,
            "--uuid", configuration.id,
            "--debug",
        ]
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
            let client = try await SandboxClient.create(id: id, runtime: runtimeName)
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

            guard shouldTrackExit else {
                return
            }

            do {
                try await self.registerContainerExitCallback(id: id)
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

    private func trackContainerExit(id: String, client: SandboxClient) async throws {
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
        client: SandboxClient
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
    private static func getContainerConfiguration(at path: URL) throws -> ContainerConfiguration {
        let bundle = ContainerResource.Bundle(path: path)
        do {
            return try bundle.configuration
        } catch {
            // Bundle doesn't exist or incomplete, try runtime configuration
            // This handles containers that were created but not started yet
            let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: path)
            guard let config = runtimeConfig.containerConfiguration else {
                throw ContainerizationError(.internalError, message: "runtime configuration missing container configuration")
            }
            return config
        }
    }
}

extension XPCMessage {
    func signal() throws -> Int64 {
        self.int64(key: .signal)
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
