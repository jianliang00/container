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
struct GuestAgentProcessStartupTests {
    @Test
    func missingExecutableReportsErrorWithoutAck() throws {
        signal(SIGPIPE, SIG_IGN)

        let harness = try AgentConnectionHarness()
        defer { harness.closePeer() }

        let ready = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
        #expect(ready.type == .ready)

        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(
                type: .exec,
                id: "missing-executable",
                executable: "/path/does/not/exist",
                arguments: [],
                environment: ["PATH=/usr/bin:/bin"],
                workingDirectory: "/",
                terminal: false,
                uid: UInt32(geteuid()),
                gid: UInt32(getegid())
            ),
            fd: harness.peerFD
        )

        let first = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
        let second = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
        let frames = [first, second]

        #expect(frames.contains(where: { $0.type == .error }))
        #expect(frames.contains(where: { $0.type == .exit }))
        #expect(!frames.contains(where: { $0.type == .ack }))

        let errorFrame = try #require(frames.first(where: { $0.type == .error }))
        #expect(errorFrame.message?.contains("No such file or directory") == true)

        try harness.waitForCompletion()
    }

    @Test
    func successfulStartSendsAckBeforeExit() throws {
        signal(SIGPIPE, SIG_IGN)

        let harness = try AgentConnectionHarness()
        defer { harness.closePeer() }

        let ready = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
        #expect(ready.type == .ready)

        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(
                type: .exec,
                id: "successful-start",
                executable: "/bin/sh",
                arguments: ["-c", "sleep 0.1"],
                environment: ["PATH=/usr/bin:/bin"],
                workingDirectory: "/",
                terminal: false,
                uid: UInt32(geteuid()),
                gid: UInt32(getegid())
            ),
            fd: harness.peerFD
        )

        var receivedAck = false
        var receivedExit = false
        for _ in 0..<4 {
            let frame = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: harness.peerFD)
            switch frame.type {
            case .ack:
                receivedAck = true
                #expect(frame.id == "successful-start")
            case .exit:
                receivedExit = true
            default:
                break
            }
            if receivedAck && receivedExit {
                break
            }
        }

        #expect(receivedAck)
        #expect(receivedExit)

        try harness.waitForCompletion()
    }
}

extension GuestAgentProcessStartupTests {
    private final class AgentConnectionHarness: @unchecked Sendable {
        let peerFD: Int32

        private let done = DispatchSemaphore(value: 0)
        private let errorBox = LockedValue<Error?>(nil)
        private let peerBox: LockedValue<Int32?>

        init() throws {
            let pair = try makeSocketPair()
            self.peerFD = pair.peer
            self.peerBox = LockedValue(pair.peer)

            Thread.detachNewThread {
                defer { self.done.signal() }
                do {
                    try AgentConnection(fd: pair.server).run()
                } catch {
                    self.errorBox.withLock { $0 = error }
                }
            }
        }

        func closePeer() {
            closeIfValid(
                peerBox.withLock { current in
                    let fd = current
                    current = nil
                    return fd
                })
        }

        func waitForCompletion(timeout: TimeInterval = 2) throws {
            closePeer()
            guard done.wait(timeout: .now() + timeout) == .success else {
                throw POSIXError(.ETIMEDOUT)
            }
            if let error = errorBox.withLock({ $0 }) {
                throw error
            }
        }
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

private func makeSocketPair() throws -> (server: Int32, peer: Int32) {
    var fds = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (fds[0], fds[1])
}

private func closeIfValid(_ fd: Int32?) {
    guard let fd, fd >= 0 else { return }
    Darwin.close(fd)
}
#endif
