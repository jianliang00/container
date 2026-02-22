import Darwin
import Foundation

public enum MacOSSidecarMethod: String, Codable, Sendable {
    case vmBootstrapStart = "vm.bootstrapStart"
    case vmConnectVsock = "vm.connectVsock"
    case processExecSync = "process.execSync"
    case vmStop = "vm.stop"
    case vmState = "vm.state"
    case sidecarQuit = "sidecar.quit"
}

public struct MacOSSidecarExecRequestPayload: Codable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String]?
    public let workingDirectory: String?
    public let terminal: Bool

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String]? = nil,
        workingDirectory: String? = nil,
        terminal: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
    }
}

public struct MacOSSidecarExecResultPayload: Codable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let agentError: String?

    public init(exitCode: Int32, stdout: Data, stderr: Data, agentError: String? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.agentError = agentError
    }
}

public struct MacOSSidecarRequest: Codable, Sendable {
    public let requestID: String
    public let method: MacOSSidecarMethod
    public let port: UInt32?
    public let exec: MacOSSidecarExecRequestPayload?

    public init(
        requestID: String = UUID().uuidString,
        method: MacOSSidecarMethod,
        port: UInt32? = nil,
        exec: MacOSSidecarExecRequestPayload? = nil
    ) {
        self.requestID = requestID
        self.method = method
        self.port = port
        self.exec = exec
    }
}

public struct MacOSSidecarErrorPayload: Codable, Sendable {
    public let code: String
    public let message: String
    public let details: String?

    public init(code: String, message: String, details: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct MacOSSidecarResponse: Codable, Sendable {
    public let requestID: String
    public let ok: Bool
    public let state: String?
    public let fdAttached: Bool?
    public let execResult: MacOSSidecarExecResultPayload?
    public let error: MacOSSidecarErrorPayload?

    public init(
        requestID: String,
        ok: Bool,
        state: String? = nil,
        fdAttached: Bool? = nil,
        execResult: MacOSSidecarExecResultPayload? = nil,
        error: MacOSSidecarErrorPayload? = nil
    ) {
        self.requestID = requestID
        self.ok = ok
        self.state = state
        self.fdAttached = fdAttached
        self.execResult = execResult
        self.error = error
    }

    public static func success(
        requestID: String,
        state: String? = nil,
        fdAttached: Bool? = nil,
        execResult: MacOSSidecarExecResultPayload? = nil
    ) -> Self {
        .init(requestID: requestID, ok: true, state: state, fdAttached: fdAttached, execResult: execResult, error: nil)
    }

    public static func failure(requestID: String, code: String, message: String, details: String? = nil) -> Self {
        .init(requestID: requestID, ok: false, state: nil, fdAttached: nil, execResult: nil, error: .init(code: code, message: message, details: details))
    }
}

public enum MacOSSidecarSocketIO {
    public static func writeJSONFrame<T: Encodable>(_ value: T, fd: Int32, encoder: JSONEncoder = JSONEncoder()) throws {
        let payload = try encoder.encode(value)
        try writeFrame(payload, fd: fd)
    }

    public static func readJSONFrame<T: Decodable>(_ type: T.Type, fd: Int32, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let payload = try readFrame(fd: fd)
        return try decoder.decode(T.self, from: payload)
    }

    public static func writeFrame(_ payload: Data, fd: Int32) throws {
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try writeAll(data: header, fd: fd)
        try writeAll(data: payload, fd: fd)
    }

    public static func readFrame(fd: Int32, maxSize: Int = 16 * 1024 * 1024) throws -> Data {
        let header = try readExact(fd: fd, count: MemoryLayout<UInt32>.size)
        let length = header.withUnsafeBytes { raw in
            raw.load(as: UInt32.self).bigEndian
        }
        let payloadLength = Int(length)
        guard payloadLength >= 0, payloadLength <= maxSize else {
            throw makePOSIXLikeError(message: "invalid frame size: \(payloadLength)")
        }
        return try readExact(fd: fd, count: payloadLength)
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
        if count == 0 { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
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
                usleep(10_000)
                continue
            }
            throw makePOSIXError(code)
        }
        return Data(buffer)
    }

    public static func writeAll(data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
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
                    usleep(10_000)
                    continue
                }
                throw makePOSIXError(code)
            }
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
