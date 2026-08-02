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

import Darwin
import Foundation

public struct FlannelControlRequest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var action: String

    public init(version: Int = Self.currentVersion, action: String = "withdraw") {
        self.version = version
        self.action = action
    }
}

public struct FlannelControlResponse: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var outcome: FlannelWithdrawalOutcome

    public init(version: Int = Self.currentVersion, outcome: FlannelWithdrawalOutcome) {
        self.version = version
        self.outcome = outcome
    }
}

public final class FlannelControlServer: @unchecked Sendable {
    public typealias WithdrawalHandler = @Sendable () async -> FlannelWithdrawalOutcome

    private let socketPath: String
    private let requiredPeerUID: uid_t
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = true
    private var handler: WithdrawalHandler?

    public init(socketPath: String, requiredPeerUID: uid_t = 0) {
        self.socketPath = socketPath
        self.requiredPeerUID = requiredPeerUID
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping WithdrawalHandler) throws {
        try prepareSocketPath()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("create control socket")
        }

        do {
            try preventSIGPIPE(fd)
            var address = try unixAddress(path: socketPath)
            let addressLength = unixAddressLength(path: socketPath)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, addressLength)
                }
            }
            guard bindResult == 0 else {
                throw posixError("bind control socket \(socketPath)")
            }
            guard Darwin.chmod(socketPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw posixError("restrict control socket \(socketPath)")
            }
            guard Darwin.listen(fd, 8) == 0 else {
                throw posixError("listen on control socket \(socketPath)")
            }
        } catch {
            Darwin.close(fd)
            _ = Darwin.unlink(socketPath)
            throw error
        }

        lock.withLock {
            listenFD = fd
            stopping = false
            self.handler = handler
        }
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            guard !stopping else {
                return -1
            }
            stopping = true
            handler = nil
            let descriptor = listenFD
            listenFD = -1
            return descriptor
        }
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        _ = Darwin.unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            let state = lock.withLock { (listenFD, stopping) }
            guard !state.1, state.0 >= 0 else {
                return
            }
            let clientFD = Darwin.accept(state.0, nil, nil)
            if clientFD >= 0 {
                Thread.detachNewThread { [weak self] in
                    self?.handleClient(clientFD)
                }
                continue
            }
            let code = errno
            if code == EINTR {
                continue
            }
            if lock.withLock({ stopping }) {
                return
            }
            usleep(50_000)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        do {
            try preventSIGPIPE(clientFD)
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(clientFD, &peerUID, &peerGID) == 0 else {
                throw posixError("inspect control socket peer")
            }
            guard peerUID == requiredPeerUID else {
                throw FlannelVXLANError.runtime("control request denied for uid \(peerUID)")
            }
            let request = try readFrame(FlannelControlRequest.self, from: clientFD)
            guard request.version == FlannelControlRequest.currentVersion, request.action == "withdraw" else {
                let outcome = FlannelWithdrawalOutcome(succeeded: false, message: "unsupported control request")
                try writeFrame(FlannelControlResponse(outcome: outcome), to: clientFD)
                return
            }
            guard let handler = lock.withLock({ self.handler }) else {
                let outcome = FlannelWithdrawalOutcome(succeeded: false, message: "control server is stopping")
                try writeFrame(FlannelControlResponse(outcome: outcome), to: clientFD)
                return
            }
            let responseTask = Task {
                FlannelControlResponse(outcome: await handler())
            }
            let response = awaitBlocking(responseTask)
            try writeFrame(response, to: clientFD)
        } catch {
            let outcome = FlannelWithdrawalOutcome(succeeded: false, message: String(describing: error))
            try? writeFrame(FlannelControlResponse(outcome: outcome), to: clientFD)
        }
    }

    private func prepareSocketPath() throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var status = stat()
        guard Darwin.lstat(socketPath, &status) == 0 else {
            guard errno == ENOENT else {
                throw posixError("inspect existing control socket \(socketPath)")
            }
            return
        }
        guard status.st_mode & S_IFMT == S_IFSOCK, status.st_uid == geteuid() else {
            throw FlannelVXLANError.runtime("refusing to replace unowned non-socket path \(socketPath)")
        }
        if let activeFD = try? connectUnixSocket(path: socketPath) {
            Darwin.close(activeFD)
            throw FlannelVXLANError.runtime("another Flannel control server is active at \(socketPath)")
        }
        guard Darwin.unlink(socketPath) == 0 else {
            throw posixError("remove stale control socket \(socketPath)")
        }
    }
}

public enum FlannelControlClient {
    public static func requestWithdrawal(
        socketPath: String = FlannelVXLANMacOSConfig.defaultControlSocketPath
    ) throws -> FlannelWithdrawalOutcome {
        let fd = try connectUnixSocket(path: socketPath)
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try writeFrame(FlannelControlRequest(), to: fd)
        let response = try readFrame(FlannelControlResponse.self, from: fd)
        guard response.version == FlannelControlResponse.currentVersion else {
            throw FlannelVXLANError.runtime("unsupported control response version \(response.version)")
        }
        return response.outcome
    }
}

private func connectUnixSocket(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw posixError("create control client socket")
    }
    do {
        try preventSIGPIPE(fd)
        var address = try unixAddress(path: path)
        let addressLength = unixAddressLength(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard result == 0 else {
            throw posixError("connect to Flannel control socket \(path)")
        }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw FlannelVXLANError.runtime("control socket path is too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: CChar.self, repeating: 0)
        for (index, byte) in bytes.enumerated() {
            buffer[index] = byte
        }
    }
    return address
}

private func unixAddressLength(path: String) -> socklen_t {
    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
}

private func readFrame<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
    let maximumSize = 4_096
    var data = Data()
    var byte: UInt8 = 0
    while data.count < maximumSize {
        let count = Darwin.read(fd, &byte, 1)
        if count == 1 {
            if byte == 0x0a {
                return try JSONDecoder().decode(type, from: data)
            }
            data.append(byte)
            continue
        }
        if count == 0 {
            throw FlannelVXLANError.runtime("control socket closed before a complete response")
        }
        if errno == EINTR {
            continue
        }
        throw posixError("read Flannel control frame")
    }
    throw FlannelVXLANError.runtime("Flannel control frame exceeds \(maximumSize) bytes")
}

private func writeFrame<T: Encodable>(_ value: T, to fd: Int32) throws {
    var data = try JSONEncoder().encode(value)
    data.append(0x0a)
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else {
            return
        }
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            throw posixError("write Flannel control frame")
        }
    }
}

private func awaitBlocking<T: Sendable>(_ task: Task<T, Never>) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = FlannelBlockingResultBox<T>()
    Task {
        box.value = await task.value
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class FlannelBlockingResultBox<T>: @unchecked Sendable {
    var value: T?
}

private func posixError(_ operation: String) -> FlannelVXLANError {
    let code = errno
    return FlannelVXLANError.runtime("\(operation) failed: \(String(cString: strerror(code))) (\(code))")
}

private func preventSIGPIPE(_ fd: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw posixError("disable SIGPIPE on Flannel control socket")
    }
}
