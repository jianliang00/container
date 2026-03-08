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

        let results = try withBuiltinZstdOnly {
            try MacOSDiskChunker.chunkDiskImage(
                diskImage: diskURL,
                blobsDir: blobsDir,
                chunkSize: logicalSize
            )
        }

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

        try withBuiltinZstdOnly {
            try MacOSDiskRebuilder.rebuild(
                layout: layout,
                chunkBlobPaths: [chunk.blobDigest: chunk.blobURL],
                outputPath: rebuiltURL
            )
        }

        #expect(try Data(contentsOf: rebuiltURL) == Data(contentsOf: diskURL))
    }

    @Test
    func chunkerAndRebuilderRoundTripMultipleChunksInParallel() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let diskURL = tempDirectory.appendingPathComponent("Disk.img")
        let rebuiltURL = tempDirectory.appendingPathComponent("Disk.rebuilt.img")
        let blobsDir = tempDirectory.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let chunkSize: Int64 = 256 * 1024
        let logicalSize = chunkSize * 3
        try createSparseDisk(
            at: diskURL,
            logicalSize: logicalSize,
            writes: [
                (offset: 4_096, data: Data("chunk-0".utf8)),
                (offset: chunkSize + 8_192, data: Data("chunk-1".utf8)),
                (offset: (chunkSize * 2) + 16_384, data: Data("chunk-2".utf8)),
            ]
        )

        let results = try withBuiltinZstdOnly {
            try MacOSDiskChunker.chunkDiskImage(
                diskImage: diskURL,
                blobsDir: blobsDir,
                chunkSize: chunkSize,
                maxConcurrentChunks: 2
            )
        }

        #expect(results.count == 3)
        #expect(results.map(\.index) == [0, 1, 2])

        let layout = DiskLayout(
            logicalSize: logicalSize,
            chunkSize: chunkSize,
            chunks: results.map { result in
                .init(
                    index: result.index,
                    offset: result.chunkOffset,
                    length: result.chunkLength,
                    layerDigest: result.blobDigest,
                    layerSize: result.blobSize,
                    rawDigest: result.rawDigest,
                    rawLength: result.rawLength
                )
            }
        )

        let blobPaths = Dictionary(uniqueKeysWithValues: results.map { ($0.blobDigest, $0.blobURL) })
        try withBuiltinZstdOnly {
            try MacOSDiskRebuilder.rebuild(
                layout: layout,
                chunkBlobPaths: blobPaths,
                outputPath: rebuiltURL,
                maxConcurrentChunks: 2
            )
        }

        #expect(try Data(contentsOf: rebuiltURL) == Data(contentsOf: diskURL))
    }

    @Test
    func chunkerReusesMatchingParentChunkBlobs() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let parentDiskURL = tempDirectory.appendingPathComponent("Parent.img")
        let childDiskURL = tempDirectory.appendingPathComponent("Child.img")
        let rebuiltURL = tempDirectory.appendingPathComponent("Child.rebuilt.img")
        let parentBlobsDir = tempDirectory.appendingPathComponent("parent-blobs")
        let childBlobsDir = tempDirectory.appendingPathComponent("child-blobs")
        try FileManager.default.createDirectory(at: parentBlobsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childBlobsDir, withIntermediateDirectories: true)

        let chunkSize: Int64 = 256 * 1024
        let logicalSize = chunkSize * 3
        let repeatedChunkData = Data("same-chunk".utf8)

        try createSparseDisk(
            at: parentDiskURL,
            logicalSize: logicalSize,
            writes: [
                (offset: 4_096, data: repeatedChunkData),
                (offset: chunkSize + 8_192, data: Data("parent-middle".utf8)),
                (offset: (chunkSize * 2) + 4_096, data: repeatedChunkData),
            ]
        )
        try createSparseDisk(
            at: childDiskURL,
            logicalSize: logicalSize,
            writes: [
                (offset: 4_096, data: repeatedChunkData),
                (offset: chunkSize + 8_192, data: Data("child-middle".utf8)),
                (offset: (chunkSize * 2) + 4_096, data: repeatedChunkData),
            ]
        )

        let parentResults = try withBuiltinZstdOnly {
            try MacOSDiskChunker.chunkDiskImage(
                diskImage: parentDiskURL,
                blobsDir: parentBlobsDir,
                chunkSize: chunkSize,
                maxConcurrentChunks: 2
            )
        }

        #expect(parentResults.count == 3)
        #expect(parentResults[0].blobDigest == parentResults[2].blobDigest)

        let parentLayout = DiskLayout(
            logicalSize: logicalSize,
            chunkSize: chunkSize,
            chunks: parentResults.map { result in
                .init(
                    index: result.index,
                    offset: result.chunkOffset,
                    length: result.chunkLength,
                    layerDigest: result.blobDigest,
                    layerSize: result.blobSize,
                    rawDigest: result.rawDigest,
                    rawLength: result.rawLength
                )
            }
        )
        let parentDiskSource = MacOSChunkedDiskSource(
            layout: parentLayout,
            chunkBlobPaths: Dictionary(
                parentResults.map { ($0.blobDigest, $0.blobURL) },
                uniquingKeysWith: { first, _ in first }
            )
        )

        let childResults = try withBuiltinZstdOnly {
            try MacOSDiskChunker.chunkDiskImage(
                diskImage: childDiskURL,
                blobsDir: childBlobsDir,
                chunkSize: chunkSize,
                parentDiskSource: parentDiskSource,
                maxConcurrentChunks: 2
            )
        }

        #expect(childResults.count == 3)
        #expect(childResults[0].blobDigest == parentResults[0].blobDigest)
        #expect(childResults[2].blobDigest == parentResults[2].blobDigest)
        #expect(childResults[1].blobDigest != parentResults[1].blobDigest)
        #expect(childResults[0].reusedFromParent)
        #expect(!childResults[0].reusedWithoutRawDigest)
        #expect(!childResults[1].reusedFromParent)

        let layout = DiskLayout(
            logicalSize: logicalSize,
            chunkSize: chunkSize,
            chunks: childResults.map { result in
                .init(
                    index: result.index,
                    offset: result.chunkOffset,
                    length: result.chunkLength,
                    layerDigest: result.blobDigest,
                    layerSize: result.blobSize,
                    rawDigest: result.rawDigest,
                    rawLength: result.rawLength
                )
            }
        )

        let blobPaths = Dictionary(
            childResults.map { ($0.blobDigest, $0.blobURL) },
            uniquingKeysWith: { first, _ in first }
        )
        try withBuiltinZstdOnly {
            try MacOSDiskRebuilder.rebuild(
                layout: layout,
                chunkBlobPaths: blobPaths,
                outputPath: rebuiltURL,
                maxConcurrentChunks: 2
            )
        }

        #expect(try Data(contentsOf: rebuiltURL) == Data(contentsOf: childDiskURL))
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: childBlobsDir.path)) ==
                Set(childResults.map { $0.blobURL.lastPathComponent })
        )
    }

    @Test
    func chunkerFastReusesUnchangedCloneBackedChunks() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let parentDiskURL = tempDirectory.appendingPathComponent("ParentClone.img")
        let childDiskURL = tempDirectory.appendingPathComponent("ChildClone.img")
        let parentBlobsDir = tempDirectory.appendingPathComponent("parent-clone-blobs")
        let childBlobsDir = tempDirectory.appendingPathComponent("child-clone-blobs")
        try FileManager.default.createDirectory(at: parentBlobsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childBlobsDir, withIntermediateDirectories: true)

        let chunkSize: Int64 = 256 * 1024
        let logicalSize = chunkSize * 3
        try createSparseDisk(
            at: parentDiskURL,
            logicalSize: logicalSize,
            writes: [
                (offset: 4_096, data: Data("parent-clone-0".utf8)),
                (offset: chunkSize + 8_192, data: Data("parent-clone-1".utf8)),
                (offset: (chunkSize * 2) + 12_288, data: Data("parent-clone-2".utf8)),
            ]
        )

        let cloneResult = try FilesystemClone.cloneOrCopyItem(at: parentDiskURL, to: childDiskURL)
        #expect(cloneResult == .cloned)
        try overwrite(at: childDiskURL, offset: chunkSize + 8_192, data: Data("child-clone-1".utf8))

        let parentResults = try withBuiltinZstdOnly {
            try MacOSDiskChunker.chunkDiskImage(
                diskImage: parentDiskURL,
                blobsDir: parentBlobsDir,
                chunkSize: chunkSize,
                maxConcurrentChunks: 2
            )
        }
        let parentLayout = DiskLayout(
            logicalSize: logicalSize,
            chunkSize: chunkSize,
            chunks: parentResults.map { result in
                .init(
                    index: result.index,
                    offset: result.chunkOffset,
                    length: result.chunkLength,
                    layerDigest: result.blobDigest,
                    layerSize: result.blobSize,
                    rawDigest: result.rawDigest,
                    rawLength: result.rawLength
                )
            }
        )
        let parentDiskSource = MacOSChunkedDiskSource(
            layout: parentLayout,
            chunkBlobPaths: Dictionary(
                parentResults.map { ($0.blobDigest, $0.blobURL) },
                uniquingKeysWith: { first, _ in first }
            ),
            diskImagePath: parentDiskURL
        )

        let childResults = try withBuiltinZstdOnly {
            try MacOSDiskChunker.chunkDiskImage(
                diskImage: childDiskURL,
                blobsDir: childBlobsDir,
                chunkSize: chunkSize,
                parentDiskSource: parentDiskSource,
                maxConcurrentChunks: 2
            )
        }

        #expect(childResults.count == 3)
        #expect(childResults[0].reusedFromParent)
        #expect(childResults[0].reusedWithoutRawDigest)
        #expect(!childResults[1].reusedFromParent)
        #expect(childResults[2].reusedFromParent)
        #expect(childResults[2].reusedWithoutRawDigest)
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

private func overwrite(at url: URL, offset: Int64, data: Data) throws {
    let fd = open(url.path, O_RDWR)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }

    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            return
        }
        let written = pwrite(fd, baseAddress, bytes.count, offset)
        guard written == bytes.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private func withBuiltinZstdOnly<T>(_ body: () throws -> T) throws -> T {
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
    return try body()
}
