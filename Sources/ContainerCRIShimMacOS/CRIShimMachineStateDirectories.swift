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

struct CRIShimMachineStateDirectoryStartupTask: CRIShimServerStartupTask {
    let policy: MachineStateConfig?

    func run() async throws {
        guard let policy, policy.enabled else { return }
        try CRIShimMachineStateDirectories.prepare(policy: policy)
    }
}

enum CRIShimMachineStateDirectories {
    static func prepare(
        policy: MachineStateConfig,
        effectiveUserID: uid_t = geteuid()
    ) throws {
        let sidecarOwnerID = uid_t(policy.runtimeOwnerUID ?? UInt32(effectiveUserID))
        guard effectiveUserID == 0 || effectiveUserID == sidecarOwnerID else {
            throw CRIShimError.invalidArgument(
                "machineState.runtimeOwnerUID must match the CRI shim uid unless the CRI shim runs as root"
            )
        }

        var sidecarRoots = [
            ("storageRoot", policy.normalizedStorageRoot),
            ("controlSocketRoot", policy.normalizedControlSocketRoot),
        ]
        sidecarRoots.append(
            contentsOf: policy.nbdSocketAllowedRoots.enumerated().map {
                ("nbdSocketAllowedRoots[\($0.offset)]", $0.element)
            }
        )
        for (field, path) in sidecarRoots {
            try preparePrivateLeafDirectory(
                path: path,
                field: "machineState.\(field)",
                effectiveUserID: effectiveUserID,
                targetOwnerID: sidecarOwnerID
            )
        }
        try preparePrivateLeafDirectory(
            path: policy.normalizedLeaseRoot,
            field: "machineState.leaseRoot",
            effectiveUserID: effectiveUserID,
            targetOwnerID: effectiveUserID
        )
    }

    private static func preparePrivateLeafDirectory(
        path: String,
        field: String,
        effectiveUserID: uid_t,
        targetOwnerID: uid_t
    ) throws {
        guard let normalizedPath = criCanonicalizedManagedDirectoryPath(path),
            normalizedPath != "/"
        else {
            throw CRIShimError.invalidArgument("\(field) must be a normalized absolute directory")
        }
        try rejectSymbolicLinkComponents(path: normalizedPath, field: field)

        let url = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        let parentPath = url.deletingLastPathComponent().path
        let leafName = url.lastPathComponent
        guard !leafName.isEmpty, leafName != ".", leafName != ".." else {
            throw CRIShimError.invalidArgument("\(field) must identify a leaf directory")
        }

        let parentFD = try openOrCreateTrustedDirectoryHierarchy(
            path: parentPath,
            field: field,
            effectiveUserID: effectiveUserID
        )
        defer { Darwin.close(parentFD) }

        if mkdirat(parentFD, leafName, mode_t(0o700)) != 0, errno != EEXIST {
            throw CRIShimError.internalError("failed to create \(field)")
        }

        let leafFD = openat(parentFD, leafName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard leafFD >= 0 else {
            throw CRIShimError.invalidArgument("\(field) must reference a directory without symbolic links")
        }
        defer { Darwin.close(leafFD) }

        var before = stat()
        guard fstat(leafFD, &before) == 0, (before.st_mode & S_IFMT) == S_IFDIR else {
            throw CRIShimError.invalidArgument("\(field) must reference a directory")
        }
        let transferableOwners: Set<uid_t> = [effectiveUserID, targetOwnerID]
        guard transferableOwners.contains(before.st_uid) else {
            throw CRIShimError.invalidArgument("\(field) has an unexpected owner and will not be taken over")
        }
        if before.st_uid != targetOwnerID {
            guard effectiveUserID == 0, fchown(leafFD, targetOwnerID, gid_t.max) == 0 else {
                throw CRIShimError.internalError("failed to transfer ownership of \(field)")
            }
        }
        guard fchmod(leafFD, mode_t(0o700)) == 0 else {
            throw CRIShimError.internalError("failed to set private permissions on \(field)")
        }

        var after = stat()
        guard fstat(leafFD, &after) == 0,
            (after.st_mode & S_IFMT) == S_IFDIR,
            after.st_uid == targetOwnerID,
            (after.st_mode & mode_t(0o777)) == mode_t(0o700)
        else {
            throw CRIShimError.internalError("failed to verify \(field) after ownership transfer")
        }
        try rejectSymbolicLinkComponents(path: normalizedPath, field: field)
    }

    private static func openOrCreateTrustedDirectoryHierarchy(
        path: String,
        field: String,
        effectiveUserID: uid_t
    ) throws -> Int32 {
        let components = NSString(string: path).pathComponents.filter { $0 != "/" }
        var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw CRIShimError.internalError("failed to open the filesystem root for \(field)")
        }
        var currentPath = "/"
        do {
            try validateTrustedDirectory(
                fd: directoryFD,
                path: "/",
                field: field,
                effectiveUserID: effectiveUserID
            )
            for component in components {
                currentPath =
                    URL(fileURLWithPath: currentPath, isDirectory: true)
                    .appendingPathComponent(component, isDirectory: true).path
                var created = false
                var value = stat()
                if fstatat(directoryFD, component, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else {
                        throw CRIShimError.internalError("failed to inspect the parent hierarchy of \(field)")
                    }
                    if mkdirat(directoryFD, component, mode_t(0o711)) == 0 {
                        created = true
                    } else if errno != EEXIST {
                        throw CRIShimError.internalError("failed to create the parent hierarchy of \(field)")
                    }
                }

                let nextFD = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard nextFD >= 0 else {
                    throw CRIShimError.invalidArgument(
                        "the parent hierarchy of \(field) must contain only directories without symbolic links"
                    )
                }
                Darwin.close(directoryFD)
                directoryFD = nextFD
                try validateTrustedDirectory(
                    fd: directoryFD,
                    path: currentPath,
                    field: field,
                    effectiveUserID: effectiveUserID
                )
                if created, fchmod(directoryFD, mode_t(0o711)) != 0 {
                    throw CRIShimError.internalError("failed to secure the parent hierarchy of \(field)")
                }
            }
            return directoryFD
        } catch {
            Darwin.close(directoryFD)
            throw error
        }
    }

    private static func validateTrustedDirectory(
        fd: Int32,
        path: String,
        field: String,
        effectiveUserID: uid_t
    ) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
            throw CRIShimError.invalidArgument("the parent hierarchy of \(field) must contain only directories")
        }
        guard value.st_uid == 0 || value.st_uid == effectiveUserID else {
            throw CRIShimError.invalidArgument("the parent hierarchy of \(field) has an unexpected owner")
        }
        guard
            criHasTrustedMachineStateParentWritePermissions(
                path: path,
                ownerID: value.st_uid,
                groupID: value.st_gid,
                mode: value.st_mode
            )
        else {
            throw CRIShimError.invalidArgument(
                "the parent hierarchy of \(field) must not contain untrusted group- or world-writable directories"
            )
        }
    }

    private static func rejectSymbolicLinkComponents(path: String, field: String) throws {
        let components = NSString(string: path).pathComponents
        var current = ""
        for component in components {
            if component == "/" {
                current = "/"
                continue
            }
            current = URL(fileURLWithPath: current, isDirectory: true).appendingPathComponent(component).path
            var value = stat()
            if lstat(current, &value) == 0 {
                guard (value.st_mode & S_IFMT) != S_IFLNK else {
                    throw CRIShimError.invalidArgument("\(field) must not traverse symbolic links")
                }
                continue
            }
            if errno == ENOENT {
                continue
            }
            throw CRIShimError.internalError("failed to inspect \(field)")
        }
    }
}

func criHasTrustedMachineStateParentWritePermissions(
    path: String,
    ownerID: uid_t,
    groupID: gid_t,
    mode: mode_t
) -> Bool {
    if mode & mode_t(0o002) != 0 {
        return path == "/private/tmp"
            && ownerID == 0
            && groupID == 0
            && mode & mode_t(S_ISVTX) != 0
    }
    if mode & mode_t(0o020) != 0 {
        return path == "/private/var/run" && ownerID == 0 && groupID == 1
    }
    return true
}

/// Converts Darwin's fixed top-level filesystem aliases to their physical
/// locations before managed-directory traversal checks. Only the leading
/// system alias is translated; symbolic links anywhere below it remain
/// subject to the normal component-by-component rejection.
func criCanonicalizedManagedDirectoryPath(_ path: String) -> String? {
    guard let normalized = criLexicallyNormalizedAbsolutePath(path), normalized == path else {
        return nil
    }
    #if os(macOS)
    for alias in ["/etc", "/tmp", "/var"] {
        if normalized == alias || normalized.hasPrefix(alias + "/") {
            return "/private" + normalized
        }
    }
    #endif
    return normalized
}
