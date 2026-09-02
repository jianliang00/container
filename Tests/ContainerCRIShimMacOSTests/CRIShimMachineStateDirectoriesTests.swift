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
    func canonicalizesOnlyDarwinSystemAliasPrefixes() {
        #expect(criCanonicalizedManagedDirectoryPath("/var/lib/container") == "/private/var/lib/container")
        #expect(criCanonicalizedManagedDirectoryPath("/tmp/runtime") == "/private/tmp/runtime")
        #expect(criCanonicalizedManagedDirectoryPath("/etc/container") == "/private/etc/container")
        #expect(criCanonicalizedManagedDirectoryPath("/private/var/lib/container") == "/private/var/lib/container")
        #expect(criCanonicalizedManagedDirectoryPath("/opt/runtime") == "/opt/runtime")
        #expect(criCanonicalizedManagedDirectoryPath("/var/lib/../runtime") == nil)
    }

    @Test
    func defaultMachineStateRootsCanonicalizeToPhysicalDarwinPaths() {
        #expect(
            criCanonicalizedManagedDirectoryPath(CRIShimConfigDefaults.machineStateStorageRootURL.path)
                == "/private/var/lib/container/cri-shim-macos/machine-state/v1"
        )
        #expect(
            criCanonicalizedManagedDirectoryPath(CRIShimConfigDefaults.machineStateControlSocketRootURL.path)
                == "/private/var/run/container/machine-state/v1"
        )
        #expect(
            criCanonicalizedManagedDirectoryPath(CRIShimConfigDefaults.machineStateLeaseRootURL.path)
                == "/private/var/lib/container/cri-shim-macos/machine-state-leases/v1"
        )
    }

    @Test
    func acceptsOnlyKnownWritableDarwinSystemParents() {
        #expect(
            criHasTrustedMachineStateParentWritePermissions(
                path: "/private/var/run",
                ownerID: 0,
                groupID: 1,
                mode: mode_t(S_IFDIR | 0o775)
            )
        )
        #expect(
            criHasTrustedMachineStateParentWritePermissions(
                path: "/private/tmp",
                ownerID: 0,
                groupID: 0,
                mode: mode_t(S_IFDIR | S_ISVTX | 0o777)
            )
        )
        #expect(
            !criHasTrustedMachineStateParentWritePermissions(
                path: "/private/var/lib",
                ownerID: 0,
                groupID: 0,
                mode: mode_t(S_IFDIR | 0o775)
            )
        )
        #expect(
            !criHasTrustedMachineStateParentWritePermissions(
                path: "/private/var/run",
                ownerID: 0,
                groupID: 20,
                mode: mode_t(S_IFDIR | 0o775)
            )
        )
    }

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
    func startupAcceptsSystemAliasPrefixButRejectsInnerSymbolicLink() throws {
        let aliasRoot = URL(
            fileURLWithPath: "/tmp/CRIShimMachineStateDirectoriesTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let physicalRoot = URL(fileURLWithPath: "/private\(aliasRoot.path)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: physicalRoot) }
        try createPrivateRoot(physicalRoot)

        let valid = policy(below: aliasRoot)
        try CRIShimMachineStateDirectories.prepare(policy: valid)
        for path in managedPaths(valid) {
            var value = stat()
            #expect(lstat(path, &value) == 0)
            #expect((value.st_mode & S_IFMT) == S_IFDIR)
        }

        let target = physicalRoot.appendingPathComponent("target", isDirectory: true)
        let link = physicalRoot.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let invalid = MachineStateConfig(
            enabled: true,
            storageRoot: aliasRoot.appendingPathComponent("link/state", isDirectory: true).path,
            controlSocketRoot: valid.normalizedControlSocketRoot,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: valid.nbdSocketAllowedRoots,
            leaseRoot: valid.normalizedLeaseRoot
        )

        do {
            try CRIShimMachineStateDirectories.prepare(policy: invalid)
            Issue.record("inner symbolic-link machine-state directory was accepted")
        } catch let error as CRIShimError {
            #expect(error.description.contains("must not traverse symbolic links"))
        }
    }

    @Test
    func startupCreatesMissingTrustedIntermediateDirectories() throws {
        let aliasRoot = URL(
            fileURLWithPath: "/tmp/CRIShimMachineStateDirectoriesTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let physicalRoot = URL(fileURLWithPath: "/private\(aliasRoot.path)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: physicalRoot) }
        try createPrivateRoot(physicalRoot)
        let policy = MachineStateConfig(
            enabled: true,
            storageRoot: aliasRoot.appendingPathComponent("persistent/state/v1", isDirectory: true).path,
            controlSocketRoot: aliasRoot.appendingPathComponent("volatile/control/v1", isDirectory: true).path,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: [aliasRoot.appendingPathComponent("volatile/nbd/v1", isDirectory: true).path],
            leaseRoot: aliasRoot.appendingPathComponent("persistent/leases/v1", isDirectory: true).path
        )

        try CRIShimMachineStateDirectories.prepare(policy: policy)

        for path in managedPaths(policy) {
            var value = stat()
            #expect(lstat(path, &value) == 0)
            #expect((value.st_mode & S_IFMT) == S_IFDIR)
            #expect((value.st_mode & 0o777) == 0o700)
        }
        for relativePath in ["persistent", "persistent/state", "persistent/leases", "volatile", "volatile/control", "volatile/nbd"] {
            var value = stat()
            let path = aliasRoot.appendingPathComponent(relativePath, isDirectory: true).path
            #expect(lstat(path, &value) == 0)
            #expect((value.st_mode & S_IFMT) == S_IFDIR)
            #expect(value.st_uid == geteuid())
            #expect((value.st_mode & 0o777) == 0o711)
        }
    }

    @Test
    func startupRejectsWritableExistingIntermediateDirectory() throws {
        let root = privateTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateRoot(root)
        let writable = root.appendingPathComponent("writable", isDirectory: true)
        try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: false)
        #expect(chmod(writable.path, mode_t(0o777)) == 0)
        let invalid = MachineStateConfig(
            enabled: true,
            storageRoot: writable.appendingPathComponent("state/v1", isDirectory: true).path,
            controlSocketRoot: root.appendingPathComponent("control/v1", isDirectory: true).path,
            runtimeOwnerUID: UInt32(geteuid()),
            leaseRoot: root.appendingPathComponent("leases/v1", isDirectory: true).path
        )

        do {
            try CRIShimMachineStateDirectories.prepare(policy: invalid)
            Issue.record("writable machine-state parent hierarchy was accepted")
        } catch let error as CRIShimError {
            #expect(error.description.contains("untrusted group- or world-writable"))
        }
    }

    @Test
    func startupRejectsExistingIntermediateDirectoryWithUnexpectedOwner() throws {
        let root = privateTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateRoot(root)
        let unexpectedEffectiveUserID = geteuid() &+ 1
        let invalid = MachineStateConfig(
            enabled: true,
            storageRoot: root.appendingPathComponent("state/v1", isDirectory: true).path,
            controlSocketRoot: root.appendingPathComponent("control/v1", isDirectory: true).path,
            runtimeOwnerUID: UInt32(unexpectedEffectiveUserID),
            leaseRoot: root.appendingPathComponent("leases/v1", isDirectory: true).path
        )

        do {
            try CRIShimMachineStateDirectories.prepare(
                policy: invalid,
                effectiveUserID: unexpectedEffectiveUserID
            )
            Issue.record("machine-state parent hierarchy with an unexpected owner was accepted")
        } catch let error as CRIShimError {
            #expect(error.description.contains("unexpected owner"))
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
