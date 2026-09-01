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
import Darwin
import Foundation

struct CRIShimMachineStateLease: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var persistenceID: String
    var podUID: String
    var sandboxID: String
    var restoreStateID: String?
    var restoreStateGeneration: UInt64?
    var storageGeneration: UInt64

    func hasSameOwner(as candidate: Self) -> Bool {
        persistenceID == candidate.persistenceID
            && podUID == candidate.podUID
            && restoreStateID == candidate.restoreStateID
            && restoreStateGeneration == candidate.restoreStateGeneration
            && storageGeneration == candidate.storageGeneration
    }
}

struct CRIShimMachineStateLeaseAcquisition: Equatable, Sendable {
    var lease: CRIShimMachineStateLease
    var created: Bool
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
            storageGeneration: storageGeneration
        )
        let leaseData = try encode(candidate)

        let directoryFD = try openLeaseDirectory(policy: policy, effectiveUserID: effectiveUserID)
        defer { Darwin.close(directoryFD) }
        let finalName = "\(machineState.persistenceID).json"
        let temporaryName = ".\(machineState.persistenceID).\(UUID().uuidString.lowercased()).tmp"
        let temporaryFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
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
            guard fsync(directoryFD) == 0 else {
                throw CRIShimError.internalError("failed to persist the machine-state lease directory")
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
        guard existing == expected else {
            throw CRIShimError.unavailable(
                "machine-state persistence id \(expected.persistenceID) is not leased to this sandbox; refusing VM start"
            )
        }
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
        let fd = open(normalized, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
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
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
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
        guard lease.schemaVersion == 1,
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

    private static func encode(_ lease: CRIShimMachineStateLease) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(lease)
        guard !data.isEmpty, data.count <= maximumLeaseBytes else {
            throw CRIShimError.internalError("machine-state lease exceeds its size limit")
        }
        return data
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
