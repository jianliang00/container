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

import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Unprivileged runtimes can submit this bounded request, but only the root
/// coordinator mutates the authoritative recovery state and reboot budget.
public struct VMNetRecoveryRequestV1: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var networkName: String
    public var networkInstanceID: String?
    public var failureReason: String
    public var observedAt: Date
    public var bootSessionID: String

    public init(
        networkName: String,
        networkInstanceID: String?,
        failureReason: String,
        observedAt: Date,
        bootSessionID: String,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.networkName = networkName
        self.networkInstanceID = networkInstanceID
        self.failureReason = failureReason
        self.observedAt = observedAt
        self.bootSessionID = bootSessionID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case networkName
        case networkInstanceID
        case failureReason
        case observedAt
        case bootSessionID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported vmnet recovery request schema version \(schemaVersion)"
            )
        }
        networkName = try container.decode(String.self, forKey: .networkName)
        networkInstanceID = try container.decodeIfPresent(String.self, forKey: .networkInstanceID)
        failureReason = try container.decode(String.self, forKey: .failureReason)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        bootSessionID = try container.decode(String.self, forKey: .bootSessionID)
    }
}

public struct VMNetRecoveryRequestStore: Sendable {
    public let requestURL: URL

    public init(path: String) {
        self.init(requestURL: URL(fileURLWithPath: path))
    }

    public init(requestURL: URL) {
        self.requestURL = requestURL
    }

    public func hasPendingRequest() throws -> Bool {
        var information = stat()
        if lstat(requestURL.path, &information) == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw VMNetRecoveryStateError.io("failed to inspect vmnet recovery request: errno \(errno)")
    }

    public func requireNoPendingRequest(networkName: String) throws {
        guard try !hasPendingRequest() else {
            throw VMNetRecoveryStateError.admissionFenced(networkName: networkName, phase: .fenced)
        }
    }

    /// Creates the fixed request sentinel exactly once. A partial file is left
    /// in place on write failure so admission remains fail-closed.
    @discardableResult
    public func submit(
        networkName: String,
        networkInstanceID: String?,
        failureReason: String,
        bootSessionID: String,
        now: Date = Date()
    ) throws -> Bool {
        let network = networkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = failureReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let boot = bootSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !network.isEmpty else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery request network name is required")
        }
        guard !reason.isEmpty else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery request failure reason is required")
        }
        guard !boot.isEmpty else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery request boot session id is required")
        }

        let request = VMNetRecoveryRequestV1(
            networkName: network,
            networkInstanceID: normalized(networkInstanceID),
            failureReason: reason,
            observedAt: now,
            bootSessionID: boot
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(request)
        guard data.count <= 16 * 1024 else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery request exceeds the size limit")
        }

        let descriptor = open(
            requestURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                return false
            }
            throw VMNetRecoveryStateError.io("failed to create vmnet recovery request: errno \(errno)")
        }
        defer { close(descriptor) }

        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw VMNetRecoveryStateError.io("failed to sync vmnet recovery request: errno \(errno)")
        }
        return true
    }

    public func load(expectedWriterUID: Int) throws -> VMNetRecoveryRequestV1? {
        guard let expectedUID = uid_t(exactly: expectedWriterUID) else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery request writer uid is invalid")
        }
        let descriptor = open(requestURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw VMNetRecoveryStateError.io("failed to open vmnet recovery request: errno \(errno)")
        }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw VMNetRecoveryStateError.io("failed to inspect vmnet recovery request: errno \(errno)")
        }
        guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery request must be a regular file")
        }
        guard information.st_uid == expectedUID else {
            throw VMNetRecoveryStateError.requestWriterMismatch(
                expected: UInt32(expectedUID),
                actual: UInt32(information.st_uid)
            )
        }
        guard information.st_mode & mode_t(0o022) == 0 else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery request must not be group or world writable")
        }

        let data = try readVMNetRecoveryRegularFile(
            descriptor: descriptor,
            maximumSize: 16 * 1024,
            description: "vmnet recovery request"
        )
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let request = try decoder.decode(VMNetRecoveryRequestV1.self, from: data)
            guard !request.networkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !request.failureReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !request.bootSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw VMNetRecoveryStateError.invalidValue("vmnet recovery request contains empty required fields")
            }
            return request
        } catch let error as VMNetRecoveryStateError {
            throw error
        } catch {
            throw VMNetRecoveryStateError.io("failed to decode vmnet recovery request: \(error)")
        }
    }

    public func remove() throws {
        guard unlink(requestURL.path) == 0 else {
            if errno == ENOENT {
                return
            }
            throw VMNetRecoveryStateError.io("failed to remove vmnet recovery request: errno \(errno)")
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw VMNetRecoveryStateError.io("failed to write vmnet recovery request: errno \(errno)")
                }
                guard count > 0 else {
                    throw VMNetRecoveryStateError.io("failed to write vmnet recovery request: zero-byte write")
                }
                offset += count
            }
        }
    }
}
