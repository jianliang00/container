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

#if os(macOS)
import Foundation

public struct MacOSGuestCacheUsage: Sendable, Equatable {
    public var entryCount: Int
    public var liveEntryCount: Int
    public var sizeInBytes: UInt64
    public var reclaimableBytes: UInt64

    public init(entryCount: Int, liveEntryCount: Int, sizeInBytes: UInt64, reclaimableBytes: UInt64) {
        self.entryCount = entryCount
        self.liveEntryCount = liveEntryCount
        self.sizeInBytes = sizeInBytes
        self.reclaimableBytes = reclaimableBytes
    }
}

public enum MacOSGuestCache {
    public static func rebuildCacheDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.apple.container/rebuild-cache")
    }

    public static func guestDiskCacheDirectory(appRoot: URL) -> URL {
        appRoot.appendingPathComponent("macos-guest-disk-cache")
    }

    public static func safeDigest(_ digest: String) -> String {
        digest.replacingOccurrences(of: ":", with: "-")
    }

    public static func rebuildCacheUsage(
        cacheDir: URL,
        liveManifestDigests: Set<String>,
        fileManager: FileManager = .default
    ) throws -> MacOSGuestCacheUsage {
        let liveCacheKeys = Set(liveManifestDigests.map(safeDigest))
        let entries = try topLevelEntries(at: cacheDir, fileManager: fileManager)

        var totalBytes: UInt64 = 0
        var reclaimableBytes: UInt64 = 0
        var liveEntryCount = 0

        for entry in entries {
            let size = try allocatedSize(at: entry, fileManager: fileManager)
            totalBytes += size

            if liveCacheKeys.contains(entry.lastPathComponent) {
                liveEntryCount += 1
            } else {
                reclaimableBytes += size
            }
        }

        return MacOSGuestCacheUsage(
            entryCount: entries.count,
            liveEntryCount: liveEntryCount,
            sizeInBytes: totalBytes,
            reclaimableBytes: reclaimableBytes
        )
    }

    public static func guestDiskCacheUsage(
        cacheDir: URL,
        fileManager: FileManager = .default
    ) throws -> MacOSGuestCacheUsage {
        let entries = try topLevelEntries(at: cacheDir, fileManager: fileManager)
        var totalBytes: UInt64 = 0

        for entry in entries {
            totalBytes += try allocatedSize(at: entry, fileManager: fileManager)
        }

        return MacOSGuestCacheUsage(
            entryCount: entries.count,
            liveEntryCount: 0,
            sizeInBytes: totalBytes,
            reclaimableBytes: totalBytes
        )
    }

    @discardableResult
    public static func pruneOrphanedRebuildCache(
        cacheDir: URL,
        liveManifestDigests: Set<String>,
        fileManager: FileManager = .default
    ) throws -> UInt64 {
        let liveCacheKeys = Set(liveManifestDigests.map(safeDigest))
        let entries = try topLevelEntries(at: cacheDir, fileManager: fileManager)
        var reclaimedBytes: UInt64 = 0

        for entry in entries {
            guard !liveCacheKeys.contains(entry.lastPathComponent) else {
                continue
            }

            reclaimedBytes += try allocatedSize(at: entry, fileManager: fileManager)
            try fileManager.removeItem(at: entry)
        }

        return reclaimedBytes
    }

    private static func topLevelEntries(
        at directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )
    }

    private static func allocatedSize(
        at url: URL,
        fileManager: FileManager
    ) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if values.isDirectory == true {
            return try directorySize(at: url, fileManager: fileManager)
        }

        if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
            return UInt64(size)
        }
        return 0
    }

    private static func directorySize(
        at directory: URL,
        fileManager: FileManager
    ) throws -> UInt64 {
        let resourceKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: []
            )
        else {
            return 0
        }

        var size: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            if let fileSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                size += UInt64(fileSize)
            }
        }
        return size
    }
}
#endif
