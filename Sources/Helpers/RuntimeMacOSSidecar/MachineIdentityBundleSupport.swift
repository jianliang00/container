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

/// Persists the host-independent VM identity needed to pair a disk snapshot
/// with either a same-host machine-state restore or a cross-host cold boot.
/// The bundle lives beside the machine-state file so archival code can treat a
/// committed state directory as one self-contained recovery unit.
struct MacOSMachineIdentityBundleStore: Sendable {
    struct Manifest: Codable, Equatable, Sendable {
        struct FileRecord: Codable, Equatable, Sendable {
            let name: String
            let size: UInt64
            let sha256: String
        }

        let schemaVersion: Int
        let files: [FileRecord]
    }

    static let bundleDirectoryName = "Identity"
    static let manifestFilename = "manifest.json"

    private static let requiredFilenames = [
        "HardwareModel.bin",
        "MachineIdentifier.bin",
        "AuxiliaryStorage",
    ]
    private static let optionalFilenames = ["macos-guest-network-lease.json"]
    private static let maximumManifestSize = 64 * 1024

    /// Captures an immutable identity bundle. `stateDirectoryURL` must be a
    /// newly reserved, private machine-state directory.
    static func capture(from runtimeRootURL: URL, into stateDirectoryURL: URL) throws {
        try capture(from: MacOSActiveMachineIdentity(runtimeRootURL: runtimeRootURL), into: stateDirectoryURL)
    }

    static func capture(
        from identity: MacOSActiveMachineIdentity,
        into stateDirectoryURL: URL,
        compatibility: MacOSMachineStateCompatibilityDescription? = nil
    ) throws {
        guard !identity.isPersistent || compatibility != nil else {
            throw SidecarRPCError(code: "identityBundleMismatch", message: "persistent identity capture requires the configured VM compatibility description")
        }
        try identity.validateDirectories()
        let stateDirectory = try lexicalDirectoryURL(stateDirectoryURL)
        try requireManagedDirectory(stateDirectory, role: "machine-state directory", requirePrivateMode: true)

        let finalURL = stateDirectory.appendingPathComponent(bundleDirectoryName, isDirectory: true)
        guard try pathStatus(finalURL) == .missing else {
            throw SidecarRPCError(code: "identityBundleAlreadyExists", message: "VM identity bundle already exists")
        }

        let temporaryURL = stateDirectory.appendingPathComponent(
            ".identity-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        try requireManagedDirectory(temporaryURL, role: "temporary identity bundle", requirePrivateMode: true)

        var records: [Manifest.FileRecord] = []
        for filename in requiredFilenames + optionalFilenames {
            let sourceURL = try identity.fileURL(for: filename)
            if optionalFilenames.contains(filename), try pathStatus(sourceURL) == .missing {
                continue
            }
            let destinationURL = temporaryURL.appendingPathComponent(filename)
            records.append(try copyAndDigest(from: sourceURL, to: destinationURL, expected: nil))
        }
        let manifest = Manifest(schemaVersion: 1, files: records.sorted { $0.name < $1.name })
        try validateManifest(manifest)
        if let compatibility { try validateBinding(manifest, compatibility: compatibility) }
        try writeManifest(manifest, to: temporaryURL.appendingPathComponent(manifestFilename))
        try syncDirectory(temporaryURL)

        guard rename(temporaryURL.path, finalURL.path) == 0 else {
            throw posixError(code: "identityBundleCommitFailed", message: "failed to publish VM identity bundle")
        }
        published = true
        try syncDirectory(stateDirectory)
    }

    /// Verifies every file before replacing any runtime identity file. A
    /// retry after a crash is safe: all target files are staged again and then
    /// atomically replaced one at a time before VM configuration is created.
    static func materialize(from stateDirectoryURL: URL, into runtimeRootURL: URL) throws {
        try materialize(from: stateDirectoryURL, into: MacOSActiveMachineIdentity(runtimeRootURL: runtimeRootURL))
    }

    static func materialize(
        from stateDirectoryURL: URL,
        into identity: MacOSActiveMachineIdentity,
        compatibility: MacOSMachineStateCompatibilityDescription? = nil
    ) throws {
        guard !identity.isPersistent || compatibility != nil else {
            throw SidecarRPCError(code: "identityBundleMismatch", message: "persistent identity restore requires the saved VM compatibility description")
        }
        try identity.validateDirectories()
        let stateDirectory = try lexicalDirectoryURL(stateDirectoryURL)
        let bundleURL = stateDirectory.appendingPathComponent(bundleDirectoryName, isDirectory: true)
        let manifest = try verify(in: stateDirectory, compatibility: compatibility)
        // Validate every destination before publishing any file. A persistent
        // identity cannot silently adopt a different machine or hardware model.
        for filename in requiredFilenames + optionalFilenames {
            let destination = try identity.fileURL(for: filename)
            switch try pathStatus(destination) {
            case .missing: break
            case .regularFile:
                try validateFile(destination)
            default:
                throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "VM identity destination is not a regular file")
            }
        }
        if compatibility != nil || identity.isPersistent {
            for filename in ["HardwareModel.bin", "MachineIdentifier.bin"] {
                let destination = try identity.fileURL(for: filename)
                if try pathStatus(destination) != .missing,
                    try fileRecord(destination) != manifest.files.first(where: { $0.name == filename })
                {
                    throw SidecarRPCError(code: "activeIdentityMismatch", message: "existing \(filename) differs from the saved VM identity")
                }
            }
        }

        // Stage on each destination filesystem; persistent storage need not be
        // on the same volume as the sandbox runtime directory.
        var staged: [(temporary: URL, destination: URL)] = []
        defer { for entry in staged { try? FileManager.default.removeItem(at: entry.temporary) } }

        for record in manifest.files {
            let destination = try identity.fileURL(for: record.name)
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".identity-materialize-\(UUID().uuidString.lowercased()).tmp")
            _ = try copyAndDigest(
                from: bundleURL.appendingPathComponent(record.name),
                to: temporary,
                expected: record
            )
            staged.append((temporary, destination))
        }

        for entry in staged {
            guard rename(entry.temporary.path, entry.destination.path) == 0 else {
                throw posixError(code: "identityBundleMaterializeFailed", message: "failed to materialize VM identity")
            }
        }

        let included = Set(manifest.files.map(\.name))
        for filename in optionalFilenames where !included.contains(filename) {
            let destinationURL = try identity.fileURL(for: filename)
            switch try pathStatus(destinationURL) {
            case .missing:
                break
            case .regularFile:
                guard unlink(destinationURL.path) == 0 || errno == ENOENT else {
                    throw posixError(
                        code: "identityBundleMaterializeFailed",
                        message: "failed to clear stale optional VM identity"
                    )
                }
            case .directory, .symbolicLink, .other:
                throw SidecarRPCError(
                    code: "unsafeIdentityBundlePath",
                    message: "optional VM identity destination is not a regular file"
                )
            }
        }
        for directory in Set(staged.map { $0.destination.deletingLastPathComponent() }) {
            try syncDirectory(directory)
        }
    }

    @discardableResult
    static func verify(in stateDirectoryURL: URL, compatibility: MacOSMachineStateCompatibilityDescription? = nil) throws -> Manifest {
        let stateDirectory = try lexicalDirectoryURL(stateDirectoryURL)
        try requireManagedDirectory(stateDirectory, role: "machine-state directory", requirePrivateMode: true)
        let bundleURL = stateDirectory.appendingPathComponent(bundleDirectoryName, isDirectory: true)
        do {
            try requireManagedDirectory(bundleURL, role: "VM identity bundle", requirePrivateMode: true)
        } catch let error as POSIXError where error.code == .ENOENT {
            throw SidecarRPCError(code: "identityBundleMissing", message: "VM identity bundle does not exist")
        }

        let manifestURL = bundleURL.appendingPathComponent(manifestFilename)
        let data: Data
        do {
            data = try readRegularFile(manifestURL, maximumSize: maximumManifestSize)
        } catch let error as POSIXError where error.code == .ENOENT {
            throw SidecarRPCError(code: "identityBundleIncomplete", message: "VM identity bundle manifest is missing")
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw SidecarRPCError(code: "identityBundleCorrupt", message: "VM identity bundle manifest is invalid")
        }
        try validateManifest(manifest)
        for record in manifest.files {
            _ = try digestFile(bundleURL.appendingPathComponent(record.name), expected: record)
        }
        if let compatibility { try validateBinding(manifest, compatibility: compatibility) }
        return manifest
    }

    private static func validateBinding(_ manifest: Manifest, compatibility: MacOSMachineStateCompatibilityDescription) throws {
        guard manifest.files.first(where: { $0.name == "HardwareModel.bin" })?.sha256 == compatibility.hardwareModelFingerprint,
            manifest.files.first(where: { $0.name == "MachineIdentifier.bin" })?.sha256 == compatibility.machineIdentifierFingerprint
        else {
            throw SidecarRPCError(code: "identityBundleMismatch", message: "VM identity bundle does not match the machine-state compatibility description")
        }
    }

    enum PathStatus: Equatable {
        case missing
        case regularFile
        case directory
        case symbolicLink
        case other
    }

    static func pathStatus(_ url: URL) throws -> PathStatus {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            if errno == ENOENT { return .missing }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        switch information.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    static func requireManagedDirectory(
        _ url: URL,
        role: String,
        requirePrivateMode: Bool
    ) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/" else {
            throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "\(role) must be an absolute directory")
        }
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "\(role) is not a directory")
        }
        guard information.st_uid == geteuid() else {
            throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "\(role) has an unexpected owner")
        }
        let unsafeMode: mode_t = requirePrivateMode ? 0o077 : 0o022
        guard information.st_mode & unsafeMode == 0 else {
            throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "\(role) has unsafe permissions")
        }
        try rejectSymbolicLinkComponents(in: url)
    }

    /// Canonicalize only verified system aliases; arbitrary symbolic links
    /// remain rejected by `requireManagedDirectory`.
    private static func lexicalDirectoryURL(_ url: URL) throws -> URL {
        guard url.isFileURL, let path = MacOSManagedPath.canonicalPath(url.path) else {
            throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "VM identity bundle requires a canonical local directory")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func rejectSymbolicLinkComponents(in url: URL) throws {
        var current = "/"
        for component in NSString(string: url.path).pathComponents where component != "/" {
            current = URL(fileURLWithPath: current, isDirectory: true).appendingPathComponent(component).path
            var information = stat()
            guard lstat(current, &information) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
            }
            guard information.st_mode & S_IFMT != S_IFLNK else {
                throw SidecarRPCError(
                    code: "unsafeIdentityBundlePath",
                    message: "VM identity paths must not traverse symbolic links"
                )
            }
        }
    }

    private static func validateManifest(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw SidecarRPCError(code: "identityBundleCorrupt", message: "unsupported VM identity bundle schema")
        }
        let allowed = Set(requiredFilenames + optionalFilenames)
        let names = manifest.files.map(\.name)
        guard Set(names).count == names.count, Set(names).isSubset(of: allowed) else {
            throw SidecarRPCError(code: "identityBundleCorrupt", message: "VM identity bundle contains invalid files")
        }
        guard Set(requiredFilenames).isSubset(of: Set(names)) else {
            throw SidecarRPCError(code: "identityBundleIncomplete", message: "VM identity bundle is incomplete")
        }
        for record in manifest.files {
            guard record.sha256.count == 64,
                record.sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
            else {
                throw SidecarRPCError(code: "identityBundleCorrupt", message: "VM identity bundle checksum is invalid")
            }
        }
    }

    static func copyAndDigest(
        from sourceURL: URL,
        to destinationURL: URL,
        expected: Manifest.FileRecord?
    ) throws -> Manifest.FileRecord {
        let sourceDescriptor = open(sourceURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            if errno == ENOENT {
                throw SidecarRPCError(code: "identityBundleIncomplete", message: "required VM identity file is missing")
            }
            throw posixError(code: "identityBundleReadFailed", message: "failed to open VM identity file")
        }
        defer { close(sourceDescriptor) }
        let sourceSize = try validateRegularFileDescriptor(sourceDescriptor)

        let destinationDescriptor = open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard destinationDescriptor >= 0 else {
            throw posixError(code: "identityBundleWriteFailed", message: "failed to create VM identity file")
        }
        var keepDestination = false
        defer {
            close(destinationDescriptor)
            if !keepDestination { _ = unlink(destinationURL.path) }
        }

        let digest = try copyAndHash(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            expectedSize: sourceSize
        )
        guard fchmod(destinationDescriptor, mode_t(0o600)) == 0, fsync(destinationDescriptor) == 0 else {
            throw posixError(code: "identityBundleWriteFailed", message: "failed to commit VM identity file")
        }
        let record = Manifest.FileRecord(name: sourceURL.lastPathComponent, size: sourceSize, sha256: digest)
        if let expected, record != expected {
            throw SidecarRPCError(code: "identityBundleCorrupt", message: "VM identity file failed integrity validation")
        }
        keepDestination = true
        return record
    }

    private static func digestFile(
        _ url: URL,
        expected: Manifest.FileRecord
    ) throws -> Manifest.FileRecord {
        let actual = try fileRecord(url)
        guard actual == expected else {
            throw SidecarRPCError(code: "identityBundleCorrupt", message: "VM identity bundle failed integrity validation")
        }
        return actual
    }

    static func fileRecord(_ url: URL) throws -> Manifest.FileRecord {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw SidecarRPCError(code: "identityBundleIncomplete", message: "VM identity bundle is incomplete")
            }
            throw posixError(code: "identityBundleReadFailed", message: "failed to open VM identity bundle")
        }
        defer { close(descriptor) }
        let size = try validateRegularFileDescriptor(descriptor)
        let digest = try hash(descriptor: descriptor, expectedSize: size)
        return Manifest.FileRecord(name: url.lastPathComponent, size: size, sha256: digest)
    }

    static func validateFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(code: "identityBundleReadFailed", message: "failed to open VM identity file") }
        defer { close(descriptor) }
        _ = try validateRegularFileDescriptor(descriptor)
    }

    static func validateRegularFileDescriptor(_ descriptor: Int32, effectiveUserID: uid_t = geteuid()) throws -> UInt64 {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw posixError(code: "identityBundleReadFailed", message: "failed to inspect VM identity file")
        }
        guard information.st_mode & S_IFMT == S_IFREG, information.st_size >= 0 else {
            throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "VM identity source is not a regular file")
        }
        guard information.st_uid == effectiveUserID, information.st_nlink == 1, information.st_mode & 0o022 == 0 else {
            throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "VM identity file has an unsafe owner, permissions, or link count")
        }
        return UInt64(information.st_size)
    }

    private static func copyAndHash(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        expectedSize: UInt64
    ) throws -> String {
        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw posixError(code: "identityBundleReadFailed", message: "failed to read VM identity file")
            }
            if count == 0 { break }
            let chunk = Data(buffer[0..<count])
            hasher.update(data: chunk)
            try writeAll(chunk, to: destinationDescriptor)
            total += UInt64(count)
        }
        guard total == expectedSize else {
            throw SidecarRPCError(code: "identityBundleCorrupt", message: "VM identity file changed while being captured")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(descriptor: Int32, expectedSize: UInt64) throws -> String {
        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw posixError(code: "identityBundleReadFailed", message: "failed to read VM identity file")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            total += UInt64(count)
        }
        guard total == expectedSize else {
            throw SidecarRPCError(code: "identityBundleCorrupt", message: "VM identity file size changed during validation")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func readRegularFile(_ url: URL, maximumSize: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        let size = try validateRegularFileDescriptor(descriptor)
        guard size <= UInt64(maximumSize) else {
            throw SidecarRPCError(code: "identityBundleCorrupt", message: "VM identity manifest exceeds the size limit")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }

    private static func writeManifest(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw posixError(code: "identityBundleWriteFailed", message: "failed to create VM identity manifest")
        }
        defer { close(descriptor) }
        try writeAll(data, to: descriptor)
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw posixError(code: "identityBundleWriteFailed", message: "failed to commit VM identity manifest")
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw posixError(code: "identityBundleWriteFailed", message: "failed to write VM identity file")
                }
                offset += count
            }
        }
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError(code: "identityBundleWriteFailed", message: "failed to open VM identity directory")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw posixError(code: "identityBundleWriteFailed", message: "failed to sync VM identity directory")
        }
    }

    private static func posixError(code: String, message: String) -> SidecarRPCError {
        SidecarRPCError(
            code: code,
            message: message,
            details: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
        )
    }
}
