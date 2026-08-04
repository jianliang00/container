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
import RuntimeMacOSSidecarShared

/// Implements Kubernetes resolver search and `ndots` behavior before forwarding to cluster DNS.
/// macOS SystemConfiguration applies search domains only to single-label names, so multi-label
/// service names require a local resolver to match the semantics of a Pod's `resolv.conf`.
final class GuestDNSProxy: @unchecked Sendable {
    struct ResolutionConfiguration: Sendable {
        let nameservers: [String]
        let searchDomains: [DNSWireName]
        let ndots: Int
        let timeoutSeconds: Int

        init(_ dns: MacOSGuestDNSConfiguration) throws {
            nameservers = dns.nameservers
            searchDomains = try dns.searchDomains.map(DNSWireName.init)
            ndots = Self.integerOption(named: "ndots", in: dns.options, defaultValue: 1, range: 1...15)
            timeoutSeconds = Self.integerOption(named: "timeout", in: dns.options, defaultValue: 5, range: 1...30)
        }

        func candidates(for name: DNSWireName) -> [DNSWireName] {
            guard !name.labels.isEmpty else {
                return [name]
            }
            if searchDomains.contains(where: { name.hasSuffix($0) }) {
                return [name]
            }

            let searched = searchDomains.compactMap { try? name.appending($0) }
            let ordered = name.dotCount >= ndots ? [name] + searched : searched + [name]
            var unique: [DNSWireName] = []
            for candidate in ordered where !unique.contains(where: { $0.isEqualCaseInsensitive(to: candidate) }) {
                unique.append(candidate)
            }
            return unique
        }

        private static func integerOption(
            named name: String,
            in options: [String],
            defaultValue: Int,
            range: ClosedRange<Int>
        ) -> Int {
            for option in options.reversed() {
                let fields = option.split(separator: ":", maxSplits: 1).map(String.init)
                guard fields.count == 2, fields[0].caseInsensitiveCompare(name) == .orderedSame,
                    let value = Int(fields[1])
                else {
                    continue
                }
                return min(max(value, range.lowerBound), range.upperBound)
            }
            return defaultValue
        }
    }

    private enum Transport {
        case udp
        case tcp

        var socketType: Int32 {
            switch self {
            case .udp:
                return Int32(SOCK_DGRAM)
            case .tcp:
                return Int32(SOCK_STREAM)
            }
        }

        var socketProtocol: Int32 {
            switch self {
            case .udp:
                return IPPROTO_UDP
            case .tcp:
                return IPPROTO_TCP
            }
        }
    }

    private struct ClientAddress: @unchecked Sendable {
        let storage: sockaddr_storage
        let length: socklen_t
    }

    static let shared = GuestDNSProxy()
    static let listenAddress = "127.0.0.1"
    static let listenPort: UInt16 = 53

    private let lock = NSLock()
    private let querySlots = DispatchSemaphore(value: 64)
    private var configuration: ResolutionConfiguration?
    private var udpFD: Int32 = -1
    private var tcpFD: Int32 = -1

    deinit {
        Self.closeSocket(udpFD)
        Self.closeSocket(tcpFD)
    }

    func configure(_ dns: MacOSGuestDNSConfiguration) throws -> MacOSGuestDNSConfiguration {
        guard Self.requiresProxy(dns) else {
            lock.lock()
            configuration = nil
            lock.unlock()
            return dns
        }

        let newConfiguration = try ResolutionConfiguration(dns)
        try startIfNeeded(configuration: newConfiguration)
        return MacOSGuestDNSConfiguration(
            nameservers: [Self.listenAddress],
            domain: dns.domain,
            searchDomains: dns.searchDomains,
            options: dns.options
        )
    }

    static func requiresProxy(_ dns: MacOSGuestDNSConfiguration) -> Bool {
        !dns.nameservers.isEmpty && !dns.searchDomains.isEmpty
            && !dns.nameservers.contains(where: { $0 == listenAddress || $0 == "::1" })
    }

    private func startIfNeeded(configuration newConfiguration: ResolutionConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }

        if udpFD >= 0, tcpFD >= 0 {
            configuration = newConfiguration
            return
        }

        let newUDPFD = try Self.bindSocket(type: Int32(SOCK_DGRAM), protocol: IPPROTO_UDP)
        do {
            let newTCPFD = try Self.bindSocket(type: Int32(SOCK_STREAM), protocol: IPPROTO_TCP)
            guard Darwin.listen(newTCPFD, 32) == 0 else {
                throw POSIXError.fromErrno()
            }

            configuration = newConfiguration
            udpFD = newUDPFD
            tcpFD = newTCPFD

            Thread.detachNewThread { [weak self] in
                self?.serveUDP(fd: newUDPFD)
            }
            Thread.detachNewThread { [weak self] in
                self?.serveTCP(fd: newTCPFD)
            }
            Self.log("DNS proxy listening on \(Self.listenAddress):\(Self.listenPort) over UDP and TCP")
        } catch {
            Self.closeSocket(newUDPFD)
            throw error
        }
    }

    private func serveUDP(fd: Int32) {
        while true {
            var buffer = [UInt8](repeating: 0, count: Int(UInt16.max))
            var storage = sockaddr_storage()
            var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    buffer.withUnsafeMutableBytes { bytes in
                        Darwin.recvfrom(fd, bytes.baseAddress, bytes.count, 0, addressPointer, &addressLength)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                Self.log("UDP receive failed: \(String(cString: strerror(errno)))")
                continue
            }
            guard count > 0 else {
                continue
            }

            let query = Array(buffer[..<count])
            let client = ClientAddress(storage: storage, length: addressLength)
            querySlots.wait()
            Thread.detachNewThread { [self] in
                defer { self.querySlots.signal() }
                let response = self.resolve(query: query, transport: .udp)
                guard !response.isEmpty else {
                    return
                }
                var clientStorage = client.storage
                let result = withUnsafePointer(to: &clientStorage) { storagePointer in
                    storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                        response.withUnsafeBytes { bytes in
                            Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, addressPointer, client.length)
                        }
                    }
                }
                if result < 0 {
                    Self.log("UDP response failed: \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    private func serveTCP(fd: Int32) {
        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                Self.log("TCP accept failed: \(String(cString: strerror(errno)))")
                continue
            }
            var on: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            querySlots.wait()
            Thread.detachNewThread { [self] in
                defer { Self.closeSocket(clientFD) }
                defer { self.querySlots.signal() }
                self.handleTCPClient(fd: clientFD)
            }
        }
    }

    private func handleTCPClient(fd: Int32) {
        while true {
            guard let lengthBytes = try? Self.readExactly(2, from: fd) else {
                return
            }
            let length = Int(UInt16(lengthBytes[0]) << 8 | UInt16(lengthBytes[1]))
            guard length > 0, let query = try? Self.readExactly(length, from: fd) else {
                return
            }
            let response = resolve(query: query, transport: .tcp)
            guard !response.isEmpty, response.count <= Int(UInt16.max) else {
                return
            }
            let responseLength = UInt16(response.count)
            let prefix = [UInt8((responseLength >> 8) & 0xff), UInt8(responseLength & 0xff)]
            do {
                try Self.writeAll(prefix, to: fd)
                try Self.writeAll(response, to: fd)
            } catch {
                return
            }
        }
    }

    private func resolve(query: [UInt8], transport: Transport) -> [UInt8] {
        guard let configuration = currentConfiguration() else {
            return DNSWireMessage.serverFailureResponse(for: query)
        }

        do {
            let originalName = try DNSWireMessage.questionName(in: query)
            let candidates = configuration.candidates(for: originalName)

            for (index, candidate) in candidates.enumerated() {
                let candidateQuery: [UInt8]
                if candidate.isEqualCaseInsensitive(to: originalName) {
                    candidateQuery = query
                } else {
                    candidateQuery = try DNSWireMessage.replacingQuestionName(in: query, with: candidate)
                }

                guard
                    let response = forward(
                        query: candidateQuery,
                        transport: transport,
                        configuration: configuration
                    )
                else {
                    continue
                }
                if !DNSWireMessage.isTruncated(response), DNSWireMessage.isSearchMiss(response),
                    index < candidates.count - 1
                {
                    continue
                }
                let clientResponse: [UInt8]
                if candidate.isEqualCaseInsensitive(to: originalName) {
                    clientResponse = response
                } else {
                    clientResponse = try DNSWireMessage.rewritingResponse(
                        response,
                        expandedName: candidate,
                        originalName: originalName
                    )
                }
                return Self.responseForClient(clientResponse, query: query, transport: transport)
            }

            return DNSWireMessage.serverFailureResponse(for: query)
        } catch {
            Self.log("failed to process DNS query: \(error)")
            return DNSWireMessage.serverFailureResponse(for: query)
        }
    }

    private static func responseForClient(_ response: [UInt8], query: [UInt8], transport: Transport) -> [UInt8] {
        guard transport == .udp, response.count > DNSWireMessage.udpPayloadSize(in: query) else {
            return response
        }
        return DNSWireMessage.truncatedResponse(for: query)
    }

    private func forward(
        query: [UInt8],
        transport: Transport,
        configuration: ResolutionConfiguration
    ) -> [UInt8]? {
        for nameserver in configuration.nameservers {
            do {
                let response = try Self.exchange(
                    query: query,
                    nameserver: nameserver,
                    transport: transport,
                    timeoutSeconds: configuration.timeoutSeconds
                )
                guard DNSWireMessage.transactionID(response) == DNSWireMessage.transactionID(query) else {
                    continue
                }
                if DNSWireMessage.isServerFailure(response) {
                    continue
                }
                return response
            } catch {
                continue
            }
        }
        return nil
    }

    private func currentConfiguration() -> ResolutionConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    private static func bindSocket(type: Int32, protocol socketProtocol: Int32) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, type, socketProtocol)
        guard fd >= 0 else {
            throw POSIXError.fromErrno()
        }
        do {
            var on: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError.fromErrno()
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = listenPort.bigEndian
            guard inet_pton(AF_INET, listenAddress, &address.sin_addr) == 1 else {
                throw POSIXError(.EINVAL)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                throw POSIXError.fromErrno()
            }
            return fd
        } catch {
            closeSocket(fd)
            throw error
        }
    }

    private static func exchange(
        query: [UInt8],
        nameserver: String,
        transport: Transport,
        timeoutSeconds: Int
    ) throws -> [UInt8] {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = transport.socketType
        hints.ai_protocol = transport.socketProtocol

        var result: UnsafeMutablePointer<addrinfo>?
        let errorCode = getaddrinfo(nameserver, "53", &hints, &result)
        guard errorCode == 0, let first = result else {
            throw DNSWireError.invalidMessage("invalid DNS nameserver \(nameserver)")
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var lastError: Error = POSIXError(.EHOSTUNREACH)
        while let infoPointer = current {
            let info = infoPointer.pointee
            let fd = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else {
                current = info.ai_next
                continue
            }
            do {
                try configureTimeouts(fd: fd, seconds: timeoutSeconds)
                var on: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                guard Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0 else {
                    throw POSIXError.fromErrno()
                }

                let response: [UInt8]
                switch transport {
                case .udp:
                    let written = query.withUnsafeBytes {
                        Darwin.send(fd, $0.baseAddress, $0.count, 0)
                    }
                    guard written == query.count else {
                        throw written < 0 ? POSIXError.fromErrno() : POSIXError(.EIO)
                    }
                    var buffer = [UInt8](repeating: 0, count: Int(UInt16.max))
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.recv(fd, $0.baseAddress, $0.count, 0)
                    }
                    guard count > 0 else {
                        throw POSIXError.fromErrno()
                    }
                    response = Array(buffer[..<count])
                case .tcp:
                    guard query.count <= Int(UInt16.max) else {
                        throw DNSWireError.invalidMessage("DNS query exceeds TCP framing limit")
                    }
                    let queryLength = UInt16(query.count)
                    try writeAll(
                        [UInt8((queryLength >> 8) & 0xff), UInt8(queryLength & 0xff)] + query,
                        to: fd
                    )
                    let lengthBytes = try readExactly(2, from: fd)
                    let responseLength = Int(UInt16(lengthBytes[0]) << 8 | UInt16(lengthBytes[1]))
                    response = try readExactly(responseLength, from: fd)
                }
                closeSocket(fd)
                return response
            } catch {
                lastError = error
                closeSocket(fd)
                current = info.ai_next
            }
        }
        throw lastError
    }

    private static func configureTimeouts(fd: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
        else {
            throw POSIXError.fromErrno()
        }
    }

    private static func readExactly(_ count: Int, from fd: Int32) throws -> [UInt8] {
        guard count >= 0 else {
            throw POSIXError(.EINVAL)
        }
        var result = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = result.withUnsafeMutableBytes { bytes in
                Darwin.recv(fd, bytes.baseAddress?.advanced(by: offset), count - offset, 0)
            }
            if received < 0, errno == EINTR {
                continue
            }
            guard received > 0 else {
                throw received == 0 ? POSIXError(.ECONNRESET) : POSIXError.fromErrno()
            }
            offset += received
        }
        return result
    }

    private static func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
            }
            if written < 0, errno == EINTR {
                continue
            }
            guard written > 0 else {
                throw POSIXError.fromErrno()
            }
            offset += written
        }
    }

    private static func log(_ message: String) {
        fputs("container-macos-guest-agent: \(message)\n", stderr)
        fflush(stderr)
    }

    private static func closeSocket(_ fd: Int32) {
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }
}
