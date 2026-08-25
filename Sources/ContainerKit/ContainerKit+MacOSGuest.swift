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

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Darwin
import Foundation

extension ContainerKit {
    public func createSandbox(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default
    ) async throws {
        try await containerClient.createSandbox(
            configuration: configuration,
            options: options
        )
    }

    public func startSandbox(id: String, presentGUI: Bool = true) async throws {
        try await containerClient.startSandbox(id: id, presentGUI: presentGUI)
    }

    public func showSandboxGUI(id: String) async throws {
        try await containerClient.showSandboxGUI(id: id)
    }

    public func inspectSandbox(id: String) async throws -> SandboxSnapshot {
        try await containerClient.inspectSandbox(id: id)
    }

    public func stopSandbox(
        id: String,
        options: ContainerStopOptions = .default
    ) async throws {
        try await containerClient.stop(id: id, opts: options)
    }

    public func removeSandbox(id: String, force: Bool = false) async throws {
        try await containerClient.delete(id: id, force: force)
    }

    public func createWorkload(
        sandboxID: String,
        configuration: WorkloadConfiguration
    ) async throws {
        try await containerClient.createWorkload(
            containerId: sandboxID,
            configuration: configuration
        )
    }

    public func startWorkload(sandboxID: String, workloadID: String) async throws {
        try await containerClient.startWorkload(
            containerId: sandboxID,
            workloadId: workloadID
        )
    }

    public func streamAttach(
        sandboxID: String,
        workloadID: String,
        options: WorkloadAttachOptions = .init(),
        attachmentID: String = UUID().uuidString.lowercased(),
        stdio: [FileHandle?]
    ) async throws -> any ClientWorkloadAttachment {
        try await containerClient.attachWorkload(
            containerId: sandboxID,
            workloadId: workloadID,
            options: options,
            stdio: stdio,
            attachmentID: attachmentID
        )
    }

    public func stopWorkload(
        sandboxID: String,
        workloadID: String,
        options: ContainerStopOptions = .default
    ) async throws {
        try await containerClient.stopWorkload(
            containerId: sandboxID,
            workloadId: workloadID,
            options: options
        )
    }

    public func removeWorkload(sandboxID: String, workloadID: String) async throws {
        try await containerClient.removeWorkload(
            containerId: sandboxID,
            workloadId: workloadID
        )
    }

    public func inspectWorkload(sandboxID: String, workloadID: String) async throws -> WorkloadSnapshot {
        try await containerClient.inspectWorkload(
            containerId: sandboxID,
            workloadId: workloadID
        )
    }

    public func sandboxLogPaths(id: String) async throws -> SandboxLogPaths {
        try await containerClient.sandboxLogPaths(id: id)
    }

    public func streamPortForward(id: String, port: UInt32) async throws -> FileHandle {
        try GuestAgentPortForwardTunnel.validateTargetPort(port)
        let snapshot = try await containerClient.inspectSandbox(id: id)
        let agentPort = snapshot.configuration?.macosGuest?.agentPort ?? 27_000
        let handle = try await containerClient.dial(id: id, port: agentPort)
        do {
            try await GuestAgentPortForwardTunnel.connect(
                fileDescriptor: handle.fileDescriptor,
                targetPort: port
            )
            return handle
        } catch is CancellationError {
            try? handle.close()
            throw CancellationError()
        } catch let error as ContainerizationError {
            try? handle.close()
            throw ContainerizationError(
                error.code,
                message: "failed to open guest TCP port-forward tunnel to port \(port)",
                cause: error
            )
        } catch {
            try? handle.close()
            throw ContainerizationError(
                .internalError,
                message: "failed to open guest TCP port-forward tunnel to port \(port)",
                cause: error
            )
        }
    }
}

enum GuestAgentPortForwardTunnel {
    private static let tcpConnectCapability = "tcpConnectV1"
    private static let handshakeTimeout: Duration = .seconds(5)
    private static let maximumFrameSize = 1 << 20
    private static let blockingHandshakeQueue = BoundedBlockingQueue(maximumConcurrentOperations: 8)

    private final class BoundedBlockingQueue: @unchecked Sendable {
        typealias Operation = @Sendable () -> Void

        private let maximumConcurrentOperations: Int
        private let blockingQueue = DispatchQueue(
            label: "com.apple.container.guest-agent-port-forward-handshake",
            qos: .userInitiated,
            attributes: .concurrent
        )
        private let timeoutQueue = DispatchQueue(
            label: "com.apple.container.guest-agent-port-forward-handshake-timeout",
            qos: .userInitiated
        )
        private let lock = NSLock()
        private var activeOperationCount = 0
        private var pendingOperations: [Operation] = []

        init(maximumConcurrentOperations: Int) {
            precondition(maximumConcurrentOperations > 0)
            self.maximumConcurrentOperations = maximumConcurrentOperations
        }

        func submit(_ operation: @escaping Operation) {
            let shouldDispatch = lock.withLock {
                guard activeOperationCount < maximumConcurrentOperations else {
                    pendingOperations.append(operation)
                    return false
                }
                activeOperationCount += 1
                return true
            }
            if shouldDispatch {
                dispatch(operation)
            }
        }

        func scheduleTimeout(_ operation: HandshakeOperation, deadline: UInt64) {
            guard deadline < UInt64.max else {
                return
            }
            timeoutQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) {
                operation.timeout()
            }
        }

        private func dispatch(_ firstOperation: @escaping Operation) {
            blockingQueue.async { [self] in
                var nextOperation: Operation? = firstOperation
                while let operation = nextOperation {
                    operation()
                    nextOperation = lock.withLock {
                        guard !pendingOperations.isEmpty else {
                            activeOperationCount -= 1
                            return nil
                        }
                        return pendingOperations.removeFirst()
                    }
                }
            }
        }
    }

    private final class HandshakeOperation: @unchecked Sendable {
        private enum State {
            case pending
            case running
            case completed
        }

        private let fileDescriptor: Int32
        private let lock = NSLock()
        private var state = State.pending
        private var terminalError: (any Error)?
        private var continuation: CheckedContinuation<Void, any Error>?

        init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }

        func install(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
            let rejection = lock.withLock { () -> (any Error)? in
                guard state == .pending else {
                    return terminalError ?? CancellationError()
                }
                self.continuation = continuation
                return nil
            }
            if let rejection {
                continuation.resume(throwing: rejection)
                return false
            }
            return true
        }

        func run(_ operation: @Sendable () throws -> Void) {
            let shouldRun = lock.withLock {
                guard state == .pending else {
                    return false
                }
                state = .running
                return true
            }
            guard shouldRun else {
                return
            }

            let operationError: (any Error)?
            do {
                try operation()
                operationError = nil
            } catch {
                operationError = error
            }

            let completion = lock.withLock {
                state = .completed
                let completion = (continuation, terminalError ?? operationError)
                continuation = nil
                return completion
            }
            guard let continuation = completion.0 else {
                return
            }
            if let error = completion.1 {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }

        func cancel() {
            interrupt(with: CancellationError())
        }

        func timeout() {
            interrupt(
                with: ContainerizationError(
                    .timeout,
                    message: "guest TCP port-forward handshake timed out"
                )
            )
        }

        private func interrupt(with error: any Error) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard state != .completed, terminalError == nil else {
                    return nil
                }
                terminalError = error
                switch state {
                case .pending:
                    state = .completed
                    let continuation = self.continuation
                    self.continuation = nil
                    return continuation
                case .running:
                    _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
                    return nil
                case .completed:
                    return nil
                }
            }
            continuation?.resume(throwing: error)
        }
    }

    private struct Frame: Codable {
        enum FrameType: String, Codable {
            case ready
            case tcpConnect
            case ack
            case error
            case exit
        }

        let type: FrameType
        let id: String?
        let port: UInt32?
        let message: String?
        let exitCode: Int32?
        let capabilities: [String]?

        init(
            type: FrameType,
            id: String? = nil,
            port: UInt32? = nil,
            message: String? = nil,
            exitCode: Int32? = nil,
            capabilities: [String]? = nil
        ) {
            self.type = type
            self.id = id
            self.port = port
            self.message = message
            self.exitCode = exitCode
            self.capabilities = capabilities
        }
    }

    static func validateTargetPort(_ targetPort: UInt32) throws {
        guard targetPort > 0, targetPort <= UInt32(UInt16.max) else {
            throw ContainerizationError(.invalidArgument, message: "TCP port must be between 1 and 65535")
        }
    }

    static func connect(
        fileDescriptor: Int32,
        targetPort: UInt32,
        timeout: Duration = handshakeTimeout
    ) async throws {
        try validateTargetPort(targetPort)

        let now = DispatchTime.now().uptimeNanoseconds
        let (candidateDeadline, overflow) = now.addingReportingOverflow(timeout.nanosecondsClamped)
        let deadline = overflow ? UInt64.max : candidateDeadline
        let handshakeOperation = HandshakeOperation(fileDescriptor: fileDescriptor)

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                guard handshakeOperation.install(continuation) else {
                    return
                }
                blockingHandshakeQueue.scheduleTimeout(handshakeOperation, deadline: deadline)
                blockingHandshakeQueue.submit {
                    handshakeOperation.run {
                        try performHandshake(
                            fileDescriptor: fileDescriptor,
                            targetPort: targetPort,
                            deadline: deadline
                        )
                    }
                }
            }
        } onCancel: {
            handshakeOperation.cancel()
        }
    }

    private static func performHandshake(
        fileDescriptor: Int32,
        targetPort: UInt32,
        deadline: UInt64
    ) throws {
        try disableSIGPIPE(fileDescriptor)

        let ready = try readFrame(fileDescriptor: fileDescriptor, deadline: deadline)
        guard ready.type == .ready else {
            throw handshakeError(frame: ready, expected: "ready")
        }
        guard ready.capabilities?.contains(tcpConnectCapability) == true else {
            throw ContainerizationError(
                .unsupported,
                message: "guest agent does not advertise the \(tcpConnectCapability) capability"
            )
        }

        let requestID = UUID().uuidString
        try writeFrame(
            Frame(type: .tcpConnect, id: requestID, port: targetPort),
            fileDescriptor: fileDescriptor,
            deadline: deadline
        )

        let response = try readFrame(fileDescriptor: fileDescriptor, deadline: deadline)
        guard response.type == .ack, response.id == requestID else {
            throw handshakeError(frame: response, expected: "ack for \(requestID)")
        }
    }

    private static func handshakeError(frame: Frame, expected: String) -> ContainerizationError {
        let detail =
            switch frame.type {
            case .error:
                frame.message ?? "unknown guest-agent error"
            case .exit:
                "guest-agent exited with code \(frame.exitCode ?? 1)"
            default:
                "received \(frame.type.rawValue)"
            }
        return ContainerizationError(
            .internalError,
            message: "guest TCP port-forward handshake expected \(expected): \(detail)"
        )
    }

    private static func readFrame(fileDescriptor: Int32, deadline: UInt64) throws -> Frame {
        let header = try readExact(
            fileDescriptor: fileDescriptor,
            count: MemoryLayout<UInt32>.size,
            deadline: deadline
        )
        let payloadLength = header.reduce(into: UInt32(0)) { value, byte in
            value = (value << 8) | UInt32(byte)
        }
        guard payloadLength <= maximumFrameSize else {
            throw ContainerizationError(
                .internalError,
                message: "guest TCP port-forward frame is too large: \(payloadLength)"
            )
        }
        let payload = try readExact(
            fileDescriptor: fileDescriptor,
            count: Int(payloadLength),
            deadline: deadline
        )
        return try JSONDecoder().decode(Frame.self, from: payload)
    }

    private static func writeFrame(
        _ frame: Frame,
        fileDescriptor: Int32,
        deadline: UInt64
    ) throws {
        let payload = try JSONEncoder().encode(frame)
        guard payload.count <= maximumFrameSize else {
            throw ContainerizationError(
                .internalError,
                message: "guest TCP port-forward frame is too large: \(payload.count)"
            )
        }
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try writeAll(header, fileDescriptor: fileDescriptor, deadline: deadline)
        try writeAll(payload, fileDescriptor: fileDescriptor, deadline: deadline)
    }

    private static func readExact(
        fileDescriptor: Int32,
        count: Int,
        deadline: UInt64
    ) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try waitForEvent(fileDescriptor: fileDescriptor, events: Int16(POLLIN), deadline: deadline)
            let readCount = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fileDescriptor, buffer.baseAddress?.advanced(by: offset), count - offset)
            }
            if readCount > 0 {
                offset += readCount
                continue
            }
            if readCount == 0 {
                throw ContainerizationError(.internalError, message: "guest TCP port-forward handshake reached EOF")
            }
            let code = errno
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return data
    }

    private static func writeAll(
        _ data: Data,
        fileDescriptor: Int32,
        deadline: UInt64
    ) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                try waitForEvent(fileDescriptor: fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    throw ContainerizationError(
                        .internalError,
                        message: "guest TCP port-forward handshake write returned zero"
                    )
                }
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
    }

    private static func waitForEvent(
        fileDescriptor: Int32,
        events: Int16,
        deadline: UInt64
    ) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw ContainerizationError(.timeout, message: "guest TCP port-forward handshake timed out")
            }
            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = 1 + ((remainingNanoseconds - 1) / 1_000_000)
            let remainingMilliseconds = min(roundedMilliseconds, UInt64(Int32.max))
            var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(remainingMilliseconds))
            if result > 0 {
                if (descriptor.revents & events) != 0 {
                    return
                }
                if (descriptor.revents & Int16(POLLNVAL | POLLERR)) != 0 {
                    throw ContainerizationError(.internalError, message: "guest TCP port-forward socket failed")
                }
                if (descriptor.revents & Int16(POLLHUP)) != 0 {
                    if events == Int16(POLLIN) {
                        return
                    }
                    throw ContainerizationError(.internalError, message: "guest TCP port-forward socket closed")
                }
                continue
            }
            if result == 0 {
                throw ContainerizationError(.timeout, message: "guest TCP port-forward handshake timed out")
            }
            if errno == EINTR {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func disableSIGPIPE(_ fileDescriptor: Int32) throws {
        var enabled: Int32 = 1
        guard
            Darwin.setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

extension Duration {
    fileprivate var nanosecondsClamped: UInt64 {
        let components = self.components
        guard components.seconds >= 0 else {
            return 0
        }
        let seconds = UInt64(clamping: components.seconds)
        let attoseconds = max(components.attoseconds, 0)
        let nanoseconds = UInt64(attoseconds / 1_000_000_000)
        let (secondsNanoseconds, secondsOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if secondsOverflow {
            return UInt64.max
        }
        let (total, totalOverflow) = secondsNanoseconds.addingReportingOverflow(nanoseconds)
        return totalOverflow ? UInt64.max : total
    }
}
