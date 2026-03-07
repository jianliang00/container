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
