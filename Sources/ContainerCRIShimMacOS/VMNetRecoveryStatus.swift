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
import Foundation

private let maximumVMNetRecoveryStatusErrorMessageSize = 4096
private let maximumVMNetRecoveryStatusFreshnessSeconds: TimeInterval = 3 * 24 * 60 * 60

public enum VMNetRecoveryStatusState: String, Codable, Sendable, Equatable {
    case starting
    case ready
    case degraded
    case failed
}

public enum VMNetRecoveryStatusPhase: String, Codable, Sendable, Equatable {
    case starting
    case initializing
    case healthy
    case probeDegraded
    case fenced
    case rebootRequested
    case waitingForReboot
    case verifying
    case blocked
    case failed
}

public enum VMNetRecoveryRebootCommandResult: String, Codable, Sendable, Equatable {
    case requested
    case accepted
    case waiting
    case blocked
    case failed
    case recovered
}

public enum VMNetRecoveryStatusFreshness: Sendable, Equatable {
    case fresh
    case expired
}

public struct VMNetRecoveryStatusCounters: Codable, Sendable, Equatable {
    public var successfulReconciles: UInt64
    public var failedReconciles: UInt64
    public var fencesObserved: UInt64
    public var rebootCommandsAccepted: UInt64
    public var rebootCommandsFailed: UInt64
    public var rebootsObserved: UInt64
    public var recoveriesSucceeded: UInt64
    public var recoveriesFailed: UInt64
    public var loopProtectionBlocks: UInt64

    public init(
        successfulReconciles: UInt64,
        failedReconciles: UInt64,
        fencesObserved: UInt64,
        rebootCommandsAccepted: UInt64,
        rebootCommandsFailed: UInt64,
        rebootsObserved: UInt64,
        recoveriesSucceeded: UInt64,
        recoveriesFailed: UInt64,
        loopProtectionBlocks: UInt64
    ) {
        self.successfulReconciles = successfulReconciles
        self.failedReconciles = failedReconciles
        self.fencesObserved = fencesObserved
        self.rebootCommandsAccepted = rebootCommandsAccepted
        self.rebootCommandsFailed = rebootCommandsFailed
        self.rebootsObserved = rebootsObserved
        self.recoveriesSucceeded = recoveriesSucceeded
        self.recoveriesFailed = recoveriesFailed
        self.loopProtectionBlocks = loopProtectionBlocks
    }

    public static let zero = Self(
        successfulReconciles: 0,
        failedReconciles: 0,
        fencesObserved: 0,
        rebootCommandsAccepted: 0,
        rebootCommandsFailed: 0,
        rebootsObserved: 0,
        recoveriesSucceeded: 0,
        recoveriesFailed: 0,
        loopProtectionBlocks: 0
    )
}

public struct VMNetRecoveryStatus: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var nodeName: String
    public var networkName: String
    public var coordinatorInstanceID: String
    public var updatedAt: String
    public var expiresAt: String
    public var phaseSince: String
    public var lastSuccessAt: String?
    public var state: VMNetRecoveryStatusState
    public var phase: VMNetRecoveryStatusPhase
    public var authorityPhase: VMNetRecoveryPhase?
    public var networkInstanceID: String?
    public var currentBootSessionID: String?
    public var stateBootSessionID: String?
    public var authorityUpdatedAt: String?
    public var recoveryWindowStartedAt: String?
    public var requestPending: Bool?
    public var sandboxAdmissionRejecting: Bool
    public var sandboxRejectedTotal: UInt64?
    public var fenceActive: Bool
    public var failureReason: String?
    public var rebootAttempts: Int
    public var maxRebootAttempts: Int
    public var lastRebootRequestedAt: String?
    public var rebootCommandResult: VMNetRecoveryRebootCommandResult?
    public var consecutiveHealthyProbeFailures: Int
    public var healthyProbeFailureThreshold: Int
    public var loopProtectionBlocked: Bool
    public var counters: VMNetRecoveryStatusCounters
    public var errorCode: String?
    public var errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case nodeName
        case networkName
        case coordinatorInstanceID
        case updatedAt
        case expiresAt
        case phaseSince
        case lastSuccessAt
        case state
        case phase
        case authorityPhase
        case networkInstanceID
        case currentBootSessionID
        case stateBootSessionID
        case authorityUpdatedAt
        case recoveryWindowStartedAt
        case requestPending
        case sandboxAdmissionRejecting
        case sandboxRejectedTotal
        case fenceActive
        case failureReason
        case rebootAttempts
        case maxRebootAttempts
        case lastRebootRequestedAt
        case rebootCommandResult
        case consecutiveHealthyProbeFailures
        case healthyProbeFailureThreshold
        case loopProtectionBlocked
        case counters
        case errorCode
        case errorMessage
    }

    public init(
        nodeName: String,
        networkName: String,
        coordinatorInstanceID: String,
        updatedAt: String,
        expiresAt: String,
        phaseSince: String,
        lastSuccessAt: String?,
        state: VMNetRecoveryStatusState,
        phase: VMNetRecoveryStatusPhase,
        authorityPhase: VMNetRecoveryPhase?,
        networkInstanceID: String?,
        currentBootSessionID: String?,
        stateBootSessionID: String?,
        authorityUpdatedAt: String?,
        recoveryWindowStartedAt: String?,
        requestPending: Bool?,
        sandboxAdmissionRejecting: Bool,
        sandboxRejectedTotal: UInt64?,
        fenceActive: Bool,
        failureReason: String?,
        rebootAttempts: Int,
        maxRebootAttempts: Int,
        lastRebootRequestedAt: String?,
        rebootCommandResult: VMNetRecoveryRebootCommandResult?,
        consecutiveHealthyProbeFailures: Int,
        healthyProbeFailureThreshold: Int,
        loopProtectionBlocked: Bool,
        counters: VMNetRecoveryStatusCounters,
        errorCode: String?,
        errorMessage: String?,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.nodeName = nodeName
        self.networkName = networkName
        self.coordinatorInstanceID = coordinatorInstanceID
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.phaseSince = phaseSince
        self.lastSuccessAt = lastSuccessAt
        self.state = state
        self.phase = phase
        self.authorityPhase = authorityPhase
        self.networkInstanceID = networkInstanceID
        self.currentBootSessionID = currentBootSessionID
        self.stateBootSessionID = stateBootSessionID
        self.authorityUpdatedAt = authorityUpdatedAt
        self.recoveryWindowStartedAt = recoveryWindowStartedAt
        self.requestPending = requestPending
        self.sandboxAdmissionRejecting = sandboxAdmissionRejecting
        self.sandboxRejectedTotal = sandboxRejectedTotal
        self.fenceActive = fenceActive
        self.failureReason = failureReason
        self.rebootAttempts = rebootAttempts
        self.maxRebootAttempts = maxRebootAttempts
        self.lastRebootRequestedAt = lastRebootRequestedAt
        self.rebootCommandResult = rebootCommandResult
        self.consecutiveHealthyProbeFailures = consecutiveHealthyProbeFailures
        self.healthyProbeFailureThreshold = healthyProbeFailureThreshold
        self.loopProtectionBlocked = loopProtectionBlocked
        self.counters = counters
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(nodeName, forKey: .nodeName)
        try container.encode(networkName, forKey: .networkName)
        try container.encode(coordinatorInstanceID, forKey: .coordinatorInstanceID)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(phaseSince, forKey: .phaseSince)
        try container.encodeIfPresent(lastSuccessAt, forKey: .lastSuccessAt)
        try container.encode(state, forKey: .state)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(authorityPhase, forKey: .authorityPhase)
        try container.encodeIfPresent(networkInstanceID, forKey: .networkInstanceID)
        try container.encodeIfPresent(currentBootSessionID, forKey: .currentBootSessionID)
        try container.encodeIfPresent(stateBootSessionID, forKey: .stateBootSessionID)
        try container.encodeIfPresent(authorityUpdatedAt, forKey: .authorityUpdatedAt)
        try container.encodeIfPresent(recoveryWindowStartedAt, forKey: .recoveryWindowStartedAt)
        try container.encodeIfPresent(requestPending, forKey: .requestPending)
        try container.encode(sandboxAdmissionRejecting, forKey: .sandboxAdmissionRejecting)
        if let sandboxRejectedTotal {
            try container.encode(sandboxRejectedTotal, forKey: .sandboxRejectedTotal)
        } else {
            try container.encodeNil(forKey: .sandboxRejectedTotal)
        }
        try container.encode(fenceActive, forKey: .fenceActive)
        try container.encodeIfPresent(failureReason, forKey: .failureReason)
        try container.encode(rebootAttempts, forKey: .rebootAttempts)
        try container.encode(maxRebootAttempts, forKey: .maxRebootAttempts)
        try container.encodeIfPresent(lastRebootRequestedAt, forKey: .lastRebootRequestedAt)
        try container.encodeIfPresent(rebootCommandResult, forKey: .rebootCommandResult)
        try container.encode(consecutiveHealthyProbeFailures, forKey: .consecutiveHealthyProbeFailures)
        try container.encode(healthyProbeFailureThreshold, forKey: .healthyProbeFailureThreshold)
        try container.encode(loopProtectionBlocked, forKey: .loopProtectionBlocked)
        try container.encode(counters, forKey: .counters)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }

    public func freshness(at date: Date = Date()) throws -> VMNetRecoveryStatusFreshness {
        _ = try validated()
        let timestamps = try parsedTimestamps()
        return date >= timestamps.updatedAt && date < timestamps.expiresAt ? .fresh : .expired
    }

    public func isFreshlyReady(at date: Date = Date()) throws -> Bool {
        _ = try validated()
        let timestamps = try parsedTimestamps()
        return state == .ready
            && date >= timestamps.updatedAt
            && date < timestamps.expiresAt
    }

    package func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "unsupported vmnet recovery status schema version \(schemaVersion)"
            )
        }
        try Self.validateIdentity(nodeName, field: "node")
        try Self.validateIdentity(networkName, field: "network")
        guard UUID(uuidString: coordinatorInstanceID) != nil else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "vmnet recovery status contains an invalid coordinator instance ID"
            )
        }
        try Self.validateOptionalIdentity(networkInstanceID, field: "network instance")
        try Self.validateOptionalIdentity(currentBootSessionID, field: "current boot session")
        try Self.validateOptionalIdentity(stateBootSessionID, field: "state boot session")
        guard rebootAttempts >= 0,
            maxRebootAttempts > 0,
            consecutiveHealthyProbeFailures >= 0,
            healthyProbeFailureThreshold > 0
        else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "vmnet recovery status contains an invalid attempt count"
            )
        }
        guard (errorCode == nil) == (errorMessage == nil),
            errorCode.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains(where: \.isWhitespace) }) ?? true,
            errorMessage.map({ !$0.isEmpty && $0.utf8.count <= maximumVMNetRecoveryStatusErrorMessageSize }) ?? true,
            failureReason.map({ !$0.isEmpty && $0.utf8.count <= maximumVMNetRecoveryStatusErrorMessageSize }) ?? true
        else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "vmnet recovery status contains an invalid error"
            )
        }
        _ = try parsedTimestamps()
        try validateState()
        return self
    }

    private func validateState() throws {
        switch state {
        case .starting:
            guard phase == .starting, errorCode == nil, errorMessage == nil else {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "starting vmnet recovery status is inconsistent"
                )
            }
        case .ready:
            guard phase == .healthy,
                authorityPhase == .healthy,
                networkInstanceID != nil,
                currentBootSessionID != nil,
                currentBootSessionID == stateBootSessionID,
                requestPending == false,
                !sandboxAdmissionRejecting,
                !fenceActive,
                lastSuccessAt != nil,
                errorCode == nil,
                errorMessage == nil
            else {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "ready vmnet recovery status is inconsistent"
                )
            }
        case .degraded:
            guard
                [.initializing, .probeDegraded, .fenced, .rebootRequested, .waitingForReboot, .verifying]
                    .contains(phase),
                errorCode != nil,
                errorMessage != nil
            else {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "degraded vmnet recovery status is inconsistent"
                )
            }
            if phase == .probeDegraded {
                guard authorityPhase == .healthy, !sandboxAdmissionRejecting else {
                    throw VMNetRecoveryStatusStoreError.persistence(
                        "probe-degraded vmnet recovery status is inconsistent"
                    )
                }
            } else {
                guard sandboxAdmissionRejecting else {
                    throw VMNetRecoveryStatusStoreError.persistence(
                        "degraded vmnet recovery status must reject sandbox admission"
                    )
                }
            }
        case .failed:
            guard [.blocked, .failed].contains(phase),
                sandboxAdmissionRejecting,
                errorCode != nil,
                errorMessage != nil
            else {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "failed vmnet recovery status is inconsistent"
                )
            }
        }
        if authorityPhase == .rebootRequested {
            guard rebootAttempts > 0, lastRebootRequestedAt != nil else {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "reboot-requested authority state lacks reboot details"
                )
            }
        }
        if loopProtectionBlocked {
            guard state == .failed, phase == .blocked else {
                throw VMNetRecoveryStatusStoreError.persistence(
                    "loop-protection status is not blocked"
                )
            }
        }
    }

    private func parsedTimestamps() throws -> ParsedTimestamps {
        let updatedAt = try Self.parseTimestamp(updatedAt, field: "updatedAt")
        let expiresAt = try Self.parseTimestamp(expiresAt, field: "expiresAt")
        let phaseSince = try Self.parseTimestamp(phaseSince, field: "phaseSince")
        let lastSuccessAt = try lastSuccessAt.map {
            try Self.parseTimestamp($0, field: "lastSuccessAt")
        }
        let authorityUpdatedAt = try authorityUpdatedAt.map {
            try Self.parseTimestamp($0, field: "authorityUpdatedAt")
        }
        let recoveryWindowStartedAt = try recoveryWindowStartedAt.map {
            try Self.parseTimestamp($0, field: "recoveryWindowStartedAt")
        }
        let lastRebootRequestedAt = try lastRebootRequestedAt.map {
            try Self.parseTimestamp($0, field: "lastRebootRequestedAt")
        }
        guard phaseSince <= updatedAt,
            updatedAt < expiresAt,
            expiresAt.timeIntervalSince(updatedAt) <= maximumVMNetRecoveryStatusFreshnessSeconds,
            lastSuccessAt.map({ $0 <= updatedAt }) ?? true,
            authorityUpdatedAt.map({ $0 <= updatedAt }) ?? true,
            recoveryWindowStartedAt.map({ $0 <= updatedAt }) ?? true,
            lastRebootRequestedAt.map({ $0 <= updatedAt }) ?? true
        else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "vmnet recovery status timestamps are inconsistent"
            )
        }
        return ParsedTimestamps(updatedAt: updatedAt, expiresAt: expiresAt)
    }

    private static func validateIdentity(_ value: String, field: String) throws {
        guard !value.isEmpty,
            value.utf8.count <= 512,
            !value.contains("/"),
            !value.contains(where: \.isWhitespace)
        else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "vmnet recovery status contains an invalid \(field) name"
            )
        }
    }

    private static func validateOptionalIdentity(_ value: String?, field: String) throws {
        guard let value else {
            return
        }
        try validateIdentity(value, field: field)
    }

    private static func parseTimestamp(_ timestamp: String, field: String) throws -> Date {
        let pattern =
            #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#
        guard timestamp.range(of: pattern, options: .regularExpression) != nil else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "vmnet recovery status contains an invalid RFC3339 \(field) timestamp"
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            timestamp.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        guard let date = formatter.date(from: timestamp) else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "vmnet recovery status contains an invalid RFC3339 \(field) timestamp"
            )
        }
        return date
    }

    private struct ParsedTimestamps {
        var updatedAt: Date
        var expiresAt: Date
    }
}
