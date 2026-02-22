#!/usr/bin/swift

// Minimal manual launcher for a macOS template VM with GUI + virtiofs.
//
// Build + run:
//   xcrun swiftc scripts/macos-guest-agent/manual-template-vm.swift \
//     -framework AppKit -framework Virtualization \
//     -o /tmp/manual-template-vm
//   /tmp/manual-template-vm \
//     --template /path/to/template-dir \
//     --share /tmp/macos-agent-seed \
//     --share-tag seed

import AppKit
import Darwin
import Foundation
import Virtualization

struct Options {
    let templateURL: URL
    let sharedDirectoryURL: URL
    let shareTag: String
    let cpus: Int
    let memoryMiB: UInt64
    let agentREPL: Bool
    let agentPort: UInt32
    let agentConnectRetries: Int
}

enum ArgumentError: Error, CustomStringConvertible {
    case missingValue(flag: String)
    case unknownFlag(String)
    case invalidNumber(flag: String, value: String)
    case required(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .unknownFlag(let flag):
            return "unknown flag: \(flag)"
        case .invalidNumber(let flag, let value):
            return "invalid numeric value for \(flag): \(value)"
        case .required(let message):
            return message
        }
    }
}

func printUsage() {
    let usage = """
    Usage:
      manual-template-vm.swift --template <path> --share <path> [options]

    Required:
      --template <path>     Template directory containing Disk.img/AuxiliaryStorage/HardwareModel.bin
      --share <path>        Host directory to mount into guest using virtiofs

    Optional:
      --share-tag <name>    virtiofs tag visible in guest (default: seed)
      --cpus <n>            Requested vCPU count (default: 4)
      --memory-mib <n>      Requested memory in MiB (default: 8192)
      --agent-repl          Enable interactive guest-agent debugger over vsock
      --agent-port <n>      Guest-agent vsock port (default: 27000)
      --agent-connect-retries <n>
                            Number of connect retries after VM start (default: 60)
      -h, --help            Show this help

    In guest, mount the shared directory with:
      sudo mkdir -p /Volumes/<tag>
      sudo mount -t virtiofs <tag> /Volumes/<tag>

    With --agent-repl enabled:
      connect
      connect-wait
      sh /bin/ls /
      exec /usr/bin/id
      exec-tty /bin/sh
      stdin echo hello
      close
      signal 15
      resize 120 40
      quit
    """
    print(usage)
}

func parseOptions() throws -> Options {
    var templatePath: String?
    var sharePath: String?
    var shareTag = "seed"
    var cpus = 4
    var memoryMiB: UInt64 = 8192
    var agentREPL = false
    var agentPort: UInt32 = 27000
    var agentConnectRetries = 60

    var index = 1
    let args = CommandLine.arguments

    while index < args.count {
        let flag = args[index]
        switch flag {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "--template":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            templatePath = args[index]
        case "--share":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            sharePath = args[index]
        case "--share-tag":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            shareTag = args[index]
        case "--cpus":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            guard let value = Int(args[index]), value > 0 else {
                throw ArgumentError.invalidNumber(flag: flag, value: args[index])
            }
            cpus = value
        case "--memory-mib":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            guard let value = UInt64(args[index]), value > 0 else {
                throw ArgumentError.invalidNumber(flag: flag, value: args[index])
            }
            memoryMiB = value
        case "--agent-repl":
            agentREPL = true
        case "--agent-port":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            guard let value = UInt32(args[index]), value > 0 else {
                throw ArgumentError.invalidNumber(flag: flag, value: args[index])
            }
            agentPort = value
        case "--agent-connect-retries":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            guard let value = Int(args[index]), value > 0 else {
                throw ArgumentError.invalidNumber(flag: flag, value: args[index])
            }
            agentConnectRetries = value
        default:
            throw ArgumentError.unknownFlag(flag)
        }
        index += 1
    }

    guard let templatePath else {
        throw ArgumentError.required("missing required argument: --template")
    }
    guard let sharePath else {
        throw ArgumentError.required("missing required argument: --share")
    }

    return Options(
        templateURL: URL(fileURLWithPath: templatePath).standardizedFileURL,
        sharedDirectoryURL: URL(fileURLWithPath: sharePath).standardizedFileURL,
        shareTag: shareTag,
        cpus: cpus,
        memoryMiB: memoryMiB,
        agentREPL: agentREPL,
        agentPort: agentPort,
        agentConnectRetries: agentConnectRetries
    )
}

func ensureFileExists(_ path: URL, message: String) {
    guard FileManager.default.fileExists(atPath: path.path) else {
        fputs("error: \(message): \(path.path)\n", stderr)
        exit(1)
    }
}

func ensureDirectoryExists(_ path: URL, message: String) {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
    guard exists, isDirectory.boolValue else {
        fputs("error: \(message): \(path.path)\n", stderr)
        exit(1)
    }
}

func clampedCPUCount(_ requested: Int) -> Int {
    let minAllowed = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    let maxAllowed = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    return max(minAllowed, min(maxAllowed, requested))
}

func clampedMemoryBytes(_ requestedMiB: UInt64) -> UInt64 {
    let requested = requestedMiB * 1024 * 1024
    let minAllowed = VZVirtualMachineConfiguration.minimumAllowedMemorySize
    let maxAllowed = VZVirtualMachineConfiguration.maximumAllowedMemorySize
    return max(minAllowed, min(maxAllowed, requested))
}

func loadOrCreateMachineIdentifier(at path: URL) throws -> VZMacMachineIdentifier {
    if FileManager.default.fileExists(atPath: path.path) {
        let data = try Data(contentsOf: path)
        if let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: data) {
            return machineIdentifier
        }
        fputs("warning: existing MachineIdentifier.bin is invalid, generating a new one\n", stderr)
    }

    let machineIdentifier = VZMacMachineIdentifier()
    try machineIdentifier.dataRepresentation.write(to: path)
    return machineIdentifier
}

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        NSApplication.shared.terminate(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("vm stopped with error: \(error)\n", stderr)
        NSApplication.shared.terminate(nil)
    }
}

enum DebuggerError: Error, CustomStringConvertible {
    case socketDeviceUnavailable
    case notConnected
    case invalidCommand(String)
    case missingActiveProcess
    case connectFailed(String)

    var description: String {
        switch self {
        case .socketDeviceUnavailable:
            return "vm socket device not available"
        case .notConnected:
            return "not connected to guest-agent; run `connect` first"
        case .invalidCommand(let message):
            return message
        case .missingActiveProcess:
            return "no active process; run `exec`/`exec-tty` first"
        case .connectFailed(let message):
            return message
        }
    }
}

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
        .init(type: .exec, id: id, executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, terminal: terminal, signal: nil, width: nil, height: nil, data: nil, exitCode: nil, message: nil)
    }

    static func stdin(id: String, data: Data) -> Self {
        .init(type: .stdin, id: id, executable: nil, arguments: nil, environment: nil, workingDirectory: nil, terminal: nil, signal: nil, width: nil, height: nil, data: data, exitCode: nil, message: nil)
    }

    static func signal(id: String, signal: Int32) -> Self {
        .init(type: .signal, id: id, executable: nil, arguments: nil, environment: nil, workingDirectory: nil, terminal: nil, signal: signal, width: nil, height: nil, data: nil, exitCode: nil, message: nil)
    }

    static func resize(id: String, width: UInt16, height: UInt16) -> Self {
        .init(type: .resize, id: id, executable: nil, arguments: nil, environment: nil, workingDirectory: nil, terminal: nil, signal: nil, width: width, height: height, data: nil, exitCode: nil, message: nil)
    }

    static func close(id: String) -> Self {
        .init(type: .close, id: id, executable: nil, arguments: nil, environment: nil, workingDirectory: nil, terminal: nil, signal: nil, width: nil, height: nil, data: nil, exitCode: nil, message: nil)
    }
}

final class AgentDebugger {
    private let virtualMachine: VZVirtualMachine
    private let port: UInt32
    private let connectRetries: Int
    private let retryDelayMicroseconds: useconds_t = 500_000
    private let readyTimeoutSeconds: TimeInterval = 5
    private let connectCallbackTimeoutSeconds: TimeInterval = 2
    private let writeLock = NSLock()
    private let connectionLock = NSLock()

    private var connection: VZVirtioSocketConnection?
    private var socketHandle: FileHandle?
    private var readGeneration: UInt64 = 0
    private var activeProcessID: String?
    private var pendingReady: (generation: UInt64, semaphore: DispatchSemaphore)?

    init(virtualMachine: VZVirtualMachine, port: UInt32, connectRetries: Int) {
        self.virtualMachine = virtualMachine
        self.port = port
        self.connectRetries = connectRetries
    }

    func launchREPL() {
        Thread.detachNewThread { [weak self] in
            self?.runREPLLoop()
        }
    }

    private func runREPLLoop() {
        print("")
        print("Agent REPL started (vsock port \(port)). Type `help` for commands.")
        do {
            try connect(forceReconnect: true, maxRetries: 1)
        } catch {
            print("[agent-repl] initial connect failed: \(error)")
            print("[agent-repl] VM may still be booting; run `connect` after login")
        }

        while true {
            print("agent> ", terminator: "")
            fflush(stdout)
            guard let line = readLine(strippingNewline: true) else {
                disconnect()
                return
            }
            let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }

            do {
                if command == "help" {
                    printHelp()
                } else if command == "connect" {
                    print("[agent-repl] connecting (single attempt)...")
                    try connect(forceReconnect: true, maxRetries: 1)
                } else if command == "connect-wait" {
                    print("[agent-repl] connecting with retries (\(connectRetries))...")
                    try connect(forceReconnect: true, maxRetries: connectRetries)
                } else if command == "quit" || command == "exit" {
                    disconnect()
                    print("Agent REPL stopped.")
                    return
                } else if command.hasPrefix("sh ") {
                    let shellCommand = String(command.dropFirst(3))
                    guard !shellCommand.isEmpty else {
                        throw DebuggerError.invalidCommand("usage: sh <command>")
                    }
                    try startExec(executable: "/bin/sh", arguments: ["-lc", shellCommand], terminal: false)
                } else if command.hasPrefix("exec-tty ") {
                    let value = String(command.dropFirst("exec-tty ".count))
                    let parts = splitWhitespace(value)
                    guard let executable = parts.first else {
                        throw DebuggerError.invalidCommand("usage: exec-tty <executable> [args...]")
                    }
                    try startExec(executable: executable, arguments: Array(parts.dropFirst()), terminal: true)
                } else if command.hasPrefix("exec ") {
                    let value = String(command.dropFirst(5))
                    let parts = splitWhitespace(value)
                    guard let executable = parts.first else {
                        throw DebuggerError.invalidCommand("usage: exec <executable> [args...]")
                    }
                    try startExec(executable: executable, arguments: Array(parts.dropFirst()), terminal: false)
                } else if command.hasPrefix("stdin ") {
                    let value = String(command.dropFirst(6))
                    guard !value.isEmpty else {
                        throw DebuggerError.invalidCommand("usage: stdin <text>")
                    }
                    try sendStdin(value + "\n")
                } else if command == "close" {
                    try closeStdin()
                } else if command.hasPrefix("signal ") {
                    let value = String(command.dropFirst(7))
                    guard let signal = Int32(value) else {
                        throw DebuggerError.invalidCommand("usage: signal <int>")
                    }
                    try sendSignal(signal)
                } else if command.hasPrefix("resize ") {
                    let parts = splitWhitespace(String(command.dropFirst(7)))
                    guard parts.count == 2, let width = UInt16(parts[0]), let height = UInt16(parts[1]) else {
                        throw DebuggerError.invalidCommand("usage: resize <width> <height>")
                    }
                    try resize(width: width, height: height)
                } else {
                    throw DebuggerError.invalidCommand("unknown command: \(command)")
                }
            } catch {
                print("[agent-repl] \(error)")
            }
        }
    }

    private func printHelp() {
        print(
            """
            Commands:
              connect                          reconnect once (fast fail)
              connect-wait                     reconnect with retry loop
              sh <command>                     run /bin/sh -lc <command>
              exec <path> [args...]            run a non-tty process
              exec-tty <path> [args...]        run a tty process
              stdin <text>                     send text + newline to active process
              close                            close stdin for active process
              signal <int>                     send signal to active process
              resize <width> <height>          resize tty for active process
              quit | exit                      stop REPL (VM keeps running)
            """
        )
    }

    private func connect(forceReconnect: Bool, maxRetries: Int? = nil) throws {
        if forceReconnect {
            disconnect()
        } else {
            connectionLock.lock()
            let hasConnection = socketHandle != nil
            connectionLock.unlock()
            if hasConnection {
                return
            }
        }

        let retries = max(1, maxRetries ?? connectRetries)

        guard let socketDevice = virtualMachine.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
            throw DebuggerError.socketDeviceUnavailable
        }

        var lastError: Error?
        for attempt in 1...retries {
            if retries > 1 {
                print("[agent-repl] connect attempt \(attempt)/\(retries)")
            }
            do {
                let connection = try connectOnMain(socketDevice: socketDevice, port: port)
                let handle = FileHandle(fileDescriptor: connection.fileDescriptor, closeOnDealloc: false)
                let generation: UInt64

                connectionLock.lock()
                self.connection = connection
                self.socketHandle = handle
                self.readGeneration &+= 1
                generation = self.readGeneration
                self.pendingReady = (generation: generation, semaphore: DispatchSemaphore(value: 0))
                connectionLock.unlock()

                startReadLoop(handle: handle, generation: generation)
                print("[agent-repl] vsock connect callback succeeded; waiting for ready frame...")
                if waitForReady(generation: generation) {
                    print("[agent-repl] connected to guest-agent on port \(port)")
                    return
                }
                disconnect()
                lastError = DebuggerError.connectFailed("timeout waiting for ready frame")
                if retries > 1 {
                    print("[agent-repl] attempt \(attempt) failed: timeout waiting for ready frame")
                }
            } catch {
                lastError = error
                if retries > 1 {
                    print("[agent-repl] attempt \(attempt) failed: \(describeError(error))")
                }
                if attempt < retries {
                    usleep(retryDelayMicroseconds)
                }
            }
        }

        throw DebuggerError.connectFailed(
            "failed to connect to guest-agent on port \(port) after \(retries) retries: \(describeError(lastError ?? DebuggerError.notConnected))"
        )
    }

    private func disconnect() {
        connectionLock.lock()
        let handle = socketHandle
        let connection = connection
        readGeneration &+= 1
        socketHandle = nil
        self.connection = nil
        activeProcessID = nil
        pendingReady = nil
        connectionLock.unlock()

        try? handle?.close()
        connection?.close()
    }

    private func connectOnMain(socketDevice: VZVirtioSocketDevice, port: UInt32) throws -> VZVirtioSocketConnection {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<VZVirtioSocketConnection, Error>?
        DispatchQueue.main.async {
            socketDevice.connect(toPort: port) { connectionResult in
                result = connectionResult
                semaphore.signal()
            }
        }
        let timeout = DispatchTime.now() + connectCallbackTimeoutSeconds
        guard semaphore.wait(timeout: timeout) == .success else {
            throw DebuggerError.connectFailed("timeout waiting for vsock connect callback")
        }
        switch result {
        case .success(let connection):
            return connection
        case .failure(let error):
            throw error
        case .none:
            throw DebuggerError.connectFailed("socket connect completion not called")
        }
    }

    private func startReadLoop(handle: FileHandle, generation: UInt64) {
        let fd = handle.fileDescriptor
        let thread = Thread { [weak self] in
            self?.readLoop(fd: fd, generation: generation)
        }
        thread.name = "manual-template-vm-agent-read"
        thread.start()
    }

    private func readLoop(fd: Int32, generation: UInt64) {
        var buffer = Data()
        var chunkBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if !isCurrentReadGeneration(generation) {
                return
            }

            do {
                let chunk = try readChunk(fd: fd, into: &chunkBuffer)
                guard let chunk, !chunk.isEmpty else {
                    if isCurrentReadGeneration(generation) {
                        print("[agent-repl] connection closed by peer")
                    }
                    return
                }
                buffer.append(chunk)
                try consumeFrames(buffer: &buffer, generation: generation)
            } catch {
                if isCurrentReadGeneration(generation) {
                    print("[agent-repl] read failed: \(describeError(error))")
                }
                return
            }
        }
    }

    private func readChunk(fd: Int32, into storage: inout [UInt8]) throws -> Data? {
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

    private func isCurrentReadGeneration(_ generation: UInt64) -> Bool {
        connectionLock.lock()
        let current = readGeneration
        connectionLock.unlock()
        return generation == current
    }

    private func waitForReady(generation: UInt64) -> Bool {
        let semaphore: DispatchSemaphore?
        connectionLock.lock()
        if let pendingReady, pendingReady.generation == generation {
            semaphore = pendingReady.semaphore
        } else {
            semaphore = nil
        }
        connectionLock.unlock()
        guard let semaphore else {
            return true
        }
        let deadline = DispatchTime.now() + readyTimeoutSeconds
        let status = semaphore.wait(timeout: deadline)
        if status == .success {
            return true
        }

        connectionLock.lock()
        if pendingReady?.generation == generation {
            pendingReady = nil
        }
        connectionLock.unlock()
        return false
    }

    private func consumeFrames(buffer: inout Data, generation: UInt64) throws {
        while buffer.count >= MemoryLayout<UInt32>.size {
            let lengthBytes = buffer.prefix(MemoryLayout<UInt32>.size)
            let length = lengthBytes.withUnsafeBytes { raw in
                raw.load(as: UInt32.self).bigEndian
            }
            let total = MemoryLayout<UInt32>.size + Int(length)
            guard buffer.count >= total else { return }

            let payload = buffer.subdata(in: MemoryLayout<UInt32>.size..<total)
            buffer.removeSubrange(0..<total)
            let frame = try JSONDecoder().decode(GuestAgentFrame.self, from: payload)
            render(frame: frame, generation: generation)
        }
    }

    private func render(frame: GuestAgentFrame, generation: UInt64) {
        switch frame.type {
        case .stdout:
            if let data = frame.data {
                print("[stdout] \(String(decoding: data, as: UTF8.self))", terminator: "")
            } else {
                print("[stdout] <empty>")
            }
        case .stderr:
            if let data = frame.data {
                print("[stderr] \(String(decoding: data, as: UTF8.self))", terminator: "")
            } else {
                print("[stderr] <empty>")
            }
        case .exit:
            print("[exit] code=\(frame.exitCode ?? 1)")
        case .error:
            print("[error] \(frame.message ?? "unknown error")")
        case .ready:
            print("[ready] guest-agent is ready")
            connectionLock.lock()
            if let pendingReady, pendingReady.generation == generation {
                pendingReady.semaphore.signal()
                self.pendingReady = nil
            }
            connectionLock.unlock()
        case .exec, .stdin, .signal, .resize, .close:
            print("[frame] \(frame.type.rawValue)")
        }
    }

    private func startExec(executable: String, arguments: [String], terminal: Bool) throws {
        try connect(forceReconnect: false)
        let processID = UUID().uuidString
        activeProcessID = processID
        let frame = GuestAgentFrame.exec(
            id: processID,
            executable: executable,
            arguments: arguments,
            environment: ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"],
            workingDirectory: "/",
            terminal: terminal
        )
        try sendFrame(frame)
        print("[agent-repl] exec id=\(processID) tty=\(terminal) command=\(executable) \(arguments.joined(separator: " "))")
    }

    private func sendStdin(_ text: String) throws {
        guard let processID = activeProcessID else {
            throw DebuggerError.missingActiveProcess
        }
        try sendFrame(.stdin(id: processID, data: Data(text.utf8)))
    }

    private func closeStdin() throws {
        guard let processID = activeProcessID else {
            throw DebuggerError.missingActiveProcess
        }
        try sendFrame(.close(id: processID))
    }

    private func sendSignal(_ signal: Int32) throws {
        guard let processID = activeProcessID else {
            throw DebuggerError.missingActiveProcess
        }
        try sendFrame(.signal(id: processID, signal: signal))
    }

    private func resize(width: UInt16, height: UInt16) throws {
        guard let processID = activeProcessID else {
            throw DebuggerError.missingActiveProcess
        }
        try sendFrame(.resize(id: processID, width: width, height: height))
    }

    private func sendFrame(_ frame: GuestAgentFrame) throws {
        connectionLock.lock()
        let handle = socketHandle
        connectionLock.unlock()
        guard let handle else {
            throw DebuggerError.notConnected
        }
        let fd = handle.fileDescriptor

        let payload = try JSONEncoder().encode(frame)
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)

        writeLock.lock()
        defer { writeLock.unlock() }
        try writeAll(fd: fd, data: header)
        try writeAll(fd: fd, data: payload)
    }

    private func writeAll(fd: Int32, data: Data) throws {
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
}

func splitWhitespace(_ value: String) -> [String] {
    value.split(whereSeparator: \.isWhitespace).map(String.init)
}

func describeError(_ error: Error) -> String {
    if let debuggerError = error as? DebuggerError {
        return debuggerError.description
    }
    let nsError = error as NSError
    return "\(nsError.domain) Code=\(nsError.code) \"\(nsError.localizedDescription)\""
}

do {
    guard #available(macOS 13.0, *) else {
        fputs("error: this script requires macOS 13 or newer\n", stderr)
        exit(1)
    }

    #if !arch(arm64)
    fputs("error: macOS guest virtualization requires Apple Silicon (arm64)\n", stderr)
    exit(1)
    #else
    let options = try parseOptions()

    ensureDirectoryExists(options.templateURL, message: "template directory does not exist")
    ensureDirectoryExists(options.sharedDirectoryURL, message: "shared directory does not exist")

    let hardwareModelURL = options.templateURL.appendingPathComponent("HardwareModel.bin")
    let auxiliaryStorageURL = options.templateURL.appendingPathComponent("AuxiliaryStorage")
    let diskImageURL = options.templateURL.appendingPathComponent("Disk.img")
    let machineIdentifierURL = options.templateURL.appendingPathComponent("MachineIdentifier.bin")

    ensureFileExists(hardwareModelURL, message: "missing template file")
    ensureFileExists(auxiliaryStorageURL, message: "missing template file")
    ensureFileExists(diskImageURL, message: "missing template file")

    let hardwareModelData = try Data(contentsOf: hardwareModelURL)
    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
        fputs("error: invalid HardwareModel.bin\n", stderr)
        exit(1)
    }

    let machineIdentifier = try loadOrCreateMachineIdentifier(at: machineIdentifierURL)

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = hardwareModel
    platform.machineIdentifier = machineIdentifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStorageURL)

    let bootLoader = VZMacOSBootLoader()

    let blockAttachment = try VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false)
    let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: blockAttachment)

    let networkDevice = VZVirtioNetworkDeviceConfiguration()
    networkDevice.attachment = VZNATNetworkDeviceAttachment()

    let sharedDirectory = VZSharedDirectory(url: options.sharedDirectoryURL, readOnly: false)
    let singleDirectoryShare = VZSingleDirectoryShare(directory: sharedDirectory)
    let fileSystemDevice = VZVirtioFileSystemDeviceConfiguration(tag: options.shareTag)
    fileSystemDevice.share = singleDirectoryShare

    let graphics = VZMacGraphicsDeviceConfiguration()
    if let screen = NSScreen.main ?? NSScreen.screens.first {
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                for: screen,
                sizeInPoints: NSSize(width: 1440, height: 900)
            )
        ]
    } else {
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1440, heightInPixels: 900, pixelsPerInch: 80)
        ]
    }

    let vmConfiguration = VZVirtualMachineConfiguration()
    vmConfiguration.bootLoader = bootLoader
    vmConfiguration.platform = platform
    vmConfiguration.cpuCount = clampedCPUCount(options.cpus)
    vmConfiguration.memorySize = clampedMemoryBytes(options.memoryMiB)
    vmConfiguration.storageDevices = [blockDevice]
    vmConfiguration.networkDevices = [networkDevice]
    vmConfiguration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    vmConfiguration.directorySharingDevices = [fileSystemDevice]
    vmConfiguration.graphicsDevices = [graphics]
    vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
    vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

    try vmConfiguration.validate()

    let virtualMachine = VZVirtualMachine(configuration: vmConfiguration)
    let delegate = VMDelegate()
    virtualMachine.delegate = delegate
    let debugger = options.agentREPL ? AgentDebugger(
        virtualMachine: virtualMachine,
        port: options.agentPort,
        connectRetries: options.agentConnectRetries
    ) : nil

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Manual macOS Template VM"

    let vmView = VZVirtualMachineView(frame: frame)
    vmView.virtualMachine = virtualMachine
    vmView.capturesSystemKeys = true
    vmView.autoresizingMask = [.width, .height]
    window.contentView = vmView
    window.makeKeyAndOrderFront(nil)

    app.activate(ignoringOtherApps: true)

    print("Starting VM...")
    print("template: \(options.templateURL.path)")
    print("share: \(options.sharedDirectoryURL.path)")
    print("share tag: \(options.shareTag)")
    if options.agentREPL {
        print("agent repl: enabled (port \(options.agentPort))")
    }
    print("In guest:")
    print("  sudo mkdir -p /Volumes/\(options.shareTag)")
    print("  sudo mount -t virtiofs \(options.shareTag) /Volumes/\(options.shareTag)")

    virtualMachine.start { result in
        switch result {
        case .success:
            print("VM started.")
            debugger?.launchREPL()
        case .failure(let error):
            fputs("failed to start VM: \(error)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    // Keep references alive for the app lifetime.
    _ = delegate
    _ = debugger
    _ = window
    _ = vmView

    app.run()
    #endif
} catch {
    fputs("error: \(error)\n", stderr)
    printUsage()
    exit(1)
}
