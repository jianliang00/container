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

/// Version 1 is the original unversioned control protocol. Version 2 adds
/// capability discovery and machine-state lifecycle operations. Version 3
/// adds consumer acknowledgements for durable event delivery. Version 4 adds
/// trusted durable-process delete identities. Version 5 separates trusted and
/// guest launch fingerprints and fences requests by process incarnation.
/// Version 6 binds machine state to a durable disk snapshot and process
/// adoption manifest.
public enum MacOSSidecarProtocolVersion {
    public static let legacy = 1
    public static let machineState = 2
    public static let durableEventAcknowledgement = 3
    public static let durableProcessDeleteIdentity = 4
    public static let durableProcessIdentity = 5
    public static let durableCheckpointAdoption = 6
    public static let current = durableCheckpointAdoption
    public static let supported = [
        legacy,
        machineState,
        durableEventAcknowledgement,
        durableProcessDeleteIdentity,
        durableProcessIdentity,
        durableCheckpointAdoption,
    ]
}

public enum MacOSVMRuntimeState: String, Codable, Sendable {
    case created
    case starting
    case running
    case pausing
    case paused
    case resuming
    case saving
    case restoring
    case stopping
    case stopped
    case failed
}

public struct MacOSMachineStateRequestPayload: Codable, Sendable, Equatable {
    public let stateID: String?
    public let timeoutSeconds: Double?
    public let checkpointID: String?
    public let persistenceID: String?
    public let sourcePodUID: String?
    public let sourceStorageGeneration: UInt64?
    public let diskSnapshot: MacOSMachineStateDiskSnapshotReceipt?
    public let pairID: String?
    public let compatibilityClass: String?
    public let adoptionManifestDigest: String?
    public let restoreRequestID: String?

    public init(
        stateID: String? = nil,
        timeoutSeconds: Double? = nil,
        checkpointID: String? = nil,
        persistenceID: String? = nil,
        sourcePodUID: String? = nil,
        sourceStorageGeneration: UInt64? = nil,
        diskSnapshot: MacOSMachineStateDiskSnapshotReceipt? = nil,
        pairID: String? = nil,
        compatibilityClass: String? = nil,
        adoptionManifestDigest: String? = nil,
        restoreRequestID: String? = nil
    ) {
        self.stateID = stateID
        self.timeoutSeconds = timeoutSeconds
        self.checkpointID = checkpointID
        self.persistenceID = persistenceID
        self.sourcePodUID = sourcePodUID
        self.sourceStorageGeneration = sourceStorageGeneration
        self.diskSnapshot = diskSnapshot
        self.pairID = pairID
        self.compatibilityClass = compatibilityClass
        self.adoptionManifestDigest = adoptionManifestDigest
        self.restoreRequestID = restoreRequestID
    }
}

public struct MacOSMachineStateDiskSnapshotReceipt: Codable, Sendable, Equatable {
    public let snapshotID: String
    public let volumeID: String
    public let snapshotRef: String
    public let storageGeneration: UInt64
    public let operationID: String
    public let operationSequence: UInt64
    public let ownerEpoch: UInt64

    public init(
        snapshotID: String,
        volumeID: String,
        snapshotRef: String,
        storageGeneration: UInt64,
        operationID: String,
        operationSequence: UInt64,
        ownerEpoch: UInt64
    ) {
        self.snapshotID = snapshotID
        self.volumeID = volumeID
        self.snapshotRef = snapshotRef
        self.storageGeneration = storageGeneration
        self.operationID = operationID
        self.operationSequence = operationSequence
        self.ownerEpoch = ownerEpoch
    }
}

public struct MacOSMachineStateAdoptionWorkload: Codable, Sendable, Equatable {
    public let runtimeWorkloadID: String
    public let guestProcessID: String
    public let trustedLaunchFingerprint: String
    public let guestLaunchFingerprint: String
    public let processIncarnation: String
    public let storageGeneration: UInt64
    public let processIdentifier: Int32
    public let lastPersistedEventSequence: UInt64

    public init(
        runtimeWorkloadID: String,
        guestProcessID: String,
        trustedLaunchFingerprint: String,
        guestLaunchFingerprint: String,
        processIncarnation: String,
        storageGeneration: UInt64,
        processIdentifier: Int32,
        lastPersistedEventSequence: UInt64
    ) {
        self.runtimeWorkloadID = runtimeWorkloadID
        self.guestProcessID = guestProcessID
        self.trustedLaunchFingerprint = trustedLaunchFingerprint
        self.guestLaunchFingerprint = guestLaunchFingerprint
        self.processIncarnation = processIncarnation
        self.storageGeneration = storageGeneration
        self.processIdentifier = processIdentifier
        self.lastPersistedEventSequence = lastPersistedEventSequence
    }
}

public struct MacOSMachineStateAdoptionManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let checkpointID: String
    public let persistenceID: String
    public let sourcePodUID: String?
    public let sourceStorageGeneration: UInt64
    public let workloads: [MacOSMachineStateAdoptionWorkload]

    public init(
        schemaVersion: Int = 1,
        checkpointID: String,
        persistenceID: String,
        sourcePodUID: String? = nil,
        sourceStorageGeneration: UInt64,
        workloads: [MacOSMachineStateAdoptionWorkload]
    ) {
        self.schemaVersion = schemaVersion
        self.checkpointID = checkpointID
        self.persistenceID = persistenceID
        self.sourcePodUID = sourcePodUID
        self.sourceStorageGeneration = sourceStorageGeneration
        self.workloads = workloads
    }
}

public struct MacOSMachineStateDurablePair: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let pairID: String
    public let persistenceID: String
    public let stateID: String
    public let stateGeneration: UInt64
    public let diskSnapshot: MacOSMachineStateDiskSnapshotReceipt
    public let compatibilityClass: String
    public let adoptionManifestDigest: String

    public init(
        schemaVersion: Int = 1,
        pairID: String,
        persistenceID: String,
        stateID: String,
        stateGeneration: UInt64,
        diskSnapshot: MacOSMachineStateDiskSnapshotReceipt,
        compatibilityClass: String,
        adoptionManifestDigest: String
    ) {
        self.schemaVersion = schemaVersion
        self.pairID = pairID
        self.persistenceID = persistenceID
        self.stateID = stateID
        self.stateGeneration = stateGeneration
        self.diskSnapshot = diskSnapshot
        self.compatibilityClass = compatibilityClass
        self.adoptionManifestDigest = adoptionManifestDigest
    }
}

public struct MacOSMachineStateReceipt: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let committed: Bool
    public let pair: MacOSMachineStateDurablePair
    public let adoption: MacOSMachineStateAdoptionManifest
    public let stateSizeBytes: UInt64
    public let committedAt: Date

    public init(
        schemaVersion: Int = 1,
        committed: Bool = true,
        pair: MacOSMachineStateDurablePair,
        adoption: MacOSMachineStateAdoptionManifest,
        stateSizeBytes: UInt64,
        committedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.committed = committed
        self.pair = pair
        self.adoption = adoption
        self.stateSizeBytes = stateSizeBytes
        self.committedAt = committedAt
    }
}

public struct MacOSMachineStateCheckpointResult: Codable, Sendable, Equatable {
    public let checkpointID: String
    public let persistenceID: String
    public let storageGeneration: UInt64
    public let adoption: MacOSMachineStateAdoptionManifest
    public let adoptionManifestDigest: String

    public init(
        checkpointID: String,
        persistenceID: String,
        storageGeneration: UInt64,
        adoption: MacOSMachineStateAdoptionManifest,
        adoptionManifestDigest: String
    ) {
        self.checkpointID = checkpointID
        self.persistenceID = persistenceID
        self.storageGeneration = storageGeneration
        self.adoption = adoption
        self.adoptionManifestDigest = adoptionManifestDigest
    }
}

public struct MacOSStorageAttachmentStatus: Codable, Sendable, Equatable {
    public let identifier: String
    public let readOnly: Bool
    public let synchronizationMode: String?
    public let connectionCount: Int
    public let terminalError: String?

    public init(
        identifier: String,
        readOnly: Bool,
        synchronizationMode: String? = nil,
        connectionCount: Int,
        terminalError: String? = nil
    ) {
        self.identifier = identifier
        self.readOnly = readOnly
        self.synchronizationMode = synchronizationMode
        self.connectionCount = connectionCount
        self.terminalError = terminalError
    }
}

public struct MacOSMachineStateUnsupportedReason: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let configurationComponent: String?

    public init(code: String, message: String, configurationComponent: String? = nil) {
        self.code = code
        self.message = message
        self.configurationComponent = configurationComponent
    }
}

public struct MacOSMachineStateCapability: Codable, Sendable, Equatable {
    public let supported: Bool
    public let unsupportedReason: MacOSMachineStateUnsupportedReason?

    public init(supported: Bool, unsupportedReason: MacOSMachineStateUnsupportedReason? = nil) {
        self.supported = supported
        self.unsupportedReason = unsupportedReason
    }
}

public struct MacOSSidecarCapabilities: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let supportedProtocolVersions: [Int]
    public let lifecycleState: MacOSVMRuntimeState
    public let machineState: MacOSMachineStateCapability
    public let methods: [String]

    public init(
        protocolVersion: Int = MacOSSidecarProtocolVersion.current,
        supportedProtocolVersions: [Int] = MacOSSidecarProtocolVersion.supported,
        lifecycleState: MacOSVMRuntimeState,
        machineState: MacOSMachineStateCapability,
        methods: [String]
    ) {
        self.protocolVersion = protocolVersion
        self.supportedProtocolVersions = supportedProtocolVersions
        self.lifecycleState = lifecycleState
        self.machineState = machineState
        self.methods = methods
    }
}

public struct MacOSMachineStateStorageDescription: Codable, Sendable, Equatable {
    public let kind: String
    public let identifier: String
    public let readOnly: Bool
    public let synchronizationMode: String?

    public init(kind: String, identifier: String, readOnly: Bool, synchronizationMode: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.readOnly = readOnly
        self.synchronizationMode = synchronizationMode
    }
}

public struct MacOSMachineStateVMConfigurationDescription: Codable, Sendable, Equatable {
    public let cpuCount: Int
    public let memorySize: UInt64
    public let bootLoader: String
    public let networkBackend: String
    public let networkDeviceMACAddresses: [String]?
    public let storageDevices: [MacOSMachineStateStorageDescription]
    public let directoryShareCount: Int
    public let hasGraphics: Bool
    public let hasVirtioSocket: Bool
    public let fingerprint: String

    public init(
        cpuCount: Int,
        memorySize: UInt64,
        bootLoader: String,
        networkBackend: String,
        networkDeviceMACAddresses: [String]? = nil,
        storageDevices: [MacOSMachineStateStorageDescription],
        directoryShareCount: Int,
        hasGraphics: Bool,
        hasVirtioSocket: Bool,
        fingerprint: String
    ) {
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.bootLoader = bootLoader
        self.networkBackend = networkBackend
        self.networkDeviceMACAddresses = networkDeviceMACAddresses
        self.storageDevices = storageDevices
        self.directoryShareCount = directoryShareCount
        self.hasGraphics = hasGraphics
        self.hasVirtioSocket = hasVirtioSocket
        self.fingerprint = fingerprint
    }
}

/// Machine state is intentionally host-bound. `hostIdentifier`, `hostModel`,
/// and `hostBuild` must all match before a restore is attempted.
public struct MacOSMachineStateCompatibilityDescription: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let runtimeProtocolVersion: Int
    public let createdAt: Date
    public let hostBuild: String
    public let hostModel: String
    public let hostIdentifier: String
    public let hardwareModelFingerprint: String
    public let machineIdentifierFingerprint: String
    /// Writable external-disk generation present when this state was saved.
    public let storageGeneration: UInt64?
    public let configuration: MacOSMachineStateVMConfigurationDescription

    public init(
        schemaVersion: Int = 1,
        runtimeProtocolVersion: Int = MacOSSidecarProtocolVersion.machineState,
        createdAt: Date,
        hostBuild: String,
        hostModel: String,
        hostIdentifier: String,
        hardwareModelFingerprint: String,
        machineIdentifierFingerprint: String,
        storageGeneration: UInt64? = nil,
        configuration: MacOSMachineStateVMConfigurationDescription
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeProtocolVersion = runtimeProtocolVersion
        self.createdAt = createdAt
        self.hostBuild = hostBuild
        self.hostModel = hostModel
        self.hostIdentifier = hostIdentifier
        self.hardwareModelFingerprint = hardwareModelFingerprint
        self.machineIdentifierFingerprint = machineIdentifierFingerprint
        self.storageGeneration = storageGeneration
        self.configuration = configuration
    }
}

public struct MacOSMachineStateCompatibilityResult: Codable, Sendable, Equatable {
    public let current: MacOSMachineStateCompatibilityDescription
    public let saved: MacOSMachineStateCompatibilityDescription?
    public let compatible: Bool
    public let reasons: [MacOSMachineStateUnsupportedReason]

    public init(
        current: MacOSMachineStateCompatibilityDescription,
        saved: MacOSMachineStateCompatibilityDescription? = nil,
        compatible: Bool,
        reasons: [MacOSMachineStateUnsupportedReason] = []
    ) {
        self.current = current
        self.saved = saved
        self.compatible = compatible
        self.reasons = reasons
    }
}

public struct MacOSMachineStateOperationResult: Codable, Sendable, Equatable {
    public let lifecycleState: MacOSVMRuntimeState
    public let stateID: String?
    public let compatibility: MacOSMachineStateCompatibilityDescription?
    public let receipt: MacOSMachineStateReceipt?

    public init(
        lifecycleState: MacOSVMRuntimeState,
        stateID: String? = nil,
        compatibility: MacOSMachineStateCompatibilityDescription? = nil,
        receipt: MacOSMachineStateReceipt? = nil
    ) {
        self.lifecycleState = lifecycleState
        self.stateID = stateID
        self.compatibility = compatibility
        self.receipt = receipt
    }
}

public struct MacOSMachineStateDeleteResult: Codable, Sendable, Equatable {
    public let stateID: String
    public let deleted: Bool

    public init(stateID: String, deleted: Bool) {
        self.stateID = stateID
        self.deleted = deleted
    }
}
