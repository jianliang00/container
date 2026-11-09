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

/// Wire-compatible with the node agent's nativeBaseReceipt. Receipts are
/// local metadata and must only be read from trusted host directories.
struct MacOSNativeBaseReceipt: Codable, Sendable {
    typealias Base = MacOSLocalDiskBundle.Manifest.NativeBase

    struct Stamp: Codable, Equatable, Sendable {
        struct Time: Codable, Equatable, Sendable {
            let Sec: Int
            let Nsec: Int

            init(_ value: timespec) {
                Sec = value.tv_sec
                Nsec = value.tv_nsec
            }
        }

        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mode: UInt32
        let uid: UInt32
        let modified: Time
        let changed: Time

        init(_ fd: Int32, immutable: Bool = false) throws {
            var value = stat()
            guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                value.st_uid == 0 || value.st_uid == geteuid(),
                value.st_mode & (immutable ? 0o222 : 0o022) == 0,
                value.st_size > 0, value.st_size <= 1 << 40
            else { throw CocoaError(.fileReadCorruptFile) }
            device = UInt64(bitPattern: Int64(value.st_dev))
            inode = value.st_ino
            size = value.st_size
            mode = UInt32(value.st_mode)
            uid = value.st_uid
            modified = Time(value.st_mtimespec)
            changed = Time(value.st_ctimespec)
        }
    }

    let version: Int
    let base: Base
    let stamp: Stamp

    /// A provenance token comes only from a successful fd-based clone. It is
    /// never reconstructed for a destination left by an interrupted attempt.
    struct Clone: Sendable {
        fileprivate let source: URL
        fileprivate let sourceStamp: Stamp
        fileprivate let destination: URL
        fileprivate let destinationStamp: Stamp

        @discardableResult
        func inherit(reference: String, expected: Base? = nil) -> Bool {
            guard let base = cachedBase(reference: reference, expected: expected) else { return false }
            return (try? publish(base)) == true
        }

        private func cachedBase(reference: String, expected: Base? = nil) -> Base? {
            guard let receipt = try? MacOSNativeBaseReceipt.read(source), receipt.stamp == sourceStamp,
                expected == nil || receipt.base == expected
            else { return nil }
            return Base(reference: reference, sha256: receipt.base.sha256, size: receipt.base.size)
        }

        /// Scan the OCI cache in the background. Limit a rebuild cache to one
        /// concurrent full scan so simultaneous VM boots do not saturate it.
        func preverify(reference: String) {
            DispatchQueue.global(qos: .utility).async {
                try? verify(reference: reference)
            }
        }

        func verify(reference: String) throws {
            try MacOSLocalDiskBundle.validateDirectory(source.deletingLastPathComponent())
            let lock = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".native-base-verify.lock")
            let lockFD = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { return }
            defer { close(lockFD) }
            var value = stat()
            guard fstat(lockFD, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                value.st_uid == geteuid(), value.st_mode & 0o077 == 0,
                flock(lockFD, LOCK_EX | LOCK_NB) == 0
            else { return }
            if let cached = cachedBase(reference: reference) {
                _ = try publish(cached)
                return
            }
            let fd = try MacOSNativeBaseReceipt.openDisk(source)
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            guard try Stamp(fd) == sourceStamp else { return }
            var hash = SHA256()
            var bytes: Int64 = 0
            while let block = try file.read(upToCount: 4 << 20), !block.isEmpty {
                hash.update(data: block)
                bytes += Int64(block.count)
            }
            guard bytes == sourceStamp.size, try Stamp(fd) == sourceStamp else { return }
            let base = Base(reference: reference, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), size: bytes)
            try MacOSNativeBaseReceipt(version: 1, base: base, stamp: sourceStamp).write(source)
            _ = try publish(base)
        }

        private func publish(_ base: Base) throws -> Bool {
            try MacOSLocalDiskBundle.validateDirectory(destination.deletingLastPathComponent())
            let fd = try MacOSNativeBaseReceipt.openDisk(destination)
            defer { close(fd) }
            guard base.size == destinationStamp.size, try Stamp(fd, immutable: true) == destinationStamp else { return false }
            try MacOSNativeBaseReceipt(version: 1, base: base, stamp: destinationStamp).write(destination)
            return true
        }
    }

    static func clone(_ source: URL, to destination: URL, immutableSource: Bool) throws -> Clone? {
        let fd = try openDisk(source)
        defer { close(fd) }
        // Preserve the normal clone path for legacy or non-receiptable sources.
        let before = try? Stamp(fd, immutable: immutableSource)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".native-base-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard fclonefileat(fd, AT_FDCWD, temporary.path, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard chmod(temporary.path, 0o400) == 0 else { throw POSIXError(.EIO) }
        try MacOSLocalDiskBundle.synchronize(temporary)
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(.EIO) }
        guard let before, (try? Stamp(fd, immutable: immutableSource)) == before else { return nil }
        let output = try openDisk(destination)
        defer { close(output) }
        guard let stamp = try? Stamp(output, immutable: true), stamp.size == before.size else { return nil }
        return Clone(source: source, sourceStamp: before, destination: destination, destinationStamp: stamp)
    }

    static func read(_ disk: URL) throws -> Self {
        let data = try MacOSLocalDiskBundle.readRegular(disk.appendingPathExtension("verified.json"), limit: 65536)
        let receipt = try JSONDecoder().decode(Self.self, from: data)
        guard receipt.version == 1, receipt.base.size == receipt.stamp.size, receipt.base.sha256.count == 64,
            receipt.base.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw CocoaError(.fileReadCorruptFile) }
        return receipt
    }

    private func write(_ disk: URL) throws {
        let target = disk.appendingPathExtension("verified.json")
        let staged = target.deletingLastPathComponent().appendingPathComponent(".native-verification-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try JSONEncoder().encode(self).write(to: staged, options: .withoutOverwriting)
        guard chmod(staged.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        try MacOSLocalDiskBundle.synchronize(staged)
        guard rename(staged.path, target.path) == 0 else { throw POSIXError(.EIO) }
        try MacOSLocalDiskBundle.synchronize(target.deletingLastPathComponent(), directory: true)
    }

    private static func openDisk(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }
}
