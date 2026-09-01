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

import Darwin
import Foundation
import Testing

@testable import RuntimeMacOSSidecarShared

struct SidecarControlProtocolTests {
    @Test
    func eventSubscriptionMethodRoundTrips() throws {
        let request = MacOSSidecarRequest(requestID: "events", method: .eventsSubscribe)
        let decoded = try JSONDecoder().decode(MacOSSidecarRequest.self, from: JSONEncoder().encode(request))

        #expect(decoded.method == .eventsSubscribe)
        #expect(decoded.method.rawValue == "events.subscribe")
        #expect(MacOSSidecarMethod(rawValue: "events.subscribe") == .eventsSubscribe)
        #expect(MacOSSidecarMethod(rawValue: "process.inspect") == .processInspect)
        #expect(MacOSSidecarMethod(rawValue: "process.delete") == .processDelete)
        #expect(MacOSSidecarMethod(rawValue: "vm.deleteMachineState") == .vmDeleteMachineState)
    }

    @Test
    func durableEventAcknowledgementV3RoundTrips() throws {
        let acknowledgement = MacOSSidecarEventAcknowledgement(
            subscriptionID: "subscriber-1",
            processID: "process-1",
            sequence: 42
        )
        let request = MacOSSidecarRequest(
            requestID: "ack",
            method: .eventsAcknowledge,
            protocolVersion: MacOSSidecarProtocolVersion.durableEventAcknowledgement,
            eventAcknowledgement: acknowledgement
        )
        let decoded = try JSONDecoder().decode(MacOSSidecarRequest.self, from: JSONEncoder().encode(request))

        #expect(decoded.method == .eventsAcknowledge)
        #expect(decoded.protocolVersion == 3)
        #expect(decoded.eventAcknowledgement == acknowledgement)
        #expect(MacOSSidecarMethod(rawValue: "events.acknowledge") == .eventsAcknowledge)
        #expect(MacOSSidecarProtocolVersion.supported == [1, 2, 3, 4, 5])
    }

    @Test
    func durableProcessDeleteIdentityV5RoundTrips() throws {
        let identity = MacOSSidecarDurableProcessDeleteIdentity(
            executionID: "sandbox:container:builder",
            trustedLaunchFingerprint: "sha256:\(String(repeating: "c", count: 64))",
            incarnation: "sha256:\(String(repeating: "d", count: 64))",
            storageGeneration: 12
        )
        let request = MacOSSidecarRequest(
            requestID: "delete",
            method: .processDelete,
            protocolVersion: MacOSSidecarProtocolVersion.durableProcessIdentity,
            processID: identity.executionID,
            durableProcessDeleteIdentity: identity
        )

        let decoded = try JSONDecoder().decode(MacOSSidecarRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.protocolVersion == 5)
        #expect(decoded.durableProcessDeleteIdentity == identity)
    }

    @Test
    func legacyRequestWithoutVersionRemainsDecodable() throws {
        let data = Data(#"{"requestID":"legacy","method":"vm.stop"}"#.utf8)
        let request = try JSONDecoder().decode(MacOSSidecarRequest.self, from: data)

        #expect(request.requestID == "legacy")
        #expect(request.method == .vmStop)
        #expect(request.protocolVersion == nil)
    }

    @Test
    func unknownMethodRemainsStructuredAndPreservesRequestID() throws {
        let data = Data(#"{"requestID":"future","method":"vm.futureMethod","protocolVersion":2}"#.utf8)
        let request = try JSONDecoder().decode(MacOSSidecarRequest.self, from: data)

        #expect(request.requestID == "future")
        #expect(request.method == .unknown("vm.futureMethod"))
        #expect(request.method.rawValue == "vm.futureMethod")
        #expect(MacOSSidecarMethod(rawValue: "vm.stop") == .vmStop)
        #expect(MacOSSidecarMethod(rawValue: "events.subscribe") == .eventsSubscribe)
        #expect(MacOSSidecarMethod(rawValue: "vm.futureMethod") == nil)
        #expect(try JSONDecoder().decode(MacOSSidecarRequest.self, from: JSONEncoder().encode(request)).method == request.method)
    }

    @Test
    func machineStateV2PayloadRoundTrips() throws {
        let request = MacOSSidecarRequest(
            requestID: "save-1",
            method: .vmSaveMachineState,
            protocolVersion: MacOSSidecarProtocolVersion.machineState,
            machineState: .init(stateID: "checkpoint-1", timeoutSeconds: 120)
        )

        let decoded = try JSONDecoder().decode(MacOSSidecarRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.protocolVersion == 2)
        #expect(decoded.machineState == .init(stateID: "checkpoint-1", timeoutSeconds: 120))

        let result = MacOSMachineStateDeleteResult(stateID: "checkpoint-1", deleted: true)
        #expect(try JSONDecoder().decode(MacOSMachineStateDeleteResult.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test
    func durableGenerationFencePayloadRoundTrips() throws {
        let fingerprint = "sha256:\(String(repeating: "a", count: 64))"
        let request = MacOSSidecarRequest(
            requestID: "adopt-1",
            method: .processStart,
            protocolVersion: MacOSSidecarProtocolVersion.current,
            processID: "runtime-process",
            exec: .init(
                executable: "/bin/sleep",
                arguments: ["60"],
                durableExecutionID: "sandbox:container:builder",
                durableLaunchFingerprint: fingerprint,
                storageGeneration: 8,
                previousStorageGeneration: 7,
                replayCursor: 19
            )
        )

        let decoded = try JSONDecoder().decode(MacOSSidecarRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.exec?.durableExecutionID == "sandbox:container:builder")
        #expect(decoded.exec?.durableLaunchFingerprint == fingerprint)
        #expect(decoded.exec?.storageGeneration == 8)
        #expect(decoded.exec?.previousStorageGeneration == 7)
        #expect(decoded.exec?.replayCursor == 19)
    }

    @Test
    func diagnosticErrorMetadataRoundTrips() throws {
        let response = MacOSSidecarResponse.failure(
            requestID: "bad-version",
            code: "protocolVersionMismatch",
            message: "unsupported version",
            metadata: ["requestedVersion": "99", "supportedVersions": "1,2"],
            protocolVersion: 2
        )
        let decoded = try JSONDecoder().decode(MacOSSidecarResponse.self, from: JSONEncoder().encode(response))

        #expect(decoded.ok == false)
        #expect(decoded.error?.metadata?["requestedVersion"] == "99")
        #expect(decoded.protocolVersion == 2)
    }

    @Test
    func envelopeJSONFrameRoundTripPreservesPayload() throws {
        let payload = Data("sidecar-stdin".utf8)
        let request = MacOSSidecarRequest(
            method: .processStdin,
            processID: "proc-1",
            data: payload
        )
        let envelope = MacOSSidecarEnvelope.request(request)

        let (reader, writer) = try socketPair()
        defer {
            closeIfValid(reader)
            closeIfValid(writer)
        }

        try MacOSSidecarSocketIO.writeJSONFrame(envelope, fd: writer)
        let decoded = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: reader)

        #expect(decoded.kind == .request)
        let decodedRequest = try #require(decoded.request)
        #expect(decodedRequest.requestID == request.requestID)
        #expect(decodedRequest.method == .processStdin)
        #expect(decodedRequest.processID == "proc-1")
        #expect(decodedRequest.data == payload)
    }

    @Test
    func responseAndEventRoundTripPreserveFields() throws {
        let response = MacOSSidecarEnvelope.response(
            .success(requestID: "req-1", fdAttached: true)
        )
        let eventPayload = Data("stdout\n".utf8)
        let event = MacOSSidecarEnvelope.event(
            .init(
                event: .processStdout,
                processID: "proc-2",
                data: eventPayload,
                sequence: 17,
                subscriptionID: "subscriber-2"
            )
        )

        let (reader, writer) = try socketPair()
        defer {
            closeIfValid(reader)
            closeIfValid(writer)
        }

        try MacOSSidecarSocketIO.writeJSONFrame(response, fd: writer)
        try MacOSSidecarSocketIO.writeJSONFrame(event, fd: writer)

        let decodedResponse = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: reader)
        let decodedEvent = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: reader)

        #expect(decodedResponse.kind == .response)
        #expect(decodedResponse.response?.requestID == "req-1")
        #expect(decodedResponse.response?.ok == true)
        #expect(decodedResponse.response?.fdAttached == true)

        #expect(decodedEvent.kind == .event)
        #expect(decodedEvent.event?.event == .processStdout)
        #expect(decodedEvent.event?.processID == "proc-2")
        #expect(decodedEvent.event?.data == eventPayload)
        #expect(decodedEvent.event?.sequence == 17)
        #expect(decodedEvent.event?.subscriptionID == "subscriber-2")
    }

    @Test
    func filesystemPayloadRoundTripPreservesStructuredFields() throws {
        let beginPayload = MacOSSidecarFSBeginRequestPayload(
            txID: "tx-1",
            op: .writeFile,
            path: "/tmp/file.txt",
            digest: "sha256:test",
            mode: 0o644,
            mtime: 1_730_000_000,
            overwrite: false,
            inlineData: Data("abc".utf8),
            autoCommit: true
        )
        let request = MacOSSidecarRequest(
            method: .fsBegin,
            port: 27000,
            fsBegin: beginPayload
        )

        let (reader, writer) = try socketPair()
        defer {
            closeIfValid(reader)
            closeIfValid(writer)
        }

        try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(request), fd: writer)
        let decoded = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: reader)

        #expect(decoded.kind == .request)
        let decodedRequest = try #require(decoded.request)
        let decodedPayload = try #require(decodedRequest.fsBegin)
        #expect(decodedRequest.method == .fsBegin)
        #expect(decodedRequest.port == 27000)
        #expect(decodedPayload.txID == "tx-1")
        #expect(decodedPayload.op == .writeFile)
        #expect(decodedPayload.path == "/tmp/file.txt")
        #expect(decodedPayload.digest == "sha256:test")
        #expect(decodedPayload.mode == 0o644)
        #expect(decodedPayload.mtime == 1_730_000_000)
        #expect(decodedPayload.overwrite == false)
        #expect(decodedPayload.inlineData == Data("abc".utf8))
        #expect(decodedPayload.autoCommit == true)
    }

    @Test
    func execPayloadRoundTripPreservesUserIdentityFields() throws {
        let exec = MacOSSidecarExecRequestPayload(
            executable: "/usr/bin/id",
            arguments: ["-un"],
            environment: ["PATH=/usr/bin:/bin"],
            workingDirectory: "/tmp",
            terminal: false,
            user: "nobody",
            supplementalGroups: [20, 80],
            durableExecutionID: "sandbox:container:builder",
            replayCursor: 42
        )
        let request = MacOSSidecarRequest(
            method: .processStart,
            port: 27000,
            processID: "proc-user",
            exec: exec
        )

        let (reader, writer) = try socketPair()
        defer {
            closeIfValid(reader)
            closeIfValid(writer)
        }

        try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(request), fd: writer)
        let decoded = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: reader)

        let decodedExec = try #require(decoded.request?.exec)
        #expect(decodedExec.executable == "/usr/bin/id")
        #expect(decodedExec.arguments == ["-un"])
        #expect(decodedExec.environment == ["PATH=/usr/bin:/bin"])
        #expect(decodedExec.workingDirectory == "/tmp")
        #expect(decodedExec.user == "nobody")
        #expect(decodedExec.uid == nil)
        #expect(decodedExec.gid == nil)
        #expect(decodedExec.supplementalGroups == [20, 80])
        #expect(decodedExec.durableExecutionID == "sandbox:container:builder")
        #expect(decodedExec.replayCursor == 42)
    }

    @Test
    func fileDescriptorMarkerRoundTripTransfersWorkingFD() throws {
        let (transportReader, transportWriter) = try socketPair()
        defer {
            closeIfValid(transportReader)
            closeIfValid(transportWriter)
        }

        var pipeFDs = [Int32](repeating: -1, count: 2)
        #expect(Darwin.pipe(&pipeFDs) == 0)
        var originalReadFD = pipeFDs[0]
        let originalWriteFD = pipeFDs[1]
        defer {
            closeIfValid(originalReadFD)
            closeIfValid(originalWriteFD)
        }

        try MacOSSidecarSocketIO.sendFileDescriptorMarker(socketFD: transportWriter, descriptorFD: originalReadFD)
        let maybeTransferredFD = try MacOSSidecarSocketIO.receiveOptionalFileDescriptorMarker(socketFD: transportReader)
        let transferredFD = try #require(maybeTransferredFD)
        defer { closeIfValid(transferredFD) }

        // The ancillary fd is duplicated by the kernel. Close the original to prove the
        // received descriptor is independently usable.
        closeIfValid(originalReadFD)
        originalReadFD = -1

        let expected = Data("fd-pass".utf8)
        try writeAll(expected, fd: originalWriteFD)
        let actual = try MacOSSidecarSocketIO.readExact(fd: transferredFD, count: expected.count)
        #expect(actual == expected)
    }

    @Test
    func noFileDescriptorMarkerRoundTripReturnsNil() throws {
        let (reader, writer) = try socketPair()
        defer {
            closeIfValid(reader)
            closeIfValid(writer)
        }

        try MacOSSidecarSocketIO.sendNoFileDescriptorMarker(socketFD: writer)
        let fd = try MacOSSidecarSocketIO.receiveOptionalFileDescriptorMarker(socketFD: reader)
        #expect(fd == nil)
    }

    @Test
    func oversizedFrameHeaderIsRejectedBeforePayloadRead() throws {
        let (reader, writer) = try socketPair()
        defer {
            closeIfValid(reader)
            closeIfValid(writer)
        }

        var length = UInt32(MacOSSidecarSocketIO.defaultMaxFrameSize + 1).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try writeAll(header, fd: writer)

        do {
            _ = try MacOSSidecarSocketIO.readFrame(fd: reader)
            Issue.record("expected oversized frame header to be rejected")
        } catch {
            #expect(error.localizedDescription.contains("invalid frame size"))
        }
    }

    @Test
    func frameReadDeadlineCoversPartialPayloadWithoutLateReader() throws {
        let (reader, writer) = try socketPair()
        defer {
            closeIfValid(reader)
            closeIfValid(writer)
        }

        var length = UInt32(8).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try writeAll(header + Data("ab".utf8), fd: writer)

        do {
            _ = try MacOSSidecarSocketIO.readFrame(fd: reader, timeoutMilliseconds: 50)
            Issue.record("partial payload unexpectedly completed")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == NSPOSIXErrorDomain)
            #expect(nsError.code == Int(ETIMEDOUT))
        }

        let remaining = Data("cdefghTAIL".utf8)
        try writeAll(remaining, fd: writer)
        usleep(100_000)
        #expect(try MacOSSidecarSocketIO.readExact(fd: reader, count: remaining.count) == remaining)
    }

    @Test
    func duplicatedReaderCannotConsumeAReusedOwnerDescriptor() throws {
        let old = try socketPair()
        let replacement = try socketPair()
        let readerFD = Darwin.dup(old.0)
        #expect(readerFD >= 0)
        guard readerFD >= 0 else { return }
        let reusedFD = old.0
        defer {
            closeIfValid(readerFD)
            closeIfValid(reusedFD)
            closeIfValid(old.1)
            closeIfValid(replacement.0)
            closeIfValid(replacement.1)
        }

        let headerRead = DispatchSemaphore(value: 0)
        let releaseReader = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        let oldReaderSucceeded = ProtocolLockedValue(false)
        Thread.detachNewThread {
            defer { readerDone.signal() }
            do {
                _ = try MacOSSidecarSocketIO.readFrame(
                    fd: readerFD,
                    timeoutMilliseconds: 2_000,
                    afterHeaderRead: {
                        headerRead.signal()
                        _ = releaseReader.wait(timeout: .now() + 2)
                    }
                )
                oldReaderSucceeded.withLock { $0 = true }
            } catch {}
        }

        var oldLength = UInt32(3).bigEndian
        try withUnsafeBytes(of: &oldLength) { bytes in
            try writeAll(Data(bytes), fd: old.1)
        }
        #expect(headerRead.wait(timeout: .now() + 2) == .success)

        _ = Darwin.shutdown(reusedFD, SHUT_RDWR)
        closeIfValid(reusedFD)
        #expect(Darwin.dup2(replacement.0, reusedFD) == reusedFD)
        let replacementPayload = Data("replacement-frame".utf8)
        try MacOSSidecarSocketIO.writeFrame(replacementPayload, fd: replacement.1)

        releaseReader.signal()
        #expect(readerDone.wait(timeout: .now() + 2) == .success)
        #expect(!oldReaderSucceeded.withLock { $0 })
        #expect(try MacOSSidecarSocketIO.readFrame(fd: reusedFD, timeoutMilliseconds: 1_000) == replacementPayload)
    }
}

private final class ProtocolLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func socketPair() throws -> (Int32, Int32) {
    var fds = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (fds[0], fds[1])
}

private func writeAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let n = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
            if n > 0 {
                offset += n
                continue
            }
            if n == 0 {
                throw POSIXError(.EIO)
            }
            let code = errno
            if code == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

private func closeIfValid(_ fd: Int32?) {
    guard let fd, fd >= 0 else { return }
    Darwin.close(fd)
}
