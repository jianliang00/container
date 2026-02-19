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
import Foundation
import Logging

#if arch(arm64)
import AppKit
import CoreGraphics
@preconcurrency import Virtualization

@MainActor
private var macOSGuestWindows: [NSWindow] = []
#endif

public actor MacOSSandboxService {
    private static let fallbackAgentPort: UInt32 = 27000

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
        var vsockConnection: AnyObject?
        var vsockHandle: FileHandle?
        var inputBuffer: Data = .init()
        var started: Bool = false
        var exitStatus: ExitStatus?
        var readTask: Task<Void, Never>?
    }

    private let root: URL
    private let connection: xpc_connection_t
    private let log: Logger

    private var sandboxState: State = .created
    private var configuration: ContainerConfiguration?
    private var sessions: [String: Session] = [:]
    private var waiters: [String: [CheckedContinuation<ExitStatus, Never>]] = [:]

    private var logHandle: FileHandle?
    private var bootLogHandle: FileHandle?

    #if arch(arm64)
    private var vm: VZVirtualMachine?
    private var vmConfiguration: VZVirtualMachineConfiguration?
    private var socketDevice: VZVirtioSocketDevice?
    #endif

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
        try await startSession(&session, containerConfig: configuration)
        #else
        throw ContainerizationError(.unsupported, message: "macOS runtime requires an arm64 host")
        #endif

        session.started = true
        sessions[processID] = session

        if processID == configuration.id {
            sandboxState = .running
        }
        return message.reply()
    }

    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let status = try await waitForProcess(id)
        let reply = message.reply()
        reply.set(key: SandboxKeys.exitCode.rawValue, value: Int64(status.exitCode))
        reply.set(key: SandboxKeys.exitedAt.rawValue, value: status.exitedAt)
        return reply
    }

    @Sendable
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        let signal = Int32(message.int64(key: SandboxKeys.signal.rawValue))
        try await sendFrame(to: processID, frame: .signal(id: processID, signal: signal))
        return message.reply()
    }

    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        let processID = try message.id()
        let width = UInt16(message.uint64(key: SandboxKeys.width.rawValue))
        let height = UInt16(message.uint64(key: SandboxKeys.height.rawValue))
        try await sendFrame(to: processID, frame: .resize(id: processID, width: width, height: height))
        return message.reply()
    }

    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        let stopOptions = try message.stopOptions()
        sandboxState = .stopping

        if let id = configuration?.id, sessions[id]?.started == true {
            try? await sendFrame(to: id, frame: .signal(id: id, signal: Int32(stopOptions.signal)))
            _ = try? await waitForProcess(id, timeout: stopOptions.timeoutInSeconds)
        }

        #if arch(arm64)
        if let configuration {
            try await saveSnapshotIfNeeded(configuration)
        }
        try await stopVirtualMachine()
        #endif

        closeAllSessions()
        sandboxState = .stopped(0)
        return message.reply()
    }

    @Sendable
    public func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
        switch sandboxState {
        case .created, .stopping, .stopped(_):
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
        let status: RuntimeStatus = switch sandboxState {
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
        guard let socketDevice else {
            throw ContainerizationError(.invalidState, message: "vm socket device not available")
        }
        let port = UInt32(message.uint64(key: SandboxKeys.port.rawValue))
        let connection = try await socketDevice.connect(toPort: port)
        let duplicated = dup(connection.fileDescriptor)
        guard duplicated >= 0 else {
            throw POSIXError.fromErrno()
        }
        let fh = FileHandle(fileDescriptor: duplicated, closeOnDealloc: true)
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

    private func machineIdentifierPath() -> URL {
        root.appendingPathComponent("MachineIdentifier.bin")
    }

    private func snapshotPath() -> URL {
        root.appendingPathComponent("MachineState.vzvmsave")
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

    private func writeContainerLog(_ data: Data) {
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
        let layers = try MacOSTemplateLayers(manifest: manifest)

        guard let hardwareContent: Content = try await store.get(digest: layers.hardwareModel.digest) else {
            throw ContainerizationError(.notFound, message: "missing hardware model blob \(layers.hardwareModel.digest)")
        }
        guard let auxiliaryContent: Content = try await store.get(digest: layers.auxiliaryStorage.digest) else {
            throw ContainerizationError(.notFound, message: "missing auxiliary storage blob \(layers.auxiliaryStorage.digest)")
        }
        guard let diskContent: Content = try await store.get(digest: layers.diskImage.digest) else {
            throw ContainerizationError(.notFound, message: "missing disk image blob \(layers.diskImage.digest)")
        }

        return LayerPaths(
            hardwareModel: hardwareContent.path,
            auxiliaryStorage: auxiliaryContent.path,
            diskImage: diskContent.path
        )
    }

    #if arch(arm64)
    private func startOrRestoreVirtualMachine(config: ContainerConfiguration) async throws {
        let vmConfiguration = try makeVirtualMachineConfiguration(containerConfig: config)
        self.vmConfiguration = vmConfiguration
        let vm = VZVirtualMachine(configuration: vmConfiguration)
        self.vm = vm
        self.socketDevice = vm.socketDevices.compactMap { $0 as? VZVirtioSocketDevice }.first
        guard socketDevice != nil else {
            throw ContainerizationError(.invalidState, message: "vm socket device is unavailable")
        }

        let snapshotEnabled = config.macosGuest?.snapshotEnabled ?? false
        let snapshotURL = snapshotPath()
        if snapshotEnabled, #available(macOS 14.0, *), FileManager.default.fileExists(atPath: snapshotURL.path) {
            do {
                try await restoreMachineState(vm, from: snapshotURL)
                try await vm.resume()
                await presentGUIIfNeeded(config: config, vm: vm)
                try writeBootLog("restored vm state from snapshot")
                return
            } catch {
                try writeBootLog("failed to restore snapshot, falling back to cold boot: \(error)")
            }
        }

        try await vm.start()
        await presentGUIIfNeeded(config: config, vm: vm)
    }

    private func makeVirtualMachineConfiguration(containerConfig: ContainerConfiguration) throws -> VZVirtualMachineConfiguration {
        let hardwareData = try Data(contentsOf: hardwareModelPath())
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw ContainerizationError(.invalidState, message: "invalid hardware model data")
        }
        let machineIdentifier: VZMacMachineIdentifier = try {
            if FileManager.default.fileExists(atPath: machineIdentifierPath().path) {
                let data = try Data(contentsOf: machineIdentifierPath())
                if let value = VZMacMachineIdentifier(dataRepresentation: data) {
                    return value
                }
            }
            let value = VZMacMachineIdentifier()
            try value.dataRepresentation.write(to: machineIdentifierPath())
            return value
        }()

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStoragePath())

        let vmConfiguration = VZVirtualMachineConfiguration()
        vmConfiguration.bootLoader = VZMacOSBootLoader()
        vmConfiguration.platform = platform

        vmConfiguration.cpuCount = max(
            Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            min(Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount), containerConfig.resources.cpus)
        )
        vmConfiguration.memorySize = max(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(VZVirtualMachineConfiguration.maximumAllowedMemorySize, containerConfig.resources.memoryInBytes)
        )
        vmConfiguration.storageDevices = [
            VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: diskImagePath(), readOnly: false)
            )
        ]
        vmConfiguration.networkDevices = [createNATDevice()]
        vmConfiguration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if containerConfig.macosGuest?.guiEnabled == true {
            if !Self.isAquaSession() {
                throw ContainerizationError(
                    .unsupported,
                    message: "--gui requires an Aqua login session. Run from a user login session instead of background launch contexts."
                )
            }
            vmConfiguration.graphicsDevices = [createGraphicsDevice()]
            vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
            vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }

        try vmConfiguration.validate()
        return vmConfiguration
    }

    private static func isAquaSession() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["kCGSessionOnConsoleKey"] as? Bool) == true
    }

    private func createNATDevice() -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return device
    }

    private func presentGUIIfNeeded(config: ContainerConfiguration, vm: VZVirtualMachine) async {
        guard config.macosGuest?.guiEnabled == true else {
            return
        }
        // UI APIs are main-thread-only. We explicitly opt out of actor isolation for this
        // immutable reference before hopping to MainActor to wire it into the window view.
        nonisolated(unsafe) let uiVM = vm

        await MainActor.run {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)

            let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = config.id

            let vmView = VZVirtualMachineView(frame: frame)
            vmView.virtualMachine = uiVM
            vmView.capturesSystemKeys = true
            vmView.autoresizingMask = [.width, .height]
            window.contentView = vmView

            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            macOSGuestWindows.append(window)
        }
    }

    private func createGraphicsDevice() -> VZMacGraphicsDeviceConfiguration {
        let graphics = VZMacGraphicsDeviceConfiguration()
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            graphics.displays = [
                VZMacGraphicsDisplayConfiguration(
                    for: screen,
                    sizeInPoints: NSSize(width: 1280, height: 800)
                )
            ]
        } else {
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 80)]
        }
        return graphics
    }

    @available(macOS 14.0, *)
    private func restoreMachineState(_ vm: VZVirtualMachine, from url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.restoreMachineStateFrom(url: url) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    @available(macOS 14.0, *)
    private func saveMachineState(_ vm: VZVirtualMachine, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.saveMachineStateTo(url: url) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private func stopVirtualMachine() async throws {
        guard let vm else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.stop(completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            })
        }
    }

    private func saveSnapshotIfNeeded(_ config: ContainerConfiguration) async throws {
        guard config.macosGuest?.snapshotEnabled == true else {
            return
        }
        guard #available(macOS 14.0, *) else {
            return
        }
        guard let vm else {
            return
        }

        guard let vmConfiguration else {
            throw ContainerizationError(.invalidState, message: "vm configuration not initialized")
        }
        try vmConfiguration.validateSaveRestoreSupport()

        if vm.canPause {
            try await vm.pause()
        }
        try await saveMachineState(vm, to: snapshotPath())
    }
    #endif
}

// MARK: - Process/session plumbing

extension MacOSSandboxService {
    private func waitWithoutTimeout(_ id: String) async -> ExitStatus {
        if let status = sessions[id]?.exitStatus {
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
    }

    private func completeProcess(id: String, status: ExitStatus) {
        guard var session = sessions[id] else {
            return
        }
        session.exitStatus = status
        sessions[id] = session

        let continuations = waiters[id] ?? []
        waiters[id] = []
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
            session.readTask?.cancel()
            session.stdio[0]?.readabilityHandler = nil
            try? session.vsockHandle?.close()
            #if arch(arm64)
            if let conn = session.vsockConnection as? VZVirtioSocketConnection {
                conn.close()
            }
            #endif
        }
        sessions.removeAll()
    }

    #if arch(arm64)
    private func startSession(_ session: inout Session, containerConfig: ContainerConfiguration) async throws {
        let agentPort = containerConfig.macosGuest?.agentPort ?? Self.fallbackAgentPort
        let vsockConnection = try await connectAgent(port: agentPort)
        let handle = FileHandle(fileDescriptor: vsockConnection.fileDescriptor, closeOnDealloc: false)
        session.vsockConnection = vsockConnection
        session.vsockHandle = handle

        let processID = session.processID
        sessions[processID] = session
        session.readTask = Task { [weak self] in
            await self?.readFramesLoop(processID: processID)
        }

        if let stdin = session.stdio[0] {
            let service = self
            stdin.readabilityHandler = { handle in
                let data = handle.availableData
                Task {
                    await service.forwardHostStdin(processID: processID, data: data)
                }
            }
        }

        let payload = GuestAgentFrame.exec(
            id: processID,
            executable: session.config.executable,
            arguments: session.config.arguments,
            environment: session.config.environment,
            workingDirectory: session.config.workingDirectory,
            terminal: session.config.terminal
        )
        try sendFrameNow(payload, session: session)
    }

    private func connectAgent(port: UInt32) async throws -> VZVirtioSocketConnection {
        guard let socketDevice else {
            throw ContainerizationError(.invalidState, message: "vm socket device not ready")
        }

        var lastError: Error?
        for _ in 0..<60 {
            do {
                return try await socketDevice.connect(toPort: port)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError ?? ContainerizationError(.timeout, message: "timed out waiting for guest agent on vsock port \(port)")
    }
    #endif

    private func forwardHostStdin(processID: String, data: Data) async {
        guard let session = sessions[processID], session.started else {
            return
        }

        do {
            if data.isEmpty {
                session.stdio[0]?.readabilityHandler = nil
                try sendFrameNow(.close(id: processID), session: session)
            } else {
                try sendFrameNow(.stdin(id: processID, data: data), session: session)
            }
        } catch {
            log.error("failed to forward stdin", metadata: ["process_id": "\(processID)", "error": "\(error)"])
        }

        sessions[processID] = session
    }

    private func sendFrame(to processID: String, frame: GuestAgentFrame) async throws {
        guard let session = sessions[processID] else {
            throw ContainerizationError(.notFound, message: "process \(processID) not found")
        }
        try sendFrameNow(frame, session: session)
        sessions[processID] = session
    }

    private func sendFrameNow(_ frame: GuestAgentFrame, session: Session) throws {
        guard let handle = session.vsockHandle else {
            throw ContainerizationError(.invalidState, message: "agent session for process \(session.processID) is not started")
        }

        let payload = try JSONEncoder().encode(frame)
        var length = UInt32(payload.count).bigEndian
        let lengthData = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try handle.write(contentsOf: lengthData)
        try handle.write(contentsOf: payload)
    }

    private func readFramesLoop(processID: String) async {
        while true {
            guard let handle = sessions[processID]?.vsockHandle else {
                break
            }
            do {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    break
                }
                try await processIncomingData(chunk, processID: processID)
            } catch {
                log.error("failed to read guest agent stream", metadata: ["process_id": "\(processID)", "error": "\(error)"])
                break
            }
        }

        let status = sessions[processID]?.exitStatus ?? ExitStatus(exitCode: 1, exitedAt: Date())
        completeProcess(id: processID, status: status)
    }

    private func processIncomingData(_ data: Data, processID: String) async throws {
        guard var session = sessions[processID] else {
            return
        }
        session.inputBuffer.append(data)

        while session.inputBuffer.count >= MemoryLayout<UInt32>.size {
            let lengthBytes = session.inputBuffer.prefix(MemoryLayout<UInt32>.size)
            let length = lengthBytes.withUnsafeBytes { raw in
                raw.load(as: UInt32.self).bigEndian
            }
            let frameSize = Int(length)
            let total = MemoryLayout<UInt32>.size + frameSize
            guard session.inputBuffer.count >= total else {
                break
            }

            let payload = session.inputBuffer.subdata(in: MemoryLayout<UInt32>.size..<total)
            session.inputBuffer.removeSubrange(0..<total)

            let frame = try JSONDecoder().decode(GuestAgentFrame.self, from: payload)
            try handleFrame(frame, processID: processID, session: &session)
        }

        sessions[processID] = session
    }

    private func handleFrame(_ frame: GuestAgentFrame, processID: String, session: inout Session) throws {
        switch frame.type {
        case .stdout:
            if let data = frame.data {
                if let stdout = session.stdio[1] {
                    try? stdout.write(contentsOf: data)
                }
                writeContainerLog(data)
            }
        case .stderr:
            if let data = frame.data {
                if let stderr = session.stdio[2] {
                    try? stderr.write(contentsOf: data)
                } else if let stdout = session.stdio[1] {
                    try? stdout.write(contentsOf: data)
                }
                writeContainerLog(data)
            }
        case .exit:
            let status = ExitStatus(exitCode: frame.exitCode ?? 1, exitedAt: Date())
            completeProcess(id: processID, status: status)
            if processID == configuration?.id {
                sandboxState = .stopped(status.exitCode)
            }
        case .error:
            let text = frame.message ?? "unknown guest agent error"
            writeContainerLog(Data(("guest-agent error: \(text)\n").utf8))
        case .ready:
            break
        case .exec, .stdin, .signal, .resize, .close:
            break
        }
    }
}

// MARK: - Protocol frame model

private struct GuestAgentFrame: Codable {
    enum FrameType: String, Codable {
        case exec
        case stdin
        case signal
        case resize
        case close
        case stdout
        case stderr
        case exit
        case error
        case ready
    }

    let type: FrameType
    let id: String?
    let executable: String?
    let arguments: [String]?
    let environment: [String]?
    let workingDirectory: String?
    let terminal: Bool?
    let signal: Int32?
    let width: UInt16?
    let height: UInt16?
    let data: Data?
    let exitCode: Int32?
    let message: String?

    static func exec(id: String, executable: String, arguments: [String], environment: [String], workingDirectory: String, terminal: Bool) -> Self {
        .init(
            type: .exec,
            id: id,
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            terminal: terminal,
            signal: nil,
            width: nil,
            height: nil,
            data: nil,
            exitCode: nil,
            message: nil
        )
    }

    static func stdin(id: String, data: Data) -> Self {
        .init(
            type: .stdin,
            id: id,
            executable: nil,
            arguments: nil,
            environment: nil,
            workingDirectory: nil,
            terminal: nil,
            signal: nil,
            width: nil,
            height: nil,
            data: data,
            exitCode: nil,
            message: nil
        )
    }

    static func signal(id: String, signal: Int32) -> Self {
        .init(
            type: .signal,
            id: id,
            executable: nil,
            arguments: nil,
            environment: nil,
            workingDirectory: nil,
            terminal: nil,
            signal: signal,
            width: nil,
            height: nil,
            data: nil,
            exitCode: nil,
            message: nil
        )
    }

    static func resize(id: String, width: UInt16, height: UInt16) -> Self {
        .init(
            type: .resize,
            id: id,
            executable: nil,
            arguments: nil,
            environment: nil,
            workingDirectory: nil,
            terminal: nil,
            signal: nil,
            width: width,
            height: height,
            data: nil,
            exitCode: nil,
            message: nil
        )
    }

    static func close(id: String) -> Self {
        .init(
            type: .close,
            id: id,
            executable: nil,
            arguments: nil,
            environment: nil,
            workingDirectory: nil,
            terminal: nil,
            signal: nil,
            width: nil,
            height: nil,
            data: nil,
            exitCode: nil,
            message: nil
        )
    }
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
