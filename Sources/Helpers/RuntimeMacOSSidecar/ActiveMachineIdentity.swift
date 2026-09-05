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
import RuntimeMacOSSidecarShared
@preconcurrency import Virtualization

/// The selected identity locations for one VM configuration. VZ configuration,
/// compatibility, checkpoint capture and restore must use this same selection.
struct MacOSActiveMachineIdentity: Sendable {
    let runtimeRootURL: URL
    let identityRootURL: URL
    let isPersistent: Bool

    init(runtimeRootURL: URL, persistentIdentityURL: URL? = nil) throws {
        self.runtimeRootURL = try Self.canonicalDirectory(runtimeRootURL)
        identityRootURL = try Self.canonicalDirectory(persistentIdentityURL ?? runtimeRootURL)
        isPersistent = persistentIdentityURL != nil
        try validateDirectories()
    }

    var hardwareModelURL: URL { runtimeRootURL.appendingPathComponent("HardwareModel.bin") }
    var machineIdentifierURL: URL { identityRootURL.appendingPathComponent("MachineIdentifier.bin") }
    var auxiliaryStorageURL: URL { identityRootURL.appendingPathComponent("AuxiliaryStorage") }

    func fileURL(for filename: String) throws -> URL {
        switch filename {
        case "HardwareModel.bin": return hardwareModelURL
        case "MachineIdentifier.bin": return machineIdentifierURL
        case "AuxiliaryStorage": return auxiliaryStorageURL
        case "macos-guest-network-lease.json": return runtimeRootURL.appendingPathComponent(filename)
        default: throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "unknown VM identity file")
        }
    }

    func validateDirectories() throws {
        try MacOSMachineIdentityBundleStore.requireManagedDirectory(runtimeRootURL, role: "runtime root", requirePrivateMode: false)
        if isPersistent {
            try MacOSMachineIdentityBundleStore.requireManagedDirectory(identityRootURL, role: "active identity", requirePrivateMode: true)
        }
    }

    func hardwareModelData() throws -> Data {
        try validateDirectories()
        return try MacOSMachineIdentityBundleStore.readRegularFile(hardwareModelURL, maximumSize: 1024 * 1024)
    }

    func loadOrCreateMachineIdentifier(allowCreation: Bool) throws -> VZMacMachineIdentifier {
        try validateDirectories()
        if try MacOSMachineIdentityBundleStore.pathStatus(machineIdentifierURL) != .missing {
            let data = try MacOSMachineIdentityBundleStore.readRegularFile(machineIdentifierURL, maximumSize: 4096)
            if let identifier = VZMacMachineIdentifier(dataRepresentation: data) { return identifier }
            // Legacy cold starts historically repaired an invalid identifier.
            // A persistent or restored VM must never silently change identity.
            guard !isPersistent && allowCreation else {
                throw SidecarRPCError(code: "activeIdentityInvalid", message: "existing VM machine identifier is invalid")
            }
            let identifier = VZMacMachineIdentifier()
            try identifier.dataRepresentation.write(to: machineIdentifierURL, options: .atomic)
            guard chmod(machineIdentifierURL.path, 0o600) == 0 else { throw Self.posixError() }
            return identifier
        }
        guard allowCreation else {
            throw SidecarRPCError(code: "identityBundleIncomplete", message: "restored machine identifier is missing")
        }
        if isPersistent, try MacOSMachineIdentityBundleStore.pathStatus(auxiliaryStorageURL) != .missing {
            throw SidecarRPCError(code: "activeIdentityInvalid", message: "persistent auxiliary storage exists without its machine identifier")
        }
        let identifier: VZMacMachineIdentifier
        let sourceIdentifier = runtimeRootURL.appendingPathComponent("MachineIdentifier.bin")
        if isPersistent, try MacOSMachineIdentityBundleStore.pathStatus(sourceIdentifier) != .missing {
            // Enabling persistence for an existing runtime must preserve its
            // identity pair. Templates without an identifier create a new VM.
            let data = try MacOSMachineIdentityBundleStore.readRegularFile(sourceIdentifier, maximumSize: 4096)
            guard let existing = VZMacMachineIdentifier(dataRepresentation: data) else {
                throw SidecarRPCError(code: "activeIdentityInvalid", message: "runtime machine identifier is invalid")
            }
            try MacOSMachineIdentityBundleStore.validateFile(runtimeRootURL.appendingPathComponent("AuxiliaryStorage"))
            identifier = existing
        } else {
            identifier = VZMacMachineIdentifier()
        }
        let descriptor = open(machineIdentifierURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        var committed = false
        defer {
            close(descriptor)
            if !committed { _ = unlink(machineIdentifierURL.path) }
        }
        try MacOSMachineIdentityBundleStore.writeAll(identifier.dataRepresentation, to: descriptor)
        guard fsync(descriptor) == 0 else { throw Self.posixError() }
        try MacOSMachineIdentityBundleStore.syncDirectory(identityRootURL)
        committed = true
        return identifier
    }

    func prepareAuxiliaryStorage(allowCreation: Bool) throws -> URL {
        try validateDirectories()
        if try MacOSMachineIdentityBundleStore.pathStatus(auxiliaryStorageURL) == .missing {
            guard isPersistent && allowCreation else {
                throw SidecarRPCError(code: "identityBundleIncomplete", message: "VM auxiliary storage is missing")
            }
            let temporary = identityRootURL.appendingPathComponent(".AuxiliaryStorage.\(UUID().uuidString).tmp")
            _ = try MacOSMachineIdentityBundleStore.copyAndDigest(
                from: runtimeRootURL.appendingPathComponent("AuxiliaryStorage"), to: temporary, expected: nil
            )
            defer { try? FileManager.default.removeItem(at: temporary) }
            // Publish without replacing any identity created by another owner
            // or retry. The runtime admission lease normally excludes peers.
            guard link(temporary.path, auxiliaryStorageURL.path) == 0 else { throw Self.posixError() }
            guard unlink(temporary.path) == 0 else { throw Self.posixError() }
            try MacOSMachineIdentityBundleStore.syncDirectory(identityRootURL)
        }
        try MacOSMachineIdentityBundleStore.validateFile(auxiliaryStorageURL)
        return auxiliaryStorageURL
    }

    private static func canonicalDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL, let path = MacOSManagedPath.canonicalPath(url.path), path != "/" else {
            throw SidecarRPCError(code: "unsafeIdentityBundlePath", message: "active VM identity requires a canonical local directory")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
