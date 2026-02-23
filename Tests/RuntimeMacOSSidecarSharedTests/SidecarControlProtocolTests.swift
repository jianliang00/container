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
            .init(event: .processStdout, processID: "proc-2", data: eventPayload)
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
