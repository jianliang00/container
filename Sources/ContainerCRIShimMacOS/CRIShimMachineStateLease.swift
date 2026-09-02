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

import ContainerResource
import CryptoKit
import Darwin
import Foundation
import RuntimeMacOSSidecarShared

enum CRIShimMachineStateLeaseAdmissionState: String, Codable, Equatable, Sendable {
    case reserved
    case runtimeCreationStarted
    case runtimeDeletionConfirmed
}

struct CRIShimMachineStateLease: Codable, Equatable, Sendable {
    struct SidecarLifecycleBarrier: Codable, Equatable, Sendable {
        var protocolVersion: Int
        var bootNonce: String
        var launchMayHaveStarted: Bool
    }

    var schemaVersion: Int = 2
    var persistenceID: String
    var podUID: String
    var sandboxID: String
    var restoreStateID: String?
    var restoreStateGeneration: UInt64?
    var storageGeneration: UInt64
    var admissionState: CRIShimMachineStateLeaseAdmissionState? = nil
    var sidecarLifecycleBarrier: SidecarLifecycleBarrier? = nil

    func hasSameOwner(as candidate: Self) -> Bool {
        persistenceID == candidate.persistenceID
            && podUID == candidate.podUID
            && restoreStateID == candidate.restoreStateID
            && restoreStateGeneration == candidate.restoreStateGeneration
            && storageGeneration == candidate.storageGeneration
    }

    func hasSameBinding(as candidate: Self) -> Bool {
        hasSameOwner(as: candidate) && sandboxID == candidate.sandboxID
    }

    func hasSameLifecycleIncarnation(as candidate: Self) -> Bool {
        hasSameBinding(as: candidate)
            && schemaVersion == candidate.schemaVersion
            && sidecarLifecycleBarrier == candidate.sidecarLifecycleBarrier
    }
}

struct CRIShimMachineStateLeaseAcquisition: Equatable, Sendable {
    var lease: CRIShimMachineStateLease
    var created: Bool
}

final class CRIShimMachineStateAdmissionLock: @unchecked Sendable {
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}

enum CRIShimMachineStateLeaseStore {
    private static let maximumLeaseBytes = 64 * 1024

    static func acquire(
        policy: MachineStateConfig,
        machineState: ContainerConfiguration.MacOSGuestOptions.MachineState,
        podUID: String,
        proposedSandboxID: String,
        effectiveUserID: uid_t = geteuid()
    ) throws -> CRIShimMachineStateLeaseAcquisition {
        guard let storageGeneration = machineState.storageGeneration, storageGeneration > 0 else {
            throw CRIShimError.invalidArgument("machine-state lease requires a positive storageGeneration")
        }
        let normalizedPodUID = podUID.trimmed
        guard !normalizedPodUID.isEmpty else {
            throw CRIShimError.invalidArgument("machine-state workloads require Kubernetes pod metadata.uid")
        }
        let sandboxID = proposedSandboxID.trimmed
        guard !sandboxID.isEmpty else {
            throw CRIShimError.invalidArgument("machine-state lease requires a sandbox id")
        }
        let candidate = CRIShimMachineStateLease(
            persistenceID: machineState.persistenceID,
            podUID: normalizedPodUID,
            sandboxID: sandboxID,
            restoreStateID: machineState.restoreStateID,
            restoreStateGeneration: machineState.restoreStateGeneration,
            storageGeneration: storageGeneration,
            admissionState: .reserved,
            sidecarLifecycleBarrier: .init(
                protocolVersion: MacOSSidecarLifecycleBarrierProtocol.current,
                bootNonce: UUID().uuidString.lowercased(),
                launchMayHaveStarted: false
            )
        )
        let leaseData = try encode(candidate)

        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let finalName = "\(machineState.persistenceID).json"
        let temporaryName = ".\(machineState.persistenceID).\(UUID().uuidString.lowercased()).tmp"
        let temporaryFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else {
            throw CRIShimError.internalError("failed to create a machine-state lease candidate")
        }
        defer {
            Darwin.close(temporaryFD)
            _ = unlinkat(directoryFD, temporaryName, 0)
        }

        try writeAll(leaseData, to: temporaryFD)
        guard fsync(temporaryFD) == 0 else {
            throw CRIShimError.internalError("failed to persist a machine-state lease candidate")
        }

        if linkat(directoryFD, temporaryName, directoryFD, finalName, 0) == 0 {
            do {
                guard fsync(directoryFD) == 0 else {
                    throw CRIShimError.internalError("failed to persist the machine-state lease directory")
                }
                try prepareSidecarLifecycleBarrier(
                    policy: policy,
                    lease: candidate,
                    effectiveUserID: effectiveUserID
                )
            } catch {
                _ = unlinkat(directoryFD, finalName, 0)
                _ = fsync(directoryFD)
                throw error
            }
            return .init(lease: candidate, created: true)
        }
        guard errno == EEXIST else {
            throw CRIShimError.internalError("failed to publish a machine-state lease")
        }

        let existing = try readLease(
            named: finalName,
            directoryFD: directoryFD,
            effectiveUserID: effectiveUserID
        )
        guard existing.hasSameOwner(as: candidate) else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(machineState.persistenceID) is fenced by another pod or storage generation"
            )
        }
        return .init(lease: existing, created: false)
    }

    static func markRuntimeCreationStarted(
        policy: MachineStateConfig,
        expected: CRIShimMachineStateLease,
        effectiveUserID: uid_t = geteuid()
    ) throws -> CRIShimMachineStateLease {
        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let leaseName = "\(expected.persistenceID).json"
        let existing = try readLease(
            named: leaseName,
            directoryFD: directoryFD,
            effectiveUserID: effectiveUserID
        )
        guard existing == expected else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) lease owner changed before runtime creation"
            )
        }
        if existing.admissionState == .runtimeCreationStarted {
            return existing
        }
        guard existing.admissionState == .reserved else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) has legacy or unknown admission state"
            )
        }

        var updated = existing
        updated.admissionState = .runtimeCreationStarted
        try replaceLease(
            updated,
            named: leaseName,
            directoryFD: directoryFD
        )
        return updated
    }

    static func markSidecarLaunchMayHaveStarted(
        policy: MachineStateConfig,
        expected: CRIShimMachineStateLease,
        effectiveUserID: uid_t = geteuid()
    ) throws -> CRIShimMachineStateLease {
        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let leaseName = "\(expected.persistenceID).json"
        let existing = try readLease(
            named: leaseName,
            directoryFD: directoryFD,
            effectiveUserID: effectiveUserID
        )
        guard existing == expected else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) lease owner changed before sidecar launch"
            )
        }
        guard existing.admissionState == .runtimeCreationStarted else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) is not eligible for sidecar launch"
            )
        }
        guard var barrier = existing.sidecarLifecycleBarrier else {
            // A pre-upgrade runtime configuration has no lifecycle barrier and
            // remains on the legacy shutdown-ack path.
            return existing
        }
        if barrier.launchMayHaveStarted {
            return existing
        }
        barrier.launchMayHaveStarted = true
        var updated = existing
        updated.sidecarLifecycleBarrier = barrier
        try replaceLease(updated, named: leaseName, directoryFD: directoryFD)
        return updated
    }

    static func markRuntimeDeletionConfirmed(
        policy: MachineStateConfig,
        expected: CRIShimMachineStateLease,
        effectiveUserID: uid_t = geteuid()
    ) throws -> CRIShimMachineStateLease {
        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let leaseName = "\(expected.persistenceID).json"
        let existing = try readLease(
            named: leaseName,
            directoryFD: directoryFD,
            effectiveUserID: effectiveUserID
        )
        guard existing.hasSameLifecycleIncarnation(as: expected) else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) lease owner changed during runtime deletion"
            )
        }
        if existing.admissionState == .runtimeDeletionConfirmed {
            return existing
        }
        guard existing.admissionState == .runtimeCreationStarted || existing.admissionState == nil else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) is not eligible for runtime deletion"
            )
        }
        if existing.sidecarLifecycleBarrier != nil {
            try requireRetiredSidecarLifecycleBarrier(
                policy: policy,
                lease: existing,
                effectiveUserID: effectiveUserID
            )
        }

        var updated = existing
        updated.admissionState = .runtimeDeletionConfirmed
        try replaceLease(
            updated,
            named: leaseName,
            directoryFD: directoryFD
        )
        return updated
    }

    static func acquireAdmissionLock(
        policy: MachineStateConfig,
        persistenceID: String,
        effectiveUserID: uid_t = geteuid()
    ) throws -> CRIShimMachineStateAdmissionLock {
        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let digest = SHA256.hash(data: Data(persistenceID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let name = ".admission-\(digest).lock"
        let fd = openat(
            directoryFD,
            name,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard fd >= 0 else {
            throw CRIShimError.internalError("failed to open the machine-state admission lock")
        }

        var value = stat()
        guard fstat(fd, &value) == 0,
            (value.st_mode & S_IFMT) == S_IFREG,
            value.st_uid == effectiveUserID,
            value.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            Darwin.close(fd)
            throw CRIShimError.internalError("machine-state admission lock has unsafe ownership, type, or permissions")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(fd)
            if lockError == EWOULDBLOCK {
                throw CRIShimError.unavailable(
                    "machine-state persistence id \(persistenceID) has another admission in progress"
                )
            }
            throw CRIShimError.internalError("failed to acquire the machine-state admission lock")
        }
        return CRIShimMachineStateAdmissionLock(descriptor: fd)
    }

    static func list(
        policy: MachineStateConfig,
        effectiveUserID: uid_t = geteuid()
    ) throws -> [CRIShimMachineStateLease] {
        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: policy.normalizedLeaseRoot)
        } catch {
            throw CRIShimError.internalError("failed to list machine-state leases")
        }
        return
            try names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map {
                try readLease(
                    named: $0,
                    directoryFD: directoryFD,
                    effectiveUserID: effectiveUserID
                )
            }
    }

    static func load(
        policy: MachineStateConfig,
        persistenceID: String,
        effectiveUserID: uid_t = geteuid()
    ) throws -> CRIShimMachineStateLease? {
        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        do {
            return try readLease(
                named: "\(persistenceID).json",
                directoryFD: directoryFD,
                effectiveUserID: effectiveUserID
            )
        } catch CRIShimError.notFound {
            return nil
        }
    }

    static func release(
        policy: MachineStateConfig,
        expected: CRIShimMachineStateLease,
        effectiveUserID: uid_t = geteuid()
    ) throws {
        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let leaseName = "\(expected.persistenceID).json"
        let existing: CRIShimMachineStateLease
        do {
            existing = try readLease(
                named: leaseName,
                directoryFD: directoryFD,
                effectiveUserID: effectiveUserID
            )
        } catch CRIShimError.notFound {
            return
        }
        guard existing == expected else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) lease owner changed; refusing release"
            )
        }
        if existing.sidecarLifecycleBarrier != nil {
            if existing.admissionState == .reserved {
                try retirePreparedSidecarLifecycleBarrier(
                    policy: policy,
                    lease: existing,
                    effectiveUserID: effectiveUserID
                )
            } else {
                try requireRetiredSidecarLifecycleBarrier(
                    policy: policy,
                    lease: existing,
                    effectiveUserID: effectiveUserID
                )
            }
        }
        guard unlinkat(directoryFD, leaseName, 0) == 0 else {
            if errno == ENOENT { return }
            throw CRIShimError.internalError("failed to release a machine-state lease")
        }
        guard fsync(directoryFD) == 0 else {
            throw CRIShimError.internalError("failed to persist machine-state lease release")
        }
    }

    static func requireActive(
        policy: MachineStateConfig,
        expected: CRIShimMachineStateLease,
        effectiveUserID: uid_t = geteuid()
    ) throws {
        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let existing: CRIShimMachineStateLease
        do {
            existing = try readLease(
                named: "\(expected.persistenceID).json",
                directoryFD: directoryFD,
                effectiveUserID: effectiveUserID
            )
        } catch CRIShimError.notFound {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) has no active lease; refusing VM start"
            )
        }
        guard existing.hasSameBinding(as: expected) else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) is not leased to this sandbox; refusing VM start"
            )
        }
    }

    static func hasActiveBinding(
        policy: MachineStateConfig,
        expected: CRIShimMachineStateLease,
        effectiveUserID: uid_t = geteuid()
    ) throws -> Bool {
        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let existing: CRIShimMachineStateLease
        do {
            existing = try readLease(
                named: "\(expected.persistenceID).json",
                directoryFD: directoryFD,
                effectiveUserID: effectiveUserID
            )
        } catch CRIShimError.notFound {
            return false
        }
        guard existing.hasSameBinding(as: expected) else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) is leased to another sandbox"
            )
        }
        return true
    }

    private static func openLeaseDirectory(
        policy: MachineStateConfig,
        effectiveUserID: uid_t
    ) throws -> Int32 {
        guard let normalized = criLexicallyNormalizedAbsolutePath(policy.normalizedLeaseRoot),
            normalized == policy.normalizedLeaseRoot,
            normalized != "/"
        else {
            throw CRIShimError.invalidArgument("machineState.leaseRoot must be a normalized absolute directory")
        }
        let fd = open(normalized, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw CRIShimError.internalError("machine-state lease directory is unavailable")
        }
        var value = stat()
        guard fstat(fd, &value) == 0,
            (value.st_mode & S_IFMT) == S_IFDIR,
            value.st_uid == effectiveUserID,
            value.st_mode & mode_t(0o077) == 0
        else {
            Darwin.close(fd)
            throw CRIShimError.invalidArgument("machine-state lease directory has unsafe ownership or permissions")
        }
        return fd
    }

    private static func readLease(
        named name: String,
        directoryFD: Int32,
        effectiveUserID: uid_t
    ) throws -> CRIShimMachineStateLease {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT {
                throw CRIShimError.notFound("machine-state lease does not exist")
            }
            throw CRIShimError.internalError("failed to open a machine-state lease")
        }
        defer { Darwin.close(fd) }

        var value = stat()
        guard fstat(fd, &value) == 0,
            (value.st_mode & S_IFMT) == S_IFREG,
            value.st_uid == effectiveUserID,
            value.st_mode & mode_t(0o777) == mode_t(0o600),
            value.st_size > 0,
            value.st_size <= maximumLeaseBytes
        else {
            throw CRIShimError.internalError("machine-state lease has unsafe ownership, type, permissions, or size")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        let lease: CRIShimMachineStateLease
        do {
            lease = try JSONDecoder().decode(CRIShimMachineStateLease.self, from: data)
        } catch {
            throw CRIShimError.internalError("machine-state lease is corrupted")
        }
        let hasValidLifecycleBarrier: Bool
        switch (lease.schemaVersion, lease.sidecarLifecycleBarrier) {
        case (1, nil):
            hasValidLifecycleBarrier = true
        case (2, let barrier?):
            hasValidLifecycleBarrier =
                barrier.protocolVersion == MacOSSidecarLifecycleBarrierProtocol.current
                && UUID(uuidString: barrier.bootNonce)?.uuidString.lowercased() == barrier.bootNonce
        default:
            hasValidLifecycleBarrier = false
        }
        guard hasValidLifecycleBarrier,
            "\(lease.persistenceID).json" == name,
            !lease.podUID.trimmed.isEmpty,
            !lease.sandboxID.trimmed.isEmpty,
            lease.storageGeneration > 0,
            (lease.restoreStateID == nil) == (lease.restoreStateGeneration == nil),
            lease.restoreStateGeneration.map({ $0 > 0 && lease.storageGeneration > $0 }) ?? true
        else {
            throw CRIShimError.internalError("machine-state lease is corrupted")
        }
        return lease
    }

    private static func prepareSidecarLifecycleBarrier(
        policy: MachineStateConfig,
        lease: CRIShimMachineStateLease,
        effectiveUserID: uid_t
    ) throws {
        guard let barrier = lease.sidecarLifecycleBarrier else {
            throw CRIShimError.internalError("new machine-state lease is missing its sidecar lifecycle barrier")
        }
        try withLockedSidecarLifecycleFile(
            policy: policy,
            persistenceID: lease.persistenceID,
            effectiveUserID: effectiveUserID,
            createIfMissing: true
        ) { directoryFD, lockValue, ownerUID, lockWasCreated in
            do {
                let existing = try MacOSSidecarLifecycleLock.readAttestation(
                    directoryFD: directoryFD,
                    expectedOwnerUID: ownerUID
                )
                guard existing.state == .retired,
                    existing.lockDevice == UInt64(lockValue.st_dev),
                    existing.lockInode == UInt64(lockValue.st_ino)
                else {
                    throw CRIShimError.unavailable(
                        "machine-state persistence id \(lease.persistenceID) has an unretired sidecar lifecycle binding"
                    )
                }
            } catch let error as POSIXError where error.code == .ENOENT {
                guard lockWasCreated else {
                    throw CRIShimError.unavailable(
                        "machine-state persistence id \(lease.persistenceID) has an unattested lifecycle lock"
                    )
                }
            } catch let error as CRIShimError {
                throw error
            } catch {
                throw CRIShimError.unavailable(
                    "machine-state persistence id \(lease.persistenceID) has an unreadable sidecar lifecycle binding"
                )
            }
            let prepared = MacOSSidecarLifecycleAttestation(
                protocolVersion: barrier.protocolVersion,
                persistenceID: lease.persistenceID,
                sandboxID: lease.sandboxID,
                bootNonce: barrier.bootNonce,
                processID: 0,
                lockDevice: UInt64(lockValue.st_dev),
                lockInode: UInt64(lockValue.st_ino),
                state: .prepared
            )
            do {
                try MacOSSidecarLifecycleLock.persistAttestation(
                    prepared,
                    directoryFD: directoryFD,
                    ownerUID: ownerUID
                )
            } catch {
                throw CRIShimError.internalError("failed to persist the sidecar lifecycle barrier")
            }
        }
    }

    private static func retirePreparedSidecarLifecycleBarrier(
        policy: MachineStateConfig,
        lease: CRIShimMachineStateLease,
        effectiveUserID: uid_t
    ) throws {
        guard let barrier = lease.sidecarLifecycleBarrier else { return }
        guard lease.admissionState == .reserved, !barrier.launchMayHaveStarted else {
            throw CRIShimError.unavailable(
                "only an unlaunched reserved sidecar lifecycle barrier can be retired without runtime cleanup"
            )
        }
        try withLockedSidecarLifecycleFile(
            policy: policy,
            persistenceID: lease.persistenceID,
            effectiveUserID: effectiveUserID,
            createIfMissing: true
        ) { directoryFD, lockValue, ownerUID, _ in
            let existing: MacOSSidecarLifecycleAttestation?
            do {
                existing = try MacOSSidecarLifecycleLock.readAttestation(
                    directoryFD: directoryFD,
                    expectedOwnerUID: ownerUID
                )
            } catch let error as POSIXError where error.code == .ENOENT {
                // The lease is durable before its barrier is prepared. A crash
                // in that narrow window can leave no attestation (and possibly
                // no lock). The reserved state plus the durable false launch
                // marker proves that this lifecycle was never handed to the
                // runtime, so publish a retired tombstone before releasing it.
                existing = nil
            } catch {
                throw CRIShimError.unavailable("sidecar lifecycle barrier is unavailable during lease release")
            }
            if let existing {
                guard existing.protocolVersion == barrier.protocolVersion,
                    existing.persistenceID == lease.persistenceID,
                    existing.sandboxID == lease.sandboxID,
                    existing.bootNonce == barrier.bootNonce,
                    existing.lockDevice == UInt64(lockValue.st_dev),
                    existing.lockInode == UInt64(lockValue.st_ino),
                    existing.state == .prepared || existing.state == .retired
                else {
                    throw CRIShimError.unavailable("sidecar lifecycle barrier changed during lease release")
                }
                if existing.state == .retired {
                    return
                }
            }
            let retired = MacOSSidecarLifecycleAttestation(
                protocolVersion: barrier.protocolVersion,
                persistenceID: lease.persistenceID,
                sandboxID: lease.sandboxID,
                bootNonce: barrier.bootNonce,
                processID: 0,
                lockDevice: UInt64(lockValue.st_dev),
                lockInode: UInt64(lockValue.st_ino),
                state: .retired
            )
            do {
                try MacOSSidecarLifecycleLock.persistAttestation(
                    retired,
                    directoryFD: directoryFD,
                    ownerUID: ownerUID
                )
            } catch {
                throw CRIShimError.internalError("failed to retire the sidecar lifecycle barrier")
            }
            let readback: MacOSSidecarLifecycleAttestation
            do {
                readback = try MacOSSidecarLifecycleLock.readAttestation(
                    directoryFD: directoryFD,
                    expectedOwnerUID: ownerUID
                )
            } catch {
                throw CRIShimError.unavailable("retired sidecar lifecycle barrier could not be read back")
            }
            guard readback == retired else {
                throw CRIShimError.unavailable("sidecar lifecycle barrier retirement was not durable")
            }
        }
    }

    private static func requireRetiredSidecarLifecycleBarrier(
        policy: MachineStateConfig,
        lease: CRIShimMachineStateLease,
        effectiveUserID: uid_t
    ) throws {
        guard let barrier = lease.sidecarLifecycleBarrier else { return }
        let ownerUID = uid_t(policy.runtimeOwnerUID ?? UInt32(effectiveUserID))
        let storageDirectory = URL(
            fileURLWithPath: policy.normalizedStorageRoot,
            isDirectory: true
        ).appendingPathComponent(lease.persistenceID, isDirectory: true)
        let directoryFD = open(storageDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw CRIShimError.unavailable("sidecar lifecycle storage directory is unavailable")
        }
        defer { Darwin.close(directoryFD) }
        let lockFD = openat(
            directoryFD,
            MacOSSidecarLifecycleBarrierProtocol.lockFileName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard lockFD >= 0 else {
            throw CRIShimError.unavailable("sidecar lifecycle lock is unavailable")
        }
        defer { Darwin.close(lockFD) }
        var lockValue = stat()
        guard fstat(lockFD, &lockValue) == 0,
            (lockValue.st_mode & S_IFMT) == S_IFREG,
            lockValue.st_uid == ownerUID,
            lockValue.st_mode & mode_t(0o777) == mode_t(0o600),
            lockValue.st_nlink == 1
        else {
            throw CRIShimError.unavailable("sidecar lifecycle lock is unsafe during lease release")
        }
        let attestation: MacOSSidecarLifecycleAttestation
        do {
            attestation = try MacOSSidecarLifecycleLock.readAttestation(
                directoryFD: directoryFD,
                expectedOwnerUID: ownerUID
            )
        } catch {
            throw CRIShimError.unavailable("retired sidecar lifecycle barrier is unavailable")
        }
        guard attestation.protocolVersion == barrier.protocolVersion,
            attestation.persistenceID == lease.persistenceID,
            attestation.sandboxID == lease.sandboxID,
            attestation.bootNonce == barrier.bootNonce,
            attestation.lockDevice == UInt64(lockValue.st_dev),
            attestation.lockInode == UInt64(lockValue.st_ino),
            attestation.state == .retired
        else {
            throw CRIShimError.unavailable("sidecar lifecycle barrier is not retired for this lease")
        }
    }

    private static func withLockedSidecarLifecycleFile<Result>(
        policy: MachineStateConfig,
        persistenceID: String,
        effectiveUserID: uid_t,
        createIfMissing: Bool,
        _ body: (Int32, stat, uid_t, Bool) throws -> Result
    ) throws -> Result {
        let ownerUID = uid_t(policy.runtimeOwnerUID ?? UInt32(effectiveUserID))
        let storageDirectory = URL(
            fileURLWithPath: policy.normalizedStorageRoot,
            isDirectory: true
        ).appendingPathComponent(persistenceID, isDirectory: true)
        let directoryFD = open(storageDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw CRIShimError.internalError("machine-state storage directory is unavailable")
        }
        defer { Darwin.close(directoryFD) }
        var directoryValue = stat()
        guard fstat(directoryFD, &directoryValue) == 0,
            (directoryValue.st_mode & S_IFMT) == S_IFDIR,
            directoryValue.st_uid == ownerUID,
            directoryValue.st_mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw CRIShimError.internalError("machine-state storage directory has unsafe ownership or permissions")
        }

        let lockFD: Int32
        let lockWasCreated: Bool
        if createIfMissing {
            let createdFD = openat(
                directoryFD,
                MacOSSidecarLifecycleBarrierProtocol.lockFileName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            if createdFD >= 0 {
                lockFD = createdFD
                lockWasCreated = true
            } else if errno == EEXIST {
                lockFD = openat(
                    directoryFD,
                    MacOSSidecarLifecycleBarrierProtocol.lockFileName,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC
                )
                lockWasCreated = false
            } else {
                lockFD = -1
                lockWasCreated = false
            }
        } else {
            lockFD = openat(
                directoryFD,
                MacOSSidecarLifecycleBarrierProtocol.lockFileName,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            )
            lockWasCreated = false
        }
        guard lockFD >= 0 else {
            throw CRIShimError.internalError("sidecar lifecycle lock is unavailable")
        }
        defer {
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw CRIShimError.unavailable("machine-state sidecar lifecycle lock is still held")
        }
        var lockValue = stat()
        guard fstat(lockFD, &lockValue) == 0,
            (lockValue.st_mode & S_IFMT) == S_IFREG,
            lockValue.st_nlink == 1,
            effectiveUserID == ownerUID || effectiveUserID == 0
        else {
            throw CRIShimError.internalError("sidecar lifecycle lock has unsafe ownership or type")
        }
        if lockValue.st_uid != ownerUID {
            guard effectiveUserID == 0, lockValue.st_uid == effectiveUserID,
                fchown(lockFD, ownerUID, gid_t.max) == 0
            else {
                throw CRIShimError.internalError("sidecar lifecycle lock has an unexpected owner")
            }
        }
        guard fchmod(lockFD, mode_t(0o600)) == 0,
            fstat(lockFD, &lockValue) == 0,
            lockValue.st_uid == ownerUID,
            lockValue.st_mode & mode_t(0o777) == mode_t(0o600),
            lockValue.st_nlink == 1
        else {
            throw CRIShimError.internalError("failed to secure the sidecar lifecycle lock")
        }
        return try body(directoryFD, lockValue, ownerUID, lockWasCreated)
    }

    private static func encode(_ lease: CRIShimMachineStateLease) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(lease)
        guard !data.isEmpty, data.count <= maximumLeaseBytes else {
            throw CRIShimError.internalError("machine-state lease exceeds its size limit")
        }
        return data
    }

    private static func replaceLease(
        _ lease: CRIShimMachineStateLease,
        named finalName: String,
        directoryFD: Int32
    ) throws {
        let data = try encode(lease)
        let temporaryName = ".\(lease.persistenceID).\(UUID().uuidString.lowercased()).tmp"
        let temporaryFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else {
            throw CRIShimError.internalError("failed to create a machine-state lease update")
        }
        defer {
            Darwin.close(temporaryFD)
            _ = unlinkat(directoryFD, temporaryName, 0)
        }
        try writeAll(data, to: temporaryFD)
        guard fsync(temporaryFD) == 0 else {
            throw CRIShimError.internalError("failed to persist a machine-state lease update")
        }
        guard renameat(directoryFD, temporaryName, directoryFD, finalName) == 0 else {
            throw CRIShimError.internalError("failed to publish a machine-state lease update")
        }
        guard fsync(directoryFD) == 0 else {
            throw CRIShimError.internalError("failed to persist the machine-state lease update")
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), rawBuffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CRIShimError.internalError("failed to write a machine-state lease")
                }
                written += count
            }
        }
    }
}
