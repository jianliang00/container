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
import ContainerResource
import Foundation
import Logging
import RuntimeMacOSSidecarShared
import Testing

@testable import container_runtime_macos_sidecar

@Suite(.serialized)
struct SidecarControlServerTests {
    @Test
    func unknownMethodAndVersionMismatchReturnFramesWithoutClosingConnection() throws {
        let socketPath = "/tmp/runtime-macos-sidecar-protocol-\(UUID().uuidString).sock"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeMacOSSidecarProtocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeConfigurationWithInvalidStorage().write(to: root.appendingPathComponent("config.json"))
        let service = MacOSSidecarService(rootURL: root, log: Logger(label: "RuntimeMacOSSidecarTests"))
        let server = SidecarControlServer(
            socketPath: socketPath,
            service: service,
            log: Logger(label: "RuntimeMacOSSidecarTests")
        )
        try server.start()
        defer { server.stop() }
        let fd = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(fd) }

        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(
                .init(requestID: "unknown", method: .unknown("vm.future"), protocolVersion: 2)
            ),
            fd: fd
        )
        let unknown = try responseFrame(fd: fd)
        #expect(unknown.requestID == "unknown")
        #expect(unknown.error?.code == "unknownMethod")

        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(
                .init(requestID: "version", method: .vmPause, protocolVersion: 1)
            ),
            fd: fd
        )
        let version = try responseFrame(fd: fd)
        #expect(version.requestID == "version")
        #expect(version.error?.code == "protocolVersionMismatch")
        #expect(version.error?.metadata?["requiredVersion"] == "2")

        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(.init(requestID: "storage", method: .vmBootstrapStart)),
            fd: fd
        )
        let storage = try responseFrame(fd: fd)
        #expect(storage.requestID == "storage")
        #expect(storage.error?.code == "invalidStorageConfiguration")

        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(.init(requestID: "legacy-stop", method: .vmStop)),
            fd: fd
        )
        let legacyStop = try responseFrame(fd: fd)
        #expect(legacyStop.requestID == "legacy-stop")
        #expect(legacyStop.ok)
    }

    @Test
    func ownerDisconnectClosesOwnedFileTransferSessions() throws {
        let server = makeServer()
        defer { server._testCloseAllFSSessions() }

        let ownedPair = try makeSocketPair()
        let otherPair = try makeSocketPair()
        defer {
            closeIfValid(ownedPair.peer)
            closeIfValid(otherPair.peer)
        }

        try server._testRegisterFSSession(
            txID: "tx-owned",
            fd: ownedPair.server,
            ownerClientFD: 41,
            op: .writeFile,
            path: "/tmp/owned.txt"
        )
        try server._testRegisterFSSession(
            txID: "tx-other",
            fd: otherPair.server,
            ownerClientFD: 99,
            op: .writeFile,
            path: "/tmp/other.txt"
        )

        server._testCloseOwnedFSSessions(clientFD: 41)

        #expect(!server._testHasFSSession(txID: "tx-owned"))
        #expect(server._testHasFSSession(txID: "tx-other"))
        try expectEOF(fd: ownedPair.peer)
    }

    @Test
    func chunkFailureRemovesFileTransferSession() throws {
        signal(SIGPIPE, SIG_IGN)

        let server = makeServer()
        defer { server._testCloseAllFSSessions() }

        let pair = try makeSocketPair()
        let peerFD = LockedValue<Int32?>(pair.peer)
        defer {
            closeIfValid(
                peerFD.withLock { fd in
                    let current = fd
                    fd = nil
                    return current
                })
        }

        try server._testRegisterFSSession(
            txID: "tx-chunk",
            fd: pair.server,
            ownerClientFD: 7,
            op: .writeFile,
            path: "/tmp/chunked.txt"
        )

        let readerDone = DispatchSemaphore(value: 0)
        let readerError = LockedValue<Error?>(nil)
        let receivedFrame = LockedValue<SidecarGuestAgentFrame?>(nil)

        Thread.detachNewThread {
            defer { readerDone.signal() }
            do {
                guard let fd = peerFD.withLock({ $0 }) else {
                    throw POSIXError(.EBADF)
                }
                let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
                receivedFrame.withLock { $0 = frame }
                closeIfValid(
                    peerFD.withLock { current in
                        let fd = current
                        current = nil
                        return fd
                    })
            } catch {
                readerError.withLock { $0 = error }
            }
        }

        #expect(throws: Error.self) {
            try server._testSendFSChunk(.init(txID: "tx-chunk", offset: 0, data: Data("payload".utf8)))
        }

        #expect(readerDone.wait(timeout: .now() + 2) == .success)
        if let error = readerError.withLock({ $0 }) {
            throw error
        }

        let frame = try #require(receivedFrame.withLock { $0 })
        #expect(frame.type == .fsChunk)
        #expect(frame.id == "tx-chunk")
        #expect(frame.offset == 0)
        #expect(frame.data == Data("payload".utf8))
        #expect(!server._testHasFSSession(txID: "tx-chunk"))
    }

    @Test
    func processStartHandshakeBuffersEarlyOutputUntilAck() throws {
        let server = makeServer()
        let pair = try makeSocketPair()
        defer {
            closeIfValid(pair.server)
            closeIfValid(pair.peer)
        }

        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame(type: .stdout, data: Data("early-output\n".utf8)),
            fd: pair.peer
        )
        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame.ack(id: "process-1"),
            fd: pair.peer
        )

        let initialFrames = try server._testWaitForProcessStartAck(
            fd: pair.server,
            expectedProcessID: "process-1"
        )

        #expect(initialFrames.count == 1)
        #expect(initialFrames.first?.type == .stdout)
        #expect(initialFrames.first?.data == Data("early-output\n".utf8))
    }

    @Test
    func processStartHandshakeThrowsGuestAgentErrorBeforeAck() throws {
        let server = makeServer()
        let pair = try makeSocketPair()
        defer {
            closeIfValid(pair.server)
            closeIfValid(pair.peer)
        }

        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame(type: .error, message: "failed to start process: No such file or directory"),
            fd: pair.peer
        )

        do {
            _ = try server._testWaitForProcessStartAck(
                fd: pair.server,
                expectedProcessID: "process-2"
            )
            Issue.record("expected process start handshake to throw")
        } catch {
            #expect(String(describing: error).contains("failed to start process"))
            #expect(String(describing: error).contains("No such file or directory"))
        }
    }

    @Test
    func bareExecutableLaunchUsesGuestPathLookup() throws {
        let server = makeServer()

        let launch = server._testGuestExecutableLaunch(
            executable: "sh",
            arguments: ["-lc", "echo ok"]
        )

        #expect(launch.executable == "/usr/bin/env")
        #expect(launch.arguments == ["sh", "-lc", "echo ok"])
    }

    @Test
    func pathExecutableLaunchIsPreserved() throws {
        let server = makeServer()

        let launch = server._testGuestExecutableLaunch(
            executable: "/bin/sh",
            arguments: ["-lc", "echo ok"]
        )

        #expect(launch.executable == "/bin/sh")
        #expect(launch.arguments == ["-lc", "echo ok"])
    }

    @Test
    func emptyExecutableLaunchIsPreserved() throws {
        let server = makeServer()

        let launch = server._testGuestExecutableLaunch(executable: "", arguments: ["arg"])

        #expect(launch.executable == "")
        #expect(launch.arguments == ["arg"])
    }
}

private func makeConfigurationWithInvalidStorage() throws -> Data {
    let image = try JSONDecoder().decode(
        ImageDescription.self,
        from: Data(
            #"{"reference":"example/macos:latest","descriptor":{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:test","size":1}}"#.utf8
        )
    )
    var configuration = ContainerConfiguration(
        id: "invalid-storage",
        image: image,
        process: ProcessConfiguration(
            executable: "/bin/true",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
    )
    configuration.macosGuest = .init(
        snapshotEnabled: false,
        guiEnabled: false,
        agentPort: 27_000,
        blockDevices: [
            .init(identifier: "root", kind: .nbdUnixSocket, path: "relative.sock")
        ]
    )
    return try JSONEncoder().encode(configuration)
}

private func responseFrame(fd: Int32) throws -> MacOSSidecarResponse {
    let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: fd)
    #expect(envelope.kind == .response)
    return try #require(envelope.response)
}

private func makeServer() -> SidecarControlServer {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeMacOSSidecarTests-\(UUID().uuidString)")
    let service = MacOSSidecarService(rootURL: root, log: Logger(label: "RuntimeMacOSSidecarTests"))
    return SidecarControlServer(
        socketPath: "/tmp/runtime-macos-sidecar-tests-\(UUID().uuidString).sock",
        service: service,
        log: Logger(label: "RuntimeMacOSSidecarTests")
    )
}

private func makeSocketPair() throws -> (server: Int32, peer: Int32) {
    var fds = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (fds[0], fds[1])
}

private func expectEOF(fd: Int32) throws {
    var buffer = UInt8.zero
    let count = Darwin.read(fd, &buffer, 1)
    if count == 0 {
        return
    }
    if count > 0 {
        Issue.record("expected EOF on fd \(fd)")
        return
    }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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

private func closeIfValid(_ fd: Int32?) {
    guard let fd, fd >= 0 else { return }
    Darwin.close(fd)
}
#endif
