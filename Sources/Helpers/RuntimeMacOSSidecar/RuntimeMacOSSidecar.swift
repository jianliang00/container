import AppKit
import ArgumentParser
import ContainerLog
import ContainerResource
import ContainerVersion
import ContainerizationError
import Darwin
import Foundation
import Logging
import RuntimeMacOSSidecarShared
@preconcurrency import Virtualization

@MainActor
@main
struct RuntimeMacOSSidecar: @preconcurrency ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-runtime-macos-sidecar",
        abstract: "GUI-domain sidecar host for macOS guest VMs",
        version: ReleaseVersion.singleLine(appName: "container-runtime-macos-sidecar")
    )

    @Flag(name: .long, help: "Enable debug logging")
    var debug = false

    @Option(name: .shortAndLong, help: "Sandbox UUID")
    var uuid: String

    @Option(name: .shortAndLong, help: "Root directory for the sandbox")
    var root: String

    @Option(name: .long, help: "Unix socket path for control RPC")
    var controlSocket: String

    @MainActor
    mutating func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let log = Self.setupLogger(debug: debug, metadata: ["uuid": "\(uuid)"])

        log.info("starting sidecar", metadata: ["root": "\(root)", "control_socket": "\(controlSocket)"])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        log.info("host context", metadata: Self.hostContextMetadata())

        let service = MacOSSidecarService(rootURL: URL(fileURLWithPath: root), log: log)
        let server = SidecarControlServer(socketPath: controlSocket, service: service, log: log)
        DispatchQueue.main.async {
            do {
                try server.start()
                log.info("sidecar entering app run loop")
            } catch {
                log.error("failed to start control server", metadata: ["error": "\(error)"])
                NSApplication.shared.terminate(nil)
            }
        }
        app.run()
        server.stop()
        log.info("sidecar stopped")
    }

    static func setupLogger(debug: Bool, metadata: [String: Logging.Logger.Metadata.Value] = [:]) -> Logging.Logger {
        LoggingSystem.bootstrap { label in
            OSLogHandler(label: label, category: "RuntimeMacOSSidecar")
        }
        var log = Logging.Logger(label: "com.apple.container")
        if debug { log.logLevel = .debug }
        for (key, val) in metadata { log[metadataKey: key] = val }
        return log
    }

    @MainActor
    static func hostContextMetadata() -> Logger.Metadata {
        var metadata: Logger.Metadata = [:]
        metadata["pid"] = "\(getpid())"
        metadata["uid"] = "\(getuid())"
        metadata["stdin_tty"] = "\(isatty(STDIN_FILENO) == 1)"
        metadata["screens"] = "\(NSScreen.screens.count)"
        metadata["has_main_screen"] = "\(NSScreen.main != nil)"
        metadata["launch_label"] = "\(ProcessInfo.processInfo.environment["LAUNCH_JOB_LABEL"] ?? "-")"
        metadata["session"] = "\(currentSessionSummary())"
        return metadata
    }

    @MainActor
    static func currentSessionSummary() -> String {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return "unavailable"
        }
        let onConsole = dict["kCGSessionOnConsoleKey"].map { "\($0)" } ?? "nil"
        let loginDone = dict["kCGSessionLoginDoneKey"].map { "\($0)" } ?? "nil"
        let userName = dict["kCGSessionUserNameKey"].map { "\($0)" } ?? "nil"
        let userID = dict["kCGSessionUserIDKey"].map { "\($0)" } ?? "nil"
        return "onConsole=\(onConsole) loginDone=\(loginDone) user=\(userName) uid=\(userID)"
    }
}

private final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    private let log: Logging.Logger

    init(log: Logging.Logger) {
        self.log = log
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log.info("vm guest did stop")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        log.error("vm stopped with error", metadata: ["error": "\(error)"])
    }
}

struct SidecarGuestAgentFrame: Codable {
    enum FrameType: String, Codable {
        case exec
        case stdin
        case signal
        case resize
        case close
        case fsBegin
        case fsChunk
        case fsEnd
        case ack
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
    let user: String?
    let signal: Int32?
    let width: UInt16?
    let height: UInt16?
    let data: Data?
    let exitCode: Int32?
    let message: String?
    let op: MacOSSidecarFSOperation?
    let path: String?
    let mode: UInt32?
    let uid: UInt32?
    let gid: UInt32?
    let supplementalGroups: [UInt32]?
    let mtime: Int64?
    let linkTarget: String?
    let overwrite: Bool?
    let autoCommit: Bool?
    let offset: UInt64?
    let action: MacOSSidecarFSEndAction?
    let digest: String?

    init(
        type: FrameType,
        id: String? = nil,
        executable: String? = nil,
        arguments: [String]? = nil,
        environment: [String]? = nil,
        workingDirectory: String? = nil,
        terminal: Bool? = nil,
        user: String? = nil,
        signal: Int32? = nil,
        width: UInt16? = nil,
        height: UInt16? = nil,
        data: Data? = nil,
        exitCode: Int32? = nil,
        message: String? = nil,
        op: MacOSSidecarFSOperation? = nil,
        path: String? = nil,
        mode: UInt32? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        supplementalGroups: [UInt32]? = nil,
        mtime: Int64? = nil,
        linkTarget: String? = nil,
        overwrite: Bool? = nil,
        autoCommit: Bool? = nil,
        offset: UInt64? = nil,
        action: MacOSSidecarFSEndAction? = nil,
        digest: String? = nil
    ) {
        self.type = type
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.user = user
        self.signal = signal
        self.width = width
        self.height = height
        self.data = data
        self.exitCode = exitCode
        self.message = message
        self.op = op
        self.path = path
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.supplementalGroups = supplementalGroups
        self.mtime = mtime
        self.linkTarget = linkTarget
        self.overwrite = overwrite
        self.autoCommit = autoCommit
        self.offset = offset
        self.action = action
        self.digest = digest
    }

    static func exec(
        id: String,
        executable: String,
        arguments: [String],
        environment: [String]?,
        workingDirectory: String?,
        terminal: Bool,
        user: String?,
        uid: UInt32?,
        gid: UInt32?,
        supplementalGroups: [UInt32]?
    ) -> Self {
        .init(
            type: .exec,
            id: id,
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            terminal: terminal,
            user: user,
            signal: nil,
            width: nil,
            height: nil,
            data: nil,
            exitCode: nil,
            message: nil,
            uid: uid,
            gid: gid,
            supplementalGroups: supplementalGroups
        )
    }

    static func close(id: String) -> Self {
        .init(type: .close, id: id)
    }

    static func stdin(id: String, data: Data) -> Self {
        .init(type: .stdin, id: id, data: data)
    }

    static func fsBegin(_ payload: MacOSSidecarFSBeginRequestPayload) -> Self {
        .init(
            type: .fsBegin,
            id: payload.txID,
            data: payload.inlineData,
            op: payload.op,
            path: payload.path,
            mode: payload.mode,
            uid: payload.uid,
            gid: payload.gid,
            mtime: payload.mtime,
            linkTarget: payload.linkTarget,
            overwrite: payload.overwrite,
            autoCommit: payload.autoCommit,
            digest: payload.digest
        )
    }

    static func fsChunk(_ payload: MacOSSidecarFSChunkRequestPayload) -> Self {
        .init(type: .fsChunk, id: payload.txID, data: payload.data, offset: payload.offset)
    }

    static func fsEnd(_ payload: MacOSSidecarFSEndRequestPayload) -> Self {
        .init(type: .fsEnd, id: payload.txID, action: payload.action, digest: payload.digest)
    }

    static func ack(id: String) -> Self {
        .init(type: .ack, id: id)
    }
}

actor MacOSSidecarService {
    private static let bootstrapGuestAgentRetryDelayNanoseconds: UInt64 = 500_000_000
    private static let bootstrapGuestAgentMaxAttempts = 120
    private static let bootstrapGuestAgentReadyTimeoutSeconds: TimeInterval = 3

    private final class UnsafeSendableBox<T>: @unchecked Sendable {
        let value: T

        init(_ value: T) {
            self.value = value
        }
    }

    private final class BlockingResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func tryComplete() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if completed {
                return false
            }
            completed = true
            return true
        }
    }

    private final class CreatedVM: @unchecked Sendable {
        let vm: VZVirtualMachine
        let delegate: VMDelegate

        init(vm: VZVirtualMachine, delegate: VMDelegate) {
            self.vm = vm
            self.delegate = delegate
        }
    }

    private enum State: String {
        case created
        case running
        case stopped
    }

    private let rootURL: URL
    private let log: Logging.Logger

    private var vm: VZVirtualMachine?
    private var vmConfiguration: VZVirtualMachineConfiguration?
    private var vmDelegate: VMDelegate?
    private var vmWindow: UnsafeSendableBox<NSWindow>?
    private var vmWindowView: UnsafeSendableBox<VZVirtualMachineView>?
    private var state: State = .created

    init(rootURL: URL, log: Logging.Logger) {
        self.rootURL = rootURL
        self.log = log
    }

    func bootstrapStart() async throws {
        if state == .running, vm != nil {
            log.info("bootstrapStart skipped; vm already running")
            return
        }

        log.info("bootstrapStart: loading container config")
        let config = try loadContainerConfiguration()
        let guiEnabled = config.macosGuest?.guiEnabled ?? false
        log.info(
            "bootstrapStart: building vm configuration",
            metadata: [
                "cpus": "\(config.resources.cpus)",
                "memory": "\(config.resources.memoryInBytes)",
                "gui_enabled": "\(guiEnabled)",
            ])
        let vmConfiguration = try makeVirtualMachineConfiguration(containerConfig: config)
        self.vmConfiguration = vmConfiguration

        log.info("bootstrapStart: creating VZVirtualMachine")
        let created = try await createVirtualMachineOnMain(configuration: vmConfiguration)
        let vm = created.vm
        self.vmDelegate = created.delegate
        self.vm = vm
        if guiEnabled {
            try await presentGUIWindowOnMain(vm: vm, containerID: config.id)
        }
        log.info("bootstrapStart: starting vm", metadata: ["gui_enabled": "\(guiEnabled)"])
        let agentPort = config.macosGuest?.agentPort ?? 27000
        var didStartVM = false
        do {
            try await startVirtualMachine(vm)
            didStartVM = true
            try await validateSocketDeviceAvailable(on: vm)
            try await waitForGuestAgentDuringBootstrap(port: agentPort)
        } catch {
            if didStartVM {
                try? await stopVirtualMachine(vm)
            }
            await closeGUIWindowOnMain()
            self.vm = nil
            self.vmConfiguration = nil
            self.vmDelegate = nil
            self.state = .created
            throw error
        }
        state = .running
        log.info("vm started", metadata: ["state": "\(state.rawValue)", "agent_port": "\(agentPort)"])
    }

    func stopVM() async throws {
        guard let vm else {
            state = .stopped
            return
        }
        try await stopVirtualMachine(vm)
        await closeGUIWindowOnMain()
        self.vm = nil
        self.vmConfiguration = nil
        self.vmDelegate = nil
        state = .stopped
        log.info("vm stopped", metadata: ["state": "\(state.rawValue)"])
    }

    func connectVsock(port: UInt32) async throws -> Int32 {
        guard let vm else {
            throw ContainerizationError(.invalidState, message: "vm is not running")
        }
        log.info("sidecar connectVsock begin", metadata: ["port": "\(port)"])
        let connection = try await connectSocketOnMainWithTimeout(vm, toPort: port, timeoutSeconds: 3)
        let duplicated = dup(connection.fileDescriptor)
        guard duplicated >= 0 else {
            throw makePOSIXError(errno)
        }
        connection.close()
        return duplicated
    }

    private func waitForGuestAgentReadyWithTimeout(fd: Int32, timeoutSeconds: TimeInterval) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingResultBox<Void>()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.waitForGuestAgentReady(fd: fd)
                box.result = .success(())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        let deadline = DispatchTime.now() + timeoutSeconds
        if semaphore.wait(timeout: deadline) == .timedOut {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            throw ContainerizationError(.timeout, message: "timed out waiting for guest-agent ready frame")
        }
        switch box.result {
        case .success?:
            return
        case .failure(let error)?:
            throw error
        case nil:
            throw ContainerizationError(.internalError, message: "ready wait finished without result")
        }
    }

    private func waitForGuestAgentDuringBootstrap(port: UInt32) async throws {
        try await GuestAgentBootstrapRetrier.run(
            maxAttempts: Self.bootstrapGuestAgentMaxAttempts,
            retryDelayNanoseconds: Self.bootstrapGuestAgentRetryDelayNanoseconds
        ) { [self] attempt, maxAttempts in
            if shouldLogBootstrapGuestAgentAttempt(attempt, maxAttempts: maxAttempts) {
                log.info(
                    "bootstrap guest-agent probe attempt",
                    metadata: [
                        "attempt": "\(attempt)",
                        "max_attempts": "\(maxAttempts)",
                        "port": "\(port)",
                    ]
                )
            }

            let fd = try await connectVsock(port: port)
            defer {
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }

            do {
                try await self.waitForGuestAgentReadyWithTimeout(
                    fd: fd,
                    timeoutSeconds: Self.bootstrapGuestAgentReadyTimeoutSeconds
                )
                if shouldLogBootstrapGuestAgentAttempt(attempt, maxAttempts: maxAttempts) {
                    log.info(
                        "bootstrap guest-agent probe succeeded",
                        metadata: [
                            "attempt": "\(attempt)",
                            "max_attempts": "\(maxAttempts)",
                            "port": "\(port)",
                        ]
                    )
                }
            } catch {
                if shouldLogBootstrapGuestAgentAttempt(attempt, maxAttempts: maxAttempts) {
                    log.warning(
                        "bootstrap guest-agent probe failed",
                        metadata: [
                            "attempt": "\(attempt)",
                            "max_attempts": "\(maxAttempts)",
                            "port": "\(port)",
                            "error": "\(error)",
                        ]
                    )
                }
                throw error
            }
        }
    }

    func prepareForQuit() async {
        do {
            try await stopVM()
        } catch {
            log.error("failed to stop vm during quit", metadata: ["error": "\(error)"])
        }
    }

    private func configPath() -> URL { rootURL.appendingPathComponent("config.json") }
    private func diskImagePath() -> URL { rootURL.appendingPathComponent("Disk.img") }
    private func auxiliaryStoragePath() -> URL { rootURL.appendingPathComponent("AuxiliaryStorage") }
    private func hardwareModelPath() -> URL { rootURL.appendingPathComponent("HardwareModel.bin") }
    private func machineIdentifierPath() -> URL { rootURL.appendingPathComponent("MachineIdentifier.bin") }

    private func loadContainerConfiguration() throws -> ContainerConfiguration {
        let data = try Data(contentsOf: configPath())
        return try JSONDecoder().decode(ContainerConfiguration.self, from: data)
    }

    private func makeVirtualMachineConfiguration(containerConfig: ContainerConfiguration) throws -> VZVirtualMachineConfiguration {
        let hardwareData = try Data(contentsOf: hardwareModelPath())
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw ContainerizationError(.invalidState, message: "invalid hardware model data")
        }
        let machineIdentifier = try loadOrCreateMachineIdentifier(at: machineIdentifierPath())

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
        vmConfiguration.directorySharingDevices = try createDirectorySharingDevices(containerConfig: containerConfig)
        vmConfiguration.graphicsDevices = [createGraphicsDevice()]
        if containerConfig.macosGuest?.guiEnabled == true {
            vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
            vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
        try vmConfiguration.validate()
        return vmConfiguration
    }

    private func createNATDevice() -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return device
    }

    private func createDirectorySharingDevices(
        containerConfig: ContainerConfiguration
    ) throws -> [VZDirectorySharingDeviceConfiguration] {
        let shares = try MacOSGuestMountMapping.hostPathShares(from: containerConfig.mounts)
        guard !shares.isEmpty else {
            return []
        }

        let directories = Dictionary(uniqueKeysWithValues: shares.map { share in
            (
                share.name,
                VZSharedDirectory(
                    url: URL(fileURLWithPath: share.source),
                    readOnly: share.readOnly
                )
            )
        })

        let fileSystemDevice = VZVirtioFileSystemDeviceConfiguration(
            tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
        )
        fileSystemDevice.share = VZMultipleDirectoryShare(directories: directories)
        return [fileSystemDevice]
    }

    private func createGraphicsDevice() -> VZMacGraphicsDeviceConfiguration {
        let graphics = VZMacGraphicsDeviceConfiguration()
        let applyScreenBackedDisplay = {
            let screen = NSScreen.main ?? NSScreen.screens.first
            if let screen {
                graphics.displays = [
                    VZMacGraphicsDisplayConfiguration(
                        for: screen,
                        sizeInPoints: NSSize(width: 1440, height: 900)
                    )
                ]
            } else {
                graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1440, heightInPixels: 900, pixelsPerInch: 80)]
            }
        }
        if Thread.isMainThread {
            applyScreenBackedDisplay()
        } else {
            DispatchQueue.main.sync(execute: applyScreenBackedDisplay)
        }
        return graphics
    }

    private func presentGUIWindowOnMain(vm: VZVirtualMachine, containerID: String) async throws {
        let vmBox = UnsafeSendableBox(vm)
        let title = "Container macOS Guest (\(String(containerID.prefix(12))))"
        let created = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(UnsafeSendableBox<NSWindow>, UnsafeSendableBox<VZVirtualMachineView>), Error>) in
            DispatchQueue.main.async {
                let app = NSApplication.shared
                guard app.setActivationPolicy(.regular) else {
                    continuation.resume(
                        throwing: ContainerizationError(.internalError, message: "failed to enable GUI activation policy")
                    )
                    return
                }

                let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
                let window = NSWindow(
                    contentRect: frame,
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = title
                window.minSize = NSSize(width: 800, height: 500)
                window.center()

                let vmView = VZVirtualMachineView(frame: frame)
                vmView.virtualMachine = vmBox.value
                vmView.capturesSystemKeys = true
                vmView.autoresizingMask = [.width, .height]

                window.contentView = vmView
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                continuation.resume(returning: (UnsafeSendableBox(window), UnsafeSendableBox(vmView)))
            }
        }
        vmWindow = created.0
        vmWindowView = created.1
    }

    private func closeGUIWindowOnMain() async {
        let windowBox = vmWindow
        vmWindow = nil
        vmWindowView = nil
        guard let windowBox else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                windowBox.value.orderOut(nil)
                windowBox.value.contentView = nil
                windowBox.value.close()
                _ = NSApplication.shared.setActivationPolicy(.prohibited)
                continuation.resume()
            }
        }
    }

    private func loadOrCreateMachineIdentifier(at path: URL) throws -> VZMacMachineIdentifier {
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            if let value = VZMacMachineIdentifier(dataRepresentation: data) {
                return value
            }
        }
        let value = VZMacMachineIdentifier()
        try value.dataRepresentation.write(to: path)
        return value
    }

    private func startVirtualMachine(_ vm: VZVirtualMachine) async throws {
        // Virtualization callbacks must be invoked on the main queue. We wrap the VM reference
        // so the compiler knows we are intentionally transferring it to that queue.
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vmBox.value.start { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func createVirtualMachineOnMain(configuration: VZVirtualMachineConfiguration) async throws -> CreatedVM {
        let configurationBox = UnsafeSendableBox(configuration)
        let log = self.log
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CreatedVM, Error>) in
            DispatchQueue.main.async {
                log.info("creating vm on main thread")
                let vm = VZVirtualMachine(configuration: configurationBox.value)
                let delegate = VMDelegate(log: log)
                vm.delegate = delegate
                continuation.resume(returning: CreatedVM(vm: vm, delegate: delegate))
            }
        }
    }

    private func stopVirtualMachine(_ vm: VZVirtualMachine) async throws {
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vmBox.value.stop { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    private func connectSocketOnMainWithTimeout(
        _ vm: VZVirtualMachine,
        toPort port: UInt32,
        timeoutSeconds: TimeInterval
    ) async throws -> VZVirtioSocketConnection {
        let vmBox = UnsafeSendableBox(vm)
        let log = self.log
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VZVirtioSocketConnection, Error>) in
            let gate = CompletionGate()
            if timeoutSeconds > 0 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                    guard gate.tryComplete() else { return }
                    log.error("sidecar vsock connect callback timed out", metadata: ["port": "\(port)"])
                    continuation.resume(
                        throwing: ContainerizationError(
                            .timeout,
                            message: "timed out waiting for vsock connect callback on port \(port)"
                        )
                    )
                }
            }
            DispatchQueue.main.async {
                log.info("sidecar issuing vsock connect on main queue", metadata: ["port": "\(port)"])
                guard let socketDevice = vmBox.value.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
                    log.error("sidecar vsock connect missing socket device", metadata: ["port": "\(port)"])
                    guard gate.tryComplete() else { return }
                    continuation.resume(
                        throwing: ContainerizationError(.invalidState, message: "vm socket device unavailable on main thread")
                    )
                    return
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let connection):
                        log.info("sidecar vsock connect callback succeeded", metadata: ["port": "\(port)"])
                        guard gate.tryComplete() else {
                            connection.close()
                            return
                        }
                        nonisolated(unsafe) let unsafeConnection = connection
                        continuation.resume(returning: unsafeConnection)
                    case .failure(let error):
                        log.error("sidecar vsock connect callback failed", metadata: ["port": "\(port)", "error": "\(error)"])
                        guard gate.tryComplete() else { return }
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func validateSocketDeviceAvailable(on vm: VZVirtualMachine) async throws {
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let hasSocketDevice = vmBox.value.socketDevices.contains { $0 is VZVirtioSocketDevice }
                if hasSocketDevice {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ContainerizationError(.invalidState, message: "vm socket device is unavailable"))
                }
            }
        }
    }

    private nonisolated func waitForGuestAgentReady(fd: Int32) throws {
        while true {
            let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
            switch frame.type {
            case .ready:
                return
            case .error:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent error before ready: \(frame.message ?? "unknown error")"
                )
            case .exit:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent exited before ready (code=\(frame.exitCode ?? 1))"
                )
            case .stdout, .stderr, .ack, .exec, .stdin, .signal, .resize, .close, .fsBegin, .fsChunk, .fsEnd:
                continue
            }
        }
    }
}

final class SidecarControlServer: @unchecked Sendable {
    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private final class ProcessStreamSession: @unchecked Sendable {
        let processID: String
        let fd: Int32
        let writeLock = NSLock()
        let stateLock = NSLock()
        var closed = false

        init(processID: String, fd: Int32) {
            self.processID = processID
            self.fd = fd
        }
    }

    private final class FSTransferSession: @unchecked Sendable {
        let txID: String
        let fd: Int32
        let ownerClientFD: Int32
        let op: MacOSSidecarFSOperation
        let path: String
        let writeLock = NSLock()
        let stateLock = NSLock()
        var closed = false

        init(txID: String, fd: Int32, ownerClientFD: Int32, op: MacOSSidecarFSOperation, path: String) {
            self.txID = txID
            self.fd = fd
            self.ownerClientFD = ownerClientFD
            self.op = op
            self.path = path
        }
    }

    private let socketPath: String
    private let service: MacOSSidecarService
    private let log: Logging.Logger
    private let lock = NSLock()
    private let eventClientLock = NSLock()
    private let eventWriteLock = NSLock()
    private let processLock = NSLock()
    private let fsLock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = false
    private var eventClientFD: Int32 = -1
    private var processSessions: [String: ProcessStreamSession] = [:]
    private var fsSessions: [String: FSTransferSession] = [:]

    init(socketPath: String, service: MacOSSidecarService, log: Logging.Logger) {
        self.socketPath = socketPath
        self.service = service
        self.log = log
    }

    func start() throws {
        try cleanupStaleSocket()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw makePOSIXError(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxPathCount = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxPathCount else {
            Darwin.close(fd)
            throw makePOSIXLikeError(message: "unix socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            let error = makePOSIXError(errno)
            Darwin.close(fd)
            throw error
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let error = makePOSIXError(errno)
            Darwin.close(fd)
            throw error
        }
        _ = chmod(socketPath, mode_t(S_IRUSR | S_IWUSR))

        lock.lock()
        listenFD = fd
        stopping = false
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
        log.info("control socket listening", metadata: ["path": "\(socketPath)"])
    }

    func stop() {
        lock.lock()
        if stopping {
            lock.unlock()
            return
        }
        stopping = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        clearEventClient()
        closeAllProcessSessions()
        closeAllFSSessions()
        _ = unlink(socketPath)
    }

    private func cleanupStaleSocket() throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let isStopping = stopping
            lock.unlock()
            if isStopping || fd < 0 { return }

            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD >= 0 {
                Thread.detachNewThread { [weak self] in
                    self?.handleClient(fd: clientFD)
                }
                continue
            }
            let code = errno
            if code == EINTR { continue }
            lock.lock()
            let shouldExit = stopping
            lock.unlock()
            if shouldExit { return }
            log.error("accept failed", metadata: ["error": "\(String(cString: strerror(code)))", "code": "\(code)"])
            usleep(50_000)
        }
    }

    private func handleClient(fd clientFD: Int32) {
        defer {
            clearEventClientIfMatches(clientFD)
            closeOwnedFSSessions(clientFD: clientFD)
            Darwin.close(clientFD)
        }

        while true {
            var parsedRequest: MacOSSidecarRequest?
            do {
                let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: clientFD)
                guard envelope.kind == .request, let request = envelope.request else {
                    throw ContainerizationError(.invalidArgument, message: "control envelope must be a request")
                }
                parsedRequest = request
                if request.method != .vmConnectVsock {
                    setEventClient(fd: clientFD)
                }

                log.info("control request received", metadata: ["method": "\(request.method.rawValue)", "request_id": "\(request.requestID)"])
                let response = try perform(request: request, clientFD: clientFD)
                try writeEnvelope(.response(response), to: clientFD)
                log.info("control request completed", metadata: ["method": "\(request.method.rawValue)", "request_id": "\(request.requestID)", "ok": "\(response.ok)"])
            } catch {
                if parsedRequest == nil, isExpectedEOF(error) {
                    return
                }
                log.error("control request failed", metadata: ["error": "\(error)"])
                guard let request = parsedRequest else {
                    return
                }
                if request.method == .vmConnectVsock {
                    try? MacOSSidecarSocketIO.sendNoFileDescriptorMarker(socketFD: clientFD)
                }
                let response = failureResponse(requestID: request.requestID, error: error)
                try? writeEnvelope(.response(response), to: clientFD)
            }
        }
    }

    private func writeEnvelope(_ envelope: MacOSSidecarEnvelope, to fd: Int32) throws {
        eventWriteLock.lock()
        defer { eventWriteLock.unlock() }
        try MacOSSidecarSocketIO.writeJSONFrame(envelope, fd: fd)
    }

    private func emitEvent(_ event: MacOSSidecarEvent) {
        let clientFD: Int32
        eventClientLock.lock()
        clientFD = eventClientFD
        eventClientLock.unlock()

        guard clientFD >= 0 else {
            log.warning("dropping sidecar event without control client", metadata: ["event": "\(event.event.rawValue)", "process_id": "\(event.processID)"])
            return
        }

        do {
            try writeEnvelope(.event(event), to: clientFD)
        } catch {
            log.error(
                "failed to send sidecar event",
                metadata: [
                    "event": "\(event.event.rawValue)",
                    "process_id": "\(event.processID)",
                    "error": "\(error)",
                ])
        }
    }

    private func setEventClient(fd: Int32) {
        eventClientLock.lock()
        eventClientFD = fd
        eventClientLock.unlock()
    }

    private func clearEventClient() {
        eventClientLock.lock()
        eventClientFD = -1
        eventClientLock.unlock()
    }

    private func clearEventClientIfMatches(_ fd: Int32) {
        eventClientLock.lock()
        if eventClientFD == fd {
            eventClientFD = -1
        }
        eventClientLock.unlock()
    }

    private func isExpectedEOF(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "RuntimeMacOSSidecarShared" && nsError.localizedDescription.contains("unexpected EOF")
    }

    private func registerProcessSession(_ session: ProcessStreamSession) throws {
        processLock.lock()
        defer { processLock.unlock() }
        guard processSessions[session.processID] == nil else {
            throw ContainerizationError(.exists, message: "process \(session.processID) already exists in sidecar")
        }
        processSessions[session.processID] = session
    }

    private func processSession(for processID: String) throws -> ProcessStreamSession {
        processLock.lock()
        let session = processSessions[processID]
        processLock.unlock()
        guard let session else {
            throw ContainerizationError(.notFound, message: "process \(processID) not found in sidecar")
        }
        return session
    }

    private func removeProcessSession(_ processID: String) -> ProcessStreamSession? {
        processLock.lock()
        let removed = processSessions.removeValue(forKey: processID)
        processLock.unlock()
        return removed
    }

    private func closeAllProcessSessions() {
        let sessions: [ProcessStreamSession]
        processLock.lock()
        sessions = Array(processSessions.values)
        processSessions.removeAll()
        processLock.unlock()

        for session in sessions {
            closeProcessStreamSession(session)
        }
    }

    private func closeProcessStreamSession(_ session: ProcessStreamSession) {
        session.stateLock.lock()
        let shouldClose = !session.closed
        session.closed = true
        session.stateLock.unlock()
        guard shouldClose else { return }
        _ = Darwin.shutdown(session.fd, SHUT_RDWR)
        Darwin.close(session.fd)
    }

    private func registerFSSession(_ session: FSTransferSession) throws {
        fsLock.lock()
        defer { fsLock.unlock() }
        guard fsSessions[session.txID] == nil else {
            throw ContainerizationError(.exists, message: "filesystem transaction \(session.txID) already exists in sidecar")
        }
        fsSessions[session.txID] = session
    }

    private func fsSession(for txID: String) throws -> FSTransferSession {
        fsLock.lock()
        let session = fsSessions[txID]
        fsLock.unlock()
        guard let session else {
            throw ContainerizationError(.notFound, message: "filesystem transaction \(txID) not found in sidecar")
        }
        return session
    }

    private func removeFSSession(_ txID: String) -> FSTransferSession? {
        fsLock.lock()
        let removed = fsSessions.removeValue(forKey: txID)
        fsLock.unlock()
        return removed
    }

    private func closeOwnedFSSessions(clientFD: Int32) {
        let sessions: [FSTransferSession]
        fsLock.lock()
        let txIDs = fsSessions.values.filter { $0.ownerClientFD == clientFD }.map(\.txID)
        sessions = txIDs.compactMap { fsSessions.removeValue(forKey: $0) }
        fsLock.unlock()

        for session in sessions {
            closeFSSession(session, reason: "owner client disconnected")
        }
    }

    private func closeAllFSSessions() {
        let sessions: [FSTransferSession]
        fsLock.lock()
        sessions = Array(fsSessions.values)
        fsSessions.removeAll()
        fsLock.unlock()

        for session in sessions {
            closeFSSession(session, reason: "sidecar shutdown")
        }
    }

    private func closeFSSession(_ session: FSTransferSession, reason: String? = nil) {
        session.stateLock.lock()
        let shouldClose = !session.closed
        session.closed = true
        session.stateLock.unlock()
        guard shouldClose else { return }
        logFS("closing", session: session, extra: reason.map { ["reason": $0] } ?? [:])
        _ = Darwin.shutdown(session.fd, SHUT_RDWR)
        Darwin.close(session.fd)
    }

    func _testRegisterFSSession(
        txID: String,
        fd: Int32,
        ownerClientFD: Int32,
        op: MacOSSidecarFSOperation,
        path: String
    ) throws {
        try registerFSSession(
            FSTransferSession(
                txID: txID,
                fd: fd,
                ownerClientFD: ownerClientFD,
                op: op,
                path: path
            )
        )
    }

    func _testHasFSSession(txID: String) -> Bool {
        fsLock.lock()
        let exists = fsSessions[txID] != nil
        fsLock.unlock()
        return exists
    }

    func _testCloseOwnedFSSessions(clientFD: Int32) {
        closeOwnedFSSessions(clientFD: clientFD)
    }

    func _testCloseAllFSSessions() {
        closeAllFSSessions()
    }

    func _testSendFSChunk(_ payload: MacOSSidecarFSChunkRequestPayload) throws {
        try sendFSChunk(payload)
    }

    private func sendFrame(_ frame: SidecarGuestAgentFrame, to session: ProcessStreamSession) throws {
        session.writeLock.lock()
        defer { session.writeLock.unlock() }
        try MacOSSidecarSocketIO.writeJSONFrame(frame, fd: session.fd)
    }

    private func sendFrame(_ frame: SidecarGuestAgentFrame, to session: FSTransferSession) throws {
        session.writeLock.lock()
        defer { session.writeLock.unlock() }
        try MacOSSidecarSocketIO.writeJSONFrame(frame, fd: session.fd)
    }

    private func sendProcessControlFrame(processID: String, build: (ProcessStreamSession) -> SidecarGuestAgentFrame) throws {
        let session = try processSession(for: processID)
        try sendFrame(build(session), to: session)
    }

    private func startFSTransfer(port: UInt32, clientFD: Int32, payload: MacOSSidecarFSBeginRequestPayload) throws {
        logFS(
            "begin",
            txID: payload.txID,
            op: payload.op,
            path: payload.path,
            extra: [
                "port": "\(port)",
                "owner_client_fd": "\(clientFD)",
                "auto_commit": "\(payload.autoCommit)",
                "inline_bytes": "\(payload.inlineData?.count ?? 0)",
                "digest": payload.digest ?? "-",
            ]
        )
        let fd = try syncValue {
            try await self.service.connectVsock(port: port)
        }

        do {
            try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
            try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame.fsBegin(payload), fd: fd)
            try waitForFSAck(fd: fd, expectedID: payload.txID)

            if payload.autoCommit {
                logFS("auto-commit completed", txID: payload.txID, op: payload.op, path: payload.path)
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
                return
            }

            let session = FSTransferSession(
                txID: payload.txID,
                fd: fd,
                ownerClientFD: clientFD,
                op: payload.op,
                path: payload.path
            )
            try registerFSSession(session)
            logFS("session registered", session: session)
        } catch {
            logFS(
                "begin failed",
                txID: payload.txID,
                op: payload.op,
                path: payload.path,
                extra: ["error": "\(error)"]
            )
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            throw error
        }
    }

    private func sendFSChunk(_ payload: MacOSSidecarFSChunkRequestPayload) throws {
        let session = try fsSession(for: payload.txID)
        do {
            logFS(
                "chunk",
                session: session,
                extra: [
                    "offset": "\(payload.offset)",
                    "bytes": "\(payload.data.count)",
                ]
            )
            try sendFrame(.fsChunk(payload), to: session)
            try waitForFSAck(fd: session.fd, expectedID: payload.txID)
        } catch {
            logFS("chunk failed", session: session, extra: ["error": "\(error)"])
            closeFSSession(session, reason: "chunk failed")
            _ = removeFSSession(payload.txID)
            throw error
        }
    }

    private func finishFSTransfer(_ payload: MacOSSidecarFSEndRequestPayload) throws {
        let session = try fsSession(for: payload.txID)
        defer {
            closeFSSession(session, reason: "transfer finished")
            _ = removeFSSession(payload.txID)
        }
        logFS(
            "end",
            session: session,
            extra: [
                "action": payload.action.rawValue,
                "digest": payload.digest ?? "-",
            ]
        )
        try sendFrame(.fsEnd(payload), to: session)
        try waitForFSAck(fd: session.fd, expectedID: payload.txID)
    }

    private func startProcessStream(port: UInt32, processID: String, exec: MacOSSidecarExecRequestPayload) throws {
        let fd = try syncValue {
            try await self.service.connectVsock(port: port)
        }

        do {
            try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
            let env = exec.environment ?? ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
            let cwd = exec.workingDirectory ?? "/"
            try MacOSSidecarSocketIO.writeJSONFrame(
                SidecarGuestAgentFrame.exec(
                    id: processID,
                    executable: exec.executable,
                    arguments: exec.arguments,
                    environment: env,
                    workingDirectory: cwd,
                    terminal: exec.terminal,
                    user: exec.user,
                    uid: exec.uid,
                    gid: exec.gid,
                    supplementalGroups: exec.supplementalGroups
                ),
                fd: fd
            )
            let session = ProcessStreamSession(processID: processID, fd: fd)
            try registerProcessSession(session)
            startProcessReadLoop(session)
        } catch {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            throw error
        }
    }

    private func startProcessReadLoop(_ session: ProcessStreamSession) {
        Thread.detachNewThread { [weak self] in
            self?.processReadLoop(session)
        }
    }

    private func processReadLoop(_ session: ProcessStreamSession) {
        let processID = session.processID
        var exitEmitted = false
        var pendingExitCode: Int32?
        defer {
            closeProcessStreamSession(session)
            _ = removeProcessSession(processID)
            if !exitEmitted {
                emitEvent(.init(event: .processExit, processID: processID, exitCode: pendingExitCode ?? 1))
            }
        }

        do {
            while true {
                let frame: SidecarGuestAgentFrame
                if pendingExitCode == nil {
                    frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: session.fd)
                } else {
                    guard let drained = try readProcessFrameIfAvailable(fd: session.fd, timeoutMilliseconds: 100) else {
                        emitEvent(.init(event: .processExit, processID: processID, exitCode: pendingExitCode))
                        exitEmitted = true
                        return
                    }
                    frame = drained
                }
                switch frame.type {
                case .stdout:
                    if let data = frame.data, !data.isEmpty {
                        emitEvent(.init(event: .processStdout, processID: processID, data: data))
                    }
                case .stderr:
                    if let data = frame.data, !data.isEmpty {
                        emitEvent(.init(event: .processStderr, processID: processID, data: data))
                    }
                case .error:
                    emitEvent(.init(event: .processError, processID: processID, message: frame.message ?? "unknown guest-agent error"))
                case .exit:
                    pendingExitCode = frame.exitCode ?? 1
                case .ready:
                    continue
                case .ack, .exec, .stdin, .signal, .resize, .close, .fsBegin, .fsChunk, .fsEnd:
                    continue
                }
            }
        } catch {
            if let pendingExitCode, isExpectedEOF(error) {
                emitEvent(.init(event: .processExit, processID: processID, exitCode: pendingExitCode))
                exitEmitted = true
                return
            }
            if !isExpectedEOF(error) {
                emitEvent(.init(event: .processError, processID: processID, message: "sidecar process stream read failed: \(error.localizedDescription)"))
            }
        }
    }

    private func readProcessFrameIfAvailable(fd: Int32, timeoutMilliseconds: Int32) throws -> SidecarGuestAgentFrame? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let result = withUnsafeMutablePointer(to: &descriptor) { pointer in
                Darwin.poll(pointer, 1, timeoutMilliseconds)
            }

            if result == 0 {
                return nil
            }
            if result > 0 {
                if descriptor.revents & Int16(POLLIN) != 0 {
                    return try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
                }
                if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    return nil
                }
                continue
            }

            if errno == EINTR {
                continue
            }
            throw POSIXError.fromErrno()
        }
    }

    private func waitForFSAck(fd: Int32, expectedID: String) throws {
        while true {
            let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
            switch frame.type {
            case .ack:
                guard frame.id == expectedID else {
                    throw ContainerizationError(
                        .internalError,
                        message: "filesystem ack transaction ID mismatch (expected=\(expectedID) actual=\(frame.id ?? "nil"))"
                    )
                }
                return
            case .error:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent filesystem error for transaction \(expectedID): \(frame.message ?? "unknown error")"
                )
            case .exit:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent filesystem stream exited for transaction \(expectedID) (code=\(frame.exitCode ?? 1))"
                )
            case .ready, .stdout, .stderr:
                continue
            case .exec, .stdin, .signal, .resize, .close, .fsBegin, .fsChunk, .fsEnd:
                continue
            }
        }
    }

    private func logFS(
        _ message: String,
        txID: String,
        op: MacOSSidecarFSOperation,
        path: String,
        extra: [String: String] = [:]
    ) {
        var metadata: Logger.Metadata = [
            "tx_id": "\(txID)",
            "op": "\(op.rawValue)",
            "path": "\(path)",
        ]
        for (key, value) in extra {
            metadata[key] = "\(value)"
        }
        log.info("filesystem transfer \(message)", metadata: metadata)
    }

    private func logFS(_ message: String, session: FSTransferSession, extra: [String: String] = [:]) {
        logFS(message, txID: session.txID, op: session.op, path: session.path, extra: extra)
    }

    private func waitForGuestAgentReadyWithTimeout(fd: Int32, timeoutSeconds: TimeInterval) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Void>()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                while true {
                    let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
                    switch frame.type {
                    case .ready:
                        box.result = .success(())
                        semaphore.signal()
                        return
                    case .error:
                        throw ContainerizationError(.internalError, message: "guest-agent error before ready: \(frame.message ?? "unknown error")")
                    case .exit:
                        throw ContainerizationError(.internalError, message: "guest-agent exited before ready (code=\(frame.exitCode ?? 1))")
                    case .stdout, .stderr, .ack, .exec, .stdin, .signal, .resize, .close, .fsBegin, .fsChunk, .fsEnd:
                        continue
                    }
                }
            } catch {
                box.result = .failure(error)
                semaphore.signal()
            }
        }

        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            throw ContainerizationError(.timeout, message: "timed out waiting for guest-agent ready frame")
        }
        switch box.result {
        case .success?:
            return
        case .failure(let error)?:
            throw error
        case nil:
            throw ContainerizationError(.internalError, message: "guest-agent ready wait finished without result")
        }
    }

    private func failureResponse(requestID: String, error: Error) -> MacOSSidecarResponse {
        let normalized = normalizedError(error)
        return .failure(
            requestID: requestID,
            code: normalized.code.description,
            message: normalized.message,
            details: responseErrorDetails(for: normalized)
        )
    }

    private func normalizedError(_ error: Error) -> ContainerizationError {
        if let containerError = error as? ContainerizationError {
            return containerError
        }
        let nsError = error as NSError
        return ContainerizationError(.internalError, message: nsError.localizedDescription, cause: error)
    }

    private func responseErrorDetails(for error: ContainerizationError) -> String? {
        if let cause = error.cause {
            return String(describing: cause)
        }
        return nil
    }

    private func perform(request: MacOSSidecarRequest, clientFD: Int32) throws -> MacOSSidecarResponse {
        let service = self.service
        let requestID = request.requestID
        switch request.method {
        case .vmBootstrapStart:
            return try sync(requestID: requestID) {
                try await service.bootstrapStart()
                return .success(requestID: requestID)
            }
        case .vmConnectVsock:
            guard let port = request.port else {
                try MacOSSidecarSocketIO.sendNoFileDescriptorMarker(socketFD: clientFD)
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing port")
            }
            do {
                let fd = try syncValue {
                    try await service.connectVsock(port: port)
                }
                defer { Darwin.close(fd) }
                try MacOSSidecarSocketIO.sendFileDescriptorMarker(socketFD: clientFD, descriptorFD: fd)
                return .success(requestID: requestID, fdAttached: true)
            } catch {
                try MacOSSidecarSocketIO.sendNoFileDescriptorMarker(socketFD: clientFD)
                return failureResponse(requestID: requestID, error: error)
            }
        case .processStart:
            guard let exec = request.exec else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing exec payload")
            }
            guard let processID = request.processID, !processID.isEmpty else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            let port = request.port ?? 27000
            do {
                try startProcessStream(port: port, processID: processID, exec: exec)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processStdin:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            guard let data = request.data else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing data")
            }
            do {
                try sendProcessControlFrame(processID: processID) { _ in
                    SidecarGuestAgentFrame.stdin(id: processID, data: data)
                }
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processClose:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            do {
                try sendProcessControlFrame(processID: processID) { _ in SidecarGuestAgentFrame.close(id: processID) }
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processSignal:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            guard let signal = request.signal else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing signal")
            }
            do {
                try sendProcessControlFrame(processID: processID) { _ in
                    .init(
                        type: .signal,
                        id: processID,
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
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processResize:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            guard let width = request.width, let height = request.height else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing width/height")
            }
            do {
                try sendProcessControlFrame(processID: processID) { _ in
                    .init(
                        type: .resize,
                        id: processID,
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
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsBegin:
            guard let payload = request.fsBegin else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing filesystem begin payload")
            }
            let port = request.port ?? 27000
            do {
                try startFSTransfer(port: port, clientFD: clientFD, payload: payload)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsChunk:
            guard let payload = request.fsChunk else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing filesystem chunk payload")
            }
            do {
                try sendFSChunk(payload)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsEnd:
            guard let payload = request.fsEnd else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing filesystem end payload")
            }
            do {
                try finishFSTransfer(payload)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .vmStop:
            return try sync(requestID: requestID) {
                self.closeAllProcessSessions()
                self.closeAllFSSessions()
                try await service.stopVM()
                return .success(requestID: requestID)
            }
        case .sidecarQuit:
            let response: MacOSSidecarResponse = try sync(requestID: requestID) {
                self.closeAllProcessSessions()
                self.closeAllFSSessions()
                await service.prepareForQuit()
                return .success(requestID: requestID)
            }
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            return response
        }
    }

    private func sync(requestID: String, _ body: @Sendable @escaping () async throws -> MacOSSidecarResponse) throws -> MacOSSidecarResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<MacOSSidecarResponse>()
        Task { @Sendable in
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result! {
        case .success(let response):
            return response
        case .failure(let error):
            return failureResponse(requestID: requestID, error: error)
        }
    }

    private func syncValue<T>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task { @Sendable in
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result {
        case .success(let value)?:
            return value
        case .failure(let error)?:
            throw error
        case nil:
            throw ContainerizationError(.internalError, message: "sidecar syncValue finished without result")
        }
    }
}

package enum GuestAgentBootstrapRetrier {
    package static func run(
        maxAttempts: Int,
        retryDelayNanoseconds: UInt64,
        operation: @escaping @Sendable (_ attempt: Int, _ maxAttempts: Int) async throws -> Void
    ) async throws {
        let attempts = max(1, maxAttempts)
        var lastError: Error?

        for attempt in 1...attempts {
            do {
                try await operation(attempt, attempts)
                return
            } catch {
                lastError = error
                if attempt < attempts, retryDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                }
            }
        }

        throw lastError ?? ContainerizationError(
            .timeout,
            message: "guest-agent bootstrap probe finished without result"
        )
    }
}

private func shouldLogBootstrapGuestAgentAttempt(_ attempt: Int, maxAttempts: Int) -> Bool {
    if attempt <= 5 {
        return true
    }
    if attempt == maxAttempts {
        return true
    }
    return attempt % 10 == 0
}
