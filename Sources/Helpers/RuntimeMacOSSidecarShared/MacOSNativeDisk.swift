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

/// Prepares an initial native disk from a trusted OCI template. A durable intent
/// owns partial creation; a committed disk is never re-created on restart.
public enum MacOSNativeDisk {
    public static var available: Bool {
        #if canImport(DiskImageKit)
        if #available(macOS 27, *) { return true }
        #endif
        return false
    }

    private static let marker = "native-disk-created"
    private static let pending = "native-disk-creating"
    private static let members = ["base.img", "active.asif", "HardwareModel.bin", "AuxiliaryStorage"]

    /// Checks the published files without needing the image cache to remain.
    public static func isPrepared(destination: URL, imageDigest: String) throws -> Bool {
        try checkDigest(imageDigest)
        try MacOSLocalDiskBundle.validateDirectory(destination)
        let receipt = destination.appendingPathComponent(marker)
        guard try exists(receipt) else { return false }
        guard try MacOSLocalDiskBundle.readRegular(receipt, limit: 80) == Data(imageDigest.utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for name in members { try MacOSLocalDiskBundle.validateNonemptyFile(destination.appendingPathComponent(name)) }
        try validateBase(destination.appendingPathComponent("base.img"))
        return true
    }

    /// The runtime supplies its platform overlay creator; this transaction layer
    /// does not link DiskImageKit into guest-agent or CRI binaries.
    public static func prepare(
        destination: URL, imageDigest: String, base: URL, hardware: URL, auxiliary: URL,
        createOverlay: (URL, URL) throws -> Void
    ) throws {
        try checkDigest(imageDigest)
        try MacOSLocalDiskBundle.validateDirectory(destination)
        let lock = destination.appendingPathComponent("native-disk.lock")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
            value.st_uid == geteuid(), value.st_mode & 0o077 == 0
        else { throw CocoaError(.fileReadNoPermission) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        if try isPrepared(destination: destination, imageDigest: imageDigest) { return }
        // Imported disk bundles and initial OCI disks have separate ownership.
        for name in ["Disk.img", "disk-bundle-imported", "disk-bundle-importing"] {
            guard try !exists(destination.appendingPathComponent(name)) else { throw CocoaError(.fileWriteFileExists) }
        }
        let intent = destination.appendingPathComponent(pending)
        let receipt = Data(imageDigest.utf8)
        if try exists(intent) {
            guard try MacOSLocalDiskBundle.readRegular(intent, limit: 80) == receipt else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            for name in members {
                guard try !exists(destination.appendingPathComponent(name)) else { throw CocoaError(.fileWriteFileExists) }
            }
            try receipt.write(to: intent, options: .withoutOverwriting)
            try MacOSLocalDiskBundle.synchronize(intent)
            try MacOSLocalDiskBundle.synchronize(destination, directory: true)
        }
        for (name, source) in [("base.img", base), ("HardwareModel.bin", hardware), ("AuxiliaryStorage", auxiliary)] {
            let output = destination.appendingPathComponent(name)
            if try !exists(output) {
                try MacOSLocalDiskBundle.validateDirectory(source.deletingLastPathComponent())
                try MacOSLocalDiskBundle.validateNonemptyFile(source)
                let temporary = destination.appendingPathComponent(".native-template-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try MacOSLocalDiskBundle.cloneMember(source, to: temporary)
                try MacOSLocalDiskBundle.validateNonemptyFile(temporary)
                guard chmod(temporary.path, name == "base.img" ? 0o400 : 0o600) == 0 else { throw POSIXError(.EIO) }
                try MacOSLocalDiskBundle.synchronize(temporary)
                guard renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(.EIO) }
            }
            try MacOSLocalDiskBundle.validateNonemptyFile(output)
            if name == "base.img" { try validateBase(output) }
            try MacOSLocalDiskBundle.synchronize(output)
        }
        let baseURL = destination.appendingPathComponent("base.img")
        let overlay = destination.appendingPathComponent("active.asif")
        if try !exists(overlay) {
            let temporary = destination.appendingPathComponent(".native-overlay-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try createOverlay(baseURL, temporary)
            try MacOSLocalDiskBundle.validateNonemptyFile(temporary)
            guard chmod(temporary.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            try MacOSLocalDiskBundle.synchronize(temporary)
            // Never replace a disk another initializer may have published.
            guard renamex_np(temporary.path, overlay.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(.EIO) }
        }
        try MacOSLocalDiskBundle.validateNonemptyFile(overlay)
        try MacOSLocalDiskBundle.synchronize(overlay)
        try MacOSLocalDiskBundle.synchronize(destination, directory: true)
        guard renamex_np(intent.path, destination.appendingPathComponent(marker).path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(.EIO) }
        try MacOSLocalDiskBundle.synchronize(destination, directory: true)
    }

    private static func checkDigest(_ digest: String) throws {
        guard digest.hasPrefix("sha256:"), digest.count == 71,
            digest.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    private static func exists(_ url: URL) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 { return true }
        guard errno == ENOENT else { throw POSIXError(.EIO) }
        return false
    }

    private static func validateBase(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & 0o222 == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

}
