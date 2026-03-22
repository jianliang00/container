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

struct MacOSImagePackagerTests {
    @Test
    func packageCleansUpTemporaryLayoutDirectoryWhenLayoutCreationFails() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let imageDirectory = tempDirectory.appendingPathComponent("image")
        let layoutRoot = tempDirectory.appendingPathComponent("layout-root")
        let seedBlobsDir = tempDirectory.appendingPathComponent("seed-blobs")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layoutRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: seedBlobsDir, withIntermediateDirectories: true)

        let logicalSize: Int64 = 4096
        let diskImage = imageDirectory.appendingPathComponent(MacOSImagePackager.diskImageFilename)
        try createSparseDisk(
            at: diskImage,
            logicalSize: logicalSize,
            writes: [(offset: 0, data: Data("seed".utf8))]
        )
        try Data("aux".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.auxiliaryStorageFilename)
        )
        try Data("hardware".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.hardwareModelFilename)
        )

        let seededChunks = try withBuiltinZstdOnly {
            try MacOSDiskChunker.chunkDiskImage(
                diskImage: diskImage,
                blobsDir: seedBlobsDir,
                chunkSize: DiskLayout.defaultChunkSize
            )
        }
        let seededChunk = try #require(seededChunks.first)
        let parentLayout = DiskLayout(
            logicalSize: logicalSize,
            chunks: [
                .init(
                    index: seededChunk.index,
                    offset: seededChunk.chunkOffset,
                    length: seededChunk.chunkLength,
                    layerDigest: seededChunk.blobDigest,
                    layerSize: seededChunk.blobSize,
                    rawDigest: seededChunk.rawDigest,
                    rawLength: seededChunk.rawLength
                )
            ]
        )
        let missingBlobURL = tempDirectory.appendingPathComponent("missing-parent-blob")
        let parentDiskSource = MacOSChunkedDiskSource(
            layout: parentLayout,
            chunkBlobPaths: [seededChunk.blobDigest: missingBlobURL]
        )

        let outputTar = tempDirectory.appendingPathComponent("out.tar")
        #expect(throws: Error.self) {
            try withBuiltinZstdOnly {
                try MacOSImagePackager.package(
                    imageDirectory: imageDirectory,
                    outputTar: outputTar,
                    reference: nil,
                    parentDiskSource: parentDiskSource,
                    temporaryRootDirectory: layoutRoot
                )
            }
        }

        let leftoverLayouts = try FileManager.default.contentsOfDirectory(
            at: layoutRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("macos-oci-layout-") }

        #expect(leftoverLayouts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: outputTar.path))
    }

    @Test
    func packageReportsProgressAcrossChunkingAndTarCreation() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let imageDirectory = tempDirectory.appendingPathComponent("image")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        try createSparseDisk(
            at: imageDirectory.appendingPathComponent(MacOSImagePackager.diskImageFilename),
            logicalSize: 4096,
            writes: [(offset: 0, data: Data("seed".utf8))]
        )
        try Data("aux".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.auxiliaryStorageFilename)
        )
        try Data("hardware".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.hardwareModelFilename)
        )

        let outputTar = tempDirectory.appendingPathComponent("out.tar")
        let recorder = LockedMessages()
        try withBuiltinZstdOnly {
            try MacOSImagePackager.package(
                imageDirectory: imageDirectory,
                outputTar: outputTar,
                reference: "local/test:latest",
                progress: { recorder.append($0) }
            )
        }

        let messages = recorder.values()
        #expect(messages.contains("Packaging macOS image bundle"))
        #expect(messages.contains(where: { $0.contains("Chunking macOS disk image") }))
        #expect(messages.contains(where: { $0.contains("Chunked 1/1 disk chunk") }))
        #expect(messages.contains("Writing OCI tar metadata"))
        #expect(messages.contains(where: { $0.contains("Appending ") && $0.contains("OCI blob") }))
        #expect(messages.contains("Finished macOS image packaging"))
        #expect(FileManager.default.fileExists(atPath: outputTar.path))
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacOSImagePackagerTests-\(UUID().uuidString)")
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

private final class LockedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
