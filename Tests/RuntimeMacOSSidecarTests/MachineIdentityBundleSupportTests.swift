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
import Darwin
import Foundation
import Testing

@testable import container_runtime_macos_sidecar

@Suite(.serialized)
struct MachineIdentityBundleSupportTests {
    @Test
    func captureVerifyAndMaterializeRoundTrip() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePrivateDirectory(root.appendingPathComponent("source"))
        let state = try makePrivateDirectory(root.appendingPathComponent("state"))
        let destination = try makePrivateDirectory(root.appendingPathComponent("destination"))
        let contents = try writeIdentityFiles(to: source, includeLease: true)
        try Data("stale".utf8).write(to: destination.appendingPathComponent("MachineIdentifier.bin"))

        try MacOSMachineIdentityBundleStore.capture(from: source, into: state)
        let manifest = try MacOSMachineIdentityBundleStore.verify(in: state)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.files.map(\.name) == manifest.files.map(\.name).sorted())
        #expect(manifest.files.count == 4)

        try MacOSMachineIdentityBundleStore.materialize(from: state, into: destination)
        for (name, expected) in contents {
            #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == expected)
            #expect(try permissions(destination.appendingPathComponent(name)) == 0o600)
        }
        #expect(
            try permissions(
                state.appendingPathComponent(MacOSMachineIdentityBundleStore.bundleDirectoryName)
            ) == 0o700
        )

        // Materialization is intentionally retry-safe.
        try MacOSMachineIdentityBundleStore.materialize(from: state, into: destination)
        for (name, expected) in contents {
            #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == expected)
        }
    }

    @Test
    func bundleWithoutNetworkLeaseClearsAStaleDestinationLease() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePrivateDirectory(root.appendingPathComponent("source"))
        let state = try makePrivateDirectory(root.appendingPathComponent("state"))
        let destination = try makePrivateDirectory(root.appendingPathComponent("destination"))
        _ = try writeIdentityFiles(to: source, includeLease: false)
        let lease = destination.appendingPathComponent("macos-guest-network-lease.json")
        try Data("stale".utf8).write(to: lease)

        try MacOSMachineIdentityBundleStore.capture(from: source, into: state)
        try MacOSMachineIdentityBundleStore.materialize(from: state, into: destination)

        #expect(!FileManager.default.fileExists(atPath: lease.path))
    }

    @Test
    func staleTemporaryDirectoriesDoNotBlockCaptureOrMaterializeRetry() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePrivateDirectory(root.appendingPathComponent("source"))
        let state = try makePrivateDirectory(root.appendingPathComponent("state"))
        let destination = try makePrivateDirectory(root.appendingPathComponent("destination"))
        let contents = try writeIdentityFiles(to: source, includeLease: false)

        _ = try makePrivateDirectory(state.appendingPathComponent(".identity-\(UUID().uuidString.lowercased()).tmp"))
        _ = try makePrivateDirectory(
            destination.appendingPathComponent(".identity-materialize-\(UUID().uuidString.lowercased()).tmp")
        )

        try MacOSMachineIdentityBundleStore.capture(from: source, into: state)
        try MacOSMachineIdentityBundleStore.materialize(from: state, into: destination)

        for (name, expected) in contents {
            #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == expected)
        }
    }

    @Test
    func verifyRejectsContentTampering() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePrivateDirectory(root.appendingPathComponent("source"))
        let state = try makePrivateDirectory(root.appendingPathComponent("state"))
        _ = try writeIdentityFiles(to: source, includeLease: true)
        try MacOSMachineIdentityBundleStore.capture(from: source, into: state)
        let auxiliaryStorage =
            state
            .appendingPathComponent(MacOSMachineIdentityBundleStore.bundleDirectoryName)
            .appendingPathComponent("AuxiliaryStorage")
        try Data("tampered".utf8).write(to: auxiliaryStorage)

        do {
            _ = try MacOSMachineIdentityBundleStore.verify(in: state)
            Issue.record("tampered identity bundle was accepted")
        } catch let error as SidecarRPCError {
            #expect(error.code == "identityBundleCorrupt")
        }
    }

    @Test
    func captureRejectsMissingRequiredFileAndSymbolicLinkSource() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingSource = try makePrivateDirectory(root.appendingPathComponent("missing-source"))
        let missingState = try makePrivateDirectory(root.appendingPathComponent("missing-state"))
        try Data("hardware".utf8).write(to: missingSource.appendingPathComponent("HardwareModel.bin"))
        try Data("auxiliary".utf8).write(to: missingSource.appendingPathComponent("AuxiliaryStorage"))

        do {
            try MacOSMachineIdentityBundleStore.capture(from: missingSource, into: missingState)
            Issue.record("incomplete identity source was accepted")
        } catch let error as SidecarRPCError {
            #expect(error.code == "identityBundleIncomplete")
        }

        let linkedSource = try makePrivateDirectory(root.appendingPathComponent("linked-source"))
        let linkedState = try makePrivateDirectory(root.appendingPathComponent("linked-state"))
        _ = try writeIdentityFiles(to: linkedSource, includeLease: false)
        let identifier = linkedSource.appendingPathComponent("MachineIdentifier.bin")
        try FileManager.default.removeItem(at: identifier)
        try FileManager.default.createSymbolicLink(
            at: identifier,
            withDestinationURL: linkedSource.appendingPathComponent("HardwareModel.bin")
        )

        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineIdentityBundleStore.capture(from: linkedSource, into: linkedState)
        }
    }

    @Test
    func materializeRejectsUnsafeDestinationEntry() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePrivateDirectory(root.appendingPathComponent("source"))
        let state = try makePrivateDirectory(root.appendingPathComponent("state"))
        let destination = try makePrivateDirectory(root.appendingPathComponent("destination"))
        _ = try writeIdentityFiles(to: source, includeLease: false)
        try MacOSMachineIdentityBundleStore.capture(from: source, into: state)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("AuxiliaryStorage"),
            withIntermediateDirectories: false
        )

        do {
            try MacOSMachineIdentityBundleStore.materialize(from: state, into: destination)
            Issue.record("unsafe identity destination was accepted")
        } catch let error as SidecarRPCError {
            #expect(error.code == "unsafeIdentityBundlePath")
        }
    }
}

private func makePrivateTemporaryDirectory() throws -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
    let canonicalPath = temporaryPath.hasPrefix("/var/") ? "/private\(temporaryPath)" : temporaryPath
    let url = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        .appendingPathComponent("machine-identity-tests-\(UUID().uuidString)")
    return try makePrivateDirectory(url)
}

@discardableResult
private func makePrivateDirectory(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    #expect(chmod(url.path, mode_t(0o700)) == 0)
    return url
}

private func writeIdentityFiles(to root: URL, includeLease: Bool) throws -> [String: Data] {
    var contents = [
        "HardwareModel.bin": Data("hardware-model".utf8),
        "MachineIdentifier.bin": Data("machine-identifier".utf8),
        "AuxiliaryStorage": Data("auxiliary-storage".utf8),
    ]
    if includeLease {
        contents["macos-guest-network-lease.json"] = Data(#"{"interfaces":[]}"#.utf8)
    }
    for (name, data) in contents {
        try data.write(to: root.appendingPathComponent(name))
    }
    return contents
}

private func permissions(_ url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return UInt16(try #require(attributes[.posixPermissions] as? NSNumber).uint16Value)
}
#endif
