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
        guard let normalizedPath = criLexicallyNormalizedAbsolutePath(path),
            path != "/", normalizedPath == path
        else {
            throw CRIShimError.invalidArgument("\(field) must be a normalized absolute directory")
        }
        try rejectSymbolicLinkComponents(path: path, field: field)

        let url = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        let parentPath = url.deletingLastPathComponent().path
        let leafName = url.lastPathComponent
        guard !leafName.isEmpty, leafName != ".", leafName != ".." else {
            throw CRIShimError.invalidArgument("\(field) must identify a leaf directory")
        }

        let parentFD = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFD >= 0 else {
            throw CRIShimError.internalError("failed to open the parent of \(field)")
        }
        defer { Darwin.close(parentFD) }
        try validateTrustedParent(
            fd: parentFD,
            field: field,
            effectiveUserID: effectiveUserID
        )

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
        try rejectSymbolicLinkComponents(path: path, field: field)
    }

    private static func validateTrustedParent(
        fd: Int32,
        field: String,
        effectiveUserID: uid_t
    ) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
            throw CRIShimError.invalidArgument("the parent of \(field) must be a directory")
        }
        guard value.st_uid == 0 || value.st_uid == effectiveUserID else {
            throw CRIShimError.invalidArgument("the parent of \(field) has an unexpected owner")
        }
        guard value.st_mode & mode_t(0o022) == 0 else {
            throw CRIShimError.invalidArgument("the parent of \(field) must not be group- or world-writable")
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
