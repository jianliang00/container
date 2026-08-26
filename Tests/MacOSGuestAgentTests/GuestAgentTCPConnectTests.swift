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
import RuntimeMacOSSidecarShared
import Testing

@testable import container_macos_guest_agent

@Suite(.serialized)
struct GuestAgentTCPConnectTests {
    @Test
    func relaysServerFirstResponseOverIPv6Loopback() throws {
        signal(SIGPIPE, SIG_IGN)
        let server = try LoopbackTCPServer(family: AF_INET6)
        server.start { connectionFD in
            try testWriteAll(Data("server-first".utf8), to: connectionFD)
        }

        let harness = try TCPAgentConnectionHarness()
        defer { harness.closePeer() }
        try openTunnel(harness, id: "server-first", port: server.port)

        let response = try readExactWithTimeout(from: harness.peerFD, count: 12)
        #expect(response == Data("server-first".utf8))

        try server.waitForCompletion()
        try harness.waitForCompletion()
    }

    @Test
    func relaysClientBytesOverIPv4Fallback() throws {
        signal(SIGPIPE, SIG_IGN)
        let server = try LoopbackTCPServer(family: AF_INET)
        server.start { connectionFD in
            let request = try readExactWithTimeout(from: connectionFD, count: 4)
            try testWriteAll(Data("reply:".utf8) + request, to: connectionFD)
        }

        let harness = try TCPAgentConnectionHarness()
        defer { harness.closePeer() }
        try openTunnel(harness, id: "client-bytes", port: server.port)

        try testWriteAll(Data("ping".utf8), to: harness.peerFD)
        let response = try readExactWithTimeout(from: harness.peerFD, count: 10)
        #expect(response == Data("reply:ping".utf8))

        try server.waitForCompletion()
        try harness.waitForCompletion()
    }

    @Test
    func clientHalfCloseStillReceivesServerResponse() throws {
        signal(SIGPIPE, SIG_IGN)
        let server = try LoopbackTCPServer(family: AF_INET6)
        server.start { connectionFD in
            let request = try readUntilEOFWithTimeout(from: connectionFD)
            #expect(request == Data("request".utf8))
            usleep(100_000)
            try testWriteAll(Data("after-eof".utf8), to: connectionFD)
        }

        let harness = try TCPAgentConnectionHarness(relayPeerStateCheckInterval: 0.02)
        defer { harness.closePeer() }
        try openTunnel(harness, id: "half-close", port: server.port)

        try testWriteAll(Data("request".utf8), to: harness.peerFD)
        #expect(Darwin.shutdown(harness.peerFD, SHUT_WR) == 0)
        let response = try readExactWithTimeout(from: harness.peerFD, count: 9)
        #expect(response == Data("after-eof".utf8))

        try server.waitForCompletion()
        try harness.waitForCompletion()
    }

    @Test
    func explicitHalfCloseIdleTimeoutReleasesSilentBackend() throws {
        signal(SIGPIPE, SIG_IGN)
        let serverRelease = DispatchSemaphore(value: 0)
        let server = try LoopbackTCPServer(family: AF_INET6)
        server.start { connectionFD in
            _ = try readUntilEOFWithTimeout(from: connectionFD)
            _ = serverRelease.wait(timeout: .now() + 2)
        }

        let harness = try TCPAgentConnectionHarness(relayHalfCloseIdleTimeout: 0.05)
        defer {
            harness.closePeer()
            serverRelease.signal()
        }
        try openTunnel(harness, id: "silent-half-close", port: server.port)

        #expect(Darwin.shutdown(harness.peerFD, SHUT_WR) == 0)
        try harness.waitForAgentCompletion(timeout: 1)
        try expectEOFWithTimeout(from: harness.peerFD)

        serverRelease.signal()
        try server.waitForCompletion()
    }

    @Test
    func completeClientCloseReleasesSilentBackend() throws {
        signal(SIGPIPE, SIG_IGN)
        let serverObservedEOF = DispatchSemaphore(value: 0)
        let serverRelease = DispatchSemaphore(value: 0)
        let server = try LoopbackTCPServer(family: AF_INET6)
        server.start { connectionFD in
            _ = try readUntilEOFWithTimeout(from: connectionFD)
            serverObservedEOF.signal()
            guard serverRelease.wait(timeout: .now() + 2) == .success else {
                throw POSIXError(.ETIMEDOUT)
            }
        }

        let harness = try TCPAgentConnectionHarness(relayPeerStateCheckInterval: 0.02)
        defer {
            harness.closePeer()
            serverRelease.signal()
        }
        try openTunnel(harness, id: "full-close", port: server.port)

        #expect(Darwin.shutdown(harness.peerFD, SHUT_WR) == 0)
        #expect(serverObservedEOF.wait(timeout: .now() + 1) == .success)
        #expect(!harness.hasCompleted)
        harness.closePeer()
        try harness.waitForAgentCompletion(timeout: 1)

        serverRelease.signal()
        try server.waitForCompletion()
    }

    @Test
    func connectionErrorClosesOwnedFDWithoutClosingReusedDescriptor() throws {
        signal(SIGPIPE, SIG_IGN)
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError.fromErrno()
        }
        let minimum = try guestAgentHighDescriptorMinimum()
        let ownedFD = Darwin.fcntl(descriptors[0], F_DUPFD_CLOEXEC, minimum)
        let duplicateErrno = errno
        closeTestFD(descriptors[0])
        guard ownedFD >= 0 else {
            closeTestFD(descriptors[1])
            throw POSIXError(POSIXErrorCode(rawValue: duplicateErrno) ?? .EIO)
        }
        closeTestFD(descriptors[1])

        var connection: AgentConnection? = AgentConnection(fd: ownedFD)
        do {
            try connection?.run()
            Issue.record("expected ready write to fail after the peer closed")
        } catch {
            // Expected. The assertion below verifies cleanup ran before the error escaped.
        }
        let closedDescriptorStatus = fcntl(ownedFD, F_GETFD)
        let closedDescriptorErrno = errno
        #expect(closedDescriptorStatus == -1)
        #expect(closedDescriptorErrno == EBADF)

        let sourceFD = Darwin.open("/dev/null", O_RDONLY)
        guard sourceFD >= 0 else {
            throw POSIXError.fromErrno()
        }
        defer { closeTestFD(sourceFD) }
        let reusedFD = Darwin.fcntl(sourceFD, F_DUPFD_CLOEXEC, ownedFD)
        guard reusedFD >= 0 else {
            throw POSIXError.fromErrno()
        }
        guard reusedFD == ownedFD else {
            closeTestFD(reusedFD)
            throw POSIXError(.EBUSY)
        }
        defer { closeTestFD(reusedFD) }

        connection = nil
        #expect(fcntl(reusedFD, F_GETFD) >= 0)
    }

    @Test
    func listenerAndAcceptedSocketsAreCloseOnExec() throws {
        let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listenFD >= 0 else {
            throw POSIXError.fromErrno()
        }
        defer { closeTestFD(listenFD) }

        try setGuestAgentCloseOnExec(listenFD)
        let listenFlags = fcntl(listenFD, F_GETFD)
        #expect(listenFlags >= 0)
        #expect((listenFlags & FD_CLOEXEC) != 0)
        let port = try bindLoopbackSocket(listenFD, family: AF_INET, port: 0)
        guard Darwin.listen(listenFD, 1) == 0 else {
            throw POSIXError.fromErrno()
        }

        let clientFD = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard clientFD >= 0 else {
            throw POSIXError.fromErrno()
        }
        defer { closeTestFD(clientFD) }
        try connectIPv4LoopbackSocket(clientFD, port: port)

        let acceptedFD = try acceptGuestAgentConnection(
            from: listenFD,
            address: nil,
            addressLength: nil
        )
        defer { closeTestFD(acceptedFD) }
        let acceptedFlags = fcntl(acceptedFD, F_GETFD)
        #expect(acceptedFlags >= 0)
        #expect((acceptedFlags & FD_CLOEXEC) != 0)
    }

    @Test
    func rejectsOutOfRangePort() throws {
        try expectTCPConnectError(port: 0, messageFragment: "between 1 and 65535")
        try expectTCPConnectError(port: 65_536, messageFragment: "between 1 and 65535")
    }

    @Test
    func reportsLoopbackConnectionFailure() throws {
        let reservation = try ClosedLoopbackPortReservation()
        let harness = try TCPAgentConnectionHarness()
        defer { harness.closePeer() }
        try withExtendedLifetime(reservation) {
            let ready = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
            #expect(ready.type == .ready)
            #expect(ready.capabilities?.contains("tcpConnectV1") == true)
            try MacOSSidecarSocketIO.writeJSONFrame(
                GuestAgentFrame(type: .tcpConnect, id: "closed-port", port: reservation.port),
                fd: harness.peerFD
            )

            let error = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
            #expect(error.type == .error)
            #expect(error.id == "closed-port")
            #expect(error.message?.contains("failed to connect to loopback TCP port") == true)
            try harness.waitForCompletion()
        }
    }

    private func expectTCPConnectError(port: UInt32, messageFragment: String) throws {
        let harness = try TCPAgentConnectionHarness()
        defer { harness.closePeer() }

        let ready = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
        #expect(ready.type == .ready)
        #expect(ready.capabilities?.contains("tcpConnectV1") == true)
        let requestID = "invalid-\(port)"
        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(type: .tcpConnect, id: requestID, port: port),
            fd: harness.peerFD
        )

        let error = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
        #expect(error.type == .error)
        #expect(error.id == requestID)
        #expect(error.message?.contains(messageFragment) == true)
        try harness.waitForCompletion()
    }
}

private func guestAgentHighDescriptorMinimum() throws -> Int32 {
    var limit = rlimit()
    guard Darwin.getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
        throw POSIXError.fromErrno()
    }
    let cappedLimit = min(limit.rlim_cur, rlim_t(32_768))
    guard cappedLimit > 96 else {
        throw POSIXError(.EMFILE)
    }
    return Int32(cappedLimit - 64)
}

private func openTunnel(_ harness: TCPAgentConnectionHarness, id: String, port: UInt32) throws {
    let ready = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
    #expect(ready.type == .ready)
    #expect(ready.capabilities?.contains("tcpConnectV1") == true)
    try MacOSSidecarSocketIO.writeJSONFrame(
        GuestAgentFrame(type: .tcpConnect, id: id, port: port),
        fd: harness.peerFD
    )
    let ack = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
    #expect(ack.type == .ack)
    #expect(ack.id == id)
}

private final class TCPAgentConnectionHarness: @unchecked Sendable {
    let peerFD: Int32

    private let done = DispatchSemaphore(value: 0)
    private let errorBox = TCPTestLockedValue<Error?>(nil)
    private let peerBox: TCPTestLockedValue<Int32?>
    private let completedBox = TCPTestLockedValue(false)

    init(
        relayHalfCloseIdleTimeout: TimeInterval? = nil,
        relayPeerStateCheckInterval: TimeInterval = 1
    ) throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError.fromErrno()
        }
        let serverFD = descriptors[0]
        self.peerFD = descriptors[1]
        self.peerBox = TCPTestLockedValue(descriptors[1])

        Thread.detachNewThread {
            defer {
                self.completedBox.withLock { $0 = true }
                self.done.signal()
            }
            do {
                try AgentConnection(
                    fd: serverFD,
                    relayHalfCloseIdleTimeout: relayHalfCloseIdleTimeout,
                    relayPeerStateCheckInterval: relayPeerStateCheckInterval
                ).run()
            } catch {
                self.errorBox.withLock { $0 = error }
            }
        }
    }

    var hasCompleted: Bool {
        completedBox.withLock { $0 }
    }

    func closePeer() {
        closeTestFD(
            peerBox.withLock { current in
                let descriptor = current
                current = nil
                return descriptor
            })
    }

    func waitForCompletion(timeout: TimeInterval = 3) throws {
        closePeer()
        try waitForAgentCompletion(timeout: timeout)
    }

    func waitForAgentCompletion(timeout: TimeInterval = 3) throws {
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = errorBox.withLock({ $0 }) {
            throw error
        }
    }
}

private final class LoopbackTCPServer: @unchecked Sendable {
    let port: UInt32

    private let listenFD: Int32
    private let done = DispatchSemaphore(value: 0)
    private let errorBox = TCPTestLockedValue<Error?>(nil)

    init(family: Int32) throws {
        let descriptor = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw POSIXError.fromErrno()
        }
        self.listenFD = descriptor

        do {
            self.port = try bindLoopbackSocket(descriptor, family: family, port: 0)
            guard Darwin.listen(descriptor, 1) == 0 else {
                throw POSIXError.fromErrno()
            }
        } catch {
            closeTestFD(descriptor)
            throw error
        }
    }

    deinit {
        closeTestFD(listenFD)
    }

    func start(_ handler: @escaping @Sendable (Int32) throws -> Void) {
        Thread.detachNewThread {
            defer { self.done.signal() }
            do {
                let connectionFD = try acceptTestConnection(from: self.listenFD)
                defer { closeTestFD(connectionFD) }
                try handler(connectionFD)
            } catch {
                self.errorBox.withLock { $0 = error }
            }
        }
    }

    func waitForCompletion(timeout: TimeInterval = 3) throws {
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = errorBox.withLock({ $0 }) {
            throw error
        }
    }
}

private final class ClosedLoopbackPortReservation {
    let port: UInt32

    private let ipv6FD: Int32
    private let ipv4FD: Int32

    init() throws {
        let reservation = try Self.reserveBothFamilies()
        self.port = reservation.port
        self.ipv6FD = reservation.ipv6FD
        self.ipv4FD = reservation.ipv4FD
    }

    deinit {
        closeTestFD(ipv4FD)
        closeTestFD(ipv6FD)
    }

    private static func reserveBothFamilies() throws -> (
        port: UInt32,
        ipv6FD: Int32,
        ipv4FD: Int32
    ) {
        for _ in 0..<32 {
            let ipv4FD = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard ipv4FD >= 0 else {
                throw POSIXError.fromErrno()
            }

            do {
                let port = try bindLoopbackSocket(ipv4FD, family: AF_INET, port: 0)
                let ipv6FD = Darwin.socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
                guard ipv6FD >= 0 else {
                    throw POSIXError.fromErrno()
                }
                var ownsIPv6FD = true
                defer {
                    if ownsIPv6FD {
                        closeTestFD(ipv6FD)
                    }
                }
                var ipv6Only: Int32 = 1
                guard
                    setsockopt(
                        ipv6FD,
                        IPPROTO_IPV6,
                        IPV6_V6ONLY,
                        &ipv6Only,
                        socklen_t(MemoryLayout<Int32>.size)
                    ) == 0
                else {
                    throw POSIXError.fromErrno()
                }
                _ = try bindLoopbackSocket(ipv6FD, family: AF_INET6, port: port)
                ownsIPv6FD = false
                return (port: port, ipv6FD: ipv6FD, ipv4FD: ipv4FD)
            } catch let error as POSIXError where error.code == .EADDRINUSE {
                closeTestFD(ipv4FD)
                continue
            } catch {
                closeTestFD(ipv4FD)
                throw error
            }
        }
        throw POSIXError(.EADDRINUSE)
    }
}

private final class TCPTestLockedValue<T>: @unchecked Sendable {
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

private func bindLoopbackSocket(_ fd: Int32, family: Int32, port: UInt32) throws -> UInt32 {
    switch family {
    case AF_INET:
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError.fromErrno()
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard
            withUnsafeMutablePointer(
                to: &address,
                { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(fd, $0, &length)
                    }
                }) == 0
        else {
            throw POSIXError.fromErrno()
        }
        return UInt32(UInt16(bigEndian: address.sin_port))
    case AF_INET6:
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port).bigEndian)
        address.sin6_addr = in6addr_loopback
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError.fromErrno()
        }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        guard
            withUnsafeMutablePointer(
                to: &address,
                { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(fd, $0, &length)
                    }
                }) == 0
        else {
            throw POSIXError.fromErrno()
        }
        return UInt32(UInt16(bigEndian: address.sin6_port))
    default:
        throw POSIXError(.EAFNOSUPPORT)
    }
}

private func acceptTestConnection(from listenFD: Int32) throws -> Int32 {
    while true {
        let connectionFD = Darwin.accept(listenFD, nil, nil)
        if connectionFD >= 0 {
            return connectionFD
        }
        if errno == EINTR {
            continue
        }
        throw POSIXError.fromErrno()
    }
}

private func connectIPv4LoopbackSocket(_ fd: Int32, port: UInt32) throws {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    while true {
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            return
        }
        if errno == EINTR {
            continue
        }
        throw POSIXError.fromErrno()
    }
}

private func readExactWithTimeout(from fd: Int32, count: Int, timeoutMilliseconds: Int32 = 2_000) throws -> Data {
    var result = Data()
    while result.count < count {
        try waitForReadable(fd, timeoutMilliseconds: timeoutMilliseconds)
        var buffer = [UInt8](repeating: 0, count: count - result.count)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead > 0 {
            result.append(contentsOf: buffer.prefix(bytesRead))
            continue
        }
        if bytesRead == 0 {
            throw POSIXError(.ECONNRESET)
        }
        if errno == EINTR {
            continue
        }
        throw POSIXError.fromErrno()
    }
    return result
}

private func readUntilEOFWithTimeout(from fd: Int32, timeoutMilliseconds: Int32 = 2_000) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        try waitForReadable(fd, timeoutMilliseconds: timeoutMilliseconds)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead > 0 {
            result.append(contentsOf: buffer.prefix(bytesRead))
            continue
        }
        if bytesRead == 0 {
            return result
        }
        if errno == EINTR {
            continue
        }
        throw POSIXError.fromErrno()
    }
}

private func expectEOFWithTimeout(from fd: Int32, timeoutMilliseconds: Int32 = 1_000) throws {
    while true {
        try waitForReadable(fd, timeoutMilliseconds: timeoutMilliseconds)
        var byte: UInt8 = 0
        let bytesRead = Darwin.read(fd, &byte, MemoryLayout<UInt8>.size)
        if bytesRead == 0 {
            return
        }
        if bytesRead > 0 {
            throw POSIXError(.EIO)
        }
        if errno == EINTR {
            continue
        }
        throw POSIXError.fromErrno()
    }
}

private func waitForReadable(_ fd: Int32, timeoutMilliseconds: Int32) throws {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
        if result > 0 {
            return
        }
        if result == 0 {
            throw POSIXError(.ETIMEDOUT)
        }
        if errno == EINTR {
            continue
        }
        throw POSIXError.fromErrno()
    }
}

private func testWriteAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                throw POSIXError(.EPIPE)
            }
            if errno == EINTR {
                continue
            }
            throw POSIXError.fromErrno()
        }
    }
}

private func closeTestFD(_ fd: Int32?) {
    guard let fd, fd >= 0 else { return }
    _ = Darwin.close(fd)
}
#endif
