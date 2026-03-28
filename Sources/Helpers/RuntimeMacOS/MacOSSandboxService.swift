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

import ContainerImagesServiceClient
import ContainerResource
import ContainerSandboxServiceClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import RuntimeMacOSSidecarShared

final class SidecarEventPump: @unchecked Sendable {
    let stream: AsyncStream<MacOSSidecarEvent>

    private let continuation: AsyncStream<MacOSSidecarEvent>.Continuation

    init() {
        var storedContinuation: AsyncStream<MacOSSidecarEvent>.Continuation?
        self.stream = AsyncStream { continuation in
            storedContinuation = continuation
        }
        self.continuation = storedContinuation!
    }

    func yield(_ event: MacOSSidecarEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

public actor MacOSSandboxService {
    private static let defaultAgentPort: UInt32 = 27000
    private static let guestAgentLogGuestPath = "/var/log/container-macos-guest-agent.log"

    private enum State: Equatable {
        case created
        case booted
        case running
        case stopping
        case stopped(Int32)
        case shuttingDown
    }

    struct WorkloadLogFiles {
        let stdoutURL: URL
        let stderrURL: URL
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
    }

    struct Session {
        let processID: String
        let config: ProcessConfiguration
        let stdio: [FileHandle?]
        let includeInSnapshots: Bool
        let stdoutLogURL: URL
        let stderrLogURL: URL
        var stdoutLogHandle: FileHandle?
        var stderrLogHandle: FileHandle?
        var stdinClosed: Bool = false
        var started: Bool = false
        var startedAt: Date?
        var exitStatus: ExitStatus?
        var lastAgentError: String?
        var lastStderr: String?
    }

    struct WorkloadRecord {
        let id: String
        var configuration: WorkloadConfiguration
        var sessionID: String?
        var startedAt: Date?
        var exitStatus: ExitStatus?
        var stdoutLogPath: String
        var stderrLogPath: String
    }

    struct SidecarHandle {
        let launchLabel: String
        let client: MacOSSidecarClient
    }

    let root: URL
    private let connection: xpc_connection_t?
    let log: Logger

    private var sandboxState: State = .created
    var configuration: ContainerConfiguration?
    var sessions: [String: Session] = [:]
    private var workloads: [String: WorkloadRecord] = [:]
    private var workloadSessions: [String: String] = [:]
    private var waiters: [String: [CheckedContinuation<ExitStatus, Never>]] = [:]
    var guestMountsPrepared = false
    var readOnlyInjectionsPrepared = false
    private var guestAgentLogCaptureProcessID: String?

    var logHandle: FileHandle?
    private var bootLogHandle: FileHandle?
    var sidecarHandle: SidecarHandle?
    var sidecarEventPump: SidecarEventPump?
    var sidecarEventPumpTask: Task<Void, Never>?

    public init(root: URL, connection: xpc_connection_t? = nil, log: Logger) {
        self.root = root
        self.connection = connection
        self.log = log
    }

    private var layout: MacOSSandboxLayout {
        MacOSSandboxLayout(root: root)
    }
}

// MARK: - Route handlers

extension MacOSSandboxService {
    @Sendable
    public func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
        guard let connection else {
            throw ContainerizationError(.invalidState, message: "sandbox service has no XPC connection")
        }
        let endpoint = xpc_endpoint_create(connection)
        let reply = message.reply()
        reply.set(key: SandboxKeys.sandboxServiceEndpoint.rawValue, value: endpoint)
        return reply
    }

    @Sendable
    public func createSandbox(_ message: XPCMessage) async throws -> XPCMessage {
        _ = try await prepareSandboxIfNeeded()
        return message.reply()
    }

    @Sendable
    public func startSandbox(_ message: XPCMessage) async throws -> XPCMessage {
        try await startSandboxIfNeeded(stdio: message.stdio())
        return message.reply()
    }

    @Sendable
    public func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
        guard case .created = sandboxState else {
            throw ContainerizationError(.invalidState, message: "container expected to be in created state, got: \(sandboxState)")
        }
        _ = try await prepareSandboxIfNeeded()
        try await startSandboxIfNeeded(stdio: message.stdio())
        return message.reply()
    }

    @Sendable
    public func createWorkload(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let processConfig = try message.processConfig()
        try createWorkloadIfNeeded(
            workloadID: id,
            processConfiguration: processConfig,
            stdio: message.stdio()
        )
        return message.reply()
    }

    @Sendable
    public func startWorkload(_ message: XPCMessage) async throws -> XPCMessage {
        let workloadID = try message.id()
        try await startWorkloadIfNeeded(workloadID: workloadID)
        return message.reply()
    }

    @Sendable
    public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        return try await createWorkload(message)
    }

    @Sendable
    public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        return try await startWorkload(message)
    }

    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let workloadID = try message.id()
        writeContainerLog(Data(("wait requested for workload \(workloadID)\n").utf8))
        let status = try await waitForWorkload(workloadID)
        writeContainerLog(Data(("wait completed for workload \(workloadID) code=\(status.exitCode)\n").utf8))
        let reply = message.reply()
        reply.set(key: SandboxKeys.exitCode.rawValue, value: Int64(status.exitCode))
        reply.set(key: SandboxKeys.exitedAt.rawValue, value: status.exitedAt)
        return reply
    }

    @Sendable
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let workloadID = try message.id()
        let signal = Int32(message.int64(key: SandboxKeys.signal.rawValue))
        try sendSignalToWorkload(workloadID: workloadID, signal: signal)
        return message.reply()
    }

    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        let workloadID = try message.id()
        let width = UInt16(message.uint64(key: SandboxKeys.width.rawValue))
        let height = UInt16(message.uint64(key: SandboxKeys.height.rawValue))
        try sendResizeToWorkload(workloadID: workloadID, width: width, height: height)
        return message.reply()
    }

    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        let stopOptions = try message.stopOptions()
        sandboxState = .stopping
        writeContainerLog(Data(("stop requested signal=\(stopOptions.signal) timeout=\(stopOptions.timeoutInSeconds)\n").utf8))

        if let workloadID = configuration?.id,
            let sessionID = try? sessionID(forWorkload: workloadID),
            let current = sessions[sessionID],
            current.started
        {
            if current.exitStatus == nil {
                writeContainerLog(Data(("stop: init workload \(workloadID) still running; sending signal \(stopOptions.signal)\n").utf8))
                try? sendSignalToSession(processID: sessionID, signal: Int32(stopOptions.signal))
                _ = try? await waitForSession(sessionID, timeout: stopOptions.timeoutInSeconds)
                writeContainerLog(Data(("stop: wait for init workload \(workloadID) finished\n").utf8))
            } else {
                writeContainerLog(Data(("stop: init workload \(workloadID) already exited; skipping signal/wait\n").utf8))
            }
        }

        #if arch(arm64)
        writeContainerLog(Data(("stop: sidecar shutdown start\n").utf8))
        await stopAndQuitSidecarIfPresent()
        writeContainerLog(Data(("stop: sidecar shutdown done\n").utf8))
        #endif

        await releaseSandboxNetworkStateIfNeeded()

        closeAllSessions()
        writeContainerLog(Data(("stop: sessions closed\n").utf8))
        sandboxState = .stopped(0)
        return message.reply()
    }

    @Sendable
    public func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
        switch sandboxState {
        case .created, .stopping, .stopped(_):
            #if arch(arm64)
            await stopAndQuitSidecarIfPresent()
            #endif
            await releaseSandboxNetworkStateIfNeeded()
            closeAllSessions()
            sandboxState = .shuttingDown
            return message.reply()
        default:
            throw ContainerizationError(.invalidState, message: "cannot shutdown while container is running")
        }
    }

    @Sendable
    public func state(_ message: XPCMessage) async throws -> XPCMessage {
        guard let configuration else {
            throw ContainerizationError(.invalidState, message: "container not bootstrapped")
        }
        let status: RuntimeStatus =
            switch sandboxState {
            case .running: .running
            case .stopping: .stopping
            default: .stopped
            }
        let networks = await inspectSandboxNetworkState(containerConfig: configuration).attachments

        let snapshot = SandboxSnapshot(
            configuration: sandboxConfigurationSnapshot(),
            status: status,
            networks: networks,
            containers: [
                ContainerSnapshot(
                    configuration: configuration,
                    status: status,
                    networks: networks,
                    startedDate: workloads[configuration.id]?.startedAt
                )
            ],
            workloads: workloadSnapshots()
        )
        let reply = message.reply()
        try reply.setState(snapshot)
        return reply
    }

    @Sendable
    public func inspectWorkload(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        let snapshot = try workloadSnapshot(processID: processID)
        let reply = message.reply()
        try reply.setWorkloadSnapshot(snapshot)
        return reply
    }

    @Sendable
    public func dial(_ message: XPCMessage) async throws -> XPCMessage {
        #if arch(arm64)
        let port = UInt32(message.uint64(key: SandboxKeys.port.rawValue))
        let fh = try sidecarDial(port: port)
        let reply = message.reply()
        reply.set(key: SandboxKeys.fd.rawValue, value: fh)
        return reply
        #else
        throw ContainerizationError(.unsupported, message: "macOS runtime requires an arm64 host")
        #endif
    }

    @Sendable
    public func statistics(_ message: XPCMessage) async throws -> XPCMessage {
        let stats = ContainerStats(
            id: configuration?.id ?? "unknown",
            memoryUsageBytes: nil,
            memoryLimitBytes: nil,
            cpuUsageUsec: nil,
            networkRxBytes: nil,
            networkTxBytes: nil,
            blockReadBytes: nil,
            blockWriteBytes: nil,
            numProcesses: UInt64(runningWorkloadCount())
        )
        let data = try JSONEncoder().encode(stats)
        let reply = message.reply()
        reply.set(key: SandboxKeys.statistics.rawValue, value: data)
        return reply
    }
}

// MARK: - Bundle and VM setup

extension MacOSSandboxService {
    private func prepareSandboxIfNeeded() async throws -> ContainerConfiguration {
        if let configuration {
            try restorePersistedWorkloadsIfNeeded(containerConfig: configuration)
            return configuration
        }

        let config = try await createBundleIfNeeded()
        self.configuration = config
        try persistSandboxMetadata(for: config)
        try restorePersistedWorkloadsIfNeeded(containerConfig: config)
        return config
    }

    private func startSandboxIfNeeded(stdio: [FileHandle?]) async throws {
        if case .booted = sandboxState {
            return
        }
        if case .running = sandboxState {
            return
        }
        guard case .created = sandboxState else {
            throw ContainerizationError(.invalidState, message: "cannot start sandbox from state \(sandboxState)")
        }

        let config = try await prepareSandboxIfNeeded()
        try openLogsIfNeeded()
        try writeBootLog("bootstrapping container \(config.id)")
        _ = try ensureWorkloadSessionIfNeeded(workloadID: config.id, stdio: stdio)

        do {
            _ = try await prepareSandboxNetworkState(containerConfig: config)
            #if arch(arm64)
            try await startOrRestoreVirtualMachine(config: config)
            await startGuestAgentLogCaptureIfPossible(containerConfig: config)
            #else
            throw ContainerizationError(.unsupported, message: "macOS runtime requires an arm64 host")
            #endif
        } catch {
            await releaseSandboxNetworkStateIfNeeded()
            discardWorkloadSession(workloadID: config.id)
            throw error
        }

        sandboxState = .booted
    }

    private func createWorkloadIfNeeded(
        workloadID: String,
        processConfiguration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) throws {
        guard let _ = configuration else {
            throw ContainerizationError(.invalidState, message: "sandbox not prepared")
        }
        guard sandboxState == .booted || sandboxState == .running else {
            throw ContainerizationError(.invalidState, message: "sandbox not started")
        }
        guard workloads[workloadID] == nil else {
            throw ContainerizationError(.exists, message: "workload \(workloadID) already exists")
        }

        let workloadConfiguration = WorkloadConfiguration(id: workloadID, processConfiguration: processConfiguration)
        try persistWorkloadConfiguration(workloadConfiguration)
        do {
            upsertWorkloadRecord(configuration: workloadConfiguration)
            _ = try ensureWorkloadSessionIfNeeded(workloadID: workloadID, stdio: stdio)
        } catch {
            workloads.removeValue(forKey: workloadID)
            try? FileManager.default.removeItem(at: workloadConfigurationPath(for: workloadID))
            throw error
        }
    }

    private func startWorkloadIfNeeded(workloadID: String) async throws {
        guard let configuration else {
            throw ContainerizationError(.invalidState, message: "sandbox not prepared")
        }
        guard sandboxState == .booted || sandboxState == .running else {
            throw ContainerizationError(.invalidState, message: "sandbox not started")
        }

        let sessionID = try sessionID(forWorkload: workloadID)
        guard var session = sessions[sessionID] else {
            throw ContainerizationError(.notFound, message: "workload \(workloadID) not found")
        }
        if session.started {
            return
        }

        #if arch(arm64)
        try await prepareGuestMountsIfNeeded(containerConfig: configuration)
        try await prepareReadOnlyInjectionsIfNeeded()
        try await startSessionViaSidecarProcessStream(&session, containerConfig: configuration)
        writeContainerLog(Data(("startWorkload using sidecar process stream path for \(workloadID) session=\(sessionID)\n").utf8))
        #else
        throw ContainerizationError(.unsupported, message: "macOS runtime requires an arm64 host")
        #endif

        let startedAt = session.startedAt ?? Date()
        if var current = sessions[sessionID] {
            current.started = true
            current.startedAt = current.startedAt ?? startedAt
            sessions[sessionID] = current
        } else {
            session.started = true
            session.startedAt = startedAt
            sessions[sessionID] = session
        }
        markWorkloadStarted(workloadID: workloadID, startedAt: startedAt)

        if workloadID == configuration.id {
            sandboxState = .running
        }
    }

    private func runtimeConfigurationPath() -> URL {
        layout.runtimeConfigurationURL
    }

    private func optionsPath() -> URL {
        layout.optionsURL
    }

    private func configPath() -> URL {
        layout.containerConfigurationURL
    }

    private func diskImagePath() -> URL {
        layout.diskImageURL
    }

    private func auxiliaryStoragePath() -> URL {
        layout.auxiliaryStorageURL
    }

    private func hardwareModelPath() -> URL {
        layout.hardwareModelURL
    }

    private func stdioLogPath() -> URL {
        layout.stdioLogURL
    }

    private func bootLogPath() -> URL {
        layout.bootLogURL
    }

    private func guestAgentHostLogPath() -> URL {
        layout.guestAgentHostLogURL
    }

    private func guestAgentHostStderrLogPath() -> URL {
        layout.guestAgentHostStderrLogURL
    }

    private func workloadsDirectory() -> URL {
        layout.workloadsDirectoryURL
    }

    private func workloadDirectory(for processID: String) -> URL {
        layout.workloadDirectoryURL(id: processID)
    }

    private func sandboxConfigurationPath() -> URL {
        layout.sandboxConfigurationURL
    }

    private func workloadConfigurationPath(for processID: String) -> URL {
        layout.workloadConfigurationURL(id: processID)
    }

    private func workloadStdoutLogPath(for processID: String) -> URL {
        layout.workloadStdoutLogURL(id: processID)
    }

    private func workloadStderrLogPath(for processID: String) -> URL {
        layout.workloadStderrLogURL(id: processID)
    }

    private func sandboxConfigurationSnapshot() -> SandboxConfiguration? {
        if let persisted = try? loadJSON(SandboxConfiguration.self, from: sandboxConfigurationPath()) {
            return persisted
        }
        if let configuration {
            return SandboxConfiguration(containerConfiguration: configuration)
        }
        return nil
    }

    private func workloadConfigurationSnapshot(for processID: String, fallback: ProcessConfiguration) -> WorkloadConfiguration {
        if let persisted = try? loadJSON(WorkloadConfiguration.self, from: workloadConfigurationPath(for: processID)) {
            return persisted
        }
        return WorkloadConfiguration(id: processID, processConfiguration: fallback)
    }

    private func persistSandboxMetadata(for configuration: ContainerConfiguration) throws {
        try layout.prepareBaseDirectories()
        try persistJSON(SandboxConfiguration(containerConfiguration: configuration), to: sandboxConfigurationPath())
        if configuration.readOnlyFiles.isEmpty {
            try MacOSReadOnlyFileInjectionStore.stage([], in: layout)
        } else if !FileManager.default.fileExists(atPath: layout.readonlyInjectionManifestURL.path) {
            try MacOSReadOnlyFileInjectionStore.stage(configuration.readOnlyFiles, in: layout)
        }
        try persistWorkloadConfiguration(.init(id: configuration.id, processConfiguration: configuration.initProcess))
    }

    private func persistWorkloadConfiguration(_ configuration: WorkloadConfiguration) throws {
        try layout.prepareBaseDirectories()
        try persistJSON(configuration, to: workloadConfigurationPath(for: configuration.id))
    }

    private func persistJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func loadJSON<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func restorePersistedWorkloadsIfNeeded(containerConfig: ContainerConfiguration) throws {
        let initConfiguration = WorkloadConfiguration(
            id: containerConfig.id,
            processConfiguration: containerConfig.initProcess
        )
        upsertWorkloadRecord(configuration: initConfiguration)

        let fm = FileManager.default
        guard fm.fileExists(atPath: workloadsDirectory().path) else {
            return
        }

        for candidate in try fm.contentsOfDirectory(
            at: workloadsDirectory(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let configURL = candidate.appendingPathComponent("config.json")
            guard fm.fileExists(atPath: configURL.path) else {
                continue
            }
            let workloadConfiguration = try loadJSON(WorkloadConfiguration.self, from: configURL)
            upsertWorkloadRecord(configuration: workloadConfiguration)
        }
    }

    private func openAppendLogHandle(at url: URL) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            _ = fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func openWorkloadLogFiles(processID: String) throws -> WorkloadLogFiles {
        let stdoutURL = workloadStdoutLogPath(for: processID)
        let stderrURL = workloadStderrLogPath(for: processID)
        return try openLogFiles(stdoutURL: stdoutURL, stderrURL: stderrURL)
    }

    private func openLogFiles(stdoutURL: URL, stderrURL: URL) throws -> WorkloadLogFiles {
        WorkloadLogFiles(
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            stdoutHandle: try openAppendLogHandle(at: stdoutURL),
            stderrHandle: try openAppendLogHandle(at: stderrURL)
        )
    }

    private func openLogs() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: stdioLogPath().path) {
            _ = fm.createFile(atPath: stdioLogPath().path, contents: nil)
        }
        if !fm.fileExists(atPath: bootLogPath().path) {
            _ = fm.createFile(atPath: bootLogPath().path, contents: nil)
        }
        logHandle = try FileHandle(forWritingTo: stdioLogPath())
        bootLogHandle = try FileHandle(forWritingTo: bootLogPath())
        try logHandle?.seekToEnd()
        try bootLogHandle?.seekToEnd()
    }

    private func openLogsIfNeeded() throws {
        if logHandle != nil || bootLogHandle != nil {
            return
        }
        try openLogs()
    }

    private func writeBootLog(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        try bootLogHandle?.write(contentsOf: data)
    }

    func writeContainerLog(_ data: Data) {
        try? logHandle?.write(contentsOf: data)
    }

    private func createBundleIfNeeded() async throws -> ContainerConfiguration {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        if fm.fileExists(atPath: configPath().path) {
            let data = try Data(contentsOf: configPath())
            return try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        }

        let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: root)
        guard let config = runtimeConfig.containerConfiguration else {
            throw ContainerizationError(.invalidState, message: "runtime configuration missing container configuration")
        }

        let configData = try JSONEncoder().encode(config)
        try configData.write(to: configPath())
        if let options = runtimeConfig.options {
            try JSONEncoder().encode(options).write(to: optionsPath())
        }

        let layers = try await resolveTemplateLayers(containerConfig: config)
        _ = try FilesystemClone.cloneOrCopyItem(at: layers.hardwareModel, to: hardwareModelPath())
        _ = try FilesystemClone.cloneOrCopyItem(at: layers.auxiliaryStorage, to: auxiliaryStoragePath())
        _ = try FilesystemClone.cloneOrCopyItem(at: layers.diskImage, to: diskImagePath())
        return config
    }

    private struct LayerPaths {
        let hardwareModel: URL
        let auxiliaryStorage: URL
        let diskImage: URL
    }

    private func resolveTemplateLayers(containerConfig: ContainerConfiguration) async throws -> LayerPaths {
        let store = RemoteContentStoreClient()

        guard let indexContent: Content = try await store.get(digest: containerConfig.image.digest) else {
            throw ContainerizationError(.notFound, message: "missing index blob \(containerConfig.image.digest)")
        }
        let index: Index = try indexContent.decode()
        guard let manifestDescriptor = index.manifests.first(where: { $0.platform == containerConfig.platform }) else {
            throw ContainerizationError(.notFound, message: "no manifest for platform \(containerConfig.platform)")
        }
        guard let manifestContent: Content = try await store.get(digest: manifestDescriptor.digest) else {
            throw ContainerizationError(.notFound, message: "missing manifest blob \(manifestDescriptor.digest)")
        }
        let manifest: Manifest = try manifestContent.decode()
        let layers = try MacOSImageLayers(manifest: manifest)

        guard let hardwareContent: Content = try await store.get(digest: layers.hardwareModel.digest) else {
            throw ContainerizationError(.notFound, message: "missing hardware model blob \(layers.hardwareModel.digest)")
        }
        guard let auxiliaryContent: Content = try await store.get(digest: layers.auxiliaryStorage.digest) else {
            throw ContainerizationError(.notFound, message: "missing auxiliary storage blob \(layers.auxiliaryStorage.digest)")
        }

        let diskImagePath: URL
        switch layers {
        case .v0(_, _, let diskImage):
            guard let diskContent: Content = try await store.get(digest: diskImage.digest) else {
                throw ContainerizationError(.notFound, message: "missing disk image blob \(diskImage.digest)")
            }
            diskImagePath = diskContent.path

        case .v1(_, _, let diskLayoutDesc, let diskChunks):
            diskImagePath = try await resolveV1DiskImage(
                store: store,
                manifestDigest: manifestDescriptor.digest,
                diskLayoutDescriptor: diskLayoutDesc,
                diskChunks: diskChunks
            )
        }

        return LayerPaths(
            hardwareModel: hardwareContent.path,
            auxiliaryStorage: auxiliaryContent.path,
            diskImage: diskImagePath
        )
    }

    /// Resolve a v1 chunked disk image: check rebuild cache, rebuild if needed.
    private func resolveV1DiskImage(
        store: RemoteContentStoreClient,
        manifestDigest: String,
        diskLayoutDescriptor: Descriptor,
        diskChunks: [Descriptor]
    ) async throws -> URL {
        // Load disk layout
        guard let layoutContent: Content = try await store.get(digest: diskLayoutDescriptor.digest) else {
            throw ContainerizationError(.notFound, message: "missing disk layout blob \(diskLayoutDescriptor.digest)")
        }
        let layoutData = try layoutContent.data()
        let layout = try JSONDecoder().decode(DiskLayout.self, from: layoutData)

        // Check rebuild cache
        let cacheDir = rebuildCacheDirectory()
        let cachedPath = MacOSDiskRebuilder.rebuildCachePath(cacheDir: cacheDir, manifestDigest: manifestDigest)

        if MacOSDiskRebuilder.cacheExists(at: cachedPath) {
            return cachedPath
        }

        // Rebuild: fetch all chunk blob paths
        var chunkBlobPaths: [String: URL] = [:]
        for chunk in diskChunks {
            guard let content: Content = try await store.get(digest: chunk.digest) else {
                throw ContainerizationError(.notFound, message: "missing disk chunk blob \(chunk.digest)")
            }
            chunkBlobPaths[chunk.digest] = content.path
        }

        // Perform rebuild
        try MacOSDiskRebuilder.rebuild(
            layout: layout,
            chunkBlobPaths: chunkBlobPaths,
            outputPath: cachedPath
        )

        return cachedPath
    }

    /// Get the rebuild cache directory path.
    private func rebuildCacheDirectory() -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("com.apple.container/rebuild-cache")
    }

    #if arch(arm64)
    private func startOrRestoreVirtualMachine(config: ContainerConfiguration) async throws {
        try await startVirtualMachineViaSidecar(config: config)
    }
    #endif
}

// MARK: - Process/session plumbing

extension MacOSSandboxService {
    private func visibleSessionCount() -> Int {
        workloads.count
    }

    private func runningWorkloadCount() -> Int {
        workloads.values.filter { $0.startedAt != nil && $0.exitStatus == nil }.count
    }

    private func makeWorkloadRecord(configuration: WorkloadConfiguration) -> WorkloadRecord {
        WorkloadRecord(
            id: configuration.id,
            configuration: configuration,
            sessionID: nil,
            startedAt: nil,
            exitStatus: nil,
            stdoutLogPath: workloadStdoutLogPath(for: configuration.id).path,
            stderrLogPath: workloadStderrLogPath(for: configuration.id).path
        )
    }

    private func upsertWorkloadRecord(configuration: WorkloadConfiguration) {
        if var existing = workloads[configuration.id] {
            existing.configuration = configuration
            workloads[configuration.id] = existing
        } else {
            workloads[configuration.id] = makeWorkloadRecord(configuration: configuration)
        }
    }

    private func attachSession(_ sessionID: String, toWorkload workloadID: String) {
        guard var record = workloads[workloadID] else {
            return
        }
        if let previousSessionID = record.sessionID, previousSessionID != sessionID {
            workloadSessions.removeValue(forKey: previousSessionID)
        }
        record.sessionID = sessionID
        workloads[workloadID] = record
        workloadSessions[sessionID] = workloadID
    }

    private func markWorkloadStarted(workloadID: String, startedAt: Date) {
        guard var record = workloads[workloadID] else {
            return
        }
        record.startedAt = record.startedAt ?? startedAt
        record.exitStatus = nil
        workloads[workloadID] = record
    }

    private func markWorkloadExited(workloadID: String, status: ExitStatus) {
        guard var record = workloads[workloadID] else {
            return
        }
        record.exitStatus = status
        workloads[workloadID] = record
    }

    private func workloadID(forSession sessionID: String) -> String? {
        workloadSessions[sessionID]
    }

    private func sessionID(forWorkload workloadID: String) throws -> String {
        guard let record = workloads[workloadID] else {
            throw ContainerizationError(.notFound, message: "workload \(workloadID) not found")
        }
        guard let sessionID = record.sessionID else {
            throw ContainerizationError(.invalidState, message: "workload \(workloadID) has no active session")
        }
        return sessionID
    }

    private func ensureWorkloadSessionIfNeeded(workloadID: String, stdio: [FileHandle?]) throws -> String {
        guard let record = workloads[workloadID] else {
            throw ContainerizationError(.notFound, message: "workload \(workloadID) not found")
        }
        if let sessionID = record.sessionID {
            return sessionID
        }

        let sessionID = "__workload__\(UUID().uuidString)"
        let session = try makeSession(
            processID: sessionID,
            config: record.configuration.processConfiguration,
            stdio: stdio,
            workloadID: workloadID
        )
        sessions[sessionID] = session
        attachSession(sessionID, toWorkload: workloadID)
        return sessionID
    }

    private func discardWorkloadSession(workloadID: String) {
        guard let record = workloads[workloadID], let sessionID = record.sessionID else {
            return
        }
        if let session = sessions.removeValue(forKey: sessionID) {
            session.stdio[0]?.readabilityHandler = nil
            try? session.stdio[1]?.close()
            try? session.stdio[2]?.close()
            try? session.stdoutLogHandle?.close()
            try? session.stderrLogHandle?.close()
        }
        workloadSessions.removeValue(forKey: sessionID)
        if var updated = workloads[workloadID] {
            updated.sessionID = nil
            workloads[workloadID] = updated
        }
    }

    func makeSession(
        processID: String,
        config: ProcessConfiguration,
        stdio: [FileHandle?],
        includeInSnapshots: Bool = true,
        workloadID: String? = nil,
        logFiles: WorkloadLogFiles? = nil
    ) throws -> Session {
        let logs: WorkloadLogFiles
        if let logFiles {
            logs = logFiles
        } else if let workloadID {
            logs = try openWorkloadLogFiles(processID: workloadID)
        } else {
            logs = try openWorkloadLogFiles(processID: processID)
        }
        return Session(
            processID: processID,
            config: config,
            stdio: stdio,
            includeInSnapshots: includeInSnapshots,
            stdoutLogURL: logs.stdoutURL,
            stderrLogURL: logs.stderrURL,
            stdoutLogHandle: logs.stdoutHandle,
            stderrLogHandle: logs.stderrHandle
        )
    }

    private func workloadSnapshot(processID: String) throws -> WorkloadSnapshot {
        guard let record = workloads[processID] else {
            throw ContainerizationError(.notFound, message: "workload \(processID) not found")
        }
        return workloadSnapshot(for: record)
    }

    private func workloadSnapshots() -> [WorkloadSnapshot] {
        workloads.values
            .sorted { $0.id < $1.id }
            .map(workloadSnapshot(for:))
    }

    private func startGuestAgentLogCaptureIfPossible(
        containerConfig: ContainerConfiguration
    ) async {
        guard guestAgentLogCaptureProcessID == nil else {
            return
        }

        let processID = "__guest-agent-log__"
        do {
            let logFiles = try openLogFiles(
                stdoutURL: guestAgentHostLogPath(),
                stderrURL: guestAgentHostStderrLogPath()
            )
            var session = try makeSession(
                processID: processID,
                config: ProcessConfiguration(
                    executable: "/usr/bin/tail",
                    arguments: ["-n", "+1", "-F", Self.guestAgentLogGuestPath],
                    environment: [],
                    workingDirectory: "/",
                    terminal: false,
                    user: .id(uid: 0, gid: 0)
                ),
                stdio: [nil, nil, nil],
                includeInSnapshots: false,
                logFiles: logFiles
            )
            sessions[processID] = session
            guestAgentLogCaptureProcessID = processID
            try await startSessionViaSidecarProcessStream(&session, containerConfig: containerConfig)
            writeContainerLog(
                Data(
                    ("started guest-agent host log capture path=\(guestAgentHostLogPath().path)\n").utf8
                )
            )
        } catch {
            if let session = sessions.removeValue(forKey: processID) {
                try? session.stdoutLogHandle?.close()
                try? session.stderrLogHandle?.close()
            }
            guestAgentLogCaptureProcessID = nil
            writeContainerLog(
                Data(
                    ("failed to start guest-agent host log capture: \(error)\n").utf8
                )
            )
        }
    }

    private func workloadSnapshot(for record: WorkloadRecord) -> WorkloadSnapshot {
        let status: RuntimeStatus
        if record.exitStatus != nil {
            status = .stopped
        } else if record.startedAt != nil {
            status = .running
        } else {
            status = .stopped
        }

        return WorkloadSnapshot(
            configuration: record.configuration,
            status: status,
            exitCode: record.exitStatus?.exitCode,
            startedDate: record.startedAt,
            exitedAt: record.exitStatus?.exitedAt,
            stdoutLogPath: record.stdoutLogPath,
            stderrLogPath: record.stderrLogPath
        )
    }

    private func waitWithoutTimeoutForSession(_ sessionID: String) async throws -> ExitStatus {
        if let status = sessions[sessionID]?.exitStatus {
            writeContainerLog(Data(("waitWithoutTimeout immediate hit for session \(sessionID) code=\(status.exitCode)\n").utf8))
            return status
        }
        guard sessions[sessionID] != nil else {
            throw ContainerizationError(.notFound, message: "session \(sessionID) not found")
        }
        return await withCheckedContinuation { continuation in
            addWaiter(id: sessionID, continuation: continuation)
        }
    }

    private func addWaiter(id: String, continuation: CheckedContinuation<ExitStatus, Never>) {
        var current = waiters[id] ?? []
        current.append(continuation)
        waiters[id] = current
        writeContainerLog(Data(("waiter added for \(id); total=\(current.count)\n").utf8))
    }

    private func removeWaiters(for id: String) -> [CheckedContinuation<ExitStatus, Never>] {
        let continuations = waiters[id] ?? []
        waiters[id] = []
        return continuations
    }

    private func resumeWaiters(
        for id: String,
        fallbackStatus: ExitStatus,
        reason: String
    ) {
        let continuations = removeWaiters(for: id)
        guard !continuations.isEmpty else {
            return
        }

        let status = sessions[id]?.exitStatus ?? fallbackStatus
        writeContainerLog(
            Data(
                ("resuming waiters for \(id) code=\(status.exitCode) reason=\(reason) waiters=\(continuations.count)\n").utf8
            )
        )
        for continuation in continuations {
            continuation.resume(returning: status)
        }
    }

    private func resumeAllWaiters(reason: String, fallbackExitCode: Int32 = 255) {
        guard !waiters.isEmpty else {
            return
        }

        let fallbackStatus = ExitStatus(exitCode: fallbackExitCode, exitedAt: Date())
        for id in Array(waiters.keys) {
            resumeWaiters(for: id, fallbackStatus: fallbackStatus, reason: reason)
        }
    }

    private func completeProcess(id: String, status: ExitStatus) {
        guard var session = sessions[id] else {
            writeContainerLog(Data(("completeProcess missing session \(id) code=\(status.exitCode); waking waiters anyway\n").utf8))
            resumeWaiters(for: id, fallbackStatus: status, reason: "process_completed_without_session")
            return
        }
        session.exitStatus = status
        sessions[id] = session
        if let workloadID = workloadID(forSession: id) {
            if var record = workloads[workloadID] {
                record.startedAt = record.startedAt ?? session.startedAt
                record.exitStatus = status
                workloads[workloadID] = record
            }
        }

        let continuations = removeWaiters(for: id)
        writeContainerLog(Data(("completeProcess for \(id) code=\(status.exitCode) waiters=\(continuations.count)\n").utf8))
        for continuation in continuations {
            continuation.resume(returning: status)
        }
    }

    func waitForWorkload(_ workloadID: String, timeout: Int32 = 0) async throws -> ExitStatus {
        guard let record = workloads[workloadID] else {
            throw ContainerizationError(.notFound, message: "workload \(workloadID) not found")
        }
        if let status = record.exitStatus {
            return status
        }
        guard let sessionID = record.sessionID else {
            throw ContainerizationError(.invalidState, message: "workload \(workloadID) has no active session")
        }
        return try await waitForSession(sessionID, timeout: timeout)
    }

    func waitForSession(_ sessionID: String, timeout: Int32 = 0) async throws -> ExitStatus {
        if let status = sessions[sessionID]?.exitStatus {
            return status
        }
        guard sessions[sessionID] != nil else {
            throw ContainerizationError(.notFound, message: "session \(sessionID) not found")
        }

        if timeout == 0 {
            return try await waitWithoutTimeoutForSession(sessionID)
        }

        return try await withThrowingTaskGroup(of: ExitStatus.self) { group in
            group.addTask {
                try await self.waitWithoutTimeoutForSession(sessionID)
            }
            group.addTask {
                let delay = UInt64(max(timeout, 0)) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                throw ContainerizationError(.timeout, message: "timed out waiting for session \(sessionID)")
            }

            do {
                guard let value = try await group.next() else {
                    throw ContainerizationError(.internalError, message: "wait cancelled for session \(sessionID)")
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                resumeWaiters(
                    for: sessionID,
                    fallbackStatus: ExitStatus(exitCode: 255, exitedAt: Date()),
                    reason: "wait_timeout_or_cancelled"
                )
                throw error
            }
        }
    }

    func waitForProcess(_ id: String, timeout: Int32 = 0) async throws -> ExitStatus {
        try await waitForSession(id, timeout: timeout)
    }

    private func closeAllSessions() {
        resumeAllWaiters(reason: "sessions_closed")
        let fallbackStatus = ExitStatus(exitCode: 255, exitedAt: Date())
        for (sessionID, session) in sessions {
            if let workloadID = workloadID(forSession: sessionID), var record = workloads[workloadID] {
                record.startedAt = record.startedAt ?? session.startedAt
                record.exitStatus = record.exitStatus ?? session.exitStatus ?? fallbackStatus
                record.sessionID = nil
                workloads[workloadID] = record
                workloadSessions.removeValue(forKey: sessionID)
            }
            session.stdio[0]?.readabilityHandler = nil
            try? session.stdio[1]?.close()
            try? session.stdio[2]?.close()
            try? session.stdoutLogHandle?.close()
            try? session.stderrLogHandle?.close()
        }
        sessions.removeAll()
        guestAgentLogCaptureProcessID = nil
    }

    #if arch(arm64)
    func startSessionViaSidecarProcessStream(
        _ session: inout Session,
        containerConfig: ContainerConfiguration
    ) async throws {
        let processID = session.processID
        let agentPort = containerConfig.macosGuest?.agentPort ?? Self.defaultAgentPort
        writeContainerLog(Data(("sidecar process.start begin for \(processID) on vsock port \(agentPort)\n").utf8))
        sessions[processID] = session

        let execIdentity: (user: String?, uid: UInt32?, gid: UInt32?) =
            switch session.config.user {
            case .raw(let userString):
                (userString, nil, nil)
            case .id(let uid, let gid):
                (nil, uid, gid)
            }
        let request = MacOSSidecarExecRequestPayload(
            executable: session.config.executable,
            arguments: session.config.arguments,
            environment: session.config.environment,
            workingDirectory: session.config.workingDirectory,
            terminal: session.config.terminal,
            user: execIdentity.user,
            uid: execIdentity.uid,
            gid: execIdentity.gid,
            supplementalGroups: session.config.supplementalGroups.isEmpty ? nil : session.config.supplementalGroups,
            stdin: nil
        )

        do {
            try await startProcessViaSidecarWithRetries(port: agentPort, processID: processID, request: request)
            session.started = true
            session.startedAt = session.startedAt ?? Date()
            if let stdin = session.stdio[0] {
                let service = self
                stdin.readabilityHandler = { handle in
                    let data = handle.availableData
                    Task {
                        await service.forwardHostStdin(processID: processID, data: data)
                    }
                }
            }
            sessions[processID] = session
            writeContainerLog(Data(("sidecar process.start sent for \(processID)\n").utf8))
        } catch {
            let detail = describeError(error)
            writeContainerLog(Data(("sidecar process.start failed for \(processID): \(detail)\n").utf8))
            throw ContainerizationError(
                .internalError,
                message: """
                    failed to start process via macOS sidecar guest agent on vsock port \(agentPort): \(detail)
                    check host guest-agent log mirror: \(guestAgentHostLogPath().path)
                    check guest log: \(Self.guestAgentLogGuestPath)
                    """
            )
        }
    }
    #endif

    private func forwardHostStdin(processID: String, data: Data) async {
        guard var session = sessions[processID], session.started else {
            return
        }

        do {
            if session.stdinClosed {
                return
            }
            guard let client = sidecarHandle?.client else {
                throw ContainerizationError(.invalidState, message: "macOS sidecar is not initialized")
            }
            if data.isEmpty {
                session.stdinClosed = true
                sessions[processID] = session
                session.stdio[0]?.readabilityHandler = nil
                try client.processClose(processID: processID)
            } else {
                try client.processStdin(processID: processID, data: data)
            }
        } catch {
            log.error("failed to forward stdin", metadata: ["process_id": "\(processID)", "error": "\(error)"])
        }
    }

    func sendSignalToProcess(processID: String, signal: Int32) throws {
        try sendSignalToSession(processID: processID, signal: signal)
    }

    private func sendSignalToSession(processID: String, signal: Int32) throws {
        guard let session = sessions[processID] else {
            throw ContainerizationError(.notFound, message: "process \(processID) not found")
        }
        if session.exitStatus != nil {
            return
        }
        guard let client = sidecarHandle?.client else {
            throw ContainerizationError(.invalidState, message: "macOS sidecar is not initialized")
        }
        try client.processSignal(processID: processID, signal: signal)
    }

    private func sendSignalToWorkload(workloadID: String, signal: Int32) throws {
        let sessionID = try sessionID(forWorkload: workloadID)
        try sendSignalToSession(processID: sessionID, signal: signal)
    }

    private func sendResizeToProcess(processID: String, width: UInt16, height: UInt16) throws {
        try sendResizeToSession(processID: processID, width: width, height: height)
    }

    private func sendResizeToSession(processID: String, width: UInt16, height: UInt16) throws {
        guard let session = sessions[processID] else {
            throw ContainerizationError(.notFound, message: "process \(processID) not found")
        }
        if session.exitStatus != nil {
            return
        }
        guard let client = sidecarHandle?.client else {
            throw ContainerizationError(.invalidState, message: "macOS sidecar is not initialized")
        }
        try client.processResize(processID: processID, width: width, height: height)
    }

    private func sendResizeToWorkload(workloadID: String, width: UInt16, height: UInt16) throws {
        let sessionID = try sessionID(forWorkload: workloadID)
        try sendResizeToSession(processID: sessionID, width: width, height: height)
    }

    func handleSidecarEvent(_ event: MacOSSidecarEvent) {
        let processID = event.processID
        guard var session = sessions[processID] else {
            return
        }

        switch event.event {
        case .processStdout:
            if let data = event.data, !data.isEmpty {
                if let stdout = session.stdio[1] {
                    try? stdout.write(contentsOf: data)
                }
                try? session.stdoutLogHandle?.write(contentsOf: data)
                writeContainerLog(data)
            }
        case .processStderr:
            if let data = event.data, !data.isEmpty {
                if let stderr = session.stdio[2] {
                    try? stderr.write(contentsOf: data)
                } else if let stdout = session.stdio[1] {
                    try? stdout.write(contentsOf: data)
                }
                try? session.stderrLogHandle?.write(contentsOf: data)
                writeContainerLog(data)
                if let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                {
                    session.lastStderr = text
                }
            }
        case .processError:
            let text = event.message ?? "unknown sidecar process error"
            session.lastAgentError = text
            writeContainerLog(Data(("sidecar process error for \(processID): \(text)\n").utf8))
        case .processExit:
            if session.exitStatus != nil {
                return
            }
            let code = event.exitCode ?? 1
            writeContainerLog(Data(("sidecar process exit event for \(processID) code=\(code)\n").utf8))
            let status = ExitStatus(exitCode: code, exitedAt: Date())
            session.exitStatus = status
            session.stdio[0]?.readabilityHandler = nil
            try? session.stdio[1]?.close()
            try? session.stdio[2]?.close()
            try? session.stdoutLogHandle?.close()
            try? session.stderrLogHandle?.close()
            sessions[processID] = session
            if processID == guestAgentLogCaptureProcessID {
                guestAgentLogCaptureProcessID = nil
            }
            completeProcess(id: processID, status: status)
            if workloadID(forSession: processID) == configuration?.id {
                sandboxState = .stopped(status.exitCode)
            }
            return
        }

        sessions[processID] = session
    }
}

private func describeError(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain) Code=\(nsError.code) \"\(nsError.localizedDescription)\""
}

// MARK: - XPC helpers

extension XPCMessage {
    fileprivate func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: SandboxKeys.snapshot.rawValue, value: data)
    }

    func setSandboxNetworkState(_ state: SandboxNetworkState) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: SandboxKeys.networkState.rawValue, value: data)
    }

    fileprivate func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: SandboxKeys.stdin.rawValue) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: SandboxKeys.stdout.rawValue) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: SandboxKeys.stderr.rawValue) {
            handles[2] = stderr
        }
        return handles
    }

    fileprivate func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: SandboxKeys.processConfig.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }

    fileprivate func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: SandboxKeys.stopOptions.rawValue) else {
            return .default
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }
}

extension MacOSSandboxService {
    // These hooks are used by release-mode test builds in CI.
    func testingAddSession(
        id: String,
        config: ProcessConfiguration,
        started: Bool = false,
        exitCode: Int32? = nil,
        includeInSnapshots: Bool = true,
        sessionID: String? = nil
    ) {
        let actualSessionID = sessionID ?? id
        var session = try! makeSession(
            processID: actualSessionID,
            config: config,
            stdio: [nil, nil, nil],
            includeInSnapshots: includeInSnapshots,
            workloadID: includeInSnapshots ? id : nil
        )
        session.started = started
        session.startedAt = started ? Date() : nil
        if let exitCode {
            session.exitStatus = ExitStatus(exitCode: exitCode, exitedAt: Date())
            try? session.stdoutLogHandle?.close()
            try? session.stderrLogHandle?.close()
        }
        sessions[actualSessionID] = session
        if includeInSnapshots {
            let workloadConfiguration =
                (try? loadJSON(WorkloadConfiguration.self, from: workloadConfigurationPath(for: id)))
                ?? .init(id: id, processConfiguration: config)
            upsertWorkloadRecord(configuration: workloadConfiguration)
            attachSession(actualSessionID, toWorkload: id)
            if started, let startedAt = session.startedAt {
                markWorkloadStarted(workloadID: id, startedAt: startedAt)
            }
            if let status = session.exitStatus {
                if var record = workloads[id] {
                    record.startedAt = record.startedAt ?? session.startedAt
                    record.exitStatus = status
                    workloads[id] = record
                }
            }
        }
    }

    func testingWaitForProcess(_ id: String, timeout: Int32 = 0) async throws -> ExitStatus {
        if workloads[id] != nil {
            return try await waitForWorkload(id, timeout: timeout)
        }
        return try await waitForProcess(id, timeout: timeout)
    }

    func testingCloseAllSessions() {
        closeAllSessions()
    }

    func testingWaiterCount(for id: String) -> Int {
        if let sessionID = workloads[id]?.sessionID {
            return waiters[sessionID]?.count ?? 0
        }
        return waiters[id]?.count ?? 0
    }

    func testingInspectWorkload(_ id: String) throws -> WorkloadSnapshot {
        try workloadSnapshot(processID: id)
    }

    func testingWorkloadSnapshots() -> [WorkloadSnapshot] {
        workloadSnapshots()
    }

    func testingVisibleSessionCount() -> Int {
        visibleSessionCount()
    }

    func testingSessionID(for workloadID: String) -> String? {
        workloads[workloadID]?.sessionID
    }

    func testingGuestAgentHostLogPath() -> String {
        guestAgentHostLogPath().path
    }

    func testingPersistSandboxMetadata(_ configuration: ContainerConfiguration) throws {
        try persistSandboxMetadata(for: configuration)
    }

    func testingPersistWorkloadConfiguration(_ configuration: WorkloadConfiguration) throws {
        try persistWorkloadConfiguration(configuration)
    }
}
