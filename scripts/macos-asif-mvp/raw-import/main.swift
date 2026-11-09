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

// Experimental adapter; all chunk blobs must have been verified by the caller.
// Shares the production sparse reconstruction implementation, not a second decoder.
func run() throws {
    let arguments = CommandLine.arguments
    func require(_ condition: Bool) throws {
        guard condition else { throw CocoaError(.fileReadCorruptFile) }
    }
    try require(arguments.count == 4)
    let layoutURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let blobs = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    let output = URL(fileURLWithPath: arguments[3]).standardizedFileURL
    try require(!FileManager.default.fileExists(atPath: output.path))
    try require(output == output.resolvingSymlinksInPath())
    let layout = try JSONDecoder().decode(DiskLayout.self, from: Data(contentsOf: layoutURL))
    try require(layout.version == 1 && layout.logicalSize > 0 && layout.logicalSize <= 300 << 30)
    try require(layout.chunkSize == DiskLayout.defaultChunkSize)
    try require(layout.chunkCount == Int((layout.logicalSize - 1) / layout.chunkSize + 1))
    try require(layout.chunks.count == layout.chunkCount)
    var paths: [String: URL] = [:]
    for (index, chunk) in layout.chunks.enumerated() {
        try require(chunk.index == index && chunk.offset == Int64(index) * layout.chunkSize)
        try require(chunk.length == min(layout.chunkSize, layout.logicalSize - chunk.offset))
        try require(chunk.rawLength == chunk.length)
        try require(chunk.layerDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil)
        let path = blobs.appendingPathComponent(String(chunk.layerDigest.dropFirst(7)))
        try require(path == path.resolvingSymlinksInPath())
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        try require(attributes[.type] as? FileAttributeType == .typeRegular)
        try require((attributes[.size] as? NSNumber)?.int64Value == chunk.layerSize)
        paths[chunk.layerDigest] = path
    }
    try MacOSDiskRebuilder.rebuild(layout: layout, chunkBlobPaths: paths, outputPath: output)
}

do {
    try run()
} catch {
    fputs("RAW reconstruction failed: \(error)\n", stderr)
    exit(1)
}
