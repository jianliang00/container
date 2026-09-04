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
import ContainerResource
import ContainerizationError
import Foundation
import Logging
import RuntimeMacOSSidecarShared
import Testing

@testable import container_runtime_macos_sidecar

@Suite(.serialized)
struct SidecarControlServerTests {
    @Test
    func machineStateControlClientDoesNotReplaceExplicitEventSubscriber() throws {
        signal(SIGPIPE, SIG_IGN)
        let socketPath = "/tmp/runtime-macos-sidecar-events-\(UUID().uuidString).sock"
        let server = makeServer(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let runtimeFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(runtimeFD) }
        let subscription = MacOSSidecarRequest(
            requestID: "subscribe",
            method: .eventsSubscribe,
            protocolVersion: MacOSSidecarProtocolVersion.machineState
        )
        try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(subscription), fd: runtimeFD)
        #expect(try responseFrame(fd: runtimeFD).ok)

        let contenderFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        let contender = MacOSSidecarRequest(
            requestID: "contender",
            method: .eventsSubscribe,
            protocolVersion: MacOSSidecarProtocolVersion.machineState
        )
        try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(contender), fd: contenderFD)
        #expect(try responseFrame(fd: contenderFD).error?.code == "eventClientAlreadySubscribed")
        closeIfValid(contenderFD)

        let controlFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        let capabilities = MacOSSidecarRequest(
            requestID: "capabilities",
            method: .vmCapabilities,
            protocolVersion: MacOSSidecarProtocolVersion.machineState
        )
        try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(capabilities), fd: controlFD)
        #expect(try responseFrame(fd: controlFD).ok)
        closeIfValid(controlFD)

        server._testEmitEvent(
            .init(event: .processStdout, processID: "process-1", data: Data("preserved\n".utf8))
        )
        let eventEnvelope = try readableEnvelope(fd: runtimeFD)
        #expect(eventEnvelope.kind == .event)
        #expect(eventEnvelope.event?.event == .processStdout)
        #expect(eventEnvelope.event?.processID == "process-1")
        #expect(eventEnvelope.event?.data == Data("preserved\n".utf8))
    }

    @Test
    func legacyRuntimeRequestClaimsOnlyAnUnownedEventSubscription() throws {
        signal(SIGPIPE, SIG_IGN)
        let socketPath = "/tmp/runtime-macos-sidecar-legacy-events-\(UUID().uuidString).sock"
        let server = makeServer(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let legacyFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(legacyFD) }
        let legacyRequest = MacOSSidecarRequest(requestID: "legacy", method: .vmShowGUI)
        try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(legacyRequest), fd: legacyFD)
        _ = try responseFrame(fd: legacyFD)

        let controlFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(controlFD) }
        let pause = MacOSSidecarRequest(
            requestID: "pause",
            method: .vmPause,
            protocolVersion: MacOSSidecarProtocolVersion.machineState
        )
        try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(pause), fd: controlFD)
        _ = try responseFrame(fd: controlFD)

        server._testEmitEvent(.init(event: .processExit, processID: "legacy-process", exitCode: 0))
        let eventEnvelope = try readableEnvelope(fd: legacyFD)
        #expect(eventEnvelope.kind == .event)
        #expect(eventEnvelope.event?.event == .processExit)
        #expect(eventEnvelope.event?.processID == "legacy-process")
    }

    @Test
    func cleanupCreatesSecureParentsAndSupportsSystemTemporaryDirectoryAlias() throws {
        let root = URL(fileURLWithPath: "/tmp/runtime-macos-sidecar-security-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("nested")
        let socketPath = parent.appendingPathComponent("control.sock").path
        let server = makeServer(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        var rootValue = stat()
        var parentValue = stat()
        #expect(lstat(root.path, &rootValue) == 0)
        #expect(lstat(parent.path, &parentValue) == 0)
        #expect(rootValue.st_uid == geteuid())
        #expect(parentValue.st_uid == geteuid())
        #expect(rootValue.st_mode & mode_t(0o777) == mode_t(0o700))
        #expect(parentValue.st_mode & mode_t(0o777) == mode_t(0o700))

        var socketValue = stat()
        #expect(lstat(socketPath, &socketValue) == 0)
        #expect(socketValue.st_mode & S_IFMT == S_IFSOCK)
        #expect(socketValue.st_uid == geteuid())
        #expect(socketValue.st_mode & mode_t(0o777) == mode_t(0o600))

        let clientFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        closeIfValid(clientFD)

        server.stop()
        #expect(lstat(socketPath, &socketValue) != 0)
        #expect(errno == ENOENT)
    }

    @Test
    func cleanupRefusesToReplaceActiveCurrentUserSocket() throws {
        let root = try makeSocketSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("active.sock").path
        let firstServer = makeServer(socketPath: socketPath)
        try firstServer.start()
        defer { firstServer.stop() }

        let secondServer = makeServer(socketPath: socketPath)
        #expect(throws: Error.self) {
            try secondServer.start()
        }

        let clientFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        closeIfValid(clientFD)
    }

    @Test
    func stopPreservesPathReplacementWithDifferentIdentity() throws {
        let root = try makeSocketSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent("control.sock")
        let server = makeServer(socketPath: socketURL.path)
        try server.start()

        guard unlink(socketURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try Data("replacement".utf8).write(to: socketURL)

        server.stop()
        #expect(try Data(contentsOf: socketURL) == Data("replacement".utf8))
    }

    @Test
    func cleanupReplacesOnlyCurrentUserOwnedUnixSockets() throws {
        let root = try makeSocketSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("stale.sock").path
        let staleFD = try bindUnixSocket(path: socketPath)
        closeIfValid(staleFD)

        let server = makeServer(socketPath: socketPath)
        let mismatchedOwnerID: uid_t = geteuid() == 0 ? 1 : 0
        #expect(throws: Error.self) {
            try server._testCleanupStaleSocket(requiredOwnerID: mismatchedOwnerID)
        }
        var staleValue = stat()
        #expect(lstat(socketPath, &staleValue) == 0)
        #expect(staleValue.st_mode & S_IFMT == S_IFSOCK)

        try server.start()
        defer { server.stop() }
        let clientFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        closeIfValid(clientFD)
    }

    @Test
    func cleanupRejectsNonSocketTargetsWithoutRemovingThem() throws {
        let root = try makeSocketSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let regularFile = root.appendingPathComponent("regular.sock")
        try Data("keep".utf8).write(to: regularFile)
        let directory = root.appendingPathComponent("directory.sock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fifo = root.appendingPathComponent("fifo.sock")
        guard mkfifo(fifo.path, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        for target in [regularFile, directory, fifo] {
            let server = makeServer(socketPath: target.path)
            #expect(throws: Error.self) {
                try server.start()
            }
            var value = stat()
            #expect(lstat(target.path, &value) == 0)
        }
    }

    @Test
    func cleanupRejectsSymbolicLinksInTargetAndParentComponents() throws {
        let root = try makeSocketSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        let socketLink = root.appendingPathComponent("linked.sock")
        try FileManager.default.createSymbolicLink(at: socketLink, withDestinationURL: target)
        #expect(throws: Error.self) {
            try makeServer(socketPath: socketLink.path).start()
        }

        let realParent = root.appendingPathComponent("real-parent")
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        guard chmod(realParent.path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let linkedParent = root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        #expect(throws: Error.self) {
            try makeServer(socketPath: linkedParent.appendingPathComponent("control.sock").path).start()
        }
        #expect(!FileManager.default.fileExists(atPath: realParent.appendingPathComponent("control.sock").path))
    }

    @Test
    func cleanupRejectsWritableParentDirectories() throws {
        let root = try makeSocketSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writableParent = root.appendingPathComponent("writable")
        try FileManager.default.createDirectory(at: writableParent, withIntermediateDirectories: false)
        guard chmod(writableParent.path, mode_t(0o777)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        #expect(throws: Error.self) {
            try makeServer(socketPath: writableParent.appendingPathComponent("control.sock").path).start()
        }
    }

    @Test
    func newExplicitSubscriberCanClaimAfterPreviousSubscriberDisconnect() throws {
        signal(SIGPIPE, SIG_IGN)

        let fixture = try makeStartedServer()
        defer {
            fixture.server.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        var firstSubscriberFD = try MacOSSidecarSocketIO.connectUnixSocket(path: fixture.socketPath)
        defer { closeIfValid(firstSubscriberFD) }
        let secondSubscriberFD = try MacOSSidecarSocketIO.connectUnixSocket(path: fixture.socketPath)
        defer { closeIfValid(secondSubscriberFD) }

        try writeRequest(
            .init(
                requestID: "subscribe-first",
                method: .eventsSubscribe,
                protocolVersion: MacOSSidecarProtocolVersion.machineState
            ),
            to: firstSubscriberFD
        )
        #expect(try responseFrame(fd: firstSubscriberFD).ok)

        _ = Darwin.shutdown(firstSubscriberFD, SHUT_RDWR)
        closeIfValid(firstSubscriberFD)
        firstSubscriberFD = -1
        #expect(waitUntil { !fixture.server._testHasEventClient() })

        try writeRequest(
            .init(
                requestID: "subscribe-second",
                method: .eventsSubscribe,
                protocolVersion: MacOSSidecarProtocolVersion.machineState
            ),
            to: secondSubscriberFD
        )
        #expect(try responseFrame(fd: secondSubscriberFD).ok)

        fixture.server._testEmitEvent(.init(event: .processExit, processID: "new-subscriber", exitCode: 0))
        let event = try eventFrame(fd: secondSubscriberFD)
        #expect(event.processID == "new-subscriber")
        #expect(event.exitCode == 0)
        #expect(fixture.server._testHasEventClient())

        _ = Darwin.shutdown(secondSubscriberFD, SHUT_RDWR)
        #expect(waitUntil { !fixture.server._testHasEventClient() })
    }

    @Test
    func durableEventWriteWithoutConsumerAckReplaysAfterReconnect() throws {
        signal(SIGPIPE, SIG_IGN)
        let fixture = try makeStartedServer()
        defer {
            fixture.server.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let acknowledged = LockedValue(0)

        var firstFD = try MacOSSidecarSocketIO.connectUnixSocket(path: fixture.socketPath)
        let firstSubscription = try subscribeDurableEvents(fd: firstFD, requestID: "subscribe-first-v3")
        fixture.server._testEmitEvent(
            .init(
                event: .processStdout,
                processID: "durable-process",
                data: Data("not-consumed".utf8),
                sequence: 1
            ),
            acknowledged: { acknowledged.withLock { $0 += 1 } }
        )

        let firstDelivery = try eventFrame(fd: firstFD)
        #expect(firstDelivery.sequence == 1)
        #expect(firstDelivery.subscriptionID == firstSubscription.subscriptionID)
        #expect(fixture.server._testPendingEventCount() == 1)
        #expect(acknowledged.withLock { $0 } == 0)

        _ = Darwin.shutdown(firstFD, SHUT_RDWR)
        closeIfValid(firstFD)
        firstFD = -1
        #expect(waitUntil { !fixture.server._testHasEventClient() })

        let secondFD = try MacOSSidecarSocketIO.connectUnixSocket(path: fixture.socketPath)
        defer { closeIfValid(secondFD) }
        let secondSubscription = try subscribeDurableEvents(fd: secondFD, requestID: "subscribe-second-v3")
        #expect(secondSubscription.subscriptionID != firstSubscription.subscriptionID)
        let replayed = try eventFrame(fd: secondFD)
        #expect(replayed.sequence == 1)
        #expect(replayed.data == Data("not-consumed".utf8))
        #expect(replayed.subscriptionID == secondSubscription.subscriptionID)

        let outOfRange = try acknowledgeDurableEvent(
            subscriptionID: secondSubscription.subscriptionID,
            processID: "durable-process",
            sequence: 2,
            fd: secondFD,
            requestID: "ack-out-of-range"
        )
        #expect(outOfRange.error?.code == "eventAcknowledgementOutOfRange")
        #expect(fixture.server._testPendingEventCount() == 1)

        let stale = try acknowledgeDurableEvent(
            subscriptionID: firstSubscription.subscriptionID,
            processID: "durable-process",
            sequence: 1,
            fd: secondFD,
            requestID: "ack-stale"
        )
        #expect(stale.error?.code == "staleEventSubscription")
        #expect(fixture.server._testPendingEventCount() == 1)

        let accepted = try acknowledgeDurableEvent(
            subscriptionID: secondSubscription.subscriptionID,
            processID: "durable-process",
            sequence: 1,
            fd: secondFD,
            requestID: "ack-accepted"
        )
        #expect(accepted.ok)
        #expect(waitUntil { fixture.server._testPendingEventCount() == 0 })
        #expect(acknowledged.withLock { $0 } == 1)

        let duplicate = try acknowledgeDurableEvent(
            subscriptionID: secondSubscription.subscriptionID,
            processID: "durable-process",
            sequence: 1,
            fd: secondFD,
            requestID: "ack-duplicate"
        )
        #expect(duplicate.ok)
        #expect(acknowledged.withLock { $0 } == 1)
    }

    @Test
    func durableExitIsRetainedUntilCumulativeConsumerAck() throws {
        let fixture = try makeStartedServer()
        defer {
            fixture.server.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let acknowledged = LockedValue<[UInt64]>([])
        let subscriberFD = try MacOSSidecarSocketIO.connectUnixSocket(path: fixture.socketPath)
        defer { closeIfValid(subscriberFD) }
        let subscription = try subscribeDurableEvents(fd: subscriberFD, requestID: "subscribe-exit-v3")

        fixture.server._testEmitEvent(
            .init(event: .processStdout, processID: "terminal-process", data: Data("final".utf8), sequence: 1),
            acknowledged: { acknowledged.withLock { $0.append(1) } }
        )
        fixture.server._testEmitEvent(
            .init(event: .processExit, processID: "terminal-process", exitCode: 0, sequence: 2),
            acknowledged: { acknowledged.withLock { $0.append(2) } }
        )

        let stdout = try eventFrame(fd: subscriberFD)
        let exit = try eventFrame(fd: subscriberFD)
        #expect(stdout.sequence == 1)
        #expect(exit.event == .processExit)
        #expect(exit.sequence == 2)
        #expect(exit.subscriptionID == subscription.subscriptionID)
        #expect(fixture.server._testPendingEventCount() == 2)

        let response = try acknowledgeDurableEvent(
            subscriptionID: subscription.subscriptionID,
            processID: "terminal-process",
            sequence: 2,
            fd: subscriberFD,
            requestID: "ack-exit"
        )
        #expect(response.ok)
        #expect(waitUntil { fixture.server._testPendingEventCount() == 0 })
        #expect(acknowledged.withLock { $0 } == [1, 2])
    }

    @Test
    func eventAcknowledgementWaitsForDeliveryPublicationBarrier() throws {
        let buffer = SidecarEventDeliveryBuffer(log: Logger(label: "SidecarEventDeliveryBufferTests"))
        let pair = try makeSocketPair()
        let writeCompleted = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        defer {
            releasePublication.signal()
            buffer.stop()
            closeIfValid(pair.server)
            closeIfValid(pair.peer)
        }
        buffer._testSetAfterEventWriteBeforePublication {
            writeCompleted.signal()
            _ = releasePublication.wait(timeout: .now() + 2)
        }
        buffer.start()
        buffer.setClient(pair.server, subscriptionID: "barrier-subscription")

        let callbackCount = LockedValue(0)
        let enqueued = buffer.enqueue(
            .init(event: .processExit, processID: "barrier-process", exitCode: 0, sequence: 1),
            acknowledged: { callbackCount.withLock { $0 += 1 } }
        )
        #expect(enqueued)
        #expect(writeCompleted.wait(timeout: .now() + 2) == .success)
        let delivered = try readableEnvelope(fd: pair.peer).event
        #expect(delivered?.sequence == 1)
        #expect(delivered?.subscriptionID == "barrier-subscription")

        let ackDone = DispatchSemaphore(value: 0)
        let ackError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer { ackDone.signal() }
            do {
                try buffer.acknowledge(
                    .init(
                        subscriptionID: "barrier-subscription",
                        processID: "barrier-process",
                        sequence: 1
                    ),
                    from: pair.server
                )
            } catch {
                ackError.withLock { $0 = error }
            }
        }

        #expect(ackDone.wait(timeout: .now() + 0.1) == .timedOut)
        releasePublication.signal()
        #expect(ackDone.wait(timeout: .now() + 2) == .success)
        #expect(ackError.withLock { $0 == nil })
        #expect(buffer.pendingCount() == 0)
        #expect(callbackCount.withLock { $0 } == 1)
    }

    @Test
    func failedEventWriteInvalidatesSubscriptionAndReplaysPendingEvent() throws {
        signal(SIGPIPE, SIG_IGN)
        let buffer = SidecarEventDeliveryBuffer(log: Logger(label: "SidecarEventDeliveryBufferTests"))
        let failedPair = try makeSocketPair()
        let replayPair = try makeSocketPair()
        defer {
            buffer.stop()
            closeIfValid(failedPair.server)
            closeIfValid(replayPair.server)
            closeIfValid(replayPair.peer)
        }
        closeIfValid(failedPair.peer)
        buffer.start()
        buffer.setClient(failedPair.server, subscriptionID: "failed-subscription")

        let callbackCount = LockedValue(0)
        let enqueued = buffer.enqueue(
            .init(event: .processExit, processID: "replayed-process", exitCode: 0, sequence: 1),
            acknowledged: { callbackCount.withLock { $0 += 1 } }
        )
        #expect(enqueued)
        #expect(waitUntil { !buffer.hasClient() })
        #expect(buffer.pendingCount() == 1)
        #expect(callbackCount.withLock { $0 } == 0)

        buffer.setClient(replayPair.server, subscriptionID: "replay-subscription")
        let replayed = try readableEnvelope(fd: replayPair.peer).event
        #expect(replayed?.sequence == 1)
        #expect(replayed?.subscriptionID == "replay-subscription")
        try buffer.acknowledge(
            .init(
                subscriptionID: "replay-subscription",
                processID: "replayed-process",
                sequence: 1
            ),
            from: replayPair.server
        )
        #expect(buffer.pendingCount() == 0)
        #expect(callbackCount.withLock { $0 } == 1)
    }

    @Test
    func terminalEventAcknowledgementReachesGuestOnlyAfterConsumerAck() throws {
        signal(SIGPIPE, SIG_IGN)
        let fixture = try makeStartedServer()
        let processPair = try makeSocketPair()
        defer {
            fixture.server._testCloseAllProcessSessions()
            fixture.server.stop()
            closeIfValid(processPair.peer)
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let processID = "terminal-runtime-process"
        let executionID = "sandbox:container:terminal"
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/true",
            durableExecutionID: executionID,
            replayCursor: 0
        )
        try fixture.server._testRegisterProcessSession(
            processID: processID,
            guestProcessID: executionID,
            durable: true,
            exec: request,
            replayCursor: 0,
            fd: processPair.server
        )
        try fixture.server._testStartProcessReadLoop(processID: processID)

        let subscriberFD = try MacOSSidecarSocketIO.connectUnixSocket(path: fixture.socketPath)
        defer { closeIfValid(subscriberFD) }
        let subscription = try subscribeDurableEvents(fd: subscriberFD, requestID: "subscribe-terminal-v3")

        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame(
                type: .exit,
                id: executionID,
                sequence: 1,
                exitCode: 0
            ),
            fd: processPair.peer
        )
        let terminalEvent = try eventFrame(fd: subscriberFD)
        #expect(terminalEvent.event == .processExit)
        #expect(terminalEvent.sequence == 1)

        var descriptor = pollfd(fd: processPair.peer, events: Int16(POLLIN), revents: 0)
        #expect(Darwin.poll(&descriptor, 1, 100) == 0)

        let response = try acknowledgeDurableEvent(
            subscriptionID: subscription.subscriptionID,
            processID: processID,
            sequence: 1,
            fd: subscriberFD,
            requestID: "ack-terminal"
        )
        #expect(response.ok)

        let guestAck = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: processPair.peer)
        #expect(guestAck.type == .processEventAck)
        #expect(guestAck.id == executionID)
        #expect(guestAck.sequence == 1)
        try expectEOF(fd: processPair.peer)
    }

    @Test
    func explicitEventSubscriberSurvivesConcurrentControlClientDisconnect() throws {
        signal(SIGPIPE, SIG_IGN)

        let fixture = try makeStartedServer()
        defer {
            fixture.server.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let subscriberFD = try MacOSSidecarSocketIO.connectUnixSocket(path: fixture.socketPath)
        defer { closeIfValid(subscriberFD) }
        var controlFD = try MacOSSidecarSocketIO.connectUnixSocket(path: fixture.socketPath)
        defer { closeIfValid(controlFD) }

        try writeRequest(
            .init(
                requestID: "subscribe",
                method: .eventsSubscribe,
                protocolVersion: MacOSSidecarProtocolVersion.machineState
            ),
            to: subscriberFD
        )
        #expect(try responseFrame(fd: subscriberFD).ok)

        try writeRequest(
            .init(
                requestID: "capabilities",
                method: .vmCapabilities,
                protocolVersion: MacOSSidecarProtocolVersion.current
            ),
            to: controlFD
        )
        #expect(try responseFrame(fd: controlFD).ok)

        fixture.server._testEmitEvent(.init(event: .processStdout, processID: "proc-1", data: Data("first".utf8)))
        let firstEvent = try eventFrame(fd: subscriberFD)
        #expect(firstEvent.processID == "proc-1")
        #expect(firstEvent.data == Data("first".utf8))

        _ = Darwin.shutdown(controlFD, SHUT_RDWR)
        closeIfValid(controlFD)
        controlFD = -1

        fixture.server._testEmitEvent(.init(event: .processExit, processID: "proc-1", exitCode: 0))
        let secondEvent = try eventFrame(fd: subscriberFD)
        #expect(secondEvent.event == .processExit)
        #expect(secondEvent.exitCode == 0)

        #expect(fixture.server._testHasEventClient())
        _ = Darwin.shutdown(subscriberFD, SHUT_RDWR)
        #expect(waitUntil { !fixture.server._testHasEventClient() })
    }

    @Test
    func nonReadingEventSubscriberCannotBlockControlResponses() throws {
        signal(SIGPIPE, SIG_IGN)
        let socketPath = "/tmp/runtime-macos-sidecar-stalled-events-\(UUID().uuidString).sock"
        let server = makeServer(
            socketPath: socketPath,
            maximumBufferedEventCount: 8,
            controlWriteTimeoutMilliseconds: 100
        )
        try server.start()
        defer { server.stop() }

        let subscriberFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(subscriberFD) }
        var receiveBufferBytes: Int32 = 1_024
        #expect(
            Darwin.setsockopt(
                subscriberFD,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        )
        try writeRequest(
            .init(
                requestID: "subscribe-stalled",
                method: .eventsSubscribe,
                protocolVersion: MacOSSidecarProtocolVersion.machineState
            ),
            to: subscriberFD
        )
        #expect(try responseFrame(fd: subscriberFD).ok)

        server._testEmitEvent(
            .init(
                event: .processStdout,
                processID: "stalled",
                data: Data(repeating: 0x61, count: 4 * 1024 * 1024)
            )
        )
        usleep(50_000)

        let controlFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(controlFD) }
        try writeRequest(
            .init(
                requestID: "capabilities-after-stall",
                method: .vmCapabilities,
                protocolVersion: MacOSSidecarProtocolVersion.current
            ),
            to: controlFD
        )
        let response = try readableEnvelope(fd: controlFD, timeoutMilliseconds: 2_000)
        #expect(response.response?.requestID == "capabilities-after-stall")
        #expect(response.response?.ok == true)
        #expect(waitUntil { !server._testHasEventClient() })
    }

    @Test
    func legacyBootstrapRequestRegistersEventSubscriber() throws {
        let fixture = try makeStartedServer()
        defer {
            fixture.server.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let legacyFD = try MacOSSidecarSocketIO.connectUnixSocket(path: fixture.socketPath)
        defer { closeIfValid(legacyFD) }

        try writeRequest(.init(requestID: "legacy-bootstrap", method: .vmBootstrapStart), to: legacyFD)
        let bootstrap = try responseFrame(fd: legacyFD)
        #expect(bootstrap.requestID == "legacy-bootstrap")
        #expect(bootstrap.error?.code == "invalidStorageConfiguration")

        fixture.server._testEmitEvent(.init(event: .processStderr, processID: "legacy", data: Data("legacy".utf8)))
        let event = try eventFrame(fd: legacyFD)
        #expect(event.event == .processStderr)
        #expect(event.processID == "legacy")
        #expect(event.data == Data("legacy".utf8))
    }

    @Test
    func unknownMethodAndVersionMismatchReturnFramesWithoutClosingConnection() throws {
        let socketPath = "/tmp/runtime-macos-sidecar-protocol-\(UUID().uuidString).sock"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeMacOSSidecarProtocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeConfigurationWithInvalidStorage().write(to: root.appendingPathComponent("config.json"))
        let service = MacOSSidecarService(rootURL: root, log: Logger(label: "RuntimeMacOSSidecarTests"))
        let server = SidecarControlServer(
            socketPath: socketPath,
            service: service,
            log: Logger(label: "RuntimeMacOSSidecarTests")
        )
        try server.start()
        defer { server.stop() }
        let fd = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(fd) }

        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(
                .init(requestID: "unknown", method: .unknown("vm.future"), protocolVersion: 2)
            ),
            fd: fd
        )
        let unknown = try responseFrame(fd: fd)
        #expect(unknown.requestID == "unknown")
        #expect(unknown.error?.code == "unknownMethod")

        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(
                .init(requestID: "version", method: .vmPause, protocolVersion: 1)
            ),
            fd: fd
        )
        let version = try responseFrame(fd: fd)
        #expect(version.requestID == "version")
        #expect(version.error?.code == "protocolVersionMismatch")
        #expect(
            version.error?.metadata?["requiredVersion"]
                == "\(MacOSSidecarProtocolVersion.machineState),\(MacOSSidecarProtocolVersion.durableCheckpointAdoption)"
        )

        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(
                .init(
                    requestID: "delete-state",
                    method: .vmDeleteMachineState,
                    protocolVersion: MacOSSidecarProtocolVersion.machineState,
                    machineState: .init(stateID: "missing")
                )
            ),
            fd: fd
        )
        let deleteState = try responseFrame(fd: fd)
        #expect(deleteState.requestID == "delete-state")
        #expect(deleteState.ok)
        let deleteData = try #require(deleteState.data)
        #expect(
            try JSONDecoder().decode(MacOSMachineStateDeleteResult.self, from: deleteData)
                == .init(stateID: "missing", deleted: false)
        )

        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(.init(requestID: "storage", method: .vmBootstrapStart)),
            fd: fd
        )
        let storage = try responseFrame(fd: fd)
        #expect(storage.requestID == "storage")
        #expect(storage.error?.code == "invalidStorageConfiguration")

        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(.init(requestID: "legacy-stop", method: .vmStop)),
            fd: fd
        )
        let legacyStop = try responseFrame(fd: fd)
        #expect(legacyStop.requestID == "legacy-stop")
        #expect(legacyStop.ok)
    }

    @Test
    func durableCheckpointRejectsAnEmptyWorkloadManifest() throws {
        let socketPath = "/tmp/runtime-macos-sidecar-empty-checkpoint-\(UUID().uuidString).sock"
        let server = makeServer(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let clientFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(clientFD) }
        let request = MacOSSidecarRequest(
            requestID: "empty-checkpoint",
            method: .vmPrepareCheckpoint,
            protocolVersion: MacOSSidecarProtocolVersion.durableCheckpointAdoption,
            machineState: .init(
                checkpointID: "snapshot-42",
                persistenceID: "workload-42",
                sourcePodUID: "source-pod",
                sourceStorageGeneration: 7
            )
        )
        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(request),
            fd: clientFD
        )

        let response = try responseFrame(fd: clientFD)
        #expect(response.error?.code == "checkpointWorkloadUnavailable")
    }

    @Test
    func durableCheckpointWaitsForInFlightProcessStartAndCapturesIt() throws {
        signal(SIGPIPE, SIG_IGN)
        let processPair = try makeSocketPair()
        let processFD = LockedValue<Int32?>(processPair.server)
        let processStartEntered = DispatchSemaphore(value: 0)
        let releaseProcessStart = DispatchSemaphore(value: 0)
        let server = makeServer(processConnectionFactory: { _ in
            guard
                let fd = processFD.withLock({ current -> Int32? in
                    let fd = current
                    current = nil
                    return fd
                })
            else {
                throw POSIXError(.ENOTCONN)
            }
            processStartEntered.signal()
            guard releaseProcessStart.wait(timeout: .now() + 2) == .success else {
                closeIfValid(fd)
                throw POSIXError(.ETIMEDOUT)
            }
            return fd
        })
        defer {
            releaseProcessStart.signal()
            server._testCloseAllProcessSessions()
            closeIfValid(processFD.withLock { $0 })
            closeIfValid(processPair.peer)
        }

        let executionID = "sandbox:container:checkpoint-admission"
        let trustedFingerprint = "sha256:\(String(repeating: "a", count: 64))"
        let incarnation = "sha256:\(String(repeating: "b", count: 64))"
        let processRequest = MacOSSidecarExecRequestPayload(
            executable: "/bin/sleep",
            arguments: ["60"],
            durableExecutionID: executionID,
            durableLaunchFingerprint: trustedFingerprint,
            durableIncarnation: incarnation,
            storageGeneration: 7,
            replayCursor: 0
        )
        let guestDone = DispatchSemaphore(value: 0)
        let guestError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer { guestDone.signal() }
            do {
                try writeGuestReady(fd: processPair.peer)
                let inspect = try MacOSSidecarSocketIO.readJSONFrame(
                    SidecarGuestAgentFrame.self,
                    fd: processPair.peer
                )
                #expect(inspect.type == .processInspect)
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(
                        type: .error,
                        id: executionID,
                        message: "process not found",
                        errorCode: ENOENT
                    ),
                    fd: processPair.peer
                )
                let exec = try MacOSSidecarSocketIO.readJSONFrame(
                    SidecarGuestAgentFrame.self,
                    fd: processPair.peer
                )
                #expect(exec.type == .exec)
                try writeGuestStatusAck(
                    makeGuestProcessStatus(
                        executionID: executionID,
                        launchFingerprint: "guest-launch-fingerprint",
                        trustedLaunchFingerprint: trustedFingerprint,
                        incarnation: incarnation,
                        storageGeneration: 7,
                        disposition: .created
                    ),
                    fd: processPair.peer
                )
            } catch {
                guestError.withLock { $0 = error }
            }
        }

        let processStartDone = DispatchSemaphore(value: 0)
        let processStartError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer { processStartDone.signal() }
            do {
                try server._testStartProcessStream(
                    processID: "runtime-workload-checkpoint-admission",
                    exec: processRequest
                )
            } catch {
                processStartError.withLock { $0 = error }
            }
        }
        #expect(processStartEntered.wait(timeout: .now() + 2) == .success)

        let checkpointDone = DispatchSemaphore(value: 0)
        let checkpointResult = LockedValue<MacOSMachineStateCheckpointResult?>(nil)
        let checkpointError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer { checkpointDone.signal() }
            do {
                let result = try server._testPrepareCheckpoint(
                    .init(
                        checkpointID: "snapshot-42",
                        persistenceID: "workload-42",
                        sourcePodUID: "source-pod",
                        sourceStorageGeneration: 7
                    )
                )
                checkpointResult.withLock { $0 = result }
            } catch {
                checkpointError.withLock { $0 = error }
            }
        }

        #expect(checkpointDone.wait(timeout: .now() + 0.1) == .timedOut)
        releaseProcessStart.signal()
        #expect(processStartDone.wait(timeout: .now() + 2) == .success)
        #expect(checkpointDone.wait(timeout: .now() + 2) == .success)
        #expect(guestDone.wait(timeout: .now() + 2) == .success)
        if let error = processStartError.withLock({ $0 }) {
            throw error
        }
        if let error = checkpointError.withLock({ $0 }) {
            throw error
        }
        if let error = guestError.withLock({ $0 }) {
            throw error
        }

        let checkpoint = try #require(checkpointResult.withLock { $0 })
        #expect(checkpoint.adoption.workloads.count == 1)
        #expect(checkpoint.adoption.workloads.first?.runtimeWorkloadID == "runtime-workload-checkpoint-admission")
        #expect(checkpoint.adoption.workloads.first?.guestProcessID == executionID)

        server._testEmitEvent(
            .init(
                event: .processStdout,
                processID: "runtime-workload-checkpoint-admission",
                data: Data("after-prepare".utf8),
                sequence: 1
            )
        )
        #expect(server._testPendingEventCount() == 1)
        let replay = try server._testPrepareCheckpoint(
            .init(
                checkpointID: "snapshot-42",
                persistenceID: "workload-42",
                sourcePodUID: "source-pod",
                sourceStorageGeneration: 7
            )
        )
        #expect(replay.adoptionManifestDigest == checkpoint.adoptionManifestDigest)

        do {
            try server._testStartProcessStream(
                processID: "runtime-workload-after-checkpoint",
                exec: .init(executable: "/bin/true")
            )
            Issue.record("process start was accepted after checkpoint preparation")
        } catch let error as SidecarRPCError {
            #expect(error.code == "checkpointInProgress")
        }
    }

    @Test
    func controlSocketRejectsSymbolicLinkAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuntimeMacOSSidecarSocketPath-\(UUID().uuidString)"
        )
        let realParent = root.appendingPathComponent("real", isDirectory: true)
        let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)

        let server = makeServer(socketPath: linkedParent.appendingPathComponent("control.sock").path)
        #expect(throws: Error.self) {
            try server.start()
        }
    }

    @Test
    func ownerDisconnectClosesOwnedFileTransferSessions() throws {
        let server = makeServer()
        defer { server._testCloseAllFSSessions() }

        let ownedPair = try makeSocketPair()
        let otherPair = try makeSocketPair()
        defer {
            closeIfValid(ownedPair.peer)
            closeIfValid(otherPair.peer)
        }

        try server._testRegisterFSSession(
            txID: "tx-owned",
            fd: ownedPair.server,
            ownerClientFD: 41,
            op: .writeFile,
            path: "/tmp/owned.txt"
        )
        try server._testRegisterFSSession(
            txID: "tx-other",
            fd: otherPair.server,
            ownerClientFD: 99,
            op: .writeFile,
            path: "/tmp/other.txt"
        )

        server._testCloseOwnedFSSessions(clientFD: 41)

        #expect(!server._testHasFSSession(txID: "tx-owned"))
        #expect(server._testHasFSSession(txID: "tx-other"))
        try expectEOF(fd: ownedPair.peer)
    }

    @Test
    func chunkFailureRemovesFileTransferSession() throws {
        signal(SIGPIPE, SIG_IGN)

        let server = makeServer()
        defer { server._testCloseAllFSSessions() }

        let pair = try makeSocketPair()
        let peerFD = LockedValue<Int32?>(pair.peer)
        defer {
            closeIfValid(
                peerFD.withLock { fd in
                    let current = fd
                    fd = nil
                    return current
                })
        }

        try server._testRegisterFSSession(
            txID: "tx-chunk",
            fd: pair.server,
            ownerClientFD: 7,
            op: .writeFile,
            path: "/tmp/chunked.txt"
        )

        let readerDone = DispatchSemaphore(value: 0)
        let readerError = LockedValue<Error?>(nil)
        let receivedFrame = LockedValue<SidecarGuestAgentFrame?>(nil)

        Thread.detachNewThread {
            defer { readerDone.signal() }
            do {
                guard let fd = peerFD.withLock({ $0 }) else {
                    throw POSIXError(.EBADF)
                }
                let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
                receivedFrame.withLock { $0 = frame }
                closeIfValid(
                    peerFD.withLock { current in
                        let fd = current
                        current = nil
                        return fd
                    })
            } catch {
                readerError.withLock { $0 = error }
            }
        }

        #expect(throws: Error.self) {
            try server._testSendFSChunk(.init(txID: "tx-chunk", offset: 0, data: Data("payload".utf8)))
        }

        #expect(readerDone.wait(timeout: .now() + 2) == .success)
        if let error = readerError.withLock({ $0 }) {
            throw error
        }

        let frame = try #require(receivedFrame.withLock { $0 })
        #expect(frame.type == .fsChunk)
        #expect(frame.id == "tx-chunk")
        #expect(frame.offset == 0)
        #expect(frame.data == Data("payload".utf8))
        #expect(!server._testHasFSSession(txID: "tx-chunk"))
    }

    @Test
    func processStartHandshakeBuffersEarlyOutputUntilAck() throws {
        let server = makeServer()
        let pair = try makeSocketPair()
        defer {
            closeIfValid(pair.server)
            closeIfValid(pair.peer)
        }

        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame(type: .stdout, data: Data("early-output\n".utf8)),
            fd: pair.peer
        )
        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame.ack(id: "process-1"),
            fd: pair.peer
        )

        let initialFrames = try server._testWaitForProcessStartAck(
            fd: pair.server,
            expectedProcessID: "process-1"
        )

        #expect(initialFrames.count == 1)
        #expect(initialFrames.first?.type == .stdout)
        #expect(initialFrames.first?.data == Data("early-output\n".utf8))
    }

    @Test
    func processStartAdmissionRejectsConcurrentPauseUntilStartAck() throws {
        signal(SIGPIPE, SIG_IGN)
        let processPair = try makeSocketPair()
        let processFD = LockedValue<Int32?>(processPair.server)
        let admissionReached = DispatchSemaphore(value: 0)
        let releaseProcessConnect = DispatchSemaphore(value: 0)
        let releaseGuest = DispatchSemaphore(value: 0)
        let socketPath = "/tmp/runtime-macos-sidecar-admission-\(UUID().uuidString).sock"
        let server = makeServer(
            socketPath: socketPath,
            processConnectionFactory: { _ in
                guard
                    let fd = processFD.withLock({ current -> Int32? in
                        let fd = current
                        current = nil
                        return fd
                    })
                else {
                    throw POSIXError(.ENOTCONN)
                }
                admissionReached.signal()
                guard releaseProcessConnect.wait(timeout: .now() + 2) == .success else {
                    closeIfValid(fd)
                    throw POSIXError(.ETIMEDOUT)
                }
                return fd
            })
        try server._testSetVMLifecycleRunning()
        try server.start()
        defer {
            releaseProcessConnect.signal()
            releaseGuest.signal()
            server.stop()
            server._testCloseAllProcessSessions()
            closeIfValid(processFD.withLock { $0 })
            closeIfValid(processPair.peer)
        }

        let guestDone = DispatchSemaphore(value: 0)
        let guestError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer { guestDone.signal() }
            do {
                try writeGuestReady(fd: processPair.peer)
                let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: processPair.peer)
                #expect(frame.type == .exec)
                #expect(frame.id == "admitted-process")
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame.ack(id: "admitted-process"),
                    fd: processPair.peer
                )
                _ = releaseGuest.wait(timeout: .now() + 2)
            } catch {
                guestError.withLock { $0 = error }
            }
        }

        let startClientFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(startClientFD) }
        let startResponse = LockedValue<MacOSSidecarResponse?>(nil)
        let startError = LockedValue<Error?>(nil)
        let startDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { startDone.signal() }
            do {
                try MacOSSidecarSocketIO.writeJSONFrame(
                    MacOSSidecarEnvelope.request(
                        MacOSSidecarRequest(
                            requestID: "start-admitted",
                            method: .processStart,
                            port: 27_000,
                            processID: "admitted-process",
                            exec: .init(executable: "/bin/true")
                        )
                    ),
                    fd: startClientFD
                )
                let response = try responseFrame(fd: startClientFD)
                startResponse.withLock { $0 = response }
            } catch {
                startError.withLock { $0 = error }
            }
        }

        #expect(admissionReached.wait(timeout: .now() + 2) == .success)
        let pauseClientFD = try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
        defer { closeIfValid(pauseClientFD) }
        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(
                MacOSSidecarRequest(
                    requestID: "pause-during-start",
                    method: .vmPause,
                    protocolVersion: MacOSSidecarProtocolVersion.machineState
                )
            ),
            fd: pauseClientFD
        )
        let pauseResponse = try responseFrame(fd: pauseClientFD)
        #expect(!pauseResponse.ok)
        #expect(pauseResponse.error?.code == "operationInProgress")

        releaseProcessConnect.signal()
        #expect(startDone.wait(timeout: .now() + 2) == .success)
        #expect(startError.withLock { $0 } == nil)
        #expect(startResponse.withLock { $0?.ok } == true)
        releaseGuest.signal()
        #expect(guestDone.wait(timeout: .now() + 2) == .success)
        if let error = guestError.withLock({ $0 }) {
            throw error
        }
    }

    @Test
    func processStartHandshakeThrowsGuestAgentErrorBeforeAck() throws {
        let server = makeServer()
        let pair = try makeSocketPair()
        defer {
            closeIfValid(pair.server)
            closeIfValid(pair.peer)
        }

        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame(type: .error, message: "failed to start process: No such file or directory"),
            fd: pair.peer
        )

        do {
            _ = try server._testWaitForProcessStartAck(
                fd: pair.server,
                expectedProcessID: "process-2"
            )
            Issue.record("expected process start handshake to throw")
        } catch {
            #expect(String(describing: error).contains("failed to start process"))
            #expect(String(describing: error).contains("No such file or directory"))
        }
    }

    @Test
    func processStartHandshakeTimeoutLeavesNoLateReader() throws {
        let server = makeServer()
        let pair = try makeSocketPair()
        defer {
            closeIfValid(pair.server)
            closeIfValid(pair.peer)
        }

        let payload = try JSONEncoder().encode(SidecarGuestAgentFrame.ack(id: "partial-process"))
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        let split = max(1, payload.count / 2)
        try MacOSSidecarSocketIO.writeAll(data: header + payload.prefix(split), fd: pair.peer)

        do {
            _ = try server._testWaitForProcessStartAck(
                fd: pair.server,
                expectedProcessID: "partial-process",
                timeoutSeconds: 0.05
            )
            Issue.record("partial process-start frame did not time out")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
        }

        let remainder = Data(payload.dropFirst(split))
        try MacOSSidecarSocketIO.writeAll(data: remainder, fd: pair.peer)
        usleep(50_000)
        var peekBuffer = [UInt8](repeating: 0, count: remainder.count)
        let peeked = Darwin.recv(pair.server, &peekBuffer, peekBuffer.count, MSG_PEEK | MSG_DONTWAIT)
        #expect(peeked == remainder.count)
    }

    @Test
    func structuredGuestErrnoControlsRuntimeErrorAndReconnectPolicy() {
        let server = makeServer()
        let cases: [(Int32, ContainerizationError.Code, Bool)] = [
            (ENOENT, .notFound, true),
            (EEXIST, .exists, true),
            (EINVAL, .invalidArgument, true),
            (ESTALE, .invalidState, true),
            (EPERM, .invalidState, true),
            (EBUSY, .interrupted, false),
        ]

        for (errorCode, expectedCode, permanent) in cases {
            #expect(server._testGuestProcessErrorCode(errorCode: errorCode, message: "structured failure") == expectedCode)
            #expect(server._testIsPermanentProcessReconnectFailure(errorCode: errorCode, message: "structured failure") == permanent)
        }

        #expect(server._testGuestProcessErrorCode(errorCode: EBUSY, message: "not found") == .interrupted)
        #expect(server._testGuestProcessErrorCode(errorCode: nil, message: "process not found") == .notFound)
    }

    @Test
    func matchingDurableProcessRetryRejectsTerminalCancelledAndReconnectBlockedSessions() throws {
        let states: [(String, (SidecarControlServer, String) throws -> Void)] = [
            ("terminal", { try $0._testMarkProcessTerminal(processID: $1) }),
            ("cancelled", { try $0._testCancelProcessSessionWithoutRemoval(processID: $1) }),
            ("reconnect-blocked", { try $0._testBlockProcessReconnect(processID: $1) }),
        ]

        for (state, transition) in states {
            let connectionAttempts = LockedValue(0)
            let server = makeServer(processConnectionFactory: { _ in
                connectionAttempts.withLock { $0 += 1 }
                throw POSIXError(.ENOTCONN)
            })
            let pair = try makeSocketPair()
            let processID = "retry-\(state)"
            let request = MacOSSidecarExecRequestPayload(
                executable: "/bin/true",
                durableExecutionID: "sandbox:container:\(state)",
                replayCursor: 0
            )
            defer {
                server._testCloseAllProcessSessions()
                closeIfValid(pair.peer)
            }
            try server._testRegisterProcessSession(
                processID: processID,
                guestProcessID: request.durableExecutionID!,
                durable: true,
                exec: request,
                replayCursor: 0,
                fd: pair.server
            )
            try transition(server, processID)

            do {
                try server._testStartProcessStream(processID: processID, exec: request)
                Issue.record("matching durable retry was accepted for \(state) session")
            } catch let error as ContainerizationError {
                #expect(error.code == .invalidState)
            }

            do {
                _ = try server._testInspectDurableProcess(processID: processID, exec: request)
                Issue.record("matching durable inspect was accepted for \(state) session")
            } catch let error as ContainerizationError {
                #expect(error.code == .invalidState)
            }
            #expect(connectionAttempts.withLock { $0 } == 0)
        }
    }

    @Test
    func durableProcessRetryRejectsGuestTerminalStatusAfterSidecarSessionLoss() throws {
        let pair = try makeSocketPair()
        let serverFD = LockedValue<Int32?>(pair.server)
        let server = makeServer(processConnectionFactory: { _ in
            guard
                let fd = serverFD.withLock({ current -> Int32? in
                    let fd = current
                    current = nil
                    return fd
                })
            else {
                throw POSIXError(.ENOTCONN)
            }
            return fd
        })
        defer {
            server._testCloseAllProcessSessions()
            closeIfValid(serverFD.withLock { $0 })
            closeIfValid(pair.peer)
        }
        let guestDone = DispatchSemaphore(value: 0)
        let guestError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer { guestDone.signal() }
            do {
                try writeGuestReady(fd: pair.peer)
                let exec = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: pair.peer)
                #expect(exec.type == .exec)
                let status = MacOSGuestProcessStatusPayload(
                    executionID: "terminal-after-ack-loss",
                    disposition: .existing,
                    state: .exited,
                    launchFingerprint: "guest-fingerprint",
                    processIdentifier: 4_242,
                    exitCode: 0,
                    cursor: 1,
                    oldestAvailableSequence: 1,
                    replayTruncated: false
                )
                try writeGuestStatusAck(status, fd: pair.peer)
            } catch {
                guestError.withLock { $0 = error }
            }
        }

        do {
            try server._testStartProcessStream(
                processID: "runtime-process",
                exec: .init(
                    executable: "/bin/true",
                    durableExecutionID: "terminal-after-ack-loss",
                    replayCursor: 0
                )
            )
            Issue.record("terminal durable retry was reported as a successful process start")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
        }

        #expect(guestDone.wait(timeout: .now() + 2) == .success)
        if let error = guestError.withLock({ $0 }) {
            throw error
        }
        #expect(!server._testHasProcessSession(processID: "runtime-process"))
    }

    @Test
    func cancellingProcessSessionInterruptsBlockedBoundedWrite() throws {
        signal(SIGPIPE, SIG_IGN)
        let server = makeServer()
        let pair = try makeSocketPair()
        defer {
            server._testCloseAllProcessSessions()
            closeIfValid(pair.peer)
        }
        var sendBufferBytes: Int32 = 1_024
        #expect(
            Darwin.setsockopt(
                pair.server,
                SOL_SOCKET,
                SO_SNDBUF,
                &sendBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        )
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
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/cat",
            durableExecutionID: "sandbox:container:blocked-writer",
            replayCursor: 0
        )
        try server._testRegisterProcessSession(
            processID: "blocked-writer",
            guestProcessID: request.durableExecutionID!,
            durable: true,
            exec: request,
            replayCursor: 0,
            fd: pair.server,
            writeTimeoutMilliseconds: 30_000
        )
        let descriptors = try #require(server._testProcessConnectionDescriptors(processID: "blocked-writer"))
        #expect(descriptors.owner >= 0)
        #expect(descriptors.reader >= 0)
        #expect(descriptors.owner != descriptors.reader)

        let writeDone = DispatchSemaphore(value: 0)
        let writeError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer { writeDone.signal() }
            do {
                try server._testSendProcessStdin(
                    processID: "blocked-writer",
                    data: Data(repeating: 0x61, count: 8 * 1024 * 1024)
                )
            } catch {
                writeError.withLock { $0 = error }
            }
        }
        var descriptor = pollfd(fd: pair.peer, events: Int16(POLLIN), revents: 0)
        #expect(Darwin.poll(&descriptor, 1, 2_000) > 0)

        let started = Date()
        server._testCloseAllProcessSessions()
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1)
        #expect(writeDone.wait(timeout: .now() + 1) == .success)
        #expect(writeError.withLock { $0 != nil })
    }

    @Test
    func durableDeleteSurvivesLostAckAndSidecarRestartWithoutLiveSession() throws {
        signal(SIGPIPE, SIG_IGN)
        let executionID = "sandbox:container:delete-after-restart"
        let trustedFingerprint = "sha256:\(String(repeating: "d", count: 64))"
        let guestFingerprint = String(repeating: "a", count: 64)
        let incarnation = "sha256:\(String(repeating: "e", count: 64))"
        let generation: UInt64 = 17
        let identity = MacOSSidecarDurableProcessDeleteIdentity(
            executionID: executionID,
            trustedLaunchFingerprint: trustedFingerprint,
            incarnation: incarnation,
            storageGeneration: generation
        )
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/true",
            durableExecutionID: executionID,
            durableLaunchFingerprint: trustedFingerprint,
            durableIncarnation: incarnation,
            storageGeneration: generation,
            replayCursor: 0
        )

        let livePair = try makeSocketPair()
        let firstCommandPair = try makeSocketPair()
        let firstCommandFD = LockedValue<Int32?>(firstCommandPair.server)
        let firstServer = makeServer(processConnectionFactory: { _ in
            guard
                let fd = firstCommandFD.withLock({ value -> Int32? in
                    let current = value
                    value = nil
                    return current
                })
            else {
                throw POSIXError(.ENOTCONN)
            }
            return fd
        })
        defer {
            firstServer._testCloseAllProcessSessions()
            closeIfValid(livePair.peer)
            closeIfValid(firstCommandFD.withLock { $0 })
        }
        try firstServer._testRegisterProcessSession(
            processID: "delete-runtime-process",
            guestProcessID: executionID,
            durable: true,
            exec: request,
            replayCursor: 0,
            fd: livePair.server,
            launchFingerprint: guestFingerprint,
            storageGeneration: generation,
            processIdentifier: 4_242,
            trustedLaunchFingerprint: trustedFingerprint,
            incarnation: incarnation
        )

        let firstGuestDone = DispatchSemaphore(value: 0)
        let firstGuestError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer {
                closeIfValid(firstCommandPair.peer)
                firstGuestDone.signal()
            }
            do {
                try writeGuestReady(fd: firstCommandPair.peer)
                let inspect = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: firstCommandPair.peer)
                #expect(inspect.type == .processInspect)
                let status = makeGuestProcessStatus(
                    executionID: executionID,
                    launchFingerprint: guestFingerprint,
                    trustedLaunchFingerprint: trustedFingerprint,
                    incarnation: incarnation,
                    storageGeneration: generation,
                    disposition: .inspected
                )
                try writeGuestStatusAck(status, fd: firstCommandPair.peer)
                let delete = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: firstCommandPair.peer)
                #expect(delete.type == .processDelete)
                #expect(delete.expectedLaunchFingerprint == guestFingerprint)
                #expect(delete.trustedLaunchFingerprint == trustedFingerprint)
                #expect(delete.incarnation == incarnation)
                // The guest commits the delete, but the transport drops before
                // the acknowledgement reaches the first sidecar instance.
                _ = Darwin.shutdown(firstCommandPair.peer, SHUT_RDWR)
            } catch {
                firstGuestError.withLock { $0 = error }
            }
        }

        #expect(throws: Error.self) {
            try firstServer._testDeleteDurableProcess(identity: identity)
        }
        #expect(firstGuestDone.wait(timeout: .now() + 2) == .success)
        if let error = firstGuestError.withLock({ $0 }) {
            throw error
        }
        #expect(firstServer._testHasProcessSession(processID: "delete-runtime-process"))
        do {
            try firstServer._testStartProcessStream(processID: "delete-runtime-process", exec: request)
            Issue.record("delete-pending session accepted a process start retry")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
        }

        // Simulate sidecar restart: the successor has no in-memory session and
        // retries only from the trusted identity persisted by the runtime.
        firstServer._testCloseAllProcessSessions()
        let secondCommandPair = try makeSocketPair()
        let secondCommandFD = LockedValue<Int32?>(secondCommandPair.server)
        let secondServer = makeServer(processConnectionFactory: { _ in
            guard
                let fd = secondCommandFD.withLock({ value -> Int32? in
                    let current = value
                    value = nil
                    return current
                })
            else {
                throw POSIXError(.ENOTCONN)
            }
            return fd
        })
        defer {
            secondServer._testCloseAllProcessSessions()
            closeIfValid(secondCommandFD.withLock { $0 })
            closeIfValid(secondCommandPair.peer)
        }
        #expect(!secondServer._testHasProcessSession(processID: "delete-runtime-process"))

        let secondGuestDone = DispatchSemaphore(value: 0)
        let secondGuestError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer { secondGuestDone.signal() }
            do {
                try writeGuestReady(fd: secondCommandPair.peer)
                let inspect = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: secondCommandPair.peer)
                #expect(inspect.type == .processInspect)
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(
                        type: .error,
                        id: executionID,
                        message: "execution is absent",
                        errorCode: ENOENT
                    ),
                    fd: secondCommandPair.peer
                )
                let delete = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: secondCommandPair.peer)
                #expect(delete.type == .processDelete)
                #expect(delete.expectedLaunchFingerprint == nil)
                #expect(delete.trustedLaunchFingerprint == trustedFingerprint)
                #expect(delete.incarnation == incarnation)
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(type: .ack, id: executionID),
                    fd: secondCommandPair.peer
                )
            } catch {
                secondGuestError.withLock { $0 = error }
            }
        }

        try secondServer._testDeleteDurableProcess(identity: identity)
        #expect(secondGuestDone.wait(timeout: .now() + 2) == .success)
        if let error = secondGuestError.withLock({ $0 }) {
            throw error
        }
    }

    @Test
    func durableDeleteRejectsMismatchedTrustedIdentityAndGeneration() throws {
        let executionID = "sandbox:container:delete-fenced"
        let requestedFingerprint = "sha256:\(String(repeating: "e", count: 64))"
        let mismatchedFingerprint = "sha256:\(String(repeating: "f", count: 64))"
        let incarnation = "sha256:\(String(repeating: "a", count: 64))"
        let guestLaunchFingerprint = String(repeating: "b", count: 64)
        let cases: [(String, MacOSSidecarDurableProcessDeleteIdentity, String, UInt64)] = [
            (
                "fingerprint",
                .init(
                    executionID: executionID,
                    trustedLaunchFingerprint: requestedFingerprint,
                    incarnation: incarnation,
                    storageGeneration: 5
                ),
                mismatchedFingerprint,
                5
            ),
            (
                "generation",
                .init(
                    executionID: executionID,
                    trustedLaunchFingerprint: requestedFingerprint,
                    incarnation: incarnation,
                    storageGeneration: 6
                ),
                requestedFingerprint,
                5
            ),
        ]

        for (label, identity, guestTrustedFingerprint, guestGeneration) in cases {
            let pair = try makeSocketPair()
            let commandFD = LockedValue<Int32?>(pair.server)
            let server = makeServer(processConnectionFactory: { _ in
                guard
                    let fd = commandFD.withLock({ value -> Int32? in
                        let current = value
                        value = nil
                        return current
                    })
                else {
                    throw POSIXError(.ENOTCONN)
                }
                return fd
            })
            let guestDone = DispatchSemaphore(value: 0)
            let guestError = LockedValue<Error?>(nil)
            Thread.detachNewThread {
                defer { guestDone.signal() }
                do {
                    try writeGuestReady(fd: pair.peer)
                    let inspect = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: pair.peer)
                    #expect(inspect.type == .processInspect)
                    try writeGuestStatusAck(
                        makeGuestProcessStatus(
                            executionID: executionID,
                            launchFingerprint: guestLaunchFingerprint,
                            trustedLaunchFingerprint: guestTrustedFingerprint,
                            incarnation: incarnation,
                            storageGeneration: guestGeneration,
                            disposition: .inspected
                        ),
                        fd: pair.peer
                    )
                } catch {
                    guestError.withLock { $0 = error }
                }
            }

            do {
                try server._testDeleteDurableProcess(identity: identity)
                Issue.record("durable delete accepted mismatched \(label)")
            } catch let error as ContainerizationError {
                #expect(error.code == .invalidState)
            }
            #expect(guestDone.wait(timeout: .now() + 2) == .success)
            if let error = guestError.withLock({ $0 }) {
                throw error
            }
            closeIfValid(commandFD.withLock { $0 })
            closeIfValid(pair.peer)
            server._testCloseAllProcessSessions()
        }
    }

    @Test
    func durableDeleteTombstonesSupersededIncarnationWithoutDeletingCurrentGuestProcess() throws {
        signal(SIGPIPE, SIG_IGN)
        let executionID = "sandbox:container:superseded-delete"
        let trustedFingerprint = "sha256:\(String(repeating: "1", count: 64))"
        let staleIncarnation = "sha256:\(String(repeating: "2", count: 64))"
        let currentIncarnation = "sha256:\(String(repeating: "3", count: 64))"
        let generation: UInt64 = 19
        let identity = MacOSSidecarDurableProcessDeleteIdentity(
            executionID: executionID,
            trustedLaunchFingerprint: trustedFingerprint,
            incarnation: staleIncarnation,
            storageGeneration: generation
        )
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/true",
            durableExecutionID: executionID,
            durableLaunchFingerprint: trustedFingerprint,
            durableIncarnation: staleIncarnation,
            storageGeneration: generation,
            replayCursor: 0
        )
        let livePair = try makeSocketPair()
        let commandPair = try makeSocketPair()
        let commandFD = LockedValue<Int32?>(commandPair.server)
        let server = makeServer(processConnectionFactory: { _ in
            guard
                let fd = commandFD.withLock({ value -> Int32? in
                    let current = value
                    value = nil
                    return current
                })
            else {
                throw POSIXError(.ENOTCONN)
            }
            return fd
        })
        defer {
            server._testCloseAllProcessSessions()
            closeIfValid(livePair.peer)
            closeIfValid(commandFD.withLock { $0 })
            closeIfValid(commandPair.peer)
        }
        try server._testRegisterProcessSession(
            processID: "stale-runtime-session",
            guestProcessID: executionID,
            durable: true,
            exec: request,
            replayCursor: 0,
            fd: livePair.server,
            launchFingerprint: String(repeating: "a", count: 64),
            storageGeneration: generation,
            trustedLaunchFingerprint: trustedFingerprint,
            incarnation: staleIncarnation
        )

        let guestDone = DispatchSemaphore(value: 0)
        let guestError = LockedValue<Error?>(nil)
        Thread.detachNewThread {
            defer { guestDone.signal() }
            do {
                try writeGuestReady(fd: commandPair.peer)
                let inspect = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: commandPair.peer)
                #expect(inspect.type == .processInspect)
                try writeGuestStatusAck(
                    makeGuestProcessStatus(
                        executionID: executionID,
                        launchFingerprint: String(repeating: "b", count: 64),
                        trustedLaunchFingerprint: trustedFingerprint,
                        incarnation: currentIncarnation,
                        storageGeneration: generation,
                        disposition: .inspected
                    ),
                    fd: commandPair.peer
                )
                let delete = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: commandPair.peer)
                #expect(delete.type == .processDelete)
                #expect(delete.expectedLaunchFingerprint == nil)
                #expect(delete.trustedLaunchFingerprint == trustedFingerprint)
                #expect(delete.incarnation == staleIncarnation)
                #expect(delete.storageGeneration == generation)
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(type: .ack, id: executionID),
                    fd: commandPair.peer
                )
            } catch {
                guestError.withLock { $0 = error }
            }
        }

        try server._testDeleteDurableProcess(identity: identity)
        #expect(guestDone.wait(timeout: .now() + 2) == .success)
        if let error = guestError.withLock({ $0 }) {
            throw error
        }
        #expect(!server._testHasProcessSession(processID: "stale-runtime-session"))
    }

    @Test
    func durableProcessStartRetryIsIdempotentAndRejectsChangedLaunch() throws {
        let server = makeServer()
        defer { server._testCloseAllProcessSessions() }
        let pair = try makeSocketPair()
        defer { closeIfValid(pair.peer) }
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 60"],
            durableExecutionID: "sandbox:container:builder",
            replayCursor: 4
        )
        try server._testRegisterProcessSession(
            processID: "transient-process",
            guestProcessID: "sandbox:container:builder",
            durable: true,
            exec: request,
            replayCursor: 4,
            fd: pair.server
        )

        try server._testStartProcessStream(processID: "transient-process", exec: request)

        let changed = MacOSSidecarExecRequestPayload(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 61"],
            durableExecutionID: "sandbox:container:builder",
            replayCursor: 4
        )
        do {
            try server._testStartProcessStream(processID: "transient-process", exec: changed)
            Issue.record("changed durable process retry was accepted")
        } catch let error as ContainerizationError {
            #expect(error.code == .exists)
        }
    }

    @Test
    func generationFencedDurableProcessRequiresTrustedLaunchFingerprint() throws {
        let connectionAttempts = LockedValue(0)
        let server = makeServer(processConnectionFactory: { _ in
            connectionAttempts.withLock { $0 += 1 }
            throw POSIXError(.ENOTCONN)
        })
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/sleep",
            arguments: ["60"],
            durableExecutionID: "sandbox:container:missing-fingerprint",
            storageGeneration: 2,
            replayCursor: 0
        )

        do {
            try server._testStartProcessStream(processID: "missing-fingerprint", exec: request)
            Issue.record("generation-fenced durable process without a trusted launch fingerprint was accepted")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
            #expect(error.message.contains("launch fingerprint"))
        }
        #expect(connectionAttempts.withLock { $0 } == 0)
    }

    @Test
    func durableProcessWarmAdoptionAdvancesGuestStorageGeneration() throws {
        signal(SIGPIPE, SIG_IGN)
        let pair = try makeSocketPair()
        let availableFD = LockedValue<Int32?>(pair.server)
        let receivedInspect = LockedValue<SidecarGuestAgentFrame?>(nil)
        let receivedExec = LockedValue<SidecarGuestAgentFrame?>(nil)
        let guestError = LockedValue<Error?>(nil)
        let guestDone = DispatchSemaphore(value: 0)
        let trustedFingerprint = "sha256:\(String(repeating: "b", count: 64))"
        let savedIncarnation = "sha256:\(String(repeating: "c", count: 64))"
        let currentIncarnation = "sha256:\(String(repeating: "d", count: 64))"
        let server = makeServer(
            processConnectionFactory: { _ in
                guard
                    let fd = availableFD.withLock({ value -> Int32? in
                        let current = value
                        value = nil
                        return current
                    })
                else {
                    throw POSIXError(.ENOTCONN)
                }
                return fd
            }
        )
        defer {
            server._testCloseAllProcessSessions()
            closeIfValid(availableFD.withLock { $0 })
            closeIfValid(pair.peer)
        }
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/sleep",
            arguments: ["60"],
            durableExecutionID: "sandbox:container:warm",
            durableLaunchFingerprint: trustedFingerprint,
            durableIncarnation: currentIncarnation,
            storageGeneration: 8,
            previousStorageGeneration: 7,
            replayCursor: 4
        )

        Thread.detachNewThread {
            defer { guestDone.signal() }
            do {
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(
                        type: .ready,
                        capabilities: [
                            MacOSGuestProcessProtocol.durableProcessV1,
                            MacOSGuestProcessProtocol.durableProcessV2,
                            MacOSGuestProcessProtocol.durableProcessV3,
                            MacOSGuestProcessProtocol.durableProcessV4,
                        ]
                    ),
                    fd: pair.peer
                )
                let inspect = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: pair.peer)
                receivedInspect.withLock { $0 = inspect }
                let saved = MacOSGuestProcessStatusPayload(
                    executionID: "sandbox:container:warm",
                    disposition: .inspected,
                    state: .running,
                    launchFingerprint: "guest-launch-fingerprint",
                    trustedLaunchFingerprint: trustedFingerprint,
                    incarnation: savedIncarnation,
                    storageGeneration: 7,
                    processIdentifier: 4_242,
                    exitCode: nil,
                    cursor: 4,
                    oldestAvailableSequence: 1,
                    replayTruncated: false
                )
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(type: .ack, id: saved.executionID, data: try JSONEncoder().encode(saved)),
                    fd: pair.peer
                )
                let exec = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: pair.peer)
                receivedExec.withLock { $0 = exec }
                let adopted = MacOSGuestProcessStatusPayload(
                    executionID: saved.executionID,
                    disposition: .existing,
                    state: .running,
                    launchFingerprint: saved.launchFingerprint,
                    trustedLaunchFingerprint: trustedFingerprint,
                    incarnation: currentIncarnation,
                    storageGeneration: 8,
                    processIdentifier: saved.processIdentifier,
                    exitCode: nil,
                    cursor: 4,
                    oldestAvailableSequence: 1,
                    replayTruncated: false
                )
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(type: .ack, id: adopted.executionID, data: try JSONEncoder().encode(adopted)),
                    fd: pair.peer
                )
            } catch {
                guestError.withLock { $0 = error }
            }
        }

        try server._testStartProcessStream(processID: "warm-runtime-process", exec: request)
        #expect(guestDone.wait(timeout: .now() + 2) == .success)
        if let error = guestError.withLock({ $0 }) {
            throw error
        }
        let inspect = try #require(receivedInspect.withLock { $0 })
        #expect(inspect.type == .processInspect)
        #expect(inspect.id == "sandbox:container:warm")
        let exec = try #require(receivedExec.withLock { $0 })
        #expect(exec.type == .exec)
        #expect(exec.expectedLaunchFingerprint == "guest-launch-fingerprint")
        #expect(exec.trustedLaunchFingerprint == trustedFingerprint)
        #expect(exec.incarnation == currentIncarnation)
        #expect(exec.storageGeneration == 8)
        #expect(exec.previousStorageGeneration == 7)

        // A repeated host request is idempotent after the guest has advanced
        // to the current generation and cannot launch a duplicate process.
        try server._testStartProcessStream(processID: "warm-runtime-process", exec: request)
    }

    @Test
    func durableProcessStreamEOFReattachesWithDeliveredCursorWithoutExecutingAgain() throws {
        signal(SIGPIPE, SIG_IGN)
        let initialPair = try makeSocketPair()
        let reconnectPair = try makeSocketPair()
        let eventPair = try makeSocketPair()
        let initialPeerFD = LockedValue<Int32?>(initialPair.peer)
        let reconnectFD = LockedValue<Int32?>(reconnectPair.server)
        let receivedAttach = LockedValue<SidecarGuestAgentFrame?>(nil)
        let reconnectError = LockedValue<Error?>(nil)
        let reconnectDone = DispatchSemaphore(value: 0)
        let server = makeServer(
            processConnectionFactory: { _ in
                guard
                    let fd = reconnectFD.withLock({ value -> Int32? in
                        let current = value
                        value = nil
                        return current
                    })
                else {
                    throw POSIXError(.ENOTCONN)
                }
                return fd
            },
            processReconnectDelayMicroseconds: 0
        )
        defer {
            server._testClearEventClient()
            server._testCloseAllProcessSessions()
            closeIfValid(
                initialPeerFD.withLock { value -> Int32? in
                    let current = value
                    value = nil
                    return current
                })
            closeIfValid(reconnectFD.withLock { $0 })
            closeIfValid(reconnectPair.peer)
            closeIfValid(eventPair.server)
            closeIfValid(eventPair.peer)
        }
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/sleep",
            arguments: ["60"],
            durableExecutionID: "sandbox:container:builder",
            replayCursor: 0
        )
        try server._testRegisterProcessSession(
            processID: "transient-process",
            guestProcessID: "sandbox:container:builder",
            durable: true,
            exec: request,
            replayCursor: 0,
            fd: initialPair.server,
            launchFingerprint: "launch-fingerprint",
            processIdentifier: 4242
        )
        server._testSetEventClient(fd: eventPair.server)
        try server._testStartProcessReadLoop(processID: "transient-process")

        Thread.detachNewThread {
            defer { reconnectDone.signal() }
            do {
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(
                        type: .ready,
                        capabilities: [
                            MacOSGuestProcessProtocol.durableProcessV1,
                            MacOSGuestProcessProtocol.durableProcessV2,
                            MacOSGuestProcessProtocol.durableProcessV3,
                        ]
                    ),
                    fd: reconnectPair.peer
                )
                let attach = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: reconnectPair.peer)
                receivedAttach.withLock { $0 = attach }
                let status = MacOSGuestProcessStatusPayload(
                    executionID: "sandbox:container:builder",
                    disposition: .attached,
                    state: .running,
                    launchFingerprint: "launch-fingerprint",
                    processIdentifier: 4242,
                    exitCode: nil,
                    cursor: 1,
                    oldestAvailableSequence: 1,
                    replayTruncated: false
                )
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(
                        type: .ack,
                        id: status.executionID,
                        data: try JSONEncoder().encode(status)
                    ),
                    fd: reconnectPair.peer
                )
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame(
                        type: .stdout,
                        id: status.executionID,
                        sequence: 1,
                        data: Data("reattached".utf8)
                    ),
                    fd: reconnectPair.peer
                )
            } catch {
                reconnectError.withLock { $0 = error }
            }
        }

        closeIfValid(
            initialPeerFD.withLock { value -> Int32? in
                let current = value
                value = nil
                return current
            })
        let output = try eventFrame(fd: eventPair.peer)
        #expect(output.event == .processStdout)
        #expect(output.data == Data("reattached".utf8))
        #expect(reconnectDone.wait(timeout: .now() + 2) == .success)
        if let error = reconnectError.withLock({ $0 }) {
            throw error
        }
        let attach = try #require(receivedAttach.withLock { $0 })
        #expect(attach.type == .processAttach)
        #expect(attach.id == "sandbox:container:builder")
        #expect(attach.cursor == 0)
        #expect(waitUntil { server._testProcessDeliveredCursor(processID: "transient-process") == 1 })
    }

    @Test
    func durableProcessEventsWaitForSubscriberAndAdvanceCursorOnlyAfterDelivery() throws {
        let processPair = try makeSocketPair()
        let eventPair = try makeSocketPair()
        let server = makeServer(maximumBufferedEventCount: 1)
        defer {
            server._testClearEventClient()
            server._testCloseAllProcessSessions()
            closeIfValid(processPair.peer)
            closeIfValid(eventPair.server)
            closeIfValid(eventPair.peer)
        }
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/sleep",
            arguments: ["60"],
            durableExecutionID: "sandbox:container:buffered",
            replayCursor: 0
        )
        try server._testRegisterProcessSession(
            processID: "buffered-process",
            guestProcessID: "sandbox:container:buffered",
            durable: true,
            exec: request,
            replayCursor: 0,
            fd: processPair.server
        )
        try server._testStartProcessReadLoop(processID: "buffered-process")

        for sequence in UInt64(1)...2 {
            try MacOSSidecarSocketIO.writeJSONFrame(
                SidecarGuestAgentFrame(
                    type: .stdout,
                    id: "sandbox:container:buffered",
                    sequence: sequence,
                    data: Data("event-\(sequence)".utf8)
                ),
                fd: processPair.peer
            )
        }

        #expect(waitUntil { server._testPendingEventCount() == 1 })
        #expect(server._testProcessDeliveredCursor(processID: "buffered-process") == 0)

        server._testSetEventClient(fd: eventPair.server)
        let first = try eventFrame(fd: eventPair.peer)
        let second = try eventFrame(fd: eventPair.peer)
        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(waitUntil { server._testProcessDeliveredCursor(processID: "buffered-process") == 2 })
        #expect(server._testPendingEventCount() == 0)
    }

    @Test
    func durableProcessReconnectRejectsChangedGuestIdentity() throws {
        signal(SIGPIPE, SIG_IGN)
        let initialPair = try makeSocketPair()
        let reconnectPair = try makeSocketPair()
        let eventPair = try makeSocketPair()
        let initialPeerFD = LockedValue<Int32?>(initialPair.peer)
        let reconnectFD = LockedValue<Int32?>(reconnectPair.server)
        let connectionAttempts = LockedValue(0)
        let server = makeServer(
            processConnectionFactory: { _ in
                connectionAttempts.withLock { $0 += 1 }
                guard
                    let fd = reconnectFD.withLock({ value -> Int32? in
                        let current = value
                        value = nil
                        return current
                    })
                else {
                    throw POSIXError(.ENOTCONN)
                }
                return fd
            },
            processReconnectDelayMicroseconds: 0
        )
        defer {
            server._testClearEventClient()
            server._testCloseAllProcessSessions()
            closeIfValid(
                initialPeerFD.withLock { value -> Int32? in
                    let current = value
                    value = nil
                    return current
                })
            closeIfValid(reconnectFD.withLock { $0 })
            closeIfValid(reconnectPair.peer)
            closeIfValid(eventPair.server)
            closeIfValid(eventPair.peer)
        }
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/sleep",
            durableExecutionID: "sandbox:container:identity"
        )
        try server._testRegisterProcessSession(
            processID: "identity-process",
            guestProcessID: "sandbox:container:identity",
            durable: true,
            exec: request,
            replayCursor: 0,
            fd: initialPair.server,
            launchFingerprint: "expected-fingerprint",
            processIdentifier: 101
        )
        server._testSetEventClient(fd: eventPair.server)
        try server._testStartProcessReadLoop(processID: "identity-process")

        Thread.detachNewThread {
            try? MacOSSidecarSocketIO.writeJSONFrame(
                SidecarGuestAgentFrame(
                    type: .ready,
                    capabilities: [
                        MacOSGuestProcessProtocol.durableProcessV1,
                        MacOSGuestProcessProtocol.durableProcessV2,
                        MacOSGuestProcessProtocol.durableProcessV3,
                    ]
                ),
                fd: reconnectPair.peer
            )
            _ = try? MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: reconnectPair.peer)
            let changed = MacOSGuestProcessStatusPayload(
                executionID: "sandbox:container:identity",
                disposition: .attached,
                state: .running,
                launchFingerprint: "changed-fingerprint",
                processIdentifier: 202,
                exitCode: nil,
                cursor: 0,
                oldestAvailableSequence: 1,
                replayTruncated: false
            )
            try? MacOSSidecarSocketIO.writeJSONFrame(
                SidecarGuestAgentFrame(
                    type: .ack,
                    id: changed.executionID,
                    data: try? JSONEncoder().encode(changed)
                ),
                fd: reconnectPair.peer
            )
        }

        closeIfValid(
            initialPeerFD.withLock { value -> Int32? in
                let current = value
                value = nil
                return current
            })
        let rejected = try eventFrame(fd: eventPair.peer)
        #expect(rejected.event == .processError)
        #expect(rejected.message?.contains("reconnect was rejected") == true)
        usleep(150_000)
        #expect(connectionAttempts.withLock { $0 } == 1)
        #expect(server._testHasProcessSession(processID: "identity-process"))

    }

    @Test
    func closingProcessSessionsCancelsPendingDurableReconnect() throws {
        let initialPair = try makeSocketPair()
        let initialPeerFD = LockedValue<Int32?>(initialPair.peer)
        let connectionAttempts = LockedValue(0)
        let server = makeServer(
            processConnectionFactory: { _ in
                connectionAttempts.withLock { $0 += 1 }
                throw POSIXError(.ENOTCONN)
            },
            processReconnectDelayMicroseconds: 300_000
        )
        defer {
            server._testCloseAllProcessSessions()
            closeIfValid(
                initialPeerFD.withLock { value -> Int32? in
                    let current = value
                    value = nil
                    return current
                })
        }
        let request = MacOSSidecarExecRequestPayload(
            executable: "/bin/sleep",
            durableExecutionID: "sandbox:container:shutdown"
        )
        try server._testRegisterProcessSession(
            processID: "shutdown-process",
            guestProcessID: "sandbox:container:shutdown",
            durable: true,
            exec: request,
            replayCursor: 0,
            fd: initialPair.server
        )
        try server._testStartProcessReadLoop(processID: "shutdown-process")

        closeIfValid(
            initialPeerFD.withLock { value -> Int32? in
                let current = value
                value = nil
                return current
            })
        #expect(waitUntil { server._testIsProcessReconnectPending(processID: "shutdown-process") })

        server._testCloseAllProcessSessions()
        usleep(400_000)

        #expect(connectionAttempts.withLock { $0 } == 0)
        #expect(!server._testHasProcessSession(processID: "shutdown-process"))
    }

    @Test
    func bareExecutableLaunchUsesGuestPathLookup() throws {
        let server = makeServer()

        let launch = server._testGuestExecutableLaunch(
            executable: "sh",
            arguments: ["-lc", "echo ok"]
        )

        #expect(launch.executable == "/usr/bin/env")
        #expect(launch.arguments == ["sh", "-lc", "echo ok"])
    }

    @Test
    func pathExecutableLaunchIsPreserved() throws {
        let server = makeServer()

        let launch = server._testGuestExecutableLaunch(
            executable: "/bin/sh",
            arguments: ["-lc", "echo ok"]
        )

        #expect(launch.executable == "/bin/sh")
        #expect(launch.arguments == ["-lc", "echo ok"])
    }

    @Test
    func emptyExecutableLaunchIsPreserved() throws {
        let server = makeServer()

        let launch = server._testGuestExecutableLaunch(executable: "", arguments: ["arg"])

        #expect(launch.executable == "")
        #expect(launch.arguments == ["arg"])
    }
}

private func makeConfigurationWithInvalidStorage() throws -> Data {
    let image = try JSONDecoder().decode(
        ImageDescription.self,
        from: Data(
            #"{"reference":"example/macos:latest","descriptor":{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:test","size":1}}"#.utf8
        )
    )
    var configuration = ContainerConfiguration(
        id: "invalid-storage",
        image: image,
        process: ProcessConfiguration(
            executable: "/bin/true",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
    )
    configuration.macosGuest = .init(
        snapshotEnabled: false,
        guiEnabled: false,
        agentPort: 27_000,
        blockDevices: [
            .init(identifier: "root", kind: .nbdUnixSocket, path: "relative.sock")
        ]
    )
    return try JSONEncoder().encode(configuration)
}

private func writeGuestReady(fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(
        SidecarGuestAgentFrame(
            type: .ready,
            capabilities: [
                MacOSGuestProcessProtocol.durableProcessV1,
                MacOSGuestProcessProtocol.durableProcessV2,
                MacOSGuestProcessProtocol.durableProcessV3,
                MacOSGuestProcessProtocol.durableProcessV4,
            ]
        ),
        fd: fd
    )
}

private func makeGuestProcessStatus(
    executionID: String,
    launchFingerprint: String,
    trustedLaunchFingerprint: String? = nil,
    incarnation: String? = nil,
    storageGeneration: UInt64,
    disposition: MacOSGuestProcessDisposition
) -> MacOSGuestProcessStatusPayload {
    .init(
        executionID: executionID,
        disposition: disposition,
        state: .running,
        launchFingerprint: launchFingerprint,
        trustedLaunchFingerprint: trustedLaunchFingerprint,
        incarnation: incarnation,
        storageGeneration: storageGeneration,
        processIdentifier: 4_242,
        exitCode: nil,
        cursor: 0,
        oldestAvailableSequence: 1,
        replayTruncated: false
    )
}

private func writeGuestStatusAck(_ status: MacOSGuestProcessStatusPayload, fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(
        SidecarGuestAgentFrame(
            type: .ack,
            id: status.executionID,
            data: try JSONEncoder().encode(status)
        ),
        fd: fd
    )
}

private func responseFrame(fd: Int32) throws -> MacOSSidecarResponse {
    let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: fd)
    #expect(envelope.kind == .response)
    return try #require(envelope.response)
}

private func eventFrame(fd: Int32, timeoutMilliseconds: Int32 = 2_000) throws -> MacOSSidecarEvent {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&descriptor, 1, timeoutMilliseconds) > 0 else {
        throw POSIXError(.ETIMEDOUT)
    }
    let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: fd)
    #expect(envelope.kind == .event)
    return try #require(envelope.event)
}

private func writeRequest(_ request: MacOSSidecarRequest, to fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(request), fd: fd)
}

private func subscribeDurableEvents(fd: Int32, requestID: String) throws -> MacOSSidecarEventSubscription {
    try writeRequest(
        .init(
            requestID: requestID,
            method: .eventsSubscribe,
            protocolVersion: MacOSSidecarProtocolVersion.durableEventAcknowledgement
        ),
        to: fd
    )
    let response = try responseFrame(fd: fd)
    #expect(response.ok)
    return try JSONDecoder().decode(MacOSSidecarEventSubscription.self, from: #require(response.data))
}

private func acknowledgeDurableEvent(
    subscriptionID: String,
    processID: String,
    sequence: UInt64,
    fd: Int32,
    requestID: String
) throws -> MacOSSidecarResponse {
    try writeRequest(
        .init(
            requestID: requestID,
            method: .eventsAcknowledge,
            protocolVersion: MacOSSidecarProtocolVersion.durableEventAcknowledgement,
            eventAcknowledgement: .init(
                subscriptionID: subscriptionID,
                processID: processID,
                sequence: sequence
            )
        ),
        to: fd
    )
    return try responseFrame(fd: fd)
}

private func waitUntil(timeout: TimeInterval = 2, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(10_000)
    }
    return condition()
}

private func makeStartedServer() throws -> (server: SidecarControlServer, socketPath: String, root: URL) {
    let socketPath = "/tmp/runtime-macos-sidecar-routing-\(UUID().uuidString).sock"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeMacOSSidecarRouting-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    do {
        try makeConfigurationWithInvalidStorage().write(to: root.appendingPathComponent("config.json"))
        let service = MacOSSidecarService(rootURL: root, log: Logger(label: "RuntimeMacOSSidecarTests"))
        let server = SidecarControlServer(
            socketPath: socketPath,
            service: service,
            log: Logger(label: "RuntimeMacOSSidecarTests")
        )
        try server.start()
        return (server, socketPath, root)
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func makeServer(
    socketPath: String = "/tmp/runtime-macos-sidecar-tests-\(UUID().uuidString).sock",
    processConnectionFactory: (@Sendable (UInt32) throws -> Int32)? = nil,
    processReconnectDelayMicroseconds: useconds_t = 100_000,
    maximumBufferedEventCount: Int = 256,
    controlWriteTimeoutMilliseconds: Int32 = 1_000
) -> SidecarControlServer {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeMacOSSidecarTests-\(UUID().uuidString)")
    let service = MacOSSidecarService(rootURL: root, log: Logger(label: "RuntimeMacOSSidecarTests"))
    return SidecarControlServer(
        socketPath: socketPath,
        service: service,
        log: Logger(label: "RuntimeMacOSSidecarTests"),
        processConnectionFactory: processConnectionFactory,
        processReconnectDelayMicroseconds: processReconnectDelayMicroseconds,
        maximumBufferedEventCount: maximumBufferedEventCount,
        controlWriteTimeoutMilliseconds: controlWriteTimeoutMilliseconds
    )
}

private func readableEnvelope(fd: Int32, timeoutMilliseconds: Int32 = 2_000) throws -> MacOSSidecarEnvelope {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&descriptor, 1, timeoutMilliseconds) == 1,
        descriptor.revents & Int16(POLLIN) != 0
    else {
        throw POSIXError(.ETIMEDOUT)
    }
    return try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: fd)
}

private func makeSocketSecurityRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp/runtime-macos-sidecar-security-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    guard chmod(root.path, mode_t(0o700)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return root
}

private func bindUnixSocket(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    do {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    } catch {
        closeIfValid(fd)
        throw error
    }
}

private func makeSocketPair() throws -> (server: Int32, peer: Int32) {
    var fds = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (fds[0], fds[1])
}

private func expectEOF(fd: Int32) throws {
    var buffer = UInt8.zero
    let count = Darwin.read(fd, &buffer, 1)
    if count == 0 {
        return
    }
    if count > 0 {
        Issue.record("expected EOF on fd \(fd)")
        return
    }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private final class LockedValue<T>: @unchecked Sendable {
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

private func closeIfValid(_ fd: Int32?) {
    guard let fd, fd >= 0 else { return }
    Darwin.close(fd)
}
#endif
