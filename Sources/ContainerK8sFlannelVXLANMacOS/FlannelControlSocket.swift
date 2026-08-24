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

import CryptoKit
import Darwin
import Foundation

public struct FlannelPurgePreflightClaim: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var manifestSHA256: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        manifestSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.manifestSHA256 = manifestSHA256
    }

    public init(manifest: FlannelStateManifest) throws {
        try manifest.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        self.init(
            manifestSHA256: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FlannelVXLANError.runtime(
                "unsupported purge preflight claim schema version \(schemaVersion)"
            )
        }
        let digestBytes = Array(manifestSHA256.utf8)
        guard digestBytes.count == 64,
            digestBytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else {
            throw FlannelVXLANError.runtime("purge preflight claim contains an invalid SHA-256 digest")
        }
    }
}

public struct FlannelControlRequest: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let withdrawAction = "withdraw"
    public static let checkPurgeAction = "check-purge"

    public var version: Int
    public var action: String
    public var purgePreflightClaim: FlannelPurgePreflightClaim?

    public init(
        version: Int = Self.currentVersion,
        action: String = Self.withdrawAction,
        purgePreflightClaim: FlannelPurgePreflightClaim? = nil
    ) {
        self.version = version
        self.action = action
        self.purgePreflightClaim = purgePreflightClaim
    }
}

public struct FlannelControlResponse: Codable, Sendable, Equatable {
    public enum FailureKind: String, Codable, Sendable, Equatable {
        case operationFailed
        case unsupportedAction
        case unsupportedVersion
    }

    public static let currentVersion = 1

    public var version: Int
    public var outcome: FlannelWithdrawalOutcome
    public var failureKind: FailureKind?

    public init(
        version: Int = Self.currentVersion,
        outcome: FlannelWithdrawalOutcome,
        failureKind: FailureKind? = nil
    ) {
        self.version = version
        self.outcome = outcome
        self.failureKind = failureKind
    }
}

public enum FlannelCheckPurgeControlError: Error, Sendable, Equatable, CustomStringConvertible {
    case authentication(String)
    case protocolViolation(String)
    case transport(String)
    case unsupportedAction(String)

    public var description: String {
        switch self {
        case .authentication(let message):
            "control socket authentication failed: \(message)"
        case .protocolViolation(let message):
            "control protocol violation: \(message)"
        case .transport(let message):
            "control transport failed: \(message)"
        case .unsupportedAction(let message):
            "control action is unsupported: \(message)"
        }
    }

    public var fallbackManifestPolicy: FlannelPurgePreflightFallbackManifestPolicy? {
        switch self {
        case .transport:
            .requireExactManifest
        case .unsupportedAction:
            .allowMissingLegacyManifest
        case .authentication, .protocolViolation:
            nil
        }
    }
}

public enum FlannelPurgePreflightFallbackManifestPolicy: Sendable, Equatable {
    case requireExactManifest
    case allowMissingLegacyManifest
}

public final class FlannelControlServer: @unchecked Sendable {
    public typealias WithdrawalHandler = @Sendable () async -> FlannelWithdrawalOutcome
    public typealias CheckPurgeHandler = @Sendable (FlannelPurgePreflightClaim) async -> FlannelWithdrawalOutcome

    private let socketPath: String
    private let requiredPeerUID: uid_t
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = true
    private var withdrawalHandler: WithdrawalHandler?
    private var checkPurgeHandler: CheckPurgeHandler?

    public init(socketPath: String, requiredPeerUID: uid_t = 0) {
        self.socketPath = socketPath
        self.requiredPeerUID = requiredPeerUID
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping WithdrawalHandler) throws {
        try startServer(withdrawalHandler: handler, checkPurgeHandler: nil)
    }

    public func start(
        withdrawalHandler: @escaping WithdrawalHandler,
        checkPurgeHandler: @escaping CheckPurgeHandler
    ) throws {
        try startServer(withdrawalHandler: withdrawalHandler, checkPurgeHandler: checkPurgeHandler)
    }

    private func startServer(
        withdrawalHandler: @escaping WithdrawalHandler,
        checkPurgeHandler: CheckPurgeHandler?
    ) throws {
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
            self.withdrawalHandler = withdrawalHandler
            self.checkPurgeHandler = checkPurgeHandler
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
            withdrawalHandler = nil
            checkPurgeHandler = nil
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
            guard request.version == FlannelControlRequest.currentVersion else {
                try writeFailure(
                    "unsupported control request version \(request.version)",
                    kind: .unsupportedVersion,
                    to: clientFD
                )
                return
            }
            let handler: WithdrawalHandler?
            switch request.action {
            case FlannelControlRequest.withdrawAction:
                handler = lock.withLock { withdrawalHandler }
            case FlannelControlRequest.checkPurgeAction:
                guard let claim = request.purgePreflightClaim else {
                    try writeFailure(
                        "control request action \(request.action) requires a purge preflight claim",
                        kind: .operationFailed,
                        to: clientFD
                    )
                    return
                }
                do {
                    try claim.validate()
                } catch {
                    try writeFailure(
                        "invalid purge preflight claim: \(error)",
                        kind: .operationFailed,
                        to: clientFD
                    )
                    return
                }
                guard let checkHandler = lock.withLock({ checkPurgeHandler }) else {
                    try writeFailure(
                        "unsupported control request action \(request.action)",
                        kind: .unsupportedAction,
                        to: clientFD
                    )
                    return
                }
                handler = { await checkHandler(claim) }
            default:
                try writeFailure(
                    "unsupported control request action \(request.action)",
                    kind: .unsupportedAction,
                    to: clientFD
                )
                return
            }
            guard let handler else {
                let kind: FlannelControlResponse.FailureKind =
                    request.action == FlannelControlRequest.checkPurgeAction
                    ? .unsupportedAction
                    : .operationFailed
                try writeFailure(
                    request.action == FlannelControlRequest.checkPurgeAction
                        ? "unsupported control request action \(request.action)"
                        : "control server is stopping",
                    kind: kind,
                    to: clientFD
                )
                return
            }
            let responseTask = Task {
                let outcome = await handler()
                return FlannelControlResponse(
                    outcome: outcome,
                    failureKind: outcome.succeeded ? nil : .operationFailed
                )
            }
            let response = awaitBlocking(responseTask)
            try writeFrame(response, to: clientFD)
        } catch {
            let outcome = FlannelWithdrawalOutcome(succeeded: false, message: String(describing: error))
            try? writeFrame(FlannelControlResponse(outcome: outcome), to: clientFD)
        }
    }

    private func writeFailure(
        _ message: String,
        kind: FlannelControlResponse.FailureKind,
        to clientFD: Int32
    ) throws {
        let outcome = FlannelWithdrawalOutcome(succeeded: false, message: message)
        try writeFrame(FlannelControlResponse(outcome: outcome, failureKind: kind), to: clientFD)
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
        socketPath: String = FlannelVXLANMacOSConfig.defaultControlSocketPath,
        requiredPeerUID: uid_t = 0
    ) throws -> FlannelWithdrawalOutcome {
        let response = try request(
            FlannelControlRequest(),
            socketPath: socketPath,
            requiredPeerUID: requiredPeerUID
        )
        return response.outcome
    }

    public static func requestPurgePreflight(
        claim: FlannelPurgePreflightClaim,
        socketPath: String = FlannelVXLANMacOSConfig.defaultControlSocketPath,
        requiredPeerUID: uid_t = 0
    ) throws -> FlannelWithdrawalOutcome {
        let response: FlannelControlResponse
        do {
            response = try request(
                FlannelControlRequest(
                    action: FlannelControlRequest.checkPurgeAction,
                    purgePreflightClaim: claim
                ),
                socketPath: socketPath,
                requiredPeerUID: requiredPeerUID,
                classifyCheckPurgeErrors: true
            )
        } catch let error as FlannelCheckPurgeControlError {
            throw error
        } catch {
            throw FlannelCheckPurgeControlError.transport(String(describing: error))
        }
        return try purgePreflightOutcome(from: response)
    }

    static func purgePreflightOutcome(
        from response: FlannelControlResponse
    ) throws -> FlannelWithdrawalOutcome {
        if response.outcome.succeeded, let failureKind = response.failureKind {
            throw FlannelCheckPurgeControlError.protocolViolation(
                "successful response reported failure kind \(failureKind.rawValue)"
            )
        }
        if response.failureKind == .unsupportedAction
            || (response.failureKind == nil
                && !response.outcome.succeeded
                && response.outcome.message == "unsupported control request")
        {
            throw FlannelCheckPurgeControlError.unsupportedAction(response.outcome.message)
        }
        if response.failureKind == .unsupportedVersion {
            throw FlannelCheckPurgeControlError.protocolViolation(response.outcome.message)
        }
        return response.outcome
    }

    static func request(
        _ request: FlannelControlRequest,
        socketPath: String,
        requiredPeerUID: uid_t,
        classifyCheckPurgeErrors: Bool = false
    ) throws -> FlannelControlResponse {
        let fd: Int32
        do {
            fd = try connectUnixSocket(path: socketPath)
        } catch {
            if classifyCheckPurgeErrors {
                throw FlannelCheckPurgeControlError.transport(String(describing: error))
            }
            throw error
        }
        defer { Darwin.close(fd) }
        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard getpeereid(fd, &peerUID, &peerGID) == 0 else {
            let error = posixError("authenticate Flannel control server")
            if classifyCheckPurgeErrors {
                throw FlannelCheckPurgeControlError.authentication(String(describing: error))
            }
            throw error
        }
        guard peerUID == requiredPeerUID else {
            let message =
                "refusing Flannel control server owned by uid \(peerUID); expected uid \(requiredPeerUID)"
            if classifyCheckPurgeErrors {
                throw FlannelCheckPurgeControlError.authentication(message)
            }
            throw FlannelVXLANError.runtime(message)
        }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let response: FlannelControlResponse
        do {
            try writeFrame(request, to: fd)
        } catch let error as EncodingError {
            if classifyCheckPurgeErrors {
                throw FlannelCheckPurgeControlError.protocolViolation(String(describing: error))
            }
            throw error
        } catch {
            if classifyCheckPurgeErrors {
                throw FlannelCheckPurgeControlError.transport(String(describing: error))
            }
            throw error
        }
        do {
            response = try readFrame(FlannelControlResponse.self, from: fd)
        } catch let error as DecodingError {
            if classifyCheckPurgeErrors {
                throw FlannelCheckPurgeControlError.protocolViolation(String(describing: error))
            }
            throw error
        } catch let error as FlannelControlFrameError {
            if classifyCheckPurgeErrors {
                throw FlannelCheckPurgeControlError.protocolViolation(error.description)
            }
            throw error
        } catch {
            if classifyCheckPurgeErrors {
                throw FlannelCheckPurgeControlError.transport(String(describing: error))
            }
            throw error
        }
        guard response.version == FlannelControlResponse.currentVersion else {
            let message = "unsupported control response version \(response.version)"
            if classifyCheckPurgeErrors {
                throw FlannelCheckPurgeControlError.protocolViolation(message)
            }
            throw FlannelVXLANError.runtime(message)
        }
        return response
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
    throw FlannelControlFrameError.tooLarge(maximumSize: maximumSize)
}

private enum FlannelControlFrameError: Error, CustomStringConvertible {
    case tooLarge(maximumSize: Int)

    var description: String {
        switch self {
        case .tooLarge(let maximumSize):
            "Flannel control frame exceeds \(maximumSize) bytes"
        }
    }
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
