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
import Foundation

private let maximumVMNetRecoveryStatusErrorMessageSize = 4096
private let maximumVMNetRecoveryStatusFreshnessSeconds: TimeInterval = 3 * 24 * 60 * 60

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
    private let admissionRejectionCounter: VMNetRecoveryAdmissionRejectionCounter?
    private let now: @Sendable () -> Date
    private let coordinatorInstanceID: String

    init(
        store: any VMNetRecoveryStatusStoring,
        admissionRejectionCounter: VMNetRecoveryAdmissionRejectionCounter? = nil,
        coordinatorInstanceID: String = UUID().uuidString,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.admissionRejectionCounter = admissionRejectionCounter
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
        let sandboxRejectedTotal: UInt64?
        if let bootSessionID = normalizedCurrentBoot, let admissionRejectionCounter {
            let result = admissionRejectionCounter.consume(currentBootSessionID: bootSessionID)
            sandboxRejectedTotal = result.known ? result.total : nil
        } else {
            sandboxRejectedTotal = nil
        }
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
            sandboxRejectedTotal: sandboxRejectedTotal,
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
