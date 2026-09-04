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
import Virtualization

@testable import container_runtime_macos_sidecar

struct ActiveMachineIdentityTests {
    @Test(arguments: ["hostIdentifier", "hostBuild", "configuration", "stateID", "pair"])
    func restorePreflightRejectsIncompatibilityWithoutChangingActiveFiles(kind: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let saved = try fixture.save()
        var config = fixture.restoreConfig
        var compatibility = saved.compatibility
        var expectedCode = "machineStateIncompatible"
        if kind == "hostIdentifier" || kind == "hostBuild" {
            let data = try JSONEncoder().encode(compatibility)
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object[kind] = "different-\(kind)"
            compatibility = try JSONDecoder().decode(
                MacOSMachineStateCompatibilityDescription.self, from: JSONSerialization.data(withJSONObject: object)
            )
        } else if kind == "configuration" {
            config.macosGuest?.guiEnabled = true
        } else if kind == "stateID" {
            config.macosGuest?.machineState?.restoreStateID = "different-state"
            expectedCode = "machineStateRequestMismatch"
        } else {
            config.macosGuest?.machineState?.protocolVersion = MacOSSidecarProtocolVersion.durableCheckpointAdoption
            expectedCode = "durablePairMismatch"
        }
        let stored = MacOSMachineStateStore.StoredState(
            directoryURL: saved.directoryURL, stateURL: saved.stateURL, compatibility: compatibility, receipt: saved.receipt
        )
        let auxiliary = Data("must-not-change".utf8)
        try write(auxiliary, to: fixture.identity.auxiliaryStorageURL)
        do {
            _ = try await fixture.service.prepareRestoredIdentity(containerConfig: config, stored: stored)
            Issue.record("restore bypassed preflight validation")
        } catch let error as SidecarRPCError {
            #expect(error.code == expectedCode)
        }
        #expect(try Data(contentsOf: fixture.identity.auxiliaryStorageURL) == auxiliary)
        #expect(try Data(contentsOf: fixture.identity.machineIdentifierURL) == fixture.identifier)
        try expectNoTemporaryFiles(fixture.identity.identityRootURL)
    }

    @Test
    func configuredRestoreCannotEnterTheColdBootPath() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        try write(JSONEncoder().encode(fixture.restoreConfig), to: fixture.runtime.appendingPathComponent("config.json"))
        do {
            try await fixture.service.bootstrapStart(presentGUI: false)
            Issue.record("configured restore fell back to cold boot")
        } catch let error as SidecarRPCError {
            #expect(error.code == "machineStateRestoreRequired")
        }
        #expect(try Data(contentsOf: fixture.identity.machineIdentifierURL) == fixture.identifier)
        #expect(try Data(contentsOf: fixture.identity.auxiliaryStorageURL) == fixture.auxiliary)
    }

    @Test
    func persistentBundleOperationsRequireAnExplicitCompatibilityBinding() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let stored = try fixture.save()
        let target = try makeDirectory(fixture.parent.appendingPathComponent("unbound"))
        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineIdentityBundleStore.capture(from: fixture.identity, into: target)
        }
        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineIdentityBundleStore.materialize(from: stored.directoryURL, into: fixture.identity)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test
    func invalidIdentityPathAndFIFOAreRejected() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        #expect(throws: SidecarRPCError.self) {
            _ = try MacOSActiveMachineIdentity(runtimeRootURL: URL(fileURLWithPath: fixture.runtime.path + "/../runtime"))
        }
        #expect(throws: SidecarRPCError.self) { _ = try fixture.identity.fileURL(for: "../escape") }
        #expect(throws: SidecarRPCError.self) {
            _ = try MacOSMachineIdentityBundleStore.verify(in: URL(fileURLWithPath: fixture.runtime.path + "/../runtime"))
        }
        try FileManager.default.removeItem(at: fixture.identity.machineIdentifierURL)
        #expect(mkfifo(fixture.identity.machineIdentifierURL.path, 0o600) == 0)
        #expect(throws: SidecarRPCError.self) { _ = try fixture.identity.loadOrCreateMachineIdentifier(allowCreation: true) }
    }

    @Test
    func divergentRuntimeFilesAreNotCapturedOrRestoredOverTheActiveIdentity() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let stored = try fixture.save()
        let bundle = stored.directoryURL.appendingPathComponent("Identity")
        #expect(try Data(contentsOf: bundle.appendingPathComponent("MachineIdentifier.bin")) == fixture.identifier)
        #expect(try Data(contentsOf: bundle.appendingPathComponent("AuxiliaryStorage")) == fixture.auxiliary)
        #expect(stored.compatibility.machineIdentifierFingerprint == sha256Fingerprint(fixture.identifier))

        let newRoot = try makeDirectory(fixture.parent.appendingPathComponent("rebuilt-runtime"))
        let staleIdentifier = VZMacMachineIdentifier().dataRepresentation
        let staleAuxiliary = Data("stale-runtime-auxiliary".utf8)
        try write(fixture.hardware, to: newRoot.appendingPathComponent("HardwareModel.bin"))
        try write(staleIdentifier, to: newRoot.appendingPathComponent("MachineIdentifier.bin"))
        try write(staleAuxiliary, to: newRoot.appendingPathComponent("AuxiliaryStorage"))
        // Auxiliary storage is mutable. Restore may roll it back only after
        // the checkpoint binding and immutable active identity are validated.
        try write(Data("later-nvram".utf8), to: fixture.identity.auxiliaryStorageURL)
        let service = MacOSSidecarService(rootURL: newRoot, log: Logger(label: "rebuilt-identity"))
        let restored = try await service.prepareRestoredIdentity(containerConfig: fixture.restoreConfig, stored: stored)
        #expect(restored.machineIdentifierURL == fixture.identity.machineIdentifierURL)
        #expect(try restored.loadOrCreateMachineIdentifier(allowCreation: false).dataRepresentation == fixture.identifier)
        #expect(try Data(contentsOf: restored.prepareAuxiliaryStorage(allowCreation: false)) == fixture.auxiliary)
        #expect(try Data(contentsOf: newRoot.appendingPathComponent("MachineIdentifier.bin")) == staleIdentifier)
        #expect(try Data(contentsOf: newRoot.appendingPathComponent("AuxiliaryStorage")) == staleAuxiliary)
        // Repeating preparation with another sidecar instance is retry-safe.
        let retryService = MacOSSidecarService(rootURL: newRoot, log: Logger(label: "identity-retry"))
        _ = try await retryService.prepareRestoredIdentity(containerConfig: fixture.restoreConfig, stored: stored)
        #expect(try Data(contentsOf: restored.auxiliaryStorageURL) == fixture.auxiliary)
    }

    @Test
    func restorePopulatesAnEmptyPersistentIdentityWithoutUsingStaleRuntimeFiles() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let stored = try fixture.save()
        let empty = try makeDirectory(fixture.parent.appendingPathComponent("empty-identity"))
        let target = try MacOSActiveMachineIdentity(runtimeRootURL: fixture.runtime, persistentIdentityURL: empty)
        try MacOSMachineIdentityBundleStore.materialize(from: stored.directoryURL, into: target, compatibility: stored.compatibility)
        #expect(try target.loadOrCreateMachineIdentifier(allowCreation: false).dataRepresentation == fixture.identifier)
        #expect(try Data(contentsOf: target.prepareAuxiliaryStorage(allowCreation: false)) == fixture.auxiliary)
    }

    @Test(arguments: ["HardwareModel.bin", "MachineIdentifier.bin"])
    func existingImmutableMismatchRejectsRestoreBeforeAnyFileChanges(filename: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let stored = try fixture.save()
        let mismatched = filename == "MachineIdentifier.bin" ? VZMacMachineIdentifier().dataRepresentation : Data("other-hardware".utf8)
        let target = try fixture.identity.fileURL(for: filename)
        try write(mismatched, to: target)
        let auxiliary = Data("unmodified-active-auxiliary".utf8)
        try write(auxiliary, to: fixture.identity.auxiliaryStorageURL)
        do {
            _ = try await fixture.service.prepareRestoredIdentity(containerConfig: fixture.restoreConfig, stored: stored)
            Issue.record("mismatched active identity was overwritten")
        } catch let error as SidecarRPCError {
            #expect(error.code == "activeIdentityMismatch")
        }
        #expect(try Data(contentsOf: target) == mismatched)
        #expect(try Data(contentsOf: fixture.identity.auxiliaryStorageURL) == auxiliary)
        try expectNoTemporaryFiles(fixture.identity.identityRootURL)
    }

    @Test
    func legacySourceBundleCannotMasqueradeAsTheActivePersistentIdentity() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let state = try makeDirectory(fixture.parent.appendingPathComponent("wrong-source-state"))
        try MacOSMachineIdentityBundleStore.capture(from: fixture.runtime, into: state)
        let compatibility = try fixture.compatibility()
        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineIdentityBundleStore.verify(in: state, compatibility: compatibility)
        }
        do {
            try MacOSMachineIdentityBundleStore.materialize(from: state, into: fixture.identity, compatibility: compatibility)
            Issue.record("runtime-root bundle was accepted as persistent identity")
        } catch let error as SidecarRPCError {
            #expect(error.code == "identityBundleMismatch")
        }
        #expect(try Data(contentsOf: fixture.identity.machineIdentifierURL) == fixture.identifier)
        #expect(try Data(contentsOf: fixture.identity.auxiliaryStorageURL) == fixture.auxiliary)
    }

    @Test
    func captureRejectsChangedActiveIdentityAndCleansItsStagingFiles() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let compatibility = try fixture.compatibility()
        try write(VZMacMachineIdentifier().dataRepresentation, to: fixture.identity.machineIdentifierURL)
        let state = try makeDirectory(fixture.parent.appendingPathComponent("failed-capture"))
        do {
            try MacOSMachineIdentityBundleStore.capture(from: fixture.identity, into: state, compatibility: compatibility)
            Issue.record("capture accepted identity different from the configured VM")
        } catch let error as SidecarRPCError {
            #expect(error.code == "identityBundleMismatch")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: state.path).isEmpty)
    }

    @Test(arguments: ["symlink", "hardlink", "writable"])
    func unsafeExistingIdentityFailsBeforeMaterialization(kind: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let stored = try fixture.save()
        let auxiliary = fixture.identity.auxiliaryStorageURL
        let other = fixture.parent.appendingPathComponent("untouched")
        let contents = Data("protected-target".utf8)
        try write(contents, to: other)
        switch kind {
        case "symlink":
            try FileManager.default.removeItem(at: auxiliary)
            try FileManager.default.createSymbolicLink(at: auxiliary, withDestinationURL: other)
        case "hardlink":
            try FileManager.default.removeItem(at: auxiliary)
            #expect(link(other.path, auxiliary.path) == 0)
        default:
            #expect(chmod(auxiliary.path, 0o666) == 0)
        }
        do {
            _ = try await fixture.service.prepareRestoredIdentity(containerConfig: fixture.restoreConfig, stored: stored)
            Issue.record("unsafe destination was overwritten")
        } catch let error as SidecarRPCError {
            #expect(error.code == "unsafeIdentityBundlePath")
        }
        #expect(try Data(contentsOf: other) == contents)
        #expect(try Data(contentsOf: fixture.identity.machineIdentifierURL) == fixture.identifier)
        try expectNoTemporaryFiles(fixture.identity.identityRootURL)
    }

    @Test
    func identityFileOwnerValidationRejectsUnexpectedOwner() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let descriptor = open(fixture.identity.machineIdentifierURL.path, O_RDONLY | O_NOFOLLOW)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(throws: SidecarRPCError.self) {
            _ = try MacOSMachineIdentityBundleStore.validateRegularFileDescriptor(descriptor, effectiveUserID: geteuid() &+ 1)
        }
    }

    @Test
    func persistentIdentifierIsNotRegeneratedWhenInvalidOrLost() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let invalid = Data("invalid-machine-identifier".utf8)
        try write(invalid, to: fixture.identity.machineIdentifierURL)
        #expect(throws: SidecarRPCError.self) { _ = try fixture.identity.loadOrCreateMachineIdentifier(allowCreation: true) }
        #expect(try Data(contentsOf: fixture.identity.machineIdentifierURL) == invalid)
        try FileManager.default.removeItem(at: fixture.identity.machineIdentifierURL)
        #expect(throws: SidecarRPCError.self) { _ = try fixture.identity.loadOrCreateMachineIdentifier(allowCreation: true) }
        #expect(throws: SidecarRPCError.self) { _ = try fixture.identity.loadOrCreateMachineIdentifier(allowCreation: false) }
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.machineIdentifierURL.path))
    }

    @Test
    func legacyColdBootKeepsRuntimeRootAndRepairsInvalidIdentifier() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data("invalid".utf8), to: root.appendingPathComponent("MachineIdentifier.bin"))
        let auxiliary = Data("legacy-auxiliary".utf8)
        try write(auxiliary, to: root.appendingPathComponent("AuxiliaryStorage"))
        let identity = try MacOSActiveMachineIdentity(runtimeRootURL: root)
        let identifier = try identity.loadOrCreateMachineIdentifier(allowCreation: true)
        #expect(try Data(contentsOf: identity.machineIdentifierURL) == identifier.dataRepresentation)
        #expect(try identity.prepareAuxiliaryStorage(allowCreation: true) == root.appendingPathComponent("AuxiliaryStorage"))
        #expect(try Data(contentsOf: identity.auxiliaryStorageURL) == auxiliary)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Identity").path))
    }

    @Test
    func coldPersistentPreparationCopiesAuxiliaryOnlyOnce() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistent = try makeDirectory(root.appendingPathComponent("persistent"))
        try write(Data("seed".utf8), to: root.appendingPathComponent("AuxiliaryStorage"))
        let identity = try MacOSActiveMachineIdentity(runtimeRootURL: root, persistentIdentityURL: persistent)
        let identifier = try identity.loadOrCreateMachineIdentifier(allowCreation: true)
        _ = try identity.prepareAuxiliaryStorage(allowCreation: true)
        let otherRoot = try makeDirectory(root.appendingPathComponent("other-vm"))
        let otherIdentity = try MacOSActiveMachineIdentity(runtimeRootURL: root, persistentIdentityURL: otherRoot)
        #expect(try otherIdentity.loadOrCreateMachineIdentifier(allowCreation: true).dataRepresentation != identifier.dataRepresentation)
        try write(Data("changed-root".utf8), to: root.appendingPathComponent("AuxiliaryStorage"))
        #expect(try identity.loadOrCreateMachineIdentifier(allowCreation: true).dataRepresentation == identifier.dataRepresentation)
        #expect(try Data(contentsOf: identity.prepareAuxiliaryStorage(allowCreation: true)) == Data("seed".utf8))
        try expectNoTemporaryFiles(persistent)
    }

    @Test
    func newPersistentBindingInheritsAnExistingRuntimeIdentityPair() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistent = try makeDirectory(root.appendingPathComponent("persistent"))
        let original = VZMacMachineIdentifier().dataRepresentation
        let auxiliary = Data("existing-runtime-auxiliary".utf8)
        try write(original, to: root.appendingPathComponent("MachineIdentifier.bin"))
        try write(auxiliary, to: root.appendingPathComponent("AuxiliaryStorage"))
        let identity = try MacOSActiveMachineIdentity(runtimeRootURL: root, persistentIdentityURL: persistent)
        #expect(try identity.loadOrCreateMachineIdentifier(allowCreation: true).dataRepresentation == original)
        #expect(try Data(contentsOf: identity.prepareAuxiliaryStorage(allowCreation: true)) == auxiliary)
        #expect(try Data(contentsOf: root.appendingPathComponent("MachineIdentifier.bin")) == original)
        try write(VZMacMachineIdentifier().dataRepresentation, to: root.appendingPathComponent("MachineIdentifier.bin"))
        #expect(try identity.loadOrCreateMachineIdentifier(allowCreation: true).dataRepresentation == original)
    }

    @Test(arguments: ["invalidIdentifier", "missingAuxiliary", "unsafeAuxiliary"])
    func unsafeRuntimeIdentityPairIsNotReplacedWithANewIdentifier(kind: String) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistent = try makeDirectory(root.appendingPathComponent("persistent"))
        let identifier = kind == "invalidIdentifier" ? Data("invalid".utf8) : VZMacMachineIdentifier().dataRepresentation
        try write(identifier, to: root.appendingPathComponent("MachineIdentifier.bin"))
        if kind != "missingAuxiliary" {
            try write(Data("existing-auxiliary".utf8), to: root.appendingPathComponent("AuxiliaryStorage"))
        }
        if kind == "unsafeAuxiliary" { #expect(chmod(root.appendingPathComponent("AuxiliaryStorage").path, 0o666) == 0) }
        let identity = try MacOSActiveMachineIdentity(runtimeRootURL: root, persistentIdentityURL: persistent)
        #expect(throws: SidecarRPCError.self) { _ = try identity.loadOrCreateMachineIdentifier(allowCreation: true) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: persistent.path).isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent("MachineIdentifier.bin")) == identifier)
    }
}

private struct Fixture {
    let parent: URL
    let runtime: URL
    let config: ContainerConfiguration
    let service: MacOSSidecarService
    let identity: MacOSActiveMachineIdentity
    let hardware = Data("hardware-model".utf8)
    let identifier: Data
    let auxiliary = Data("active-auxiliary".utf8)

    static func make() async throws -> Fixture {
        let parent = try makeTemporaryDirectory()
        let runtime = try makeDirectory(parent.appendingPathComponent("runtime"))
        let persistence = try makeDirectory(parent.appendingPathComponent("persistence"))
        var config = ContainerConfiguration(
            id: "identity-test",
            image: .init(reference: "example/macos:latest", descriptor: .init(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:test", size: 1)),
            process: .init(executable: "/usr/bin/true", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        )
        config.macosGuest = .init(
            snapshotEnabled: true, guiEnabled: false, agentPort: 27_000,
            machineState: .init(
                persistenceID: "binding", storageDirectory: persistence.appendingPathComponent("binding").path, controlSocketPath: "/var/run/container/test.sock",
                storageGeneration: 1)
        )
        let service = MacOSSidecarService(rootURL: runtime, log: Logger(label: "active-identity-tests"))
        let identity = try await service.activeMachineIdentity(containerConfig: config)
        let fixture = Fixture(parent: parent, runtime: runtime, config: config, service: service, identity: identity, identifier: VZMacMachineIdentifier().dataRepresentation)
        try write(fixture.hardware, to: identity.hardwareModelURL)
        try write(fixture.identifier, to: identity.machineIdentifierURL)
        try write(fixture.auxiliary, to: identity.auxiliaryStorageURL)
        try write(VZMacMachineIdentifier().dataRepresentation, to: runtime.appendingPathComponent("MachineIdentifier.bin"))
        try write(Data("runtime-auxiliary".utf8), to: runtime.appendingPathComponent("AuxiliaryStorage"))
        return fixture
    }

    var restoreConfig: ContainerConfiguration {
        var config = config
        config.macosGuest?.machineState?.restoreStateID = "state-1"
        config.macosGuest?.machineState?.restoreStateGeneration = 1
        config.macosGuest?.machineState?.storageGeneration = 2
        return config
    }

    func compatibility() throws -> MacOSMachineStateCompatibilityDescription {
        try MacOSCompatibilityDescriptionBuilder.make(
            containerConfig: config, hardwareModelData: identity.hardwareModelData(),
            machineIdentifierData: identity.loadOrCreateMachineIdentifier(allowCreation: false).dataRepresentation,
            networkDeviceMACAddresses: [], storageDescriptions: []
        )
    }

    func save() throws -> MacOSMachineStateStore.StoredState {
        let store = MacOSMachineStateStore(runtimeRootURL: identity.identityRootURL.deletingLastPathComponent())
        let reservation = try store.reserve(stateID: "state-1")
        let compatibility = try compatibility()
        try MacOSMachineIdentityBundleStore.capture(from: identity, into: reservation.directoryURL, compatibility: compatibility)
        try write(Data("machine-state-fixture".utf8), to: reservation.stateURL)
        try store.commit(reservation, compatibility: compatibility)
        return try store.load(stateID: "state-1")
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
}

private func makeTemporaryDirectory() throws -> URL {
    try makeDirectory(URL(fileURLWithPath: "/private/var/tmp").appendingPathComponent("container-active-identity-\(UUID().uuidString)"))
}

private func makeDirectory(_ url: URL) throws -> URL {
    guard mkdir(url.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return url
}

private func write(_ data: Data, to url: URL) throws {
    try data.write(to: url)
    #expect(chmod(url.path, 0o600) == 0)
}

private func expectNoTemporaryFiles(_ directory: URL) throws {
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".tmp") })
}
#endif
