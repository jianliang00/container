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

/// Exports dedicated offline fixtures through the existing image chunker.
struct MacOSChunkExportExperimentTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACOS_CHUNK_EXPORT_EXPERIMENT"] != nil))
    func exportFixture() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACOS_CHUNK_EXPORT_EXPERIMENT"])
        let root = URL(fileURLWithPath: path).standardizedFileURL
        try #require(root == root.resolvingSymlinksInPath())
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        try #require((attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        try #require(((attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0)
        let source = root.appendingPathComponent("Disk.img")
        let output = root.appendingPathComponent("chunks")
        try #require(source == source.resolvingSymlinksInPath())
        try #require(!FileManager.default.fileExists(atPath: output.path))
        let blobs = output.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        var parent: MacOSChunkedDiskSource?
        if let parentPath = ProcessInfo.processInfo.environment["MACOS_CHUNK_PARENT_EXPERIMENT"] {
            let directory = URL(fileURLWithPath: parentPath).standardizedFileURL
            try #require(directory == directory.resolvingSymlinksInPath())
            let layout = try JSONDecoder().decode(DiskLayout.self, from: Data(contentsOf: directory.appendingPathComponent("layout.json")))
            var paths: [String: URL] = [:]
            for chunk in layout.chunks {
                try #require(chunk.layerDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil)
                paths[chunk.layerDigest] = directory.appendingPathComponent("blobs/sha256/" + String(chunk.layerDigest.dropFirst(7)))
            }
            parent = MacOSChunkedDiskSource(layout: layout, chunkBlobPaths: paths)
        }
        let chunks = try MacOSDiskChunker.chunkDiskImage(diskImage: source, blobsDir: blobs, parentDiskSource: parent)
        let layout = DiskLayout(
            logicalSize: try MacOSDiskChunker.logicalFileSize(source),
            chunks: chunks.map {
                DiskLayout.ChunkInfo(
                    index: $0.index, offset: $0.chunkOffset, length: $0.chunkLength,
                    layerDigest: $0.blobDigest, layerSize: $0.blobSize, rawDigest: $0.rawDigest, rawLength: $0.rawLength)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(layout).write(to: output.appendingPathComponent("layout.json"))
    }
}
