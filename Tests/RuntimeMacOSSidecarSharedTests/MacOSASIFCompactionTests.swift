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

import Darwin
import Foundation
import Testing

@testable import RuntimeMacOSSidecarShared

struct MacOSASIFCompactionTests {
    @Test func excludesFullDiscardsOnlyWhenTheWholeChainReadsZeros() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let block = MacOSASIFLayerIndex.blockBytes
        let size = 4 * block
        let base = directory.appendingPathComponent("base.img")
        try Data(repeating: 0xA5, count: 4096).write(to: base)
        let file = try FileHandle(forWritingTo: base)
        try file.truncate(atOffset: UInt64(size))
        try file.close()
        #expect(chmod(base.path, 0o400) == 0)

        let lower = directory.appendingPathComponent("lower.asif")
        let upper = directory.appendingPathComponent("upper.asif")
        let fullDiscard: UInt64 = 2 << 62
        try writeIndex([fullDiscard, fullDiscard, (1 << 62) | 2, 0], to: lower, size: size)
        try writeIndex([0, 0, fullDiscard, 3 << 62], to: upper, size: size)

        let unpruned = try MacOSASIFCompaction(layers: [lower, upper], logicalBytes: UInt64(size))
        #expect(unpruned.usesIndex)
        #expect(unpruned.blockCount == 4)
        let plan = try MacOSASIFCompaction(layers: [lower, upper], logicalBytes: UInt64(size), sparseBase: base)
        #expect(plan.usesIndex)
        #expect(plan.blockCount == 3)
    }

    private func writeIndex(_ entries: [UInt64], to path: URL, size: Int) throws {
        let block = MacOSASIFLayerIndex.blockBytes
        var data = Data(count: 4 * block)
        func put<T: FixedWidthInteger>(_ number: T, at offset: Int) {
            var encoded = number.bigEndian
            withUnsafeBytes(of: &encoded) { bytes in
                data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            }
        }
        data.replaceSubrange(0..<4, with: [0x73, 0x68, 0x64, 0x77])
        put(UInt32(1), at: 4)
        put(UInt32(512), at: 8)
        put(UInt64(512), at: 16)
        put(UInt64(1024), at: 24)
        put(UInt64(size / 512), at: 48)
        put(UInt64(size / 512), at: 56)
        put(UInt32(block), at: 64)
        put(UInt16(512), at: 68)
        put(UInt64(1), at: 512)
        put(UInt64(1), at: 520)
        put(UInt64(3), at: block + 2048 * 8)
        for (index, entry) in entries.enumerated() {
            put(entry, at: block + index * 8)
        }
        try data.write(to: path)
        #expect(chmod(path.path, 0o400) == 0)
    }
}
