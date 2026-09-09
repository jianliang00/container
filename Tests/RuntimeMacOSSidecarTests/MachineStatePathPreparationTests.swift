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

#if os(macOS)
import ContainerResource
import Darwin
import Foundation
import Logging
import RuntimeMacOSSidecarShared
import Testing

@testable import container_runtime_macos_sidecar

struct MachineStatePathPreparationTests {
    @Test(arguments: [false, true], [MacOSSidecarProtocolVersion.machineState, MacOSSidecarProtocolVersion.durableCheckpointAdoption])
    func servicePreparesTheSameIdentityAndStoreThroughBothDarwinSpellings(useAlias: Bool, protocolVersion: Int) async throws {
        let parent = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let storage = parent.appendingPathComponent("binding", isDirectory: true)
        let path = useAlias ? String(storage.path.dropFirst("/private".count)) : storage.path
        let config = makeConfiguration(storageDirectory: path, protocolVersion: protocolVersion)
        let service = makeService(root: parent)

        // Exercise the methods used by VM identity construction and save/restore,
        // without booting a VM or requiring an image or Virtualization entitlement.
        let identity = try #require(await service.persistentIdentityDirectory(containerConfig: config))
        #expect(identity.path == storage.appendingPathComponent("Identity").path)
        try expectPrivateDirectory(storage)
        try expectPrivateDirectory(identity)
        let identifier = identity.appendingPathComponent("MachineIdentifier.bin")
        let contents = Data("retained-identity".utf8)
        try contents.write(to: identifier)

        // A new sidecar and the other path spelling must reuse the same identity.
        let rebuiltService = makeService(root: parent)
        let otherPath = useAlias ? storage.path : String(storage.path.dropFirst("/private".count))
        let rebuiltConfig = makeConfiguration(storageDirectory: otherPath, protocolVersion: protocolVersion)
        let rebuiltIdentity = try await rebuiltService.persistentIdentityDirectory(containerConfig: rebuiltConfig)
        #expect(rebuiltIdentity == identity)
        #expect(try Data(contentsOf: identifier) == contents)

        let store = try await service.machineStateStore(containerConfig: config)
        let reservation = try store.reserve(stateID: "state-1")
        #expect(reservation.directoryURL.path == storage.appendingPathComponent("MachineStates/state-1").path)
        try expectPrivateDirectory(reservation.directoryURL)
        store.abort(reservation)
    }

    @Test
    func legacyConfigurationDoesNotCreatePersistentIdentity() async throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)
        let config = makeConfiguration(storageDirectory: nil)
        #expect(try await service.persistentIdentityDirectory(containerConfig: config) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let store = try await service.machineStateStore(containerConfig: config)
        let reservation = try store.reserve(stateID: "legacy")
        #expect(reservation.directoryURL.path == root.appendingPathComponent("MachineStates/legacy").path)
        store.abort(reservation)
    }

    @Test(arguments: ["relative", "", "/", "dot", "traversal", "duplicate", "nul"])
    func serviceRejectsNoncanonicalConfigurationBeforeCreatingFiles(kind: String) async throws {
        let parent = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let path: String
        switch kind {
        case "dot": path = parent.path + "/./binding"
        case "traversal": path = parent.path + "/binding/../escape"
        case "duplicate": path = parent.path + "//binding"
        case "nul": path = parent.path + "/binding\0ignored"
        default: path = kind
        }
        try await expectServiceRejection(root: parent, storageDirectory: path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test(arguments: ["parent", "storage", "identity"], [false, true])
    func identityPreparationRejectsSymbolicLinksWithoutTouchingTheirTargets(location: String, dangling: Bool) async throws {
        let parent = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        if !dangling { try makePrivateDirectory(target) }
        let storage: URL
        switch location {
        case "parent":
            let link = parent.appendingPathComponent("linked-parent")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            storage = link.appendingPathComponent("binding")
        case "storage":
            storage = parent.appendingPathComponent("binding")
            try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: target)
        default:
            storage = parent.appendingPathComponent("binding")
            try makePrivateDirectory(storage)
            try FileManager.default.createSymbolicLink(at: storage.appendingPathComponent("Identity"), withDestinationURL: target)
        }
        let service = makeService(root: parent)
        do {
            _ = try await service.persistentIdentityDirectory(containerConfig: makeConfiguration(storageDirectory: storage.path))
            Issue.record("symbolic-link identity path was accepted")
        } catch let error as SidecarRPCError {
            #expect(error.code == "unsafeMachineStatePath")
        }
        if dangling {
            #expect(!FileManager.default.fileExists(atPath: target.path))
        } else {
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
            try expectPrivateDirectory(target)
        }
    }

    @Test(arguments: ["parent", "storage", "identity"])
    func identityPreparationRejectsUnsafePermissionsWithoutRepairingThem(location: String) async throws {
        let parent = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let storage = parent.appendingPathComponent("binding")
        let identity = storage.appendingPathComponent("Identity")
        try makePrivateDirectory(storage)
        try makePrivateDirectory(identity)
        let unsafe = location == "parent" ? parent : (location == "storage" ? storage : identity)
        #expect(chmod(unsafe.path, 0o755) == 0)
        let service = makeService(root: parent)
        do {
            _ = try await service.persistentIdentityDirectory(containerConfig: makeConfiguration(storageDirectory: storage.path))
            Issue.record("unsafe identity permissions were accepted")
        } catch let error as SidecarRPCError {
            #expect(error.code == "unsafeMachineStatePath")
            #expect(error.message.contains("unsafe permissions"))
        }
        #expect(try status(unsafe).st_mode & 0o777 == 0o755)
    }

    @Test
    func identityPreparationRejectsAnUntrustedParentOwner() async throws {
        // This private fixture is inside a root-owned temporary directory.
        // Rejection must precede creation of any identity data inside it.
        let storage = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let service = makeService(root: storage)
        do {
            _ = try await service.persistentIdentityDirectory(containerConfig: makeConfiguration(storageDirectory: storage.path))
            Issue.record("untrusted persistent parent was accepted")
        } catch let error as SidecarRPCError {
            #expect(error.code == "unsafeMachineStatePath")
            #expect(error.message.contains(geteuid() == 0 ? "unsafe permissions" : "unexpected owner"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.path).isEmpty)
    }

    @Test
    func sharedPreparationRejectsUnexpectedOwnerAndTraversal() throws {
        let parent = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let storage = parent.appendingPathComponent("binding")
        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineStateStore.preparePersistentRoot(at: storage, effectiveUserID: geteuid() &+ 1)
        }
        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineStateStore.preparePersistentRoot(at: URL(fileURLWithPath: parent.path + "/./binding"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test
    func invalidProtocolIsRejectedConsistentlyWithoutCreatingDirectories() async throws {
        let parent = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        try await expectServiceRejection(
            root: parent, storageDirectory: parent.appendingPathComponent("binding").path,
            protocolVersion: -1, code: "protocolVersionMismatch"
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    private func expectServiceRejection(root: URL, storageDirectory: String, protocolVersion: Int = 2, code: String = "unsafeMachineStatePath") async throws {
        let service = makeService(root: root)
        let config = makeConfiguration(storageDirectory: storageDirectory, protocolVersion: protocolVersion)
        do {
            _ = try await service.persistentIdentityDirectory(containerConfig: config)
            Issue.record("unsafe identity configuration was accepted")
        } catch let error as SidecarRPCError {
            #expect(error.code == code)
        }
        do {
            _ = try await service.machineStateStore(containerConfig: config)
            Issue.record("unsafe storage configuration was accepted")
        } catch let error as SidecarRPCError {
            #expect(error.code == code)
        }
    }

    private func makeService(root: URL) -> MacOSSidecarService {
        MacOSSidecarService(rootURL: root, log: Logger(label: "identity-path-tests"))
    }

    private func makeConfiguration(storageDirectory: String?, protocolVersion: Int = 2) -> ContainerConfiguration {
        var configuration = ContainerConfiguration(
            id: "identity-path-test",
            image: .init(reference: "example/macos:latest", descriptor: .init(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:test", size: 1)),
            process: .init(executable: "/usr/bin/true", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        )
        configuration.macosGuest = .init(
            snapshotEnabled: storageDirectory != nil, guiEnabled: false, agentPort: 27_000,
            machineState: storageDirectory.map {
                .init(protocolVersion: protocolVersion, persistenceID: "binding", storageDirectory: $0, controlSocketPath: "/var/run/container/test.sock")
            }
        )
        return configuration
    }

    private func makePrivateTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("container-identity-tests-\(UUID().uuidString)", isDirectory: true)
        try makePrivateDirectory(directory)
        return directory
    }

    private func makePrivateDirectory(_ directory: URL) throws {
        guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func expectPrivateDirectory(_ directory: URL) throws {
        let information = try status(directory)
        #expect(information.st_mode & S_IFMT == S_IFDIR)
        #expect(information.st_mode & 0o777 == 0o700)
        #expect(information.st_uid == geteuid())
    }

    private func status(_ path: URL) throws -> stat {
        var information = stat()
        guard lstat(path.path, &information) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return information
    }
}
#endif
