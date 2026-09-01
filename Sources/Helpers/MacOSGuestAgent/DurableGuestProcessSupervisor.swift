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

import CryptoKit
import Darwin
import Foundation
import RuntimeMacOSSidecarShared

struct GuestProcessAttachmentHandle: Sendable, Equatable {
    let executionID: String
    let token: UUID
}

private struct DurableGuestProcessLaunchSpec: Codable, Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let rootDirectory: String?
    let workingDirectory: String?
    let terminal: Bool
    let uid: UInt32
    let gid: UInt32
    let supplementalGroups: [UInt32]

    init(frame: GuestAgentFrame) throws {
        guard let executable = frame.executable else {
            throw durableProcessError(code: EINVAL, message: "missing executable")
        }
        let identity = try GuestAgentExecIdentity.resolve(from: frame) ?? .currentProcess()
        self.executable = executable
        self.arguments = frame.arguments ?? []
        self.environment = frame.environment ?? []
        self.rootDirectory = frame.rootDirectory
        self.workingDirectory = frame.workingDirectory
        self.terminal = frame.terminal == true
        self.uid = UInt32(identity.uid)
        self.gid = UInt32(identity.gid)
        self.supplementalGroups = identity.supplementalGroups.map { UInt32($0) }.sorted()
    }

    var identity: GuestAgentExecIdentity {
        .init(
            uid: uid_t(uid),
            gid: gid_t(gid),
            supplementalGroups: supplementalGroups.map { gid_t($0) }
        )
    }

    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct DurableGuestProcessEvent: Sendable {
    enum Kind: Sendable {
        case stdout
        case stderr
        case exit
    }

    let sequence: UInt64
    let kind: Kind
    let data: Data?
    let exitCode: Int32?

    var retainedByteCount: Int {
        (data?.count ?? 0) + 32
    }

    func frame(executionID: String) -> GuestAgentFrame {
        switch kind {
        case .stdout:
            return .stdout(id: executionID, sequence: sequence, data: data ?? Data())
        case .stderr:
            return .stderr(id: executionID, sequence: sequence, data: data ?? Data())
        case .exit:
            return .exit(id: executionID, sequence: sequence, code: exitCode ?? 1)
        }
    }
}

private struct DurableGuestProcessAttachmentRequest: Sendable {
    let expectedLaunchFingerprint: String?
    let trustedLaunchFingerprint: String?
    let incarnation: String?
    let storageGeneration: UInt64?
    let previousStorageGeneration: UInt64?

    init(frame: GuestAgentFrame) throws {
        self.expectedLaunchFingerprint = frame.expectedLaunchFingerprint
        self.trustedLaunchFingerprint = frame.trustedLaunchFingerprint
        self.incarnation = frame.incarnation
        self.storageGeneration = frame.storageGeneration
        self.previousStorageGeneration = frame.previousStorageGeneration

        if let expectedLaunchFingerprint, expectedLaunchFingerprint.isEmpty {
            throw durableProcessError(code: EINVAL, message: "expected launch fingerprint must not be empty")
        }
        if let trustedLaunchFingerprint, trustedLaunchFingerprint.isEmpty {
            throw durableProcessError(code: EINVAL, message: "trusted launch fingerprint must not be empty")
        }
        if let incarnation, incarnation.isEmpty {
            throw durableProcessError(code: EINVAL, message: "process incarnation must not be empty")
        }
        if let storageGeneration, storageGeneration == 0 {
            throw durableProcessError(code: EINVAL, message: "storage generation must be positive")
        }
        if let previousStorageGeneration, previousStorageGeneration == 0 {
            throw durableProcessError(code: EINVAL, message: "previous storage generation must be positive")
        }
        if previousStorageGeneration != nil, storageGeneration == nil {
            throw durableProcessError(code: EINVAL, message: "generation adoption requires a current storage generation")
        }
        if (trustedLaunchFingerprint == nil) != (incarnation == nil) {
            throw durableProcessError(
                code: EINVAL,
                message: "trusted launch fingerprint and incarnation must be supplied together"
            )
        }
    }

    var isLegacy: Bool {
        expectedLaunchFingerprint == nil && trustedLaunchFingerprint == nil && incarnation == nil && storageGeneration == nil
            && previousStorageGeneration == nil
    }

    func forCreateOrRetry(launchFingerprint: String) throws -> Self {
        guard previousStorageGeneration == nil else {
            throw durableProcessError(code: EINVAL, message: "new execution cannot adopt a previous storage generation")
        }
        if let expectedLaunchFingerprint, expectedLaunchFingerprint != launchFingerprint {
            throw durableProcessError(code: ESTALE, message: "new execution launch fingerprint does not match request")
        }
        if !isLegacy, expectedLaunchFingerprint == nil {
            return .init(
                expectedLaunchFingerprint: launchFingerprint,
                trustedLaunchFingerprint: trustedLaunchFingerprint,
                incarnation: incarnation,
                storageGeneration: storageGeneration,
                previousStorageGeneration: nil
            )
        }
        return self
    }

    private init(
        expectedLaunchFingerprint: String?,
        trustedLaunchFingerprint: String?,
        incarnation: String?,
        storageGeneration: UInt64?,
        previousStorageGeneration: UInt64?
    ) {
        self.expectedLaunchFingerprint = expectedLaunchFingerprint
        self.trustedLaunchFingerprint = trustedLaunchFingerprint
        self.incarnation = incarnation
        self.storageGeneration = storageGeneration
        self.previousStorageGeneration = previousStorageGeneration
    }
}

private struct DeletedGuestProcessIncarnation: Sendable {
    let trustedLaunchFingerprint: String
    let guestLaunchFingerprint: String?
    let incarnation: String
    let storageGeneration: UInt64?

    func matches(_ request: DurableGuestProcessDeleteRequest) -> Bool {
        trustedLaunchFingerprint == request.trustedLaunchFingerprint
            && incarnation == request.incarnation
            && storageGeneration == request.storageGeneration
            && (guestLaunchFingerprint == nil || request.expectedLaunchFingerprint == nil
                || guestLaunchFingerprint == request.expectedLaunchFingerprint)
    }
}

private struct DurableGuestProcessDeleteRequest: Sendable {
    let executionID: String
    let expectedLaunchFingerprint: String?
    let trustedLaunchFingerprint: String
    let incarnation: String
    let storageGeneration: UInt64?

    init(frame: GuestAgentFrame) throws {
        guard let executionID = frame.id, !executionID.isEmpty else {
            throw durableProcessError(code: EINVAL, message: "durable delete is missing execution identifier")
        }
        guard let trustedLaunchFingerprint = frame.trustedLaunchFingerprint, !trustedLaunchFingerprint.isEmpty else {
            throw durableProcessError(code: EINVAL, message: "durable delete is missing trusted launch fingerprint")
        }
        guard let incarnation = frame.incarnation, !incarnation.isEmpty else {
            throw durableProcessError(code: EINVAL, message: "durable delete is missing process incarnation")
        }
        if let storageGeneration = frame.storageGeneration, storageGeneration == 0 {
            throw durableProcessError(code: EINVAL, message: "durable delete storage generation must be positive")
        }
        if let expectedLaunchFingerprint = frame.expectedLaunchFingerprint, expectedLaunchFingerprint.isEmpty {
            throw durableProcessError(code: EINVAL, message: "durable delete guest launch fingerprint must not be empty")
        }
        self.executionID = executionID
        self.expectedLaunchFingerprint = frame.expectedLaunchFingerprint
        self.trustedLaunchFingerprint = trustedLaunchFingerprint
        self.incarnation = incarnation
        self.storageGeneration = frame.storageGeneration
    }

    var tombstone: DeletedGuestProcessIncarnation {
        .init(
            trustedLaunchFingerprint: trustedLaunchFingerprint,
            guestLaunchFingerprint: expectedLaunchFingerprint,
            incarnation: incarnation,
            storageGeneration: storageGeneration
        )
    }
}

final class GuestProcessSupervisor: @unchecked Sendable {
    static let shared = GuestProcessSupervisor()

    private let lock = NSLock()
    private let replayByteLimit: Int
    private let attachmentWriteTimeout: TimeInterval
    private let beforeCreateLock: (@Sendable () -> Void)?
    private let afterPendingHandoffPublication: (@Sendable (MacOSGuestProcessDisposition) -> Void)?
    private let beforeEventAppendBarrier: (@Sendable () -> Void)?
    private let afterAttachmentAcknowledgement: (@Sendable (MacOSGuestProcessDisposition) -> Void)?
    private var processes: [String: DurableGuestProcess] = [:]
    private var lifecycleLocks: [String: NSLock] = [:]
    // Retained for the guest-agent/VM lifetime. Incarnations are never silently
    // collected because doing so could let a delayed pre-delete start revive.
    private var deletedIncarnations: [String: [String: DeletedGuestProcessIncarnation]] = [:]

    init(
        replayByteLimit: Int = 1024 * 1024,
        attachmentWriteTimeout: TimeInterval = 3,
        beforeCreateLock: (@Sendable () -> Void)? = nil,
        afterPendingHandoffPublication: (@Sendable (MacOSGuestProcessDisposition) -> Void)? = nil,
        beforeEventAppendBarrier: (@Sendable () -> Void)? = nil,
        afterAttachmentAcknowledgement: (@Sendable (MacOSGuestProcessDisposition) -> Void)? = nil
    ) {
        self.replayByteLimit = max(replayByteLimit, 64)
        self.attachmentWriteTimeout = max(attachmentWriteTimeout, 0.05)
        self.beforeCreateLock = beforeCreateLock
        self.afterPendingHandoffPublication = afterPendingHandoffPublication
        self.beforeEventAppendBarrier = beforeEventAppendBarrier
        self.afterAttachmentAcknowledgement = afterAttachmentAcknowledgement
    }

    func createAndAttach(
        frame: GuestAgentFrame,
        connection: AgentConnection,
        cursor: UInt64
    ) throws -> GuestProcessAttachmentHandle {
        let executionID = try requireExecutionID(frame.id)
        let spec = try DurableGuestProcessLaunchSpec(frame: frame)
        let fingerprint = try spec.fingerprint()
        let requestedAttachment = try DurableGuestProcessAttachmentRequest(frame: frame)

        let process: DurableGuestProcess
        let disposition: MacOSGuestProcessDisposition
        let attachmentRequest: DurableGuestProcessAttachmentRequest
        beforeCreateLock?()
        let lifecycleLock = lifecycleLock(for: executionID)
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        if let incarnation = requestedAttachment.incarnation,
            deletedIncarnations[executionID]?[incarnation] != nil
        {
            lock.unlock()
            throw durableProcessError(
                code: ESTALE,
                message: "execution \(executionID) incarnation \(incarnation) was already deleted"
            )
        }
        if let existing = processes[executionID] {
            guard existing.matches(spec: spec) else {
                let existingFingerprint = existing.launchFingerprint
                lock.unlock()
                throw durableProcessError(
                    code: EEXIST,
                    message:
                        "execution \(executionID) launch specification conflicts with existing fingerprint \(existingFingerprint)"
                )
            }
            process = existing
            disposition = .existing
            attachmentRequest = requestedAttachment
            lock.unlock()
        } else {
            guard cursor == 0 else {
                lock.unlock()
                throw durableProcessError(
                    code: EINVAL,
                    message: "new execution \(executionID) requires replay cursor 0"
                )
            }
            do {
                attachmentRequest = try requestedAttachment.forCreateOrRetry(launchFingerprint: fingerprint)
            } catch {
                lock.unlock()
                throw error
            }
            let created = DurableGuestProcess(
                executionID: executionID,
                launchSpec: spec,
                launchFingerprint: fingerprint,
                trustedLaunchFingerprint: attachmentRequest.trustedLaunchFingerprint,
                incarnation: attachmentRequest.incarnation,
                storageGeneration: attachmentRequest.storageGeneration,
                replayByteLimit: replayByteLimit,
                attachmentWriteTimeout: attachmentWriteTimeout,
                afterPendingHandoffPublication: afterPendingHandoffPublication,
                beforeEventAppendBarrier: beforeEventAppendBarrier,
                afterAttachmentAcknowledgement: afterAttachmentAcknowledgement
            )
            let session: SpawnedProcessSession
            do {
                session = try SpawnedProcessSession.spawn(
                    executable: spec.executable,
                    arguments: spec.arguments,
                    environment: spec.environment,
                    rootDirectory: spec.rootDirectory,
                    workingDirectory: spec.workingDirectory,
                    terminal: spec.terminal,
                    identity: spec.identity,
                    eventSink: created
                )
                created.install(session: session)
                processes[executionID] = created
                try session.start(stdoutHandle: nil, stderrHandle: nil)
                process = created
                disposition = .created
                lock.unlock()
            } catch {
                if processes[executionID] === created {
                    processes.removeValue(forKey: executionID)
                }
                lock.unlock()
                created.forceDelete()
                throw error
            }
        }

        return try process.attach(
            connection: connection,
            cursor: cursor,
            disposition: disposition,
            request: attachmentRequest
        )
    }

    func inspect(executionID rawExecutionID: String?) throws -> MacOSGuestProcessStatusPayload {
        let executionID = try requireExecutionID(rawExecutionID)
        return try process(executionID: executionID).status(disposition: .inspected)
    }

    func attach(
        frame: GuestAgentFrame,
        connection: AgentConnection,
        cursor: UInt64
    ) throws -> GuestProcessAttachmentHandle {
        let executionID = try requireExecutionID(frame.id)
        let lifecycleLock = lifecycleLock(for: executionID)
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return try process(executionID: executionID).attach(
            connection: connection,
            cursor: cursor,
            disposition: .attached,
            request: try DurableGuestProcessAttachmentRequest(frame: frame)
        )
    }

    func detach(_ handle: GuestProcessAttachmentHandle) {
        processIfPresent(executionID: handle.executionID)?.detach(handle: handle)
    }

    func acknowledgeEvents(through sequence: UInt64, handle: GuestProcessAttachmentHandle) throws {
        try process(executionID: handle.executionID).acknowledgeEvents(through: sequence, handle: handle)
    }

    func writeStdin(_ data: Data, handle: GuestProcessAttachmentHandle) throws {
        try process(executionID: handle.executionID).writeStdin(data, handle: handle)
    }

    func closeStdin(handle: GuestProcessAttachmentHandle) throws {
        try process(executionID: handle.executionID).closeStdin(handle: handle)
    }

    func sendSignal(_ signal: Int32, handle: GuestProcessAttachmentHandle) throws {
        try process(executionID: handle.executionID).sendSignal(signal, handle: handle)
    }

    func resize(width: UInt16, height: UInt16, handle: GuestProcessAttachmentHandle) throws {
        try process(executionID: handle.executionID).resize(width: width, height: height, handle: handle)
    }

    func stop(
        signal: Int32,
        handle: GuestProcessAttachmentHandle,
        acknowledge: (MacOSGuestProcessStatusPayload) throws -> Void
    ) throws {
        guard signal > 0 else {
            throw durableProcessError(code: EINVAL, message: "stop requires a non-zero signal")
        }
        let process = try process(executionID: handle.executionID)
        try process.stop(signal: signal, handle: handle, acknowledge: acknowledge)
    }

    func delete(handle: GuestProcessAttachmentHandle) throws -> MacOSGuestProcessStatusPayload {
        let lifecycleLock = lifecycleLock(for: handle.executionID)
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let process = try process(executionID: handle.executionID)
        let deletedIdentity = process.deletionIdentity()
        let status = try process.delete(handle: handle)

        lock.lock()
        if processes[handle.executionID] === process {
            processes.removeValue(forKey: handle.executionID)
            if let deletedIdentity {
                deletedIncarnations[handle.executionID, default: [:]][deletedIdentity.incarnation] = deletedIdentity
            }
        }
        lock.unlock()
        return status
    }

    /// Atomically deletes the matching process or records a tombstone when it
    /// is already absent. This closes the inspect-ENOENT/start replay window.
    func deleteOrTombstone(frame: GuestAgentFrame) throws -> MacOSGuestProcessStatusPayload? {
        let request = try DurableGuestProcessDeleteRequest(frame: frame)
        let lifecycleLock = lifecycleLock(for: request.executionID)
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let process: DurableGuestProcess?
        let cleanup: SpawnedProcessSession?
        let status: MacOSGuestProcessStatusPayload?

        lock.lock()
        if let existingTombstone = deletedIncarnations[request.executionID]?[request.incarnation] {
            guard existingTombstone.matches(request) else {
                lock.unlock()
                throw durableProcessError(code: ESTALE, message: "durable delete identity conflicts with an existing tombstone")
            }
            lock.unlock()
            return nil
        }

        process = processes[request.executionID]
        if let process {
            if process.deletionIdentity()?.incarnation != request.incarnation {
                deletedIncarnations[request.executionID, default: [:]][request.incarnation] = request.tombstone
                lock.unlock()
                return nil
            }
            do {
                let committed = try process.commitDelete(request: request)
                status = committed.status
                cleanup = committed.session
            } catch {
                lock.unlock()
                throw error
            }
            processes.removeValue(forKey: request.executionID)
        } else {
            status = nil
            cleanup = nil
        }
        deletedIncarnations[request.executionID, default: [:]][request.incarnation] = request.tombstone
        lock.unlock()

        cleanup?.cleanup()
        return status
    }

    func removeAllForTesting() {
        let values: [DurableGuestProcess]
        lock.lock()
        values = Array(processes.values)
        processes.removeAll()
        deletedIncarnations.removeAll()
        lock.unlock()
        for process in values {
            process.forceDelete()
        }
    }

    private func process(executionID: String) throws -> DurableGuestProcess {
        guard let process = processIfPresent(executionID: executionID) else {
            throw durableProcessError(code: ENOENT, message: "execution \(executionID) not found")
        }
        return process
    }

    private func processIfPresent(executionID: String) -> DurableGuestProcess? {
        lock.lock()
        let process = processes[executionID]
        lock.unlock()
        return process
    }

    private func lifecycleLock(for executionID: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = lifecycleLocks[executionID] {
            return existing
        }
        let created = NSLock()
        lifecycleLocks[executionID] = created
        return created
    }

    private func requireExecutionID(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else {
            throw durableProcessError(code: EINVAL, message: "missing execution identifier")
        }
        return value
    }
}

private final class DurableGuestProcess: SpawnedProcessEventSink, @unchecked Sendable {
    private struct ResolvedAttachmentIdentity {
        let storageGeneration: UInt64?
        let trustedLaunchFingerprint: String?
        let incarnation: String?
    }

    private final class Attachment: @unchecked Sendable {
        weak var connection: AgentConnection?
        let handle: GuestProcessAttachmentHandle
        let deliveryQueue: DispatchQueue
        var nextSequence: UInt64
        var lastSentSequence: UInt64
        var acknowledgedSequence: UInt64
        var deliveryScheduled = false

        init(
            connection: AgentConnection,
            handle: GuestProcessAttachmentHandle,
            nextSequence: UInt64,
            acknowledgedSequence: UInt64
        ) {
            self.connection = connection
            self.handle = handle
            self.nextSequence = nextSequence
            self.lastSentSequence = acknowledgedSequence
            self.acknowledgedSequence = acknowledgedSequence
            self.deliveryQueue = DispatchQueue(
                label: "container.macos.guest-agent.durable-process.\(handle.token.uuidString)"
            )
        }
    }

    private struct PendingHandoff {
        let token: UUID
        let protectedSequence: UInt64
        let connection: AgentConnection
    }

    let executionID: String
    let launchFingerprint: String

    private let launchSpec: DurableGuestProcessLaunchSpec
    private let replayByteLimit: Int
    private let attachmentWriteTimeout: TimeInterval
    private let afterPendingHandoffPublication: (@Sendable (MacOSGuestProcessDisposition) -> Void)?
    private let beforeEventAppendBarrier: (@Sendable () -> Void)?
    private let afterAttachmentAcknowledgement: (@Sendable (MacOSGuestProcessDisposition) -> Void)?
    private let controlBarrier = NSLock()
    private let lock = NSLock()
    private var session: SpawnedProcessSession?
    private var processIdentifier: Int32 = -1
    private var attachment: Attachment?
    private var events: [DurableGuestProcessEvent] = []
    private var retainedBytes = 0
    private var lastSequence: UInt64 = 0
    private var exitCode: Int32?
    private var deleted = false
    private var trustedLaunchFingerprint: String?
    private var incarnation: String?
    private var storageGeneration: UInt64?
    private var pendingHandoff: PendingHandoff?

    init(
        executionID: String,
        launchSpec: DurableGuestProcessLaunchSpec,
        launchFingerprint: String,
        trustedLaunchFingerprint: String?,
        incarnation: String?,
        storageGeneration: UInt64?,
        replayByteLimit: Int,
        attachmentWriteTimeout: TimeInterval,
        afterPendingHandoffPublication: (@Sendable (MacOSGuestProcessDisposition) -> Void)?,
        beforeEventAppendBarrier: (@Sendable () -> Void)?,
        afterAttachmentAcknowledgement: (@Sendable (MacOSGuestProcessDisposition) -> Void)?
    ) {
        self.executionID = executionID
        self.launchSpec = launchSpec
        self.launchFingerprint = launchFingerprint
        self.trustedLaunchFingerprint = trustedLaunchFingerprint
        self.incarnation = incarnation
        self.storageGeneration = storageGeneration
        self.replayByteLimit = replayByteLimit
        self.attachmentWriteTimeout = attachmentWriteTimeout
        self.afterPendingHandoffPublication = afterPendingHandoffPublication
        self.beforeEventAppendBarrier = beforeEventAppendBarrier
        self.afterAttachmentAcknowledgement = afterAttachmentAcknowledgement
    }

    func install(session: SpawnedProcessSession) {
        lock.lock()
        self.session = session
        self.processIdentifier = session.processIdentifier
        lock.unlock()
    }

    func matches(spec: DurableGuestProcessLaunchSpec) -> Bool {
        launchSpec == spec
    }

    func attach(
        connection: AgentConnection,
        cursor: UInt64,
        disposition: MacOSGuestProcessDisposition,
        request: DurableGuestProcessAttachmentRequest
    ) throws -> GuestProcessAttachmentHandle {
        let handle = GuestProcessAttachmentHandle(executionID: executionID, token: UUID())
        let candidate: Attachment
        let payload: MacOSGuestProcessStatusPayload
        let proposedIdentity: ResolvedAttachmentIdentity
        let handoffToken = UUID()

        controlBarrier.lock()
        lock.lock()
        guard !deleted else {
            lock.unlock()
            controlBarrier.unlock()
            throw durableProcessError(code: ENOENT, message: "execution \(executionID) was deleted")
        }
        guard cursor <= lastSequence else {
            lock.unlock()
            controlBarrier.unlock()
            throw durableProcessError(
                code: EINVAL,
                message: "execution \(executionID) cursor \(cursor) exceeds current sequence \(lastSequence)"
            )
        }
        guard pendingHandoff == nil else {
            lock.unlock()
            controlBarrier.unlock()
            throw durableProcessError(code: EBUSY, message: "execution \(executionID) already has an attachment handoff in progress")
        }
        do {
            proposedIdentity = try resolvedAttachmentIdentity(for: request)
        } catch {
            lock.unlock()
            controlBarrier.unlock()
            throw error
        }

        let oldestSequence = events.first?.sequence ?? (lastSequence + 1)
        let replayTruncated = cursor.safelyIncremented < oldestSequence
        candidate = Attachment(
            connection: connection,
            handle: handle,
            nextSequence: max(cursor.safelyIncremented, oldestSequence),
            acknowledgedSequence: cursor
        )
        payload = makeStatus(
            disposition: disposition,
            replayTruncated: replayTruncated,
            oldestAvailableSequence: oldestSequence,
            reportedStorageGeneration: proposedIdentity.storageGeneration,
            reportedTrustedLaunchFingerprint: proposedIdentity.trustedLaunchFingerprint,
            reportedIncarnation: proposedIdentity.incarnation
        )
        pendingHandoff = .init(
            token: handoffToken,
            protectedSequence: candidate.nextSequence,
            connection: connection
        )
        lock.unlock()
        afterPendingHandoffPublication?(disposition)

        // Socket writes can block when the peer stops reading. Keep the current
        // controller and generation installed until the candidate receives its
        // ACK outside the state lock. The control barrier makes publication and
        // commit one ownership transition: once the new controller can observe
        // success, the previous controller can no longer issue a command.
        let writeDeadline = Date().addingTimeInterval(attachmentWriteTimeout)
        do {
            try connection.send(
                frame: .ack(id: executionID, data: try JSONEncoder().encode(payload)),
                deadline: writeDeadline
            )
            afterAttachmentAcknowledgement?(disposition)
        } catch {
            lock.lock()
            if pendingHandoff?.token == handoffToken {
                pendingHandoff = nil
            }
            let invalidatedConnections = enforceReplayByteLimit()
            lock.unlock()
            controlBarrier.unlock()
            invalidate(invalidatedConnections)
            connection.invalidate()
            throw error
        }

        let shouldDrain: Bool
        lock.lock()
        guard pendingHandoff?.token == handoffToken else {
            lock.unlock()
            controlBarrier.unlock()
            connection.invalidate()
            throw durableProcessError(
                code: EOVERFLOW,
                message: "execution \(executionID) attachment handoff lost its replay cursor"
            )
        }
        storageGeneration = proposedIdentity.storageGeneration
        trustedLaunchFingerprint = proposedIdentity.trustedLaunchFingerprint
        incarnation = proposedIdentity.incarnation
        attachment = candidate
        pendingHandoff = nil
        shouldDrain = lastSequence >= candidate.nextSequence
        candidate.deliveryScheduled = shouldDrain
        let invalidatedConnections = enforceReplayByteLimit()
        lock.unlock()
        controlBarrier.unlock()
        invalidate(invalidatedConnections)

        connection.installDurableAttachment(handle)
        if shouldDrain {
            candidate.deliveryQueue.async { [weak self, candidate] in
                self?.drainLiveEvents(through: candidate)
            }
        }
        return handle
    }

    func detach(handle: GuestProcessAttachmentHandle) {
        controlBarrier.lock()
        lock.lock()
        if attachment?.handle == handle {
            attachment = nil
        }
        let invalidatedConnections = enforceReplayByteLimit()
        lock.unlock()
        controlBarrier.unlock()
        invalidate(invalidatedConnections)
    }

    func acknowledgeEvents(through sequence: UInt64, handle: GuestProcessAttachmentHandle) throws {
        controlBarrier.lock()
        lock.lock()
        do {
            try requireController(handle)
            guard !deleted, let attachment else {
                throw durableProcessError(code: ENOENT, message: "execution \(executionID) is unavailable")
            }
            guard sequence <= attachment.lastSentSequence else {
                throw durableProcessError(
                    code: EINVAL,
                    message:
                        "execution \(executionID) event acknowledgement \(sequence) exceeds last sent sequence \(attachment.lastSentSequence)"
                )
            }
            if sequence > attachment.acknowledgedSequence {
                attachment.acknowledgedSequence = sequence
            }
            let invalidatedConnections = enforceReplayByteLimit()
            lock.unlock()
            controlBarrier.unlock()
            invalidate(invalidatedConnections)
        } catch {
            lock.unlock()
            controlBarrier.unlock()
            throw error
        }
    }

    func status(disposition: MacOSGuestProcessDisposition) -> MacOSGuestProcessStatusPayload {
        controlBarrier.lock()
        defer { controlBarrier.unlock() }
        lock.lock()
        defer { lock.unlock() }
        return makeStatus(
            disposition: disposition,
            replayTruncated: false,
            oldestAvailableSequence: events.first?.sequence ?? (lastSequence + 1)
        )
    }

    func writeStdin(_ data: Data, handle: GuestProcessAttachmentHandle) throws {
        guard !data.isEmpty else { return }

        let deadline = Date().addingTimeInterval(attachmentWriteTimeout)
        let maximumChunkSize = 16 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + maximumChunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            let written: Int? = try withControlledSession(handle: handle) { session in
                try session?.writeStdinNonblocking(chunk)
            }
            guard let written else {
                if offset == 0 {
                    return
                }
                throw durableProcessError(
                    code: EPIPE,
                    message: "execution \(executionID) exited during stdin write"
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            guard deadline.timeIntervalSinceNow > 0 else {
                throw durableProcessError(
                    code: ETIMEDOUT,
                    message: "execution \(executionID) stdin write timed out"
                )
            }
            usleep(5_000)
        }
    }

    func closeStdin(handle: GuestProcessAttachmentHandle) throws {
        try withControlledSession(handle: handle) { session in
            session?.closeStdin()
        }
    }

    func sendSignal(_ signal: Int32, handle: GuestProcessAttachmentHandle) throws {
        try withControlledSession(handle: handle) { session in
            try session?.sendSignal(signal)
        }
    }

    func stop(
        signal: Int32,
        handle: GuestProcessAttachmentHandle,
        acknowledge: (MacOSGuestProcessStatusPayload) throws -> Void
    ) throws {
        try withControlledSession(handle: handle) { session in
            try session?.sendSignal(signal)
        }

        lock.lock()
        let payload = makeStatus(
            disposition: .stopping,
            replayTruncated: false,
            oldestAvailableSequence: events.first?.sequence ?? (lastSequence + 1)
        )
        lock.unlock()
        try acknowledge(payload)
    }

    func resize(width: UInt16, height: UInt16, handle: GuestProcessAttachmentHandle) throws {
        try withControlledSession(handle: handle) { session in
            try session?.resize(width: width, height: height)
        }
    }

    func delete(handle: GuestProcessAttachmentHandle) throws -> MacOSGuestProcessStatusPayload {
        controlBarrier.lock()
        lock.lock()
        do {
            try requireController(handle)
            guard pendingHandoff == nil else {
                throw durableProcessError(
                    code: EBUSY,
                    message: "execution \(executionID) has an attachment handoff in progress"
                )
            }
        } catch {
            lock.unlock()
            controlBarrier.unlock()
            throw error
        }
        deleted = true
        attachment = nil
        let session = self.session
        self.session = nil
        let payload = makeStatus(
            disposition: .deleted,
            replayTruncated: false,
            oldestAvailableSequence: events.first?.sequence ?? (lastSequence + 1)
        )
        lock.unlock()
        controlBarrier.unlock()
        session?.cleanup()
        return payload
    }

    func commitDelete(
        request: DurableGuestProcessDeleteRequest
    ) throws -> (status: MacOSGuestProcessStatusPayload, session: SpawnedProcessSession?) {
        controlBarrier.lock()
        lock.lock()
        do {
            guard !deleted else {
                throw durableProcessError(code: ENOENT, message: "execution \(executionID) was deleted")
            }
            guard pendingHandoff == nil else {
                throw durableProcessError(
                    code: EBUSY,
                    message: "execution \(executionID) has an attachment handoff in progress"
                )
            }
            guard request.expectedLaunchFingerprint == launchFingerprint else {
                throw durableProcessError(code: ESTALE, message: "durable delete guest launch fingerprint does not match")
            }
            guard request.trustedLaunchFingerprint == trustedLaunchFingerprint else {
                throw durableProcessError(code: ESTALE, message: "durable delete trusted launch fingerprint does not match")
            }
            guard request.incarnation == incarnation else {
                throw durableProcessError(code: ESTALE, message: "durable delete process incarnation does not match")
            }
            guard request.storageGeneration == storageGeneration else {
                throw durableProcessError(code: ESTALE, message: "durable delete storage generation does not match")
            }
        } catch {
            lock.unlock()
            controlBarrier.unlock()
            throw error
        }

        deleted = true
        attachment = nil
        let session = self.session
        self.session = nil
        let payload = makeStatus(
            disposition: .deleted,
            replayTruncated: false,
            oldestAvailableSequence: events.first?.sequence ?? (lastSequence + 1)
        )
        lock.unlock()
        controlBarrier.unlock()
        return (payload, session)
    }

    func deletionIdentity() -> DeletedGuestProcessIncarnation? {
        lock.lock()
        defer { lock.unlock() }
        guard let trustedLaunchFingerprint, let incarnation else {
            return nil
        }
        return .init(
            trustedLaunchFingerprint: trustedLaunchFingerprint,
            guestLaunchFingerprint: launchFingerprint,
            incarnation: incarnation,
            storageGeneration: storageGeneration
        )
    }

    func forceDelete() {
        controlBarrier.lock()
        lock.lock()
        deleted = true
        attachment = nil
        let pendingConnection = pendingHandoff?.connection
        pendingHandoff = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        controlBarrier.unlock()
        pendingConnection?.invalidate()
        session?.cleanup()
    }

    func processSession(_ session: SpawnedProcessSession, didOutput channel: GuestProcessOutputChannel, data: Data) {
        _ = session
        let kind: DurableGuestProcessEvent.Kind
        switch channel {
        case .stdout:
            kind = .stdout
        case .stderr:
            kind = .stderr
        }
        let chunkSize = max(replayByteLimit - 32, 1)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            appendEvent(kind: kind, data: data.subdata(in: offset..<end), exitCode: nil)
            offset = end
        }
    }

    func processSession(_ session: SpawnedProcessSession, didExitWithCode code: Int32) {
        _ = session
        appendEvent(kind: .exit, data: nil, exitCode: code)
    }

    private func appendEvent(kind: DurableGuestProcessEvent.Kind, data: Data?, exitCode: Int32?) {
        beforeEventAppendBarrier?()
        controlBarrier.lock()
        lock.lock()
        guard !deleted else {
            lock.unlock()
            controlBarrier.unlock()
            return
        }
        guard lastSequence < .max else {
            lock.unlock()
            controlBarrier.unlock()
            return
        }
        if case .exit = kind {
            self.exitCode = exitCode
        }
        lastSequence += 1
        let event = DurableGuestProcessEvent(
            sequence: lastSequence,
            kind: kind,
            data: data,
            exitCode: exitCode
        )
        events.append(event)
        retainedBytes += event.retainedByteCount
        let invalidatedConnections = enforceReplayByteLimit()

        let scheduledAttachment: Attachment?
        if let currentAttachment = attachment, !currentAttachment.deliveryScheduled {
            currentAttachment.deliveryScheduled = true
            scheduledAttachment = currentAttachment
        } else {
            scheduledAttachment = nil
        }
        lock.unlock()
        controlBarrier.unlock()
        invalidate(invalidatedConnections)

        guard let scheduledAttachment else { return }
        scheduledAttachment.deliveryQueue.async { [weak self, scheduledAttachment] in
            self?.drainLiveEvents(through: scheduledAttachment)
        }
    }

    private func drainLiveEvents(through expectedAttachment: Attachment) {
        while true {
            controlBarrier.lock()
            lock.lock()
            guard attachment?.handle == expectedAttachment.handle else {
                expectedAttachment.deliveryScheduled = false
                lock.unlock()
                controlBarrier.unlock()
                return
            }
            guard let connection = expectedAttachment.connection else {
                attachment = nil
                expectedAttachment.deliveryScheduled = false
                let invalidatedConnections = enforceReplayByteLimit()
                lock.unlock()
                controlBarrier.unlock()
                invalidate(invalidatedConnections)
                return
            }
            guard let event = events.first(where: { $0.sequence >= expectedAttachment.nextSequence }) else {
                expectedAttachment.deliveryScheduled = false
                let invalidatedConnections = enforceReplayByteLimit()
                lock.unlock()
                controlBarrier.unlock()
                invalidate(invalidatedConnections)
                return
            }
            lock.unlock()
            controlBarrier.unlock()

            do {
                try connection.send(
                    frame: event.frame(executionID: executionID),
                    deadline: Date().addingTimeInterval(attachmentWriteTimeout)
                )
            } catch {
                controlBarrier.lock()
                lock.lock()
                if attachment?.handle == expectedAttachment.handle {
                    attachment = nil
                }
                expectedAttachment.deliveryScheduled = false
                let invalidatedConnections = enforceReplayByteLimit()
                lock.unlock()
                controlBarrier.unlock()
                invalidate(invalidatedConnections)
                connection.invalidate()
                return
            }

            controlBarrier.lock()
            lock.lock()
            guard attachment?.handle == expectedAttachment.handle else {
                expectedAttachment.deliveryScheduled = false
                lock.unlock()
                controlBarrier.unlock()
                return
            }
            expectedAttachment.nextSequence = event.sequence.safelyIncremented
            expectedAttachment.lastSentSequence = event.sequence
            let invalidatedConnections = enforceReplayByteLimit()
            if event.sequence == .max {
                expectedAttachment.deliveryScheduled = false
            }
            lock.unlock()
            controlBarrier.unlock()
            invalidate(invalidatedConnections)
            if event.sequence == .max {
                return
            }
        }
    }

    private func withControlledSession<Result>(
        handle: GuestProcessAttachmentHandle,
        _ operation: (SpawnedProcessSession?) throws -> Result
    ) throws -> Result {
        controlBarrier.lock()
        defer { controlBarrier.unlock() }

        lock.lock()
        let controlledSession: SpawnedProcessSession?
        do {
            try requireController(handle)
            guard !deleted, let session else {
                throw durableProcessError(code: ENOENT, message: "execution \(executionID) is unavailable")
            }
            controlledSession = exitCode == nil ? session : nil
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        return try operation(controlledSession)
    }

    private func requireController(_ handle: GuestProcessAttachmentHandle) throws {
        guard attachment?.handle == handle else {
            throw durableProcessError(
                code: EPERM,
                message: "connection no longer controls execution \(executionID)"
            )
        }
    }

    private func makeStatus(
        disposition: MacOSGuestProcessDisposition,
        replayTruncated: Bool,
        oldestAvailableSequence: UInt64,
        reportedStorageGeneration: UInt64? = nil,
        reportedTrustedLaunchFingerprint: String? = nil,
        reportedIncarnation: String? = nil
    ) -> MacOSGuestProcessStatusPayload {
        let state: MacOSGuestProcessState
        if deleted {
            state = .deleted
        } else if exitCode != nil {
            state = .exited
        } else {
            state = .running
        }
        return .init(
            executionID: executionID,
            disposition: disposition,
            state: state,
            launchFingerprint: launchFingerprint,
            trustedLaunchFingerprint: reportedTrustedLaunchFingerprint ?? trustedLaunchFingerprint,
            incarnation: reportedIncarnation ?? incarnation,
            storageGeneration: reportedStorageGeneration ?? storageGeneration,
            processIdentifier: processIdentifier,
            exitCode: exitCode,
            cursor: lastSequence,
            oldestAvailableSequence: oldestAvailableSequence,
            replayTruncated: replayTruncated
        )
    }

    private func resolvedAttachmentIdentity(
        for request: DurableGuestProcessAttachmentRequest
    ) throws -> ResolvedAttachmentIdentity {
        if request.isLegacy {
            guard storageGeneration == nil, trustedLaunchFingerprint == nil, incarnation == nil else {
                throw durableProcessError(
                    code: ESTALE,
                    message: "execution \(executionID) requires generation-fenced attachment"
                )
            }
            return .init(storageGeneration: nil, trustedLaunchFingerprint: nil, incarnation: nil)
        }

        guard request.expectedLaunchFingerprint == launchFingerprint else {
            throw durableProcessError(
                code: ESTALE,
                message: "execution \(executionID) launch fingerprint does not match"
            )
        }
        if request.trustedLaunchFingerprint == nil, request.incarnation == nil {
            guard let requestedGeneration = request.storageGeneration, let boundGeneration = storageGeneration else {
                throw durableProcessError(
                    code: ESTALE,
                    message: "legacy generation-fenced execution \(executionID) has incompatible storage identity"
                )
            }
            if let previousGeneration = request.previousStorageGeneration {
                guard previousGeneration == boundGeneration, requestedGeneration > previousGeneration else {
                    throw durableProcessError(
                        code: ESTALE,
                        message: "legacy execution \(executionID) cannot adopt the requested storage generation"
                    )
                }
                return .init(storageGeneration: requestedGeneration, trustedLaunchFingerprint: nil, incarnation: nil)
            }
            guard requestedGeneration == boundGeneration else {
                throw durableProcessError(
                    code: ESTALE,
                    message: "legacy execution \(executionID) is bound to storage generation \(boundGeneration)"
                )
            }
            return .init(storageGeneration: boundGeneration, trustedLaunchFingerprint: nil, incarnation: nil)
        }
        guard let requestedTrustedFingerprint = request.trustedLaunchFingerprint,
            requestedTrustedFingerprint == trustedLaunchFingerprint
        else {
            throw durableProcessError(
                code: ESTALE,
                message: "execution \(executionID) trusted launch fingerprint does not match"
            )
        }
        guard let requestedIncarnation = request.incarnation else {
            throw durableProcessError(code: EINVAL, message: "generation-fenced attachment is missing process incarnation")
        }
        guard let requestedGeneration = request.storageGeneration else {
            guard storageGeneration == nil, request.previousStorageGeneration == nil else {
                throw durableProcessError(
                    code: ESTALE,
                    message: "execution \(executionID) requires a storage generation"
                )
            }
            guard requestedIncarnation == incarnation else {
                throw durableProcessError(
                    code: ESTALE,
                    message: "execution \(executionID) process incarnation does not match"
                )
            }
            return .init(
                storageGeneration: nil,
                trustedLaunchFingerprint: requestedTrustedFingerprint,
                incarnation: requestedIncarnation
            )
        }
        guard let boundGeneration = storageGeneration else {
            throw durableProcessError(
                code: ESTALE,
                message: "legacy execution \(executionID) cannot adopt a storage generation"
            )
        }

        if let previousGeneration = request.previousStorageGeneration {
            guard previousGeneration == boundGeneration else {
                throw durableProcessError(
                    code: ESTALE,
                    message:
                        "execution \(executionID) is bound to generation \(boundGeneration), not previous generation \(previousGeneration)"
                )
            }
            guard requestedGeneration > previousGeneration else {
                throw durableProcessError(
                    code: EINVAL,
                    message: "adopted storage generation must be greater than the previous generation"
                )
            }
            return .init(
                storageGeneration: requestedGeneration,
                trustedLaunchFingerprint: requestedTrustedFingerprint,
                incarnation: requestedIncarnation
            )
        }

        guard requestedGeneration == boundGeneration else {
            throw durableProcessError(
                code: ESTALE,
                message: "execution \(executionID) is bound to storage generation \(boundGeneration)"
            )
        }
        guard requestedIncarnation == incarnation else {
            throw durableProcessError(
                code: ESTALE,
                message: "execution \(executionID) process incarnation does not match"
            )
        }
        return .init(
            storageGeneration: boundGeneration,
            trustedLaunchFingerprint: requestedTrustedFingerprint,
            incarnation: requestedIncarnation
        )
    }

    /// Must be called with both controlBarrier and lock held.
    private func enforceReplayByteLimit() -> [AgentConnection] {
        var invalidatedConnections: [ObjectIdentifier: AgentConnection] = [:]
        while retainedBytes > replayByteLimit, let first = events.first {
            if let pendingHandoff, pendingHandoff.protectedSequence <= first.sequence {
                invalidatedConnections[ObjectIdentifier(pendingHandoff.connection)] = pendingHandoff.connection
                self.pendingHandoff = nil
            }
            if let attachment, attachment.acknowledgedSequence.safelyIncremented <= first.sequence {
                attachment.deliveryScheduled = false
                if let connection = attachment.connection {
                    invalidatedConnections[ObjectIdentifier(connection)] = connection
                }
                self.attachment = nil
            }
            events.removeFirst()
            retainedBytes -= first.retainedByteCount
        }
        return Array(invalidatedConnections.values)
    }

    private func invalidate(_ connections: [AgentConnection]) {
        for connection in connections {
            connection.invalidate()
        }
    }
}

private func durableProcessError(code: Int32, message: String) -> NSError {
    NSError(
        domain: "container.macos.guest-agent.durable-process",
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

extension UInt64 {
    fileprivate var safelyIncremented: UInt64 {
        self == .max ? .max : self + 1
    }
}
