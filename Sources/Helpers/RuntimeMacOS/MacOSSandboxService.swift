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

public actor MacOSSandboxService {
    private static let defaultAgentPort: UInt32 = 27000

    private enum State: Equatable {
        case created
        case booted
        case running
        case stopping
        case stopped(Int32)
        case shuttingDown
    }

    private struct Session {
        let processID: String
        let config: ProcessConfiguration
        let stdio: [FileHandle?]
        var stdinClosed: Bool = false
        var started: Bool = false
        var exitStatus: ExitStatus?
        var lastAgentError: String?
    }

    struct SidecarHandle {
        let launchLabel: String
        let client: MacOSSidecarClient
    }

    let root: URL
    private let connection: xpc_connection_t
    let log: Logger

    private var sandboxState: State = .created
    var configuration: ContainerConfiguration?
    private var sessions: [String: Session] = [:]
    private var waiters: [String: [CheckedContinuation<ExitStatus, Never>]] = [:]

    var logHandle: FileHandle?
    private var bootLogHandle: FileHandle?
    var sidecarHandle: SidecarHandle?

    public init(root: URL, connection: xpc_connection_t, log: Logger) {
        self.root = root
        self.connection = connection
        self.log = log
    }
}

// MARK: - Route handlers

extension MacOSSandboxService {
    @Sendable
    public func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
        let endpoint = xpc_endpoint_create(self.connection)
        let reply = message.reply()
        reply.set(key: SandboxKeys.sandboxServiceEndpoint.rawValue, value: endpoint)
        return reply
    }

    @Sendable
    public func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
        guard case .created = sandboxState else {
            throw ContainerizationError(.invalidState, message: "container expected to be in created state, got: \(sandboxState)")
        }

        let config = try await createBundleIfNeeded()
        self.configuration = config

        try openLogs()
        try writeBootLog("bootstrapping container \(config.id)")

        let initSession = Session(
            processID: config.id,
            config: config.initProcess,
            stdio: message.stdio()
        )
        sessions[config.id] = initSession

        #if arch(arm64)
        try await startOrRestoreVirtualMachine(config: config)
        #else
        throw ContainerizationError(.unsupported, message: "macOS runtime requires an arm64 host")
        #endif

        sandboxState = .booted
        return message.reply()
    }

    @Sendable
    public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        guard let _ = configuration else {
            throw ContainerizationError(.invalidState, message: "container not bootstrapped")
        }
        let processConfig = try message.processConfig()
        guard sessions[id] == nil else {
            throw ContainerizationError(.exists, message: "process \(id) already exists")
        }

        sessions[id] = Session(processID: id, config: processConfig, stdio: message.stdio())
        return message.reply()
    }

    @Sendable
    public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        guard var session = sessions[processID] else {
            throw ContainerizationError(.notFound, message: "process \(processID) not found")
        }
        if session.started {
            return message.reply()
        }
        guard let configuration else {
            throw ContainerizationError(.invalidState, message: "container not bootstrapped")
        }

        #if arch(arm64)
        try await startSessionViaSidecarProcessStream(&session, containerConfig: configuration)
        writeContainerLog(Data(("startProcess using sidecar process stream path for \(processID)\n").utf8))
        #else
        throw ContainerizationError(.unsupported, message: "macOS runtime requires an arm64 host")
        #endif

        // Sidecar events can arrive (including an immediate exit for short-lived commands)
        // before we return here. Merge with the latest dictionary state instead of blindly
        // overwriting it with the older local copy.
        if var current = sessions[processID] {
            current.started = true
            sessions[processID] = current
        } else {
            session.started = true
            sessions[processID] = session
        }

        if processID == configuration.id {
            sandboxState = .running
        }
        return message.reply()
    }

    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        writeContainerLog(Data(("wait requested for \(id)\n").utf8))
        let status = try await waitForProcess(id)
        writeContainerLog(Data(("wait completed for \(id) code=\(status.exitCode)\n").utf8))
        let reply = message.reply()
        reply.set(key: SandboxKeys.exitCode.rawValue, value: Int64(status.exitCode))
        reply.set(key: SandboxKeys.exitedAt.rawValue, value: status.exitedAt)
        return reply
    }

    @Sendable
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        let signal = Int32(message.int64(key: SandboxKeys.signal.rawValue))
        try sendSignalToProcess(processID: processID, signal: signal)
        return message.reply()
    }

    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        let width = UInt16(message.uint64(key: SandboxKeys.width.rawValue))
        let height = UInt16(message.uint64(key: SandboxKeys.height.rawValue))
        try sendResizeToProcess(processID: processID, width: width, height: height)
        return message.reply()
    }

    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        let stopOptions = try message.stopOptions()
        sandboxState = .stopping
        writeContainerLog(Data(("stop requested signal=\(stopOptions.signal) timeout=\(stopOptions.timeoutInSeconds)\n").utf8))

        if let id = configuration?.id, let current = sessions[id], current.started {
            if current.exitStatus == nil {
                writeContainerLog(Data(("stop: init process \(id) still running; sending signal \(stopOptions.signal)\n").utf8))
                try? sendSignalToProcess(processID: id, signal: Int32(stopOptions.signal))
                _ = try? await waitForProcess(id, timeout: stopOptions.timeoutInSeconds)
                writeContainerLog(Data(("stop: wait for init process \(id) finished\n").utf8))
            } else {
                writeContainerLog(Data(("stop: init process \(id) already exited; skipping signal/wait\n").utf8))
            }
        }

        #if arch(arm64)
        writeContainerLog(Data(("stop: sidecar shutdown start\n").utf8))
        await stopAndQuitSidecarIfPresent()
        writeContainerLog(Data(("stop: sidecar shutdown done\n").utf8))
        #endif

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

        let snapshot = SandboxSnapshot(
            status: status,
            networks: [],
            containers: [
                ContainerSnapshot(
                    configuration: configuration,
                    status: status,
                    networks: [],
                    startedDate: nil
                )
            ]
        )
        let reply = message.reply()
        try reply.setState(snapshot)
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
            numProcesses: UInt64(sessions.count)
        )
        let data = try JSONEncoder().encode(stats)
        let reply = message.reply()
        reply.set(key: SandboxKeys.statistics.rawValue, value: data)
        return reply
    }
}

// MARK: - Bundle and VM setup

extension MacOSSandboxService {
    private func runtimeConfigurationPath() -> URL {
        root.appendingPathComponent("runtime-configuration.json")
    }

    private func optionsPath() -> URL {
        root.appendingPathComponent("options.json")
    }

    private func configPath() -> URL {
        root.appendingPathComponent("config.json")
    }

    private func diskImagePath() -> URL {
        root.appendingPathComponent("Disk.img")
    }

    private func auxiliaryStoragePath() -> URL {
        root.appendingPathComponent("AuxiliaryStorage")
    }

    private func hardwareModelPath() -> URL {
        root.appendingPathComponent("HardwareModel.bin")
    }

    private func stdioLogPath() -> URL {
        root.appendingPathComponent("stdio.log")
    }

    private func bootLogPath() -> URL {
        root.appendingPathComponent("vminitd.log")
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
    private func waitWithoutTimeout(_ id: String) async -> ExitStatus {
        if let status = sessions[id]?.exitStatus {
            writeContainerLog(Data(("waitWithoutTimeout immediate hit for \(id) code=\(status.exitCode)\n").utf8))
            return status
        }
        return await withCheckedContinuation { continuation in
            addWaiter(id: id, continuation: continuation)
        }
    }

    private func addWaiter(id: String, continuation: CheckedContinuation<ExitStatus, Never>) {
        var current = waiters[id] ?? []
        current.append(continuation)
        waiters[id] = current
        writeContainerLog(Data(("waiter added for \(id); total=\(current.count)\n").utf8))
    }

    private func completeProcess(id: String, status: ExitStatus) {
        guard var session = sessions[id] else {
            writeContainerLog(Data(("completeProcess dropped for missing session \(id) code=\(status.exitCode)\n").utf8))
            return
        }
        session.exitStatus = status
        sessions[id] = session

        let continuations = waiters[id] ?? []
        waiters[id] = []
        writeContainerLog(Data(("completeProcess for \(id) code=\(status.exitCode) waiters=\(continuations.count)\n").utf8))
        for continuation in continuations {
            continuation.resume(returning: status)
        }
    }

    private func waitForProcess(_ id: String, timeout: Int32 = 0) async throws -> ExitStatus {
        if let status = sessions[id]?.exitStatus {
            return status
        }

        if timeout == 0 {
            return await waitWithoutTimeout(id)
        }

        return try await withThrowingTaskGroup(of: ExitStatus.self) { group in
            group.addTask {
                await self.waitWithoutTimeout(id)
            }
            group.addTask {
                let delay = UInt64(max(timeout, 0)) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                throw ContainerizationError(.timeout, message: "timed out waiting for process \(id)")
            }

            guard let value = try await group.next() else {
                throw ContainerizationError(.internalError, message: "wait cancelled for process \(id)")
            }
            group.cancelAll()
            return value
        }
    }

    private func closeAllSessions() {
        for (_, session) in sessions {
            session.stdio[0]?.readabilityHandler = nil
            try? session.stdio[1]?.close()
            try? session.stdio[2]?.close()
        }
        sessions.removeAll()
    }

    #if arch(arm64)
    private func startSessionViaSidecarProcessStream(
        _ session: inout Session,
        containerConfig: ContainerConfiguration
    ) async throws {
        let processID = session.processID
        let agentPort = containerConfig.macosGuest?.agentPort ?? Self.defaultAgentPort
        writeContainerLog(Data(("sidecar process.start begin for \(processID) on vsock port \(agentPort)\n").utf8))
        sessions[processID] = session

        let request = MacOSSidecarExecRequestPayload(
            executable: session.config.executable,
            arguments: session.config.arguments,
            environment: session.config.environment,
            workingDirectory: session.config.workingDirectory,
            terminal: session.config.terminal,
            stdin: nil
        )

        do {
            try await startProcessViaSidecarWithRetries(port: agentPort, processID: processID, request: request)
            session.started = true
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
                    check guest log: /var/log/container-macos-guest-agent.log
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

    private func sendSignalToProcess(processID: String, signal: Int32) throws {
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

    private func sendResizeToProcess(processID: String, width: UInt16, height: UInt16) throws {
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
                writeContainerLog(data)
            }
        case .processStderr:
            if let data = event.data, !data.isEmpty {
                if let stderr = session.stdio[2] {
                    try? stderr.write(contentsOf: data)
                } else if let stdout = session.stdio[1] {
                    try? stdout.write(contentsOf: data)
                }
                writeContainerLog(data)
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
            sessions[processID] = session
            completeProcess(id: processID, status: status)
            if processID == configuration?.id {
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
