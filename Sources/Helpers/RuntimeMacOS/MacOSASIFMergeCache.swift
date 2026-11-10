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
import ContainerizationOCI
import Darwin
import Foundation
import RuntimeMacOSSidecarShared

/// Cache entries belong to a selected OCI manifest. The original blobs remain
/// in the image store, and each started VM keeps its own cloned parent files.
enum MacOSASIFMergeCache {
    private static var fm: FileManager { .default }

    static func ready(manifestDigest: String, cacheDirectory: URL = MacOSGuestCache.rebuildCacheDirectory()) throws -> URL? {
        guard MacOSDiskChain.isDigest(manifestDigest) else { throw CocoaError(.fileReadCorruptFile) }
        let cache = cacheDirectory.appendingPathComponent(MacOSGuestCache.safeDigest(manifestDigest)).appendingPathComponent("asif-merge-v1")
        let overlay = cache.appendingPathComponent("merged.asif")
        guard fm.fileExists(atPath: cache.path) else { return nil }
        try validatePrivateDirectory(cache)
        let expected = try String(contentsOf: cache.appendingPathComponent("sha256"), encoding: .utf8)
        var value = stat()
        guard lstat(overlay.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(),
            value.st_mode & 0o222 == 0, try digest(overlay) == expected
        else { throw CocoaError(.fileReadCorruptFile) }
        return overlay
    }

    static func compact(
        manifestDigest: String, base: URL, parents: [URL], logicalSize: Int64,
        cacheDirectory: URL = MacOSGuestCache.rebuildCacheDirectory()
    ) throws {
        guard MacOSDiskChain.isDigest(manifestDigest), logicalSize > 0,
            logicalSize <= MacOSDiskChain.maximumLogicalSize
        else { throw CocoaError(.fileReadCorruptFile) }
        let cache = cacheDirectory.appendingPathComponent(MacOSGuestCache.safeDigest(manifestDigest))
        guard let lock = try MacOSGuestCache.lockRebuildEntry(cache, nonBlocking: true) else { return }
        defer { close(lock) }
        do {
            if try ready(manifestDigest: manifestDigest, cacheDirectory: cacheDirectory) != nil { return }
        } catch {
            // The equivalent cache is disposable. Instances have private clones.
            try fm.removeItem(at: cache.appendingPathComponent("asif-merge-v1"))
        }

        let jobs = cache.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("asif-merge-jobs-v2")
        try fm.createDirectory(at: jobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validatePrivateDirectory(jobs)
        let job = jobs.appendingPathComponent(cache.lastPathComponent)
        let sourceBase = job.appendingPathComponent("base.img")
        let outputBase = job.appendingPathComponent("target-base.img")
        let size = UInt64(logicalSize)
        func cleanJob() throws {
            try MacOSASIFCompactionJob.recover(base: sourceBase, size: size)
            try MacOSASIFCompactionJob.recover(base: outputBase, size: size)
            try fm.removeItem(at: job)
        }
        if fm.fileExists(atPath: job.path) {
            try validatePrivateDirectory(job)
            try cleanJob()
        }
        try fm.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? cleanJob() }
        let names = MacOSNativeDisk.parentNames(count: parents.count)
        guard names.count == parents.count else { throw CocoaError(.fileReadCorruptFile) }
        try cloneReadOnly(base, to: sourceBase)
        for (parent, name) in zip(parents, names) {
            try cloneReadOnly(parent, to: job.appendingPathComponent(name))
        }
        try MacOSASIFCompactionJob.run(directory: job, parentCount: parents.count)
        try publish(job.appendingPathComponent(MacOSASIFCompactionJob.outputName), cache: cache)
    }

    private static func cloneReadOnly(_ input: URL, to output: URL) throws {
        var value = stat()
        guard lstat(input.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard clonefile(input.path, output.path, UInt32(CLONE_NOFOLLOW)) == 0,
            chmod(output.path, 0o400) == 0
        else { throw posixError() }
    }

    private static func validatePrivateDirectory(_ directory: URL) throws {
        var value = stat()
        guard lstat(directory.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
            value.st_mode & 0o077 == 0, value.st_uid == geteuid()
        else { throw CocoaError(.fileReadNoPermission) }
    }

    private static func publish(_ output: URL, cache: URL) throws {
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let staging = cache.appendingPathComponent(".asif-merge-pending")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let overlay = staging.appendingPathComponent("merged.asif")
        try cloneReadOnly(output, to: overlay)
        let receipt = staging.appendingPathComponent("sha256")
        try digest(overlay).write(to: receipt, atomically: false, encoding: .utf8)
        try sync(overlay)
        try sync(receipt)
        try sync(staging)
        guard renamex_np(staging.path, cache.appendingPathComponent("asif-merge-v1").path, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError()
        }
        try sync(cache)
    }

    private static func digest(_ file: URL) throws -> String {
        try LocalContent(path: file).digest().map { String(format: "%02x", $0) }.joined()
    }

    private static func sync(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
