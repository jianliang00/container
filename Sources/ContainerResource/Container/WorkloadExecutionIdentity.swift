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

/// Stable identity for one logical workload execution across runtime object recreation.
///
/// The execution identifier is issued independently from transient runtime, container, or
/// process identifiers. The launch fingerprint is supplied by a trusted caller and must be
/// computed from a deterministic launch descriptor. Only the final digest may be persisted;
/// secret values, credentials, tokens, and transient identifiers must not be stored alongside it.
public struct WorkloadExecutionIdentity: Sendable, Codable, Equatable {
    public static let schemaVersion = 1

    public enum ValidationError: Swift.Error, Sendable, Equatable, LocalizedError {
        case invalidExecutionID
        case invalidLaunchFingerprint
        case invalidIncarnation
        case invalidRestoreGeneration
        case conflictingRestoreExecutionID

        public var errorDescription: String? {
            switch self {
            case .invalidExecutionID:
                "execution id must be a canonical, non-empty identifier"
            case .invalidLaunchFingerprint:
                "launch fingerprint must be a canonical lowercase SHA-256 digest"
            case .invalidIncarnation:
                "incarnation must be a canonical lowercase SHA-256 digest"
            case .invalidRestoreGeneration:
                "restore generation must be greater than zero"
            case .conflictingRestoreExecutionID:
                "restore binding does not match the workload execution id"
            }
        }
    }

    /// Identifies the logical execution and generation to which restored state belongs.
    public struct RestoreBinding: Sendable, Codable, Equatable {
        /// Stable execution identifier recorded with the restored state.
        public let executionID: String
        /// Positive, monotonically increasing generation of the restored state.
        public let generation: UInt64

        private enum CodingKeys: String, CodingKey {
            case executionID
            case generation
        }

        public init(executionID: String, generation: UInt64) throws {
            guard WorkloadExecutionIdentity.isCanonicalIdentifier(executionID) else {
                throw ValidationError.invalidExecutionID
            }
            guard generation > 0 else {
                throw ValidationError.invalidRestoreGeneration
            }

            self.executionID = executionID
            self.generation = generation
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let executionID = try container.decode(String.self, forKey: .executionID)
            let generation = try container.decode(UInt64.self, forKey: .generation)

            do {
                try self.init(executionID: executionID, generation: generation)
            } catch ValidationError.invalidExecutionID {
                throw DecodingError.dataCorruptedError(
                    forKey: .executionID,
                    in: container,
                    debugDescription: ValidationError.invalidExecutionID.localizedDescription
                )
            } catch ValidationError.invalidRestoreGeneration {
                throw DecodingError.dataCorruptedError(
                    forKey: .generation,
                    in: container,
                    debugDescription: ValidationError.invalidRestoreGeneration.localizedDescription
                )
            }
        }
    }

    /// Persisted schema version for this identity record.
    public let persistedSchemaVersion: Int
    /// Stable identifier for the logical execution, independent of runtime object IDs.
    public let executionID: String
    /// Caller-supplied fingerprint in canonical `sha256:<64 lowercase hex>` form.
    public let launchFingerprint: String
    /// Stable token for one concrete CRI container incarnation. Retries of the
    /// same CreateContainer request retain it; a new container attempt changes it.
    public let incarnation: String?
    /// Optional binding when this execution is resumed from previously retained state.
    public let restoreBinding: RestoreBinding?

    private enum CodingKeys: String, CodingKey {
        case persistedSchemaVersion = "schemaVersion"
        case executionID
        case launchFingerprint
        case incarnation
        case restoreBinding
    }

    public init(
        executionID: String,
        launchFingerprint: String,
        incarnation: String? = nil,
        restoreBinding: RestoreBinding? = nil
    ) throws {
        guard Self.isCanonicalIdentifier(executionID) else {
            throw ValidationError.invalidExecutionID
        }
        guard Self.isCanonicalLaunchFingerprint(launchFingerprint) else {
            throw ValidationError.invalidLaunchFingerprint
        }
        if let incarnation, !Self.isCanonicalLaunchFingerprint(incarnation) {
            throw ValidationError.invalidIncarnation
        }
        if let restoreBinding, restoreBinding.executionID != executionID {
            throw ValidationError.conflictingRestoreExecutionID
        }

        self.persistedSchemaVersion = Self.schemaVersion
        self.executionID = executionID
        self.launchFingerprint = launchFingerprint
        self.incarnation = incarnation
        self.restoreBinding = restoreBinding
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .persistedSchemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .persistedSchemaVersion,
                in: container,
                debugDescription: "unsupported WorkloadExecutionIdentity schemaVersion \(schemaVersion)"
            )
        }

        let executionID = try container.decode(String.self, forKey: .executionID)
        let launchFingerprint = try container.decode(String.self, forKey: .launchFingerprint)
        let incarnation = try container.decodeIfPresent(String.self, forKey: .incarnation)
        let restoreBinding = try container.decodeIfPresent(RestoreBinding.self, forKey: .restoreBinding)

        do {
            try self.init(
                executionID: executionID,
                launchFingerprint: launchFingerprint,
                incarnation: incarnation,
                restoreBinding: restoreBinding
            )
        } catch ValidationError.invalidExecutionID {
            throw DecodingError.dataCorruptedError(
                forKey: .executionID,
                in: container,
                debugDescription: ValidationError.invalidExecutionID.localizedDescription
            )
        } catch ValidationError.invalidLaunchFingerprint {
            throw DecodingError.dataCorruptedError(
                forKey: .launchFingerprint,
                in: container,
                debugDescription: ValidationError.invalidLaunchFingerprint.localizedDescription
            )
        } catch ValidationError.invalidIncarnation {
            throw DecodingError.dataCorruptedError(
                forKey: .incarnation,
                in: container,
                debugDescription: ValidationError.invalidIncarnation.localizedDescription
            )
        } catch ValidationError.conflictingRestoreExecutionID {
            throw DecodingError.dataCorruptedError(
                forKey: .restoreBinding,
                in: container,
                debugDescription: ValidationError.conflictingRestoreExecutionID.localizedDescription
            )
        }
    }

    private static func isCanonicalIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        guard let first = bytes.first, bytes.count <= 128, isASCIIAlphaNumeric(first) else {
            return false
        }

        return bytes.dropFirst().allSatisfy { byte in
            isASCIIAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 58 || byte == 95
        }
    }

    private static func isCanonicalLaunchFingerprint(_ value: String) -> Bool {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix) else {
            return false
        }

        let digest = value.utf8.dropFirst(prefix.utf8.count)
        guard digest.count == 64 else {
            return false
        }
        return digest.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }
}
