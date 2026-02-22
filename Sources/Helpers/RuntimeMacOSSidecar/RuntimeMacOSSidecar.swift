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

private struct SidecarGuestAgentFrame: Codable {
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

    static func exec(
        id: String,
        executable: String,
        arguments: [String],
        environment: [String]?,
        workingDirectory: String?,
        terminal: Bool
    ) -> Self {
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
}

actor MacOSSidecarService {
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
        log.info("bootstrapStart: building vm configuration", metadata: [
            "cpus": "\(config.resources.cpus)",
            "memory": "\(config.resources.memoryInBytes)",
        ])
        let vmConfiguration = try makeVirtualMachineConfiguration(containerConfig: config)
        self.vmConfiguration = vmConfiguration

        log.info("bootstrapStart: creating VZVirtualMachine")
        let created = try await createVirtualMachineOnMain(configuration: vmConfiguration)
        let vm = created.vm
        self.vmDelegate = created.delegate
        self.vm = vm
        log.info("bootstrapStart: starting vm")
        try await startVirtualMachine(vm)
        try await validateSocketDeviceAvailable(on: vm)
        state = .running
        log.info("vm started", metadata: ["state": "\(state.rawValue)"])
    }

    func stopVM() async throws {
        guard let vm else {
            state = .stopped
            return
        }
        try await stopVirtualMachine(vm)
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
        vmConfiguration.graphicsDevices = [createGraphicsDevice()]
        try vmConfiguration.validate()
        return vmConfiguration
    }

    private func createNATDevice() -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return device
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
        nonisolated(unsafe) let unsafeVM = vm
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                unsafeVM.start { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func createVirtualMachineOnMain(configuration: VZVirtualMachineConfiguration) async throws -> CreatedVM {
        nonisolated(unsafe) let unsafeConfiguration = configuration
        let log = self.log
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CreatedVM, Error>) in
            DispatchQueue.main.async {
                log.info("creating vm on main thread")
                let vm = VZVirtualMachine(configuration: unsafeConfiguration)
                let delegate = VMDelegate(log: log)
                vm.delegate = delegate
                continuation.resume(returning: CreatedVM(vm: vm, delegate: delegate))
            }
        }
    }

    private func stopVirtualMachine(_ vm: VZVirtualMachine) async throws {
        nonisolated(unsafe) let unsafeVM = vm
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                unsafeVM.stop { error in
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
        nonisolated(unsafe) let unsafeVM = vm
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
                guard let socketDevice = unsafeVM.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
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
        nonisolated(unsafe) let unsafeVM = vm
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let hasSocketDevice = unsafeVM.socketDevices.contains { $0 is VZVirtioSocketDevice }
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
            case .stdout, .stderr, .exec, .stdin, .signal, .resize, .close:
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

    private let socketPath: String
    private let service: MacOSSidecarService
    private let log: Logging.Logger
    private let lock = NSLock()
    private let eventClientLock = NSLock()
    private let eventWriteLock = NSLock()
    private let processLock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = false
    private var eventClientFD: Int32 = -1
    private var processSessions: [String: ProcessStreamSession] = [:]

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
                let response = MacOSSidecarResponse.failure(requestID: request.requestID, code: "request_failed", message: error.localizedDescription)
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
            log.error("failed to send sidecar event", metadata: [
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

    private func sendFrame(_ frame: SidecarGuestAgentFrame, to session: ProcessStreamSession) throws {
        session.writeLock.lock()
        defer { session.writeLock.unlock() }
        try MacOSSidecarSocketIO.writeJSONFrame(frame, fd: session.fd)
    }

    private func sendProcessControlFrame(processID: String, build: (ProcessStreamSession) -> SidecarGuestAgentFrame) throws {
        let session = try processSession(for: processID)
        try sendFrame(build(session), to: session)
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
                    terminal: exec.terminal
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
        defer {
            closeProcessStreamSession(session)
            _ = removeProcessSession(processID)
            if !exitEmitted {
                emitEvent(.init(event: .processExit, processID: processID, exitCode: 1))
            }
        }

        do {
            while true {
                let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: session.fd)
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
                    emitEvent(.init(event: .processExit, processID: processID, exitCode: frame.exitCode ?? 1))
                    exitEmitted = true
                    return
                case .ready:
                    continue
                case .exec, .stdin, .signal, .resize, .close:
                    continue
                }
            }
        } catch {
            if !isExpectedEOF(error) {
                emitEvent(.init(event: .processError, processID: processID, message: "sidecar process stream read failed: \(error.localizedDescription)"))
            }
        }
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
                    case .stdout, .stderr, .exec, .stdin, .signal, .resize, .close:
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
                return .failure(requestID: requestID, code: "invalid_request", message: "missing port")
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
                let nsError = error as NSError
                return .failure(requestID: requestID, code: "sidecar_error", message: nsError.localizedDescription, details: "\(nsError.domain) Code=\(nsError.code)")
            }
        case .processStart:
            guard let exec = request.exec else {
                return .failure(requestID: requestID, code: "invalid_request", message: "missing exec payload")
            }
            guard let processID = request.processID, !processID.isEmpty else {
                return .failure(requestID: requestID, code: "invalid_request", message: "missing processID")
            }
            let port = request.port ?? 27000
            do {
                try startProcessStream(port: port, processID: processID, exec: exec)
                return .success(requestID: requestID)
            } catch {
                let nsError = error as NSError
                return .failure(requestID: requestID, code: "sidecar_error", message: nsError.localizedDescription, details: "\(nsError.domain) Code=\(nsError.code)")
            }
        case .processStdin:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalid_request", message: "missing processID")
            }
            guard let data = request.data else {
                return .failure(requestID: requestID, code: "invalid_request", message: "missing data")
            }
            do {
                try sendProcessControlFrame(processID: processID) { _ in
                    SidecarGuestAgentFrame.stdin(id: processID, data: data)
                }
                return .success(requestID: requestID)
            } catch {
                let nsError = error as NSError
                return .failure(requestID: requestID, code: "sidecar_error", message: nsError.localizedDescription, details: "\(nsError.domain) Code=\(nsError.code)")
            }
        case .processClose:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalid_request", message: "missing processID")
            }
            do {
                try sendProcessControlFrame(processID: processID) { _ in SidecarGuestAgentFrame.close(id: processID) }
                return .success(requestID: requestID)
            } catch {
                let nsError = error as NSError
                return .failure(requestID: requestID, code: "sidecar_error", message: nsError.localizedDescription, details: "\(nsError.domain) Code=\(nsError.code)")
            }
        case .processSignal:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalid_request", message: "missing processID")
            }
            guard let signal = request.signal else {
                return .failure(requestID: requestID, code: "invalid_request", message: "missing signal")
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
                let nsError = error as NSError
                return .failure(requestID: requestID, code: "sidecar_error", message: nsError.localizedDescription, details: "\(nsError.domain) Code=\(nsError.code)")
            }
        case .processResize:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalid_request", message: "missing processID")
            }
            guard let width = request.width, let height = request.height else {
                return .failure(requestID: requestID, code: "invalid_request", message: "missing width/height")
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
                let nsError = error as NSError
                return .failure(requestID: requestID, code: "sidecar_error", message: nsError.localizedDescription, details: "\(nsError.domain) Code=\(nsError.code)")
            }
        case .vmStop:
            return try sync(requestID: requestID) {
                self.closeAllProcessSessions()
                try await service.stopVM()
                return .success(requestID: requestID)
            }
        case .sidecarQuit:
            let response: MacOSSidecarResponse = try sync(requestID: requestID) {
                self.closeAllProcessSessions()
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
            let nsError = error as NSError
            return .failure(requestID: requestID, code: "sidecar_error", message: nsError.localizedDescription, details: "\(nsError.domain) Code=\(nsError.code)")
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
