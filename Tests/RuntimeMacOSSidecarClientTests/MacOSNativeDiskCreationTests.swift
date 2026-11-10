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

import CryptoKit
import Darwin
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import container_runtime_macos

struct MacOSNativeDiskCreationTests {
    @Test
    func platformCreatorBuildsASIFOrRejectsBeforeMutation() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-platform-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base.img")
        let overlay = root.appendingPathComponent("active.asif")
        #expect(FileManager.default.createFile(atPath: base.path, contents: nil))
        let file = try FileHandle(forWritingTo: base)
        try file.truncate(atOffset: 64 << 20)
        try file.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: base.path)
        if MacOSNativeDisk.available {
            try createNativeASIFOverlay(base: base, output: overlay)
            #expect((try overlay.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0)
            // A second create cannot overwrite the first overlay.
            #expect(throws: (any Error).self) { try createNativeASIFOverlay(base: base, output: overlay) }
        } else {
            #expect(throws: (any Error).self) { try createNativeASIFOverlay(base: base, output: overlay) }
            #expect(!FileManager.default.fileExists(atPath: overlay.path))
        }
    }
}

extension MacOSNativeDiskCreationTests {
    @Test
    func unknownAllocationLayoutUsesFullScan() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-fallback-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let unknown = root.appendingPathComponent("future.asif")
        try Data("unknown geometry".utf8).write(to: unknown)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: unknown.path)
        let size = 2 << 20
        let base = root.appendingPathComponent("base")
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let before = Data(repeating: 0xa5, count: size)
        let after = Data(repeating: 0, count: size)
        try before.write(to: base)
        try before.write(to: target)
        try after.write(to: source)
        let plan = try MacOSASIFCompaction(layers: [unknown, unknown], logicalBytes: UInt64(size), sparseBase: base)
        #expect(!plan.usesIndex)
        #expect(plan.blockCount == 2)
        let baseFD = try FileHandle(forReadingFrom: base)
        let sourceFD = try FileHandle(forReadingFrom: source)
        let targetFD = try FileHandle(forUpdating: target)
        let hashes = try plan.copy(base: baseFD.fileDescriptor, source: sourceFD.fileDescriptor, target: targetFD.fileDescriptor, completed: []) { _ in }
        try plan.verify(target: targetFD.fileDescriptor, expected: hashes)
        #expect(try Data(contentsOf: target) == after)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONTAINER_TEST_NATIVE_ASIF"] == "1"))
    func nativeMergePreservesPartialWritesZeroesAndDiscards() throws {
        guard #available(macOS 27, *) else { return }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-merge-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }

        let cache = root.appendingPathComponent("rebuild-cache")
        let base = root.appendingPathComponent("base.img")
        let size: Int64 = 64 << 20
        let input = Data(repeating: 0x13, count: 4096)
        try input.write(to: base)
        let baseHandle = try FileHandle(forWritingTo: base)
        try baseHandle.truncate(atOffset: UInt64(size))
        for offset: UInt64 in [2 << 20, 3 << 20] {
            try baseHandle.seek(toOffset: offset)
            try baseHandle.write(contentsOf: input)
        }
        try baseHandle.close()
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: base.path)

        func write(_ fd: Int32, _ value: UInt8, offset: Int64) throws {
            let data = Data(repeating: value, count: 512)
            guard data.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, offset) }) == data.count, fsync(fd) == 0 else {
                throw POSIXError(.EIO)
            }
        }

        func trim(_ fd: Int32, offset: UInt64, length: UInt64) throws {
            var extent = dk_extent_t(offset: offset, length: length)
            // DKIOCUNMAP is a C _IOW macro that Swift cannot import.
            let code = UInt(0x8000_0000 | (MemoryLayout<dk_unmap_t>.size << 16) | (0x64 << 8) | 31)
            let result = withUnsafeMutablePointer(to: &extent) { pointer in
                var request = dk_unmap_t(extents: pointer, extentsCount: 1, options: 0)
                return withUnsafeMutablePointer(to: &request) { ioctl(fd, code, $0) }
            }
            guard result == 0, fsync(fd) == 0 else { throw POSIXError(.EIO) }
        }

        let first = root.appendingPathComponent("first.asif")
        try MacOSASIFCompactionJob.withDevice(base: base, layers: [first], size: UInt64(size), readOnly: false) {
            try write($0, 0xaa, offset: 512)
            try write($0, 0x77, offset: 10 << 20)
        }
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: first.path)
        let second = root.appendingPathComponent("second.asif")
        try MacOSASIFCompactionJob.withDevice(base: base, layers: [first, second], size: UInt64(size), readOnly: false) {
            try write($0, 0, offset: 1024)
            try write($0, 0xbb, offset: 8 << 20)
            try trim($0, offset: (2 << 20) + 512, length: 512)
            try trim($0, offset: 3 << 20, length: 1 << 20)
            try trim($0, offset: 10 << 20, length: 50 << 20)
        }
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: second.path)
        let plan = try MacOSASIFCompaction(layers: [first, second], logicalBytes: UInt64(size), sparseBase: base)
        #expect(plan.usesIndex)
        #expect(plan.blockCount == 5)

        let digest = "sha256:" + String(repeating: "a", count: 64)
        try MacOSASIFMergeCache.compact(manifestDigest: digest, base: base, parents: [first, second], logicalSize: size, cacheDirectory: cache)
        let output = try #require(try MacOSASIFMergeCache.ready(manifestDigest: digest, cacheDirectory: cache))
        var expected = Data(count: Int(size))
        expected.replaceSubrange(0..<4096, with: input)
        expected.replaceSubrange(512..<1024, with: Data(repeating: 0xaa, count: 512))
        expected.replaceSubrange(1024..<1536, with: Data(repeating: 0, count: 512))
        let partialTrim = 2 << 20
        expected.replaceSubrange(partialTrim..<(partialTrim + 4096), with: input)
        expected.replaceSubrange((partialTrim + 512)..<(partialTrim + 1024), with: Data(repeating: 0, count: 512))
        let distantWrite = 8 << 20
        expected.replaceSubrange(distantWrite..<(distantWrite + 512), with: Data(repeating: 0xbb, count: 512))
        try MacOSASIFCompactionJob.withDevice(base: base, layers: [output], size: UInt64(size), readOnly: true) { fd in
            var actual = SHA256()
            for offset in stride(from: 0, to: Int(size), by: 1 << 20) {
                var block = Data(count: 1 << 20)
                guard block.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, $0.count, Int64(offset)) }) == block.count else {
                    throw POSIXError(.EIO)
                }
                actual.update(data: block)
            }
            #expect(actual.finalize() == SHA256.hash(data: expected))
        }
        try MacOSASIFMergeCache.compact(manifestDigest: digest, base: base, parents: [first, second], logicalSize: size, cacheDirectory: cache)
        #expect(try MacOSASIFMergeCache.ready(manifestDigest: digest, cacheDirectory: cache) == output)

        let broken = root.appendingPathComponent("broken.asif")
        try fm.copyItem(at: second, to: broken)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: broken.path)
        let damaged = try FileHandle(forWritingTo: broken)
        try damaged.seek(toOffset: 16)
        try damaged.write(contentsOf: Data(count: 8))
        try damaged.close()
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: broken.path)
        let rejected = "sha256:" + String(repeating: "b", count: 64)
        #expect(throws: MacOSASIFLayerIndex.IndexError.self) {
            try MacOSASIFMergeCache.compact(manifestDigest: rejected, base: base, parents: [first, broken], logicalSize: size, cacheDirectory: cache)
        }
        #expect(try MacOSASIFMergeCache.ready(manifestDigest: rejected, cacheDirectory: cache) == nil)
    }
}
