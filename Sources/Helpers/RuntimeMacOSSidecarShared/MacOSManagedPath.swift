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

import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Shared path spelling and system-parent policy for CRI, runtime and sidecar.
/// Never use Foundation standardization at these trust boundaries: it can
/// change a physical Darwin path back to an alias after the file is created.
public enum MacOSManagedPath {
    public static func lexicallyNormalizedAbsolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// Accepts only lexically canonical absolute paths. Translates a fixed
    /// leading OS alias only after verifying its owner and literal target.
    /// This does not resolve, or authorize, any other symbolic link.
    public static func canonicalPath(_ path: String) -> String? {
        guard lexicallyNormalizedAbsolutePath(path) == path else { return nil }
        #if os(macOS)
        for alias in ["/etc", "/tmp", "/var"] where path == alias || path.hasPrefix(alias + "/") {
            var value = stat()
            guard lstat(alias, &value) == 0 else { return nil }
            var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
            let count = readlink(alias, &bytes, bytes.count)
            guard count > 0, count < bytes.count else { return nil }
            let target = String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isTrustedSystemAlias(path: alias, ownerID: value.st_uid, mode: value.st_mode, target: target) else {
                return nil
            }
            return "/private" + path
        }
        #endif
        return path
    }

    static func isTrustedSystemAlias(path: String, ownerID: uid_t, mode: mode_t, target: String) -> Bool {
        ["/etc", "/tmp", "/var"].contains(path)
            && ownerID == 0 && mode & S_IFMT == S_IFLNK
            && (target == "private" + path || target == "/private" + path)
    }

    /// Only these exact Darwin system directories may be writable by others.
    /// Callers must additionally check directory type and trusted ownership.
    public static func hasTrustedParentWritePermissions(path: String, ownerID: uid_t, groupID: gid_t, mode: mode_t) -> Bool {
        #if os(macOS)
        if path == "/private/tmp" {
            return ownerID == 0 && groupID == 0 && mode & 0o7777 == 0o1777
        }
        if path == "/private/var/run", mode & 0o022 != 0 {
            return ownerID == 0 && groupID == 1 && mode & 0o7777 == 0o775
        }
        #endif
        return mode & 0o022 == 0
    }
}
