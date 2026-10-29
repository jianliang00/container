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

@testable import RuntimeMacOSSidecarShared

struct SidecarLifecycleBarrierTests {
    @Test(arguments: [mode_t(0o111), mode_t(0o600), mode_t(0o700)])
    func lifecycleLockRequiresSearchInsteadOfReadAccessOnAncestors(parentMode: mode_t) throws {
        guard geteuid() != 0 else {
            print("SKIP: directory access regression requires an unprivileged process")
            return
        }
        let fixture = try Fixture()
        defer {
            _ = chmod(fixture.parent.path, 0o700)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        #expect(chmod(fixture.parent.path, parentMode) == 0)
        if parentMode == 0o600 {
            #expect(throws: (any Error).self) { try fixture.acquire() }
            return
        }

        let lifecycleLock = try fixture.acquire()
        let attestation = try MacOSSidecarLifecycleLock.readAttestation(
            directoryFD: fixture.directoryFD, expectedOwnerUID: geteuid()
        )
        #expect(attestation.state == .active)
        #expect(attestation.processID == getpid())
        #expect(throws: (any Error).self) { try fixture.acquire() }
        var parentValue = stat()
        #expect(lstat(fixture.parent.path, &parentValue) == 0)
        #expect(parentValue.st_mode & 0o777 == parentMode)
        withExtendedLifetime(lifecycleLock) {}
    }

    @Test
    func lifecycleLockRejectsSymbolicLinkAncestor() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.parent)
        #expect(throws: (any Error).self) {
            try fixture.acquire(storageDirectory: alias.appendingPathComponent("state").path)
        }
        let attestation = try MacOSSidecarLifecycleLock.readAttestation(
            directoryFD: fixture.directoryFD, expectedOwnerUID: geteuid()
        )
        #expect(attestation.state == .prepared)
    }

    private final class Fixture {
        let root: URL
        let parent: URL
        let storage: URL
        let directory: FileHandle
        var directoryFD: Int32 { directory.fileDescriptor }
        let nonce = UUID().uuidString.lowercased()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("sidecar-lifecycle-\(UUID().uuidString)")
            parent = root.appendingPathComponent("private-parent")
            storage = parent.appendingPathComponent("state")
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            guard chmod(storage.path, 0o700) == 0 else { throw POSIXError(.EIO) }
            let fd = open(storage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            directory = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let lockFD = openat(
                directoryFD, MacOSSidecarLifecycleBarrierProtocol.lockFileName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
            )
            guard lockFD >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(lockFD) }
            var value = stat()
            guard fstat(lockFD, &value) == 0 else { throw POSIXError(.EIO) }
            try MacOSSidecarLifecycleLock.persistAttestation(
                .init(
                    protocolVersion: 1, persistenceID: "fixture", sandboxID: "fixture", bootNonce: nonce,
                    processID: 0, lockDevice: UInt64(value.st_dev), lockInode: UInt64(value.st_ino), state: .prepared
                ),
                directoryFD: directoryFD, ownerUID: geteuid()
            )
        }

        func acquire(storageDirectory: String? = nil) throws -> MacOSSidecarLifecycleLock {
            try MacOSSidecarLifecycleLock(
                protocolVersion: 1, persistenceID: "fixture", sandboxID: "fixture", bootNonce: nonce,
                storageDirectory: storageDirectory ?? storage.path
            )
        }
    }

}
