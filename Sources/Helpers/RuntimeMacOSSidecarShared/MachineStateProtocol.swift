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
/// capability discovery and machine-state lifecycle operations.
public enum MacOSSidecarProtocolVersion {
    public static let legacy = 1
    public static let machineState = 2
    public static let current = machineState
    public static let supported = [legacy, machineState]
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

    public init(stateID: String? = nil, timeoutSeconds: Double? = nil) {
        self.stateID = stateID
        self.timeoutSeconds = timeoutSeconds
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

    public init(
        lifecycleState: MacOSVMRuntimeState,
        stateID: String? = nil,
        compatibility: MacOSMachineStateCompatibilityDescription? = nil
    ) {
        self.lifecycleState = lifecycleState
        self.stateID = stateID
        self.compatibility = compatibility
    }
}
