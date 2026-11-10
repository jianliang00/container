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

/// A cold disk import, supplied by a trusted host-side storage controller.
/// This format contains disk and platform files, never memory or credentials.
public enum MacOSLocalDiskBundle {
    public static let fileNames = ["Disk.img", "AuxiliaryStorage", "HardwareModel.bin", "MachineIdentifier.bin"]

    public enum Format: Sendable, Equatable {
        case raw
        case nativeASIF
        case nativeASIFChain(parentCount: Int)
        case nativeASIFOCIChain(parentCount: Int)

        fileprivate var version: Int {
            switch self {
            case .raw: 1
            case .nativeASIF: 3
            case .nativeASIFChain: 4
            case .nativeASIFOCIChain: 5
            }
        }

        fileprivate var parents: [String] {
            switch self {
            case .nativeASIFChain(let count), .nativeASIFOCIChain(let count): MacOSNativeDisk.parentNames(count: count)
            case .raw, .nativeASIF: []
            }
        }

        fileprivate var names: [String] {
            switch self {
            case .raw: fileNames
            case .nativeASIFChain: parents + Array(fileNames.dropFirst())
            case .nativeASIF, .nativeASIFOCIChain: parents + ["active.asif"] + Array(fileNames.dropFirst())
            }
        }
    }

    public static func parentNames(count: Int) -> [String] {
        MacOSNativeDisk.parentNames(count: count)
    }

    public struct Manifest: Codable, Sendable {
        public struct File: Codable, Sendable {
            public var name: String
            public var size: Int64
            public var sha256: String?
        }
        public struct NativeBase: Codable, Equatable, Sendable {
            public var reference: String
            public var sha256: String
            public var size: Int64
        }
        public var version: Int
        public var persistenceID: String
        public var storageGeneration: UInt64
        public var files: [File]
        public var nativeBase: NativeBase?
    }

    public static func install(
        storageDirectory: String, persistenceID: String, generation: UInt64, digest: String, destination: URL,
        format requestedFormat: Format = .raw, allowLegacyASIFChain: Bool = false,
        createOverlay: ((URL, [URL], URL) throws -> Void)? = nil
    ) throws {
        guard let storage = MacOSManagedPath.canonicalPath(storageDirectory), generation > 0,
            digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw CocoaError(.fileReadCorruptFile) }
        if requestedFormat.version >= 4, requestedFormat.parents.isEmpty {
            throw CocoaError(.fileReadCorruptFile)
        }
        let native = requestedFormat != .raw
        try validateDirectory(destination)
        let fm = FileManager.default
        let marker = destination.appendingPathComponent("disk-bundle-imported")
        let pending = destination.appendingPathComponent("disk-bundle-importing")
        let retainedManifest = destination.appendingPathComponent("disk-bundle-manifest.json")
        let active = destination.appendingPathComponent("active.asif")
        if native, fm.fileExists(atPath: destination.appendingPathComponent("Disk.img").path) {
            throw CocoaError(.fileWriteFileExists)
        }
        if fm.fileExists(atPath: marker.path) {
            guard try readRegular(marker, limit: 64) == Data(digest.utf8) else { throw CocoaError(.fileReadCorruptFile) }
            var format = requestedFormat
            if native {
                let result = try readManifest(
                    retainedManifest, digest: digest, persistenceID: persistenceID, generation: generation, format: requestedFormat,
                    allowLegacyASIFChain: allowLegacyASIFChain)
                let manifest = result.manifest
                format = result.format
                guard let base = manifest.nativeBase else { throw CocoaError(.fileReadCorruptFile) }
                try validateBase(destination.appendingPathComponent("base.img"), base: base)
                for entry in manifest.files where format.parents.contains(entry.name) {
                    let parent = destination.appendingPathComponent(entry.name)
                    try validateFile(parent, size: entry.size)
                    var value = stat()
                    guard lstat(parent.path, &value) == 0, value.st_mode & 0o222 == 0 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
            }
            if case .nativeASIFChain = format { try validateNonemptyFile(active) }
            for name in format.names {
                let file = destination.appendingPathComponent(name)
                var value = stat()
                guard lstat(file.path, &value) == 0, value.st_size > 0 else { throw CocoaError(.fileReadCorruptFile) }
                try validateFile(file, size: value.st_size)
            }
            try validateActiveIdentity(storage: URL(fileURLWithPath: storage), runtime: destination)
            return
        }
        let source = URL(fileURLWithPath: storage).appendingPathComponent("disks/g\(generation)")
        try validateDirectory(source)
        let manifestURL = source.appendingPathComponent("disk-bundle.json")
        let (manifest, format) = try readManifest(
            manifestURL, digest: digest, persistenceID: persistenceID, generation: generation, format: requestedFormat,
            allowLegacyASIFChain: allowLegacyASIFChain)
        let createsOverlay = format.version == 4
        if createsOverlay, createOverlay == nil { throw CocoaError(.fileReadCorruptFile) }
        if fm.fileExists(atPath: pending.path) {
            guard try readRegular(pending, limit: 64) == Data(digest.utf8) else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            var requiredNames = format.names + (native ? ["base.img", "disk-bundle-manifest.json"] : [])
            if createsOverlay { requiredNames.append("active.asif") }
            guard requiredNames.allSatisfy({ !fm.fileExists(atPath: destination.appendingPathComponent($0).path) }) else { throw CocoaError(.fileWriteFileExists) }
            try Data(digest.utf8).write(to: pending, options: .withoutOverwriting)
            try synchronize(pending)
            try synchronize(destination, directory: true)
        }
        if let base = manifest.nativeBase {
            let from = source.appendingPathComponent("base.img")
            let to = destination.appendingPathComponent("base.img")
            try validateBase(from, base: base)
            if !fm.fileExists(atPath: to.path) {
                let clone = try MacOSNativeBaseReceipt.clone(from, to: to, immutableSource: true)
                clone?.inherit(reference: base.reference, expected: base)
            }
            try validateBase(to, base: base)
            try synchronize(to)
        }
        for entry in manifest.files {
            let from = source.appendingPathComponent(entry.name)
            try validateFile(from, size: entry.size)
            let to = destination.appendingPathComponent(entry.name)
            if let expected = entry.sha256, native { try verifyDigest(from, expected: expected) }
            if !fm.fileExists(atPath: to.path) { try cloneMember(from, to: to) }
            try validateFile(to, size: entry.size)
            if let expected = entry.sha256, native { try verifyDigest(to, expected: expected) }
            if native, chmod(to.path, format.parents.contains(entry.name) ? 0o400 : 0o600) != 0 { throw POSIXError(.EIO) }
            try synchronize(to)
        }
        if createsOverlay, let createOverlay, !fm.fileExists(atPath: active.path) {
            let temporary = destination.appendingPathComponent(".bundle-overlay-" + UUID().uuidString)
            defer { try? fm.removeItem(at: temporary) }
            try createOverlay(destination.appendingPathComponent("base.img"), format.parents.map { destination.appendingPathComponent($0) }, temporary)
            try validateNonemptyFile(temporary)
            guard chmod(temporary.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            try synchronize(temporary)
            guard renamex_np(temporary.path, active.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(.EIO) }
        }
        if createsOverlay { try validateNonemptyFile(active) }
        if native {
            let data = try readRegular(manifestURL, limit: 65536)
            if fm.fileExists(atPath: retainedManifest.path) {
                guard try readRegular(retainedManifest, limit: 65536) == data else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                try cloneMember(manifestURL, to: retainedManifest)
            }
            _ = try readManifest(retainedManifest, digest: digest, persistenceID: persistenceID, generation: generation, format: format)
            try synchronize(retainedManifest)
        }
        try installActiveIdentity(storage: URL(fileURLWithPath: storage), runtime: destination)
        guard rename(pending.path, marker.path) == 0 else { throw POSIXError(.EIO) }
        try synchronize(destination, directory: true)
    }

    private static func readManifest(
        _ url: URL, digest: String, persistenceID: String, generation: UInt64, format requestedFormat: Format,
        allowLegacyASIFChain: Bool = false
    ) throws -> (manifest: Manifest, format: Format) {
        let data = try readRegular(url, limit: 65536)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { throw CocoaError(.fileReadCorruptFile) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let format: Format
        if allowLegacyASIFChain, manifest.version == 4, case .nativeASIFOCIChain(let count) = requestedFormat {
            format = .nativeASIFChain(parentCount: count)
        } else {
            format = requestedFormat
        }
        guard manifest.version == format.version, manifest.persistenceID == persistenceID,
            manifest.storageGeneration == generation, manifest.files.map(\.name) == format.names,
            manifest.files.allSatisfy({ $0.size > 0 && $0.size <= 1 << 40 })
        else { throw CocoaError(.fileReadCorruptFile) }
        switch format {
        case .raw:
            guard manifest.nativeBase == nil else { throw CocoaError(.fileReadCorruptFile) }
        case .nativeASIF, .nativeASIFChain, .nativeASIFOCIChain:
            guard let base = manifest.nativeBase, !base.reference.isEmpty, validDigest(base.sha256),
                base.size > 0, base.size <= 1 << 40, manifest.files.allSatisfy({ validDigest($0.sha256 ?? "") })
            else { throw CocoaError(.fileReadCorruptFile) }
        }
        return (manifest, format)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // The trusted host materializer authenticates the base against its retained
    // catalog before publishing this bundle. Import pins that immutable inode;
    // it never downloads a base or follows an archive-controlled location.
    private static func validateBase(_ url: URL, base: Manifest.NativeBase) throws {
        try validateFile(url, size: base.size)
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & 0o222 == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    static func cloneMember(_ source: URL, to destination: URL) throws {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fclonefileat(fd, AT_FDCWD, destination.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func verifyDigest(_ url: URL, expected: String) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { digest.update(data: data) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw CocoaError(.fileReadCorruptFile) }
    }

    // The sidecar uses the persistent Identity directory, rather than the
    // runtime's template firmware. Include it in the import transaction before
    // publishing the marker. A committed import must never rewind live firmware.
    private static func installActiveIdentity(storage: URL, runtime: URL) throws {
        try validateDirectory(storage)
        let identity = storage.appendingPathComponent("Identity")
        let fm = FileManager.default
        if !fm.fileExists(atPath: identity.path) {
            try fm.createDirectory(at: identity, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try synchronize(storage, directory: true)
        }
        try validateDirectory(identity)
        let machine = identity.appendingPathComponent("MachineIdentifier.bin")
        let auxiliary = identity.appendingPathComponent("AuxiliaryStorage")
        let incomingMachine = try readRegular(runtime.appendingPathComponent("MachineIdentifier.bin"), limit: 4096)
        if fm.fileExists(atPath: machine.path) {
            guard try readRegular(machine, limit: 4096) == incomingMachine else { throw CocoaError(.fileReadCorruptFile) }
        } else if fm.fileExists(atPath: auxiliary.path) {
            throw CocoaError(.fileReadCorruptFile)
        }
        if fm.fileExists(atPath: auxiliary.path) { try validateNonemptyFile(auxiliary) }
        for name in ["MachineIdentifier.bin", "AuxiliaryStorage"] {
            let staged = identity.appendingPathComponent(".import-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            let from = runtime.appendingPathComponent(name)
            try validateNonemptyFile(from)
            guard clonefile(from.path, staged.path, UInt32(CLONE_NOFOLLOW)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard chmod(staged.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            try synchronize(staged)
            guard rename(staged.path, identity.appendingPathComponent(name).path) == 0 else { throw POSIXError(.EIO) }
            try synchronize(identity, directory: true)
        }
    }

    private static func validateActiveIdentity(storage: URL, runtime: URL) throws {
        let identity = storage.appendingPathComponent("Identity")
        try validateDirectory(identity)
        guard
            try readRegular(identity.appendingPathComponent("MachineIdentifier.bin"), limit: 4096)
                == readRegular(runtime.appendingPathComponent("MachineIdentifier.bin"), limit: 4096)
        else { throw CocoaError(.fileReadCorruptFile) }
        try validateNonemptyFile(identity.appendingPathComponent("AuxiliaryStorage"))
    }

    static func validateNonemptyFile(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_size > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try validateFile(url, size: value.st_size)
    }

    static func synchronize(_ url: URL, directory: Bool = false) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func validateDirectory(_ url: URL) throws {
        guard var path = MacOSManagedPath.canonicalPath(url.path) else { throw CocoaError(.fileReadNoPermission) }
        while path != "/" {
            var value = stat()
            guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
                value.st_uid == 0 || value.st_uid == geteuid(),
                MacOSManagedPath.hasTrustedParentWritePermissions(path: path, ownerID: value.st_uid, groupID: value.st_gid, mode: value.st_mode)
            else { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path]) }
            guard let slash = path.lastIndex(of: "/") else { throw CocoaError(.fileReadNoPermission) }
            path = slash == path.startIndex ? "/" : String(path[..<slash])
        }
    }

    private static func validateFile(_ url: URL, size: Int64) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
            value.st_uid == geteuid(), value.st_mode & 0o022 == 0, value.st_size == size
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    static func readRegular(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size <= limit,
            value.st_uid == geteuid(), value.st_mode & 0o022 == 0
        else { throw CocoaError(.fileReadCorruptFile) }
        return try handle.readToEnd() ?? Data()
    }
}
