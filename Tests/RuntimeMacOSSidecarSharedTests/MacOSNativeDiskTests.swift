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

struct MacOSNativeDiskTests {
    @Test
    func verifiedSourceProducesSeparateReceiptsAndRejectsChangedFiles() throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = f.source.appendingPathComponent("base.img")
        let first = f.runtime.appendingPathComponent("first.img")
        let reference = "registry.example/mac/base@" + f.digest
        let initial = try #require(try MacOSNativeBaseReceipt.clone(source, to: first, immutableSource: false))
        try initial.verify(reference: reference)
        let cache = try MacOSNativeBaseReceipt.read(source)
        let firstReceipt = try MacOSNativeBaseReceipt.read(first)
        #expect(firstReceipt.base == cache.base)
        #expect(firstReceipt.stamp.inode != cache.stamp.inode)

        let second = f.runtime.appendingPathComponent("second.img")
        let clone = try #require(try MacOSNativeBaseReceipt.clone(source, to: second, immutableSource: false))
        #expect(!clone.inherit(reference: reference, expected: .init(reference: reference, sha256: String(repeating: "0", count: 64), size: cache.base.size)))
        #expect(clone.inherit(reference: reference, expected: cache.base))
        let secondReceipt = try MacOSNativeBaseReceipt.read(second)
        #expect(secondReceipt.base == firstReceipt.base)
        #expect(secondReceipt.stamp.inode != firstReceipt.stamp.inode)
        try Data("replaced".utf8).write(to: second, options: .atomic)
        #expect(!clone.inherit(reference: reference, expected: cache.base))

        try Data("new.img".utf8).write(to: source, options: .atomic)
        let third = f.runtime.appendingPathComponent("third.img")
        let changed = try #require(try MacOSNativeBaseReceipt.clone(source, to: third, immutableSource: false))
        #expect(!changed.inherit(reference: reference))
        #expect(!FileManager.default.fileExists(atPath: third.appendingPathExtension("verified.json").path))
    }

    @Test
    func committedDiskSurvivesImageCacheGCAndKeepsGuestWrites() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        #expect(try MacOSNativeDisk.isPrepared(destination: f.runtime, imageDigest: f.digest))
        let overlay = f.runtime.appendingPathComponent("active.asif")
        let firmware = f.runtime.appendingPathComponent("AuxiliaryStorage")
        try Data("guest-write".utf8).write(to: overlay)
        try Data("firmware-write".utf8).write(to: firmware)
        try FileManager.default.removeItem(at: f.source)
        try f.prepare { _, _ in throw POSIXError(.EIO) }
        #expect(try Data(contentsOf: overlay) == Data("guest-write".utf8))
        #expect(try Data(contentsOf: firmware) == Data("firmware-write".utf8))
        var base = stat()
        #expect(lstat(f.runtime.appendingPathComponent("base.img").path, &base) == 0)
        #expect(base.st_mode & 0o222 == 0)
    }

    @Test
    func failedOverlayCreationResumesTheSameIntent() throws {
        let f = try Fixture()
        defer { f.remove() }
        #expect(throws: (any Error).self) {
            try f.prepare { _, output in
                try Data("partial".utf8).write(to: output)
                throw POSIXError(.EIO)
            }
        }
        #expect(try !MacOSNativeDisk.isPrepared(destination: f.runtime, imageDigest: f.digest))
        #expect(!FileManager.default.fileExists(atPath: f.runtime.appendingPathComponent("active.asif").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.runtime.path).allSatisfy { !$0.hasPrefix(".native-overlay-") })
        try FileManager.default.removeItem(at: f.source)
        try f.prepare()
        #expect(try MacOSNativeDisk.isPrepared(destination: f.runtime, imageDigest: f.digest))
    }

    @Test
    func publishedOverlayIsNotRecreatedWhenCommitWasInterrupted() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        try FileManager.default.moveItem(at: f.runtime.appendingPathComponent("native-disk-created"), to: f.runtime.appendingPathComponent("native-disk-creating"))
        try Data("existing-overlay".utf8).write(to: f.runtime.appendingPathComponent("active.asif"))
        try f.prepare { _, _ in throw POSIXError(.EIO) }
        #expect(try Data(contentsOf: f.runtime.appendingPathComponent("active.asif")) == Data("existing-overlay".utf8))
    }

    @Test(arguments: ["base.img", "active.asif", "Disk.img", "disk-bundle-imported"])
    func refusesUnownedFiles(_ name: String) throws {
        let f = try Fixture()
        defer { f.remove() }
        let file = f.runtime.appendingPathComponent(name)
        try Data("preserve".utf8).write(to: file)
        #expect(throws: (any Error).self) { try f.prepare() }
        #expect(try Data(contentsOf: file) == Data("preserve".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.runtime.appendingPathComponent("native-disk-creating").path))
    }

    @Test
    func mismatchedImageAndSymlinkAreRejected() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.prepare()
        #expect(throws: (any Error).self) {
            try MacOSNativeDisk.isPrepared(destination: f.runtime, imageDigest: "sha256:" + String(repeating: "b", count: 64))
        }
        let overlay = f.runtime.appendingPathComponent("active.asif")
        try FileManager.default.removeItem(at: overlay)
        try FileManager.default.createSymbolicLink(at: overlay, withDestinationURL: f.source.appendingPathComponent("base.img"))
        #expect(throws: (any Error).self) { try f.prepare() }
    }

    @Test
    func concurrentInitializerCannotAcquireTheSameDisk() throws {
        let f = try Fixture()
        defer { f.remove() }
        let fd = open(f.runtime.appendingPathComponent("native-disk.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: (any Error).self) { try f.prepare() }
    }

    private struct Fixture {
        let root: URL
        let runtime: URL
        let source: URL
        let digest = "sha256:" + String(repeating: "a", count: 64)
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-create-" + UUID().uuidString)
            runtime = root.appendingPathComponent("runtime")
            source = root.appendingPathComponent("source")
            for path in [root, runtime, source] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            for name in ["base.img", "HardwareModel.bin", "AuxiliaryStorage"] {
                try Data(name.utf8).write(to: source.appendingPathComponent(name))
            }
        }
        func prepare(createOverlay: (URL, URL) throws -> Void = { _, output in try Data("initial-overlay".utf8).write(to: output) }) throws {
            try MacOSNativeDisk.prepare(
                destination: runtime, imageDigest: digest, base: source.appendingPathComponent("base.img"),
                hardware: source.appendingPathComponent("HardwareModel.bin"), auxiliary: source.appendingPathComponent("AuxiliaryStorage"), createOverlay: createOverlay)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
