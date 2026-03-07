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

import ContainerResource
import Foundation
import Testing

@testable import ContainerCommands

struct MacOSDiskChunkerTests {
    @Test
    func chunkerUsesBuiltinZstdCompression() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let diskURL = tempDirectory.appendingPathComponent("Disk.img")
        let rebuiltURL = tempDirectory.appendingPathComponent("Disk.rebuilt.img")
        let blobsDir = tempDirectory.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let logicalSize: Int64 = 1 << 20
        try createSparseDisk(
            at: diskURL,
            logicalSize: logicalSize,
            writes: [
                (offset: 4096, data: Data("abc".utf8)),
                (offset: 524_288, data: Data("YZ".utf8)),
            ]
        )

        setenv(ZstdTool.overrideEnvironmentKey, "/missing/zstd", 1)
        defer { unsetenv(ZstdTool.overrideEnvironmentKey) }
        let originalPath = getenv("PATH").map { String(cString: $0) }
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
            }
        }
        setenv("PATH", "", 1)

        let results = try MacOSDiskChunker.chunkDiskImage(
            diskImage: diskURL,
            blobsDir: blobsDir,
            chunkSize: logicalSize
        )

        #expect(results.count == 1)

        let chunk = try #require(results.first)
        let layout = DiskLayout(
            logicalSize: logicalSize,
            chunkSize: logicalSize,
            chunks: [
                .init(
                    index: chunk.index,
                    offset: chunk.chunkOffset,
                    length: chunk.chunkLength,
                    layerDigest: chunk.blobDigest,
                    layerSize: chunk.blobSize,
                    rawDigest: chunk.rawDigest,
                    rawLength: chunk.rawLength
                )
            ]
        )

        try MacOSDiskRebuilder.rebuild(
            layout: layout,
            chunkBlobPaths: [chunk.blobDigest: chunk.blobURL],
            outputPath: rebuiltURL
        )

        #expect(try Data(contentsOf: rebuiltURL) == Data(contentsOf: diskURL))
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacOSDiskChunkerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func createSparseDisk(
    at url: URL,
    logicalSize: Int64,
    writes: [(offset: Int64, data: Data)]
) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fd = open(url.path, O_RDWR)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }

    guard ftruncate(fd, logicalSize) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    for writeOp in writes {
        try writeOp.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            let written = pwrite(fd, baseAddress, bytes.count, writeOp.offset)
            guard written == bytes.count else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}
