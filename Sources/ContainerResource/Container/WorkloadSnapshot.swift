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

public enum WorkloadInjectionState: String, Sendable, Codable, Equatable {
    /// The workload starts from a directly supplied process definition and does not need guest injection.
    case notRequired
    /// The workload has an image-backed payload that still needs to be injected into the guest.
    case pending
    /// The workload image payload and metadata are already present in the guest.
    case injected
}

/// Configuration for a workload that runs inside a sandbox.
public struct WorkloadConfiguration: Sendable, Codable {
    public static let schemaVersion = 1

    /// Persisted schema version for workload state.
    public var persistedSchemaVersion: Int
    /// Identifier of the workload within the sandbox.
    public var id: String
    /// Process configuration used to start the workload.
    public var processConfiguration: ProcessConfiguration
    /// Host filesystems required by this workload inside the macOS guest.
    public var mounts: [Filesystem]
    /// Read-only host files injected into the guest before this workload starts.
    public var readOnlyFiles: [ReadOnlyFileInjection]
    /// Source reference of the workload image when the workload is image-backed.
    public var workloadImageReference: String?
    /// Resolved digest of the workload image when the workload is image-backed.
    public var workloadImageDigest: String?
    /// Guest path for the injected workload payload root.
    public var guestPayloadPath: String?
    /// Guest path for the injected workload metadata file.
    public var guestMetadataPath: String?
    /// Injection progress for image-backed workloads.
    public var injectionState: WorkloadInjectionState

    /// Whether the workload is backed by an OCI workload image.
    public var isImageBacked: Bool {
        workloadImageReference != nil || workloadImageDigest != nil
    }

    private enum CodingKeys: String, CodingKey {
        case persistedSchemaVersion = "schemaVersion"
        case id
        case processConfiguration
        case mounts
        case readOnlyFiles
        case workloadImageReference
        case workloadImageDigest
        case guestPayloadPath
        case guestMetadataPath
        case injectionState
    }

    public init(
        id: String,
        processConfiguration: ProcessConfiguration,
        mounts: [Filesystem] = [],
        readOnlyFiles: [ReadOnlyFileInjection] = [],
        workloadImageReference: String? = nil,
        workloadImageDigest: String? = nil,
        guestPayloadPath: String? = nil,
        guestMetadataPath: String? = nil,
        injectionState: WorkloadInjectionState = .notRequired
    ) {
        self.persistedSchemaVersion = Self.schemaVersion
        self.id = id
        self.processConfiguration = processConfiguration
        self.mounts = mounts
        self.readOnlyFiles = readOnlyFiles
        self.workloadImageReference = workloadImageReference
        self.workloadImageDigest = workloadImageDigest
        self.guestPayloadPath = guestPayloadPath
        self.guestMetadataPath = guestMetadataPath
        self.injectionState = injectionState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .persistedSchemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .persistedSchemaVersion,
                in: container,
                debugDescription: "unsupported WorkloadConfiguration schemaVersion \(schemaVersion)"
            )
        }
        self.persistedSchemaVersion = schemaVersion
        self.id = try container.decode(String.self, forKey: .id)
        self.processConfiguration = try container.decode(ProcessConfiguration.self, forKey: .processConfiguration)
        self.mounts = try container.decodeIfPresent([Filesystem].self, forKey: .mounts) ?? []
        self.readOnlyFiles = try container.decodeIfPresent([ReadOnlyFileInjection].self, forKey: .readOnlyFiles) ?? []
        self.workloadImageReference = try container.decodeIfPresent(String.self, forKey: .workloadImageReference)
        self.workloadImageDigest = try container.decodeIfPresent(String.self, forKey: .workloadImageDigest)
        self.guestPayloadPath = try container.decodeIfPresent(String.self, forKey: .guestPayloadPath)
        self.guestMetadataPath = try container.decodeIfPresent(String.self, forKey: .guestMetadataPath)
        self.injectionState = try container.decode(WorkloadInjectionState.self, forKey: .injectionState)
    }
}

/// A snapshot of workload runtime state inside a sandbox.
public struct WorkloadSnapshot: Sendable, Codable {
    /// Static workload configuration.
    public var configuration: WorkloadConfiguration
    /// Current runtime status of the workload.
    public var status: RuntimeStatus
    /// Exit code once the workload has stopped.
    public var exitCode: Int32?
    /// When the workload was started.
    public var startedDate: Date?
    /// When the workload exited.
    public var exitedAt: Date?
    /// Host path to the workload stdout log, if available.
    public var stdoutLogPath: String?
    /// Host path to the workload stderr log, if available.
    public var stderrLogPath: String?

    public var id: String {
        configuration.id
    }

    public init(
        configuration: WorkloadConfiguration,
        status: RuntimeStatus,
        exitCode: Int32? = nil,
        startedDate: Date? = nil,
        exitedAt: Date? = nil,
        stdoutLogPath: String? = nil,
        stderrLogPath: String? = nil
    ) {
        self.configuration = configuration
        self.status = status
        self.exitCode = exitCode
        self.startedDate = startedDate
        self.exitedAt = exitedAt
        self.stdoutLogPath = stdoutLogPath
        self.stderrLogPath = stderrLogPath
    }
}
