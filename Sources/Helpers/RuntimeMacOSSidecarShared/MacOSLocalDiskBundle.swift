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

    public struct Manifest: Codable, Sendable {
        public struct File: Codable, Sendable {
            public var name: String
            public var size: Int64
        }
        public var version: Int
        public var persistenceID: String
        public var storageGeneration: UInt64
        public var files: [File]
    }

    public static func install(storageDirectory: String, persistenceID: String, generation: UInt64, digest: String, destination: URL) throws {
        guard let storage = MacOSManagedPath.canonicalPath(storageDirectory), generation > 0,
            digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw CocoaError(.fileReadCorruptFile) }
        try validateDirectory(destination)
        let fm = FileManager.default
        let marker = destination.appendingPathComponent("disk-bundle-imported")
        let pending = destination.appendingPathComponent("disk-bundle-importing")
        if fm.fileExists(atPath: marker.path) {
            guard try readRegular(marker, limit: 64) == Data(digest.utf8) else { throw CocoaError(.fileReadCorruptFile) }
            for name in fileNames {
                let file = destination.appendingPathComponent(name)
                var value = stat()
                guard lstat(file.path, &value) == 0, value.st_size > 0 else { throw CocoaError(.fileReadCorruptFile) }
                try validateFile(file, size: value.st_size)
            }
            return
        }
        let source = URL(fileURLWithPath: storage).appendingPathComponent("disks/g\(generation)")
        try validateDirectory(source)
        let manifestData = try readRegular(source.appendingPathComponent("disk-bundle.json"), limit: 65536)
        guard SHA256.hash(data: manifestData).map({ String(format: "%02x", $0) }).joined() == digest else { throw CocoaError(.fileReadCorruptFile) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.version == 1, manifest.persistenceID == persistenceID,
            manifest.storageGeneration == generation, manifest.files.map(\.name) == fileNames,
            manifest.files.allSatisfy({ $0.size > 0 && $0.size <= 1 << 40 })
        else { throw CocoaError(.fileReadCorruptFile) }
        if fm.fileExists(atPath: pending.path) {
            guard try readRegular(pending, limit: 64) == Data(digest.utf8) else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            guard fileNames.allSatisfy({ !fm.fileExists(atPath: destination.appendingPathComponent($0).path) }) else { throw CocoaError(.fileWriteFileExists) }
            try Data(digest.utf8).write(to: pending, options: .withoutOverwriting)
        }
        for entry in manifest.files {
            let from = source.appendingPathComponent(entry.name)
            try validateFile(from, size: entry.size)
            let to = destination.appendingPathComponent(entry.name)
            if fm.fileExists(atPath: to.path) {
                try validateFile(to, size: entry.size)
                continue
            }
            guard clonefile(from.path, to.path, UInt32(CLONE_NOFOLLOW)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try validateFile(to, size: entry.size)
        }
        guard rename(pending.path, marker.path) == 0 else { throw POSIXError(.EIO) }
    }

    private static func validateDirectory(_ url: URL) throws {
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

    private static func readRegular(_ url: URL, limit: Int) throws -> Data {
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
