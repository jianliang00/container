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
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimMachineStateDirectoriesTests {
    @Test
    func startupCreatesPrivateSidecarAndLeaseDirectories() throws {
        let root = privateTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateRoot(root)
        let policy = policy(below: root)

        try CRIShimMachineStateDirectories.prepare(policy: policy)

        for path in [
            policy.normalizedStorageRoot,
            policy.normalizedControlSocketRoot,
            try #require(policy.nbdSocketAllowedRoots.first),
        ] {
            var value = stat()
            #expect(lstat(path, &value) == 0)
            #expect((value.st_mode & S_IFMT) == S_IFDIR)
            #expect(value.st_uid == geteuid())
            #expect((value.st_mode & 0o777) == 0o700)
        }
        var lease = stat()
        #expect(lstat(policy.normalizedLeaseRoot, &lease) == 0)
        #expect((lease.st_mode & S_IFMT) == S_IFDIR)
        #expect(lease.st_uid == geteuid())
        #expect((lease.st_mode & 0o777) == 0o700)
    }

    @Test
    func startupTightensExistingDirectoryPermissions() throws {
        let root = privateTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateRoot(root)
        let policy = policy(below: root)
        for path in managedPaths(policy) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            #expect(chmod(path, 0o777) == 0)
        }

        try CRIShimMachineStateDirectories.prepare(policy: policy)

        for path in managedPaths(policy) {
            var value = stat()
            #expect(lstat(path, &value) == 0)
            #expect((value.st_mode & 0o777) == 0o700)
        }
    }

    @Test
    func startupRejectsSymbolicLinkComponents() throws {
        let root = privateTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateRoot(root)
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let invalid = MachineStateConfig(
            enabled: true,
            storageRoot: link.appendingPathComponent("state").path,
            controlSocketRoot: root.appendingPathComponent("control").path,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: [root.appendingPathComponent("nbd").path],
            leaseRoot: root.appendingPathComponent("leases").path
        )

        do {
            try CRIShimMachineStateDirectories.prepare(policy: invalid)
            Issue.record("symbolic-link machine-state directory was accepted")
        } catch let error as CRIShimError {
            #expect(error.description.contains("must not traverse symbolic links"))
        }
    }

    @Test
    func nonRootShimCannotTransferLeavesToAnotherUID() throws {
        let root = privateTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateRoot(root)
        let policy = MachineStateConfig(
            enabled: true,
            storageRoot: root.appendingPathComponent("state").path,
            controlSocketRoot: root.appendingPathComponent("control").path,
            runtimeOwnerUID: UInt32(geteuid()) &+ 1,
            nbdSocketAllowedRoots: [root.appendingPathComponent("nbd").path],
            leaseRoot: root.appendingPathComponent("leases").path
        )

        #expect(throws: CRIShimError.self) {
            try CRIShimMachineStateDirectories.prepare(policy: policy, effectiveUserID: geteuid())
        }
    }

    private func privateTemporaryRoot() -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath =
            temporaryPath == "/var" || temporaryPath.hasPrefix("/var/")
                || temporaryPath == "/tmp" || temporaryPath.hasPrefix("/tmp/")
            ? "/private\(temporaryPath)"
            : temporaryPath
        return URL(fileURLWithPath: canonicalTemporaryPath, isDirectory: true)
            .appendingPathComponent("CRIShimMachineStateDirectoriesTests-\(UUID().uuidString)")
    }

    private func policy(below root: URL) -> MachineStateConfig {
        MachineStateConfig(
            enabled: true,
            storageRoot: root.appendingPathComponent("state").path,
            controlSocketRoot: root.appendingPathComponent("control").path,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: [root.appendingPathComponent("nbd").path],
            leaseRoot: root.appendingPathComponent("leases").path
        )
    }

    private func managedPaths(_ policy: MachineStateConfig) -> [String] {
        [
            policy.normalizedStorageRoot,
            policy.normalizedControlSocketRoot,
            policy.nbdSocketAllowedRoots[0],
            policy.normalizedLeaseRoot,
        ]
    }

    private func createPrivateRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(root.path, mode_t(0o700)) == 0)
    }
}
