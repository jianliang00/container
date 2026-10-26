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

    @Test
    func executableNameSearchesPathEnvironment() throws {
        signal(SIGPIPE, SIG_IGN)

        let harness = try AgentConnectionHarness()
        defer { harness.closePeer() }

        let ready = try readAgentFrame(from: harness.peerFD)
        #expect(ready.type == .ready)

        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(
                type: .exec,
                id: "path-search",
                executable: "sh",
                arguments: ["-c", "printf path-search-ok"],
                environment: ["PATH=/bin:/usr/bin"],
                workingDirectory: "/",
                terminal: false,
                uid: UInt32(geteuid()),
                gid: UInt32(getegid())
            ),
            fd: harness.peerFD
        )

        var frames: [GuestAgentFrame] = []
        for _ in 0..<8 {
            let frame = try readAgentFrame(from: harness.peerFD)
            frames.append(frame)
            if frames.contains(where: { $0.type == .ack }) && frames.contains(where: { $0.type == .exit }) {
                break
            }
        }

        #expect(frames.contains(where: { $0.type == .ack && $0.id == "path-search" }))
        #expect(frames.contains(where: { $0.type == .stdout && $0.data == Data("path-search-ok".utf8) }))
        #expect(frames.contains(where: { $0.type == .exit && $0.exitCode == 0 }))
        #expect(!frames.contains(where: { $0.type == .error }))

        try harness.waitForCompletion()
    }

    @Test
    func fastProcessSendsAckBeforeExit() throws {
        signal(SIGPIPE, SIG_IGN)

        let harness = try AgentConnectionHarness()
        defer { harness.closePeer() }

        let ready = try readAgentFrame(from: harness.peerFD)
        #expect(ready.type == .ready)

        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(
                type: .exec,
                id: "fast-process",
                executable: "/bin/echo",
                arguments: ["fast-ok"],
                environment: ["PATH=/usr/bin:/bin"],
                workingDirectory: "/",
                terminal: false,
                uid: UInt32(geteuid()),
                gid: UInt32(getegid())
            ),
            fd: harness.peerFD
        )

        var frames: [GuestAgentFrame] = []
        for _ in 0..<6 {
            let frame = try readAgentFrame(from: harness.peerFD)
            frames.append(frame)
            if frames.contains(where: { $0.type == .ack }) && frames.contains(where: { $0.type == .exit }) {
                break
            }
        }

        let ackIndex = try #require(frames.firstIndex(where: { $0.type == .ack }))
        let exitIndex = try #require(frames.firstIndex(where: { $0.type == .exit }))
        #expect(frames[ackIndex].id == "fast-process")
        #expect(ackIndex < exitIndex)

        try harness.waitForCompletion()
    }

    @Test
    func peerDisconnectDuringProcessExitDoesNotCrashAgent() throws {
        signal(SIGPIPE, SIG_IGN)

        for iteration in 0..<24 {
            let harness = try AgentConnectionHarness()
            let ready = try readAgentFrame(from: harness.peerFD)
            #expect(ready.type == .ready)

            try MacOSSidecarSocketIO.writeJSONFrame(
                GuestAgentFrame(
                    type: .exec,
                    id: "disconnect-during-exit-\(iteration)",
                    executable: "/bin/sh",
                    arguments: ["-c", "printf output; printf error >&2; exit 28"],
                    environment: ["PATH=/usr/bin:/bin"],
                    workingDirectory: "/",
                    terminal: false,
                    uid: UInt32(geteuid()),
                    gid: UInt32(getegid())
                ),
                fd: harness.peerFD
            )

            let ack = try readAgentFrame(from: harness.peerFD)
            #expect(ack.type == .ack)
            harness.closePeer()
            try harness.waitForCompletion()
        }
    }

    @Test
    func signalStopsShellChildProcessGroup() throws {
        signal(SIGPIPE, SIG_IGN)

        let harness = try AgentConnectionHarness()
        defer { harness.closePeer() }

        let ready = try readAgentFrame(from: harness.peerFD)
        #expect(ready.type == .ready)

        let processID = "signal-process-group"
        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(
                type: .exec,
                id: processID,
                executable: "/bin/sh",
                arguments: ["-c", "echo child-started; sleep 30"],
                environment: ["PATH=/usr/bin:/bin"],
                workingDirectory: "/",
                terminal: false,
                uid: UInt32(geteuid()),
                gid: UInt32(getegid())
            ),
            fd: harness.peerFD
        )

        var receivedAck = false
        for _ in 0..<4 {
            let frame = try readAgentFrame(from: harness.peerFD)
            if frame.type == .ack {
                receivedAck = true
                #expect(frame.id == processID)
                break
            }
        }
        #expect(receivedAck)

        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(type: .signal, id: processID, signal: SIGKILL),
            fd: harness.peerFD
        )

        var receivedExit = false
        for _ in 0..<8 {
            let frame = try readAgentFrame(from: harness.peerFD)
            if frame.type == .exit {
                receivedExit = true
                break
            }
        }
        #expect(receivedExit)

        try harness.waitForCompletion()
    }
    @Test
    func normalOutputRemainsCompleteAndPrecedesExit() throws {
        let harness = try AgentConnectionHarness()
        defer { harness.closePeer() }
        _ = try readAgentFrame(from: harness.peerFD)
        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(
                type: .exec, id: "complete-output", executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/head -c 1048576 /dev/zero; /usr/bin/head -c 1048576 /dev/zero >&2; exit 23"],
                environment: ["PATH=/usr/bin:/bin"], terminal: false), fd: harness.peerFD)
        let frames = try readThroughExit(fd: harness.peerFD)
        for channel in [GuestAgentFrame.FrameType.stdout, .stderr] {
            let bytes = frames.filter { $0.type == channel }.reduce(into: Data()) { $0.append($1.data ?? Data()) }
            #expect(bytes == Data(repeating: 0, count: 1024 * 1024))
        }
        #expect(frames.first?.type == .ack)
        #expect(frames.last?.exitCode == 23)
        try harness.waitForCompletion()
    }

    @Test
    func unreadOutputDoesNotBlockChildCompletion() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let harness = try AgentConnectionHarness(outputBufferCapacity: 64 * 1024)
        defer { harness.closePeer() }
        _ = try readAgentFrame(from: harness.peerFD)
        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(
                type: .exec, id: "unread-output", executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/head -c 8388608 /dev/zero; printf done > \"$1\"; exit 23", "sh", marker.path],
                environment: ["PATH=/usr/bin:/bin"], terminal: false), fd: harness.peerFD)
        #expect(try readAgentFrame(from: harness.peerFD).type == .ack)

        // No socket reads until the child has finished writing 8 MiB to its pipe.
        try waitForFile(marker)
        let frames = try readThroughExit(fd: harness.peerFD)
        #expect(frames.last?.exitCode == 23)
        #expect(frames.contains { $0.type == .stderr && String(data: $0.data ?? Data(), encoding: .utf8)?.contains("output truncated") == true })
        #expect(frames.reduce(0) { $0 + ($1.data?.count ?? 0) } < 8_388_608)
        try harness.waitForCompletion()
    }

    @Test
    func signalIsHandledWhileOutputReaderIsPaused() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let harness = try AgentConnectionHarness(outputBufferCapacity: 64 * 1024)
        defer { harness.closePeer() }
        _ = try readAgentFrame(from: harness.peerFD)
        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(
                type: .exec, id: "signal-backpressure", executable: "/bin/sh",
                arguments: ["-c", "echo $$ > \"$1\"; /usr/bin/yes output", "sh", marker.path],
                environment: ["PATH=/usr/bin:/bin"], terminal: false), fd: harness.peerFD)
        #expect(try readAgentFrame(from: harness.peerFD).type == .ack)
        try waitForFile(marker)
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(pid > 1)
        usleep(200_000)
        try MacOSSidecarSocketIO.writeJSONFrame(GuestAgentFrame(type: .signal, signal: SIGKILL), fd: harness.peerFD)
        // Reaping must finish before the output reader resumes.
        let deadline = DispatchTime.now() + 2
        while Darwin.kill(pid, 0) == 0 {
            guard DispatchTime.now() < deadline else { throw POSIXError(.ETIMEDOUT) }
            usleep(10_000)
        }
        #expect(errno == ESRCH)
        let frames = try readThroughExit(fd: harness.peerFD)
        #expect(frames.last?.exitCode == 128 + SIGKILL)
        try harness.waitForCompletion()
    }

    @Test
    func backgroundChildDoesNotDelayExitIndefinitely() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: marker)
        }
        let harness = try AgentConnectionHarness(outputDrainTimeout: 0.1)
        defer { harness.closePeer() }
        _ = try readAgentFrame(from: harness.peerFD)
        try MacOSSidecarSocketIO.writeJSONFrame(
            GuestAgentFrame(
                type: .exec, id: "inherited-pipe", executable: "/bin/sh",
                arguments: ["-c", "sleep 30 & echo $! > \"$1\"; exit 37", "sh", marker.path],
                environment: ["PATH=/usr/bin:/bin"], terminal: false), fd: harness.peerFD)
        let start = DispatchTime.now()
        let frames = try readThroughExit(fd: harness.peerFD)
        #expect(frames.last?.exitCode == 37)
        #expect(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds < 2_000_000_000)
        try harness.waitForCompletion()
    }

    private func waitForFile(_ url: URL) throws {
        let deadline = DispatchTime.now() + 2
        while !FileManager.default.fileExists(atPath: url.path) {
            guard DispatchTime.now() < deadline else { throw POSIXError(.ETIMEDOUT) }
            usleep(10_000)
        }
    }

    private func readThroughExit(fd: Int32) throws -> [GuestAgentFrame] {
        var frames: [GuestAgentFrame] = []
        for _ in 0..<1024 {
            let frame = try readAgentFrame(from: fd)
            frames.append(frame)
            if frame.type == .exit { return frames }
        }
        throw POSIXError(.EOVERFLOW)
    }

}

extension GuestAgentProcessStartupTests {
    private final class AgentConnectionHarness: @unchecked Sendable {
        let peerFD: Int32

        private let done = DispatchSemaphore(value: 0)
        private let errorBox = LockedValue<Error?>(nil)
        private let peerBox: LockedValue<Int32?>

        init(outputBufferCapacity: Int = 4 * 1024 * 1024, outputDrainTimeout: TimeInterval = 1) throws {
            let pair = try makeSocketPair()
            self.peerFD = pair.peer
            self.peerBox = LockedValue(pair.peer)

            Thread.detachNewThread {
                defer { self.done.signal() }
                do {
                    try AgentConnection(fd: pair.server, outputBufferCapacity: outputBufferCapacity, outputDrainTimeout: outputDrainTimeout).run()
                } catch {
                    self.errorBox.withLock { $0 = error }
                }
            }
        }

        func closePeer() {
            let fd = peerBox.withLock { current in
                let fd = current
                current = nil
                return fd
            }
            if let fd { Darwin.shutdown(fd, SHUT_RDWR) }
            closeIfValid(fd)
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

private func readAgentFrame(from fd: Int32, timeoutMilliseconds: Int32 = 2_000) throws -> GuestAgentFrame {
    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let result = Darwin.poll(&pollFD, 1, timeoutMilliseconds)
    guard result > 0 else {
        if result == 0 {
            throw POSIXError(.ETIMEDOUT)
        }
        throw POSIXError.fromErrno()
    }
    return try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: fd)
}
#endif
