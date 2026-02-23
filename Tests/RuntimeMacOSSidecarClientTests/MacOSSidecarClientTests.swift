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

#if os(macOS)
import Darwin
import Foundation
import Logging
import Testing

@testable import RuntimeMacOSSidecarShared
@testable import container_runtime_macos

struct MacOSSidecarClientTests {
    @Test
    func bootstrapAndProcessEventsFlowOverPersistentControlConnection() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        let events = LockedValue<[MacOSSidecarEvent]>([])
        let eventSemaphore = DispatchSemaphore(value: 0)

        server.start { clientFD in
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let start = try readRequest(from: clientFD)
            #expect(start.method == .processStart)
            #expect(start.processID == "proc-1")
            #expect(start.port == 27000)
            #expect(start.exec?.executable == "/bin/echo")
            try writeResponse(.success(requestID: start.requestID), to: clientFD)

            try writeEvent(.init(event: .processStdout, processID: "proc-1", data: Data("hello\n".utf8)), to: clientFD)
            try writeEvent(.init(event: .processExit, processID: "proc-1", exitCode: 0), to: clientFD)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        client.setEventHandler { event in
            events.withLock { $0.append(event) }
            eventSemaphore.signal()
        }

        try client.bootstrapStart(socketConnectRetries: 3)
        try client.processStart(
            port: 27000,
            processID: "proc-1",
            request: .init(executable: "/bin/echo", arguments: ["hello"])
        )

        #expect(eventSemaphore.wait(timeout: .now() + 2) == .success)
        #expect(eventSemaphore.wait(timeout: .now() + 2) == .success)

        let received = events.withLock { $0 }
        #expect(received.contains(where: { $0.event == .processStdout && $0.data == Data("hello\n".utf8) }))
        #expect(received.contains(where: { $0.event == .processExit && $0.exitCode == 0 }))

        try server.waitForCompletion()
    }

    @Test
    func connectVsockReceivesTransferredFileDescriptor() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let request = try readRequest(from: clientFD)
            #expect(request.method == .vmConnectVsock)
            #expect(request.port == 27000)

            var pipeFDs = [Int32](repeating: -1, count: 2)
            #expect(Darwin.pipe(&pipeFDs) == 0)
            let readFD = pipeFDs[0]
            let writeFD = pipeFDs[1]
            defer {
                closeIfValid(readFD)
                closeIfValid(writeFD)
            }

            try MacOSSidecarSocketIO.sendFileDescriptorMarker(socketFD: clientFD, descriptorFD: readFD)
            try writeResponse(.success(requestID: request.requestID, fdAttached: true), to: clientFD)

            try writeAll(Data("vsock-fd".utf8), fd: writeFD)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        let fd = try client.connectVsock(port: 27000)
        defer { closeIfValid(fd) }

        let data = try MacOSSidecarSocketIO.readExact(fd: fd, count: 8)
        #expect(String(data: data, encoding: .utf8) == "vsock-fd")

        try server.waitForCompletion()
    }

    @Test
    func matchesOutOfOrderResponsesByRequestID() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let req1 = try readRequest(from: clientFD)
            let req2 = try readRequest(from: clientFD)
            #expect(Set([req1.method, req2.method]) == Set([.processClose, .processSignal]))

            // Intentionally reverse response order to validate requestID correlation.
            try writeResponse(.success(requestID: req2.requestID), to: clientFD)
            try writeResponse(.success(requestID: req1.requestID), to: clientFD)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        try client.bootstrapStart(socketConnectRetries: 3)

        let result1 = LockedValue<Error?>(nil)
        let result2 = LockedValue<Error?>(nil)
        let done1 = DispatchSemaphore(value: 0)
        let done2 = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            defer { done1.signal() }
            do {
                try client.processClose(processID: "proc-close")
            } catch {
                result1.withLock { $0 = error }
            }
        }
        Thread.detachNewThread {
            defer { done2.signal() }
            do {
                try client.processSignal(processID: "proc-signal", signal: 15)
            } catch {
                result2.withLock { $0 = error }
            }
        }

        #expect(done1.wait(timeout: .now() + 2) == .success)
        #expect(done2.wait(timeout: .now() + 2) == .success)
        #expect(result1.withLock { $0 == nil })
        #expect(result2.withLock { $0 == nil })

        try server.waitForCompletion()
    }
}

private final class FakeUnixSidecarTestServer: @unchecked Sendable {
    private let socketPath: String
    private let stateLock = NSLock()
    private var listenFD: Int32
    private let errorBox = LockedValue<Error?>(nil)
    private let done = DispatchSemaphore(value: 0)
    private let activeClientFD = LockedValue<Int32?>(nil)
    private let started = LockedValue<Bool>(false)

    init(socketPath: String) throws {
        self.socketPath = socketPath
        self.listenFD = try makeUnixListener(path: socketPath)
    }

    func start(_ handler: @Sendable @escaping (Int32) throws -> Void) {
        let wasStarted = started.withLock { value -> Bool in
            let old = value
            value = true
            return old
        }
        precondition(!wasStarted, "server can only be started once")

        Thread.detachNewThread { [self] in
            defer { done.signal() }
            do {
                let clientFD = Darwin.accept(listenFD, nil, nil)
                guard clientFD >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                activeClientFD.withLock { $0 = clientFD }
                defer {
                    activeClientFD.withLock { fd in
                        if fd == clientFD { fd = nil }
                    }
                    Darwin.close(clientFD)
                }
                try handler(clientFD)
            } catch {
                errorBox.withLock { $0 = error }
            }
        }
    }

    func waitForCompletion(timeout: TimeInterval = 2.0) throws {
        let result = done.wait(timeout: .now() + timeout)
        guard result == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = errorBox.withLock({ $0 }) {
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        let listenFD = self.listenFD
        self.listenFD = -1
        stateLock.unlock()

        activeClientFD.withLock { fd in
            if let fd, fd >= 0 {
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
            fd = nil
        }
        if listenFD >= 0 {
            _ = Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
        }
        _ = unlink(socketPath)
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func readRequest(from fd: Int32) throws -> MacOSSidecarRequest {
    let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: fd)
    #expect(envelope.kind == .request)
    return try #require(envelope.request)
}

private func writeResponse(_ response: MacOSSidecarResponse, to fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.response(response), fd: fd)
}

private func writeEvent(_ event: MacOSSidecarEvent, to fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.event(event), fd: fd)
}

private func makeTemporarySocketPath() throws -> String {
    let suffix = UUID().uuidString.prefix(8)
    return "/tmp/sidecar-client-\(suffix).sock"
}

private func makeUnixListener(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    _ = unlink(path)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let maxPathCount = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < maxPathCount else {
        Darwin.close(fd)
        throw POSIXError(.ENAMETOOLONG)
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
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        throw error
    }
    guard Darwin.listen(fd, 8) == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        throw error
    }
    return fd
}

private func writeAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let n = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
            if n > 0 {
                offset += n
                continue
            }
            if n == 0 {
                throw POSIXError(.EIO)
            }
            let code = errno
            if code == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

private func closeIfValid(_ fd: Int32?) {
    guard let fd, fd >= 0 else { return }
    Darwin.close(fd)
}
#endif
