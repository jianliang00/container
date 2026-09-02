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

public enum MacOSSidecarLifecycleBarrierProtocol {
    public static let current = 1
    public static let lockFileName = "sidecar.lifecycle.lock"
    public static let attestationFileName = "sidecar.lifecycle.attestation.json"
    public static let maximumAttestationBytes = 64 * 1024

    public static func lockPath(storageDirectory: String) -> String {
        URL(fileURLWithPath: storageDirectory, isDirectory: true)
            .appendingPathComponent(lockFileName, isDirectory: false).path
    }

    public static func attestationPath(storageDirectory: String) -> String {
        URL(fileURLWithPath: storageDirectory, isDirectory: true)
            .appendingPathComponent(attestationFileName, isDirectory: false).path
    }
}

public enum MacOSSidecarLifecycleAttestationState: String, Codable, Equatable, Sendable {
    case prepared
    case active
    case retired
}

public struct MacOSSidecarLifecycleAttestation: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var protocolVersion: Int
    public var persistenceID: String
    public var sandboxID: String
    public var bootNonce: String
    public var processID: Int32
    public var lockDevice: UInt64
    public var lockInode: UInt64
    public var state: MacOSSidecarLifecycleAttestationState

    public init(
        schemaVersion: Int = 1,
        protocolVersion: Int,
        persistenceID: String,
        sandboxID: String,
        bootNonce: String,
        processID: Int32,
        lockDevice: UInt64,
        lockInode: UInt64,
        state: MacOSSidecarLifecycleAttestationState
    ) {
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.persistenceID = persistenceID
        self.sandboxID = sandboxID
        self.bootNonce = bootNonce
        self.processID = processID
        self.lockDevice = lockDevice
        self.lockInode = lockInode
        self.state = state
    }
}

/// Owns the process-lifetime flock advertised by a sidecar attestation.
/// The attestation is committed only after the lock is held and is left in
/// place after exit so a cleanup process can audit the last boot identity.
public final class MacOSSidecarLifecycleLock: @unchecked Sendable {
    private var descriptor: Int32

    public init(
        protocolVersion: Int,
        persistenceID: String,
        sandboxID: String,
        bootNonce: String,
        storageDirectory: String,
        effectiveUserID: uid_t = geteuid()
    ) throws {
        guard protocolVersion == MacOSSidecarLifecycleBarrierProtocol.current else {
            throw POSIXError(.EPROTONOSUPPORT)
        }
        guard UUID(uuidString: bootNonce)?.uuidString.lowercased() == bootNonce else {
            throw POSIXError(.EINVAL)
        }

        let storageURL = URL(fileURLWithPath: storageDirectory, isDirectory: true).standardizedFileURL
        guard storageDirectory.hasPrefix("/"), storageURL.path == storageDirectory else {
            throw POSIXError(.EINVAL)
        }
        let directoryFD = open(storageDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw Self.posixError()
        }
        defer { Darwin.close(directoryFD) }

        var directoryValue = stat()
        guard fstat(directoryFD, &directoryValue) == 0,
            (directoryValue.st_mode & S_IFMT) == S_IFDIR,
            directoryValue.st_uid == effectiveUserID,
            directoryValue.st_mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw POSIXError(.EPERM)
        }

        let lockFD = openat(
            directoryFD,
            MacOSSidecarLifecycleBarrierProtocol.lockFileName,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard lockFD >= 0 else {
            throw Self.posixError()
        }
        var retainedLock = false
        defer {
            if !retainedLock {
                _ = flock(lockFD, LOCK_UN)
                Darwin.close(lockFD)
            }
        }

        var lockValue = stat()
        guard fstat(lockFD, &lockValue) == 0,
            (lockValue.st_mode & S_IFMT) == S_IFREG,
            lockValue.st_uid == effectiveUserID,
            lockValue.st_mode & mode_t(0o777) == mode_t(0o600),
            lockValue.st_nlink == 1
        else {
            throw POSIXError(.EPERM)
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw Self.posixError()
        }
        try Self.requireStableLockPath(
            directoryFD: directoryFD,
            expected: lockValue,
            expectedOwnerUID: effectiveUserID
        )

        let expectedAttestation = try Self.readAttestation(
            directoryFD: directoryFD,
            expectedOwnerUID: effectiveUserID
        )
        guard expectedAttestation.schemaVersion == 1,
            expectedAttestation.protocolVersion == protocolVersion,
            expectedAttestation.persistenceID == persistenceID,
            expectedAttestation.sandboxID == sandboxID,
            expectedAttestation.bootNonce == bootNonce,
            expectedAttestation.lockDevice == UInt64(lockValue.st_dev),
            expectedAttestation.lockInode == UInt64(lockValue.st_ino),
            expectedAttestation.processID == 0,
            expectedAttestation.state == .prepared
        else {
            throw POSIXError(.EPERM)
        }

        let attestation = MacOSSidecarLifecycleAttestation(
            protocolVersion: protocolVersion,
            persistenceID: persistenceID,
            sandboxID: sandboxID,
            bootNonce: bootNonce,
            processID: getpid(),
            lockDevice: UInt64(lockValue.st_dev),
            lockInode: UInt64(lockValue.st_ino),
            state: .active
        )
        try Self.persistAttestation(
            attestation,
            directoryFD: directoryFD,
            ownerUID: effectiveUserID
        )
        try Self.requireStableLockPath(
            directoryFD: directoryFD,
            expected: lockValue,
            expectedOwnerUID: effectiveUserID
        )
        let readback = try Self.readAttestation(
            directoryFD: directoryFD,
            expectedOwnerUID: effectiveUserID
        )
        guard readback == attestation else {
            throw POSIXError(.EIO)
        }

        descriptor = lockFD
        retainedLock = true
    }

    deinit {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    public static func readAttestation(
        directoryFD: Int32,
        expectedOwnerUID: uid_t
    ) throws -> MacOSSidecarLifecycleAttestation {
        let fd = openat(
            directoryFD,
            MacOSSidecarLifecycleBarrierProtocol.attestationFileName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw posixError()
        }
        defer { Darwin.close(fd) }

        var value = stat()
        guard fstat(fd, &value) == 0,
            (value.st_mode & S_IFMT) == S_IFREG,
            value.st_uid == expectedOwnerUID,
            value.st_mode & mode_t(0o777) == mode_t(0o600),
            value.st_nlink == 1,
            value.st_size > 0,
            value.st_size <= MacOSSidecarLifecycleBarrierProtocol.maximumAttestationBytes
        else {
            throw POSIXError(.EPERM)
        }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        let attestation = try JSONDecoder().decode(MacOSSidecarLifecycleAttestation.self, from: data)
        guard attestation.schemaVersion == 1,
            attestation.protocolVersion == MacOSSidecarLifecycleBarrierProtocol.current,
            UUID(uuidString: attestation.bootNonce)?.uuidString.lowercased() == attestation.bootNonce,
            !attestation.persistenceID.isEmpty,
            !attestation.sandboxID.isEmpty,
            attestation.processID >= 0,
            attestation.state != .prepared || attestation.processID == 0,
            attestation.state != .active || attestation.processID > 0
        else {
            throw POSIXError(.EINVAL)
        }
        return attestation
    }

    public static func persistAttestation(
        _ attestation: MacOSSidecarLifecycleAttestation,
        directoryFD: Int32,
        ownerUID: uid_t
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(attestation)
        guard !data.isEmpty, data.count <= MacOSSidecarLifecycleBarrierProtocol.maximumAttestationBytes else {
            throw POSIXError(.EFBIG)
        }

        let temporaryName = ".sidecar.lifecycle.\(UUID().uuidString.lowercased()).tmp"
        let temporaryFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else {
            throw posixError()
        }
        defer {
            Darwin.close(temporaryFD)
            _ = unlinkat(directoryFD, temporaryName, 0)
        }

        guard fchown(temporaryFD, ownerUID, gid_t.max) == 0,
            fchmod(temporaryFD, mode_t(0o600)) == 0
        else {
            throw posixError()
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    temporaryFD,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
        guard fsync(temporaryFD) == 0 else {
            throw posixError()
        }
        guard
            renameat(
                directoryFD,
                temporaryName,
                directoryFD,
                MacOSSidecarLifecycleBarrierProtocol.attestationFileName
            ) == 0
        else {
            throw posixError()
        }
        guard fsync(directoryFD) == 0 else {
            throw posixError()
        }
    }

    private static func requireStableLockPath(
        directoryFD: Int32,
        expected: stat,
        expectedOwnerUID: uid_t
    ) throws {
        var current = stat()
        guard
            fstatat(
                directoryFD,
                MacOSSidecarLifecycleBarrierProtocol.lockFileName,
                &current,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            (current.st_mode & S_IFMT) == S_IFREG,
            current.st_uid == expectedOwnerUID,
            current.st_mode & mode_t(0o777) == mode_t(0o600),
            current.st_nlink == 1,
            current.st_dev == expected.st_dev,
            current.st_ino == expected.st_ino
        else {
            throw POSIXError(.EPERM)
        }
    }

    public static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
