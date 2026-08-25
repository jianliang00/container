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

import ContainerizationError
import Darwin
import Foundation
import Testing

@testable import ContainerKit

private let fixtureHandshakeTimeout: Duration = .seconds(30)
private let fixtureInputTimeoutNanoseconds: UInt64 = 30_000_000_000

@Suite(.serialized)
struct GuestAgentPortForwardTunnelTests {
    @Test
    func negotiatesTCPConnectAndLeavesRawStreamUsable() async throws {
        let io = BoundedTestIO()
        let sockets = try makeSocketPair()
        defer {
            closeIfValid(sockets.client)
            closeIfValid(sockets.server)
        }

        async let server: Void = io.run {
            try serveRawStream(fileDescriptor: sockets.server)
        }

        try await GuestAgentPortForwardTunnel.connect(
            fileDescriptor: sockets.client,
            targetPort: 18_080,
            timeout: fixtureHandshakeTimeout
        )
        let response = try await io.run {
            try writeAll(Data("ping".utf8), fileDescriptor: sockets.client)
            return try readExact(fileDescriptor: sockets.client, count: 4)
        }
        #expect(response == Data("pong".utf8))
        try await server
    }

    @Test
    func surfacesGuestConnectFailure() async throws {
        let io = BoundedTestIO()
        let sockets = try makeSocketPair()
        defer {
            closeIfValid(sockets.client)
            closeIfValid(sockets.server)
        }

        async let server: Void = io.run {
            try writeFrame(
                WireFrame(type: "ready", capabilities: ["tcpConnectV1"]),
                fileDescriptor: sockets.server
            )
            _ = try readFrame(fileDescriptor: sockets.server)
            try writeFrame(
                WireFrame(type: "error", message: "connection refused"),
                fileDescriptor: sockets.server
            )
        }

        do {
            try await GuestAgentPortForwardTunnel.connect(
                fileDescriptor: sockets.client,
                targetPort: 18_080,
                timeout: fixtureHandshakeTimeout
            )
            Issue.record("expected guest TCP connect failure")
        } catch {
            #expect(String(describing: error).contains("connection refused"))
        }
        try await server
    }

    @Test
    func timesOutWhenGuestDoesNotAcknowledge() async throws {
        let io = BoundedTestIO()
        let sockets = try makeSocketPair()
        defer {
            closeIfValid(sockets.client)
            closeIfValid(sockets.server)
        }

        try await io.run {
            try writeFrame(
                WireFrame(type: "ready", capabilities: ["tcpConnectV1"]),
                fileDescriptor: sockets.server
            )
        }
        do {
            try await GuestAgentPortForwardTunnel.connect(
                fileDescriptor: sockets.client,
                targetPort: 18_080,
                timeout: .milliseconds(50)
            )
            Issue.record("expected guest TCP handshake timeout")
        } catch {
            #expect(String(describing: error).contains("timed out"))
        }
        #expect(Darwin.fcntl(sockets.client, F_GETFD) >= 0)
    }

    @Test
    func rejectsLegacyReadyWithoutTCPConnectCapability() async throws {
        let io = BoundedTestIO()
        let sockets = try makeSocketPair()
        defer {
            closeIfValid(sockets.client)
            closeIfValid(sockets.server)
        }

        try await io.run {
            try writeFrame(WireFrame(type: "ready"), fileDescriptor: sockets.server)
        }
        do {
            try await GuestAgentPortForwardTunnel.connect(
                fileDescriptor: sockets.client,
                targetPort: 18_080,
                timeout: fixtureHandshakeTimeout
            )
            Issue.record("expected legacy guest agent to be rejected")
        } catch let error as ContainerizationError {
            #expect(error.code == .unsupported)
            #expect(error.message.contains("tcpConnectV1"))
        }

        let pollResult = await io.runIgnoringErrors {
            var descriptor = pollfd(fd: sockets.server, events: Int16(POLLIN), revents: 0)
            return Darwin.poll(&descriptor, 1, 50)
        }
        #expect(pollResult == 0)
    }

    @Test(arguments: [UInt32(0), UInt32(65_536)])
    func rejectsInvalidTargetPortBeforeHandshake(port: UInt32) async throws {
        let io = BoundedTestIO()
        let sockets = try makeSocketPair()
        defer {
            closeIfValid(sockets.client)
            closeIfValid(sockets.server)
        }

        do {
            try await GuestAgentPortForwardTunnel.connect(
                fileDescriptor: sockets.client,
                targetPort: port,
                timeout: fixtureHandshakeTimeout
            )
            Issue.record("expected invalid target port to be rejected")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
        }

        let pollResult = await io.runIgnoringErrors {
            var descriptor = pollfd(fd: sockets.server, events: Int16(POLLIN), revents: 0)
            return Darwin.poll(&descriptor, 1, 50)
        }
        #expect(pollResult == 0)
    }

    @Test
    func cancellationUnblocksHandshakeWithoutClosingCallerDescriptor() async throws {
        let io = BoundedTestIO()
        let sockets = try makeSocketPair()
        defer {
            closeIfValid(sockets.client)
            closeIfValid(sockets.server)
        }

        let connection = Task {
            try await GuestAgentPortForwardTunnel.connect(
                fileDescriptor: sockets.client,
                targetPort: 18_080,
                timeout: fixtureHandshakeTimeout
            )
        }
        let request = try await io.run {
            try writeFrame(
                WireFrame(type: "ready", capabilities: ["tcpConnectV1"]),
                fileDescriptor: sockets.server
            )
            return try readFrame(fileDescriptor: sockets.server)
        }
        #expect(request.type == "tcpConnect")

        connection.cancel()
        do {
            try await connection.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(Darwin.fcntl(sockets.client, F_GETFD) >= 0)
    }

    @Test
    func concurrentHandshakesDoNotStarveCooperativeTasks() async throws {
        let io = BoundedTestIO()
        let connectionCount = 64
        let sockets = try (0..<connectionCount).map { _ in try makeSocketPair() }
        defer {
            for socket in sockets {
                closeIfValid(socket.client)
                closeIfValid(socket.server)
            }
        }

        let requestsReady = OneShotSignal()
        let releaseAcknowledgements = DispatchSemaphore(value: 0)
        let server = Task {
            try await io.run {
                try coordinateConcurrentHandshakes(
                    sockets: sockets.map(\.server),
                    gateAfterRequestCount: 4,
                    requestsReady: requestsReady,
                    releaseAcknowledgements: releaseAcknowledgements
                )
            }
        }

        let connections = sockets.map { socket in
            Task {
                try await GuestAgentPortForwardTunnel.connect(
                    fileDescriptor: socket.client,
                    targetPort: 18_080,
                    timeout: fixtureHandshakeTimeout
                )
            }
        }

        do {
            let clock = ContinuousClock()
            let started = clock.now
            await requestsReady.wait()
            let elapsed = started.duration(to: clock.now)
            #expect(elapsed < .seconds(4))
            releaseAcknowledgements.signal()

            for connection in connections {
                try await connection.value
            }
            try await server.value
        } catch {
            for connection in connections {
                connection.cancel()
            }
            server.cancel()
            for socket in sockets {
                _ = Darwin.shutdown(socket.client, SHUT_RDWR)
                _ = Darwin.shutdown(socket.server, SHUT_RDWR)
            }
            for connection in connections {
                _ = await connection.result
            }
            _ = await server.result
            throw error
        }
    }
}

private struct WireFrame: Codable, Sendable {
    let type: String
    let id: String?
    let port: UInt32?
    let message: String?
    let exitCode: Int32?
    let capabilities: [String]?

    init(
        type: String,
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

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

private final class BoundedTestIO: @unchecked Sendable {
    private typealias Operation = @Sendable () -> Void

    private let maximumConcurrentOperations: Int
    private let queue = DispatchQueue(
        label: "com.apple.container.guest-agent-port-forward-test-io",
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var activeOperationCount = 0
    private var pendingOperations: [Operation] = []

    init(maximumConcurrentOperations: Int = 4) {
        precondition(maximumConcurrentOperations > 0)
        self.maximumConcurrentOperations = maximumConcurrentOperations
    }

    func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            submit {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func runIgnoringErrors<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            submit {
                continuation.resume(returning: operation())
            }
        }
    }

    private func submit(_ operation: @escaping Operation) {
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

    private func dispatch(_ firstOperation: @escaping Operation) {
        queue.async { [self] in
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

private final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !signaled else {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func signal() {
        let continuation = lock.withLock {
            guard !signaled else {
                return nil as CheckedContinuation<Void, Never>?
            }
            signaled = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private func serveRawStream(fileDescriptor: Int32) throws {
    try writeFrame(
        WireFrame(type: "ready", capabilities: ["tcpConnectV1"]),
        fileDescriptor: fileDescriptor
    )
    let request = try readFrame(fileDescriptor: fileDescriptor)
    guard request.type == "tcpConnect", request.port == 18_080, let requestID = request.id else {
        throw FixtureError(description: "invalid tcpConnect request")
    }
    try writeFrame(WireFrame(type: "ack", id: requestID), fileDescriptor: fileDescriptor)

    let requestData = try readExact(fileDescriptor: fileDescriptor, count: 4)
    guard requestData == Data("ping".utf8) else {
        throw FixtureError(description: "invalid raw tunnel payload")
    }
    try writeAll(Data("pong".utf8), fileDescriptor: fileDescriptor)
}

private func coordinateConcurrentHandshakes(
    sockets: [Int32],
    gateAfterRequestCount: Int,
    requestsReady: OneShotSignal,
    releaseAcknowledgements: DispatchSemaphore
) throws {
    defer { requestsReady.signal() }
    for fileDescriptor in sockets {
        try writeFrame(
            WireFrame(type: "ready", capabilities: ["tcpConnectV1"]),
            fileDescriptor: fileDescriptor
        )
    }

    var pendingIndices = Set(sockets.indices)
    var gatedRequests: [(index: Int, requestID: String)] = []
    while gatedRequests.count < gateAfterRequestCount {
        let request = try readNextRequest(sockets: sockets, pendingIndices: &pendingIndices)
        gatedRequests.append(request)
    }

    requestsReady.signal()
    guard releaseAcknowledgements.wait(timeout: .now() + .seconds(5)) == .success else {
        throw FixtureError(description: "timed out waiting to release handshake acknowledgements")
    }
    for request in gatedRequests {
        try writeFrame(
            WireFrame(type: "ack", id: request.requestID),
            fileDescriptor: sockets[request.index]
        )
    }

    while !pendingIndices.isEmpty {
        let request = try readNextRequest(sockets: sockets, pendingIndices: &pendingIndices)
        try writeFrame(
            WireFrame(type: "ack", id: request.requestID),
            fileDescriptor: sockets[request.index]
        )
    }
}

private func readNextRequest(
    sockets: [Int32],
    pendingIndices: inout Set<Int>
) throws -> (index: Int, requestID: String) {
    let indices = Array(pendingIndices)
    var descriptors = indices.map {
        pollfd(fd: sockets[$0], events: Int16(POLLIN), revents: 0)
    }
    let pollResult = descriptors.withUnsafeMutableBufferPointer { buffer in
        Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), 2_000)
    }
    guard pollResult > 0 else {
        if pollResult == 0 {
            throw FixtureError(description: "timed out waiting for tcpConnect request")
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    for (offset, descriptor) in descriptors.enumerated()
    where (descriptor.revents & Int16(POLLIN)) != 0 {
        let index = indices[offset]
        let request = try readFrame(fileDescriptor: sockets[index])
        guard request.type == "tcpConnect", request.port == 18_080, let requestID = request.id else {
            throw FixtureError(description: "invalid concurrent tcpConnect request")
        }
        pendingIndices.remove(index)
        return (index, requestID)
    }
    throw FixtureError(description: "handshake socket closed before tcpConnect request")
}

private func makeSocketPair() throws -> (client: Int32, server: Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (client: descriptors[0], server: descriptors[1])
}

private func readFrame(fileDescriptor: Int32) throws -> WireFrame {
    let header = try readExact(fileDescriptor: fileDescriptor, count: MemoryLayout<UInt32>.size)
    let payloadLength = header.reduce(into: UInt32(0)) { value, byte in
        value = (value << 8) | UInt32(byte)
    }
    let payload = try readExact(fileDescriptor: fileDescriptor, count: Int(payloadLength))
    return try JSONDecoder().decode(WireFrame.self, from: payload)
}

private func writeFrame(_ frame: WireFrame, fileDescriptor: Int32) throws {
    let payload = try JSONEncoder().encode(frame)
    var length = UInt32(payload.count).bigEndian
    try writeAll(
        Data(bytes: &length, count: MemoryLayout<UInt32>.size),
        fileDescriptor: fileDescriptor
    )
    try writeAll(payload, fileDescriptor: fileDescriptor)
}

private func readExact(fileDescriptor: Int32, count: Int) throws -> Data {
    let now = DispatchTime.now().uptimeNanoseconds
    let (candidateDeadline, overflow) = now.addingReportingOverflow(fixtureInputTimeoutNanoseconds)
    let deadline = overflow ? UInt64.max : candidateDeadline
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        try waitForFixtureInput(fileDescriptor: fileDescriptor, deadline: deadline)
        let readCount = data.withUnsafeMutableBytes { buffer in
            Darwin.read(fileDescriptor, buffer.baseAddress?.advanced(by: offset), count - offset)
        }
        if readCount > 0 {
            offset += readCount
            continue
        }
        if readCount < 0, errno == EINTR {
            continue
        }
        throw POSIXError(POSIXErrorCode(rawValue: readCount == 0 ? ECONNRESET : errno) ?? .EIO)
    }
    return data
}

private func waitForFixtureInput(fileDescriptor: Int32, deadline: UInt64) throws {
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            throw FixtureError(description: "timed out waiting for fixture input")
        }
        let remainingNanoseconds = deadline - now
        let roundedMilliseconds = 1 + ((remainingNanoseconds - 1) / 1_000_000)
        let timeout = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
        var descriptor = pollfd(
            fd: fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let pollResult = Darwin.poll(&descriptor, 1, timeout)
        if pollResult > 0 {
            guard (descriptor.revents & Int16(POLLNVAL)) == 0 else {
                throw POSIXError(.EBADF)
            }
            return
        }
        if pollResult == 0 {
            throw FixtureError(description: "timed out waiting for fixture input")
        }
        if errno == EINTR {
            continue
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func writeAll(_ data: Data, fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return
        }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(
                fileDescriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset
            )
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: written == 0 ? EIO : errno) ?? .EIO)
        }
    }
}

private func closeIfValid(_ fileDescriptor: Int32) {
    if fileDescriptor >= 0 {
        _ = Darwin.close(fileDescriptor)
    }
}
