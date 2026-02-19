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

import ArgumentParser
import Darwin
import Foundation

@main
struct MacOSGuestAgent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-macos-guest-agent",
        abstract: "Guest-side vsock agent for container-runtime-macos"
    )

    @Option(name: .long, help: "vsock listen port")
    var port: UInt32 = 27000

    mutating func run() throws {
        let listener = try VsockListener(port: port)
        try listener.serveForever()
    }
}

private final class VsockListener {
    private let listenFD: Int32

    init(port: UInt32) throws {
        let fd = socket(AF_VSOCK, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else {
            throw POSIXError.fromErrno()
        }

        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError.fromErrno()
        }

        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_reserved1 = 0
        address.svm_port = port
        address.svm_cid = VMADDR_CID_ANY

        let addressLength = socklen_t(address.svm_len)
        let bindResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            throw POSIXError.fromErrno()
        }

        guard listen(fd, 16) == 0 else {
            throw POSIXError.fromErrno()
        }

        self.listenFD = fd
    }

    deinit {
        _ = Darwin.close(listenFD)
    }

    func serveForever() throws {
        while true {
            var clientAddr = sockaddr_vm()
            var clientLen = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &clientLen)
                }
            }
            guard clientFD >= 0 else {
                throw POSIXError.fromErrno()
            }

            let connection = AgentConnection(fd: clientFD)
            Thread.detachNewThread {
                do {
                    try connection.run()
                } catch {
                    _ = Darwin.close(clientFD)
                }
            }
        }
    }
}

private final class AgentConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let socketHandle: FileHandle

    private var buffer = Data()
    private var session: ProcessSession?

    init(fd: Int32) {
        self.fd = fd
        self.socketHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func run() throws {
        try send(frame: .ready)
        while true {
            guard let chunk = try socketHandle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            try consumeFrames()
        }
        session?.cleanup()
        try? socketHandle.close()
    }

    private func consumeFrames() throws {
        while buffer.count >= MemoryLayout<UInt32>.size {
            let lengthBytes = buffer.prefix(MemoryLayout<UInt32>.size)
            let length = lengthBytes.withUnsafeBytes { raw in
                raw.load(as: UInt32.self).bigEndian
            }
            let total = MemoryLayout<UInt32>.size + Int(length)
            guard buffer.count >= total else {
                return
            }

            let payload = buffer.subdata(in: MemoryLayout<UInt32>.size..<total)
            buffer.removeSubrange(0..<total)

            let frame = try JSONDecoder().decode(GuestAgentFrame.self, from: payload)
            try handle(frame: frame)
        }
    }

    private func handle(frame: GuestAgentFrame) throws {
        switch frame.type {
        case .exec:
            try startProcess(frame: frame)
        case .stdin:
            if let data = frame.data {
                try session?.writeStdin(data)
            }
        case .signal:
            if let signal = frame.signal {
                try session?.sendSignal(signal)
            }
        case .resize:
            if let width = frame.width, let height = frame.height {
                try session?.resize(width: width, height: height)
            }
        case .close:
            session?.closeStdin()
        case .stdout, .stderr, .exit, .error, .ready:
            break
        }
    }

    private func startProcess(frame: GuestAgentFrame) throws {
        session?.cleanup()

        guard let executable = frame.executable else {
            try send(frame: .error("missing executable"))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = frame.arguments ?? []
        process.environment = environmentDictionary(from: frame.environment ?? [])
        if let workingDirectory = frame.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        if frame.terminal == true {
            var master: Int32 = 0
            var slave: Int32 = 0
            guard openpty(&master, &slave, nil, nil, nil) == 0 else {
                throw POSIXError.fromErrno()
            }

            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
            process.standardInput = slaveHandle
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle

            let session = ProcessSession(
                process: process,
                terminal: true,
                connection: self,
                masterHandle: masterHandle,
                stdinPipe: nil
            )
            self.session = session
            try session.start()
        } else {
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let session = ProcessSession(
                process: process,
                terminal: false,
                connection: self,
                masterHandle: nil,
                stdinPipe: stdinPipe
            )
            self.session = session
            try session.start(stdoutHandle: stdoutPipe.fileHandleForReading, stderrHandle: stderrPipe.fileHandleForReading)
        }
    }

    fileprivate func send(frame: GuestAgentFrame) throws {
        let payload = try JSONEncoder().encode(frame)
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)

        lock.lock()
        defer { lock.unlock() }
        try socketHandle.write(contentsOf: header)
        try socketHandle.write(contentsOf: payload)
    }
}

private final class ProcessSession: @unchecked Sendable {
    private let process: Process
    private let terminal: Bool
    private unowned let connection: AgentConnection
    private let masterHandle: FileHandle?
    private let stdinPipe: Pipe?

    init(process: Process, terminal: Bool, connection: AgentConnection, masterHandle: FileHandle?, stdinPipe: Pipe?) {
        self.process = process
        self.terminal = terminal
        self.connection = connection
        self.masterHandle = masterHandle
        self.stdinPipe = stdinPipe
    }

    func start(stdoutHandle: FileHandle? = nil, stderrHandle: FileHandle? = nil) throws {
        try process.run()

        if let masterHandle {
            masterHandle.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                try? self.connection.send(frame: .stdout(data))
            }
        } else {
            stdoutHandle?.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                try? self.connection.send(frame: .stdout(data))
            }
            stderrHandle?.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                try? self.connection.send(frame: .stderr(data))
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            try? self.connection.send(frame: .exit(process.terminationStatus))
        }
    }

    func writeStdin(_ data: Data) throws {
        if terminal {
            guard let masterHandle else { return }
            try masterHandle.write(contentsOf: data)
        } else {
            try stdinPipe?.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func closeStdin() {
        if terminal {
            // No-op for pty stdin close in this MVP.
        } else {
            try? stdinPipe?.fileHandleForWriting.close()
        }
    }

    func sendSignal(_ signal: Int32) throws {
        guard process.isRunning else { return }
        guard Darwin.kill(process.processIdentifier, signal) == 0 else {
            throw POSIXError.fromErrno()
        }
    }

    func resize(width: UInt16, height: UInt16) throws {
        guard terminal, let masterHandle else { return }
        var ws = winsize(ws_row: height, ws_col: width, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(masterHandle.fileDescriptor, TIOCSWINSZ, &ws) == 0 else {
            throw POSIXError.fromErrno()
        }
    }

    func cleanup() {
        stdinPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.readabilityHandler = nil
        masterHandle?.readabilityHandler = nil
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        try? masterHandle?.close()
        try? stdinPipe?.fileHandleForReading.close()
        try? stdinPipe?.fileHandleForWriting.close()
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

    static let ready = GuestAgentFrame(
        type: .ready,
        id: nil,
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

    static func stdout(_ data: Data) -> Self {
        .init(type: .stdout, id: nil, executable: nil, arguments: nil, environment: nil, workingDirectory: nil, terminal: nil, signal: nil, width: nil, height: nil, data: data, exitCode: nil, message: nil)
    }

    static func stderr(_ data: Data) -> Self {
        .init(type: .stderr, id: nil, executable: nil, arguments: nil, environment: nil, workingDirectory: nil, terminal: nil, signal: nil, width: nil, height: nil, data: data, exitCode: nil, message: nil)
    }

    static func exit(_ code: Int32) -> Self {
        .init(type: .exit, id: nil, executable: nil, arguments: nil, environment: nil, workingDirectory: nil, terminal: nil, signal: nil, width: nil, height: nil, data: nil, exitCode: code, message: nil)
    }

    static func error(_ message: String) -> Self {
        .init(type: .error, id: nil, executable: nil, arguments: nil, environment: nil, workingDirectory: nil, terminal: nil, signal: nil, width: nil, height: nil, data: nil, exitCode: nil, message: message)
    }
}

private func environmentDictionary(from envList: [String]) -> [String: String] {
    var result: [String: String] = [:]
    for item in envList {
        let parts = item.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else {
            continue
        }
        result[String(parts[0])] = String(parts[1])
    }
    return result
}

private extension POSIXError {
    static func fromErrno() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
