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

import ContainerCRIShimMacOS
import ContainerResource
import Darwin
import Foundation

private let maximumVMNetRecoveryStatusErrorMessageSize = 4096
private let maximumVMNetRecoveryStatusFreshnessSeconds: TimeInterval = 3 * 24 * 60 * 60

enum VMNetRecoveryStatusState: String, Codable, Sendable, Equatable {
    case starting
    case ready
    case degraded
    case failed
}

enum VMNetRecoveryStatusPhase: String, Codable, Sendable, Equatable {
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

enum VMNetRecoveryRebootCommandResult: String, Codable, Sendable, Equatable {
    case requested
    case accepted
    case waiting
    case blocked
    case failed
    case recovered
}

enum VMNetRecoveryStatusFreshness: Sendable, Equatable {
    case fresh
    case expired
}

struct VMNetRecoveryStatusCounters: Codable, Sendable, Equatable {
    var successfulReconciles: UInt64
    var failedReconciles: UInt64
    var fencesObserved: UInt64
    var rebootCommandsAccepted: UInt64
    var rebootCommandsFailed: UInt64
    var rebootsObserved: UInt64
    var recoveriesSucceeded: UInt64
    var recoveriesFailed: UInt64
    var loopProtectionBlocks: UInt64

    static let zero = Self(
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

struct VMNetRecoveryStatus: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var nodeName: String
    var networkName: String
    var coordinatorInstanceID: String
    var updatedAt: String
    var expiresAt: String
    var phaseSince: String
    var lastSuccessAt: String?
    var state: VMNetRecoveryStatusState
    var phase: VMNetRecoveryStatusPhase
    var authorityPhase: VMNetRecoveryPhase?
    var networkInstanceID: String?
    var currentBootSessionID: String?
    var stateBootSessionID: String?
    var authorityUpdatedAt: String?
    var recoveryWindowStartedAt: String?
    var requestPending: Bool?
    var sandboxAdmissionRejecting: Bool
    var sandboxRejectedTotal: UInt64?
    var fenceActive: Bool
    var failureReason: String?
    var rebootAttempts: Int
    var maxRebootAttempts: Int
    var lastRebootRequestedAt: String?
    var rebootCommandResult: VMNetRecoveryRebootCommandResult?
    var consecutiveHealthyProbeFailures: Int
    var healthyProbeFailureThreshold: Int
    var loopProtectionBlocked: Bool
    var counters: VMNetRecoveryStatusCounters
    var errorCode: String?
    var errorMessage: String?

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

    init(
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

    func encode(to encoder: any Encoder) throws {
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

    func freshness(at date: Date = Date()) throws -> VMNetRecoveryStatusFreshness {
        _ = try validated()
        let timestamps = try parsedTimestamps()
        return date >= timestamps.updatedAt && date < timestamps.expiresAt ? .fresh : .expired
    }

    func isFreshlyReady(at date: Date = Date()) throws -> Bool {
        _ = try validated()
        let timestamps = try parsedTimestamps()
        return state == .ready
            && date >= timestamps.updatedAt
            && date < timestamps.expiresAt
    }

    func validated() throws -> Self {
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

enum VMNetRecoveryStatusEvent {
    case starting
    case result(VMNetRecoveryCoordinatorResult)
    case fenced
    case rebootCommandRequested
    case rebootCommandAccepted
    case rebootCommandFailed(String)
    case verificationStarted
    case recovered
}

struct VMNetRecoveryStatusRecorder: Sendable {
    private static let minimumFreshnessSeconds = 15

    private let store: any VMNetRecoveryStatusStoring
    private let now: @Sendable () -> Date
    private let coordinatorInstanceID: String

    init(
        store: any VMNetRecoveryStatusStoring,
        coordinatorInstanceID: String = UUID().uuidString,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.coordinatorInstanceID = coordinatorInstanceID
        self.now = now
    }

    @discardableResult
    func record(
        event: VMNetRecoveryStatusEvent,
        config: CRIShimConfig,
        currentBootSessionID: String?
    ) throws -> VMNetRecoveryStatus {
        let recovery = config.resolvedVMNetRecoveryConfig
        guard let nodeName = recovery.nodeName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !nodeName.isEmpty,
            let networkName = config.podNetwork?.networkName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !networkName.isEmpty
        else {
            throw VMNetRecoveryStatusStoreError.persistence(
                "vmnet recovery status identity is not configured"
            )
        }

        let previous = (try? store.load()).flatMap {
            $0.nodeName == nodeName && $0.networkName == networkName ? $0 : nil
        }
        let authority = captureAuthority(config: config)
        var description = describe(event, authority: authority)
        if let authorityError = authority.errorMessage, !event.isStarting {
            description = EventDescription(
                state: .failed,
                phase: .failed,
                errorCode: "authorityStateUnavailable",
                errorMessage: authorityError,
                rebootCommandResult: description.rebootCommandResult,
                consecutiveHealthyProbeFailures: description.consecutiveHealthyProbeFailures,
                recoverySucceeded: false,
                rebootCommandAccepted: description.rebootCommandAccepted,
                rebootCommandFailed: description.rebootCommandFailed
            )
        }

        let normalizedCurrentBoot = Self.normalized(currentBootSessionID)
        let stateBoot = authority.state.flatMap { Self.normalized($0.bootSessionID) }
        let requestPending = authority.requestPending
        let authorityHealthy = authority.state?.phase == .healthy
        let admissionRejecting =
            requestPending != false
            || !authorityHealthy
            || normalizedCurrentBoot == nil
            || normalizedCurrentBoot != stateBoot
        let fenceActive = admissionRejecting

        if description.state == .ready,
            admissionRejecting || authority.state?.networkInstanceID == nil
        {
            description = EventDescription(
                state: .failed,
                phase: .failed,
                errorCode: "authorityStateInconsistent",
                errorMessage: "vmnet recovery authority is not healthy for the current boot",
                rebootCommandResult: description.rebootCommandResult,
                consecutiveHealthyProbeFailures: description.consecutiveHealthyProbeFailures,
                recoverySucceeded: false,
                rebootCommandAccepted: description.rebootCommandAccepted,
                rebootCommandFailed: description.rebootCommandFailed
            )
        }

        var counters = previous?.counters ?? .zero
        if event.isReconcileResult {
            if description.state == .failed {
                counters.failedReconciles.incrementSaturating()
            } else {
                counters.successfulReconciles.incrementSaturating()
            }
        }
        let previousAuthorityWasDurablyFenced =
            previous.map { $0.authorityPhase != nil && $0.authorityPhase != .healthy } ?? false
        if event.isFenceObservation, !previousAuthorityWasDurablyFenced, fenceActive {
            counters.fencesObserved.incrementSaturating()
        }
        if description.rebootCommandAccepted,
            previous?.rebootCommandResult != .accepted
        {
            counters.rebootCommandsAccepted.incrementSaturating()
        }
        if description.rebootCommandFailed,
            previous?.rebootCommandResult != .failed
        {
            counters.rebootCommandsFailed.incrementSaturating()
        }
        if let normalizedCurrentBoot, let stateBoot,
            normalizedCurrentBoot != stateBoot,
            previous?.currentBootSessionID != normalizedCurrentBoot
                || previous?.stateBootSessionID != stateBoot
        {
            counters.rebootsObserved.incrementSaturating()
        }
        if description.recoverySucceeded,
            previous?.phase != .healthy || previous?.stateBootSessionID != normalizedCurrentBoot
        {
            counters.recoveriesSucceeded.incrementSaturating()
        }
        if description.state == .failed,
            previous?.state != .failed
        {
            counters.recoveriesFailed.incrementSaturating()
        }
        let loopProtectionBlocked = Self.isLoopProtectionError(description.errorCode)
        if loopProtectionBlocked,
            !((previous?.loopProtectionBlocked ?? false) && previous?.errorCode == description.errorCode)
        {
            counters.loopProtectionBlocks.incrementSaturating()
        }

        let timestampDate = now()
        let timestamp = Self.timestamp(timestampDate)
        let samePhase =
            previous?.coordinatorInstanceID == coordinatorInstanceID
            && previous?.phase == description.phase
            && previous?.errorCode == description.errorCode
        let lastSuccessAt = description.state == .ready ? timestamp : previous?.lastSuccessAt
        let status = VMNetRecoveryStatus(
            nodeName: nodeName,
            networkName: networkName,
            coordinatorInstanceID: coordinatorInstanceID,
            updatedAt: timestamp,
            expiresAt: Self.expirationTimestamp(
                from: timestampDate,
                pollIntervalSeconds: recovery.pollIntervalSeconds
            ),
            phaseSince: samePhase ? previous!.phaseSince : timestamp,
            lastSuccessAt: lastSuccessAt,
            state: description.state,
            phase: description.phase,
            authorityPhase: authority.state?.phase,
            networkInstanceID: Self.normalized(authority.state?.networkInstanceID),
            currentBootSessionID: normalizedCurrentBoot,
            stateBootSessionID: stateBoot,
            authorityUpdatedAt: authority.state.map { Self.timestamp($0.updatedAt) },
            recoveryWindowStartedAt: authority.state.map { Self.timestamp($0.firstObservedAt) },
            requestPending: requestPending,
            sandboxAdmissionRejecting: admissionRejecting,
            sandboxRejectedTotal: nil,
            fenceActive: fenceActive,
            failureReason: authority.state?.failureReason.map(Self.truncatedErrorMessage),
            rebootAttempts: authority.state?.rebootAttempts ?? 0,
            maxRebootAttempts: recovery.maxRebootAttempts,
            lastRebootRequestedAt: authority.state?.lastRebootRequestedAt.map(Self.timestamp),
            rebootCommandResult: description.rebootCommandResult,
            consecutiveHealthyProbeFailures: description.consecutiveHealthyProbeFailures,
            healthyProbeFailureThreshold: recovery.healthyProbeFailureThreshold,
            loopProtectionBlocked: loopProtectionBlocked,
            counters: counters,
            errorCode: description.errorCode,
            errorMessage: description.errorMessage.map(Self.truncatedErrorMessage)
        )
        try store.save(status.validated())
        return status
    }

    func remove() throws {
        try store.remove()
    }

    private func captureAuthority(config: CRIShimConfig) -> AuthoritySnapshot {
        let recovery = config.resolvedVMNetRecoveryConfig
        var state: VMNetRecoveryStateV1?
        var requestPending: Bool?
        var errors: [String] = []
        if let statePath = recovery.statePath {
            do {
                state = try VMNetRecoveryStateStore(path: statePath).load()
            } catch {
                errors.append("state: \(error)")
            }
        } else {
            errors.append("state path is not configured")
        }
        if let requestPath = recovery.requestPath {
            do {
                requestPending = try VMNetRecoveryRequestStore(path: requestPath).hasPendingRequest()
            } catch {
                errors.append("request: \(error)")
            }
        } else {
            errors.append("request path is not configured")
        }
        return AuthoritySnapshot(
            state: state,
            requestPending: requestPending,
            errorMessage: errors.isEmpty ? nil : errors.joined(separator: "; ")
        )
    }

    private func describe(
        _ event: VMNetRecoveryStatusEvent,
        authority: AuthoritySnapshot
    ) -> EventDescription {
        switch event {
        case .starting:
            return EventDescription(state: .starting, phase: .starting)
        case .fenced:
            return EventDescription(
                state: .degraded,
                phase: .fenced,
                errorCode: "networkFenced",
                errorMessage: authority.state?.failureReason ?? "vmnet network is fenced"
            )
        case .rebootCommandRequested:
            return EventDescription(
                state: .degraded,
                phase: .rebootRequested,
                errorCode: "rebootRequested",
                errorMessage: "host reboot has been requested for vmnet recovery",
                rebootCommandResult: .requested
            )
        case .rebootCommandAccepted:
            return EventDescription(
                state: .degraded,
                phase: .rebootRequested,
                errorCode: "rebootPending",
                errorMessage: "the host accepted the vmnet recovery reboot command",
                rebootCommandResult: .accepted,
                rebootCommandAccepted: true
            )
        case .rebootCommandFailed(let message):
            return EventDescription(
                state: .failed,
                phase: .failed,
                errorCode: "rebootCommandFailed",
                errorMessage: message,
                rebootCommandResult: .failed,
                rebootCommandFailed: true
            )
        case .verificationStarted:
            return EventDescription(
                state: .degraded,
                phase: .verifying,
                errorCode: "verificationPending",
                errorMessage: "vmnet recovery is verifying a new host boot and network instance"
            )
        case .recovered:
            return EventDescription(
                state: .ready,
                phase: .healthy,
                rebootCommandResult: .recovered,
                recoverySucceeded: true
            )
        case .result(let result):
            return describe(result, authority: authority)
        }
    }

    private func describe(
        _ result: VMNetRecoveryCoordinatorResult,
        authority: AuthoritySnapshot
    ) -> EventDescription {
        switch result {
        case .disabled:
            return EventDescription(
                state: .failed,
                phase: .failed,
                errorCode: "recoveryDisabled",
                errorMessage: "vmnet recovery coordinator is disabled"
            )
        case .idle, .initialized:
            return EventDescription(state: .ready, phase: .healthy)
        case .recovered:
            return EventDescription(
                state: .ready,
                phase: .healthy,
                rebootCommandResult: .recovered,
                recoverySucceeded: true
            )
        case .rebootRequested:
            return EventDescription(
                state: .degraded,
                phase: .rebootRequested,
                errorCode: "rebootPending",
                errorMessage: "the host accepted the vmnet recovery reboot command",
                rebootCommandResult: .accepted,
                rebootCommandAccepted: true
            )
        case .waitingForReboot:
            return EventDescription(
                state: .degraded,
                phase: .waitingForReboot,
                errorCode: "rebootPending",
                errorMessage: "vmnet recovery is waiting for the requested host reboot",
                rebootCommandResult: .waiting
            )
        case .waitingForHealthyProbe(let attempt, let reason):
            return EventDescription(
                state: .degraded,
                phase: .probeDegraded,
                errorCode: "healthyProbeFailed",
                errorMessage: reason,
                consecutiveHealthyProbeFailures: attempt
            )
        case .waitingForVerification(let reason):
            let phase: VMNetRecoveryStatusPhase = authority.state == nil ? .initializing : .verifying
            return EventDescription(
                state: .degraded,
                phase: phase,
                errorCode: "verificationPending",
                errorMessage: reason
            )
        case .blocked(let reason):
            let errorCode = Self.blockedErrorCode(reason)
            return EventDescription(
                state: .failed,
                phase: .blocked,
                errorCode: errorCode,
                errorMessage: reason,
                rebootCommandResult: Self.isLoopProtectionError(errorCode) ? .blocked : nil,
                rebootCommandFailed: errorCode == "rebootCommandFailed"
            )
        }
    }

    private static func blockedErrorCode(_ reason: String) -> String {
        let normalized = reason.lowercased()
        if normalized.contains("reboot attempt budget") || normalized.contains("budget is exhausted") {
            return "rebootBudgetExhausted"
        }
        if normalized.contains("minimum reboot interval") || normalized.contains("interval has not elapsed") {
            return "rebootIntervalNotElapsed"
        }
        if normalized.contains("request is too old") {
            return "rebootRequestExpired"
        }
        if normalized.contains("verification timed out") {
            return "verificationTimedOut"
        }
        if normalized.contains("reboot command") || normalized.contains("host reboot command") {
            return "rebootCommandFailed"
        }
        if normalized.contains("pending vmnet recovery request is invalid") {
            return "invalidFenceRequest"
        }
        if normalized.contains("network does not match") || normalized.contains("network mismatch") {
            return "networkMismatch"
        }
        if normalized.contains("reconciliation failed") {
            return "reconciliationFailed"
        }
        return "recoveryBlocked"
    }

    private static func isLoopProtectionError(_ errorCode: String?) -> Bool {
        guard let errorCode else {
            return false
        }
        return [
            "rebootBudgetExhausted",
            "rebootIntervalNotElapsed",
            "rebootRequestExpired",
            "verificationTimedOut",
        ].contains(errorCode)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func expirationTimestamp(from updatedAt: Date, pollIntervalSeconds: Int) -> String {
        let maximumPeriodSeconds = Int(maximumVMNetRecoveryStatusFreshnessSeconds) / 4
        let boundedPeriodSeconds = max(0, min(pollIntervalSeconds, maximumPeriodSeconds))
        let freshnessSeconds = max(boundedPeriodSeconds * 4, minimumFreshnessSeconds)
        return timestamp(updatedAt.addingTimeInterval(TimeInterval(freshnessSeconds)))
    }

    private static func truncatedErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maximumVMNetRecoveryStatusErrorMessageSize else {
            return trimmed.isEmpty ? "unknown vmnet recovery error" : trimmed
        }
        var data = Data(trimmed.utf8.prefix(maximumVMNetRecoveryStatusErrorMessageSize))
        while String(data: data, encoding: .utf8) == nil, !data.isEmpty {
            data.removeLast()
        }
        return String(data: data, encoding: .utf8) ?? "unknown vmnet recovery error"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private struct AuthoritySnapshot {
        var state: VMNetRecoveryStateV1?
        var requestPending: Bool?
        var errorMessage: String?
    }

    private struct EventDescription {
        var state: VMNetRecoveryStatusState
        var phase: VMNetRecoveryStatusPhase
        var errorCode: String?
        var errorMessage: String?
        var rebootCommandResult: VMNetRecoveryRebootCommandResult?
        var consecutiveHealthyProbeFailures: Int
        var recoverySucceeded: Bool
        var rebootCommandAccepted: Bool
        var rebootCommandFailed: Bool

        init(
            state: VMNetRecoveryStatusState,
            phase: VMNetRecoveryStatusPhase,
            errorCode: String? = nil,
            errorMessage: String? = nil,
            rebootCommandResult: VMNetRecoveryRebootCommandResult? = nil,
            consecutiveHealthyProbeFailures: Int = 0,
            recoverySucceeded: Bool = false,
            rebootCommandAccepted: Bool = false,
            rebootCommandFailed: Bool = false
        ) {
            self.state = state
            self.phase = phase
            self.errorCode = errorCode
            self.errorMessage = errorMessage
            self.rebootCommandResult = rebootCommandResult
            self.consecutiveHealthyProbeFailures = consecutiveHealthyProbeFailures
            self.recoverySucceeded = recoverySucceeded
            self.rebootCommandAccepted = rebootCommandAccepted
            self.rebootCommandFailed = rebootCommandFailed
        }
    }
}

extension VMNetRecoveryStatusEvent {
    fileprivate var isStarting: Bool {
        if case .starting = self {
            return true
        }
        return false
    }

    fileprivate var isFenceObservation: Bool {
        if case .fenced = self {
            return true
        }
        return false
    }

    fileprivate var isReconcileResult: Bool {
        if case .result = self {
            return true
        }
        return false
    }
}

extension UInt64 {
    fileprivate mutating func incrementSaturating() {
        if self < .max {
            self += 1
        }
    }
}
