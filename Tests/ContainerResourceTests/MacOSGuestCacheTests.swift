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

@testable import ContainerResource

struct MacOSGuestCacheTests {
    @Test
    func cacheHitCleansInterruptedOutputButPreservesDiskAndActiveRebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = root.appendingPathComponent("sha256-live")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let disk = entry.appendingPathComponent("Disk.img")
        let temporary = entry.appendingPathComponent(".rebuild-\(UUID().uuidString).tmp")
        try Data("valid disk".utf8).write(to: disk)
        try Data("interrupted".utf8).write(to: temporary)
        let lock = try #require(try MacOSGuestCache.lockRebuildEntry(entry))
        try MacOSGuestCache.cleanInterruptedRebuilds(in: entry)
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        close(lock)
        try MacOSGuestCache.cleanInterruptedRebuilds(in: entry)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(try Data(contentsOf: disk) == Data("valid disk".utf8))
        try Data("another interrupted rebuild".utf8).write(to: temporary)
        _ = try MacOSGuestCache.pruneOrphanedRebuildCache(cacheDir: root, liveManifestDigests: ["sha256:live"])
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(FileManager.default.fileExists(atPath: disk.path))
    }

    @Test
    func rebuildCacheUsageAndPruneTrackOrphans() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("macos-guest-cache-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        let liveDigest = "sha256:live"
        let orphanDigest = "sha256:orphan"
        let liveEntry = tempDir.appendingPathComponent(MacOSGuestCache.safeDigest(liveDigest))
        let orphanEntry = tempDir.appendingPathComponent(MacOSGuestCache.safeDigest(orphanDigest))

        try fileManager.createDirectory(at: liveEntry, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: orphanEntry, withIntermediateDirectories: true)
        try self.writeFile(at: liveEntry.appendingPathComponent("Disk.img"), size: 256 * 1024, byte: 0x11)
        try self.writeFile(at: orphanEntry.appendingPathComponent("Disk.img"), size: 512 * 1024, byte: 0x22)

        let usage = try MacOSGuestCache.rebuildCacheUsage(
            cacheDir: tempDir,
            liveManifestDigests: [liveDigest]
        )

        #expect(usage.entryCount == 2)
        #expect(usage.liveEntryCount == 1)
        #expect(usage.sizeInBytes > 0)
        #expect(usage.reclaimableBytes > 0)
        #expect(usage.sizeInBytes >= usage.reclaimableBytes)

        let reclaimed = try MacOSGuestCache.pruneOrphanedRebuildCache(
            cacheDir: tempDir,
            liveManifestDigests: [liveDigest]
        )

        #expect(reclaimed == usage.reclaimableBytes)
        #expect(fileManager.fileExists(atPath: liveEntry.path))
        #expect(!fileManager.fileExists(atPath: orphanEntry.path))

        let afterUsage = try MacOSGuestCache.rebuildCacheUsage(
            cacheDir: tempDir,
            liveManifestDigests: [liveDigest]
        )

        #expect(afterUsage.entryCount == 1)
        #expect(afterUsage.liveEntryCount == 1)
        #expect(afterUsage.reclaimableBytes == 0)
    }

    @Test
    func pruningSkipsARebuildOwnedByAnotherFileDescriptor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = root.appendingPathComponent("sha256-test")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: entry.appendingPathComponent(".rebuild-test.tmp"))
        let owner = try #require(try MacOSGuestCache.lockRebuildEntry(entry))
        let reclaimed: UInt64
        do {
            defer { close(owner) }
            reclaimed = try MacOSGuestCache.pruneOrphanedRebuildCache(cacheDir: root, liveManifestDigests: [])
        }
        #expect(reclaimed == 0)
        #expect(FileManager.default.fileExists(atPath: entry.path))
        _ = try MacOSGuestCache.pruneOrphanedRebuildCache(cacheDir: root, liveManifestDigests: [])
        #expect(!FileManager.default.fileExists(atPath: entry.path))
        // Persistent lock files are infrastructure, not reclaimable cache entries.
        #expect(try MacOSGuestCache.rebuildCacheUsage(cacheDir: root, liveManifestDigests: []).entryCount == 0)
    }

    @Test
    func guestDiskCacheUsageTreatsAllEntriesAsReclaimable() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("macos-guest-disk-cache-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        let topLevelDirectory = tempDir.appendingPathComponent("bundle-a")
        try fileManager.createDirectory(at: topLevelDirectory, withIntermediateDirectories: true)
        try self.writeFile(at: topLevelDirectory.appendingPathComponent("Disk.img"), size: 128 * 1024, byte: 0x33)
        try self.writeFile(at: tempDir.appendingPathComponent("metadata.bin"), size: 64 * 1024, byte: 0x44)

        let usage = try MacOSGuestCache.guestDiskCacheUsage(cacheDir: tempDir)

        #expect(usage.entryCount == 2)
        #expect(usage.liveEntryCount == 0)
        #expect(usage.sizeInBytes > 0)
        #expect(usage.reclaimableBytes == usage.sizeInBytes)
    }

    private func writeFile(at url: URL, size: Int, byte: UInt8) throws {
        let data = Data(repeating: byte, count: size)
        try data.write(to: url)
    }
}
