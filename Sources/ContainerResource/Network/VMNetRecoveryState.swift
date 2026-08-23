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

public enum VMNetRecoveryPhase: String, Codable, Sendable, Equatable {
    case healthy
    case fenced
    case rebootRequested
    case verifying
}

/// Durable, node-wide recovery state for a vmnet network helper generation.
public struct VMNetRecoveryStateV1: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var networkName: String
    public var networkInstanceID: String?
    public var phase: VMNetRecoveryPhase
    public var failureReason: String?
    public var firstObservedAt: Date
    public var updatedAt: Date
    public var bootSessionID: String
    public var rebootAttempts: Int
    public var lastRebootRequestedAt: Date?

    public init(
        networkName: String,
        networkInstanceID: String?,
        phase: VMNetRecoveryPhase,
        failureReason: String?,
        firstObservedAt: Date,
        updatedAt: Date,
        bootSessionID: String,
        rebootAttempts: Int = 0,
        lastRebootRequestedAt: Date? = nil,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.networkName = networkName
        self.networkInstanceID = networkInstanceID
        self.phase = phase
        self.failureReason = failureReason
        self.firstObservedAt = firstObservedAt
        self.updatedAt = updatedAt
        self.bootSessionID = bootSessionID
        self.rebootAttempts = rebootAttempts
        self.lastRebootRequestedAt = lastRebootRequestedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case networkName
        case networkInstanceID
        case phase
        case failureReason
        case firstObservedAt
        case updatedAt
        case bootSessionID
        case rebootAttempts
        case lastRebootRequestedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported vmnet recovery state schema version \(schemaVersion)"
            )
        }
        networkName = try container.decode(String.self, forKey: .networkName)
        networkInstanceID = try container.decodeIfPresent(String.self, forKey: .networkInstanceID)
        phase = try container.decode(VMNetRecoveryPhase.self, forKey: .phase)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        firstObservedAt = try container.decode(Date.self, forKey: .firstObservedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? firstObservedAt
        bootSessionID = try container.decode(String.self, forKey: .bootSessionID)
        rebootAttempts = try container.decodeIfPresent(Int.self, forKey: .rebootAttempts) ?? 0
        lastRebootRequestedAt = try container.decodeIfPresent(Date.self, forKey: .lastRebootRequestedAt)
    }
}

public enum VMNetRecoveryStateError: Error, Sendable, Equatable, CustomStringConvertible {
    case stateMissing(networkName: String)
    case networkMismatch(expected: String, actual: String)
    case admissionFenced(networkName: String, phase: VMNetRecoveryPhase)
    case bootSessionMismatch(expected: String, actual: String)
    case staleNetworkInstance(expected: String, actual: String)
    case invalidTransition(from: VMNetRecoveryPhase, to: VMNetRecoveryPhase)
    case bootSessionDidNotChange
    case rebootAttemptBudgetExhausted
    case rebootRequestTooOld
    case rebootIntervalNotElapsed
    case requestWriterMismatch(expected: UInt32, actual: UInt32)
    case invalidValue(String)
    case io(String)

    public var description: String {
        switch self {
        case .stateMissing(let networkName):
            return "vmnet recovery state is missing for network \(networkName)"
        case .networkMismatch(let expected, let actual):
            return "vmnet recovery network mismatch: expected \(expected), got \(actual)"
        case .admissionFenced(let networkName, let phase):
            return "vmnet network \(networkName) is fenced for recovery in phase \(phase.rawValue)"
        case .bootSessionMismatch(let expected, let actual):
            return "vmnet recovery boot session mismatch: expected \(expected), got \(actual)"
        case .staleNetworkInstance(let expected, let actual):
            return "vmnet network instance mismatch: expected \(expected), got \(actual)"
        case .invalidTransition(let from, let to):
            return "invalid vmnet recovery transition \(from.rawValue) -> \(to.rawValue)"
        case .bootSessionDidNotChange:
            return "host boot session has not changed since the vmnet failure"
        case .rebootAttemptBudgetExhausted:
            return "vmnet recovery reboot attempt budget is exhausted"
        case .rebootRequestTooOld:
            return "vmnet recovery request is too old for an automatic reboot"
        case .rebootIntervalNotElapsed:
            return "vmnet recovery minimum reboot interval has not elapsed"
        case .requestWriterMismatch(let expected, let actual):
            return "vmnet recovery request writer mismatch: expected uid \(expected), got \(actual)"
        case .invalidValue(let message):
            return message
        case .io(let message):
            return message
        }
    }
}

public enum VMNetBootSession {
    public static func current() throws -> String {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            throw VMNetRecoveryStateError.io("failed to query kern.bootsessionuuid")
        }

        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            throw VMNetRecoveryStateError.io("failed to read kern.bootsessionuuid")
        }
        let value = String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else {
            throw VMNetRecoveryStateError.io("kern.bootsessionuuid returned an empty value")
        }
        return value
        #else
        throw VMNetRecoveryStateError.io("vmnet recovery boot sessions are only supported on macOS")
        #endif
    }
}

/// Cross-process state store guarded by an advisory file lock. All mutations
/// use an atomic replacement while holding the exclusive lock.
public struct VMNetRecoveryStateStore: Sendable {
    public let stateURL: URL
    public let lockURL: URL

    public init(path: String) {
        self.init(stateURL: URL(fileURLWithPath: path))
    }

    public init(stateURL: URL) {
        self.stateURL = stateURL
        self.lockURL = stateURL.appendingPathExtension("lock")
    }

    public func load() throws -> VMNetRecoveryStateV1? {
        let descriptor = open(lockURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT, try pathIsMissing(stateURL) {
                return nil
            }
            throw VMNetRecoveryStateError.io("failed to open vmnet recovery lock for reading: errno \(errno)")
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_SH) == 0 else {
            throw VMNetRecoveryStateError.io("failed to lock vmnet recovery state for reading: errno \(errno)")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try loadUnlocked()
    }

    @discardableResult
    public func recordHealthyObservation(
        networkName: String,
        networkInstanceID: String?,
        bootSessionID: String,
        attemptWindow: TimeInterval = 3600,
        now: Date = Date()
    ) throws -> VMNetRecoveryStateV1 {
        try validateIdentity(networkName: networkName, bootSessionID: bootSessionID)
        guard let observedInstanceID = normalized(networkInstanceID) else {
            throw VMNetRecoveryStateError.invalidValue("vmnet network instance id is required")
        }
        guard attemptWindow >= 0 else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery attempt window must not be negative")
        }
        return try withExclusiveLock {
            if let current = try loadUnlocked() {
                guard current.networkName == networkName else {
                    throw VMNetRecoveryStateError.networkMismatch(
                        expected: networkName,
                        actual: current.networkName
                    )
                }
                guard current.phase == .healthy else {
                    return current
                }
                if normalized(current.networkInstanceID) == observedInstanceID,
                    current.bootSessionID == bootSessionID
                {
                    return current
                }

                let preserveAttemptWindow =
                    current.rebootAttempts > 0
                    && now.timeIntervalSince(current.firstObservedAt) <= attemptWindow
                if current.bootSessionID == bootSessionID,
                    normalized(current.networkInstanceID) != nil
                {
                    var fenced = current
                    fenced.networkInstanceID = observedInstanceID
                    fenced.phase = .fenced
                    fenced.failureReason = "vmnet network instance changed without host reboot"
                    fenced.updatedAt = now
                    if !preserveAttemptWindow {
                        fenced.firstObservedAt = now
                        fenced.rebootAttempts = 0
                        fenced.lastRebootRequestedAt = nil
                    }
                    try writeUnlocked(fenced)
                    return fenced
                }

                let state = VMNetRecoveryStateV1(
                    networkName: networkName,
                    networkInstanceID: observedInstanceID,
                    phase: .healthy,
                    failureReason: nil,
                    firstObservedAt: preserveAttemptWindow ? current.firstObservedAt : now,
                    updatedAt: now,
                    bootSessionID: bootSessionID,
                    rebootAttempts: preserveAttemptWindow ? current.rebootAttempts : 0,
                    lastRebootRequestedAt: preserveAttemptWindow ? current.lastRebootRequestedAt : nil
                )
                try writeUnlocked(state)
                return state
            }

            let state = VMNetRecoveryStateV1(
                networkName: networkName,
                networkInstanceID: observedInstanceID,
                phase: .healthy,
                failureReason: nil,
                firstObservedAt: now,
                updatedAt: now,
                bootSessionID: bootSessionID,
                rebootAttempts: 0
            )
            try writeUnlocked(state)
            return state
        }
    }

    @discardableResult
    public func recordFence(
        networkName: String,
        networkInstanceID: String?,
        failureReason: String,
        bootSessionID: String,
        attemptWindow: TimeInterval,
        now: Date = Date()
    ) throws -> VMNetRecoveryStateV1 {
        try validateIdentity(networkName: networkName, bootSessionID: bootSessionID)
        let reason = failureReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery failure reason is required")
        }
        guard attemptWindow >= 0 else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery attempt window must not be negative")
        }
        let observedInstanceID = normalized(networkInstanceID)

        return try withExclusiveLock {
            let previous = try loadUnlocked()
            if let current = previous {
                guard current.networkName == networkName else {
                    throw VMNetRecoveryStateError.networkMismatch(
                        expected: networkName,
                        actual: current.networkName
                    )
                }
                if current.phase != .healthy {
                    return current
                }
                if let currentInstanceID = normalized(current.networkInstanceID),
                    let observedInstanceID,
                    currentInstanceID != observedInstanceID
                {
                    return current
                }
            }

            let preserveAttemptWindow =
                previous.map {
                    $0.rebootAttempts > 0
                        && now.timeIntervalSince($0.firstObservedAt) <= attemptWindow
                } ?? false
            let state = VMNetRecoveryStateV1(
                networkName: networkName,
                networkInstanceID: observedInstanceID ?? previous.flatMap { normalized($0.networkInstanceID) },
                phase: .fenced,
                failureReason: reason,
                firstObservedAt: preserveAttemptWindow ? previous!.firstObservedAt : now,
                updatedAt: now,
                bootSessionID: bootSessionID,
                rebootAttempts: preserveAttemptWindow ? previous!.rebootAttempts : 0,
                lastRebootRequestedAt: preserveAttemptWindow ? previous!.lastRebootRequestedAt : nil
            )
            try writeUnlocked(state)
            return state
        }
    }

    public func requireHealthy(
        networkName: String,
        expectedNetworkInstanceID: String? = nil,
        expectedBootSessionID: String? = nil
    ) throws {
        guard let state = try load() else {
            throw VMNetRecoveryStateError.stateMissing(networkName: networkName)
        }
        guard state.networkName == networkName else {
            throw VMNetRecoveryStateError.networkMismatch(
                expected: networkName,
                actual: state.networkName
            )
        }
        guard state.phase == .healthy else {
            throw VMNetRecoveryStateError.admissionFenced(networkName: networkName, phase: state.phase)
        }
        if let expectedBootSessionID = normalized(expectedBootSessionID) {
            let actualBootSessionID = normalized(state.bootSessionID) ?? state.bootSessionID
            guard actualBootSessionID == expectedBootSessionID else {
                throw VMNetRecoveryStateError.bootSessionMismatch(
                    expected: expectedBootSessionID,
                    actual: actualBootSessionID
                )
            }
        }
        if let actual = normalized(expectedNetworkInstanceID) {
            guard let expected = normalized(state.networkInstanceID), expected == actual else {
                throw VMNetRecoveryStateError.staleNetworkInstance(
                    expected: normalized(state.networkInstanceID) ?? "a published network instance",
                    actual: actual
                )
            }
        }
    }

    @discardableResult
    public func requestReboot(
        networkName: String,
        currentBootSessionID: String,
        maxAttempts: Int,
        minimumInterval: TimeInterval,
        maximumRequestAge: TimeInterval,
        now: Date = Date()
    ) throws -> VMNetRecoveryStateV1 {
        guard maxAttempts > 0 else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery max attempts must be greater than zero")
        }
        guard minimumInterval >= 0 else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery minimum reboot interval must not be negative")
        }
        guard maximumRequestAge >= 0 else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery maximum request age must not be negative")
        }
        return try withExclusiveLock {
            guard var current = try loadUnlocked(), current.networkName == networkName else {
                throw VMNetRecoveryStateError.invalidValue("vmnet recovery state does not match network \(networkName)")
            }
            guard current.phase == .fenced || current.phase == .rebootRequested else {
                throw VMNetRecoveryStateError.invalidTransition(from: current.phase, to: .rebootRequested)
            }
            guard current.bootSessionID == currentBootSessionID else {
                throw VMNetRecoveryStateError.bootSessionDidNotChange
            }
            let requestAge = now.timeIntervalSince(current.updatedAt)
            guard requestAge >= 0, requestAge <= maximumRequestAge else {
                throw VMNetRecoveryStateError.rebootRequestTooOld
            }
            if current.phase == .rebootRequested,
                let lastRequest = current.lastRebootRequestedAt,
                now.timeIntervalSince(lastRequest) < minimumInterval
            {
                throw VMNetRecoveryStateError.rebootIntervalNotElapsed
            }
            guard current.rebootAttempts < maxAttempts else {
                throw VMNetRecoveryStateError.rebootAttemptBudgetExhausted
            }
            if current.phase == .fenced,
                let lastRequest = current.lastRebootRequestedAt,
                now.timeIntervalSince(lastRequest) < minimumInterval
            {
                throw VMNetRecoveryStateError.rebootIntervalNotElapsed
            }

            current.phase = .rebootRequested
            current.rebootAttempts += 1
            current.lastRebootRequestedAt = now
            current.updatedAt = now
            try writeUnlocked(current)
            return current
        }
    }

    @discardableResult
    public func beginVerification(
        networkName: String,
        currentBootSessionID: String,
        now: Date = Date()
    ) throws -> VMNetRecoveryStateV1 {
        try withExclusiveLock {
            guard var current = try loadUnlocked(), current.networkName == networkName else {
                throw VMNetRecoveryStateError.invalidValue("vmnet recovery state does not match network \(networkName)")
            }
            guard current.phase == .fenced || current.phase == .rebootRequested else {
                if current.phase == .verifying {
                    return current
                }
                throw VMNetRecoveryStateError.invalidTransition(from: current.phase, to: .verifying)
            }
            guard current.bootSessionID != currentBootSessionID else {
                throw VMNetRecoveryStateError.bootSessionDidNotChange
            }
            current.phase = .verifying
            current.updatedAt = now
            try writeUnlocked(current)
            return current
        }
    }

    @discardableResult
    public func completeVerification(
        networkName: String,
        networkInstanceID: String,
        currentBootSessionID: String,
        now: Date = Date()
    ) throws -> VMNetRecoveryStateV1 {
        guard let instanceID = normalized(networkInstanceID) else {
            throw VMNetRecoveryStateError.invalidValue("verified vmnet network instance id is required")
        }
        return try withExclusiveLock {
            guard let current = try loadUnlocked(), current.networkName == networkName else {
                throw VMNetRecoveryStateError.invalidValue("vmnet recovery state does not match network \(networkName)")
            }
            guard current.phase == .verifying else {
                throw VMNetRecoveryStateError.invalidTransition(from: current.phase, to: .healthy)
            }
            guard current.bootSessionID != currentBootSessionID else {
                throw VMNetRecoveryStateError.bootSessionDidNotChange
            }
            if let failedInstanceID = normalized(current.networkInstanceID), failedInstanceID == instanceID {
                throw VMNetRecoveryStateError.staleNetworkInstance(expected: "a new network instance", actual: instanceID)
            }

            let state = VMNetRecoveryStateV1(
                networkName: networkName,
                networkInstanceID: instanceID,
                phase: .healthy,
                failureReason: nil,
                firstObservedAt: current.firstObservedAt,
                updatedAt: now,
                bootSessionID: currentBootSessionID,
                rebootAttempts: current.rebootAttempts,
                lastRebootRequestedAt: current.lastRebootRequestedAt
            )
            try writeUnlocked(state)
            return state
        }
    }

    public func remove() throws {
        try withExclusiveLock {
            guard FileManager.default.fileExists(atPath: stateURL.path) else {
                return
            }
            do {
                try FileManager.default.removeItem(at: stateURL)
            } catch {
                throw VMNetRecoveryStateError.io("failed to remove vmnet recovery state: \(error)")
            }
        }
    }

    private func validateIdentity(networkName: String, bootSessionID: String) throws {
        guard !networkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery network name is required")
        }
        guard !bootSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery boot session id is required")
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private func loadUnlocked() throws -> VMNetRecoveryStateV1? {
        let descriptor = open(stateURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw VMNetRecoveryStateError.io("failed to open vmnet recovery state: errno \(errno)")
        }
        defer { close(descriptor) }
        do {
            let data = try readVMNetRecoveryRegularFile(
                descriptor: descriptor,
                maximumSize: 64 * 1024,
                description: "vmnet recovery state"
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(VMNetRecoveryStateV1.self, from: data)
        } catch {
            throw VMNetRecoveryStateError.io("failed to read vmnet recovery state: \(error)")
        }
    }

    private func writeUnlocked(_ state: VMNetRecoveryStateV1) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            guard chmod(stateURL.path, mode_t(0o600)) == 0 else {
                throw VMNetRecoveryStateError.io("failed to set vmnet recovery state permissions: errno \(errno)")
            }
        } catch let error as VMNetRecoveryStateError {
            throw error
        } catch {
            throw VMNetRecoveryStateError.io("failed to write vmnet recovery state: \(error)")
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw VMNetRecoveryStateError.io("failed to create vmnet recovery state directory: \(error)")
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw VMNetRecoveryStateError.io("failed to open vmnet recovery lock: errno \(errno)")
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw VMNetRecoveryStateError.io("failed to lock vmnet recovery state: errno \(errno)")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func pathIsMissing(_ url: URL) throws -> Bool {
        var information = stat()
        if lstat(url.path, &information) == 0 {
            return false
        }
        if errno == ENOENT {
            return true
        }
        throw VMNetRecoveryStateError.io("failed to inspect vmnet recovery state: errno \(errno)")
    }
}

extension ContainerConfiguration.MacOSGuestOptions {
    public func requireVMNetRecoveryAdmission(
        networkName: String,
        expectedNetworkInstanceID: String? = nil
    ) throws {
        guard vmnetDisconnectRecovery == .rebootNode else {
            return
        }
        try vmnetRecoveryRequestStore().requireNoPendingRequest(networkName: networkName)
        let store = try vmnetRecoveryStateStore()
        try store.requireHealthy(
            networkName: networkName,
            expectedNetworkInstanceID: expectedNetworkInstanceID,
            expectedBootSessionID: try vmnetRecoveryBootSession()
        )
    }

    public func validateObservedVMNetInstance(
        networkName: String,
        networkInstanceID: String?
    ) throws {
        guard vmnetDisconnectRecovery == .rebootNode else {
            return
        }
        let requestStore = try vmnetRecoveryRequestStore()
        try requestStore.requireNoPendingRequest(networkName: networkName)
        let store = try vmnetRecoveryStateStore()
        let bootSessionID = try vmnetRecoveryBootSession()
        do {
            try store.requireHealthy(
                networkName: networkName,
                expectedNetworkInstanceID: networkInstanceID,
                expectedBootSessionID: bootSessionID
            )
        } catch let error as VMNetRecoveryStateError {
            if case .staleNetworkInstance = error {
                try requestStore.submit(
                    networkName: networkName,
                    networkInstanceID: networkInstanceID,
                    failureReason: "vmnet network instance changed without host reboot",
                    bootSessionID: bootSessionID
                )
            }
            throw error
        }
    }

    public func recordVMNetRecoveryFence(
        networkName: String,
        networkInstanceID: String?,
        failureReason: String
    ) throws {
        guard vmnetDisconnectRecovery == .rebootNode else {
            return
        }
        try vmnetRecoveryRequestStore().submit(
            networkName: networkName,
            networkInstanceID: networkInstanceID,
            failureReason: failureReason,
            bootSessionID: try vmnetRecoveryBootSession()
        )
    }

    private func vmnetRecoveryStateStore() throws -> VMNetRecoveryStateStore {
        guard let path = vmnetRecoveryStatePath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            path.hasPrefix("/")
        else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery state path is not configured")
        }
        return VMNetRecoveryStateStore(path: path)
    }

    private func vmnetRecoveryRequestStore() throws -> VMNetRecoveryRequestStore {
        guard let path = vmnetRecoveryRequestPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            path.hasPrefix("/")
        else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery request path is not configured")
        }
        return VMNetRecoveryRequestStore(path: path)
    }

    private func vmnetRecoveryBootSession() throws -> String {
        guard let bootSessionID = vmnetRecoveryBootSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bootSessionID.isEmpty
        else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery boot session id is not configured")
        }
        return bootSessionID
    }
}
