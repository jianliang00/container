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

private let maximumFlannelStatusErrorMessageSize = 4096
private let maximumFlannelStatusFreshnessSeconds: TimeInterval = 3 * 24 * 60 * 60

public enum FlannelStatusState: String, Codable, Sendable, Equatable {
    case starting
    case ready
    case degraded
    case failed
}

public enum FlannelStatusFreshness: Sendable, Equatable {
    case fresh
    case expired
}

public struct FlannelStatusWireCounters: Codable, Sendable, Equatable {
    public var transmittedPackets: UInt64
    public var transmittedBytes: UInt64
    public var receivedPackets: UInt64
    public var receivedBytes: UInt64
    public var unknownPeerPackets: UInt64
    public var invalidPackets: UInt64
    public var oversizedPackets: UInt64
    public var sourceCIDRMismatches: UInt64

    public init(
        transmittedPackets: UInt64,
        transmittedBytes: UInt64,
        receivedPackets: UInt64,
        receivedBytes: UInt64,
        unknownPeerPackets: UInt64,
        invalidPackets: UInt64,
        oversizedPackets: UInt64,
        sourceCIDRMismatches: UInt64
    ) {
        self.transmittedPackets = transmittedPackets
        self.transmittedBytes = transmittedBytes
        self.receivedPackets = receivedPackets
        self.receivedBytes = receivedBytes
        self.unknownPeerPackets = unknownPeerPackets
        self.invalidPackets = invalidPackets
        self.oversizedPackets = oversizedPackets
        self.sourceCIDRMismatches = sourceCIDRMismatches
    }

    public init(statistics: FlannelTunnelStatistics) {
        self.init(
            transmittedPackets: statistics.transmittedPackets,
            transmittedBytes: statistics.transmittedBytes,
            receivedPackets: statistics.receivedPackets,
            receivedBytes: statistics.receivedBytes,
            unknownPeerPackets: statistics.unknownPeerPackets,
            invalidPackets: statistics.invalidPackets,
            oversizedPackets: statistics.oversizedPackets,
            sourceCIDRMismatches: statistics.sourceCIDRMismatches
        )
    }
}

public struct FlannelFamilyStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var ready: Bool?
    public var podCIDR: String?
    public var peerCount: Int?
    public var routeCount: Int?
    public var tunnelUp: Bool?
    public var interfaceName: String?
    public var tunnelEpoch: UInt64?
    public var wireCounters: FlannelStatusWireCounters?

    public init(
        enabled: Bool,
        ready: Bool?,
        podCIDR: String?,
        peerCount: Int?,
        routeCount: Int?,
        tunnelUp: Bool?,
        interfaceName: String?,
        tunnelEpoch: UInt64?,
        wireCounters: FlannelStatusWireCounters?
    ) {
        self.enabled = enabled
        self.ready = ready
        self.podCIDR = podCIDR
        self.peerCount = peerCount
        self.routeCount = routeCount
        self.tunnelUp = tunnelUp
        self.interfaceName = interfaceName
        self.tunnelEpoch = tunnelEpoch
        self.wireCounters = wireCounters
    }

    public static func unknown(enabled: Bool) -> Self {
        Self(
            enabled: enabled,
            ready: nil,
            podCIDR: nil,
            peerCount: nil,
            routeCount: nil,
            tunnelUp: nil,
            interfaceName: nil,
            tunnelEpoch: nil,
            wireCounters: nil
        )
    }

    public static var disabled: Self {
        Self(
            enabled: false,
            ready: false,
            podCIDR: nil,
            peerCount: 0,
            routeCount: 0,
            tunnelUp: false,
            interfaceName: nil,
            tunnelEpoch: nil,
            wireCounters: nil
        )
    }
}

public struct FlannelStatus: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var nodeName: String
    public var networkName: String
    public var controllerInstanceID: String
    public var updatedAt: String
    public var expiresAt: String
    public var stateSince: String
    public var lastSuccessAt: String?
    public var state: FlannelStatusState
    public var attemptedGeneration: Int
    public var lastSuccessfulGeneration: Int?
    public var runtimeGeneration: UInt64?
    public var mtu: Int?
    public var errorCode: String?
    public var errorMessage: String?
    public var ipv4: FlannelFamilyStatus
    public var ipv6: FlannelFamilyStatus

    public init(
        nodeName: String,
        networkName: String,
        controllerInstanceID: String,
        updatedAt: String,
        expiresAt: String,
        stateSince: String,
        lastSuccessAt: String?,
        state: FlannelStatusState,
        attemptedGeneration: Int,
        lastSuccessfulGeneration: Int? = nil,
        runtimeGeneration: UInt64? = nil,
        mtu: Int? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        ipv4: FlannelFamilyStatus,
        ipv6: FlannelFamilyStatus,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.nodeName = nodeName
        self.networkName = networkName
        self.controllerInstanceID = controllerInstanceID
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.stateSince = stateSince
        self.lastSuccessAt = lastSuccessAt
        self.state = state
        self.attemptedGeneration = attemptedGeneration
        self.lastSuccessfulGeneration = lastSuccessfulGeneration
        self.runtimeGeneration = runtimeGeneration
        self.mtu = mtu
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    public func freshness(at date: Date = Date()) throws -> FlannelStatusFreshness {
        _ = try validated()
        let timestamps = try parsedTimestamps()
        return date >= timestamps.updatedAt && date < timestamps.expiresAt ? .fresh : .expired
    }

    public func isFreshlyReady(at date: Date = Date()) throws -> Bool {
        _ = try validated()
        let timestamps = try parsedTimestamps()
        return state == .ready
            && date >= timestamps.updatedAt
            && date < timestamps.expiresAt
    }

    fileprivate func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FlannelStatusStoreError.persistence(
                "unsupported flannel status schema version \(schemaVersion)"
            )
        }
        try Self.validateName(nodeName, field: "node")
        try Self.validateName(networkName, field: "network")
        guard UUID(uuidString: controllerInstanceID) != nil else {
            throw FlannelStatusStoreError.persistence("flannel status contains an invalid controller instance ID")
        }
        guard attemptedGeneration >= 0,
            lastSuccessfulGeneration.map({ $0 >= 0 && $0 <= attemptedGeneration }) ?? true,
            (lastSuccessAt == nil) == (lastSuccessfulGeneration == nil),
            mtu.map({ $0 > 0 }) ?? true
        else {
            throw FlannelStatusStoreError.persistence("flannel status contains an invalid generation or MTU")
        }
        try validateFamily(ipv4, name: "IPv4")
        try validateFamily(ipv6, name: "IPv6")
        guard ipv4.enabled else {
            throw FlannelStatusStoreError.persistence("flannel status must enable IPv4")
        }
        _ = try parsedTimestamps()
        guard (errorCode == nil) == (errorMessage == nil),
            errorCode.map({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) ?? true,
            errorMessage.map({ !$0.isEmpty && $0.utf8.count <= maximumFlannelStatusErrorMessageSize }) ?? true
        else {
            throw FlannelStatusStoreError.persistence("flannel status contains an invalid error")
        }

        switch state {
        case .starting:
            guard attemptedGeneration == 0,
                lastSuccessfulGeneration == nil,
                runtimeGeneration == nil,
                mtu == nil,
                lastSuccessAt == nil,
                errorCode == nil,
                errorMessage == nil,
                Self.hasUnknownOperationalState(ipv4),
                Self.hasUnknownOperationalState(ipv6)
            else {
                throw FlannelStatusStoreError.persistence("starting flannel status is inconsistent")
            }
        case .ready:
            guard attemptedGeneration > 0,
                lastSuccessfulGeneration == attemptedGeneration,
                runtimeGeneration != nil,
                mtu != nil,
                lastSuccessAt != nil,
                errorCode == nil,
                errorMessage == nil,
                ipv4.enabled,
                ipv4.ready == true,
                ipv4.tunnelUp == true,
                !ipv6.enabled || ipv6.ready == true
            else {
                throw FlannelStatusStoreError.persistence("ready flannel status is inconsistent")
            }
        case .degraded:
            guard attemptedGeneration > 0,
                lastSuccessfulGeneration == attemptedGeneration,
                runtimeGeneration != nil,
                mtu != nil,
                lastSuccessAt != nil,
                errorCode != nil,
                errorMessage != nil,
                ipv4.enabled
            else {
                throw FlannelStatusStoreError.persistence("degraded flannel status is inconsistent")
            }
        case .failed:
            guard attemptedGeneration > 0,
                runtimeGeneration == nil,
                mtu == nil,
                errorCode != nil,
                errorMessage != nil,
                Self.hasUnknownOperationalState(ipv4),
                Self.hasUnknownOperationalState(ipv6)
            else {
                throw FlannelStatusStoreError.persistence("failed flannel status is inconsistent")
            }
        }
        return self
    }

    private func validateFamily(_ family: FlannelFamilyStatus, name: String) throws {
        guard family.peerCount.map({ $0 >= 0 }) ?? true,
            family.routeCount.map({ $0 >= 0 }) ?? true,
            family.podCIDR.map({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) ?? true,
            family.interfaceName.map(Self.isValidInterfaceName) ?? true
        else {
            throw FlannelStatusStoreError.persistence("flannel status contains invalid \(name) data")
        }
        if state == .ready {
            if family.enabled {
                guard family.ready == true,
                    family.podCIDR != nil,
                    family.peerCount != nil,
                    family.routeCount != nil,
                    family.tunnelUp == true,
                    family.interfaceName != nil,
                    family.tunnelEpoch.map({ $0 > 0 }) == true,
                    family.wireCounters != nil
                else {
                    throw FlannelStatusStoreError.persistence(
                        "enabled \(name) flannel status lacks operational data"
                    )
                }
            } else {
                guard family == .disabled else {
                    throw FlannelStatusStoreError.persistence(
                        "disabled \(name) flannel status contains operational data"
                    )
                }
            }
        } else if state == .degraded {
            if family.enabled {
                guard family.ready != nil else {
                    throw FlannelStatusStoreError.persistence(
                        "enabled \(name) degraded flannel status lacks readiness data"
                    )
                }
            } else {
                guard family == .disabled else {
                    throw FlannelStatusStoreError.persistence(
                        "disabled \(name) flannel status contains operational data"
                    )
                }
            }
        }
    }

    private func parsedTimestamps() throws -> ParsedTimestamps {
        let updatedAt = try Self.parseTimestamp(updatedAt, field: "updatedAt")
        let expiresAt = try Self.parseTimestamp(expiresAt, field: "expiresAt")
        let stateSince = try Self.parseTimestamp(stateSince, field: "stateSince")
        let lastSuccessAt = try lastSuccessAt.map {
            try Self.parseTimestamp($0, field: "lastSuccessAt")
        }
        guard stateSince <= updatedAt,
            updatedAt < expiresAt,
            expiresAt.timeIntervalSince(updatedAt) <= maximumFlannelStatusFreshnessSeconds,
            lastSuccessAt.map({ $0 <= updatedAt }) ?? true
        else {
            throw FlannelStatusStoreError.persistence("flannel status timestamps are inconsistent")
        }
        return ParsedTimestamps(updatedAt: updatedAt, expiresAt: expiresAt)
    }

    private static func validateName(_ value: String, field: String) throws {
        guard !value.isEmpty,
            !value.contains("/"),
            !value.contains(where: \.isWhitespace)
        else {
            throw FlannelStatusStoreError.persistence("flannel status contains an invalid \(field) name")
        }
    }

    private static func isValidInterfaceName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count < Int(IFNAMSIZ)
            && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func hasUnknownOperationalState(_ family: FlannelFamilyStatus) -> Bool {
        family.ready == nil
            && family.podCIDR == nil
            && family.peerCount == nil
            && family.routeCount == nil
            && family.tunnelUp == nil
            && family.interfaceName == nil
            && family.tunnelEpoch == nil
            && family.wireCounters == nil
    }

    private static func parseTimestamp(_ timestamp: String, field: String) throws -> Date {
        let pattern =
            #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#
        guard timestamp.range(of: pattern, options: .regularExpression) != nil else {
            throw FlannelStatusStoreError.persistence(
                "flannel status contains an invalid RFC3339 \(field) timestamp"
            )
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat =
            timestamp.contains(".")
            ? "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
            : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        formatter.isLenient = false
        guard let date = formatter.date(from: timestamp) else {
            throw FlannelStatusStoreError.persistence(
                "flannel status contains an invalid RFC3339 \(field) timestamp"
            )
        }
        return date
    }

    private struct ParsedTimestamps {
        var updatedAt: Date
        var expiresAt: Date
    }
}

public enum FlannelStatusStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case persistence(String)

    public var description: String {
        switch self {
        case .persistence(let message):
            "flannel status persistence failed: \(message)"
        }
    }
}

public protocol FlannelStatusStoring: Sendable {
    func load() throws -> FlannelStatus?
    func save(_ status: FlannelStatus) throws
    func remove() throws
}

public struct FlannelStatusFileStore: FlannelStatusStoring, Sendable {
    private static let maximumEncodedSize = 64 * 1024

    public let url: URL
    private let requiredOwnerID: uid_t
    private let requiredGroupID: gid_t

    public init(
        path: String,
        requiredOwnerID: uid_t = geteuid(),
        requiredGroupID: gid_t = getegid()
    ) {
        self.url = URL(fileURLWithPath: path)
        self.requiredOwnerID = requiredOwnerID
        self.requiredGroupID = requiredGroupID
    }

    public init(
        url: URL,
        requiredOwnerID: uid_t = geteuid(),
        requiredGroupID: gid_t = getegid()
    ) {
        self.url = url
        self.requiredOwnerID = requiredOwnerID
        self.requiredGroupID = requiredGroupID
    }

    public func load() throws -> FlannelStatus? {
        guard let directoryDescriptor = try openDirectory(createIfMissing: false) else {
            return nil
        }
        defer { close(directoryDescriptor) }
        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw persistenceError("failed to open", errno: errno)
        }
        defer { close(descriptor) }
        let data = try readAll(from: descriptor, size: try validateFileDescriptor(descriptor))
        do {
            return try JSONDecoder().decode(FlannelStatus.self, from: data).validated()
        } catch let error as FlannelStatusStoreError {
            throw error
        } catch {
            throw FlannelStatusStoreError.persistence(
                "failed to decode status at \(url.path): \(error)"
            )
        }
    }

    public func save(_ status: FlannelStatus) throws {
        let status = try status.validated()
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(status)
        } catch let error as FlannelStatusStoreError {
            throw error
        } catch {
            throw FlannelStatusStoreError.persistence(
                "failed to encode status at \(url.path): \(error)"
            )
        }
        guard data.count <= Self.maximumEncodedSize else {
            throw FlannelStatusStoreError.persistence("status exceeds the size limit")
        }
        guard let directoryDescriptor = try openDirectory(createIfMissing: true) else {
            throw FlannelStatusStoreError.persistence(
                "failed to create status directory at \(url.deletingLastPathComponent().path)"
            )
        }
        defer { close(directoryDescriptor) }
        try validateExistingFile(in: directoryDescriptor)

        let temporaryName = ".status-\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw persistenceError("failed to create a temporary file for", errno: errno)
        }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }
        guard fchown(descriptor, requiredOwnerID, requiredGroupID) == 0 else {
            throw persistenceError("failed to set ownership of a temporary file for", errno: errno)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw persistenceError("failed to protect a temporary file for", errno: errno)
        }
        try validateNoExtendedACL(descriptor, object: "temporary status file")
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw persistenceError("failed to sync a temporary file for", errno: errno)
        }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, url.lastPathComponent) == 0 else {
            throw persistenceError("failed to commit", errno: errno)
        }
        renamed = true
        guard fsync(directoryDescriptor) == 0 else {
            throw persistenceError("failed to sync the directory for", errno: errno)
        }
    }

    public func remove() throws {
        guard let directoryDescriptor = try openDirectory(createIfMissing: false) else {
            return
        }
        defer { close(directoryDescriptor) }
        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw persistenceError("failed to open before removing", errno: errno)
        }
        defer { close(descriptor) }
        _ = try validateFileDescriptor(descriptor, enforceSizeLimit: false)
        guard unlinkat(directoryDescriptor, url.lastPathComponent, 0) == 0 else {
            if errno == ENOENT {
                return
            }
            throw persistenceError("failed to remove", errno: errno)
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw persistenceError("failed to sync the directory after removing", errno: errno)
        }
    }

    private func openDirectory(createIfMissing: Bool) throws -> Int32? {
        let directoryURL = url.deletingLastPathComponent()
        guard !url.lastPathComponent.isEmpty else {
            throw FlannelStatusStoreError.persistence("status path has no file name")
        }
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755]
                )
            } catch {
                throw FlannelStatusStoreError.persistence(
                    "failed to create status directory at \(directoryURL.path): \(error)"
                )
            }
        }
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT, !createIfMissing {
                return nil
            }
            throw FlannelStatusStoreError.persistence(
                "failed to open status directory at \(directoryURL.path): "
                    + Self.posixErrorDescription(errno)
            )
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            let errorNumber = errno
            close(descriptor)
            throw FlannelStatusStoreError.persistence(
                "failed to inspect open status directory at \(directoryURL.path): "
                    + Self.posixErrorDescription(errorNumber)
            )
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw FlannelStatusStoreError.persistence(
                "status directory at \(directoryURL.path) is not a directory"
            )
        }
        guard information.st_uid == requiredOwnerID, information.st_gid == requiredGroupID else {
            close(descriptor)
            throw FlannelStatusStoreError.persistence(
                "status directory at \(directoryURL.path) has unexpected ownership"
            )
        }
        guard information.st_mode & mode_t(0o022) == 0 else {
            close(descriptor)
            throw FlannelStatusStoreError.persistence(
                "status directory at \(directoryURL.path) is group or world writable"
            )
        }
        do {
            try validateNoExtendedACL(descriptor, object: "status directory")
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private func validateExistingFile(in directoryDescriptor: Int32) throws {
        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw persistenceError("failed to inspect before replacing", errno: errno)
        }
        defer { close(descriptor) }
        let data = try readAll(from: descriptor, size: try validateFileDescriptor(descriptor))
        do {
            _ = try JSONDecoder().decode(FlannelStatus.self, from: data).validated()
        } catch let error as FlannelStatusStoreError {
            throw error
        } catch {
            throw FlannelStatusStoreError.persistence(
                "refusing to replace invalid status at \(url.path): \(error)"
            )
        }
    }

    private func validateFileDescriptor(
        _ descriptor: Int32,
        enforceSizeLimit: Bool = true
    ) throws -> Int {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw persistenceError("failed to inspect", errno: errno)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw FlannelStatusStoreError.persistence("status at \(url.path) is not a regular file")
        }
        guard information.st_uid == requiredOwnerID, information.st_gid == requiredGroupID else {
            throw FlannelStatusStoreError.persistence("status at \(url.path) has unexpected ownership")
        }
        guard information.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw FlannelStatusStoreError.persistence("status at \(url.path) must have mode 0600")
        }
        try validateNoExtendedACL(descriptor, object: "status file")
        if enforceSizeLimit {
            guard information.st_size >= 0,
                information.st_size <= off_t(Self.maximumEncodedSize)
            else {
                throw FlannelStatusStoreError.persistence("status at \(url.path) exceeds the size limit")
            }
        }
        return enforceSizeLimit ? Int(information.st_size) : 0
    }

    private func validateNoExtendedACL(_ descriptor: Int32, object: String) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw persistenceError("failed to inspect the extended ACL of the \(object) for", errno: errno)
            }
            return
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw FlannelStatusStoreError.persistence(
            "\(object) at \(url.path) must not have an extended ACL"
        )
    }

    private func readAll(from descriptor: Int32, size: Int) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw persistenceError("failed to read", errno: errno)
                }
                guard count > 0 else {
                    throw FlannelStatusStoreError.persistence(
                        "status at \(url.path) ended before its recorded size"
                    )
                }
                offset += count
            }
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw persistenceError("failed to write", errno: errno)
                }
                guard count > 0 else {
                    throw FlannelStatusStoreError.persistence("status write made no progress")
                }
                offset += count
            }
        }
    }

    private func persistenceError(_ operation: String, errno errorNumber: Int32) -> FlannelStatusStoreError {
        .persistence(
            "\(operation) status at \(url.path): "
                + Self.posixErrorDescription(errorNumber)
        )
    }

    private static func posixErrorDescription(_ errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
    }
}

public struct FlannelStatusRecorder: Sendable {
    private static let minimumFreshnessSeconds = 15

    private let store: any FlannelStatusStoring
    private let now: @Sendable () -> Date
    private let controllerInstanceID: String

    public init(
        store: any FlannelStatusStoring,
        controllerInstanceID: String = UUID().uuidString,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.controllerInstanceID = controllerInstanceID
        self.now = now
    }

    @discardableResult
    public func recordStarting(
        nodeName: String,
        networkName: String,
        ipv6Enabled: Bool,
        syncPeriodSeconds: Int
    ) throws -> FlannelStatus {
        let now = now()
        let timestamp = Self.timestamp(now)
        let status = FlannelStatus(
            nodeName: nodeName,
            networkName: networkName,
            controllerInstanceID: controllerInstanceID,
            updatedAt: timestamp,
            expiresAt: Self.expirationTimestamp(from: now, syncPeriodSeconds: syncPeriodSeconds),
            stateSince: timestamp,
            lastSuccessAt: nil,
            state: .starting,
            attemptedGeneration: 0,
            ipv4: .unknown(enabled: true),
            ipv6: .unknown(enabled: ipv6Enabled)
        )
        try store.save(status.validated())
        return status
    }

    @discardableResult
    public func recordReconciled(
        nodeName: String,
        networkName: String,
        state: FlannelStatusState,
        generation: Int,
        runtimeGeneration: UInt64,
        mtu: Int,
        ipv4: FlannelFamilyStatus,
        ipv6: FlannelFamilyStatus,
        syncPeriodSeconds: Int,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) throws -> FlannelStatus {
        guard state == .ready || state == .degraded else {
            throw FlannelStatusStoreError.persistence(
                "a completed flannel reconcile must be ready or degraded"
            )
        }
        let previous = try previousStatus(nodeName: nodeName, networkName: networkName)
        let now = now()
        let timestamp = Self.timestamp(now)
        let sameState =
            previous?.state == state
            && (state != .degraded || previous?.errorCode == errorCode)
        let status = FlannelStatus(
            nodeName: nodeName,
            networkName: networkName,
            controllerInstanceID: controllerInstanceID,
            updatedAt: timestamp,
            expiresAt: Self.expirationTimestamp(from: now, syncPeriodSeconds: syncPeriodSeconds),
            stateSince: sameState ? previous!.stateSince : timestamp,
            lastSuccessAt: timestamp,
            state: state,
            attemptedGeneration: generation,
            lastSuccessfulGeneration: generation,
            runtimeGeneration: runtimeGeneration,
            mtu: mtu,
            errorCode: errorCode,
            errorMessage: errorMessage.map(Self.truncatedErrorMessage),
            ipv4: ipv4,
            ipv6: ipv6
        )
        try store.save(status.validated())
        return status
    }

    @discardableResult
    public func record(
        result: FlannelVXLANReconcileResult,
        generation: Int,
        config: FlannelVXLANMacOSConfig
    ) throws -> FlannelStatus {
        let ipv4Ready = result.ipv4Ready && result.tunnelUp && result.tunnelEpoch > 0
        let ipv4 = FlannelFamilyStatus(
            enabled: true,
            ready: ipv4Ready,
            podCIDR: result.localNetwork.podCIDR,
            peerCount: result.peers.count,
            routeCount: result.routeCount,
            tunnelUp: result.tunnelUp,
            interfaceName: result.interfaceName,
            tunnelEpoch: result.tunnelEpoch,
            wireCounters: FlannelStatusWireCounters(statistics: result.statistics)
        )
        let ipv6: FlannelFamilyStatus
        let ipv6Ready: Bool
        if config.dualStackEnabled {
            ipv6Ready =
                result.ipv6Ready == true
                && result.ipv6TunnelUp == true
                && result.ipv6TunnelEpoch.map({ $0 > 0 }) == true
            ipv6 = FlannelFamilyStatus(
                enabled: true,
                ready: ipv6Ready,
                podCIDR: result.localIPv6Network?.podCIDR,
                peerCount: result.ipv6Peers.count,
                routeCount: result.ipv6RouteCount,
                tunnelUp: result.ipv6TunnelUp,
                interfaceName: result.ipv6InterfaceName,
                tunnelEpoch: result.ipv6TunnelEpoch,
                wireCounters: result.ipv6Statistics.map {
                    FlannelStatusWireCounters(statistics: $0)
                }
            )
        } else {
            ipv6Ready = true
            ipv6 = .disabled
        }
        let ready =
            ipv4Ready
            && ipv6Ready
            && result.issues.isEmpty
        let error = ready ? nil : Self.degradedError(result: result, config: config)
        return try recordReconciled(
            nodeName: config.nodeName,
            networkName: config.networkName,
            state: ready ? .ready : .degraded,
            generation: generation,
            runtimeGeneration: result.runtimeGeneration,
            mtu: result.mtu,
            ipv4: ipv4,
            ipv6: ipv6,
            syncPeriodSeconds: config.syncPeriodSeconds,
            errorCode: error?.code,
            errorMessage: error?.message
        )
    }

    @discardableResult
    public func recordFailure(
        nodeName: String,
        networkName: String,
        generation: Int,
        ipv6Enabled: Bool,
        syncPeriodSeconds: Int,
        errorCode: String,
        errorMessage: String
    ) throws -> FlannelStatus {
        let previous = try previousStatus(nodeName: nodeName, networkName: networkName)
        let now = now()
        let timestamp = Self.timestamp(now)
        let sameFailure = previous?.state == .failed && previous?.errorCode == errorCode
        let status = FlannelStatus(
            nodeName: nodeName,
            networkName: networkName,
            controllerInstanceID: controllerInstanceID,
            updatedAt: timestamp,
            expiresAt: Self.expirationTimestamp(from: now, syncPeriodSeconds: syncPeriodSeconds),
            stateSince: sameFailure ? previous!.stateSince : timestamp,
            lastSuccessAt: previous?.lastSuccessAt,
            state: .failed,
            attemptedGeneration: generation,
            lastSuccessfulGeneration: previous?.lastSuccessfulGeneration,
            runtimeGeneration: nil,
            mtu: nil,
            errorCode: errorCode,
            errorMessage: Self.truncatedErrorMessage(errorMessage),
            ipv4: .unknown(enabled: true),
            ipv6: .unknown(enabled: ipv6Enabled)
        )
        try store.save(status.validated())
        return status
    }

    @discardableResult
    public func recordFailure(
        error: Error,
        generation: Int,
        config: FlannelVXLANMacOSConfig
    ) throws -> FlannelStatus {
        try recordFailure(
            nodeName: config.nodeName,
            networkName: config.networkName,
            generation: generation,
            ipv6Enabled: config.dualStackEnabled,
            syncPeriodSeconds: config.syncPeriodSeconds,
            errorCode: Self.errorCode(error),
            errorMessage: String(describing: error)
        )
    }

    @discardableResult
    public func recordFailure(
        error: Error,
        config: FlannelVXLANMacOSConfig
    ) throws -> FlannelStatus {
        let previous = try previousStatus(nodeName: config.nodeName, networkName: config.networkName)
        return try recordFailure(
            error: error,
            generation: max(1, previous?.attemptedGeneration ?? 1),
            config: config
        )
    }

    public func remove() throws {
        try store.remove()
    }

    private func previousStatus(nodeName: String, networkName: String) throws -> FlannelStatus? {
        guard let previous = try store.load(),
            previous.nodeName == nodeName,
            previous.networkName == networkName,
            previous.controllerInstanceID == controllerInstanceID
        else {
            return nil
        }
        return previous
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func expirationTimestamp(from updatedAt: Date, syncPeriodSeconds: Int) -> String {
        let maximumPeriodSeconds = Int(maximumFlannelStatusFreshnessSeconds) / 4
        let boundedPeriodSeconds = max(0, min(syncPeriodSeconds, maximumPeriodSeconds))
        let freshnessSeconds = max(boundedPeriodSeconds * 4, minimumFreshnessSeconds)
        return timestamp(updatedAt.addingTimeInterval(TimeInterval(freshnessSeconds)))
    }

    private static func degradedError(
        result: FlannelVXLANReconcileResult,
        config: FlannelVXLANMacOSConfig
    ) -> (code: String, message: String) {
        if let stoppedIssue = result.issues.first(where: { $0.id == "local/ipv6-tunnel-stopped" }) {
            return ("tunnelNotRunning", stoppedIssue.message)
        }
        if !result.issues.isEmpty {
            let message = result.issues.sorted().map {
                "\($0.id) [\($0.severity.rawValue)]: \($0.message)"
            }.joined(separator: "; ")
            return ("compileIssues", message)
        }
        var stoppedTunnels: [String] = []
        if !result.tunnelUp {
            stoppedTunnels.append("IPv4")
        }
        if config.dualStackEnabled, result.ipv6TunnelUp != true {
            stoppedTunnels.append("IPv6")
        }
        if !stoppedTunnels.isEmpty {
            return (
                "tunnelNotRunning",
                "Flannel \(stoppedTunnels.joined(separator: " and ")) tunnel is not running"
            )
        }
        var invalidEpochFamilies: [String] = []
        if result.tunnelEpoch == 0 {
            invalidEpochFamilies.append("IPv4")
        }
        if config.dualStackEnabled,
            result.ipv6Ready == true,
            result.ipv6TunnelEpoch.map({ $0 > 0 }) != true
        {
            invalidEpochFamilies.append("IPv6")
        }
        if !invalidEpochFamilies.isEmpty {
            return (
                "tunnelEpochInvalid",
                "Flannel \(invalidEpochFamilies.joined(separator: " and ")) tunnel epoch is invalid"
            )
        }
        var unavailableFamilies: [String] = []
        if !result.ipv4Ready {
            unavailableFamilies.append("IPv4")
        }
        if config.dualStackEnabled, result.ipv6Ready != true {
            unavailableFamilies.append("IPv6")
        }
        return (
            "familyNotReady",
            "Flannel data plane is not ready for \(unavailableFamilies.joined(separator: " and "))"
        )
    }

    private static func errorCode(_ error: Error) -> String {
        guard let error = error as? FlannelVXLANError else {
            return "unexpected"
        }
        switch error {
        case .invalidConfiguration:
            return "invalidConfiguration"
        case .invalidNetworkConfig:
            return "invalidNetworkConfig"
        case .invalidNode:
            return "invalidNode"
        case .kubernetesAPI, .kubernetesAPIStatus:
            return "kubernetesAPI"
        case .persistence:
            return "persistence"
        case .runtime:
            return "runtime"
        }
    }

    private static func truncatedErrorMessage(_ message: String) -> String {
        guard message.utf8.count > maximumFlannelStatusErrorMessageSize else {
            return message
        }
        var result = ""
        var encodedSize = 0
        for scalar in message.unicodeScalars {
            let scalarSize = scalar.utf8.count
            guard encodedSize + scalarSize <= maximumFlannelStatusErrorMessageSize else {
                break
            }
            result.unicodeScalars.append(scalar)
            encodedSize += scalarSize
        }
        return result
    }
}
