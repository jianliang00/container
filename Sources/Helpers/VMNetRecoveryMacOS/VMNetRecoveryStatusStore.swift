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

enum VMNetRecoveryStatusStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case persistence(String)

    var description: String {
        switch self {
        case .persistence(let message):
            "vmnet recovery status persistence failed: \(message)"
        }
    }
}

protocol VMNetRecoveryStatusStoring: Sendable {
    func load() throws -> VMNetRecoveryStatus?
    func save(_ status: VMNetRecoveryStatus) throws
    func remove() throws
}

struct VMNetRecoveryStatusFileStore: VMNetRecoveryStatusStoring, Sendable {
    private static let maximumEncodedSize = 64 * 1024

    let url: URL
    private let requiredOwnerID: uid_t
    private let requiredGroupID: gid_t

    init(
        path: String,
        requiredOwnerID: uid_t = geteuid(),
        requiredGroupID: gid_t = getegid()
    ) {
        self.init(
            url: URL(fileURLWithPath: path),
            requiredOwnerID: requiredOwnerID,
            requiredGroupID: requiredGroupID
        )
    }

    init(
        url: URL,
        requiredOwnerID: uid_t = geteuid(),
        requiredGroupID: gid_t = getegid()
    ) {
        self.url = url
        self.requiredOwnerID = requiredOwnerID
        self.requiredGroupID = requiredGroupID
    }

    func load() throws -> VMNetRecoveryStatus? {
        guard let directoryDescriptor = try openDirectory(createIfMissing: false) else {
            return nil
        }
        defer { close(directoryDescriptor) }

        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw persistenceError("failed to open", errno: errno)
        }
        defer { close(descriptor) }

        let data = try readAll(from: descriptor, size: try validateFileDescriptor(descriptor))
        do {
            return try JSONDecoder().decode(VMNetRecoveryStatus.self, from: data).validated()
        } catch let error as VMNetRecoveryStatusStoreError {
            throw error
        } catch {
            throw VMNetRecoveryStatusStoreError.persistence(
                "failed to decode status at \(url.path): \(error)"
            )
        }
    }

    func save(_ status: VMNetRecoveryStatus) throws {
        let status = try status.validated()
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(status)
        } catch let error as VMNetRecoveryStatusStoreError {
            throw error
        } catch {
            throw VMNetRecoveryStatusStoreError.persistence(
                "failed to encode status at \(url.path): \(error)"
            )
        }
        guard data.count <= Self.maximumEncodedSize else {
            throw VMNetRecoveryStatusStoreError.persistence("status exceeds the size limit")
        }

        guard let directoryDescriptor = try openDirectory(createIfMissing: true) else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "failed to create status directory at \(url.deletingLastPathComponent().path)"
            )
        }
        defer { close(directoryDescriptor) }
        try validateExistingFile(in: directoryDescriptor)

        let temporaryName = ".recovery-status-\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw persistenceError("failed to create a temporary file for", errno: errno)
        }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        guard fchown(descriptor, requiredOwnerID, requiredGroupID) == 0 else {
            throw persistenceError("failed to set ownership of a temporary file for", errno: errno)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw persistenceError("failed to protect a temporary file for", errno: errno)
        }
        try clearInheritedExtendedACL(descriptor)
        try validateNoExtendedACL(descriptor, object: "temporary status file")
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw persistenceError("failed to sync a temporary file for", errno: errno)
        }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, url.lastPathComponent) == 0 else {
            throw persistenceError("failed to commit", errno: errno)
        }
        renamed = true
        guard fsync(directoryDescriptor) == 0 else {
            throw persistenceError("failed to sync the directory for", errno: errno)
        }
    }

    func remove() throws {
        guard let directoryDescriptor = try openDirectory(createIfMissing: false) else {
            return
        }
        defer { close(directoryDescriptor) }

        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw persistenceError("failed to open before removing", errno: errno)
        }
        defer { close(descriptor) }
        _ = try validateFileDescriptor(descriptor, enforceSizeLimit: false)

        guard unlinkat(directoryDescriptor, url.lastPathComponent, 0) == 0 else {
            if errno == ENOENT {
                return
            }
            throw persistenceError("failed to remove", errno: errno)
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw persistenceError("failed to sync the directory after removing", errno: errno)
        }
    }

    private func openDirectory(createIfMissing: Bool) throws -> Int32? {
        let directoryURL = url.deletingLastPathComponent()
        guard !url.lastPathComponent.isEmpty else {
            throw VMNetRecoveryStatusStoreError.persistence("status path has no file name")
        }
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "failed to create status directory at \(directoryURL.path): \(error)"
                )
            }
        }

        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT, !createIfMissing {
                return nil
            }
            throw VMNetRecoveryStatusStoreError.persistence(
                "failed to open status directory at \(directoryURL.path): "
                    + Self.posixErrorDescription(errno)
            )
        }

        do {
            try validateDirectoryDescriptor(descriptor, path: directoryURL.path)
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private func validateDirectoryDescriptor(_ descriptor: Int32, path: String) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "failed to inspect open status directory at \(path): "
                    + Self.posixErrorDescription(errno)
            )
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "status directory at \(path) is not a directory"
            )
        }
        guard information.st_uid == requiredOwnerID, information.st_gid == requiredGroupID else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "status directory at \(path) has unexpected ownership"
            )
        }
        guard information.st_mode & mode_t(0o022) == 0 else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "status directory at \(path) is group or world writable"
            )
        }
        try validateDirectoryACLDoesNotGrantMutation(descriptor)
    }

    private func validateExistingFile(in directoryDescriptor: Int32) throws {
        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw persistenceError("failed to inspect before replacing", errno: errno)
        }
        defer { close(descriptor) }
        _ = try validateFileDescriptor(descriptor, enforceSizeLimit: false)
    }

    private func validateFileDescriptor(
        _ descriptor: Int32,
        enforceSizeLimit: Bool = true
    ) throws -> Int {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw persistenceError("failed to inspect", errno: errno)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "status at \(url.path) is not a regular file"
            )
        }
        guard information.st_uid == requiredOwnerID, information.st_gid == requiredGroupID else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "status at \(url.path) has unexpected ownership"
            )
        }
        guard information.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "status at \(url.path) must have mode 0600"
            )
        }
        try validateNoExtendedACL(descriptor, object: "status file")
        if enforceSizeLimit {
            guard information.st_size >= 0,
                information.st_size <= off_t(Self.maximumEncodedSize)
            else {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "status at \(url.path) exceeds the size limit"
                )
            }
        }
        return enforceSizeLimit ? Int(information.st_size) : 0
    }

    private func clearInheritedExtendedACL(_ descriptor: Int32) throws {
        guard let emptyACL = acl_init(0) else {
            throw persistenceError("failed to allocate an empty ACL for", errno: errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) == 0 else {
            throw persistenceError("failed to clear the inherited ACL of", errno: errno)
        }
    }

    private func validateNoExtendedACL(_ descriptor: Int32, object: String) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw persistenceError("failed to inspect the extended ACL of the \(object) for", errno: errno)
            }
            return
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw VMNetRecoveryStatusStoreError.persistence(
            "\(object) at \(url.path) must not have an extended ACL"
        )
    }

    private func validateDirectoryACLDoesNotGrantMutation(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw persistenceError("failed to inspect the status directory ACL for", errno: errno)
            }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        let mutatingPermissions: [acl_perm_t] = [
            ACL_WRITE_DATA,
            ACL_DELETE,
            ACL_APPEND_DATA,
            ACL_DELETE_CHILD,
            ACL_WRITE_ATTRIBUTES,
            ACL_WRITE_EXTATTRIBUTES,
            ACL_WRITE_SECURITY,
            ACL_CHANGE_OWNER,
        ]
        var entryIdentifier = ACL_FIRST_ENTRY.rawValue
        while true {
            var entry: acl_entry_t?
            errno = 0
            let result = acl_get_entry(acl, entryIdentifier, &entry)
            if result != 0 {
                guard errno == EINVAL else {
                    throw persistenceError("failed to enumerate the status directory ACL for", errno: errno)
                }
                break
            }
            entryIdentifier = ACL_NEXT_ENTRY.rawValue
            guard let entry else {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "status directory ACL at \(url.deletingLastPathComponent().path) contains an invalid entry"
                )
            }

            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else {
                throw persistenceError("failed to inspect a status directory ACL entry for", errno: errno)
            }
            guard tag == ACL_EXTENDED_ALLOW else {
                continue
            }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions else {
                throw persistenceError("failed to inspect status directory ACL permissions for", errno: errno)
            }
            if mutatingPermissions.contains(where: { acl_get_perm_np(permissions, $0) == 1 }) {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "status directory at \(url.deletingLastPathComponent().path) grants mutation through an extended ACL"
                )
            }
        }
    }

    private func readAll(from descriptor: Int32, size: Int) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw persistenceError("failed to read", errno: errno)
                }
                guard count > 0 else {
                    throw VMNetRecoveryStatusStoreError.persistence(
                        "status at \(url.path) ended before its recorded size"
                    )
                }
                offset += count
            }
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw persistenceError("failed to write", errno: errno)
                }
                guard count > 0 else {
                    throw VMNetRecoveryStatusStoreError.persistence(
                        "status write made no progress"
                    )
                }
                offset += count
            }
        }
    }

    private func persistenceError(_ operation: String, errno errorNumber: Int32) -> VMNetRecoveryStatusStoreError {
        .persistence(
            "\(operation) status at \(url.path): "
                + Self.posixErrorDescription(errorNumber)
        )
    }

    private static func posixErrorDescription(_ errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
    }
}
