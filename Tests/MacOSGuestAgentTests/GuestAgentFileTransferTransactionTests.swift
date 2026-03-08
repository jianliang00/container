#if os(macOS)
import CryptoKit
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
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func temporaryTransactionArtifacts(in directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
        .filter { $0.lastPathComponent.hasPrefix(".container-fs-") && $0.pathExtension == "tmp" } ?? []
}
#endif
