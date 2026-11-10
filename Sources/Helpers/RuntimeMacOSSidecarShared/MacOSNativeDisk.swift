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
    private static let compacted = "native-disk-compacted"
    private static let members = ["base.img", "active.asif", "HardwareModel.bin", "AuxiliaryStorage"]

    public static func parentNames(count: Int) -> [String] {
        guard (1...3).contains(count) else { return [] }
        return (1...count).map { String(format: "parent-%02d.asif", $0) }
    }

    /// Checks the published files without needing the image cache to remain.
    public static func isPrepared(destination: URL, imageDigest: String, parentNames: [String] = []) throws -> Bool {
        try checkDigest(imageDigest)
        try MacOSLocalDiskBundle.validateDirectory(destination)
        let receipt = destination.appendingPathComponent(marker)
        guard try exists(receipt) else { return false }
        guard try MacOSLocalDiskBundle.readRegular(receipt, limit: 80) == Data(imageDigest.utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for name in members { try MacOSLocalDiskBundle.validateNonemptyFile(destination.appendingPathComponent(name)) }
        for name in ["base.img"] + (try effectiveParentNames(in: destination, configured: parentNames)) {
            let url = destination.appendingPathComponent(name)
            try MacOSLocalDiskBundle.validateNonemptyFile(url)
            try validateBase(url)
        }
        return true
    }

    /// The runtime supplies its platform overlay creator; this transaction layer
    /// does not link DiskImageKit into guest-agent or CRI binaries.
    @discardableResult
    public static func prepare(
        destination: URL, imageDigest: String, base: URL, hardware: URL, auxiliary: URL,
        imageReference: String? = nil,
        createOverlay: (URL, URL) throws -> Void
    ) throws -> (@Sendable () -> Void)? {
        try prepare(
            destination: destination, imageDigest: imageDigest, base: base, parents: [],
            hardware: hardware, auxiliary: auxiliary, imageReference: imageReference
        ) { base, _, overlay in
            try createOverlay(base, overlay)
        }
    }

    @discardableResult
    public static func prepare(
        destination: URL, imageDigest: String, base: URL, parents: [URL], hardware: URL, auxiliary: URL,
        imageReference: String? = nil, compactedParent: URL? = nil,
        createOverlay: (URL, [URL], URL) throws -> Void
    ) throws -> (@Sendable () -> Void)? {
        try checkDigest(imageDigest)
        let originalNames = parentNames(count: parents.count)
        guard originalNames.count == parents.count else { throw CocoaError(.fileReadCorruptFile) }
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
        if try isPrepared(destination: destination, imageDigest: imageDigest, parentNames: originalNames) { return nil }
        // Imported disk bundles and initial OCI disks have separate ownership.
        for name in ["Disk.img", "disk-bundle-imported", "disk-bundle-importing"] {
            guard try !exists(destination.appendingPathComponent(name)) else { throw CocoaError(.fileWriteFileExists) }
        }
        let intent = destination.appendingPathComponent(pending)
        let receipt = Data(imageDigest.utf8)
        if try exists(intent) {
            guard try MacOSLocalDiskBundle.readRegular(intent, limit: 80) == receipt else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            for name in members + originalNames + [compacted] {
                guard try !exists(destination.appendingPathComponent(name)) else { throw CocoaError(.fileWriteFileExists) }
            }
            try receipt.write(to: intent, options: .withoutOverwriting)
            try MacOSLocalDiskBundle.synchronize(intent)
            if originalNames.count >= 2, compactedParent != nil {
                let selected = destination.appendingPathComponent(compacted)
                try Data([1]).write(to: selected, options: .atomic)
                try MacOSLocalDiskBundle.synchronize(selected)
            }
            try MacOSLocalDiskBundle.synchronize(destination, directory: true)
        }
        let parentNames = try effectiveParentNames(in: destination, configured: originalNames)
        let sources: [URL]
        if parentNames.count == originalNames.count {
            sources = parents
        } else {
            let installed = destination.appendingPathComponent(parentNames[0])
            let installedSource = try exists(installed) ? installed : nil
            guard let source = compactedParent ?? installedSource else {
                throw CocoaError(.fileNoSuchFile)
            }
            sources = [source]
        }
        var preverification: MacOSNativeBaseReceipt.Clone?
        let artifacts = [("base.img", base), ("HardwareModel.bin", hardware), ("AuxiliaryStorage", auxiliary)] + Array(zip(parentNames, sources))
        for (name, source) in artifacts {
            let immutable = name == "base.img" || parentNames.contains(name)
            let output = destination.appendingPathComponent(name)
            if try !exists(output) {
                try MacOSLocalDiskBundle.validateDirectory(source.deletingLastPathComponent())
                try MacOSLocalDiskBundle.validateNonemptyFile(source)
                if name == "base.img" {
                    preverification = try MacOSNativeBaseReceipt.clone(source, to: output, immutableSource: false)
                } else {
                    let temporary = destination.appendingPathComponent(".native-template-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try MacOSLocalDiskBundle.cloneMember(source, to: temporary)
                    try MacOSLocalDiskBundle.validateNonemptyFile(temporary)
                    guard chmod(temporary.path, immutable ? 0o400 : 0o600) == 0 else { throw POSIXError(.EIO) }
                    try MacOSLocalDiskBundle.synchronize(temporary)
                    guard renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(.EIO) }
                }
            }
            try MacOSLocalDiskBundle.validateNonemptyFile(output)
            if immutable { try validateBase(output) }
            try MacOSLocalDiskBundle.synchronize(output)
        }
        let baseURL = destination.appendingPathComponent("base.img")
        let overlay = destination.appendingPathComponent("active.asif")
        if try !exists(overlay) {
            let temporary = destination.appendingPathComponent(".native-overlay-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try createOverlay(baseURL, parentNames.map { destination.appendingPathComponent($0) }, temporary)
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
        guard let reference = imageReference, reference.hasSuffix("@" + imageDigest), base.lastPathComponent == "Disk.img",
            let preverification, !preverification.inherit(reference: reference)
        else { return nil }
        return { preverification.preverify(reference: reference) }
    }

    /// A compacted instance records its selected parent count before first boot.
    public static func effectiveParentNames(in root: URL, configured: [String]) throws -> [String] {
        let selection = root.appendingPathComponent(compacted)
        guard try exists(selection) else { return configured }
        guard configured.count >= 2, try MacOSLocalDiskBundle.readRegular(selection, limit: 1) == Data([1]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return parentNames(count: 1)
    }

    /// A stopped disk can be sealed only while no sidecar can start writing it.
    public static func acquireLifecycleLease(in directory: URL) throws -> FileHandle {
        try MacOSLocalDiskBundle.validateDirectory(directory)
        let path = directory.appendingPathComponent("native-disk-lifecycle.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
            value.st_uid == geteuid(), value.st_mode & 0o077 == 0
        else { throw CocoaError(.fileReadNoPermission) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        return handle
    }

    public static func sealedDirectory(in root: URL, id: UUID) -> URL {
        root.appendingPathComponent("sealed-native-\(id.uuidString)", isDirectory: true)
    }

    /// The caller must own the filesystem checkpoint or the stopped lifecycle lease.
    public static func seal(
        in root: URL, auxiliary: URL, parents: [String], id: UUID
    ) throws {
        guard parents == parentNames(count: parents.count) else { throw CocoaError(.fileReadCorruptFile) }
        let fm = FileManager.default
        let destination = sealedDirectory(in: root, id: id)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let disks = (parents + ["active.asif"]).map { ($0, root.appendingPathComponent($0)) }
            for (name, source) in disks + [("AuxiliaryStorage", auxiliary)] {
                try MacOSLocalDiskBundle.validateNonemptyFile(source)
                try MacOSLocalDiskBundle.synchronize(source)
                let output = destination.appendingPathComponent(name)
                guard clonefile(source.path, output.path, UInt32(CLONE_NOFOLLOW)) == 0, chmod(output.path, 0o400) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try MacOSLocalDiskBundle.synchronize(output)
            }
            try MacOSLocalDiskBundle.synchronize(destination, directory: true)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
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
