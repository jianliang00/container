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
import ContainerizationArchive
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
    private static let guestWorkloadsRootPath = "/var/lib/container/workloads"

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
        var config: ProcessConfiguration
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
    private let contentStore: any ContentStore

    private var sandboxState: State = .created
    var configuration: ContainerConfiguration?
    var sessions: [String: Session] = [:]
    private var workloads: [String: WorkloadRecord] = [:]
    private var workloadSessions: [String: String] = [:]
    private var externalProcessIDs: Set<String> = []
    private var waiters: [String: [CheckedContinuation<ExitStatus, Never>]] = [:]
    var guestMountsPrepared = false
    var readOnlyInjectionsPrepared = false
    private var guestAgentLogCaptureProcessID: String?

    var logHandle: FileHandle?
    private var bootLogHandle: FileHandle?
    var sidecarHandle: SidecarHandle?
    var sidecarEventPump: SidecarEventPump?
    var sidecarEventPumpTask: Task<Void, Never>?

    public init(
        root: URL,
        connection: xpc_connection_t? = nil,
        log: Logger,
        contentStore: any ContentStore = RemoteContentStoreClient()
    ) {
        self.root = root
        self.connection = connection
        self.log = log
        self.contentStore = contentStore
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
        let config = try await prepareSandboxIfNeeded()
        try await startSandboxIfNeeded(stdio: message.stdio())
        try await startWorkloadIfNeeded(workloadID: config.id)
        return message.reply()
    }

    @Sendable
    public func createWorkload(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        try await createWorkloadIfNeeded(
            workloadConfiguration: try message.workloadConfiguration(id: id),
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
    public func stopWorkload(_ message: XPCMessage) async throws -> XPCMessage {
        let workloadID = try message.id()
        let stopOptions = try message.stopOptions()
        try await stopWorkloadIfNeeded(workloadID: workloadID, stopOptions: stopOptions)
        return message.reply()
    }

    @Sendable
    public func removeWorkload(_ message: XPCMessage) async throws -> XPCMessage {
        let workloadID = try message.id()
        try await removeWorkloadIfNeeded(workloadID: workloadID)
        return message.reply()
    }

    @Sendable
    public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        let config = try message.processConfig()
        let stdio = message.stdio()
        try await createExecProcessIfNeeded(processID: processID, config: config, stdio: stdio)
        return message.reply()
    }

    @Sendable
    public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        if workloads[processID] != nil {
            try await startWorkloadIfNeeded(workloadID: processID)
        } else {
            try await startExecProcessIfNeeded(processID: processID)
        }
        return message.reply()
    }

    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        let status: ExitStatus
        if workloads[processID] != nil {
            writeContainerLog(Data(("wait requested for workload \(processID)\n").utf8))
            status = try await waitForWorkload(processID)
            writeContainerLog(Data(("wait completed for workload \(processID) code=\(status.exitCode)\n").utf8))
        } else {
            guard externalProcessIDs.contains(processID) else {
                throw ContainerizationError(.notFound, message: "process \(processID) not found")
            }
            writeContainerLog(Data(("wait requested for process \(processID)\n").utf8))
            status = try await waitForProcess(processID)
            writeContainerLog(Data(("wait completed for process \(processID) code=\(status.exitCode)\n").utf8))
            cleanupExitedExternalProcessIfNeeded(processID: processID)
        }
        let reply = message.reply()
        reply.set(key: SandboxKeys.exitCode.rawValue, value: Int64(status.exitCode))
        reply.set(key: SandboxKeys.exitedAt.rawValue, value: status.exitedAt)
        return reply
    }

    @Sendable
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        let signal = Int32(message.int64(key: SandboxKeys.signal.rawValue))
        if workloads[processID] != nil {
            try sendSignalToWorkload(workloadID: processID, signal: signal)
        } else {
            guard externalProcessIDs.contains(processID) else {
                throw ContainerizationError(.notFound, message: "process \(processID) not found")
            }
            try sendSignalToProcess(processID: processID, signal: signal)
        }
        return message.reply()
    }

    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        let width = UInt16(message.uint64(key: SandboxKeys.width.rawValue))
        let height = UInt16(message.uint64(key: SandboxKeys.height.rawValue))
        if workloads[processID] != nil {
            try sendResizeToWorkload(workloadID: processID, width: width, height: height)
        } else {
            guard externalProcessIDs.contains(processID) else {
                throw ContainerizationError(.notFound, message: "process \(processID) not found")
            }
            try sendResizeToProcess(processID: processID, width: width, height: height)
        }
        return message.reply()
    }

    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        let stopOptions = try message.stopOptions()
        try await stopSandbox(stopOptions: stopOptions)
        return message.reply()
    }

    private func stopSandbox(stopOptions: ContainerStopOptions) async throws {
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

        if let configuration {
            await cleanupGuestWorkloadsIfNeeded(containerConfig: configuration)
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
            case .booted, .running: .running
            case .stopping: .stopping
            default: .stopped
            }
        let networks = await inspectSandboxNetworkState(containerConfig: configuration).attachments

        let snapshot = SandboxSnapshot(
            configuration: try sandboxConfigurationSnapshot(),
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
            if shouldResetImageBackedWorkloadsForRecovery() {
                try resetImageBackedWorkloadsForColdBootIfNeeded()
            }
            return configuration
        }

        let config = try await createBundleIfNeeded()
        self.configuration = config
        try persistSandboxMetadata(for: config)
        try restorePersistedWorkloadsIfNeeded(containerConfig: config)
        if shouldResetImageBackedWorkloadsForRecovery() {
            try resetImageBackedWorkloadsForColdBootIfNeeded()
        }
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

    private func createWorkloadIfNeeded(workloadConfiguration: WorkloadConfiguration, stdio: [FileHandle?]) async throws {
        let workloadConfiguration = try await resolveCreatedWorkloadConfiguration(workloadConfiguration)
        let workloadID = workloadConfiguration.id
        guard let _ = configuration else {
            throw ContainerizationError(.invalidState, message: "sandbox not prepared")
        }
        guard sandboxState == .booted || sandboxState == .running else {
            throw ContainerizationError(.invalidState, message: "sandbox not started")
        }
        guard workloads[workloadID] == nil else {
            throw ContainerizationError(.exists, message: "workload \(workloadID) already exists")
        }

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

    private func createExecProcessIfNeeded(
        processID: String,
        config: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        guard let _ = configuration else {
            throw ContainerizationError(.invalidState, message: "sandbox not prepared")
        }
        guard sandboxState == .booted || sandboxState == .running else {
            throw ContainerizationError(.invalidState, message: "sandbox not started")
        }
        guard workloads[processID] == nil else {
            throw ContainerizationError(.exists, message: "workload \(processID) already exists")
        }
        guard sessions[processID] == nil else {
            throw ContainerizationError(.exists, message: "process \(processID) already exists")
        }

        let session = try makeSession(
            processID: processID,
            config: config,
            stdio: stdio,
            includeInSnapshots: false
        )
        sessions[processID] = session
        externalProcessIDs.insert(processID)
    }

    private func removeWorkloadIfNeeded(workloadID: String) async throws {
        guard let containerConfiguration = configuration else {
            throw ContainerizationError(.invalidState, message: "sandbox not prepared")
        }
        guard workloadID != containerConfiguration.id else {
            throw ContainerizationError(.invalidArgument, message: "cannot remove the init workload \(workloadID)")
        }
        guard let record = workloads[workloadID] else {
            throw ContainerizationError(.notFound, message: "workload \(workloadID) not found")
        }
        guard !isWorkloadRunning(record) else {
            throw ContainerizationError(.invalidState, message: "cannot remove running workload \(workloadID)")
        }

        if record.configuration.isImageBacked, sandboxState == .booted || sandboxState == .running {
            try await cleanupGuestWorkloadInstance(workloadID: workloadID, containerConfig: containerConfiguration)
        }

        if let sessionID = record.sessionID {
            resumeWaiters(
                for: sessionID,
                fallbackStatus: record.exitStatus ?? sessions[sessionID]?.exitStatus ?? ExitStatus(exitCode: 255, exitedAt: Date()),
                reason: "workload_removed"
            )
        }
        discardWorkloadSession(workloadID: workloadID)
        workloads.removeValue(forKey: workloadID)
        try removeWorkloadStateDirectoryIfPresent(workloadID: workloadID)
    }

    private func stopWorkloadIfNeeded(workloadID: String, stopOptions: ContainerStopOptions) async throws {
        guard let containerConfiguration = configuration else {
            throw ContainerizationError(.invalidState, message: "sandbox not prepared")
        }
        guard workloadID != containerConfiguration.id else {
            throw ContainerizationError(.invalidArgument, message: "cannot stop the init workload \(workloadID); use StopSandbox")
        }
        guard sandboxState == .booted || sandboxState == .running else {
            throw ContainerizationError(.invalidState, message: "sandbox not started")
        }
        guard let record = workloads[workloadID] else {
            throw ContainerizationError(.notFound, message: "workload \(workloadID) not found")
        }
        guard isWorkloadRunning(record) else {
            return
        }

        writeContainerLog(
            Data(
                ("stopWorkload requested id=\(workloadID) signal=\(stopOptions.signal) timeout=\(stopOptions.timeoutInSeconds)\n").utf8
            )
        )

        do {
            try sendSignalToWorkload(workloadID: workloadID, signal: stopOptions.signal)
            _ = try await waitForWorkload(workloadID, timeout: stopOptions.timeoutInSeconds)
        } catch let error as ContainerizationError where error.code == .timeout {
            writeContainerLog(Data(("stopWorkload timeout for \(workloadID); escalating to SIGKILL\n").utf8))
            try sendSignalToWorkload(workloadID: workloadID, signal: SIGKILL)
            _ = try await waitForWorkload(workloadID)
        }
    }

    private func startWorkloadIfNeeded(workloadID: String) async throws {
        guard let configuration else {
            throw ContainerizationError(.invalidState, message: "sandbox not prepared")
        }
        guard sandboxState == .booted || sandboxState == .running else {
            throw ContainerizationError(.invalidState, message: "sandbox not started")
        }
        try await ensureImageBackedWorkloadInjectedIfNeeded(workloadID: workloadID, containerConfig: configuration)
        if let record = workloads[workloadID] {
            try validateWorkloadConfigurationForStart(record.configuration)
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

    private func startExecProcessIfNeeded(processID: String) async throws {
        guard let configuration else {
            throw ContainerizationError(.invalidState, message: "sandbox not prepared")
        }
        guard sandboxState == .booted || sandboxState == .running else {
            throw ContainerizationError(.invalidState, message: "sandbox not started")
        }
        guard externalProcessIDs.contains(processID), var session = sessions[processID] else {
            throw ContainerizationError(.notFound, message: "process \(processID) not found")
        }
        if session.started {
            return
        }

        #if arch(arm64)
        try await prepareGuestMountsIfNeeded(containerConfig: configuration)
        try await prepareReadOnlyInjectionsIfNeeded()
        try await startSessionViaSidecarProcessStream(&session, containerConfig: configuration)
        writeContainerLog(Data(("startProcess using sidecar process stream path for \(processID)\n").utf8))
        #else
        throw ContainerizationError(.unsupported, message: "macOS runtime requires an arm64 host")
        #endif

        let startedAt = session.startedAt ?? Date()
        if var current = sessions[processID] {
            current.started = true
            current.startedAt = current.startedAt ?? startedAt
            sessions[processID] = current
        } else {
            session.started = true
            session.startedAt = startedAt
            sessions[processID] = session
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

    private func sandboxConfigurationSnapshot() throws -> SandboxConfiguration? {
        if let persisted = try loadJSONIfPresent(SandboxConfiguration.self, from: sandboxConfigurationPath()) {
            return persisted
        }
        if let configuration {
            return SandboxConfiguration(containerConfiguration: configuration)
        }
        return nil
    }

    private func workloadConfigurationSnapshot(for processID: String, fallback: ProcessConfiguration) throws -> WorkloadConfiguration {
        if let persisted = try loadJSONIfPresent(WorkloadConfiguration.self, from: workloadConfigurationPath(for: processID)) {
            return normalizeWorkloadConfiguration(persisted)
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
        let normalized = normalizeWorkloadConfiguration(configuration)
        try persistJSON(normalized, to: workloadConfigurationPath(for: normalized.id))
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

    private func loadJSONIfPresent<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try loadJSON(type, from: url)
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
            let workloadConfiguration = normalizeWorkloadConfiguration(
                try loadJSON(WorkloadConfiguration.self, from: configURL)
            )
            upsertWorkloadRecord(configuration: workloadConfiguration)
        }
    }

    private func normalizeWorkloadConfiguration(_ configuration: WorkloadConfiguration) -> WorkloadConfiguration {
        guard configuration.isImageBacked else {
            return configuration
        }

        return WorkloadConfiguration(
            id: configuration.id,
            processConfiguration: configuration.processConfiguration,
            workloadImageReference: configuration.workloadImageReference,
            workloadImageDigest: configuration.workloadImageDigest,
            guestPayloadPath: configuration.guestPayloadPath ?? guestPayloadPath(for: configuration.id),
            guestMetadataPath: configuration.guestMetadataPath ?? guestMetadataPath(for: configuration.id),
            injectionState: configuration.injectionState == .notRequired ? .pending : configuration.injectionState
        )
    }

    private func validateWorkloadConfigurationForStart(_ configuration: WorkloadConfiguration) throws {
        guard configuration.isImageBacked else {
            return
        }
        guard configuration.injectionState == .injected else {
            throw ContainerizationError(
                .invalidState,
                message: "image-backed workload \(configuration.id) has not been injected into the guest yet"
            )
        }
        guard configuration.guestPayloadPath != nil, configuration.guestMetadataPath != nil else {
            throw ContainerizationError(
                .invalidState,
                message: "image-backed workload \(configuration.id) is missing guest payload metadata"
            )
        }
    }

    private func guestPayloadPath(for workloadID: String) -> String {
        "\(Self.guestWorkloadsRootPath)/\(workloadID)/rootfs"
    }

    private func guestMetadataPath(for workloadID: String) -> String {
        "\(Self.guestWorkloadsRootPath)/\(workloadID)/meta.json"
    }

    private struct ResolvedWorkloadImage {
        let imageDigest: String
        let manifest: Manifest
        let imageConfig: ContainerizationOCI.Image
    }

    private enum WorkloadLayerEntryKind {
        case directory
        case file
        case symlink
    }

    private struct WorkloadLayerEntry {
        let url: URL
        let relativePath: String
        let kind: WorkloadLayerEntryKind
    }

    private func resetImageBackedWorkloadsForColdBootIfNeeded() throws {
        for configuration in workloads.values.map(\.configuration) {
            guard configuration.isImageBacked, configuration.injectionState == .injected else {
                continue
            }
            var updated = configuration
            updated.injectionState = .pending
            try updateWorkloadConfiguration(updated)
        }
    }

    private func shouldResetImageBackedWorkloadsForRecovery() -> Bool {
        if case .created = sandboxState {
            return true
        }
        return false
    }

    private func resolveCreatedWorkloadConfiguration(_ configuration: WorkloadConfiguration) async throws -> WorkloadConfiguration {
        let normalized = normalizeWorkloadConfiguration(configuration)
        guard normalized.isImageBacked else {
            return normalized
        }

        let resolvedImage = try await resolveWorkloadImage(for: normalized)
        let processConfiguration = try resolveEffectiveProcessConfiguration(
            imageConfig: resolvedImage.imageConfig.config,
            requestedConfiguration: normalized.processConfiguration
        )
        return WorkloadConfiguration(
            id: normalized.id,
            processConfiguration: processConfiguration,
            workloadImageReference: normalized.workloadImageReference,
            workloadImageDigest: resolvedImage.imageDigest,
            guestPayloadPath: normalized.guestPayloadPath,
            guestMetadataPath: normalized.guestMetadataPath,
            injectionState: .pending
        )
    }

    private func ensureImageBackedWorkloadInjectedIfNeeded(
        workloadID: String,
        containerConfig: ContainerConfiguration
    ) async throws {
        guard let record = workloads[workloadID], record.configuration.isImageBacked else {
            return
        }
        guard record.configuration.injectionState != .injected else {
            return
        }
        guard let guestPayloadPath = record.configuration.guestPayloadPath,
            let guestMetadataPath = record.configuration.guestMetadataPath
        else {
            throw ContainerizationError(
                .invalidState,
                message: "image-backed workload \(workloadID) is missing guest payload metadata"
            )
        }

        let resolvedImage = try await resolveWorkloadImage(for: record.configuration)
        let hostRootfs = try await unpackWorkloadRootfs(resolvedImage)
        let metadata = try workloadGuestMetadata(
            workloadImageDigest: resolvedImage.imageDigest,
            processConfiguration: record.configuration.processConfiguration
        )
        let metadataFile = try writeTemporaryWorkloadMetadataFile(metadata, workloadID: workloadID)
        defer { try? FileManager.default.removeItem(at: metadataFile) }

        writeContainerLog(
            Data(
                ("injecting image-backed workload \(workloadID) digest=\(resolvedImage.imageDigest) guestRoot=\(guestPayloadPath)\n").utf8
            )
        )

        do {
            try await prepareGuestWorkloadInstanceDirectory(workloadID: workloadID, containerConfig: containerConfig)
            try await injectDirectoryTree(from: hostRootfs, to: guestPayloadPath)
            try await writeGuestFile(from: metadataFile, to: guestMetadataPath)

            var updated = record.configuration
            updated.workloadImageDigest = resolvedImage.imageDigest
            updated.injectionState = .injected
            try updateWorkloadConfiguration(updated)
        } catch {
            try? await cleanupGuestWorkloadInstance(workloadID: workloadID, containerConfig: containerConfig)
            throw error
        }
    }

    private func resolveWorkloadImage(for configuration: WorkloadConfiguration) async throws -> ResolvedWorkloadImage {
        guard let imageDigest = resolvedWorkloadImageDigest(for: configuration) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "image-backed workload \(configuration.id) requires a resolved workload image digest"
            )
        }
        let platform = self.configuration?.platform ?? .init(arch: "arm64", os: "darwin")

        guard let indexContent: Content = try await contentStore.get(digest: imageDigest) else {
            throw ContainerizationError(.notFound, message: "missing workload image index blob \(imageDigest)")
        }
        let index: Index = try indexContent.decode()
        guard let manifestDescriptor = index.manifests.first(where: { $0.platform == platform }) else {
            throw ContainerizationError(.notFound, message: "no workload image manifest for platform \(platform)")
        }
        guard let manifestContent: Content = try await contentStore.get(digest: manifestDescriptor.digest) else {
            throw ContainerizationError(.notFound, message: "missing workload image manifest blob \(manifestDescriptor.digest)")
        }
        let manifest: Manifest = try manifestContent.decode()
        guard let configContent: Content = try await contentStore.get(digest: manifest.config.digest) else {
            throw ContainerizationError(.notFound, message: "missing workload image config blob \(manifest.config.digest)")
        }
        let imageConfig: ContainerizationOCI.Image = try configContent.decode()

        do {
            try MacOSImageContract.validateWorkloadImage(
                descriptorAnnotations: manifestDescriptor.annotations,
                manifest: manifest,
                imageConfig: imageConfig
            )
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "image \(configuration.workloadImageReference ?? imageDigest) cannot be used as a macOS workload payload: \(error.localizedDescription)"
            )
        }

        let supportedLayerMediaTypes = Set([
            MediaTypes.imageLayer,
            MediaTypes.imageLayerGzip,
            MediaTypes.imageLayerZstd,
            MediaTypes.dockerImageLayer,
            MediaTypes.dockerImageLayerGzip,
            MediaTypes.dockerImageLayerZstd,
        ])
        if let unsupported = manifest.layers.first(where: { !supportedLayerMediaTypes.contains($0.mediaType) }) {
            throw ContainerizationError(
                .unsupported,
                message: "macOS workload image layer media type \(unsupported.mediaType) is not supported"
            )
        }

        return ResolvedWorkloadImage(
            imageDigest: imageDigest,
            manifest: manifest,
            imageConfig: imageConfig
        )
    }

    private func resolvedWorkloadImageDigest(for configuration: WorkloadConfiguration) -> String? {
        if let digest = configuration.workloadImageDigest, !digest.isEmpty {
            return digest
        }
        guard let reference = configuration.workloadImageReference,
            let digestStart = reference.lastIndex(of: "@")
        else {
            return nil
        }
        let digest = String(reference[reference.index(after: digestStart)...])
        return digest.isEmpty ? nil : digest
    }

    // Image-backed workloads currently use a default-shaped ProcessConfiguration as an
    // internal "no explicit override" marker until the public workload image create
    // surface grows dedicated override fields.
    private func resolveEffectiveProcessConfiguration(
        imageConfig: ImageConfig?,
        requestedConfiguration: ProcessConfiguration
    ) throws -> ProcessConfiguration {
        let command: [String]
        let requestedExecutable = requestedConfiguration.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedExecutable.isEmpty {
            command = [requestedExecutable] + requestedConfiguration.arguments
        } else {
            var fallback: [String] = imageConfig?.entrypoint ?? []
            if !requestedConfiguration.arguments.isEmpty {
                fallback.append(contentsOf: requestedConfiguration.arguments)
            } else if let cmd = imageConfig?.cmd {
                fallback.append(contentsOf: cmd)
            }
            guard !fallback.isEmpty else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "workload image does not define an entrypoint/cmd and no explicit executable override was supplied"
                )
            }
            command = fallback
        }

        let resolvedWorkingDirectory: String = {
            let requested = requestedConfiguration.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !requested.isEmpty, requested != "/" {
                return requested
            }
            if let imageWorkingDirectory = imageConfig?.workingDir, !imageWorkingDirectory.isEmpty {
                return imageWorkingDirectory
            }
            return requested.isEmpty ? "/" : requested
        }()

        let resolvedUser: ProcessConfiguration.User = {
            switch requestedConfiguration.user {
            case .raw(let userString) where !userString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                return .raw(userString: userString)
            case .id(let uid, let gid) where uid != 0 || gid != 0:
                return .id(uid: uid, gid: gid)
            default:
                if let imageUser = imageConfig?.user, !imageUser.isEmpty {
                    return .raw(userString: imageUser)
                }
                return requestedConfiguration.user
            }
        }()

        return ProcessConfiguration(
            executable: command[0],
            arguments: Array(command.dropFirst()),
            environment: mergeEnvironmentEntries(base: imageConfig?.env ?? [], overrides: requestedConfiguration.environment),
            workingDirectory: resolvedWorkingDirectory,
            terminal: requestedConfiguration.terminal,
            user: resolvedUser,
            supplementalGroups: requestedConfiguration.supplementalGroups,
            rlimits: requestedConfiguration.rlimits
        )
    }

    private func mergeEnvironmentEntries(base: [String], overrides: [String]) -> [String] {
        var orderedKeys: [String] = []
        var rawValues: [String: String] = [:]

        func insert(_ entry: String) {
            let key = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? entry
            if rawValues[key] == nil {
                orderedKeys.append(key)
            }
            rawValues[key] = entry
        }

        for entry in base {
            insert(entry)
        }
        for entry in overrides {
            insert(entry)
        }

        return orderedKeys.compactMap { rawValues[$0] }
    }

    private func resolveLaunchProcessConfiguration(
        for processID: String,
        sessionConfiguration: ProcessConfiguration
    ) async throws -> ProcessConfiguration {
        guard let workloadID = workloadID(forSession: processID),
            let record = workloads[workloadID],
            record.configuration.isImageBacked,
            let guestPayloadPath = record.configuration.guestPayloadPath
        else {
            return sessionConfiguration
        }

        let resolvedImage = try await resolveWorkloadImage(for: record.configuration)
        let hostRootfs = try await unpackWorkloadRootfs(resolvedImage)
        return mapImageBackedWorkloadProcessConfiguration(
            sessionConfiguration,
            guestPayloadPath: guestPayloadPath,
            hostRootfs: hostRootfs
        )
    }

    private func mapImageBackedWorkloadProcessConfiguration(
        _ configuration: ProcessConfiguration,
        guestPayloadPath: String,
        hostRootfs: URL
    ) -> ProcessConfiguration {
        ProcessConfiguration(
            executable: mapImageBackedWorkloadPath(
                configuration.executable,
                guestPayloadPath: guestPayloadPath,
                hostRootfs: hostRootfs
            ) ?? configuration.executable,
            arguments: configuration.arguments.map {
                mapImageBackedWorkloadArgument(
                    $0,
                    guestPayloadPath: guestPayloadPath,
                    hostRootfs: hostRootfs
                )
            },
            environment: configuration.environment,
            workingDirectory: mapImageBackedWorkloadWorkingDirectory(
                configuration.workingDirectory,
                guestPayloadPath: guestPayloadPath,
                hostRootfs: hostRootfs
            ),
            terminal: configuration.terminal,
            user: configuration.user,
            supplementalGroups: configuration.supplementalGroups,
            rlimits: configuration.rlimits
        )
    }

    private func mapImageBackedWorkloadArgument(
        _ argument: String,
        guestPayloadPath: String,
        hostRootfs: URL
    ) -> String {
        if let mapped = mapImageBackedWorkloadPath(
            argument,
            guestPayloadPath: guestPayloadPath,
            hostRootfs: hostRootfs
        ) {
            return mapped
        }

        guard let equalsIndex = argument.firstIndex(of: "=") else {
            return argument
        }
        let valueStart = argument.index(after: equalsIndex)
        let value = String(argument[valueStart...])
        guard let mappedValue = mapImageBackedWorkloadPath(
            value,
            guestPayloadPath: guestPayloadPath,
            hostRootfs: hostRootfs
        ) else {
            return argument
        }
        return String(argument[..<valueStart]) + mappedValue
    }

    private func mapImageBackedWorkloadWorkingDirectory(
        _ workingDirectory: String,
        guestPayloadPath: String,
        hostRootfs: URL
    ) -> String {
        let normalized = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == "/" {
            return guestPayloadPath
        }
        return mapImageBackedWorkloadPath(
            normalized,
            guestPayloadPath: guestPayloadPath,
            hostRootfs: hostRootfs,
            requireDirectory: true
        ) ?? workingDirectory
    }

    private func mapImageBackedWorkloadPath(
        _ path: String,
        guestPayloadPath: String,
        hostRootfs: URL,
        requireDirectory: Bool? = nil
    ) -> String? {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        guard normalized.hasPrefix("/") else {
            return nil
        }

        let relativePath = normalized.drop(while: { $0 == "/" })
        guard !relativePath.isEmpty else {
            return guestPayloadPath
        }

        let hostCandidate = hostRootfs.appendingPathComponent(String(relativePath))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hostCandidate.path, isDirectory: &isDirectory) else {
            return nil
        }
        if let requireDirectory, isDirectory.boolValue != requireDirectory {
            return nil
        }
        return joinGuestPath(guestPayloadPath, String(relativePath))
    }

    private func unpackWorkloadRootfs(_ resolvedImage: ResolvedWorkloadImage) async throws -> URL {
        let fileManager = FileManager.default
        let cacheRoot = MacOSGuestCache.workloadRootfsCacheDirectory(fileManager: fileManager)
        let cachedDirectory = cacheRoot.appendingPathComponent(MacOSGuestCache.safeDigest(resolvedImage.imageDigest), isDirectory: true)
        let cachedRootfs = cachedDirectory.appendingPathComponent("rootfs", isDirectory: true)
        if fileManager.fileExists(atPath: cachedRootfs.path) {
            return cachedRootfs
        }

        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let stagingDirectory = cacheRoot.appendingPathComponent(".workload-\(UUID().uuidString)", isDirectory: true)
        let stagingRootfs = stagingDirectory.appendingPathComponent("rootfs", isDirectory: true)
        try fileManager.createDirectory(at: stagingRootfs, withIntermediateDirectories: true)

        do {
            for (index, layer) in resolvedImage.manifest.layers.enumerated() {
                guard let layerContent: Content = try await contentStore.get(digest: layer.digest) else {
                    throw ContainerizationError(.notFound, message: "missing workload layer blob \(layer.digest)")
                }
                let extractedLayerDirectory = stagingDirectory.appendingPathComponent("layer-\(index)", isDirectory: true)
                let rejectedMembers = try ArchiveReader(file: layerContent.path).extractContents(to: extractedLayerDirectory)
                guard rejectedMembers.isEmpty else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "workload layer \(layer.digest) contains rejected archive members: \(rejectedMembers.joined(separator: ", "))"
                    )
                }
                try applyExtractedWorkloadLayer(at: extractedLayerDirectory, to: stagingRootfs)
                try? fileManager.removeItem(at: extractedLayerDirectory)
            }

            do {
                try fileManager.moveItem(at: stagingDirectory, to: cachedDirectory)
            } catch {
                if fileManager.fileExists(atPath: cachedRootfs.path) {
                    try? fileManager.removeItem(at: stagingDirectory)
                    return cachedRootfs
                }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }

        return cachedRootfs
    }

    private func applyExtractedWorkloadLayer(at sourceRoot: URL, to destinationRoot: URL) throws {
        try applyWhiteouts(from: sourceRoot, to: destinationRoot)
        for entry in try walkWorkloadLayerTree(root: sourceRoot) {
            guard !isWhiteoutEntry(entry.url) else {
                continue
            }
            let destinationURL = destinationRoot.appendingPathComponent(entry.relativePath)
            switch entry.kind {
            case .directory:
                try createOrMergeDirectory(from: entry.url, to: destinationURL)
            case .file:
                try cloneOrCopyLeafItem(from: entry.url, to: destinationURL)
            case .symlink:
                try recreateSymbolicLink(from: entry.url, to: destinationURL)
            }
        }
    }

    private func applyWhiteouts(from sourceRoot: URL, to destinationRoot: URL) throws {
        let fileManager = FileManager.default
        for entry in try walkWorkloadLayerTree(root: sourceRoot) {
            let basename = entry.url.lastPathComponent
            if basename == ".wh..wh..opq" {
                let relativeDirectory = (entry.relativePath as NSString).deletingLastPathComponent
                let targetDirectory = relativeDirectory.isEmpty
                    ? destinationRoot
                    : destinationRoot.appendingPathComponent(relativeDirectory)
                if fileManager.fileExists(atPath: targetDirectory.path) {
                    for child in try fileManager.contentsOfDirectory(at: targetDirectory, includingPropertiesForKeys: nil, options: []) {
                        try fileManager.removeItem(at: child)
                    }
                }
                try fileManager.removeItem(at: entry.url)
                continue
            }
            guard basename.hasPrefix(".wh.") else {
                continue
            }

            let parentDirectory = (entry.relativePath as NSString).deletingLastPathComponent
            let targetName = String(basename.dropFirst(4))
            let targetRelativePath = parentDirectory.isEmpty ? targetName : "\(parentDirectory)/\(targetName)"
            let targetURL = destinationRoot.appendingPathComponent(targetRelativePath)
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.removeItem(at: entry.url)
        }
    }

    private func walkWorkloadLayerTree(root: URL) throws -> [WorkloadLayerEntry] {
        var entries: [WorkloadLayerEntry] = []
        try collectWorkloadLayerTreeEntries(at: root, root: root, into: &entries)
        return entries
    }

    private func collectWorkloadLayerTreeEntries(
        at directory: URL,
        root: URL,
        into entries: inout [WorkloadLayerEntry]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in children {
            let relativePath = String(child.path.dropFirst(root.path.count + 1))
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                entries.append(.init(url: child, relativePath: relativePath, kind: .symlink))
                continue
            }
            if values.isDirectory == true {
                entries.append(.init(url: child, relativePath: relativePath, kind: .directory))
                try collectWorkloadLayerTreeEntries(at: child, root: root, into: &entries)
                continue
            }
            entries.append(.init(url: child, relativePath: relativePath, kind: .file))
        }
    }

    private func isWhiteoutEntry(_ url: URL) -> Bool {
        let basename = url.lastPathComponent
        return basename == ".wh..wh..opq" || basename.hasPrefix(".wh.")
    }

    private func createOrMergeDirectory(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try applyHostMetadata(from: source, to: destination)
    }

    private func cloneOrCopyLeafItem(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try FilesystemClone.cloneOrCopyItem(at: source, to: destination)
        try applyHostMetadata(from: source, to: destination)
    }

    private func recreateSymbolicLink(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
    }

    private func applyHostMetadata(from source: URL, to destination: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        var updatedAttributes: [FileAttributeKey: Any] = [:]
        if let permissions = attributes[.posixPermissions] {
            updatedAttributes[.posixPermissions] = permissions
        }
        if let modificationDate = attributes[.modificationDate] {
            updatedAttributes[.modificationDate] = modificationDate
        }
        if !updatedAttributes.isEmpty {
            try FileManager.default.setAttributes(updatedAttributes, ofItemAtPath: destination.path)
        }
    }

    private func prepareGuestWorkloadInstanceDirectory(
        workloadID: String,
        containerConfig: ContainerConfiguration
    ) async throws {
        try await runGuestBootstrapScript(
            processIDPrefix: "workload-prepare",
            script: """
                set -euo pipefail
                root=\(shQuoteForWorkloadScript("\(Self.guestWorkloadsRootPath)/\(workloadID)"))
                rm -rf "$root"
                mkdir -p "$root/rootfs"
                """,
            containerConfig: containerConfig
        )
    }

    private func cleanupGuestWorkloadInstance(
        workloadID: String,
        containerConfig: ContainerConfiguration
    ) async throws {
        try await runGuestBootstrapScript(
            processIDPrefix: "workload-cleanup",
            script: """
                set -euo pipefail
                root=\(shQuoteForWorkloadScript("\(Self.guestWorkloadsRootPath)/\(workloadID)"))
                rm -rf "$root"
                """,
            containerConfig: containerConfig
        )
    }

    private func cleanupGuestWorkloadsIfNeeded(containerConfig: ContainerConfiguration) async {
        guard workloads.values.contains(where: { $0.configuration.isImageBacked }) else {
            return
        }
        do {
            try await runGuestBootstrapScript(
                processIDPrefix: "workload-cleanup-all",
                script: """
                    set -euo pipefail
                    rm -rf \(shQuoteForWorkloadScript(Self.guestWorkloadsRootPath))
                    mkdir -p \(shQuoteForWorkloadScript(Self.guestWorkloadsRootPath))
                """,
                containerConfig: containerConfig
            )
            for configuration in workloads.values.map(\.configuration) where configuration.isImageBacked {
                var updated = configuration
                updated.injectionState = .pending
                try updateWorkloadConfiguration(updated)
            }
        } catch {
            writeContainerLog(Data(("failed to clean guest workloads before stop: \(describeError(error))\n").utf8))
        }
    }

    private func runGuestBootstrapScript(
        processIDPrefix: String,
        script: String,
        containerConfig: ContainerConfiguration,
        timeout: Int32 = 30
    ) async throws {
        let processID = "\(processIDPrefix)-\(UUID().uuidString)"
        var session = try makeSession(
            processID: processID,
            config: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["-ceu", script],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            stdio: [nil, nil, nil],
            includeInSnapshots: false
        )

        sessions[processID] = session
        defer {
            cleanupTemporarySession(processID: processID)
        }

        do {
            try await startSessionViaSidecarProcessStream(&session, containerConfig: containerConfig)
            let status = try await waitForProcess(processID, timeout: timeout)
            guard status.exitCode == 0 else {
                let detail =
                    sessions[processID]?.lastAgentError ?? sessions[processID]?.lastStderr ?? "bootstrap script exited with status \(status.exitCode)"
                throw ContainerizationError(.internalError, message: detail)
            }
        } catch {
            try? sendSignalToProcess(processID: processID, signal: SIGKILL)
            throw error
        }
    }

    private func cleanupTemporarySession(processID: String) {
        guard let session = sessions.removeValue(forKey: processID) else {
            return
        }
        session.stdio[0]?.readabilityHandler = nil
        try? session.stdio[1]?.close()
        try? session.stdio[2]?.close()
        try? session.stdoutLogHandle?.close()
        try? session.stderrLogHandle?.close()
    }

    private func injectDirectoryTree(from sourceRoot: URL, to guestRoot: String) async throws {
        for entry in try walkWorkloadLayerTree(root: sourceRoot) {
            let destinationPath = joinGuestPath(guestRoot, entry.relativePath)
            switch entry.kind {
            case .directory:
                try await createGuestDirectory(from: entry.url, to: destinationPath)
            case .file:
                try await writeGuestFile(from: entry.url, to: destinationPath)
            case .symlink:
                try await createGuestSymbolicLink(from: entry.url, to: destinationPath)
            }
        }
    }

    private func createGuestDirectory(from source: URL, to destinationPath: String) async throws {
        try await MacOSSidecarFileTransfer.createDirectory(
            at: destinationPath,
            options: .init(mode: hostFileMode(at: source), mtime: hostModificationTime(at: source)),
            begin: { payload in
                try await self.sendFSBegin(payload)
            }
        )
    }

    private func writeGuestFile(from source: URL, to destinationPath: String) async throws {
        try await MacOSSidecarFileTransfer.writeFile(
            from: source,
            to: destinationPath,
            options: .init(mode: hostFileMode(at: source), mtime: hostModificationTime(at: source), overwrite: true),
            begin: { payload in
                try await self.sendFSBegin(payload)
            },
            chunk: { payload in
                try await self.sendFSChunk(payload)
            },
            end: { payload in
                try await self.sendFSEnd(payload)
            }
        )
    }

    private func createGuestSymbolicLink(from source: URL, to destinationPath: String) async throws {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
        try await MacOSSidecarFileTransfer.createSymbolicLink(
            at: destinationPath,
            target: target,
            options: .init(mtime: hostModificationTime(at: source), overwrite: true),
            begin: { payload in
                try await self.sendFSBegin(payload)
            }
        )
    }

    private func hostFileMode(at url: URL) -> UInt32? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.uint32Value
    }

    private func hostModificationTime(at url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
    }

    private func writeTemporaryWorkloadMetadataFile(
        _ metadata: MacOSWorkloadGuestMetadata,
        workloadID: String
    ) throws -> URL {
        try layout.prepareBaseDirectories()
        let url = layout.temporaryDirectoryURL.appendingPathComponent("workload-\(workloadID)-meta-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: url, options: .atomic)
        return url
    }

    private func workloadGuestMetadata(
        workloadImageDigest: String,
        processConfiguration: ProcessConfiguration
    ) throws -> MacOSWorkloadGuestMetadata {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return MacOSWorkloadGuestMetadata(
            workloadImageDigest: workloadImageDigest,
            createdAt: formatter.string(from: Date()),
            processConfiguration: processConfiguration
        )
    }

    private func updateWorkloadConfiguration(_ configuration: WorkloadConfiguration) throws {
        let existingSessionID = workloads[configuration.id]?.sessionID
        upsertWorkloadRecord(configuration: configuration)
        if let existingSessionID, var session = sessions[existingSessionID] {
            session.config = configuration.processConfiguration
            sessions[existingSessionID] = session
        }
        try persistWorkloadConfiguration(configuration)
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
        guard let indexContent: Content = try await contentStore.get(digest: containerConfig.image.digest) else {
            throw ContainerizationError(.notFound, message: "missing index blob \(containerConfig.image.digest)")
        }
        let index: Index = try indexContent.decode()
        guard let manifestDescriptor = index.manifests.first(where: { $0.platform == containerConfig.platform }) else {
            throw ContainerizationError(.notFound, message: "no manifest for platform \(containerConfig.platform)")
        }
        guard let manifestContent: Content = try await contentStore.get(digest: manifestDescriptor.digest) else {
            throw ContainerizationError(.notFound, message: "missing manifest blob \(manifestDescriptor.digest)")
        }
        let manifest: Manifest = try manifestContent.decode()
        do {
            try MacOSImageContract.validateSandboxImage(
                descriptorAnnotations: manifestDescriptor.annotations,
                manifest: manifest
            )
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "image \(containerConfig.image.reference) cannot boot a macOS sandbox: \(error.localizedDescription)"
            )
        }
        let layers = try MacOSImageLayers(manifest: manifest)

        guard let hardwareContent: Content = try await contentStore.get(digest: layers.hardwareModel.digest) else {
            throw ContainerizationError(.notFound, message: "missing hardware model blob \(layers.hardwareModel.digest)")
        }
        guard let auxiliaryContent: Content = try await contentStore.get(digest: layers.auxiliaryStorage.digest) else {
            throw ContainerizationError(.notFound, message: "missing auxiliary storage blob \(layers.auxiliaryStorage.digest)")
        }

        let diskImagePath: URL
        switch layers {
        case .v0(_, _, let diskImage):
            guard let diskContent: Content = try await contentStore.get(digest: diskImage.digest) else {
                throw ContainerizationError(.notFound, message: "missing disk image blob \(diskImage.digest)")
            }
            diskImagePath = diskContent.path

        case .v1(_, _, let diskLayoutDesc, let diskChunks):
            diskImagePath = try await resolveV1DiskImage(
                store: contentStore,
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
        store: any ContentStore,
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

    private func isWorkloadRunning(_ record: WorkloadRecord) -> Bool {
        guard record.exitStatus == nil else {
            return false
        }
        if let sessionID = record.sessionID, let session = sessions[sessionID] {
            return session.started && session.exitStatus == nil
        }
        return record.startedAt != nil
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

    private func removeWorkloadStateDirectoryIfPresent(workloadID: String) throws {
        let directoryURL = workloadDirectory(for: workloadID)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: directoryURL)
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
        externalProcessIDs.removeAll()
        guestAgentLogCaptureProcessID = nil
    }

    private func cleanupExitedExternalProcessIfNeeded(processID: String) {
        guard externalProcessIDs.contains(processID) else {
            return
        }
        guard waiters[processID]?.isEmpty ?? true else {
            return
        }
        guard sessions[processID]?.exitStatus != nil else {
            return
        }
        externalProcessIDs.remove(processID)
        cleanupTemporarySession(processID: processID)
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

        let launchConfiguration = try await resolveLaunchProcessConfiguration(
            for: processID,
            sessionConfiguration: session.config
        )
        let execIdentity: (user: String?, uid: UInt32?, gid: UInt32?) =
            switch launchConfiguration.user {
            case .raw(let userString):
                (userString, nil, nil)
            case .id(let uid, let gid):
                (nil, uid, gid)
            }
        let request = MacOSSidecarExecRequestPayload(
            executable: launchConfiguration.executable,
            arguments: launchConfiguration.arguments,
            environment: launchConfiguration.environment,
            workingDirectory: launchConfiguration.workingDirectory,
            terminal: launchConfiguration.terminal,
            user: execIdentity.user,
            uid: execIdentity.uid,
            gid: execIdentity.gid,
            supplementalGroups: launchConfiguration.supplementalGroups.isEmpty ? nil : launchConfiguration.supplementalGroups,
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
            }
        case .processStderr:
            if let data = event.data, !data.isEmpty {
                if let stderr = session.stdio[2] {
                    try? stderr.write(contentsOf: data)
                } else if let stdout = session.stdio[1] {
                    try? stdout.write(contentsOf: data)
                }
                try? session.stderrLogHandle?.write(contentsOf: data)
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

private func joinGuestPath(_ base: String, _ relativePath: String) -> String {
    guard !relativePath.isEmpty else {
        return base
    }
    return base.hasSuffix("/") ? base + relativePath : base + "/" + relativePath
}

private func shQuoteForWorkloadScript(_ value: String) -> String {
    if value.isEmpty {
        return "''"
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
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

    fileprivate func workloadConfiguration(id fallbackID: String) throws -> WorkloadConfiguration {
        if let data = self.dataNoCopy(key: SandboxKeys.workloadConfig.rawValue) {
            let configuration = try JSONDecoder().decode(WorkloadConfiguration.self, from: data)
            guard configuration.id == fallbackID else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "workload configuration id \(configuration.id) does not match requested id \(fallbackID)"
                )
            }
            return configuration
        }
        return WorkloadConfiguration(id: fallbackID, processConfiguration: try processConfig())
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
            let workloadConfiguration: WorkloadConfiguration
            if let persisted = try! loadJSONIfPresent(WorkloadConfiguration.self, from: workloadConfigurationPath(for: id)) {
                workloadConfiguration = persisted
            } else {
                workloadConfiguration = .init(id: id, processConfiguration: config)
            }
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

    func testingContainerLogPath() -> String {
        stdioLogPath().path
    }

    func testingOpenLogs() throws {
        try openLogsIfNeeded()
    }

    func testingStateSnapshot() async throws -> SandboxSnapshot {
        guard let configuration else {
            throw ContainerizationError(.invalidState, message: "container not bootstrapped")
        }

        let status: RuntimeStatus =
            switch sandboxState {
            case .booted, .running: .running
            case .stopping: .stopping
            default: .stopped
            }
        let networks = await inspectSandboxNetworkState(containerConfig: configuration).attachments

        return SandboxSnapshot(
            configuration: try sandboxConfigurationSnapshot(),
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
    }

    func testingPersistSandboxMetadata(_ configuration: ContainerConfiguration) throws {
        try persistSandboxMetadata(for: configuration)
    }

    func testingPersistWorkloadConfiguration(_ configuration: WorkloadConfiguration) throws {
        try persistWorkloadConfiguration(configuration)
    }

    func testingPrepareSandbox(_ configuration: ContainerConfiguration, state: String = "booted") throws {
        self.configuration = configuration
        switch state {
        case "created":
            self.sandboxState = .created
        case "running":
            self.sandboxState = .running
        default:
            self.sandboxState = .booted
        }
        try persistSandboxMetadata(for: configuration)
        try restorePersistedWorkloadsIfNeeded(containerConfig: configuration)
        if shouldResetImageBackedWorkloadsForRecovery() {
            try resetImageBackedWorkloadsForColdBootIfNeeded()
        }
    }

    func testingInstallSidecarClient(socketPath: String, launchLabel: String = "testing-sidecar") {
        let client = MacOSSidecarClient(socketPath: socketPath, log: log)
        client.setEventHandler { [weak self] event in
            guard let self else { return }
            Task {
                await self.handleSidecarEvent(event)
            }
        }
        sidecarHandle = SidecarHandle(launchLabel: launchLabel, client: client)
    }

    func testingCreateWorkload(_ configuration: WorkloadConfiguration) async throws {
        try await createWorkloadIfNeeded(workloadConfiguration: configuration, stdio: [nil, nil, nil])
    }

    func testingCreateProcess(_ id: String, config: ProcessConfiguration) async throws {
        try await createExecProcessIfNeeded(processID: id, config: config, stdio: [nil, nil, nil])
    }

    func testingStartProcess(_ id: String) async throws {
        try await startExecProcessIfNeeded(processID: id)
    }

    func testingWaitExternalProcess(_ id: String) async throws -> ExitStatus {
        guard externalProcessIDs.contains(id) else {
            throw ContainerizationError(.notFound, message: "process \(id) not found")
        }
        let status = try await waitForProcess(id)
        cleanupExitedExternalProcessIfNeeded(processID: id)
        return status
    }

    func testingSignalExternalProcess(_ id: String, signal: Int32) throws {
        guard externalProcessIDs.contains(id) else {
            throw ContainerizationError(.notFound, message: "process \(id) not found")
        }
        try sendSignalToProcess(processID: id, signal: signal)
    }

    func testingResizeExternalProcess(_ id: String, width: UInt16, height: UInt16) throws {
        guard externalProcessIDs.contains(id) else {
            throw ContainerizationError(.notFound, message: "process \(id) not found")
        }
        try sendResizeToProcess(processID: id, width: width, height: height)
    }

    func testingExternalProcessExists(_ id: String) -> Bool {
        externalProcessIDs.contains(id) && sessions[id] != nil
    }

    func testingStartWorkload(_ workloadID: String) async throws {
        try await startWorkloadIfNeeded(workloadID: workloadID)
    }

    func testingRemoveWorkload(_ workloadID: String) async throws {
        try await removeWorkloadIfNeeded(workloadID: workloadID)
    }

    func testingStopWorkload(_ workloadID: String, options: ContainerStopOptions = .default) async throws {
        try await stopWorkloadIfNeeded(workloadID: workloadID, stopOptions: options)
    }

    func testingStop(_ options: ContainerStopOptions = .default) async throws {
        try await stopSandbox(stopOptions: options)
    }

    func testingWorkloadConfiguration(_ workloadID: String) -> WorkloadConfiguration? {
        workloads[workloadID]?.configuration
    }
}
