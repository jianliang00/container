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

enum MacOSNodeStatusConfigError: Error, CustomStringConvertible, Equatable {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message):
            "invalid macOS node status configuration: \(message)"
        }
    }
}

struct MacOSNodeStatusExpectedComponents: Codable, Equatable, Sendable {
    var kubeProxy: Bool
    var flannel: Bool
    var vmnetRecovery: Bool
}

struct MacOSNodeStatusConfig: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let defaultPath = "/etc/kubernetes/container-macos-node-status.json"

    var schemaVersion: Int
    var nodeName: String
    var networkName: String
    var expectedComponents: MacOSNodeStatusExpectedComponents

    init(
        nodeName: String,
        networkName: String,
        expectedComponents: MacOSNodeStatusExpectedComponents,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.nodeName = nodeName
        self.networkName = networkName
        self.expectedComponents = expectedComponents
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MacOSNodeStatusConfigError.invalid("unsupported schema version \(schemaVersion)")
        }
        try Self.validateIdentity(nodeName, field: "nodeName")
        try Self.validateIdentity(networkName, field: "networkName")
        return self
    }

    private static func validateIdentity(_ value: String, field: String) throws {
        guard !value.isEmpty,
            value.utf8.count <= 512,
            !value.contains("/"),
            !value.contains(where: \.isWhitespace)
        else {
            throw MacOSNodeStatusConfigError.invalid("\(field) is invalid")
        }
    }
}

struct MacOSNodeStatusConfigFile: Sendable {
    private static let maximumSize = 16 * 1024

    let url: URL
    private let requiredOwnerID: uid_t

    init(
        path: String = MacOSNodeStatusConfig.defaultPath,
        requiredOwnerID: uid_t = geteuid()
    ) {
        self.url = URL(fileURLWithPath: path)
        self.requiredOwnerID = requiredOwnerID
    }

    func load() throws -> MacOSNodeStatusConfig {
        guard url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty else {
            throw MacOSNodeStatusConfigError.invalid("configuration path must be absolute")
        }

        let directoryURL = url.deletingLastPathComponent()
        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw posixError("open configuration directory", path: directoryURL.path)
        }
        defer { close(directoryDescriptor) }
        try validateDirectory(directoryDescriptor, path: directoryURL.path)

        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw posixError("open configuration", path: url.path)
        }
        defer { close(descriptor) }

        let size = try validateFile(descriptor)
        let data = try readAll(from: descriptor, size: size)
        do {
            return try JSONDecoder().decode(MacOSNodeStatusConfig.self, from: data).validated()
        } catch let error as MacOSNodeStatusConfigError {
            throw error
        } catch {
            throw MacOSNodeStatusConfigError.invalid("configuration JSON is invalid")
        }
    }

    private func validateDirectory(_ descriptor: Int32, path: String) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw posixError("inspect configuration directory", path: path)
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
            information.st_uid == requiredOwnerID,
            information.st_mode & mode_t(0o022) == 0
        else {
            throw MacOSNodeStatusConfigError.invalid("configuration directory metadata is unsafe")
        }
        try validateDirectoryACLDoesNotGrantMutation(descriptor)
    }

    private func validateFile(_ descriptor: Int32) throws -> Int {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw posixError("inspect configuration", path: url.path)
        }
        guard information.st_mode & S_IFMT == S_IFREG,
            information.st_uid == requiredOwnerID,
            information.st_mode & mode_t(0o7777) == mode_t(0o600)
        else {
            throw MacOSNodeStatusConfigError.invalid("configuration file metadata is unsafe")
        }
        guard information.st_size >= 0, information.st_size <= off_t(Self.maximumSize) else {
            throw MacOSNodeStatusConfigError.invalid("configuration exceeds the size limit")
        }
        try validateNoExtendedACL(descriptor, object: "configuration file")
        return Int(information.st_size)
    }

    private func validateNoExtendedACL(_ descriptor: Int32, object: String) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw posixError("inspect \(object) ACL", path: url.path)
            }
            return
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw MacOSNodeStatusConfigError.invalid("\(object) must not have an extended ACL")
    }

    private func validateDirectoryACLDoesNotGrantMutation(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw posixError("inspect configuration directory ACL", path: url.deletingLastPathComponent().path)
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
                    throw posixError(
                        "enumerate configuration directory ACL",
                        path: url.deletingLastPathComponent().path
                    )
                }
                return
            }
            entryIdentifier = ACL_NEXT_ENTRY.rawValue
            guard let entry else {
                throw MacOSNodeStatusConfigError.invalid("configuration directory ACL contains an invalid entry")
            }

            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else {
                throw posixError(
                    "inspect configuration directory ACL entry",
                    path: url.deletingLastPathComponent().path
                )
            }
            guard tag == ACL_EXTENDED_ALLOW else {
                continue
            }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions else {
                throw posixError(
                    "inspect configuration directory ACL permissions",
                    path: url.deletingLastPathComponent().path
                )
            }
            if mutatingPermissions.contains(where: { acl_get_perm_np(permissions, $0) == 1 }) {
                throw MacOSNodeStatusConfigError.invalid("configuration directory ACL grants mutation")
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
                    throw posixError("read configuration", path: url.path)
                }
                guard count > 0 else {
                    throw MacOSNodeStatusConfigError.invalid("configuration ended before its recorded size")
                }
                offset += count
            }
        }
        return data
    }

    private func posixError(_ operation: String, path: String) -> MacOSNodeStatusConfigError {
        .invalid("\(operation) at \(path): \(String(cString: strerror(errno)))")
    }
}
