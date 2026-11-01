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
import ContainerizationError
import Darwin
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import container_runtime_macos_sidecar

@Suite(.serialized)
struct GuestAgentHandshakeTests {
    @Test(arguments: [Data(), Data([0, 0, 0, 20, 0x7b])])
    func retriesSilentOrPartialGreetingBeforeDispatch(prefix: Data) async throws {
        let fixture = Fixture()
        defer { fixture.closePeers() }
        let fd = try await GuestAgentHandshake.connect(
            timeoutSeconds: 1, attemptTimeoutSeconds: 0.05,
            connect: { _ in
                let attempt = fixture.count
                if attempt == 1 {
                    // The failed stream must be closed before another opens.
                    fixture.expectClosedPeer(fixture.firstPeer)
                }
                let pair = try fixture.makePair()
                if attempt == 0 {
                    try MacOSSidecarSocketIO.writeAll(data: prefix, fd: pair.peer)
                } else {
                    try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame(type: .ready), fd: pair.peer)
                }
                return pair.client
            }
        )
        defer { Darwin.close(fd) }
        #expect(fixture.count == 2)
        #expect(fcntl(fd, F_GETFD) >= 0)
        try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame(type: .clockSync), fd: fd)
        let request = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fixture.lastPeer, timeoutMilliseconds: 100)
        #expect(request.type == .clockSync)
    }

    @Test
    func retriesConnectionResetBeforeReady() async throws {
        let fixture = Fixture()
        defer { fixture.closePeers() }
        let calls = Counter()
        let fd = try await GuestAgentHandshake.connect(timeoutSeconds: 1) { _ in
            if calls.increment() == 1 { throw POSIXError(.ECONNRESET) }
            let pair = try fixture.makePair()
            try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame(type: .ready), fd: pair.peer)
            return pair.client
        }
        defer { Darwin.close(fd) }
        #expect(calls.value == 2)
    }

    @Test(arguments: [SidecarGuestAgentFrame(type: .error, message: "unsupported protocol"), SidecarGuestAgentFrame(type: .exit, exitCode: 1)])
    func rejectsGuestFailureWithoutRetry(frame: SidecarGuestAgentFrame) async throws {
        let fixture = Fixture()
        defer { fixture.closePeers() }
        do {
            _ = try await GuestAgentHandshake.connect(timeoutSeconds: 1) { _ in
                let pair = try fixture.makePair()
                try MacOSSidecarSocketIO.writeJSONFrame(frame, fd: pair.peer)
                return pair.client
            }
            Issue.record("expected guest failure")
        } catch let error as ContainerizationError {
            #expect(error.code == .internalError)
        }
        #expect(fixture.count == 1)
        fixture.expectClosedPeer(fixture.lastPeer)
    }

    @Test
    func rejectsMalformedGreetingWithoutRetry() async throws {
        let fixture = Fixture()
        defer { fixture.closePeers() }
        do {
            _ = try await GuestAgentHandshake.connect(timeoutSeconds: 1) { _ in
                let pair = try fixture.makePair()
                try MacOSSidecarSocketIO.writeFrame(Data("invalid JSON".utf8), fd: pair.peer)
                return pair.client
            }
            Issue.record("expected malformed greeting failure")
        } catch is DecodingError {}
        #expect(fixture.count == 1)
        fixture.expectClosedPeer(fixture.lastPeer)
    }

    @Test
    func connectAndGreetingShareAttemptAndTotalBudget() async throws {
        let fixture = Fixture()
        defer { fixture.closePeers() }
        let start = ContinuousClock.now
        do {
            _ = try await GuestAgentHandshake.connect(timeoutSeconds: 0.2, attemptTimeoutSeconds: 0.06) { timeout in
                #expect(timeout <= 0.06)
                try await Task.sleep(for: .seconds(min(0.04, timeout)))
                return try fixture.makePair().client
            }
            Issue.record("expected handshake timeout")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
        }
        #expect(start.duration(to: .now) < .seconds(0.5))
        #expect(fixture.count >= 2)
        fixture.expectClosedPeer(fixture.lastPeer)
    }

    @Test
    func cancellationClosesReturnedConnectionWithoutRetry() async throws {
        let fixture = Fixture()
        defer { fixture.closePeers() }
        let task = Task {
            try await GuestAgentHandshake.connect(timeoutSeconds: 1) { _ in
                let pair = try fixture.makePair()
                withUnsafeCurrentTask { $0?.cancel() }
                return pair.client
            }
        }
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {}
        #expect(fixture.count == 1)
        fixture.expectClosedPeer(fixture.lastPeer)
    }

    @Test
    func clockSynchronizationUsesRecoveredStreamOnce() async throws {
        let fixture = Fixture()
        defer { fixture.closePeers() }
        _ = try await MacOSGuestClockBootstrap.synchronize(
            timeoutSeconds: 1, handshakeAttemptTimeoutSeconds: 0.05,
            connect: { _ in
                let pair = try fixture.makePair()
                if fixture.count == 2 {
                    try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame(type: .ready), fd: pair.peer)
                    Thread.detachNewThread {
                        do {
                            let request = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: pair.peer, timeoutMilliseconds: 1_000)
                            #expect(request.type == .clockSync)
                            let time = try MacOSGuestClockBootstrap.sampleHostTime()
                            let result = MacOSGuestClockSyncResult(unixTimeSeconds: time.unixTimeSeconds, unixTimeNanoseconds: time.unixTimeNanoseconds)
                            try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame(type: .clockResult, data: JSONEncoder().encode(result)), fd: pair.peer)
                        } catch {
                            Issue.record(error)
                        }
                    }
                }
                return pair.client
            }
        )
        #expect(fixture.count == 2)
        fixture.expectClosedPeer(fixture.lastPeer)
    }

    @Test(arguments: ["silent", "error", "malformed"])
    func clockResultFailureDoesNotReconnectOrReplay(mode: String) async throws {
        let fixture = Fixture()
        defer { fixture.closePeers() }
        do {
            _ = try await MacOSGuestClockBootstrap.synchronize(timeoutSeconds: 0.15) { _ in
                let pair = try fixture.makePair()
                try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame(type: .ready), fd: pair.peer)
                if mode == "error" {
                    try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame(type: .error, message: "clock unavailable"), fd: pair.peer)
                } else if mode == "malformed" {
                    try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame(type: .clockResult, data: Data("{}".utf8)), fd: pair.peer)
                }
                return pair.client
            }
            Issue.record("expected clock synchronization failure")
        } catch let error as ContainerizationError {
            #expect(error.code == (mode == "silent" ? .timeout : .internalError))
        } catch is DecodingError {
            #expect(mode == "malformed")
        }
        #expect(fixture.count == 1)
        let request = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fixture.lastPeer, timeoutMilliseconds: 100)
        #expect(request.type == .clockSync)
        fixture.expectClosedPeer(fixture.lastPeer)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var peers: [Int32] = []
        var count: Int { lock.withLock { peers.count } }
        var firstPeer: Int32 { lock.withLock { peers.first! } }
        var lastPeer: Int32 { lock.withLock { peers.last! } }

        func makePair() throws -> (client: Int32, peer: Int32) {
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EMFILE) }
            lock.withLock {
                peers.append(fds[1])
            }
            return (fds[0], fds[1])
        }

        func expectClosedPeer(_ fd: Int32) {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            #expect(Darwin.poll(&descriptor, 1, 100) == 1)
            var byte: UInt8 = 0
            #expect(Darwin.recv(fd, &byte, 1, MSG_DONTWAIT) == 0)
        }

        func closePeers() {
            lock.withLock {
                for fd in peers { Darwin.close(fd) }
                peers.removeAll()
            }
        }
    }
}
#endif
