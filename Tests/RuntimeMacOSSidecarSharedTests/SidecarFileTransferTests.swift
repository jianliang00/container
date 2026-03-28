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

import Foundation
import Testing

@testable import RuntimeMacOSSidecarShared

struct SidecarFileTransferTests {
    @Test
    func writeFileUsesInlineAutoCommitWhenUnderLimit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("payload.txt")
        let contents = Data("inline-payload".utf8)
        try contents.write(to: sourceURL)

        let recorder = Recorder()
        try await MacOSSidecarFileTransfer.writeFile(
            from: sourceURL,
            to: "/tmp/payload.txt",
            options: .init(mode: 0o444, overwrite: false),
            inlineDataLimit: 128,
            chunkSize: 8,
            begin: { payload in
                await recorder.recordBegin(payload)
            },
            chunk: { payload in
                await recorder.recordChunk(payload)
            },
            end: { payload in
                await recorder.recordEnd(payload)
            }
        )

        let begins = await recorder.beginPayloads()
        let chunks = await recorder.chunkPayloads()
        let ends = await recorder.endPayloads()

        #expect(begins.count == 1)
        #expect(chunks.isEmpty)
        #expect(ends.isEmpty)
        #expect(begins[0].op == .writeFile)
        #expect(begins[0].path == "/tmp/payload.txt")
        #expect(begins[0].mode == 0o444)
        #expect(begins[0].overwrite == false)
        #expect(begins[0].inlineData == contents)
        #expect(begins[0].autoCommit == true)
        #expect(begins[0].digest?.hasPrefix("sha256:") == true)
    }

    @Test
    func writeFileStreamsLargePayloadAndCommitsDigest() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("payload.bin")
        let contents = Data("abcdefghijklmnopqrstuvwxyz".utf8)
        try contents.write(to: sourceURL)

        let recorder = Recorder()
        try await MacOSSidecarFileTransfer.writeFile(
            from: sourceURL,
            to: "/tmp/payload.bin",
            options: .init(mode: 0o555),
            inlineDataLimit: 4,
            chunkSize: 5,
            begin: { payload in
                await recorder.recordBegin(payload)
            },
            chunk: { payload in
                await recorder.recordChunk(payload)
            },
            end: { payload in
                await recorder.recordEnd(payload)
            }
        )

        let begins = await recorder.beginPayloads()
        let chunks = await recorder.chunkPayloads()
        let ends = await recorder.endPayloads()

        #expect(begins.count == 1)
        #expect(begins[0].inlineData == nil)
        #expect(begins[0].autoCommit == false)
        #expect(begins[0].mode == 0o555)
        #expect(chunks.count == 6)
        #expect(chunks.map(\.offset) == [0, 5, 10, 15, 20, 25])
        #expect(chunks.map(\.data).reduce(into: Data()) { $0.append($1) } == contents)
        #expect(ends.count == 1)
        #expect(ends[0].action == .commit)
        #expect(ends[0].digest?.hasPrefix("sha256:") == true)
    }

    @Test
    func writeFileAbortsTransferWhenStreamingFails() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("payload.bin")
        try Data("stream-me".utf8).write(to: sourceURL)

        let recorder = Recorder()
        do {
            try await MacOSSidecarFileTransfer.writeFile(
                from: sourceURL,
                to: "/tmp/payload.bin",
                inlineDataLimit: 1,
                chunkSize: 2,
                begin: { payload in
                    await recorder.recordBegin(payload)
                },
                chunk: { payload in
                    await recorder.recordChunk(payload)
                    throw TransferError.syntheticFailure
                },
                end: { payload in
                    await recorder.recordEnd(payload)
                }
            )
            Issue.record("expected streaming transfer to fail")
        } catch {
            #expect(error as? TransferError == .syntheticFailure)
        }

        let ends = await recorder.endPayloads()
        #expect(ends.count == 1)
        #expect(ends[0].action == .abort)
        #expect(ends[0].digest == nil)
    }
}

private actor Recorder {
    private var begins: [MacOSSidecarFSBeginRequestPayload] = []
    private var chunks: [MacOSSidecarFSChunkRequestPayload] = []
    private var ends: [MacOSSidecarFSEndRequestPayload] = []

    func recordBegin(_ payload: MacOSSidecarFSBeginRequestPayload) {
        begins.append(payload)
    }

    func recordChunk(_ payload: MacOSSidecarFSChunkRequestPayload) {
        chunks.append(payload)
    }

    func recordEnd(_ payload: MacOSSidecarFSEndRequestPayload) {
        ends.append(payload)
    }

    func beginPayloads() -> [MacOSSidecarFSBeginRequestPayload] {
        begins
    }

    func chunkPayloads() -> [MacOSSidecarFSChunkRequestPayload] {
        chunks
    }

    func endPayloads() -> [MacOSSidecarFSEndRequestPayload] {
        ends
    }
}

private enum TransferError: Error, Equatable {
    case syntheticFailure
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("SidecarFileTransferTests-\(UUID().uuidString)")
}
