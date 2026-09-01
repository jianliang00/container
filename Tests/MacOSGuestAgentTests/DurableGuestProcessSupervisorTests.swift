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

#if os(macOS)
import Darwin
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import container_macos_guest_agent

@Suite(.serialized)
struct DurableGuestProcessSupervisorTests {
    @Test
    func boundedAgentConnectionWriteTimesOutWhenPeerStopsReading() throws {
        signal(SIGPIPE, SIG_IGN)
        let pair = try makeDurableProcessSocketPair()
        defer {
            closeDurableProcessFD(pair.server)
            closeDurableProcessFD(pair.peer)
        }
        var receiveBufferBytes: Int32 = 1_024
        #expect(
            Darwin.setsockopt(
                pair.peer,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        )
        let connection = AgentConnection(fd: pair.server, processSupervisor: GuestProcessSupervisor())
        let started = Date()

        do {
            try connection.send(
                frame: .stdout(id: "slow-peer", sequence: 1, data: Data(repeating: 0x61, count: 4 * 1024 * 1024)),
                deadline: Date().addingTimeInterval(0.1)
            )
            Issue.record("bounded guest-agent write unexpectedly completed")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ETIMEDOUT))
        }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test
    func retryAfterLostAckReattachesWithoutSpawningAgain() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let directory = try makeDurableProcessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appendingPathComponent("starts")
        let pidFile = directory.appendingPathComponent("pid")
        let frame = durableExecFrame(
            id: "lost-ack",
            script: "printf 'start\\n' >> \"$MARKER\"; printf '%s' $$ > \"$PID_FILE\"; while :; do sleep 1; done",
            additionalEnvironment: [
                "MARKER=\(marker.path)",
                "PID_FILE=\(pidFile.path)",
            ]
        )

        let first = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { first.closePeer() }
        #expect(try first.readFrame().type == .ready)
        try first.write(frame)
        try waitForDurableProcessCondition {
            FileManager.default.fileExists(atPath: pidFile.path)
        }
        first.closePeer()
        try first.waitForCompletion()

        let second = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { second.closePeer() }
        #expect(try second.readFrame().type == .ready)
        try second.write(frame)
        let retryStatus = try decodeDurableStatus(from: second.readFrame())

        #expect(retryStatus.disposition == .existing)
        #expect(retryStatus.state == .running)
        let recordedPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(retryStatus.processIdentifier == recordedPID)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "start\n")

        try deleteDurableProcess(id: "lost-ack", through: second)
        try waitForDurableProcessCondition {
            !durableProcessExists(recordedPID)
        }
        try second.waitForCompletion()
    }

    @Test
    func disconnectKeepsProcessAliveAndAttachReturnsSamePID() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }

        let first = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { first.closePeer() }
        #expect(try first.readFrame().type == .ready)
        let executionID = "disconnect-survival"
        try first.write(durableExecFrame(id: executionID, script: "while :; do sleep 1; done"))
        let created = try decodeDurableStatus(from: first.readFrame())
        #expect(created.disposition == .created)
        #expect(durableProcessExists(created.processIdentifier))
        first.closePeer()
        try first.waitForCompletion()
        #expect(durableProcessExists(created.processIdentifier))

        let second = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { second.closePeer() }
        #expect(try second.readFrame().type == .ready)
        try second.write(.init(type: .processInspect, id: executionID))
        let inspected = try decodeDurableStatus(from: second.readFrame())
        #expect(inspected.disposition == .inspected)
        #expect(inspected.processIdentifier == created.processIdentifier)
        #expect(inspected.state == .running)

        try second.write(.init(type: .processAttach, id: executionID, cursor: inspected.cursor))
        let attached = try decodeDurableStatus(from: second.readFrame())
        #expect(attached.disposition == .attached)
        #expect(attached.processIdentifier == created.processIdentifier)

        try deleteDurableProcess(id: executionID, through: second)
        try waitForDurableProcessCondition {
            !durableProcessExists(created.processIdentifier)
        }
        try second.waitForCompletion()
    }

    @Test
    func conflictingRetryDoesNotReplaceExistingProcess() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "spec-conflict"

        let owner = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { owner.closePeer() }
        #expect(try owner.readFrame().type == .ready)
        try owner.write(durableExecFrame(id: executionID, script: "while :; do sleep 1; done"))
        let created = try decodeDurableStatus(from: owner.readFrame())

        let retry = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { retry.closePeer() }
        #expect(try retry.readFrame().type == .ready)
        try retry.write(durableExecFrame(id: executionID, script: "exit 17"))
        let error = try retry.readFrame()
        #expect(error.type == .error)
        #expect(error.id == executionID)
        #expect(error.message?.contains("conflicts with existing fingerprint") == true)
        #expect(durableProcessExists(created.processIdentifier))

        try deleteDurableProcess(id: executionID, through: owner)
        try waitForDurableProcessCondition {
            !durableProcessExists(created.processIdentifier)
        }
        try owner.waitForCompletion()
        try retry.waitForCompletion()
    }

    @Test
    func durableProcessErrorsCarryStructuredPOSIXCodes() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }

        let connection = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { connection.closePeer() }
        #expect(try connection.readFrame().type == .ready)
        try connection.write(.init(type: .processInspect, id: "missing-execution"))

        let response = try connection.readFrame()
        #expect(response.type == .error)
        #expect(response.id == "missing-execution")
        #expect(response.errorCode == ENOENT)
        try connection.waitForCompletion()
    }

    @Test
    func attachReplaysMissedOutputWithMonotonicSequence() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let directory = try makeDurableProcessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trigger = directory.appendingPathComponent("trigger")
        let done = directory.appendingPathComponent("done")
        let executionID = "replay"

        let first = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { first.closePeer() }
        #expect(try first.readFrame().type == .ready)
        try first.write(
            durableExecFrame(
                id: executionID,
                script:
                    "while [ ! -e \"$TRIGGER\" ]; do sleep 0.02; done; "
                    + "printf 'one\\ntwo\\n' ; printf 'warning\\n' >&2; printf 'three\\n'; : > \"$DONE\"",
                additionalEnvironment: [
                    "TRIGGER=\(trigger.path)",
                    "DONE=\(done.path)",
                ]
            )
        )
        let created = try decodeDurableStatus(from: first.readFrame())
        #expect(created.cursor == 0)
        first.closePeer()
        try first.waitForCompletion()
        #expect(FileManager.default.createFile(atPath: trigger.path, contents: Data()))
        try waitForDurableProcessCondition {
            FileManager.default.fileExists(atPath: done.path)
        }

        let second = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { second.closePeer() }
        #expect(try second.readFrame().type == .ready)
        try second.write(.init(type: .processAttach, id: executionID, cursor: 0))
        let attached = try decodeDurableStatus(from: second.readFrame())
        #expect(attached.disposition == .attached)
        #expect(attached.cursor >= 3)
        #expect(!attached.replayTruncated)

        var replay: [GuestAgentFrame] = []
        while replay.last?.type != .exit {
            replay.append(try second.readFrame())
        }
        let sequences = try replay.map { try #require($0.sequence) }
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == sequences.count)
        #expect(replay.allSatisfy { $0.id == executionID })
        let stdout = replay.filter { $0.type == .stdout }.compactMap(\.data).reduce(into: Data()) { $0.append($1) }
        let stderr = replay.filter { $0.type == .stderr }.compactMap(\.data).reduce(into: Data()) { $0.append($1) }
        #expect(String(decoding: stdout, as: UTF8.self) == "one\ntwo\nthree\n")
        #expect(String(decoding: stderr, as: UTF8.self) == "warning\n")
        #expect(replay.last?.exitCode == 0)

        try deleteDurableProcess(id: executionID, through: second)
        try second.waitForCompletion()
    }

    @Test
    func consumerEventAcknowledgementIsCumulativeIdempotentAndControllerFenced() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "consumer-event-ack"

        let owner = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { owner.closePeer() }
        let ready = try owner.readFrame()
        #expect(ready.capabilities?.contains(MacOSGuestProcessProtocol.durableProcessV3) == true)
        try owner.write(
            durableExecFrame(
                id: executionID,
                script: "printf 'final-output'; exit 0"
            )
        )
        _ = try decodeDurableStatus(from: owner.readFrame())

        var terminalSequence: UInt64?
        while terminalSequence == nil {
            let event = try owner.readFrame()
            if event.type == .exit {
                terminalSequence = event.sequence
            }
        }
        let acknowledgedSequence = try #require(terminalSequence)

        try owner.write(
            .init(
                type: .processEventAck,
                id: executionID,
                sequence: acknowledgedSequence
            )
        )
        try owner.write(
            .init(
                type: .processEventAck,
                id: executionID,
                sequence: acknowledgedSequence
            )
        )
        try owner.write(.init(type: .processInspect, id: executionID))
        #expect(try decodeDurableStatus(from: owner.readFrame()).state == .exited)

        try owner.write(
            .init(
                type: .processEventAck,
                id: executionID,
                sequence: acknowledgedSequence + 1
            )
        )
        let outOfRange = try owner.readFrame()
        #expect(outOfRange.type == .error)
        #expect(outOfRange.errorCode == EINVAL)

        let successor = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { successor.closePeer() }
        _ = try successor.readFrame()
        try successor.write(
            .init(
                type: .processAttach,
                id: executionID,
                cursor: acknowledgedSequence
            )
        )
        _ = try decodeDurableStatus(from: successor.readFrame())

        try owner.write(
            .init(
                type: .processEventAck,
                id: executionID,
                sequence: acknowledgedSequence
            )
        )
        let staleController = try owner.readFrame()
        #expect(staleController.type == .error)
        #expect(staleController.errorCode == EPERM)

        try deleteDurableProcess(id: executionID, through: successor)
        try owner.waitForCompletion()
        try successor.waitForCompletion()
    }

    @Test
    func boundedReplayReportsWhenCursorWasEvicted() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor(replayByteLimit: 128)
        defer { supervisor.removeAllForTesting() }
        let directory = try makeDurableProcessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trigger = directory.appendingPathComponent("trigger")
        let executionID = "bounded-replay"

        let first = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { first.closePeer() }
        #expect(try first.readFrame().type == .ready)
        try first.write(
            durableExecFrame(
                id: executionID,
                script:
                    "while [ ! -e \"$TRIGGER\" ]; do sleep 0.02; done; "
                    + "i=0; while [ $i -lt 80 ]; do printf '0123456789abcdef'; i=$((i + 1)); done",
                additionalEnvironment: ["TRIGGER=\(trigger.path)"]
            )
        )
        _ = try decodeDurableStatus(from: first.readFrame())
        first.closePeer()
        try first.waitForCompletion()
        #expect(FileManager.default.createFile(atPath: trigger.path, contents: Data()))

        try waitForDurableProcessCondition {
            (try? supervisor.inspect(executionID: executionID).state) == .exited
        }
        let second = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { second.closePeer() }
        #expect(try second.readFrame().type == .ready)
        try second.write(.init(type: .processAttach, id: executionID, cursor: 0))
        let attached = try decodeDurableStatus(from: second.readFrame())
        #expect(attached.replayTruncated)
        #expect(attached.oldestAvailableSequence > 1)
        #expect(attached.cursor >= attached.oldestAvailableSequence)

        var lastSequence: UInt64 = 0
        repeat {
            let event = try second.readFrame()
            let sequence = try #require(event.sequence)
            #expect(sequence > lastSequence)
            #expect(sequence >= attached.oldestAvailableSequence)
            lastSequence = sequence
            if event.type == .exit {
                break
            }
        } while true

        try deleteDurableProcess(id: executionID, through: second)
        try second.waitForCompletion()
    }

    @Test
    func slowAttachmentCannotProtectReplayPastHardByteLimit() throws {
        signal(SIGPIPE, SIG_IGN)
        let replayByteLimit = 256
        let supervisor = GuestProcessSupervisor(
            replayByteLimit: replayByteLimit,
            attachmentWriteTimeout: 0.2
        )
        defer { supervisor.removeAllForTesting() }
        let directory = try makeDurableProcessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trigger = directory.appendingPathComponent("trigger")
        let executionID = "slow-reader-hard-limit"

        let pair = try makeDurableProcessSocketPair()
        defer { closeDurableProcessFD(pair.peer) }
        var socketBufferBytes: Int32 = 1_024
        #expect(
            Darwin.setsockopt(
                pair.server,
                SOL_SOCKET,
                SO_SNDBUF,
                &socketBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        )
        #expect(
            Darwin.setsockopt(
                pair.peer,
                SOL_SOCKET,
                SO_RCVBUF,
                &socketBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        )
        let slowConnection = AgentConnection(fd: pair.server, processSupervisor: supervisor)
        let slowHandle = try supervisor.createAndAttach(
            frame: durableExecFrame(
                id: executionID,
                script:
                    "while [ ! -e \"$TRIGGER\" ]; do sleep 0.02; done; "
                    + "/bin/dd if=/dev/zero bs=1048576 count=8 2>/dev/null",
                additionalEnvironment: ["TRIGGER=\(trigger.path)"]
            ),
            connection: slowConnection,
            cursor: 0
        )
        _ = try decodeDurableStatus(from: readDurableProcessFrame(fd: pair.peer))
        #expect(FileManager.default.createFile(atPath: trigger.path, contents: Data()))

        try waitForDurableProcessCondition(timeout: 5) {
            (try? supervisor.inspect(executionID: executionID).state) == .exited
        }
        try waitForDurableProcessCondition {
            do {
                try supervisor.closeStdin(handle: slowHandle)
                return false
            } catch let error as NSError {
                return error.code == Int(EPERM)
            }
        }

        let replayConnection = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { replayConnection.closePeer() }
        #expect(try replayConnection.readFrame().type == .ready)
        try replayConnection.write(.init(type: .processAttach, id: executionID, cursor: 0))
        let attached = try decodeDurableStatus(from: replayConnection.readFrame())
        #expect(attached.replayTruncated)

        var retainedBytes = 0
        while true {
            let event = try replayConnection.readFrame()
            retainedBytes += (event.data?.count ?? 0) + 32
            if event.type == .exit {
                break
            }
        }
        #expect(retainedBytes <= replayByteLimit)

        try deleteDurableProcess(id: executionID, through: replayConnection)
        slowConnection.invalidate()
        try replayConnection.waitForCompletion()
    }

    @Test
    func newerAttachmentRevokesOldControllerAndExplicitStopDeleteCleansUp() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "single-controller"

        let oldController = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { oldController.closePeer() }
        #expect(try oldController.readFrame().type == .ready)
        try oldController.write(durableExecFrame(id: executionID, script: "exec /bin/sleep 100"))
        let created = try decodeDurableStatus(from: oldController.readFrame())

        let newController = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { newController.closePeer() }
        #expect(try newController.readFrame().type == .ready)
        try newController.write(.init(type: .processAttach, id: executionID, cursor: created.cursor))
        let attached = try decodeDurableStatus(from: newController.readFrame())
        #expect(attached.processIdentifier == created.processIdentifier)

        try oldController.write(.init(type: .signal, id: executionID, signal: SIGTERM))
        let revoked = try oldController.readFrame()
        #expect(revoked.type == .error)
        #expect(revoked.message?.contains("no longer controls") == true)
        #expect(durableProcessExists(created.processIdentifier))

        try newController.write(.init(type: .processStop, id: executionID, signal: SIGTERM))
        let stopping = try decodeDurableStatus(from: newController.readFrame())
        #expect(stopping.disposition == .stopping)
        var exit: GuestAgentFrame?
        while exit == nil {
            let frame = try newController.readFrame()
            if frame.type == .exit {
                exit = frame
            }
        }
        #expect(exit?.id == executionID)

        try newController.write(.init(type: .processDelete, id: executionID))
        let deleted = try decodeDurableStatus(from: newController.readFrame())
        #expect(deleted.disposition == .deleted)
        #expect(deleted.state == .deleted)
        #expect(deleted.processIdentifier == created.processIdentifier)
        try waitForDurableProcessCondition {
            !durableProcessExists(created.processIdentifier)
        }
        #expect(throws: (any Error).self) {
            _ = try supervisor.inspect(executionID: executionID)
        }

        try oldController.waitForCompletion()
        try newController.waitForCompletion()
    }

    @Test
    func failedAttachAcknowledgementKeepsExistingController() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "failed-attach-ack"

        let owner = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { owner.closePeer() }
        #expect(try owner.readFrame().type == .ready)
        try owner.write(
            durableExecFrame(
                id: executionID,
                script: "while :; do sleep 1; done",
                storageGeneration: 40
            )
        )
        let created = try decodeDurableStatus(from: owner.readFrame())
        #expect(created.storageGeneration == 40)

        let failedPair = try makeDurableProcessSocketPair()
        closeDurableProcessFD(failedPair.peer)
        let failedConnection = AgentConnection(fd: failedPair.server, processSupervisor: supervisor)
        #expect(throws: (any Error).self) {
            _ = try supervisor.attach(
                frame: .init(
                    type: .processAttach,
                    id: executionID,
                    cursor: created.cursor,
                    expectedLaunchFingerprint: created.launchFingerprint,
                    storageGeneration: 41,
                    previousStorageGeneration: 40
                ),
                connection: failedConnection,
                cursor: created.cursor
            )
        }
        #expect(try supervisor.inspect(executionID: executionID).storageGeneration == 40)

        try deleteDurableProcess(id: executionID, through: owner)
        try waitForDurableProcessCondition {
            !durableProcessExists(created.processIdentifier)
        }
        failedConnection.invalidate()
        try owner.waitForCompletion()
    }

    @Test
    func successfulAttachmentAcknowledgementPublishesTheNewControllerBeforeOldControlCanProceed() throws {
        signal(SIGPIPE, SIG_IGN)
        let acknowledgementPublished = DispatchSemaphore(value: 0)
        let releaseCommit = DispatchSemaphore(value: 0)
        let supervisor = GuestProcessSupervisor(afterAttachmentAcknowledgement: { disposition in
            guard disposition == .attached else { return }
            acknowledgementPublished.signal()
            _ = releaseCommit.wait(timeout: .now() + 2)
        })
        defer {
            releaseCommit.signal()
            supervisor.removeAllForTesting()
        }
        let executionID = "attachment-publication-barrier"

        let ownerPair = try makeDurableProcessSocketPair()
        defer { closeDurableProcessFD(ownerPair.peer) }
        let ownerConnection = AgentConnection(fd: ownerPair.server, processSupervisor: supervisor)
        let ownerHandle = try supervisor.createAndAttach(
            frame: durableExecFrame(id: executionID, script: "exec /bin/sleep 100"),
            connection: ownerConnection,
            cursor: 0
        )
        let created = try decodeDurableStatus(from: readDurableProcessFrame(fd: ownerPair.peer))

        let successorPair = try makeDurableProcessSocketPair()
        defer { closeDurableProcessFD(successorPair.peer) }
        let successorConnection = AgentConnection(fd: successorPair.server, processSupervisor: supervisor)
        let attachResult = DurableLockedValue<Result<GuestProcessAttachmentHandle, Error>?>(nil)
        let attachFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            attachResult.withLock { result in
                result = Result {
                    try supervisor.attach(
                        frame: .init(type: .processAttach, id: executionID, cursor: created.cursor),
                        connection: successorConnection,
                        cursor: created.cursor
                    )
                }
            }
            attachFinished.signal()
        }

        let successorStatus = try decodeDurableStatus(from: readDurableProcessFrame(fd: successorPair.peer))
        #expect(successorStatus.disposition == .attached)
        #expect(acknowledgementPublished.wait(timeout: .now() + 1) == .success)

        let oldControlError = DurableLockedValue<Error?>(nil)
        let oldControlFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do {
                try supervisor.sendSignal(0, handle: ownerHandle)
            } catch {
                oldControlError.withLock { $0 = error }
            }
            oldControlFinished.signal()
        }
        #expect(oldControlFinished.wait(timeout: .now() + 0.1) == .timedOut)

        let inspectResult = DurableLockedValue<Result<MacOSGuestProcessStatusPayload, Error>?>(nil)
        let inspectFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            inspectResult.withLock { result in
                result = Result { try supervisor.inspect(executionID: executionID) }
            }
            inspectFinished.signal()
        }
        #expect(inspectFinished.wait(timeout: .now() + 0.1) == .timedOut)

        releaseCommit.signal()
        #expect(attachFinished.wait(timeout: .now() + 1) == .success)
        #expect(oldControlFinished.wait(timeout: .now() + 1) == .success)
        #expect(inspectFinished.wait(timeout: .now() + 1) == .success)
        #expect((oldControlError.withLock { $0 } as NSError?)?.code == Int(EPERM))
        let inspectOutcome = try #require(inspectResult.withLock { $0 })
        #expect(try inspectOutcome.get().disposition == .inspected)
        let successorHandle = try #require(attachResult.withLock { try? $0?.get() })
        _ = try supervisor.delete(handle: successorHandle)
        ownerConnection.invalidate()
        successorConnection.invalidate()
    }

    @Test
    func replayOverflowCannotInvalidatePendingHandoffBeforeAcknowledgement() throws {
        signal(SIGPIPE, SIG_IGN)
        let pendingPublished = DispatchSemaphore(value: 0)
        let releaseHandoff = DispatchSemaphore(value: 0)
        let eventWaitingForBarrier = DispatchSemaphore(value: 0)
        let supervisor = GuestProcessSupervisor(
            replayByteLimit: 128,
            afterPendingHandoffPublication: { disposition in
                guard disposition == .attached else { return }
                pendingPublished.signal()
                _ = releaseHandoff.wait(timeout: .now() + 2)
            },
            beforeEventAppendBarrier: {
                eventWaitingForBarrier.signal()
            }
        )
        defer {
            releaseHandoff.signal()
            supervisor.removeAllForTesting()
        }
        let directory = try makeDurableProcessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trigger = directory.appendingPathComponent("trigger")
        let executionID = "pending-handoff-overflow"

        let owner = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { owner.closePeer() }
        #expect(try owner.readFrame().type == .ready)
        try owner.write(
            durableExecFrame(
                id: executionID,
                script:
                    "while [ ! -e \"$TRIGGER\" ]; do sleep 0.02; done; "
                    + "/bin/dd if=/dev/zero bs=4096 count=1 2>/dev/null; exec /bin/sleep 100",
                additionalEnvironment: ["TRIGGER=\(trigger.path)"]
            )
        )
        let created = try decodeDurableStatus(from: owner.readFrame())

        let successor = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { successor.closePeer() }
        #expect(try successor.readFrame().type == .ready)
        try successor.write(.init(type: .processAttach, id: executionID, cursor: created.cursor))
        #expect(pendingPublished.wait(timeout: .now() + 1) == .success)

        #expect(FileManager.default.createFile(atPath: trigger.path, contents: Data()))
        #expect(eventWaitingForBarrier.wait(timeout: .now() + 1) == .success)

        releaseHandoff.signal()
        let attached = try decodeDurableStatus(from: successor.readFrame())
        #expect(attached.disposition == .attached)
        #expect(attached.processIdentifier == created.processIdentifier)
    }

    @Test
    func generationFencedAttachRejectsStaleIdentityAndAdoptsOnlyItsBoundGeneration() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "generation-fence"

        let creator = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { creator.closePeer() }
        #expect(try creator.readFrame().type == .ready)
        try creator.write(
            durableExecFrame(
                id: executionID,
                script: "while :; do sleep 1; done",
                storageGeneration: 70
            )
        )
        let created = try decodeDurableStatus(from: creator.readFrame())
        #expect(created.storageGeneration == 70)

        let reconnected = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { reconnected.closePeer() }
        #expect(try reconnected.readFrame().type == .ready)
        try reconnected.write(
            .init(
                type: .processAttach,
                id: executionID,
                cursor: created.cursor,
                expectedLaunchFingerprint: created.launchFingerprint,
                storageGeneration: 70
            )
        )
        let sameGeneration = try decodeDurableStatus(from: reconnected.readFrame())
        #expect(sameGeneration.storageGeneration == 70)

        let wrongFingerprint = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { wrongFingerprint.closePeer() }
        #expect(try wrongFingerprint.readFrame().type == .ready)
        try wrongFingerprint.write(
            .init(
                type: .processAttach,
                id: executionID,
                cursor: sameGeneration.cursor,
                expectedLaunchFingerprint: String(repeating: "0", count: 64),
                storageGeneration: 70
            )
        )
        let fingerprintError = try wrongFingerprint.readFrame()
        #expect(fingerprintError.type == .error)
        #expect(fingerprintError.message?.contains("launch fingerprint does not match") == true)

        let stale = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { stale.closePeer() }
        #expect(try stale.readFrame().type == .ready)
        try stale.write(
            .init(
                type: .processAttach,
                id: executionID,
                cursor: sameGeneration.cursor,
                expectedLaunchFingerprint: created.launchFingerprint,
                storageGeneration: 69
            )
        )
        let staleError = try stale.readFrame()
        #expect(staleError.type == .error)
        #expect(staleError.message?.contains("bound to storage generation 70") == true)

        let adopter = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { adopter.closePeer() }
        #expect(try adopter.readFrame().type == .ready)
        try adopter.write(
            .init(
                type: .processAttach,
                id: executionID,
                cursor: sameGeneration.cursor,
                expectedLaunchFingerprint: created.launchFingerprint,
                storageGeneration: 71,
                previousStorageGeneration: 70
            )
        )
        let adopted = try decodeDurableStatus(from: adopter.readFrame())
        #expect(adopted.storageGeneration == 71)
        #expect(try supervisor.inspect(executionID: executionID).storageGeneration == 71)

        let oldGeneration = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { oldGeneration.closePeer() }
        #expect(try oldGeneration.readFrame().type == .ready)
        try oldGeneration.write(
            .init(
                type: .processAttach,
                id: executionID,
                cursor: adopted.cursor,
                expectedLaunchFingerprint: created.launchFingerprint,
                storageGeneration: 70
            )
        )
        let oldGenerationError = try oldGeneration.readFrame()
        #expect(oldGenerationError.type == .error)
        #expect(oldGenerationError.message?.contains("bound to storage generation 71") == true)

        try deleteDurableProcess(id: executionID, through: adopter)
        try creator.waitForCompletion()
        try reconnected.waitForCompletion()
        try wrongFingerprint.waitForCompletion()
        try stale.waitForCompletion()
        try adopter.waitForCompletion()
        try oldGeneration.waitForCompletion()
    }

    @Test
    func warmExecRetryAdoptsExistingProcessIntoSuccessorGeneration() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "warm-exec-adoption"
        let script = "while :; do sleep 1; done"

        let creator = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { creator.closePeer() }
        #expect(try creator.readFrame().type == .ready)
        try creator.write(durableExecFrame(id: executionID, script: script, storageGeneration: 100))
        let created = try decodeDurableStatus(from: creator.readFrame())

        let adopter = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { adopter.closePeer() }
        #expect(try adopter.readFrame().type == .ready)
        try adopter.write(
            durableExecFrame(
                id: executionID,
                script: script,
                expectedLaunchFingerprint: created.launchFingerprint,
                storageGeneration: 101,
                previousStorageGeneration: 100
            )
        )
        let adopted = try decodeDurableStatus(from: adopter.readFrame())
        #expect(adopted.disposition == .existing)
        #expect(adopted.processIdentifier == created.processIdentifier)
        #expect(adopted.storageGeneration == 101)
        #expect(try supervisor.inspect(executionID: executionID).storageGeneration == 101)

        try deleteDurableProcess(id: executionID, through: adopter)
        try creator.waitForCompletion()
        try adopter.waitForCompletion()
    }

    @Test
    func concurrentGenerationAdoptionCommitsOneSuccessfulAcknowledgementWithoutRollback() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "concurrent-adoption"

        let owner = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { owner.closePeer() }
        #expect(try owner.readFrame().type == .ready)
        try owner.write(
            durableExecFrame(
                id: executionID,
                script: "while :; do sleep 1; done",
                storageGeneration: 90
            )
        )
        let created = try decodeDurableStatus(from: owner.readFrame())

        let firstPair = try makeDurableProcessSocketPair()
        defer { closeDurableProcessFD(firstPair.peer) }
        let firstConnection = AgentConnection(fd: firstPair.server, processSupervisor: supervisor)
        let secondPair = try makeDurableProcessSocketPair()
        defer { closeDurableProcessFD(secondPair.peer) }
        let secondConnection = AgentConnection(fd: secondPair.server, processSupervisor: supervisor)
        let firstResult = DurableLockedValue<Result<GuestProcessAttachmentHandle, Error>?>(nil)
        let secondResult = DurableLockedValue<Result<GuestProcessAttachmentHandle, Error>?>(nil)
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let attachFrame = GuestAgentFrame(
            type: .processAttach,
            id: executionID,
            cursor: created.cursor,
            expectedLaunchFingerprint: created.launchFingerprint,
            storageGeneration: 91,
            previousStorageGeneration: 90
        )

        for (connection, result) in [
            (firstConnection, firstResult),
            (secondConnection, secondResult),
        ] {
            Thread.detachNewThread {
                ready.signal()
                start.wait()
                result.withLock { value in
                    value = Result {
                        try supervisor.attach(
                            frame: attachFrame,
                            connection: connection,
                            cursor: created.cursor
                        )
                    }
                }
                finished.signal()
            }
        }
        #expect(ready.wait(timeout: .now() + 1) == .success)
        #expect(ready.wait(timeout: .now() + 1) == .success)
        start.signal()
        start.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(finished.wait(timeout: .now() + 2) == .success)

        let outcomes = [
            (firstResult.withLock { $0 }, firstPair.peer),
            (secondResult.withLock { $0 }, secondPair.peer),
        ]
        let successes = outcomes.compactMap { outcome, peer -> (GuestProcessAttachmentHandle, Int32)? in
            guard case .success(let handle) = outcome else { return nil }
            return (handle, peer)
        }
        let failures = outcomes.compactMap { outcome, _ -> NSError? in
            guard case .failure(let error) = outcome else { return nil }
            return error as NSError
        }
        #expect(successes.count == 1)
        #expect(failures.count == 1)
        #expect(failures.first?.code == Int(EBUSY) || failures.first?.code == Int(ESTALE))

        let committed = try #require(successes.first)
        let acknowledgement = try decodeDurableStatus(from: readDurableProcessFrame(fd: committed.1))
        #expect(acknowledgement.storageGeneration == 91)
        #expect(try supervisor.inspect(executionID: executionID).storageGeneration == 91)
        _ = try supervisor.delete(handle: committed.0)
        firstConnection.invalidate()
        secondConnection.invalidate()
        try owner.waitForCompletion()
    }

    @Test
    func blockedStdinDoesNotHoldProcessStateLock() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "blocked-stdin"

        let pair = try makeDurableProcessSocketPair()
        defer { closeDurableProcessFD(pair.peer) }
        let connection = AgentConnection(fd: pair.server, processSupervisor: supervisor)
        let handle = try supervisor.createAndAttach(
            frame: durableExecFrame(id: executionID, script: "while :; do sleep 1; done"),
            connection: connection,
            cursor: 0
        )
        let created = try decodeDurableStatus(from: readDurableProcessFrame(fd: pair.peer))

        let writeStarted = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let writeError = DurableLockedValue<Error?>(nil)
        Thread.detachNewThread {
            writeStarted.signal()
            do {
                try supervisor.writeStdin(Data(repeating: 0x41, count: 8 * 1024 * 1024), handle: handle)
            } catch {
                writeError.withLock { $0 = error }
            }
            writeFinished.signal()
        }
        #expect(writeStarted.wait(timeout: .now() + 1) == .success)
        usleep(100_000)
        #expect(writeFinished.wait(timeout: .now()) == .timedOut)

        let inspectFinished = DispatchSemaphore(value: 0)
        let inspected = DurableLockedValue<MacOSGuestProcessStatusPayload?>(nil)
        Thread.detachNewThread {
            inspected.withLock { $0 = try? supervisor.inspect(executionID: executionID) }
            inspectFinished.signal()
        }
        #expect(inspectFinished.wait(timeout: .now() + 1) == .success)
        #expect(inspected.withLock { $0?.processIdentifier } == created.processIdentifier)

        #expect(Darwin.kill(-created.processIdentifier, SIGKILL) == 0)
        #expect(writeFinished.wait(timeout: .now() + 2) == .success)
        #expect(writeError.withLock { $0 } != nil)
        _ = try supervisor.delete(handle: handle)
        connection.invalidate()
    }

    @Test
    func generationHandoffCompletesWhilePreviousControllerStdinIsBlocked() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor(attachmentWriteTimeout: 2)
        defer { supervisor.removeAllForTesting() }
        let executionID = "blocked-stdin-handoff"

        let ownerPair = try makeDurableProcessSocketPair()
        defer { closeDurableProcessFD(ownerPair.peer) }
        let ownerConnection = AgentConnection(fd: ownerPair.server, processSupervisor: supervisor)
        let ownerHandle = try supervisor.createAndAttach(
            frame: durableExecFrame(
                id: executionID,
                script: "while :; do sleep 1; done",
                storageGeneration: 200
            ),
            connection: ownerConnection,
            cursor: 0
        )
        let created = try decodeDurableStatus(from: readDurableProcessFrame(fd: ownerPair.peer))

        let writeStarted = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let writeError = DurableLockedValue<Error?>(nil)
        Thread.detachNewThread {
            writeStarted.signal()
            do {
                try supervisor.writeStdin(Data(repeating: 0x41, count: 8 * 1024 * 1024), handle: ownerHandle)
            } catch {
                writeError.withLock { $0 = error }
            }
            writeFinished.signal()
        }
        #expect(writeStarted.wait(timeout: .now() + 1) == .success)
        usleep(100_000)
        #expect(writeFinished.wait(timeout: .now()) == .timedOut)

        let successorPair = try makeDurableProcessSocketPair()
        defer { closeDurableProcessFD(successorPair.peer) }
        let successorConnection = AgentConnection(fd: successorPair.server, processSupervisor: supervisor)
        let handoffStarted = Date()
        let successorHandle = try supervisor.attach(
            frame: .init(
                type: .processAttach,
                id: executionID,
                cursor: created.cursor,
                expectedLaunchFingerprint: created.launchFingerprint,
                storageGeneration: 201,
                previousStorageGeneration: 200
            ),
            connection: successorConnection,
            cursor: created.cursor
        )
        #expect(Date().timeIntervalSince(handoffStarted) < 1)
        let adopted = try decodeDurableStatus(from: readDurableProcessFrame(fd: successorPair.peer))
        #expect(adopted.storageGeneration == 201)

        #expect(writeFinished.wait(timeout: .now() + 1) == .success)
        let staleWriteError = try #require(writeError.withLock { $0 } as NSError?)
        #expect(staleWriteError.code == Int(EPERM))

        _ = try supervisor.delete(handle: successorHandle)
        ownerConnection.invalidate()
        successorConnection.invalidate()
    }

    @Test
    func deletedIncarnationCannotRestartButNewIncarnationCan() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "tombstone-restart"
        let trustedFingerprint = "sha256:\(String(repeating: "a", count: 64))"
        let oldIncarnation = "sha256:\(String(repeating: "b", count: 64))"
        let newIncarnation = "sha256:\(String(repeating: "c", count: 64))"

        let owner = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { owner.closePeer() }
        #expect(try owner.readFrame().type == .ready)
        let oldStart = durableExecFrame(
            id: executionID,
            script: "exec /bin/sleep 100",
            trustedLaunchFingerprint: trustedFingerprint,
            incarnation: oldIncarnation,
            storageGeneration: 9
        )
        try owner.write(oldStart)
        let created = try decodeDurableStatus(from: owner.readFrame())
        #expect(created.trustedLaunchFingerprint == trustedFingerprint)
        #expect(created.incarnation == oldIncarnation)

        try owner.write(
            durableDeleteFrame(
                id: executionID,
                guestLaunchFingerprint: created.launchFingerprint,
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: oldIncarnation,
                storageGeneration: 9
            )
        )
        let deleted = try decodeDurableStatus(from: owner.readFrame())
        #expect(deleted.state == .deleted)

        let delayedRetry = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { delayedRetry.closePeer() }
        #expect(try delayedRetry.readFrame().type == .ready)
        try delayedRetry.write(oldStart)
        let stale = try delayedRetry.readFrame()
        #expect(stale.type == .error)
        #expect(stale.errorCode == ESTALE)

        let successor = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { successor.closePeer() }
        #expect(try successor.readFrame().type == .ready)
        try successor.write(
            durableExecFrame(
                id: executionID,
                script: "exec /bin/sleep 100",
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: newIncarnation,
                storageGeneration: 9
            )
        )
        let recreated = try decodeDurableStatus(from: successor.readFrame())
        #expect(recreated.disposition == .created)
        #expect(recreated.incarnation == newIncarnation)
        try successor.write(
            durableDeleteFrame(
                id: executionID,
                guestLaunchFingerprint: recreated.launchFingerprint,
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: newIncarnation,
                storageGeneration: 9
            )
        )
        _ = try decodeDurableStatus(from: successor.readFrame())
    }

    @Test
    func missingDeleteTombstoneWinsAgainstDelayedStart() throws {
        signal(SIGPIPE, SIG_IGN)
        let beforeLock = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let shouldBlock = DurableLockedValue(true)
        let supervisor = GuestProcessSupervisor(beforeCreateLock: {
            let block = shouldBlock.withLock { value -> Bool in
                defer { value = false }
                return value
            }
            if block {
                beforeLock.signal()
                _ = releaseStart.wait(timeout: .now() + 2)
            }
        })
        defer { supervisor.removeAllForTesting() }
        let executionID = "missing-delete-race"
        let trustedFingerprint = "sha256:\(String(repeating: "d", count: 64))"
        let oldIncarnation = "sha256:\(String(repeating: "e", count: 64))"

        let delayedStart = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { delayedStart.closePeer() }
        #expect(try delayedStart.readFrame().type == .ready)
        try delayedStart.write(
            durableExecFrame(
                id: executionID,
                script: "exec /bin/sleep 100",
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: oldIncarnation,
                storageGeneration: 12
            )
        )
        #expect(beforeLock.wait(timeout: .now() + 2) == .success)

        let deleter = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { deleter.closePeer() }
        #expect(try deleter.readFrame().type == .ready)
        try deleter.write(
            durableDeleteFrame(
                id: executionID,
                guestLaunchFingerprint: nil,
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: oldIncarnation,
                storageGeneration: 12
            )
        )
        let tombstoned = try deleter.readFrame()
        #expect(tombstoned.type == .ack)
        #expect(tombstoned.data == nil)

        try deleter.write(
            durableDeleteFrame(
                id: executionID,
                guestLaunchFingerprint: "sha256:\(String(repeating: "1", count: 64))",
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: oldIncarnation,
                storageGeneration: 12
            )
        )
        #expect(try deleter.readFrame().type == .ack)

        releaseStart.signal()
        let stale = try delayedStart.readFrame()
        #expect(stale.type == .error)
        #expect(stale.errorCode == ESTALE)
        #expect(throws: (any Error).self) {
            _ = try supervisor.inspect(executionID: executionID)
        }

        let newIncarnation = "sha256:\(String(repeating: "f", count: 64))"
        let successor = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { successor.closePeer() }
        #expect(try successor.readFrame().type == .ready)
        try successor.write(
            durableExecFrame(
                id: executionID,
                script: "exec /bin/sleep 100",
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: newIncarnation,
                storageGeneration: 12
            )
        )
        let created = try decodeDurableStatus(from: successor.readFrame())
        #expect(created.disposition == .created)
        try successor.write(
            durableDeleteFrame(
                id: executionID,
                guestLaunchFingerprint: created.launchFingerprint,
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: newIncarnation,
                storageGeneration: 12
            )
        )
        _ = try decodeDurableStatus(from: successor.readFrame())
    }

    @Test
    func deletingAnOlderIncarnationFencesItWithoutDeletingTheCurrentProcess() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "superseded-delete"
        let trustedFingerprint = "sha256:\(String(repeating: "1", count: 64))"
        let oldIncarnation = "sha256:\(String(repeating: "2", count: 64))"
        let currentIncarnation = "sha256:\(String(repeating: "3", count: 64))"

        let current = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { current.closePeer() }
        #expect(try current.readFrame().type == .ready)
        try current.write(
            durableExecFrame(
                id: executionID,
                script: "exec /bin/sleep 100",
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: currentIncarnation,
                storageGeneration: 14
            )
        )
        let created = try decodeDurableStatus(from: current.readFrame())

        let staleDeleter = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { staleDeleter.closePeer() }
        #expect(try staleDeleter.readFrame().type == .ready)
        try staleDeleter.write(
            durableDeleteFrame(
                id: executionID,
                guestLaunchFingerprint: nil,
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: oldIncarnation,
                storageGeneration: 14
            )
        )
        let fenced = try staleDeleter.readFrame()
        #expect(fenced.type == .ack)
        #expect(fenced.data == nil)
        #expect(try supervisor.inspect(executionID: executionID).incarnation == currentIncarnation)

        try current.write(
            durableDeleteFrame(
                id: executionID,
                guestLaunchFingerprint: created.launchFingerprint,
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: currentIncarnation,
                storageGeneration: 14
            )
        )
        #expect(try decodeDurableStatus(from: current.readFrame()).state == .deleted)

        let delayedStart = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { delayedStart.closePeer() }
        #expect(try delayedStart.readFrame().type == .ready)
        try delayedStart.write(
            durableExecFrame(
                id: executionID,
                script: "exec /bin/sleep 100",
                trustedLaunchFingerprint: trustedFingerprint,
                incarnation: oldIncarnation,
                storageGeneration: 14
            )
        )
        let stale = try delayedStart.readFrame()
        #expect(stale.type == .error)
        #expect(stale.errorCode == ESTALE)
    }

    @Test
    func leaderExitTerminatesRemainingProcessGroupBeforePublishingExit() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let directory = try makeDurableProcessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descendantPIDFile = directory.appendingPathComponent("descendant-pid")
        let executionID = "descendant-cleanup"

        let connection = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { connection.closePeer() }
        #expect(try connection.readFrame().type == .ready)
        try connection.write(
            durableExecFrame(
                id: executionID,
                script: "/bin/sleep 100 & printf '%s' $! > \"$DESCENDANT_PID_FILE\"; exit 0",
                additionalEnvironment: ["DESCENDANT_PID_FILE=\(descendantPIDFile.path)"]
            )
        )
        _ = try decodeDurableStatus(from: connection.readFrame())
        try waitForDurableProcessCondition {
            FileManager.default.fileExists(atPath: descendantPIDFile.path)
        }
        let descendantPID = try #require(Int32(String(contentsOf: descendantPIDFile, encoding: .utf8)))

        var exitFrame: GuestAgentFrame?
        while exitFrame == nil {
            let frame = try connection.readFrame()
            if frame.type == .exit {
                exitFrame = frame
            }
        }
        #expect(exitFrame?.exitCode == 0)
        try waitForDurableProcessCondition {
            !durableProcessExists(descendantPID)
        }

        try deleteDurableProcess(id: executionID, through: connection)
        try connection.waitForCompletion()
    }

    @Test
    func rootDirectoryIsAppliedRatherThanOnlyFingerprintingTheRequest() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let executionID = "root-directory"
        let nonexistentRoot = "/private/tmp/container-durable-missing-root-\(UUID().uuidString)"

        let connection = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { connection.closePeer() }
        #expect(try connection.readFrame().type == .ready)
        try connection.write(
            GuestAgentFrame(
                type: .exec,
                id: executionID,
                executable: "/bin/sh",
                arguments: ["-c", "exit 0"],
                environment: ["PATH=/usr/bin:/bin"],
                rootDirectory: nonexistentRoot,
                workingDirectory: "/",
                terminal: false,
                durable: true,
                uid: UInt32(geteuid()),
                gid: UInt32(getegid())
            )
        )

        let response = try connection.readFrame()
        #expect(response.type == .error)
        #expect(response.id == executionID)
        #expect(throws: (any Error).self) {
            _ = try supervisor.inspect(executionID: executionID)
        }
        try connection.waitForCompletion()
    }

    @Test
    func legacyExecRemainsConnectionScoped() throws {
        signal(SIGPIPE, SIG_IGN)
        let supervisor = GuestProcessSupervisor()
        defer { supervisor.removeAllForTesting() }
        let directory = try makeDurableProcessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")

        let connection = try DurableAgentConnectionHarness(supervisor: supervisor)
        defer { connection.closePeer() }
        #expect(try connection.readFrame().type == .ready)
        try connection.write(
            GuestAgentFrame(
                type: .exec,
                id: "legacy",
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s' $$ > \"$PID_FILE\"; while :; do sleep 1; done"],
                environment: [
                    "PATH=/usr/bin:/bin",
                    "PID_FILE=\(pidFile.path)",
                ],
                workingDirectory: "/",
                terminal: false,
                uid: UInt32(geteuid()),
                gid: UInt32(getegid())
            )
        )
        #expect(try connection.readFrame().type == .ack)
        try waitForDurableProcessCondition {
            FileManager.default.fileExists(atPath: pidFile.path)
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(durableProcessExists(pid))

        connection.closePeer()
        try connection.waitForCompletion()
        try waitForDurableProcessCondition {
            !durableProcessExists(pid)
        }
    }
}

private final class DurableAgentConnectionHarness: @unchecked Sendable {
    let peerFD: Int32

    private let done = DispatchSemaphore(value: 0)
    private let errorBox = DurableLockedValue<Error?>(nil)
    private let peerBox: DurableLockedValue<Int32?>

    init(supervisor: GuestProcessSupervisor) throws {
        let pair = try makeDurableProcessSocketPair()
        self.peerFD = pair.peer
        self.peerBox = DurableLockedValue(pair.peer)

        Thread.detachNewThread {
            defer { self.done.signal() }
            do {
                try AgentConnection(fd: pair.server, processSupervisor: supervisor).run()
            } catch {
                self.errorBox.withLock { $0 = error }
            }
        }
    }

    func write(_ frame: GuestAgentFrame) throws {
        try MacOSSidecarSocketIO.writeJSONFrame(frame, fd: peerFD)
    }

    func readFrame(timeoutMilliseconds: Int32 = 2_000) throws -> GuestAgentFrame {
        try readDurableProcessFrame(fd: peerFD, timeoutMilliseconds: timeoutMilliseconds)
    }

    func closePeer() {
        closeDurableProcessFD(
            peerBox.withLock { current in
                let fd = current
                current = nil
                return fd
            }
        )
    }

    func waitForCompletion(timeout: TimeInterval = 2) throws {
        closePeer()
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw NSError(
                domain: "DurableAgentConnectionHarness.waitForCompletion",
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for the guest-agent connection thread"]
            )
        }
        if let error = errorBox.withLock({ $0 }) {
            throw error
        }
    }
}

private func readDurableProcessFrame(
    fd: Int32,
    timeoutMilliseconds: Int32 = 2_000
) throws -> GuestAgentFrame {
    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let result = Darwin.poll(&pollFD, 1, timeoutMilliseconds)
    guard result > 0 else {
        if result == 0 {
            throw NSError(
                domain: "DurableGuestProcessSupervisorTests.readFrame",
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for a guest-agent frame"]
            )
        }
        throw POSIXError.fromErrno()
    }
    return try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: fd)
}

private func durableExecFrame(
    id: String,
    script: String,
    additionalEnvironment: [String] = [],
    expectedLaunchFingerprint: String? = nil,
    trustedLaunchFingerprint: String? = nil,
    incarnation: String? = nil,
    storageGeneration: UInt64? = nil,
    previousStorageGeneration: UInt64? = nil
) -> GuestAgentFrame {
    GuestAgentFrame(
        type: .exec,
        id: id,
        executable: "/bin/sh",
        arguments: ["-c", script],
        environment: ["PATH=/usr/bin:/bin"] + additionalEnvironment,
        workingDirectory: "/",
        terminal: false,
        durable: true,
        expectedLaunchFingerprint: expectedLaunchFingerprint,
        trustedLaunchFingerprint: trustedLaunchFingerprint,
        incarnation: incarnation,
        storageGeneration: storageGeneration,
        previousStorageGeneration: previousStorageGeneration,
        uid: UInt32(geteuid()),
        gid: UInt32(getegid())
    )
}

private func durableDeleteFrame(
    id: String,
    guestLaunchFingerprint: String?,
    trustedLaunchFingerprint: String,
    incarnation: String,
    storageGeneration: UInt64?
) -> GuestAgentFrame {
    .init(
        type: .processDelete,
        id: id,
        expectedLaunchFingerprint: guestLaunchFingerprint,
        trustedLaunchFingerprint: trustedLaunchFingerprint,
        incarnation: incarnation,
        storageGeneration: storageGeneration
    )
}

private func decodeDurableStatus(from frame: GuestAgentFrame) throws -> MacOSGuestProcessStatusPayload {
    #expect(frame.type == .ack)
    return try JSONDecoder().decode(MacOSGuestProcessStatusPayload.self, from: try #require(frame.data))
}

private func deleteDurableProcess(id: String, through connection: DurableAgentConnectionHarness) throws {
    try connection.write(.init(type: .processDelete, id: id))
    let status = try decodeDurableStatus(from: connection.readFrame())
    #expect(status.disposition == .deleted)
    #expect(status.state == .deleted)
}

private func makeDurableProcessTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("container-durable-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func waitForDurableProcessCondition(
    timeout: TimeInterval = 3,
    _ condition: () throws -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() {
            return
        }
        usleep(20_000)
    }
    throw NSError(
        domain: "DurableGuestProcessSupervisorTests.waitForCondition",
        code: Int(ETIMEDOUT),
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for a durable-process condition"]
    )
}

private func durableProcessExists(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if Darwin.kill(pid, 0) == 0 {
        return true
    }
    return errno != ESRCH
}

private final class DurableLockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func makeDurableProcessSocketPair() throws -> (server: Int32, peer: Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    do {
        try setGuestAgentCloseOnExec(descriptors[0])
        try setGuestAgentCloseOnExec(descriptors[1])
    } catch {
        closeDurableProcessFD(descriptors[0])
        closeDurableProcessFD(descriptors[1])
        throw error
    }
    return (descriptors[0], descriptors[1])
}

private func closeDurableProcessFD(_ descriptor: Int32?) {
    guard let descriptor, descriptor >= 0 else { return }
    Darwin.close(descriptor)
}

#endif
