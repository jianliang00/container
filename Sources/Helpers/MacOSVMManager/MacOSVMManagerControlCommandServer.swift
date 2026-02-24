import AppKit
import Darwin
import Foundation

final class ControlCommandServer: @unchecked Sendable {
    private let socketPath: String
    private let debugger: AgentDebugger?
    private let lock = NSLock()

    private var listenFD: Int32 = -1
    private var isStopping = false
    private var thread: Thread?

    init(socketPath: String, debugger: AgentDebugger?) {
        self.socketPath = socketPath
        self.debugger = debugger
    }

    deinit {
        stop()
    }

    func start() throws {
        try stopAndCleanupStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw makePOSIXError(errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let maxPathCount = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxPathCount else {
            Darwin.close(fd)
            throw DebuggerError.invalidCommand("control socket path too long: \(socketPath)")
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

        guard listen(fd, 16) == 0 else {
            let error = makePOSIXError(errno)
            Darwin.close(fd)
            throw error
        }

        _ = chmod(socketPath, mode_t(S_IRUSR | S_IWUSR))

        lock.lock()
        listenFD = fd
        isStopping = false
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "macos-vm-manager-control-socket"
        self.thread = thread
        thread.start()

        print("control socket: \(socketPath)")
        print("control commands: help | probe | exec <path> [args...] | sh <command> | quit")
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        if isStopping {
            lock.unlock()
            return
        }
        isStopping = true
        listenFD = -1
        lock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        unlink(socketPath)
    }

    private func stopAndCleanupStaleSocket() throws {
        stop()
        unlink(socketPath)
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let stopping = isStopping
            lock.unlock()
            if stopping || fd < 0 {
                return
            }

            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD >= 0 {
                handleClient(clientFD)
                continue
            }

            let code = errno
            if code == EINTR {
                continue
            }

            lock.lock()
            let nowStopping = isStopping
            lock.unlock()
            if nowStopping {
                return
            }

            print("[control] accept failed: \(String(cString: strerror(code))) (\(code))")
            usleep(50_000)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer {
            Darwin.close(clientFD)
        }

        do {
            guard let raw = try readLineFromClient(clientFD) else {
                return
            }
            let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                try writeLineToClient(clientFD, "err empty command")
                return
            }

            switch command {
            case "help":
                try writeLineToClient(clientFD, "ok commands: help, probe, exec <path> [args...], sh <command>, quit")
            case "probe":
                guard let debugger else {
                    try writeLineToClient(clientFD, "err agent debugger unavailable")
                    return
                }
                do {
                    let message = try debugger.probeForControl()
                    try writeLineToClient(clientFD, "ok \(message)")
                } catch {
                    try writeLineToClient(clientFD, "err \(describeError(error))")
                }
            case let command where command.hasPrefix("exec "):
                guard let debugger else {
                    try writeLineToClient(clientFD, "err agent debugger unavailable")
                    return
                }
                let parts = splitWhitespace(String(command.dropFirst(5)))
                guard let executable = parts.first else {
                    try writeLineToClient(clientFD, "err usage: exec <path> [args...]")
                    return
                }
                do {
                    let result = try debugger.execForControl(executable: executable, arguments: Array(parts.dropFirst()))
                    try writeExecResultToClient(clientFD, result: result)
                } catch {
                    try writeLineToClient(clientFD, "err \(describeError(error))")
                }
            case let command where command.hasPrefix("sh "):
                guard let debugger else {
                    try writeLineToClient(clientFD, "err agent debugger unavailable")
                    return
                }
                let shellCommand = String(command.dropFirst(3))
                guard !shellCommand.isEmpty else {
                    try writeLineToClient(clientFD, "err usage: sh <command>")
                    return
                }
                do {
                    let result = try debugger.execForControl(executable: "/bin/sh", arguments: ["-lc", shellCommand])
                    try writeExecResultToClient(clientFD, result: result)
                } catch {
                    try writeLineToClient(clientFD, "err \(describeError(error))")
                }
            case "quit":
                try writeLineToClient(clientFD, "ok terminating")
                stop()
                Task { @MainActor in
                    NSApplication.shared.terminate(nil)
                }
            default:
                try writeLineToClient(clientFD, "err unknown command: \(command)")
            }
        } catch {
            print("[control] client error: \(describeError(error))")
        }
    }

    private func readLineFromClient(_ fd: Int32) throws -> String? {
        var bytes: [UInt8] = []
        var ch: UInt8 = 0
        while true {
            let count = withUnsafeMutablePointer(to: &ch) { pointer in
                Darwin.read(fd, pointer, 1)
            }
            if count > 0 {
                if ch == 0x0A {
                    break
                }
                bytes.append(ch)
                continue
            }
            if count == 0 {
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }

            let code = errno
            if code == EINTR {
                continue
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeLineToClient(_ fd: Int32, _ text: String) throws {
        let data = Data((text + "\n").utf8)
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
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
                )
            }
        }
    }

    private func writeExecResultToClient(_ fd: Int32, result: AgentDebugger.ControlExecResult) throws {
        let stdoutB64 = result.stdout.base64EncodedString()
        let stderrB64 = result.stderr.base64EncodedString()
        let agentErrorB64 = Data((result.agentError ?? "").utf8).base64EncodedString()
        try writeLineToClient(
            fd,
            "ok exit=\(result.exitCode) stdout_b64=\(stdoutB64) stderr_b64=\(stderrB64) agent_error_b64=\(agentErrorB64)"
        )
    }
}
