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

private let maximumKubeProxyStatusErrorMessageSize = 4096
private let maximumKubeProxyStatusFreshnessSeconds: TimeInterval = 3 * 24 * 60 * 60

public enum KubeProxyStatusState: String, Codable, Sendable, Equatable {
    case starting
    case applied
    case waitingForPodIngressRoute
    case failed
}

public enum KubeProxyStatusFreshness: Sendable, Equatable {
    case fresh
    case expired
}

public struct KubeProxyFamilyStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var applied: Bool?
    public var desiredRuleCount: Int?
    public var appliedRuleCount: Int?

    public init(
        enabled: Bool,
        applied: Bool?,
        desiredRuleCount: Int?,
        appliedRuleCount: Int?
    ) {
        self.enabled = enabled
        self.applied = applied
        self.desiredRuleCount = desiredRuleCount
        self.appliedRuleCount = appliedRuleCount
    }
}

public enum KubeProxyPFFinalState: String, Codable, Sendable, Equatable {
    case applied
    case withdrawn
    case unknown
}

public struct KubeProxyPFStatus: Codable, Sendable, Equatable {
    public var finalState: KubeProxyPFFinalState
    public var applyAttempted: Bool?
    public var applySucceeded: Bool?
    public var withdrawalAttempted: Bool?
    public var withdrawalSucceeded: Bool?
    public var rollbackAttempted: Bool?
    public var rollbackSucceeded: Bool?

    public init(
        finalState: KubeProxyPFFinalState,
        applyAttempted: Bool?,
        applySucceeded: Bool?,
        withdrawalAttempted: Bool?,
        withdrawalSucceeded: Bool?,
        rollbackAttempted: Bool?,
        rollbackSucceeded: Bool?
    ) {
        self.finalState = finalState
        self.applyAttempted = applyAttempted
        self.applySucceeded = applySucceeded
        self.withdrawalAttempted = withdrawalAttempted
        self.withdrawalSucceeded = withdrawalSucceeded
        self.rollbackAttempted = rollbackAttempted
        self.rollbackSucceeded = rollbackSucceeded
    }
}

public struct KubeProxyStatus: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var nodeName: String
    public var controllerInstanceID: String
    public var updatedAt: String
    public var expiresAt: String
    public var stateSince: String
    public var lastSuccessAt: String?
    public var state: KubeProxyStatusState
    public var attemptedGeneration: Int
    public var lastAppliedGeneration: Int?
    public var pendingFamily: KubeProxyAddressFamily?
    public var consecutivePendingCycles: Int
    public var consecutiveSuccesses: Int
    public var consecutiveFailures: Int
    public var errorCode: String?
    public var errorMessage: String?
    public var ipv4: KubeProxyFamilyStatus
    public var ipv6: KubeProxyFamilyStatus
    public var pf: KubeProxyPFStatus

    public init(
        nodeName: String,
        controllerInstanceID: String,
        updatedAt: String,
        expiresAt: String,
        stateSince: String,
        lastSuccessAt: String?,
        state: KubeProxyStatusState,
        attemptedGeneration: Int,
        lastAppliedGeneration: Int? = nil,
        pendingFamily: KubeProxyAddressFamily? = nil,
        consecutivePendingCycles: Int = 0,
        consecutiveSuccesses: Int = 0,
        consecutiveFailures: Int = 0,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        ipv4: KubeProxyFamilyStatus,
        ipv6: KubeProxyFamilyStatus,
        pf: KubeProxyPFStatus,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.nodeName = nodeName
        self.controllerInstanceID = controllerInstanceID
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.stateSince = stateSince
        self.lastSuccessAt = lastSuccessAt
        self.state = state
        self.attemptedGeneration = attemptedGeneration
        self.lastAppliedGeneration = lastAppliedGeneration
        self.pendingFamily = pendingFamily
        self.consecutivePendingCycles = consecutivePendingCycles
        self.consecutiveSuccesses = consecutiveSuccesses
        self.consecutiveFailures = consecutiveFailures
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.pf = pf
    }

    public func freshness(at date: Date = Date()) throws -> KubeProxyStatusFreshness {
        _ = try validated()
        let timestamps = try parsedTimestamps()
        return date >= timestamps.updatedAt && date < timestamps.expiresAt ? .fresh : .expired
    }

    public func isFreshlyApplied(at date: Date = Date()) throws -> Bool {
        _ = try validated()
        let timestamps = try parsedTimestamps()
        return state == .applied
            && date >= timestamps.updatedAt
            && date < timestamps.expiresAt
    }

    fileprivate func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw KubeProxyStatusStoreError.persistence(
                "unsupported kube-proxy status schema version \(schemaVersion)"
            )
        }
        guard !nodeName.isEmpty,
            !nodeName.contains("/"),
            !nodeName.contains(where: \.isWhitespace)
        else {
            throw KubeProxyStatusStoreError.persistence("kube-proxy status contains an invalid node name")
        }
        guard UUID(uuidString: controllerInstanceID) != nil else {
            throw KubeProxyStatusStoreError.persistence("kube-proxy status contains an invalid controller instance ID")
        }
        guard attemptedGeneration >= 0,
            lastAppliedGeneration.map({ $0 >= 0 && $0 <= attemptedGeneration }) ?? true,
            consecutivePendingCycles >= 0,
            consecutiveSuccesses >= 0,
            consecutiveFailures >= 0,
            ipv4.desiredRuleCount.map({ $0 >= 0 }) ?? true,
            ipv4.appliedRuleCount.map({ $0 >= 0 }) ?? true,
            ipv6.desiredRuleCount.map({ $0 >= 0 }) ?? true,
            ipv6.appliedRuleCount.map({ $0 >= 0 }) ?? true
        else {
            throw KubeProxyStatusStoreError.persistence("kube-proxy status contains a negative counter")
        }
        _ = try parsedTimestamps()
        guard errorCode.map({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) ?? true,
            errorMessage.map({ $0.utf8.count <= maximumKubeProxyStatusErrorMessageSize }) ?? true
        else {
            throw KubeProxyStatusStoreError.persistence("kube-proxy status contains an invalid error")
        }
        switch state {
        case .starting:
            guard lastSuccessAt == nil,
                attemptedGeneration == 0,
                lastAppliedGeneration == nil,
                pendingFamily == nil,
                consecutivePendingCycles == 0,
                consecutiveSuccesses == 0,
                consecutiveFailures == 0,
                errorCode == nil,
                errorMessage == nil,
                ipv4.enabled,
                ipv4.applied == nil,
                ipv4.desiredRuleCount == nil,
                ipv4.appliedRuleCount == nil,
                ipv6.applied == nil,
                ipv6.desiredRuleCount == nil,
                ipv6.appliedRuleCount == nil,
                pf.finalState == .unknown,
                pf.applyAttempted == nil,
                pf.applySucceeded == nil,
                pf.withdrawalAttempted == nil,
                pf.withdrawalSucceeded == nil,
                pf.rollbackAttempted == nil,
                pf.rollbackSucceeded == nil
            else {
                throw KubeProxyStatusStoreError.persistence("starting kube-proxy status is inconsistent")
            }
        case .applied:
            guard lastSuccessAt != nil,
                attemptedGeneration > 0,
                pendingFamily == nil,
                consecutivePendingCycles == 0,
                consecutiveSuccesses > 0,
                consecutiveFailures == 0,
                lastAppliedGeneration == attemptedGeneration,
                errorCode == nil,
                errorMessage == nil,
                ipv4.enabled,
                ipv4.applied == true,
                ipv4.desiredRuleCount != nil,
                ipv4.desiredRuleCount == ipv4.appliedRuleCount,
                ipv6.applied == (ipv6.enabled ? true : false),
                ipv6.enabled
                    ? ipv6.desiredRuleCount != nil
                        && ipv6.desiredRuleCount == ipv6.appliedRuleCount
                    : ipv6.desiredRuleCount == 0 && ipv6.appliedRuleCount == 0,
                pf.finalState == .applied,
                pf.applyAttempted == true,
                pf.applySucceeded == true,
                pf.withdrawalAttempted == false,
                pf.withdrawalSucceeded == nil,
                pf.rollbackAttempted == false,
                pf.rollbackSucceeded == nil
            else {
                throw KubeProxyStatusStoreError.persistence("applied kube-proxy status is inconsistent")
            }
        case .waitingForPodIngressRoute:
            guard pendingFamily != nil,
                attemptedGeneration > 0,
                pendingFamily != .ipv6 || ipv6.enabled,
                consecutivePendingCycles > 0,
                consecutiveSuccesses == 0,
                consecutiveFailures == 0,
                errorCode == "podIngressRouteUnavailable",
                errorMessage != nil,
                ipv4.enabled,
                ipv4.applied == false,
                ipv4.desiredRuleCount != nil,
                ipv4.appliedRuleCount == 0,
                ipv6.applied == false,
                ipv6.desiredRuleCount != nil,
                ipv6.appliedRuleCount == 0,
                ipv6.enabled || ipv6.desiredRuleCount == 0,
                pf.finalState == .withdrawn,
                pf.applyAttempted == false,
                pf.applySucceeded == nil,
                pf.withdrawalAttempted == true,
                pf.withdrawalSucceeded == true,
                pf.rollbackAttempted == false,
                pf.rollbackSucceeded == nil
            else {
                throw KubeProxyStatusStoreError.persistence(
                    "waiting-for-Pod-ingress-route kube-proxy status is inconsistent"
                )
            }
        case .failed:
            guard pendingFamily == nil,
                consecutivePendingCycles == 0,
                consecutiveSuccesses == 0,
                consecutiveFailures > 0,
                errorCode != nil,
                errorMessage != nil,
                ipv4.enabled,
                ipv4.applied == nil,
                ipv4.desiredRuleCount == nil,
                ipv4.appliedRuleCount == nil,
                ipv6.applied == nil,
                ipv6.desiredRuleCount == nil,
                ipv6.appliedRuleCount == nil,
                pf.finalState == .unknown,
                pf.applyAttempted == nil,
                pf.applySucceeded == nil,
                pf.withdrawalAttempted == nil,
                pf.withdrawalSucceeded == nil,
                pf.rollbackAttempted == nil,
                pf.rollbackSucceeded == nil
            else {
                throw KubeProxyStatusStoreError.persistence("failed kube-proxy status is inconsistent")
            }
        }
        return self
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
            expiresAt.timeIntervalSince(updatedAt) <= maximumKubeProxyStatusFreshnessSeconds,
            lastSuccessAt.map({ $0 <= updatedAt }) ?? true
        else {
            throw KubeProxyStatusStoreError.persistence(
                "kube-proxy status timestamps are inconsistent"
            )
        }
        return ParsedTimestamps(
            updatedAt: updatedAt,
            expiresAt: expiresAt,
            stateSince: stateSince,
            lastSuccessAt: lastSuccessAt
        )
    }

    private static func parseTimestamp(_ timestamp: String, field: String) throws -> Date {
        let pattern =
            #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#
        guard timestamp.range(of: pattern, options: .regularExpression) != nil else {
            throw invalidTimestampError(field)
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
            throw invalidTimestampError(field)
        }
        return date
    }

    private static func invalidTimestampError(_ field: String) -> KubeProxyStatusStoreError {
        .persistence("kube-proxy status contains an invalid RFC3339 \(field) timestamp")
    }

    private struct ParsedTimestamps {
        var updatedAt: Date
        var expiresAt: Date
        var stateSince: Date
        var lastSuccessAt: Date?
    }
}

public enum KubeProxyStatusStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case persistence(String)

    public var description: String {
        switch self {
        case .persistence(let message):
            "kube-proxy status persistence failed: \(message)"
        }
    }
}

public protocol KubeProxyStatusStoring: Sendable {
    func load() throws -> KubeProxyStatus?
    func save(_ status: KubeProxyStatus) throws
    func remove() throws
}

public struct KubeProxyStatusFileStore: KubeProxyStatusStoring, Sendable {
    private static let maximumEncodedSize = 64 * 1024

    public let url: URL
    private let requiredOwnerID: uid_t

    public init(path: String, requiredOwnerID: uid_t = geteuid()) {
        self.url = URL(fileURLWithPath: path)
        self.requiredOwnerID = requiredOwnerID
    }

    public init(url: URL, requiredOwnerID: uid_t = geteuid()) {
        self.url = url
        self.requiredOwnerID = requiredOwnerID
    }

    public func load() throws -> KubeProxyStatus? {
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
        let size = try validateFileDescriptor(descriptor)
        let data = try readAll(from: descriptor, size: size)
        do {
            return try JSONDecoder().decode(KubeProxyStatus.self, from: data).validated()
        } catch let error as KubeProxyStatusStoreError {
            throw error
        } catch {
            throw KubeProxyStatusStoreError.persistence(
                "failed to decode status at \(url.path): \(error)"
            )
        }
    }

    public func save(_ status: KubeProxyStatus) throws {
        let status = try status.validated()
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(status)
        } catch let error as KubeProxyStatusStoreError {
            throw error
        } catch {
            throw KubeProxyStatusStoreError.persistence(
                "failed to encode status at \(url.path): \(error)"
            )
        }
        guard data.count <= Self.maximumEncodedSize else {
            throw KubeProxyStatusStoreError.persistence("status exceeds the size limit")
        }

        guard let directoryDescriptor = try openDirectory(createIfMissing: true) else {
            throw KubeProxyStatusStoreError.persistence(
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
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw persistenceError("failed to protect a temporary file for", errno: errno)
        }
        try validateNoExtendedACL(descriptor, object: "temporary status file")
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw persistenceError("failed to sync a temporary file for", errno: errno)
        }
        guard
            renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                url.lastPathComponent
            ) == 0
        else {
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
        let size = try validateFileDescriptor(descriptor)
        let data = try readAll(from: descriptor, size: size)
        do {
            _ = try JSONDecoder().decode(KubeProxyStatus.self, from: data).validated()
        } catch let error as KubeProxyStatusStoreError {
            throw error
        } catch {
            throw KubeProxyStatusStoreError.persistence(
                "refusing to remove invalid status at \(url.path): \(error)"
            )
        }
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
            throw KubeProxyStatusStoreError.persistence("status path has no file name")
        }
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755]
                )
            } catch {
                throw KubeProxyStatusStoreError.persistence(
                    "failed to create status directory at \(directoryURL.path): \(error)"
                )
            }
        }

        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT, !createIfMissing {
                return nil
            }
            throw KubeProxyStatusStoreError.persistence(
                "failed to open status directory at \(directoryURL.path): "
                    + Self.posixErrorDescription(errno)
            )
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            let errorNumber = errno
            close(descriptor)
            throw KubeProxyStatusStoreError.persistence(
                "failed to inspect open status directory at \(directoryURL.path): "
                    + Self.posixErrorDescription(errorNumber)
            )
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw KubeProxyStatusStoreError.persistence(
                "status directory at \(directoryURL.path) is not a directory"
            )
        }
        guard information.st_uid == requiredOwnerID else {
            close(descriptor)
            throw KubeProxyStatusStoreError.persistence(
                "status directory at \(directoryURL.path) has an unexpected owner"
            )
        }
        guard information.st_mode & mode_t(0o022) == 0 else {
            close(descriptor)
            throw KubeProxyStatusStoreError.persistence(
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
        let size = try validateFileDescriptor(descriptor)
        let data = try readAll(from: descriptor, size: size)
        do {
            _ = try JSONDecoder().decode(KubeProxyStatus.self, from: data).validated()
        } catch let error as KubeProxyStatusStoreError {
            throw error
        } catch {
            throw KubeProxyStatusStoreError.persistence(
                "refusing to replace invalid status at \(url.path): \(error)"
            )
        }
    }

    private func validateFileDescriptor(_ descriptor: Int32) throws -> Int {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw persistenceError("failed to inspect", errno: errno)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw KubeProxyStatusStoreError.persistence("status at \(url.path) is not a regular file")
        }
        guard information.st_uid == requiredOwnerID else {
            throw KubeProxyStatusStoreError.persistence(
                "status at \(url.path) has an unexpected owner"
            )
        }
        guard information.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw KubeProxyStatusStoreError.persistence("status at \(url.path) must have mode 0600")
        }
        try validateNoExtendedACL(descriptor, object: "status file")
        guard information.st_size >= 0,
            information.st_size <= off_t(Self.maximumEncodedSize)
        else {
            throw KubeProxyStatusStoreError.persistence("status at \(url.path) exceeds the size limit")
        }
        return Int(information.st_size)
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
        throw KubeProxyStatusStoreError.persistence(
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
                    throw KubeProxyStatusStoreError.persistence(
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
                    throw KubeProxyStatusStoreError.persistence("status write made no progress")
                }
                offset += count
            }
        }
    }

    private func persistenceError(_ operation: String, errno errorNumber: Int32) -> KubeProxyStatusStoreError {
        .persistence(
            "\(operation) status at \(url.path): "
                + Self.posixErrorDescription(errorNumber)
        )
    }

    private static func posixErrorDescription(_ errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
    }
}

public struct KubeProxyStatusRecorder: Sendable {
    private static let minimumFreshnessSeconds = 15

    private let store: any KubeProxyStatusStoring
    private let now: @Sendable () -> Date
    private let controllerInstanceID: String

    public init(
        store: any KubeProxyStatusStoring,
        controllerInstanceID: String = UUID().uuidString,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.controllerInstanceID = controllerInstanceID
        self.now = now
    }

    @discardableResult
    public func recordStarting(config: KubeProxyMacOSConfig) throws -> KubeProxyStatus {
        let now = now()
        let timestamp = Self.timestamp(now)
        let expiresAt = Self.expirationTimestamp(from: now, syncPeriodSeconds: config.syncPeriodSeconds)
        let status = KubeProxyStatus(
            nodeName: config.nodeName,
            controllerInstanceID: controllerInstanceID,
            updatedAt: timestamp,
            expiresAt: expiresAt,
            stateSince: timestamp,
            lastSuccessAt: nil,
            state: .starting,
            attemptedGeneration: 0,
            ipv4: KubeProxyFamilyStatus(
                enabled: true,
                applied: nil,
                desiredRuleCount: nil,
                appliedRuleCount: nil
            ),
            ipv6: KubeProxyFamilyStatus(
                enabled: config.dualStackEnabled,
                applied: nil,
                desiredRuleCount: nil,
                appliedRuleCount: nil
            ),
            pf: KubeProxyPFStatus(
                finalState: .unknown,
                applyAttempted: nil,
                applySucceeded: nil,
                withdrawalAttempted: nil,
                withdrawalSucceeded: nil,
                rollbackAttempted: nil,
                rollbackSucceeded: nil
            )
        )
        try store.save(status.validated())
        return status
    }

    @discardableResult
    public func record(
        result: KubeProxyRunResult,
        config: KubeProxyMacOSConfig
    ) throws -> KubeProxyStatus {
        guard result.applied || result.pendingFamily != nil else {
            throw KubeProxyStatusStoreError.persistence(
                "a non-applied reconcile result requires a pending address family"
            )
        }
        let previous = try previousStatus(for: config.nodeName)
        let now = now()
        let timestamp = Self.timestamp(now)
        let expiresAt = Self.expirationTimestamp(from: now, syncPeriodSeconds: config.syncPeriodSeconds)
        let state: KubeProxyStatusState = result.applied ? .applied : .waitingForPodIngressRoute
        let continuesCurrentState =
            previous?.state == state
            && (state != .waitingForPodIngressRoute || previous?.pendingFamily == result.pendingFamily)
        let stateSince = continuesCurrentState ? previous!.stateSince : timestamp
        let ipv4RuleCount = result.ruleSet.rules.count { $0.family == .ipv4 }
        let ipv6RuleCount = result.ruleSet.rules.count { $0.family == .ipv6 }
        let pendingCycles =
            state == .waitingForPodIngressRoute
            ? (continuesCurrentState ? (previous?.consecutivePendingCycles ?? 0) + 1 : 1)
            : 0
        let consecutiveSuccesses =
            state == .applied
            ? (continuesCurrentState ? (previous?.consecutiveSuccesses ?? 0) + 1 : 1)
            : 0
        let status = KubeProxyStatus(
            nodeName: config.nodeName,
            controllerInstanceID: controllerInstanceID,
            updatedAt: timestamp,
            expiresAt: expiresAt,
            stateSince: stateSince,
            lastSuccessAt: result.applied ? timestamp : previous?.lastSuccessAt,
            state: state,
            attemptedGeneration: result.ruleSet.generation,
            lastAppliedGeneration: result.applied
                ? result.ruleSet.generation
                : previous?.lastAppliedGeneration,
            pendingFamily: result.pendingFamily,
            consecutivePendingCycles: pendingCycles,
            consecutiveSuccesses: consecutiveSuccesses,
            errorCode: result.applied ? nil : "podIngressRouteUnavailable",
            errorMessage: result.pendingFamily.map {
                "local \($0.rawValue) PodCIDR route is unavailable; managed PF rules are withdrawn"
            },
            ipv4: KubeProxyFamilyStatus(
                enabled: true,
                applied: result.applied,
                desiredRuleCount: ipv4RuleCount,
                appliedRuleCount: result.applied ? ipv4RuleCount : 0
            ),
            ipv6: KubeProxyFamilyStatus(
                enabled: config.dualStackEnabled,
                applied: result.applied && config.dualStackEnabled,
                desiredRuleCount: ipv6RuleCount,
                appliedRuleCount: result.applied && config.dualStackEnabled ? ipv6RuleCount : 0
            ),
            pf: KubeProxyPFStatus(
                finalState: result.applied ? .applied : .withdrawn,
                applyAttempted: result.applied,
                applySucceeded: result.applied ? true : nil,
                withdrawalAttempted: !result.applied,
                withdrawalSucceeded: result.applied ? nil : true,
                rollbackAttempted: false,
                rollbackSucceeded: nil
            )
        )
        try store.save(status.validated())
        return status
    }

    @discardableResult
    public func recordFailure(
        error: Error,
        generation: Int,
        config: KubeProxyMacOSConfig
    ) throws -> KubeProxyStatus {
        let previous = try previousStatus(for: config.nodeName)
        let now = now()
        let timestamp = Self.timestamp(now)
        let expiresAt = Self.expirationTimestamp(from: now, syncPeriodSeconds: config.syncPeriodSeconds)
        let code = Self.errorCode(error)
        let sameFailure = previous?.state == .failed && previous?.errorCode == code
        let status = KubeProxyStatus(
            nodeName: config.nodeName,
            controllerInstanceID: controllerInstanceID,
            updatedAt: timestamp,
            expiresAt: expiresAt,
            stateSince: sameFailure ? previous!.stateSince : timestamp,
            lastSuccessAt: previous?.lastSuccessAt,
            state: .failed,
            attemptedGeneration: generation,
            lastAppliedGeneration: previous?.lastAppliedGeneration,
            consecutiveFailures: sameFailure ? (previous?.consecutiveFailures ?? 0) + 1 : 1,
            errorCode: code,
            errorMessage: Self.truncatedErrorMessage(String(describing: error)),
            ipv4: KubeProxyFamilyStatus(
                enabled: true,
                applied: nil,
                desiredRuleCount: nil,
                appliedRuleCount: nil
            ),
            ipv6: KubeProxyFamilyStatus(
                enabled: config.dualStackEnabled,
                applied: nil,
                desiredRuleCount: nil,
                appliedRuleCount: nil
            ),
            pf: KubeProxyPFStatus(
                finalState: .unknown,
                applyAttempted: nil,
                applySucceeded: nil,
                withdrawalAttempted: nil,
                withdrawalSucceeded: nil,
                rollbackAttempted: nil,
                rollbackSucceeded: nil
            )
        )
        try store.save(status.validated())
        return status
    }

    public func remove() throws {
        try store.remove()
    }

    private func previousStatus(for nodeName: String) throws -> KubeProxyStatus? {
        guard let previous = try store.load(),
            previous.nodeName == nodeName,
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
        let maximumPeriodSeconds = Int(maximumKubeProxyStatusFreshnessSeconds) / 3
        let boundedPeriodSeconds = max(0, min(syncPeriodSeconds, maximumPeriodSeconds))
        let freshnessSeconds = max(boundedPeriodSeconds * 3, minimumFreshnessSeconds)
        return timestamp(updatedAt.addingTimeInterval(TimeInterval(freshnessSeconds)))
    }

    private static func errorCode(_ error: Error) -> String {
        if let routeError = error as? KubeProxyPodIngressRouteTransitionError {
            switch routeError {
            case .unavailable:
                return "applyFailed"
            case .unavailableAfterWithdrawal:
                return "podIngressRouteUnavailable"
            }
        }
        guard let error = error as? KubeProxyMacOSError else {
            return "unexpected"
        }
        switch error {
        case .invalidConfiguration:
            return "invalidConfiguration"
        case .invalidKubeconfig:
            return "invalidKubeconfig"
        case .unsupported:
            return "unsupported"
        case .applyFailed:
            return "applyFailed"
        }
    }

    private static func truncatedErrorMessage(_ message: String) -> String {
        guard message.utf8.count > maximumKubeProxyStatusErrorMessageSize else {
            return message
        }
        var result = ""
        var encodedSize = 0
        for scalar in message.unicodeScalars {
            let scalarSize = scalar.utf8.count
            guard encodedSize + scalarSize <= maximumKubeProxyStatusErrorMessageSize else {
                break
            }
            result.unicodeScalars.append(scalar)
            encodedSize += scalarSize
        }
        return result
    }
}
