#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import container_macos_guest_agent

struct GuestAgentFileTransferTransactionTests {
    @Test
    func writeFileCommitPersistsInlineAndChunkData() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("payload.txt")
        let expected = Data("abcdef".utf8)
        let tx = try GuestAgentFileTransferTransaction(
            request: .init(
                txID: "tx-write",
                op: .writeFile,
                path: outputURL.path,
                inlineData: Data("abc".utf8)
            )
        )

        try tx.append(data: Data("def".utf8), offset: 3)
        try tx.complete(action: .commit, digest: "sha256:\(sha256(expected))")

        let actual = try Data(contentsOf: outputURL)
        #expect(actual == expected)
    }

    @Test
    func abortLeavesFinalPathAbsent() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("aborted.txt")
        let tx = try GuestAgentFileTransferTransaction(
            request: .init(
                txID: "tx-abort",
                op: .writeFile,
                path: outputURL.path,
                inlineData: Data("temp".utf8)
            )
        )

        try tx.complete(action: .abort, digest: nil)

        #expect(FileManager.default.fileExists(atPath: outputURL.path) == false)
    }

    @Test
    func abortRemovesTemporaryWriteArtifact() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("aborted.txt")
        let tx = try GuestAgentFileTransferTransaction(
            request: .init(
                txID: "tx-abort-temp",
                op: .writeFile,
                path: outputURL.path,
                inlineData: Data("temp".utf8)
            )
        )

        #expect(temporaryTransactionArtifacts(in: tempDir).count == 1)

        tx.abort()

        #expect(FileManager.default.fileExists(atPath: outputURL.path) == false)
        #expect(temporaryTransactionArtifacts(in: tempDir).isEmpty)
    }

    @Test
    func failedCommitCanBeAbortedWithoutLeavingTemporaryFile() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("payload.txt")
        let tx = try GuestAgentFileTransferTransaction(
            request: .init(
                txID: "tx-digest-mismatch",
                op: .writeFile,
                path: outputURL.path,
                inlineData: Data("payload".utf8)
            )
        )

        #expect(temporaryTransactionArtifacts(in: tempDir).count == 1)
        #expect(throws: (any Error).self) {
            try tx.complete(action: .commit, digest: "sha256:deadbeef")
        }

        tx.abort()

        #expect(FileManager.default.fileExists(atPath: outputURL.path) == false)
        #expect(temporaryTransactionArtifacts(in: tempDir).isEmpty)
    }

    @Test
    func symlinkCommitCreatesRequestedLink() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appendingPathComponent("tool")
        let tx = try GuestAgentFileTransferTransaction(
            request: .init(
                txID: "tx-link",
                op: .symlink,
                path: linkURL.path,
                linkTarget: "/usr/bin/true"
            )
        )

        try tx.complete(action: .commit, digest: nil)

        let target = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        #expect(target == "/usr/bin/true")
    }

    @Test
    func mkdirCommitAppliesRequestedMetadata() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let directoryURL = tempDir.appendingPathComponent("workspace")
        let mtime: Int64 = 1_730_123_456
        let tx = try GuestAgentFileTransferTransaction(
            request: .init(
                txID: "tx-mkdir",
                op: .mkdir,
                path: directoryURL.path,
                mode: 0o700,
                mtime: mtime
            )
        )

        try tx.complete(action: .commit, digest: nil)

        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let attributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint32Value == 0o700)
        let actualMtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        #expect(Int64(actualMtime.rounded()) == mtime)
    }

    @Test
    func writeFileRejectsExistingDestinationWhenOverwriteFalse() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("payload.txt")
        try Data("existing".utf8).write(to: outputURL)

        do {
            _ = try GuestAgentFileTransferTransaction(
                request: .init(
                    txID: "tx-existing-file",
                    op: .writeFile,
                    path: outputURL.path,
                    overwrite: false
                )
            )
            Issue.record("expected write_file overwrite=false to reject existing destination")
        } catch {
            expectPOSIXError(error, .EEXIST)
        }
    }

    @Test
    func mkdirRejectsExistingNonDirectoryWhenOverwriteFalse() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("not-a-directory")
        try Data("existing".utf8).write(to: outputURL)
        let tx = try GuestAgentFileTransferTransaction(
            request: .init(
                txID: "tx-existing-mkdir",
                op: .mkdir,
                path: outputURL.path,
                overwrite: false
            )
        )

        do {
            try tx.complete(action: .commit, digest: nil)
            Issue.record("expected mkdir overwrite=false to reject existing non-directory")
        } catch {
            expectPOSIXError(error, .EEXIST)
        }
    }

    @Test
    func symlinkRejectsExistingDestinationWhenOverwriteFalse() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appendingPathComponent("tool")
        try Data("existing".utf8).write(to: linkURL)
        let tx = try GuestAgentFileTransferTransaction(
            request: .init(
                txID: "tx-existing-link",
                op: .symlink,
                path: linkURL.path,
                linkTarget: "/usr/bin/true",
                overwrite: false
            )
        )

        do {
            try tx.complete(action: .commit, digest: nil)
            Issue.record("expected symlink overwrite=false to reject existing destination")
        } catch {
            expectPOSIXError(error, .EEXIST)
        }
    }

    @Test
    func connectionCloseAbortsOutstandingWriteTransaction() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("payload.txt")
        let (serverFD, clientSocket) = try socketPair()
        let connection = AgentConnection(fd: serverFD)
        var clientFD = clientSocket
        defer { closeIfValid(&clientFD) }

        let runner = ConnectionRunner(connection: connection)
        runner.start()

        let ready = try readAgentFrame(from: clientFD)
        #expect(ready.type == .ready)

        try writeAgentFrame(
            .init(
                type: .fsBegin,
                id: "tx-close",
                data: Data("payload".utf8),
                op: .writeFile,
                path: outputURL.path,
                autoCommit: false
            ),
            to: clientFD
        )

        let ack = try readAgentFrame(from: clientFD)
        #expect(ack.type == .ack)
        #expect(temporaryTransactionArtifacts(in: tempDir).count == 1)

        closeIfValid(&clientFD)

        #expect(runner.wait(timeoutSeconds: 2))
        #expect(runner.error == nil)
        #expect(FileManager.default.fileExists(atPath: outputURL.path) == false)
        #expect(temporaryTransactionArtifacts(in: tempDir).isEmpty)
    }

    @Test
    func autoCommitDigestMismatchReturnsReadableErrorAndLeavesNoFile() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("payload.txt")
        let (serverFD, clientSocket) = try socketPair()
        let connection = AgentConnection(fd: serverFD)
        var clientFD = clientSocket
        defer { closeIfValid(&clientFD) }

        let runner = ConnectionRunner(connection: connection)
        runner.start()

        let ready = try readAgentFrame(from: clientFD)
        #expect(ready.type == .ready)

        try writeAgentFrame(
            .init(
                type: .fsBegin,
                id: "tx-auto-commit-digest",
                data: Data("payload".utf8),
                op: .writeFile,
                path: outputURL.path,
                autoCommit: true,
                digest: "sha256:deadbeef"
            ),
            to: clientFD
        )

        let errorFrame = try readAgentFrame(from: clientFD)
        #expect(errorFrame.type == .error)
        #expect(errorFrame.message?.contains("filesystem transaction tx_id=tx-auto-commit-digest") == true)
        #expect(errorFrame.message?.contains("stage=begin") == true)

        let exitFrame = try readAgentFrame(from: clientFD)
        #expect(exitFrame.type == .exit)
        #expect(exitFrame.exitCode == 1)

        closeIfValid(&clientFD)

        #expect(runner.wait(timeoutSeconds: 2))
        #expect(FileManager.default.fileExists(atPath: outputURL.path) == false)
        #expect(temporaryTransactionArtifacts(in: tempDir).isEmpty)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func socketPair() throws -> (Int32, Int32) {
    var fds = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (fds[0], fds[1])
}

private func readAgentFrame(from fd: Int32) throws -> GuestAgentFrame {
    let header = try readExact(from: fd, count: MemoryLayout<UInt32>.size)
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let payload = try readExact(from: fd, count: Int(length))
    return try JSONDecoder().decode(GuestAgentFrame.self, from: payload)
}

private func readExact(from fd: Int32, count: Int) throws -> Data {
    var result = Data(count: count)
    try result.withUnsafeMutableBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return
        }

        var offset = 0
        while offset < count {
            let bytesRead = Darwin.read(fd, baseAddress.advanced(by: offset), count - offset)
            guard bytesRead > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += bytesRead
        }
    }
    return result
}

private func writeAgentFrame(_ frame: GuestAgentFrame, to fd: Int32) throws {
    let payload = try JSONEncoder().encode(frame)
    var length = UInt32(payload.count).bigEndian
    let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    try writeAll(header, to: fd)
    try writeAll(payload, to: fd)
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return
        }

        var offset = 0
        while offset < rawBuffer.count {
            let bytesWritten = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
            guard bytesWritten > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += bytesWritten
        }
    }
}

private func closeIfValid(_ fd: inout Int32) {
    guard fd >= 0 else { return }
    Darwin.close(fd)
    fd = -1
}

private func expectPOSIXError(_ error: any Error, _ expected: POSIXErrorCode) {
    if let posix = error as? POSIXError {
        #expect(posix.code == expected)
        return
    }

    let nsError = error as NSError
    #expect(nsError.domain == NSPOSIXErrorDomain)
    #expect(nsError.code == Int(expected.rawValue))
}

private final class ConnectionRunner: @unchecked Sendable {
    private let connection: AgentConnection
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedError: (any Error)?

    init(connection: AgentConnection) {
        self.connection = connection
    }

    func start() {
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            do {
                try connection.run()
            } catch {
                lock.lock()
                storedError = error
                lock.unlock()
            }
        }
    }

    func wait(timeoutSeconds: TimeInterval) -> Bool {
        done.wait(timeout: .now() + timeoutSeconds) == .success
    }

    var error: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

private func temporaryTransactionArtifacts(in directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
        .filter { $0.lastPathComponent.hasPrefix(".container-fs-") && $0.pathExtension == "tmp" } ?? []
}
#endif
