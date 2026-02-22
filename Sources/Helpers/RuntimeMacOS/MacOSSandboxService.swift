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
        var readyReceived: Bool = false
        var exitStatus: ExitStatus?
        var lastAgentError: String?
        var streamError: String?
        var readTask: Task<Void, Never>?
    }

    struct SidecarHandle {
        let launchLabel: String
        let plistURL: URL
        let socketURL: URL
        let stdoutLogURL: URL
        let stderrLogURL: URL
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

        // `startSession` can start the read loop and receive frames (including an immediate exit)
        // before we return here for short-lived commands. Merge with the latest dictionary state
        // instead of blindly overwriting it with the older local copy.
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
        writeContainerLog(Data(("stop requested signal=\(stopOptions.signal) timeout=\(stopOptions.timeoutInSeconds)\n").utf8))

        if let id = configuration?.id, let current = sessions[id], current.started {
            if current.exitStatus == nil {
                writeContainerLog(Data(("stop: init process \(id) still running; sending signal \(stopOptions.signal)\n").utf8))
                try? await sendFrame(to: id, frame: .signal(id: id, signal: Int32(stopOptions.signal)))
                _ = try? await waitForProcess(id, timeout: stopOptions.timeoutInSeconds)
                writeContainerLog(Data(("stop: wait for init process \(id) finished\n").utf8))
            } else {
                writeContainerLog(Data(("stop: init process \(id) already exited; skipping signal/wait\n").utf8))
            }
        }

        #if arch(arm64)
        if isSidecarEnabled {
            writeContainerLog(Data(("stop: sidecar shutdown start\n").utf8))
            await stopAndQuitSidecarIfPresent()
            writeContainerLog(Data(("stop: sidecar shutdown done\n").utf8))
        } else {
            if let configuration {
                try await saveSnapshotIfNeeded(configuration)
            }
            try await stopVirtualMachine()
        }
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
            if isSidecarEnabled {
                await stopAndQuitSidecarIfPresent()
            }
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
        let port = UInt32(message.uint64(key: SandboxKeys.port.rawValue))
        let fh: FileHandle
        if isSidecarEnabled {
            fh = try sidecarDial(port: port)
        } else {
            guard let socketDevice else {
                throw ContainerizationError(.invalidState, message: "vm socket device not available")
            }
            let connection = try await socketDevice.connect(toPort: port)
            let duplicated = dup(connection.fileDescriptor)
            guard duplicated >= 0 else {
                throw POSIXError.fromErrno()
            }
            fh = FileHandle(fileDescriptor: duplicated, closeOnDealloc: true)
        }
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
        if isSidecarEnabled {
            try await startVirtualMachineViaSidecar(config: config)
            return
        }

        await logHostDisplayContext(stage: "startOrRestoreVirtualMachine:entry")
        await prepareDisplayRuntimeIfNeeded(config: config)

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
                try await resumeVirtualMachine(vm)
                await presentGUIIfNeeded(config: config, vm: vm)
                try writeBootLog("restored vm state from snapshot")
                return
            } catch {
                try writeBootLog("failed to restore snapshot, falling back to cold boot: \(error)")
            }
        }

        do {
            try await startVirtualMachine(vm)
        } catch {
            try writeBootLog("failed to start vm: \(error)")
            throw ContainerizationError(.internalError, message: "failed to start macOS virtual machine", cause: error)
        }
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
        // Keep a virtual display even for non-GUI macOS guests. On current templates,
        // a pure headless (no graphics device) boot path can leave the guest-agent
        // listener resetting vsock connections instead of accepting them.
        vmConfiguration.graphicsDevices = [createGraphicsDevice()]

        if containerConfig.macosGuest?.guiEnabled == true {
            if !Self.isAquaSession() {
                throw ContainerizationError(
                    .unsupported,
                    message: "--gui requires an Aqua login session. Run from a user login session instead of background launch contexts."
                )
            }
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

    private func prepareDisplayRuntimeIfNeeded(config: ContainerConfiguration) async {
        guard config.macosGuest?.guiEnabled != true else {
            return
        }

        await logHostDisplayContext(stage: "prepareDisplayRuntimeIfNeeded:before-mainactor")

        // "Headless display" mode: keep a virtual display device attached for the guest,
        // but do not create any local VM window.
        let runtimeSummary = await MainActor.run { () -> String in
            let hadNSApp = NSApp != nil
            let app = NSApplication.shared
            let beforePolicy = app.activationPolicy()
            app.setActivationPolicy(.prohibited)
            let afterPolicy = app.activationPolicy()
            let screens = NSScreen.screens
            let hasMainScreen = NSScreen.main != nil
            return
                "hadNSApp=\(hadNSApp) policyBefore=\(Self.describeActivationPolicy(beforePolicy)) policyAfter=\(Self.describeActivationPolicy(afterPolicy)) screens=\(screens.count) hasMainScreen=\(hasMainScreen)"
        }

        let line = "host display runtime prepared [mode=headless-display] \(runtimeSummary)\n"
        writeContainerLog(Data(line.utf8))
        log.info("host display runtime prepared", metadata: ["summary": "\(runtimeSummary)"])
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

    private func logHostDisplayContext(stage: String) async {
        let env = ProcessInfo.processInfo.environment
        let launchLabel = env["LAUNCH_JOB_LABEL"] ?? "-"
        let xpcServiceName = env["XPC_SERVICE_NAME"] ?? "-"
        let xpcServiceBundleID = env["XPC_SERVICE_BUNDLE_IDENTIFIER"] ?? "-"
        let aqua = Self.isAquaSession()
        let sessionSummary: String = {
            guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
                return "unavailable"
            }

            let onConsole = dict["kCGSessionOnConsoleKey"].map { "\($0)" } ?? "nil"
            let loginDone = dict["kCGSessionLoginDoneKey"].map { "\($0)" } ?? "nil"
            let userName = dict["kCGSessionUserNameKey"].map { "\($0)" } ?? "nil"
            let userID = dict["kCGSessionUserIDKey"].map { "\($0)" } ?? "nil"
            return "onConsole=\(onConsole) loginDone=\(loginDone) user=\(userName) uid=\(userID)"
        }()

        let line =
            "host display context [stage=\(stage)] pid=\(getpid()) ppid=\(getppid()) uid=\(getuid()) euid=\(geteuid()) stdinTTY=\(isatty(STDIN_FILENO) == 1) aqua=\(aqua) launchLabel=\(launchLabel) xpcService=\(xpcServiceName) xpcBundle=\(xpcServiceBundleID) session={\(sessionSummary)}\n"
        writeContainerLog(Data(line.utf8))
        log.info(
            "host display context",
            metadata: [
                "stage": "\(stage)",
                "aqua": "\(aqua)",
                "launchLabel": "\(launchLabel)",
                "xpcService": "\(xpcServiceName)",
                "session": "\(sessionSummary)"
            ]
        )
    }

    private static func describeActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular:
            return "regular"
        case .accessory:
            return "accessory"
        case .prohibited:
            return "prohibited"
        @unknown default:
            return "unknown(\(policy.rawValue))"
        }
    }

    private func startVirtualMachine(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vm.start(completionHandler: { result in
                    continuation.resume(with: result)
                })
            }
        }
    }

    private func resumeVirtualMachine(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vm.resume(completionHandler: { result in
                    continuation.resume(with: result)
                })
            }
        }
    }

    @available(macOS 14.0, *)
    private func restoreMachineState(_ vm: VZVirtualMachine, from url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vm.restoreMachineStateFrom(url: url) { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: ())
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private func saveMachineState(_ vm: VZVirtualMachine, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vm.saveMachineStateTo(url: url) { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func stopVirtualMachine() async throws {
        guard let vm else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vm.stop(completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: ())
                })
            }
        }
    }

    private func pauseVirtualMachineIfSupported(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                guard vm.canPause else {
                    continuation.resume(returning: ())
                    return
                }
                vm.pause(completionHandler: { result in
                    continuation.resume(with: result)
                })
            }
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

        try await pauseVirtualMachineIfSupported(vm)
        try await saveMachineState(vm, to: snapshotPath())
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
        let processID = session.processID
        writeContainerLog(Data(("guest-agent connect begin for \(processID) on vsock port \(agentPort)\n").utf8))
        let handle: FileHandle
        if isSidecarEnabled {
            do {
                let fd = try await connectAgentFileDescriptorViaSidecar(port: agentPort, processID: processID)
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            } catch {
                let detail = describeError(error)
                writeContainerLog(Data(("guest-agent connect failed via sidecar on vsock port \(agentPort): \(detail)\n").utf8))
                throw ContainerizationError(
                    .internalError,
                    message: """
                    failed to connect to guest agent on vsock port \(agentPort) via sidecar: \(detail)
                    check guest log: /var/log/container-macos-guest-agent.log
                    """
                )
            }
            writeContainerLog(Data(("guest-agent connect callback succeeded via sidecar for \(processID) on vsock port \(agentPort)\n").utf8))
            session.vsockConnection = nil
        } else {
            let vsockConnection: VZVirtioSocketConnection
            do {
                vsockConnection = try await connectAgent(port: agentPort, processID: processID)
            } catch {
                let detail = describeError(error)
                writeContainerLog(Data(("guest-agent connect failed on vsock port \(agentPort): \(detail)\n").utf8))
                throw ContainerizationError(
                    .internalError,
                    message: """
                    failed to connect to guest agent on vsock port \(agentPort): \(detail)
                    check guest log: /var/log/container-macos-guest-agent.log
                    """
                )
            }
            writeContainerLog(Data(("guest-agent connect callback succeeded for \(processID) on vsock port \(agentPort)\n").utf8))
            handle = FileHandle(fileDescriptor: vsockConnection.fileDescriptor, closeOnDealloc: false)
            session.vsockConnection = vsockConnection
        }
        session.vsockHandle = handle

        sessions[processID] = session
        session.readTask = Task { [weak self] in
            await self?.readFramesLoop(processID: processID)
        }
        sessions[processID] = session
        writeContainerLog(Data(("guest-agent read loop started for \(processID)\n").utf8))

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
        do {
            writeContainerLog(Data(("guest-agent sending exec frame for \(processID)\n").utf8))
            try sendFrameNow(payload, session: session)
        } catch {
            let detail = describeError(error)
            writeContainerLog(Data(("guest-agent send error for \(processID): \(detail)\n").utf8))
            throw ContainerizationError(
                .internalError,
                message: """
                failed to send exec request to guest agent: \(detail)
                check guest log: /var/log/container-macos-guest-agent.log
                """
            )
        }
    }

    private func connectAgent(port: UInt32, processID: String) async throws -> VZVirtioSocketConnection {
        guard let socketDevice else {
            throw ContainerizationError(.invalidState, message: "vm socket device not ready")
        }

        var lastError: Error?
        let maxAttempts = 240
        // macOS guest boot + launchd can take noticeably longer than VM start()
        // completion, especially on first boot from a freshly packaged template.
        for attempt in 1...maxAttempts {
            do {
                if shouldLogConnectAttempt(attempt, maxAttempts: maxAttempts) {
                    writeContainerLog(Data(("guest-agent connect attempt \(attempt)/\(maxAttempts) for \(processID) on vsock port \(port)\n").utf8))
                }
                return try await connectSocketOnMain(socketDevice, toPort: port)
            } catch {
                lastError = error
                if shouldLogConnectAttempt(attempt, maxAttempts: maxAttempts) {
                    let detail = describeError(error)
                    writeContainerLog(Data(("guest-agent connect attempt \(attempt)/\(maxAttempts) failed for \(processID): \(detail)\n").utf8))
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError ?? ContainerizationError(.timeout, message: "timed out waiting for guest agent on vsock port \(port)")
    }

    private func connectSocketOnMain(_ socketDevice: VZVirtioSocketDevice, toPort port: UInt32) async throws -> VZVirtioSocketConnection {
        let logger = self.log
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VZVirtioSocketConnection, Error>) in
            DispatchQueue.main.async {
                socketDevice.connect(toPort: port, completionHandler: { result in
                    switch result {
                    case .success(let connection):
                        logger.info("guest-agent vsock connect callback succeeded", metadata: ["port": "\(port)"])
                        nonisolated(unsafe) let unsafeConnection = connection
                        continuation.resume(returning: unsafeConnection)
                    case .failure(let error):
                        logger.error("guest-agent vsock connect callback failed", metadata: ["port": "\(port)", "error": "\(error)"])
                        continuation.resume(throwing: error)
                    }
                })
            }
        }
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
    }

    private func sendFrame(to processID: String, frame: GuestAgentFrame) async throws {
        guard let session = sessions[processID] else {
            throw ContainerizationError(.notFound, message: "process \(processID) not found")
        }
        try sendFrameNow(frame, session: session)
    }

    private func sendFrameNow(_ frame: GuestAgentFrame, session: Session) throws {
        guard let handle = session.vsockHandle else {
            throw ContainerizationError(.invalidState, message: "agent session for process \(session.processID) is not started")
        }
        let fd = handle.fileDescriptor

        let payload = try JSONEncoder().encode(frame)
        var length = UInt32(payload.count).bigEndian
        let lengthData = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try writeAllToSocket(fd: fd, data: lengthData)
        try writeAllToSocket(fd: fd, data: payload)
    }

    private func readFramesLoop(processID: String) async {
        var chunkBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard let fd = sessions[processID]?.vsockHandle?.fileDescriptor else {
                break
            }
            do {
                guard let chunk = try readSocketChunk(fd: fd, into: &chunkBuffer), !chunk.isEmpty else {
                    if var session = sessions[processID], session.exitStatus == nil {
                        let detail = "guest agent disconnected unexpectedly"
                        if session.streamError == nil {
                            session.streamError = detail
                        }
                        sessions[processID] = session
                        writeContainerLog(Data(("guest-agent stream closed for \(processID): \(detail)\n").utf8))
                    }
                    break
                }
                try await processIncomingData(chunk, processID: processID)
            } catch {
                let detail = describeError(error)
                log.error("failed to read guest agent stream", metadata: ["process_id": "\(processID)", "error": "\(detail)"])
                if var session = sessions[processID], session.streamError == nil {
                    session.streamError = detail
                    sessions[processID] = session
                }
                writeContainerLog(Data(("guest-agent stream read failed for \(processID): \(detail)\n").utf8))
                break
            }
        }

        if
            let session = sessions[processID],
            session.exitStatus == nil,
            let detail = session.lastAgentError ?? session.streamError
        {
            writeContainerLog(Data(("guest-agent failure for \(processID): \(detail)\n").utf8))
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
            writeContainerLog(Data(("guest-agent exit frame for \(processID) code=\(frame.exitCode ?? 1)\n").utf8))
            let status = ExitStatus(exitCode: frame.exitCode ?? 1, exitedAt: Date())
            // `processIncomingData` writes the local session copy back after frame handling.
            // Persist the exit status on the local copy first so we do not clobber the
            // dictionary update performed by `completeProcess` when no waiter is attached yet.
            session.exitStatus = status
            // For short-lived commands, upper layers may be blocked waiting for stdio EOF rather
            // than issuing an explicit wait request. Close the per-process streams as soon as the
            // agent reports exit so the caller can finish promptly.
            session.stdio[0]?.readabilityHandler = nil
            try? session.vsockHandle?.close()
            session.vsockHandle = nil
            #if arch(arm64)
            if let conn = session.vsockConnection as? VZVirtioSocketConnection {
                conn.close()
            }
            #endif
            session.vsockConnection = nil
            try? session.stdio[1]?.close()
            try? session.stdio[2]?.close()
            completeProcess(id: processID, status: status)
            if processID == configuration?.id {
                sandboxState = .stopped(status.exitCode)
            }
        case .error:
            let text = frame.message ?? "unknown guest agent error"
            session.lastAgentError = text
            writeContainerLog(Data(("guest-agent error frame for \(processID): \(text)\n").utf8))
        case .ready:
            session.readyReceived = true
            writeContainerLog(Data(("guest-agent ready frame received for \(processID)\n").utf8))
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

private func readSocketChunk(fd: Int32, into storage: inout [UInt8]) throws -> Data? {
    while true {
        let bytesRead = storage.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return Darwin.read(fd, baseAddress, rawBuffer.count)
        }

        if bytesRead > 0 {
            return Data(storage.prefix(bytesRead))
        }
        if bytesRead == 0 {
            return nil
        }

        let code = errno
        if code == EINTR {
            continue
        }
        if code == EAGAIN || code == EWOULDBLOCK {
            usleep(10_000)
            continue
        }

        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        )
    }
}

private func writeAllToSocket(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var totalWritten = 0
        while totalWritten < rawBuffer.count {
            let pointer = baseAddress.advanced(by: totalWritten)
            let remaining = rawBuffer.count - totalWritten
            let written = Darwin.write(fd, pointer, remaining)
            if written > 0 {
                totalWritten += written
                continue
            }
            if written == 0 {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EPIPE),
                    userInfo: [NSLocalizedDescriptionKey: "write returned 0 bytes"]
                )
            }

            let code = errno
            if code == EINTR {
                continue
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                usleep(10_000)
                continue
            }

            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
    }
}

private func describeError(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain) Code=\(nsError.code) \"\(nsError.localizedDescription)\""
}

private func shouldLogConnectAttempt(_ attempt: Int, maxAttempts: Int) -> Bool {
    if attempt <= 5 {
        return true
    }
    if attempt == maxAttempts {
        return true
    }
    return attempt % 20 == 0
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
