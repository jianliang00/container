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

struct CRIShimMachineStateRuntimeCleanupConfirmation {
    let lease: CRIShimMachineStateLease
    fileprivate let proof: CRIShimMachineStateSidecarExitProof
}

final class CRIShimMachineStateSidecarExitProof: @unchecked Sendable {
    fileprivate let lifecycleLock: CRIShimMachineStateSidecarLifecycleLock?

    fileprivate init(lifecycleLock: CRIShimMachineStateSidecarLifecycleLock? = nil) {
        self.lifecycleLock = lifecycleLock
    }
}

struct CRIShimMachineStateRuntimeCleanupPreparation {
    fileprivate enum Strategy {
        case lifecycleLock(CRIShimMachineStateSidecarLifecycleLock)
        case legacyShutdownAcknowledgedWithoutExitProof
    }

    fileprivate let strategy: Strategy
}

struct CRIShimMachineStateRuntimeCleaner {
    let runtimeManager: any CRIShimRuntimeManaging

    func cleanup(
        lease: CRIShimMachineStateLease,
        policy: MachineStateConfig,
        preparation: CRIShimMachineStateRuntimeCleanupPreparation? = nil
    ) async throws -> CRIShimMachineStateRuntimeCleanupConfirmation {
        let proof = try await cleanupRuntime(
            binding: lease,
            policy: policy,
            preparation: preparation
        )
        let confirmedLease = try CRIShimMachineStateLeaseStore.markRuntimeDeletionConfirmed(
            policy: policy,
            expected: lease
        )
        return CRIShimMachineStateRuntimeCleanupConfirmation(
            lease: confirmedLease,
            proof: proof
        )
    }

    func prepare(
        binding: CRIShimMachineStateLease,
        policy: MachineStateConfig
    ) async throws -> CRIShimMachineStateRuntimeCleanupPreparation {
        let ownerUID = uid_t(policy.runtimeOwnerUID ?? UInt32(geteuid()))
        if let barrier = binding.sidecarLifecycleBarrier {
            let lifecycleLock = try CRIShimMachineStateSidecarLifecycleLock(
                binding: binding,
                barrier: barrier,
                policy: policy,
                expectedOwnerUID: ownerUID
            )
            return .init(strategy: .lifecycleLock(lifecycleLock))
        }

        let controlSocket = controlSocketPath(policy: policy, persistenceID: binding.persistenceID)
        try requireSafeControlSocket(
            controlSocket,
            policy: policy,
            persistenceID: binding.persistenceID,
            expectedOwnerUID: UInt32(ownerUID)
        )
        try await runtimeManager.stopAndQuitMachineStateSidecar(controlSocketPath: controlSocket)
        return .init(strategy: .legacyShutdownAcknowledgedWithoutExitProof)
    }

    @discardableResult
    func cleanupRuntime(
        binding: CRIShimMachineStateLease,
        policy: MachineStateConfig,
        preparation requestedPreparation: CRIShimMachineStateRuntimeCleanupPreparation? = nil
    ) async throws -> CRIShimMachineStateSidecarExitProof {
        let preparation: CRIShimMachineStateRuntimeCleanupPreparation
        if let requestedPreparation {
            preparation = requestedPreparation
        } else {
            preparation = try await prepare(binding: binding, policy: policy)
        }
        do {
            try await runtimeManager.removeSandbox(id: binding.sandboxID, force: true)
        } catch {
            guard CRIShimErrorMapper.disposition(for: error).kind == .notFound else {
                throw error
            }
        }
        try await runtimeManager.removeSandboxRuntimeService(id: binding.sandboxID)

        let ownerUID = policy.runtimeOwnerUID ?? UInt32(geteuid())
        try await runtimeManager.removeMachineStateSidecar(
            sandboxID: binding.sandboxID,
            persistenceID: binding.persistenceID,
            effectiveUserID: ownerUID
        )
        let controlSocket = controlSocketPath(policy: policy, persistenceID: binding.persistenceID)
        try removeStaleControlSocket(
            controlSocket,
            policy: policy,
            persistenceID: binding.persistenceID,
            expectedOwnerUID: ownerUID
        )
        try await runtimeManager.confirmSandboxRuntimeRemoved(
            id: binding.sandboxID,
            machineStatePersistenceID: binding.persistenceID,
            machineStateOwnerUID: ownerUID
        )
        try requireControlSocketAbsent(controlSocket)

        switch preparation.strategy {
        case .lifecycleLock(let lifecycleLock):
            try lifecycleLock.retireAndAcquireExitProof()
            return CRIShimMachineStateSidecarExitProof(lifecycleLock: lifecycleLock)
        case .legacyShutdownAcknowledgedWithoutExitProof:
            // The ACK proves VM stop completion but cannot attest that an old
            // process exited or prevent a delayed relaunch. Keep the durable
            // lease even after best-effort runtime removal is confirmed.
            throw CRIShimError.unavailable(
                "legacy machine-state sidecar has no trusted process-exit proof; lease retained for manual repair"
            )
        }
    }

    private func controlSocketPath(policy: MachineStateConfig, persistenceID: String) -> String {
        URL(
            fileURLWithPath: policy.normalizedControlSocketRoot,
            isDirectory: true
        ).appendingPathComponent("\(persistenceID).sock", isDirectory: false).path
    }

    private func requireSafeControlSocket(
        _ path: String,
        policy: MachineStateConfig,
        persistenceID: String,
        expectedOwnerUID: UInt32
    ) throws {
        _ = try requireSafeIdentifier(
            persistenceID,
            annotation: CRIShimMachineStateAnnotation.persistenceID,
            maximumLength: 64
        )
        let expected = controlSocketPath(policy: policy, persistenceID: persistenceID)
        guard path == expected else {
            throw CRIShimError.invalidArgument("machine-state control socket does not match its managed binding")
        }
        var value = stat()
        guard lstat(path, &value) == 0 else {
            throw CRIShimError.unavailable("legacy machine-state sidecar control socket is unavailable")
        }
        guard (value.st_mode & S_IFMT) == S_IFSOCK,
            value.st_uid == uid_t(expectedOwnerUID),
            value.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            throw CRIShimError.unavailable(
                "legacy machine-state sidecar control socket has unsafe ownership, type, or permissions"
            )
        }
    }

    private func removeStaleControlSocket(
        _ path: String,
        policy: MachineStateConfig,
        persistenceID: String,
        expectedOwnerUID: UInt32
    ) throws {
        _ = try requireSafeIdentifier(
            persistenceID,
            annotation: CRIShimMachineStateAnnotation.persistenceID,
            maximumLength: 64
        )
        let root = URL(
            fileURLWithPath: policy.normalizedControlSocketRoot,
            isDirectory: true
        )
        let expected = root.appendingPathComponent("\(persistenceID).sock", isDirectory: false)
        guard path == expected.path else {
            throw CRIShimError.invalidArgument("machine-state control socket does not match its managed binding")
        }

        let directoryFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw CRIShimError.internalError("failed to open the machine-state control socket directory")
        }
        defer { Darwin.close(directoryFD) }

        var directoryValue = stat()
        guard fstat(directoryFD, &directoryValue) == 0,
            (directoryValue.st_mode & S_IFMT) == S_IFDIR,
            directoryValue.st_uid == uid_t(expectedOwnerUID),
            directoryValue.st_mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw CRIShimError.internalError(
                "machine-state control socket directory has unsafe ownership, type, or permissions"
            )
        }

        let socketName = "\(persistenceID).sock"
        var socketValue = stat()
        guard fstatat(directoryFD, socketName, &socketValue, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return
            }
            throw CRIShimError.internalError("failed to inspect the machine-state control socket")
        }
        guard (socketValue.st_mode & S_IFMT) == S_IFSOCK,
            socketValue.st_uid == uid_t(expectedOwnerUID),
            socketValue.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            throw CRIShimError.unavailable(
                "refusing to remove a machine-state control path with unexpected ownership, type, or permissions"
            )
        }
        try requireInactiveControlSocket(path)

        var currentSocketValue = stat()
        guard fstatat(directoryFD, socketName, &currentSocketValue, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return
            }
            throw CRIShimError.internalError("failed to revalidate the machine-state control socket")
        }
        guard currentSocketValue.st_dev == socketValue.st_dev,
            currentSocketValue.st_ino == socketValue.st_ino,
            (currentSocketValue.st_mode & S_IFMT) == S_IFSOCK,
            currentSocketValue.st_uid == uid_t(expectedOwnerUID)
        else {
            throw CRIShimError.unavailable("machine-state control socket changed during verified cleanup")
        }
        guard unlinkat(directoryFD, socketName, 0) == 0 else {
            throw CRIShimError.internalError("failed to remove the stale machine-state control socket")
        }
        guard fsync(directoryFD) == 0 else {
            throw CRIShimError.internalError("failed to persist machine-state control socket removal")
        }
    }

    private func requireInactiveControlSocket(_ path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CRIShimError.internalError("failed to create the machine-state control socket probe")
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw CRIShimError.invalidArgument("machine-state control socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, length)
            }
        }
        if result == 0 {
            throw CRIShimError.unavailable(
                "machine-state control socket is still accepting connections after sidecar deletion"
            )
        }
        guard errno == ECONNREFUSED || errno == ENOENT else {
            throw CRIShimError.internalError(
                "failed to verify that the machine-state control socket is inactive"
            )
        }
    }

    private func requireControlSocketAbsent(_ path: String) throws {
        var value = stat()
        if lstat(path, &value) == 0 {
            throw CRIShimError.unavailable("machine-state control socket is still present")
        }
        guard errno == ENOENT else {
            throw CRIShimError.internalError("failed to verify machine-state control socket removal")
        }
    }
}

final class CRIShimMachineStateSidecarLifecycleLock: @unchecked Sendable {
    let initialState: MacOSSidecarLifecycleAttestationState

    private let binding: CRIShimMachineStateLease
    private let barrier: CRIShimMachineStateLease.SidecarLifecycleBarrier
    private let ownerUID: uid_t
    private let directoryFD: Int32
    private var lockFD: Int32
    private let lockDevice: UInt64
    private let lockInode: UInt64
    private var holdsExclusiveLock = false

    init(
        binding: CRIShimMachineStateLease,
        barrier: CRIShimMachineStateLease.SidecarLifecycleBarrier,
        policy: MachineStateConfig,
        expectedOwnerUID: uid_t
    ) throws {
        let storageDirectory = URL(
            fileURLWithPath: policy.normalizedStorageRoot,
            isDirectory: true
        ).appendingPathComponent(binding.persistenceID, isDirectory: true)
        let openedDirectoryFD = open(
            storageDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard openedDirectoryFD >= 0 else {
            throw CRIShimError.unavailable("sidecar lifecycle storage directory is unavailable")
        }
        var retainedDirectory = false
        defer {
            if !retainedDirectory {
                Darwin.close(openedDirectoryFD)
            }
        }

        var directoryValue = stat()
        guard fstat(openedDirectoryFD, &directoryValue) == 0,
            (directoryValue.st_mode & S_IFMT) == S_IFDIR,
            directoryValue.st_uid == expectedOwnerUID,
            directoryValue.st_mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw CRIShimError.unavailable(
                "sidecar lifecycle storage directory has unsafe ownership, type, or permissions"
            )
        }

        let openedLockFD = openat(
            openedDirectoryFD,
            MacOSSidecarLifecycleBarrierProtocol.lockFileName,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard openedLockFD >= 0 else {
            throw CRIShimError.unavailable("sidecar lifecycle lock is unavailable")
        }
        var retainedLock = false
        defer {
            if !retainedLock {
                Darwin.close(openedLockFD)
            }
        }

        var lockValue = stat()
        guard fstat(openedLockFD, &lockValue) == 0,
            (lockValue.st_mode & S_IFMT) == S_IFREG,
            lockValue.st_uid == expectedOwnerUID,
            lockValue.st_mode & mode_t(0o777) == mode_t(0o600),
            lockValue.st_nlink == 1
        else {
            throw CRIShimError.unavailable(
                "sidecar lifecycle lock has unsafe ownership, type, links, or permissions"
            )
        }

        let attestation: MacOSSidecarLifecycleAttestation
        do {
            attestation = try MacOSSidecarLifecycleLock.readAttestation(
                directoryFD: openedDirectoryFD,
                expectedOwnerUID: expectedOwnerUID
            )
        } catch {
            throw CRIShimError.unavailable("sidecar lifecycle attestation is unavailable or invalid")
        }
        guard attestation.protocolVersion == barrier.protocolVersion,
            attestation.persistenceID == binding.persistenceID,
            attestation.sandboxID == binding.sandboxID,
            attestation.bootNonce == barrier.bootNonce,
            attestation.lockDevice == UInt64(lockValue.st_dev),
            attestation.lockInode == UInt64(lockValue.st_ino)
        else {
            throw CRIShimError.unavailable("sidecar lifecycle attestation does not match the leased binding")
        }

        self.initialState = attestation.state
        self.binding = binding
        self.barrier = barrier
        self.ownerUID = expectedOwnerUID
        self.directoryFD = openedDirectoryFD
        self.lockFD = openedLockFD
        self.lockDevice = UInt64(lockValue.st_dev)
        self.lockInode = UInt64(lockValue.st_ino)
        retainedDirectory = true
        retainedLock = true
    }

    deinit {
        if lockFD >= 0 {
            if holdsExclusiveLock {
                _ = flock(lockFD, LOCK_UN)
            }
            Darwin.close(lockFD)
            lockFD = -1
        }
        Darwin.close(directoryFD)
    }

    func retireAndAcquireExitProof() throws {
        guard !holdsExclusiveLock else { return }
        try requireStableLockPath()
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK {
                throw CRIShimError.unavailable(
                    "machine-state sidecar process still holds its lifecycle lock"
                )
            }
            throw CRIShimError.internalError("failed to acquire the sidecar lifecycle exit proof")
        }
        holdsExclusiveLock = true
        try requireStableLockPath()

        let current: MacOSSidecarLifecycleAttestation
        do {
            current = try MacOSSidecarLifecycleLock.readAttestation(
                directoryFD: directoryFD,
                expectedOwnerUID: ownerUID
            )
        } catch {
            throw CRIShimError.unavailable("sidecar lifecycle attestation disappeared during cleanup")
        }
        try requireMatchingAttestation(current)
        guard stateRank(current.state) >= stateRank(initialState) else {
            throw CRIShimError.unavailable("sidecar lifecycle attestation regressed during cleanup")
        }

        if current.state != .retired {
            var retired = current
            retired.state = .retired
            do {
                try MacOSSidecarLifecycleLock.persistAttestation(
                    retired,
                    directoryFD: directoryFD,
                    ownerUID: ownerUID
                )
            } catch {
                throw CRIShimError.internalError("failed to persist the retired sidecar lifecycle barrier")
            }
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
        try requireMatchingAttestation(readback)
        guard readback.state == .retired else {
            throw CRIShimError.unavailable("sidecar lifecycle barrier retirement was not durable")
        }
    }

    private func requireStableLockPath() throws {
        var value = stat()
        guard
            fstatat(
                directoryFD,
                MacOSSidecarLifecycleBarrierProtocol.lockFileName,
                &value,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            (value.st_mode & S_IFMT) == S_IFREG,
            value.st_uid == ownerUID,
            value.st_mode & mode_t(0o777) == mode_t(0o600),
            value.st_nlink == 1,
            UInt64(value.st_dev) == lockDevice,
            UInt64(value.st_ino) == lockInode
        else {
            throw CRIShimError.unavailable("sidecar lifecycle lock path changed during cleanup")
        }
    }

    private func requireMatchingAttestation(
        _ attestation: MacOSSidecarLifecycleAttestation
    ) throws {
        guard attestation.protocolVersion == barrier.protocolVersion,
            attestation.persistenceID == binding.persistenceID,
            attestation.sandboxID == binding.sandboxID,
            attestation.bootNonce == barrier.bootNonce,
            attestation.lockDevice == lockDevice,
            attestation.lockInode == lockInode
        else {
            throw CRIShimError.unavailable("sidecar lifecycle binding changed during cleanup")
        }
    }

    private func stateRank(_ state: MacOSSidecarLifecycleAttestationState) -> Int {
        switch state {
        case .prepared: 0
        case .active: 1
        case .retired: 2
        }
    }
}
