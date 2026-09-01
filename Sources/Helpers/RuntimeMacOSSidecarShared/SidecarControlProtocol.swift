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

public enum MacOSSidecarMethod: Codable, Sendable, Hashable, RawRepresentable {
    case eventsSubscribe
    case eventsAcknowledge
    case vmBootstrapStart
    case vmShowGUI
    case vmConnectVsock
    case processStart
    case processInspect
    case processStdin
    case processSignal
    case processResize
    case processClose
    case processDelete
    case fsBegin
    case fsChunk
    case fsEnd
    case fsReadBegin
    case fsReadChunk
    case fsReadEnd
    case fsListDir
    case vmCapabilities
    case vmPause
    case vmResume
    case vmSaveMachineState
    case vmRestoreMachineState
    case vmDeleteMachineState
    case vmCompatibilityDescription
    case vmStop
    case sidecarQuit
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .eventsSubscribe: "events.subscribe"
        case .eventsAcknowledge: "events.acknowledge"
        case .vmBootstrapStart: "vm.bootstrapStart"
        case .vmShowGUI: "vm.showGUI"
        case .vmConnectVsock: "vm.connectVsock"
        case .processStart: "process.start"
        case .processInspect: "process.inspect"
        case .processStdin: "process.stdin"
        case .processSignal: "process.signal"
        case .processResize: "process.resize"
        case .processClose: "process.close"
        case .processDelete: "process.delete"
        case .fsBegin: "fs.begin"
        case .fsChunk: "fs.chunk"
        case .fsEnd: "fs.end"
        case .fsReadBegin: "fs.read.begin"
        case .fsReadChunk: "fs.read.chunk"
        case .fsReadEnd: "fs.read.end"
        case .fsListDir: "fs.listdir"
        case .vmCapabilities: "vm.capabilities"
        case .vmPause: "vm.pause"
        case .vmResume: "vm.resume"
        case .vmSaveMachineState: "vm.saveMachineState"
        case .vmRestoreMachineState: "vm.restoreMachineState"
        case .vmDeleteMachineState: "vm.deleteMachineState"
        case .vmCompatibilityDescription: "vm.compatibilityDescription"
        case .vmStop: "vm.stop"
        case .sidecarQuit: "sidecar.quit"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown(value)
    }

    public init?(rawValue: String) {
        guard let method = Self.knownMethods[rawValue] else { return nil }
        self = method
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static let knownMethods: [String: Self] = [
        Self.eventsSubscribe.rawValue: .eventsSubscribe,
        Self.eventsAcknowledge.rawValue: .eventsAcknowledge,
        Self.vmBootstrapStart.rawValue: .vmBootstrapStart,
        Self.vmShowGUI.rawValue: .vmShowGUI,
        Self.vmConnectVsock.rawValue: .vmConnectVsock,
        Self.processStart.rawValue: .processStart,
        Self.processInspect.rawValue: .processInspect,
        Self.processStdin.rawValue: .processStdin,
        Self.processSignal.rawValue: .processSignal,
        Self.processResize.rawValue: .processResize,
        Self.processClose.rawValue: .processClose,
        Self.processDelete.rawValue: .processDelete,
        Self.fsBegin.rawValue: .fsBegin,
        Self.fsChunk.rawValue: .fsChunk,
        Self.fsEnd.rawValue: .fsEnd,
        Self.fsReadBegin.rawValue: .fsReadBegin,
        Self.fsReadChunk.rawValue: .fsReadChunk,
        Self.fsReadEnd.rawValue: .fsReadEnd,
        Self.fsListDir.rawValue: .fsListDir,
        Self.vmCapabilities.rawValue: .vmCapabilities,
        Self.vmPause.rawValue: .vmPause,
        Self.vmResume.rawValue: .vmResume,
        Self.vmSaveMachineState.rawValue: .vmSaveMachineState,
        Self.vmRestoreMachineState.rawValue: .vmRestoreMachineState,
        Self.vmDeleteMachineState.rawValue: .vmDeleteMachineState,
        Self.vmCompatibilityDescription.rawValue: .vmCompatibilityDescription,
        Self.vmStop.rawValue: .vmStop,
        Self.sidecarQuit.rawValue: .sidecarQuit,
    ]
}

/// Result returned by a version 3 event subscription. The identifier fences
/// acknowledgements to the exact Unix subscriber that received an event.
public struct MacOSSidecarEventSubscription: Codable, Sendable, Equatable {
    public let subscriptionID: String

    public init(subscriptionID: String) {
        self.subscriptionID = subscriptionID
    }
}

/// Cumulative acknowledgement for one durable process event stream.
public struct MacOSSidecarEventAcknowledgement: Codable, Sendable, Equatable {
    public let subscriptionID: String
    public let processID: String
    public let sequence: UInt64

    public init(subscriptionID: String, processID: String, sequence: UInt64) {
        self.subscriptionID = subscriptionID
        self.processID = processID
        self.sequence = sequence
    }
}

/// Trusted identity required to delete a durable guest process independently
/// from an in-memory sidecar process session.
public struct MacOSSidecarDurableProcessDeleteIdentity: Codable, Sendable, Equatable {
    public let executionID: String
    public let trustedLaunchFingerprint: String
    public let incarnation: String
    public let storageGeneration: UInt64?

    public init(
        executionID: String,
        trustedLaunchFingerprint: String,
        incarnation: String,
        storageGeneration: UInt64? = nil
    ) {
        self.executionID = executionID
        self.trustedLaunchFingerprint = trustedLaunchFingerprint
        self.incarnation = incarnation
        self.storageGeneration = storageGeneration
    }
}

public struct MacOSSidecarExecRequestPayload: Codable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String]?
    public let rootDirectory: String?
    public let workingDirectory: String?
    public let terminal: Bool
    public let user: String?
    public let uid: UInt32?
    public let gid: UInt32?
    public let supplementalGroups: [UInt32]?
    public let stdin: Data?
    /// Stable guest-side execution identifier. When present, the guest keeps
    /// the process alive independently from this sidecar stream.
    public let durableExecutionID: String?
    /// Trusted runtime fingerprint for the complete workload launch contract.
    /// This is used by the host sidecar for request arbitration. The guest has
    /// its own process-level launch fingerprint.
    public let durableLaunchFingerprint: String?
    /// Stable identity for one concrete runtime CreateContainer request.
    public let durableIncarnation: String?
    /// Generation of the writable storage attached to this runtime instance.
    public let storageGeneration: UInt64?
    /// Saved generation from which an existing durable process may be adopted.
    public let previousStorageGeneration: UInt64?
    /// Last durable event sequence consumed by the caller. Replay is
    /// at-least-once when the caller does not persist this cursor.
    public let replayCursor: UInt64?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String]? = nil,
        rootDirectory: String? = nil,
        workingDirectory: String? = nil,
        terminal: Bool = false,
        user: String? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        supplementalGroups: [UInt32]? = nil,
        stdin: Data? = nil,
        durableExecutionID: String? = nil,
        durableLaunchFingerprint: String? = nil,
        durableIncarnation: String? = nil,
        storageGeneration: UInt64? = nil,
        previousStorageGeneration: UInt64? = nil,
        replayCursor: UInt64? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.rootDirectory = rootDirectory
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.user = user
        self.uid = uid
        self.gid = gid
        self.supplementalGroups = supplementalGroups
        self.stdin = stdin
        self.durableExecutionID = durableExecutionID
        self.durableLaunchFingerprint = durableLaunchFingerprint
        self.durableIncarnation = durableIncarnation
        self.storageGeneration = storageGeneration
        self.previousStorageGeneration = previousStorageGeneration
        self.replayCursor = replayCursor
    }
}

public struct MacOSSidecarRequest: Codable, Sendable {
    public let requestID: String
    public let method: MacOSSidecarMethod
    public let protocolVersion: Int?
    public let presentGUI: Bool?
    public let port: UInt32?
    public let processID: String?
    public let exec: MacOSSidecarExecRequestPayload?
    public let data: Data?
    public let signal: Int32?
    public let width: UInt16?
    public let height: UInt16?
    public let fsBegin: MacOSSidecarFSBeginRequestPayload?
    public let fsChunk: MacOSSidecarFSChunkRequestPayload?
    public let fsEnd: MacOSSidecarFSEndRequestPayload?
    public let fsReadBegin: MacOSSidecarFSReadBeginRequestPayload?
    public let fsReadChunk: MacOSSidecarFSReadChunkRequestPayload?
    public let fsListDir: MacOSSidecarFSListDirRequestPayload?
    public let machineState: MacOSMachineStateRequestPayload?
    public let eventAcknowledgement: MacOSSidecarEventAcknowledgement?
    public let durableProcessDeleteIdentity: MacOSSidecarDurableProcessDeleteIdentity?

    public init(
        requestID: String = UUID().uuidString,
        method: MacOSSidecarMethod,
        protocolVersion: Int? = nil,
        presentGUI: Bool? = nil,
        port: UInt32? = nil,
        processID: String? = nil,
        exec: MacOSSidecarExecRequestPayload? = nil,
        data: Data? = nil,
        signal: Int32? = nil,
        width: UInt16? = nil,
        height: UInt16? = nil,
        fsBegin: MacOSSidecarFSBeginRequestPayload? = nil,
        fsChunk: MacOSSidecarFSChunkRequestPayload? = nil,
        fsEnd: MacOSSidecarFSEndRequestPayload? = nil,
        fsReadBegin: MacOSSidecarFSReadBeginRequestPayload? = nil,
        fsReadChunk: MacOSSidecarFSReadChunkRequestPayload? = nil,
        fsListDir: MacOSSidecarFSListDirRequestPayload? = nil,
        machineState: MacOSMachineStateRequestPayload? = nil,
        eventAcknowledgement: MacOSSidecarEventAcknowledgement? = nil,
        durableProcessDeleteIdentity: MacOSSidecarDurableProcessDeleteIdentity? = nil
    ) {
        self.requestID = requestID
        self.method = method
        self.protocolVersion = protocolVersion
        self.presentGUI = presentGUI
        self.port = port
        self.processID = processID
        self.exec = exec
        self.data = data
        self.signal = signal
        self.width = width
        self.height = height
        self.fsBegin = fsBegin
        self.fsChunk = fsChunk
        self.fsEnd = fsEnd
        self.fsReadBegin = fsReadBegin
        self.fsReadChunk = fsReadChunk
        self.fsListDir = fsListDir
        self.machineState = machineState
        self.eventAcknowledgement = eventAcknowledgement
        self.durableProcessDeleteIdentity = durableProcessDeleteIdentity
    }
}

public struct MacOSSidecarErrorPayload: Codable, Sendable {
    public let code: String
    public let message: String
    public let details: String?
    public let metadata: [String: String]?

    public init(code: String, message: String, details: String? = nil, metadata: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
        self.metadata = metadata
    }
}

public struct MacOSSidecarResponse: Codable, Sendable {
    public let requestID: String
    public let ok: Bool
    public let fdAttached: Bool?
    public let error: MacOSSidecarErrorPayload?
    public let data: Data?
    public let protocolVersion: Int?

    public init(
        requestID: String,
        ok: Bool,
        fdAttached: Bool? = nil,
        error: MacOSSidecarErrorPayload? = nil,
        data: Data? = nil,
        protocolVersion: Int? = nil
    ) {
        self.requestID = requestID
        self.ok = ok
        self.fdAttached = fdAttached
        self.error = error
        self.data = data
        self.protocolVersion = protocolVersion
    }

    public static func success(
        requestID: String,
        fdAttached: Bool? = nil,
        data: Data? = nil,
        protocolVersion: Int? = nil
    ) -> Self {
        .init(
            requestID: requestID,
            ok: true,
            fdAttached: fdAttached,
            error: nil,
            data: data,
            protocolVersion: protocolVersion
        )
    }

    public static func failure(
        requestID: String,
        code: String,
        message: String,
        details: String? = nil,
        metadata: [String: String]? = nil,
        protocolVersion: Int? = nil
    ) -> Self {
        .init(
            requestID: requestID,
            ok: false,
            fdAttached: nil,
            error: .init(code: code, message: message, details: details, metadata: metadata),
            protocolVersion: protocolVersion
        )
    }
}

public enum MacOSSidecarEventType: String, Codable, Sendable {
    case processStdout = "process.stdout"
    case processStderr = "process.stderr"
    case processExit = "process.exit"
    case processError = "process.error"
}

public struct MacOSSidecarEvent: Codable, Sendable {
    public let event: MacOSSidecarEventType
    public let processID: String
    public let data: Data?
    public let exitCode: Int32?
    public let message: String?
    /// Monotonic guest-side event sequence for durable processes.
    public let sequence: UInt64?
    /// Version 3 delivery fence. Durable events carrying a sequence must be
    /// acknowledged with this exact subscription identifier.
    public let subscriptionID: String?

    public init(
        event: MacOSSidecarEventType,
        processID: String,
        data: Data? = nil,
        exitCode: Int32? = nil,
        message: String? = nil,
        sequence: UInt64? = nil,
        subscriptionID: String? = nil
    ) {
        self.event = event
        self.processID = processID
        self.data = data
        self.exitCode = exitCode
        self.message = message
        self.sequence = sequence
        self.subscriptionID = subscriptionID
    }

    public func delivered(to subscriptionID: String?) -> Self {
        .init(
            event: event,
            processID: processID,
            data: data,
            exitCode: exitCode,
            message: message,
            sequence: sequence,
            subscriptionID: subscriptionID
        )
    }
}

public enum MacOSSidecarEnvelopeKind: String, Codable, Sendable {
    case request
    case response
    case event
}

public struct MacOSSidecarEnvelope: Codable, Sendable {
    public let kind: MacOSSidecarEnvelopeKind
    public let request: MacOSSidecarRequest?
    public let response: MacOSSidecarResponse?
    public let event: MacOSSidecarEvent?

    public init(kind: MacOSSidecarEnvelopeKind, request: MacOSSidecarRequest? = nil, response: MacOSSidecarResponse? = nil, event: MacOSSidecarEvent? = nil) {
        self.kind = kind
        self.request = request
        self.response = response
        self.event = event
    }

    public static func request(_ request: MacOSSidecarRequest) -> Self {
        .init(kind: .request, request: request)
    }

    public static func response(_ response: MacOSSidecarResponse) -> Self {
        .init(kind: .response, response: response)
    }

    public static func event(_ event: MacOSSidecarEvent) -> Self {
        .init(kind: .event, event: event)
    }
}

public enum MacOSSidecarSocketIO {
    public static let defaultMaxFrameSize = 16 * 1024 * 1024

    public static func writeJSONFrame<T: Encodable>(
        _ value: T,
        fd: Int32,
        encoder: JSONEncoder = JSONEncoder(),
        timeoutMilliseconds: Int32? = nil
    ) throws {
        let payload = try encoder.encode(value)
        try writeFrame(payload, fd: fd, timeoutMilliseconds: timeoutMilliseconds)
    }

    public static func readJSONFrame<T: Decodable>(
        _ type: T.Type,
        fd: Int32,
        decoder: JSONDecoder = JSONDecoder(),
        timeoutMilliseconds: Int32? = nil,
        afterHeaderRead: (() -> Void)? = nil
    ) throws -> T {
        let payload = try readFrame(
            fd: fd,
            timeoutMilliseconds: timeoutMilliseconds,
            afterHeaderRead: afterHeaderRead
        )
        return try decoder.decode(T.self, from: payload)
    }

    public static func writeFrame(
        _ payload: Data,
        fd: Int32,
        timeoutMilliseconds: Int32? = nil
    ) throws {
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        let deadline = monotonicDeadline(timeoutMilliseconds: timeoutMilliseconds)
        var originalFlags: Int32?
        if deadline != nil {
            let flags = Darwin.fcntl(fd, F_GETFL)
            guard flags >= 0 else { throw makePOSIXError(errno) }
            if flags & O_NONBLOCK == 0 {
                guard Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw makePOSIXError(errno)
                }
                originalFlags = flags
            }
        }
        defer {
            if let originalFlags {
                _ = Darwin.fcntl(fd, F_SETFL, originalFlags)
            }
        }
        try writeAll(data: header, fd: fd, deadlineUptimeNanoseconds: deadline)
        try writeAll(data: payload, fd: fd, deadlineUptimeNanoseconds: deadline)
    }

    public static func readFrame(
        fd: Int32,
        maxSize: Int = defaultMaxFrameSize,
        timeoutMilliseconds: Int32? = nil,
        afterHeaderRead: (() -> Void)? = nil
    ) throws -> Data {
        let deadline = monotonicDeadline(timeoutMilliseconds: timeoutMilliseconds)
        let header = try readExact(
            fd: fd,
            count: MemoryLayout<UInt32>.size,
            deadlineUptimeNanoseconds: deadline
        )
        let payloadLength = try frameLength(fromHeader: header, maxSize: maxSize)
        afterHeaderRead?()
        return try readExact(fd: fd, count: payloadLength, deadlineUptimeNanoseconds: deadline)
    }

    public static func frameLength<Bytes: DataProtocol>(
        fromHeader header: Bytes,
        maxSize: Int = defaultMaxFrameSize
    ) throws -> Int {
        guard header.count == MemoryLayout<UInt32>.size else {
            throw makePOSIXLikeError(message: "invalid frame header size: \(header.count)")
        }

        var length: UInt32 = 0
        for byte in header {
            length = (length << 8) | UInt32(byte)
        }

        let payloadLength = Int(length)
        guard payloadLength >= 0, payloadLength <= maxSize else {
            throw makePOSIXLikeError(message: "invalid frame size: \(payloadLength)")
        }
        return payloadLength
    }

    public static func sendFileDescriptorMarker(socketFD: Int32, descriptorFD: Int32) throws {
        var marker: UInt8 = 1
        let payloadSize = MemoryLayout<Int32>.size
        var control = [UInt8](repeating: 0, count: cmsgSpace(payloadSize))
        let sent = withUnsafeMutablePointer(to: &marker) { markerPtr -> Int in
            var ioVec = iovec(iov_base: UnsafeMutableRawPointer(markerPtr), iov_len: 1)
            return control.withUnsafeMutableBytes { controlRaw -> Int in
                guard let controlBase = controlRaw.baseAddress else { return -1 }
                var message = msghdr()
                message.msg_iov = withUnsafeMutablePointer(to: &ioVec) { $0 }
                message.msg_iovlen = 1
                message.msg_control = controlBase
                message.msg_controllen = socklen_t(controlRaw.count)

                let dataOffset = cmsgDataOffset()
                guard controlRaw.count >= dataOffset + MemoryLayout<Int32>.size else { return -1 }

                let cmsg = controlBase.assumingMemoryBound(to: cmsghdr.self)
                cmsg.pointee.cmsg_level = SOL_SOCKET
                cmsg.pointee.cmsg_type = SCM_RIGHTS
                cmsg.pointee.cmsg_len = socklen_t(dataOffset + payloadSize)

                controlBase.advanced(by: dataOffset).assumingMemoryBound(to: Int32.self).pointee = descriptorFD
                return Darwin.sendmsg(socketFD, &message, 0)
            }
        }

        guard sent == 1 else {
            if sent < 0 {
                throw makePOSIXError(errno)
            }
            throw makePOSIXLikeError(message: "sendmsg sent unexpected byte count: \(sent)")
        }
    }

    public static func sendNoFileDescriptorMarker(socketFD: Int32) throws {
        var marker: UInt8 = 0
        let sent = withUnsafeMutablePointer(to: &marker) { pointer in
            Darwin.write(socketFD, pointer, 1)
        }
        guard sent == 1 else {
            if sent < 0 {
                throw makePOSIXError(errno)
            }
            throw makePOSIXLikeError(message: "failed to send no-fd marker")
        }
    }

    public static func receiveOptionalFileDescriptorMarker(socketFD: Int32) throws -> Int32? {
        var marker: UInt8 = 0
        var control = [UInt8](repeating: 0, count: cmsgSpace(MemoryLayout<Int32>.size))

        let receivedFD: Int32? = withUnsafeMutablePointer(to: &marker) { markerPtr -> Int32? in
            var ioVec = iovec(iov_base: UnsafeMutableRawPointer(markerPtr), iov_len: 1)
            return control.withUnsafeMutableBytes { controlRaw -> Int32? in
                guard let controlBase = controlRaw.baseAddress else { return nil }
                var message = msghdr()
                message.msg_iov = withUnsafeMutablePointer(to: &ioVec) { $0 }
                message.msg_iovlen = 1
                message.msg_control = controlBase
                message.msg_controllen = socklen_t(controlRaw.count)

                let n = Darwin.recvmsg(socketFD, &message, 0)
                guard n == 1 else {
                    if n < 0 {
                        return Int32.min
                    }
                    return Int32.max
                }
                if markerPtr.pointee == 0 {
                    return 0
                }
                guard markerPtr.pointee == 1 else {
                    return Int32.max - 1
                }
                guard Int(message.msg_controllen) >= cmsgDataOffset() + MemoryLayout<Int32>.size else {
                    return Int32.max - 2
                }

                let cmsg = controlBase.assumingMemoryBound(to: cmsghdr.self)
                guard cmsg.pointee.cmsg_level == SOL_SOCKET, cmsg.pointee.cmsg_type == SCM_RIGHTS else {
                    return Int32.max - 3
                }
                return controlBase.advanced(by: cmsgDataOffset()).assumingMemoryBound(to: Int32.self).pointee
            }
        }

        guard let receivedFD else {
            throw makePOSIXLikeError(message: "recvmsg returned no ancillary data")
        }
        switch receivedFD {
        case Int32.min:
            throw makePOSIXError(errno)
        case 0:
            return nil
        case Int32.max:
            throw makePOSIXLikeError(message: "recvmsg expected 1 byte marker")
        case Int32.max - 1:
            throw makePOSIXLikeError(message: "invalid fd marker byte")
        case Int32.max - 2:
            throw makePOSIXLikeError(message: "missing SCM_RIGHTS ancillary data")
        case Int32.max - 3:
            throw makePOSIXLikeError(message: "unexpected ancillary data type")
        default:
            return receivedFD
        }
    }

    public static func receiveFileDescriptorMarker(socketFD: Int32) throws -> Int32 {
        guard let fd = try receiveOptionalFileDescriptorMarker(socketFD: socketFD) else {
            throw makePOSIXLikeError(message: "expected fd marker but received none")
        }
        return fd
    }

    public static func connectUnixSocket(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw makePOSIXError(errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxPathCount = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxPathCount else {
            Darwin.close(fd)
            throw makePOSIXLikeError(message: "unix socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard result == 0 else {
            let error = makePOSIXError(errno)
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    public static func readExact(fd: Int32, count: Int) throws -> Data {
        try readExact(fd: fd, count: count, deadlineUptimeNanoseconds: nil)
    }

    private static func readExact(
        fd: Int32,
        count: Int,
        deadlineUptimeNanoseconds: UInt64?
    ) throws -> Data {
        if count == 0 { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            if let deadlineUptimeNanoseconds {
                try waitUntilReadable(fd: fd, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
            }
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                if deadlineUptimeNanoseconds != nil {
                    return Darwin.recv(fd, base.advanced(by: offset), count - offset, MSG_DONTWAIT)
                }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if readCount > 0 {
                offset += readCount
                continue
            }
            if readCount == 0 {
                throw makePOSIXLikeError(message: "unexpected EOF")
            }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK {
                if deadlineUptimeNanoseconds != nil {
                    continue
                }
                usleep(10_000)
                continue
            }
            throw makePOSIXError(code)
        }
        return Data(buffer)
    }

    public static func writeAll(data: Data, fd: Int32) throws {
        try writeAll(data: data, fd: fd, deadlineUptimeNanoseconds: nil)
    }

    private static func writeAll(
        data: Data,
        fd: Int32,
        deadlineUptimeNanoseconds: UInt64?
    ) throws {
        let maximumWriteSize = 64 * 1024
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                if let deadlineUptimeNanoseconds,
                    DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds
                {
                    throw POSIXError(.ETIMEDOUT)
                }
                let written: Int
                if deadlineUptimeNanoseconds != nil {
                    written = Darwin.send(
                        fd,
                        base.advanced(by: offset),
                        min(rawBuffer.count - offset, maximumWriteSize),
                        MSG_DONTWAIT | MSG_NOSIGNAL
                    )
                } else {
                    written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                }
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    throw makePOSIXLikeError(message: "write returned 0 bytes")
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    guard let deadlineUptimeNanoseconds else {
                        usleep(10_000)
                        continue
                    }
                    try waitUntilWritable(fd: fd, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
                    continue
                }
                throw makePOSIXError(code)
            }
        }
    }

    private static func monotonicDeadline(timeoutMilliseconds: Int32?) -> UInt64? {
        guard let timeoutMilliseconds else {
            return nil
        }
        let timeoutNanoseconds = UInt64(max(timeoutMilliseconds, 0)) * 1_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(timeoutNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    private static func waitUntilWritable(fd: Int32, deadlineUptimeNanoseconds: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadlineUptimeNanoseconds else {
                throw POSIXError(.ETIMEDOUT)
            }
            let remainingNanoseconds = deadlineUptimeNanoseconds - now
            let roundedMilliseconds = 1 + ((remainingNanoseconds - 1) / 1_000_000)
            let remainingMilliseconds = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let result = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if result > 0 {
                return
            }
            if result == 0 {
                throw POSIXError(.ETIMEDOUT)
            }
            if errno == EINTR {
                continue
            }
            throw makePOSIXError(errno)
        }
    }

    private static func waitUntilReadable(fd: Int32, deadlineUptimeNanoseconds: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadlineUptimeNanoseconds else {
                throw POSIXError(.ETIMEDOUT)
            }
            let remainingNanoseconds = deadlineUptimeNanoseconds - now
            let roundedMilliseconds = 1 + ((remainingNanoseconds - 1) / 1_000_000)
            let remainingMilliseconds = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if result > 0 {
                if descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                    return
                }
                continue
            }
            if result == 0 {
                throw POSIXError(.ETIMEDOUT)
            }
            if errno == EINTR {
                continue
            }
            throw makePOSIXError(errno)
        }
    }
}

private func cmsgSpace(_ length: Int) -> Int {
    let alignment = MemoryLayout<UInt32>.size
    let header = MemoryLayout<cmsghdr>.size
    let align = { (value: Int) in (value + alignment - 1) & ~(alignment - 1) }
    return align(header) + align(length)
}

private func cmsgDataOffset() -> Int {
    let alignment = MemoryLayout<UInt32>.size
    let header = MemoryLayout<cmsghdr>.size
    return (header + alignment - 1) & ~(alignment - 1)
}

public func makePOSIXError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
}

public func makePOSIXLikeError(message: String) -> NSError {
    NSError(domain: "RuntimeMacOSSidecarShared", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
