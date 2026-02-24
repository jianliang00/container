import AppKit
import Darwin
import Foundation
import Virtualization

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

final class AgentDebugger: @unchecked Sendable {
    struct ControlExecResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        let agentError: String?
    }

    private final class PendingControlExec {
        let semaphore = DispatchSemaphore(value: 0)
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32?
        var agentError: String?
        var streamError: String?
        var completed = false
    }

    private let virtualMachine: VZVirtualMachine
    private let port: UInt32
    private let connectRetries: Int
    private let retryDelayMicroseconds: useconds_t = 500_000
    private let readyTimeoutSeconds: TimeInterval = 5
    private let connectCallbackTimeoutSeconds: TimeInterval = 2
    private let controlExecTimeoutSeconds: TimeInterval = 30
    private let writeLock = NSLock()
    private let connectionLock = NSLock()
    private let controlExecLock = NSLock()

    private var socketHandle: FileHandle?
    private var readGeneration: UInt64 = 0
    private var activeProcessID: String?
    private var pendingReady: (generation: UInt64, semaphore: DispatchSemaphore)?
    private var pendingControlExec: PendingControlExec?

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

    func launchProbeAndTerminateApp() {
        Thread.detachNewThread { [weak self] in
            self?.runProbeLoop()
        }
    }

    func probeForControl(maxRetries: Int? = nil) throws -> String {
        try connect(forceReconnect: true, maxRetries: maxRetries ?? connectRetries)
        disconnect()
        return "guest-agent ready on port \(port)"
    }

    func execForControl(executable: String, arguments: [String], maxRetries: Int? = nil) throws -> ControlExecResult {
        try connect(forceReconnect: true, maxRetries: maxRetries ?? connectRetries)
        defer { disconnect() }

        let pending = PendingControlExec()
        controlExecLock.lock()
        if pendingControlExec != nil {
            controlExecLock.unlock()
            throw DebuggerError.connectFailed("another control exec is already in progress")
        }
        pendingControlExec = pending
        controlExecLock.unlock()
        defer {
            controlExecLock.lock()
            if pendingControlExec === pending {
                pendingControlExec = nil
            }
            controlExecLock.unlock()
        }

        let processID = UUID().uuidString
        activeProcessID = processID
        let frame = GuestAgentFrame.exec(
            id: processID,
            executable: executable,
            arguments: arguments,
            environment: ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"],
            workingDirectory: "/",
            terminal: false
        )
        try sendFrame(frame)

        let deadline = DispatchTime.now() + controlExecTimeoutSeconds
        guard pending.semaphore.wait(timeout: deadline) == .success else {
            throw DebuggerError.connectFailed("timeout waiting for exec result")
        }

        if let streamError = pending.streamError {
            throw DebuggerError.connectFailed(streamError)
        }
        guard let exitCode = pending.exitCode else {
            if let agentError = pending.agentError {
                throw DebuggerError.connectFailed("guest-agent error: \(agentError)")
            }
            throw DebuggerError.connectFailed("missing exit frame for control exec")
        }

        return ControlExecResult(
            exitCode: exitCode,
            stdout: pending.stdout,
            stderr: pending.stderr,
            agentError: pending.agentError
        )
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

    private func runProbeLoop() {
        print("")
        print("Agent probe started (vsock port \(port)).")
        do {
            print("[agent-probe] connecting with retries (\(connectRetries))...")
            try connect(forceReconnect: true, maxRetries: connectRetries)
            print("[agent-probe] success: guest-agent ready on port \(port)")
        } catch {
            print("[agent-probe] failed: \(error)")
        }
        disconnect()
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
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

        var lastError: Error?
        for attempt in 1...retries {
            if retries > 1 {
                print("[agent-repl] connect attempt \(attempt)/\(retries)")
            }
            do {
                let fd = try connectOnMain(port: port)
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                let generation: UInt64

                connectionLock.lock()
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
        readGeneration &+= 1
        socketHandle = nil
        activeProcessID = nil
        pendingReady = nil
        connectionLock.unlock()

        try? handle?.close()
    }

    private func connectOnMain(port: UInt32) throws -> Int32 {
        guard let socketDevice = virtualMachine.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
            throw DebuggerError.socketDeviceUnavailable
        }

        let semaphore = DispatchSemaphore(value: 0)
        var fd: Int32?
        var connectError: Error?

        socketDevice.connect(toPort: port) { connectionResult in
            switch connectionResult {
            case .success(let connection):
                fd = connection.fileDescriptor
            case .failure(let error):
                connectError = error
            }
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + connectCallbackTimeoutSeconds
        guard semaphore.wait(timeout: timeout) == .success else {
            throw DebuggerError.connectFailed("timeout waiting for vsock connect callback")
        }
        if let connectError {
            throw connectError
        }
        guard let fd else {
            throw DebuggerError.connectFailed("socket connect completion not called")
        }
        return fd
    }

    private func startReadLoop(handle: FileHandle, generation: UInt64) {
        let fd = handle.fileDescriptor
        let thread = Thread { [weak self] in
            self?.readLoop(fd: fd, generation: generation)
        }
        thread.name = "macos-vm-manager-agent-read"
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
                        failPendingControlExecIfNeeded("connection closed by peer")
                        print("[agent-repl] connection closed by peer")
                    }
                    return
                }
                buffer.append(chunk)
                try consumeFrames(buffer: &buffer, generation: generation)
            } catch {
                if isCurrentReadGeneration(generation) {
                    failPendingControlExecIfNeeded("read failed: \(describeError(error))")
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
        if consumeControlExecFrameIfNeeded(frame) {
            return
        }
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

    private func consumeControlExecFrameIfNeeded(_ frame: GuestAgentFrame) -> Bool {
        controlExecLock.lock()
        guard let pending = pendingControlExec else {
            controlExecLock.unlock()
            return false
        }

        switch frame.type {
        case .stdout:
            if let data = frame.data {
                pending.stdout.append(data)
            }
            controlExecLock.unlock()
            return true
        case .stderr:
            if let data = frame.data {
                pending.stderr.append(data)
            }
            controlExecLock.unlock()
            return true
        case .error:
            pending.agentError = frame.message ?? "unknown guest-agent error"
            controlExecLock.unlock()
            return true
        case .exit:
            pending.exitCode = frame.exitCode ?? 1
            if !pending.completed {
                pending.completed = true
                pending.semaphore.signal()
            }
            self.pendingControlExec = nil
            controlExecLock.unlock()
            return true
        default:
            controlExecLock.unlock()
            return false
        }
    }

    private func failPendingControlExecIfNeeded(_ message: String) {
        controlExecLock.lock()
        guard let pending = pendingControlExec else {
            controlExecLock.unlock()
            return
        }
        pending.streamError = message
        if !pending.completed {
            pending.completed = true
            pending.semaphore.signal()
        }
        pendingControlExec = nil
        controlExecLock.unlock()
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
