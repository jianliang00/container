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

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum FlannelForwardingFamily: String, Codable, CaseIterable, Sendable, Comparable {
    case ipv4
    case ipv6

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    fileprivate var sysctlName: String {
        switch self {
        case .ipv4:
            "net.inet.ip.forwarding"
        case .ipv6:
            "net.inet6.ip6.forwarding"
        }
    }
}

public enum FlannelForwardingOwnershipPhase: String, Codable, Sendable, Equatable {
    case enabling
    case owned
    case restoring
}

public struct FlannelForwardingFamilyOwnership: Codable, Sendable, Equatable {
    public var originalEnabled: Bool
    public var phase: FlannelForwardingOwnershipPhase

    public init(
        originalEnabled: Bool,
        phase: FlannelForwardingOwnershipPhase
    ) {
        self.originalEnabled = originalEnabled
        self.phase = phase
    }
}

public struct FlannelForwardingOwnership: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    fileprivate static let maximumEncodedSize = 64 * 1024

    public var schemaVersion: Int
    public var bootSessionID: String
    public var ipv4: FlannelForwardingFamilyOwnership?
    public var ipv6: FlannelForwardingFamilyOwnership?

    public init(
        bootSessionID: String,
        ipv4: FlannelForwardingFamilyOwnership? = nil,
        ipv6: FlannelForwardingFamilyOwnership? = nil,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.bootSessionID = bootSessionID
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    public var families: Set<FlannelForwardingFamily> {
        var result: Set<FlannelForwardingFamily> = []
        if ipv4 != nil {
            result.insert(.ipv4)
        }
        if ipv6 != nil {
            result.insert(.ipv6)
        }
        return result
    }

    fileprivate var isEmpty: Bool {
        ipv4 == nil && ipv6 == nil
    }

    fileprivate func entry(for family: FlannelForwardingFamily) -> FlannelForwardingFamilyOwnership? {
        switch family {
        case .ipv4:
            ipv4
        case .ipv6:
            ipv6
        }
    }

    fileprivate mutating func set(
        _ entry: FlannelForwardingFamilyOwnership?,
        for family: FlannelForwardingFamily
    ) {
        switch family {
        case .ipv4:
            ipv4 = entry
        case .ipv6:
            ipv6 = entry
        }
    }

    fileprivate func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FlannelVXLANError.persistence(
                "unsupported forwarding ownership schema version \(schemaVersion)"
            )
        }
        guard !bootSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlannelVXLANError.persistence("forwarding ownership boot session is empty")
        }
        guard !isEmpty else {
            throw FlannelVXLANError.persistence("forwarding ownership contains no families")
        }
        return self
    }
}

public protocol FlannelForwardingOwnershipStoring: Sendable {
    func load() throws -> FlannelForwardingOwnership?
    func save(_ ownership: FlannelForwardingOwnership) throws
    func remove() throws
}

public struct FlannelForwardingOwnershipStore: FlannelForwardingOwnershipStoring, Sendable {
    public let url: URL
    private let requiredOwnerID: uid_t

    public init(path: String, requiredOwnerID: uid_t = 0) {
        self.url = URL(fileURLWithPath: path)
        self.requiredOwnerID = requiredOwnerID
    }

    public init(url: URL, requiredOwnerID: uid_t = 0) {
        self.url = url
        self.requiredOwnerID = requiredOwnerID
    }

    public func load() throws -> FlannelForwardingOwnership? {
        guard let directoryDescriptor = try openDirectory(createIfMissing: false) else {
            return nil
        }
        defer { close(directoryDescriptor) }

        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw persistenceError("failed to open", errno: errno)
        }
        defer { close(descriptor) }
        try validateFileDescriptor(descriptor)
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            guard data.count <= FlannelForwardingOwnership.maximumEncodedSize else {
                throw FlannelVXLANError.persistence(
                    "forwarding ownership at \(url.path) exceeds the size limit"
                )
            }
            let value = try JSONDecoder().decode(
                FlannelForwardingOwnership.self,
                from: data
            )
            return try value.validated()
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence(
                "failed to read forwarding ownership at \(url.path): \(error)"
            )
        }
    }

    public func save(_ ownership: FlannelForwardingOwnership) throws {
        let ownership = try ownership.validated()
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(ownership)
            guard data.count <= FlannelForwardingOwnership.maximumEncodedSize else {
                throw FlannelVXLANError.persistence("forwarding ownership exceeds the size limit")
            }
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence(
                "failed to write forwarding ownership at \(url.path): \(error)"
            )
        }

        guard let directoryDescriptor = try openDirectory(createIfMissing: true) else {
            throw FlannelVXLANError.persistence(
                "failed to create forwarding ownership directory at \(url.deletingLastPathComponent().path)"
            )
        }
        defer { close(directoryDescriptor) }
        try validateExistingOwnership(in: directoryDescriptor)

        let temporaryName = ".forwarding-ownership-\(UUID().uuidString).tmp"
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
        do {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw persistenceError("failed to protect a temporary file for", errno: errno)
            }
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
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence(
                "failed to write forwarding ownership at \(url.path): \(error)"
            )
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
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw persistenceError("failed to open before removing", errno: errno)
        }
        do {
            try validateFileDescriptor(descriptor)
        } catch {
            close(descriptor)
            throw error
        }
        close(descriptor)
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
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755]
                )
            } catch {
                throw FlannelVXLANError.persistence(
                    "failed to create forwarding ownership directory at \(directoryURL.path): \(error)"
                )
            }
        }

        var information = stat()
        guard lstat(directoryURL.path, &information) == 0 else {
            if errno == ENOENT, !createIfMissing {
                return nil
            }
            throw FlannelVXLANError.persistence(
                "failed to inspect forwarding ownership directory at \(directoryURL.path): "
                    + Self.posixErrorDescription(errno)
            )
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw FlannelVXLANError.persistence(
                "forwarding ownership directory at \(directoryURL.path) is not a directory"
            )
        }
        guard information.st_uid == requiredOwnerID else {
            throw FlannelVXLANError.persistence(
                "forwarding ownership directory at \(directoryURL.path) has an unexpected owner"
            )
        }
        guard information.st_mode & mode_t(0o022) == 0 else {
            throw FlannelVXLANError.persistence(
                "forwarding ownership directory at \(directoryURL.path) is group or world writable"
            )
        }

        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FlannelVXLANError.persistence(
                "failed to open forwarding ownership directory at \(directoryURL.path): "
                    + Self.posixErrorDescription(errno)
            )
        }
        return descriptor
    }

    private func validateExistingOwnership(in directoryDescriptor: Int32) throws {
        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw persistenceError("failed to inspect before replacing", errno: errno)
        }
        defer { close(descriptor) }
        try validateFileDescriptor(descriptor)
    }

    private func validateFileDescriptor(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw persistenceError("failed to inspect", errno: errno)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw FlannelVXLANError.persistence(
                "forwarding ownership at \(url.path) is not a regular file"
            )
        }
        guard information.st_uid == requiredOwnerID else {
            throw FlannelVXLANError.persistence(
                "forwarding ownership at \(url.path) has an unexpected owner"
            )
        }
        guard information.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw FlannelVXLANError.persistence(
                "forwarding ownership at \(url.path) must have mode 0600"
            )
        }
        guard information.st_size >= 0,
            information.st_size <= off_t(FlannelForwardingOwnership.maximumEncodedSize)
        else {
            throw FlannelVXLANError.persistence(
                "forwarding ownership at \(url.path) exceeds the size limit"
            )
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(
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
                    throw FlannelVXLANError.persistence(
                        "failed to write forwarding ownership: write made no progress"
                    )
                }
                offset += count
            }
        }
    }

    private func persistenceError(_ operation: String, errno errorNumber: Int32) -> FlannelVXLANError {
        .persistence(
            "\(operation) forwarding ownership at \(url.path): "
                + Self.posixErrorDescription(errorNumber)
        )
    }

    private static func posixErrorDescription(_ errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
    }
}

public protocol FlannelForwardingManaging: Sendable {
    func ensureEnabled(_ family: FlannelForwardingFamily) throws
    @discardableResult func restore(_ family: FlannelForwardingFamily) throws -> Bool
    func restoreAll() throws -> [FlannelForwardingFamily]
    func ownedFamilies() throws -> Set<FlannelForwardingFamily>
}

public struct SystemFlannelForwardingManager: FlannelForwardingManaging, Sendable {
    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> String
    typealias BootSessionProvider = @Sendable () throws -> String

    private static let processMutationLock = NSLock()
    private let ownershipStore: any FlannelForwardingOwnershipStoring
    private let advisoryLockPath: String
    private let bootSessionProvider: BootSessionProvider
    private let commandRunner: CommandRunner

    public init(ownershipStore: any FlannelForwardingOwnershipStoring) {
        self.ownershipStore = ownershipStore
        self.advisoryLockPath = FlannelVXLANMacOSConfig.defaultForwardingAdvisoryLockPath
        self.bootSessionProvider = Self.currentBootSessionID
        self.commandRunner = Self.runProcess
    }

    init(
        ownershipStore: any FlannelForwardingOwnershipStoring,
        advisoryLockPath: String? = nil,
        bootSessionProvider: @escaping BootSessionProvider = Self.currentBootSessionID,
        commandRunner: @escaping CommandRunner
    ) {
        self.ownershipStore = ownershipStore
        self.advisoryLockPath =
            advisoryLockPath
            ?? (ownershipStore as? FlannelForwardingOwnershipStore)?.url
            .deletingLastPathComponent()
            .appendingPathComponent("forwarding.lock")
            .path
            ?? FlannelVXLANMacOSConfig.defaultForwardingAdvisoryLockPath
        self.bootSessionProvider = bootSessionProvider
        self.commandRunner = commandRunner
    }

    public func ensureEnabled(_ family: FlannelForwardingFamily) throws {
        try withMutationLock {
            try ensureEnabledLocked(family)
        }
    }

    private func ensureEnabledLocked(_ family: FlannelForwardingFamily) throws {
        let bootSessionID = try normalizedBootSessionID()
        var ownership: FlannelForwardingOwnership
        if let persistedOwnership = try ownershipStore.load(),
            let currentOwnership = try currentBootOwnership(
                persistedOwnership,
                for: bootSessionID
            )
        {
            ownership = currentOwnership
        } else {
            ownership = FlannelForwardingOwnership(bootSessionID: bootSessionID)
        }
        var entry: FlannelForwardingFamilyOwnership
        if let persisted = ownership.entry(for: family) {
            entry = persisted
        } else {
            let originalEnabled = try read(family)
            entry = FlannelForwardingFamilyOwnership(
                originalEnabled: originalEnabled,
                phase: originalEnabled ? .owned : .enabling
            )
            ownership.set(entry, for: family)
            try persist(ownership)
        }

        let currentEnabled = try read(family)
        if currentEnabled {
            if entry.phase != .owned {
                entry.phase = .owned
                ownership.set(entry, for: family)
                try persist(ownership)
            }
            return
        }

        if entry.phase != .enabling {
            entry.phase = .enabling
            ownership.set(entry, for: family)
            try persist(ownership)
        }
        try writeAndVerify(true, family: family, operation: "enable")
        entry.phase = .owned
        ownership.set(entry, for: family)
        try persist(ownership)
    }

    @discardableResult
    public func restore(_ family: FlannelForwardingFamily) throws -> Bool {
        try withMutationLock {
            try restoreLocked(family)
        }
    }

    private func restoreLocked(_ family: FlannelForwardingFamily) throws -> Bool {
        guard let persistedOwnership = try ownershipStore.load() else {
            return false
        }
        let bootSessionID = try normalizedBootSessionID()
        guard
            var ownership = try currentBootOwnership(
                persistedOwnership,
                for: bootSessionID
            )
        else {
            return false
        }
        guard var entry = ownership.entry(for: family) else {
            return false
        }
        if entry.phase != .restoring {
            entry.phase = .restoring
            ownership.set(entry, for: family)
            try persist(ownership)
        }

        let currentEnabled = try read(family)
        if currentEnabled != entry.originalEnabled {
            try writeAndVerify(entry.originalEnabled, family: family, operation: "restore")
        }
        guard try read(family) == entry.originalEnabled else {
            throw FlannelVXLANError.runtime(
                "restore \(family.rawValue) forwarding did not reach the recorded original value"
            )
        }

        ownership.set(nil, for: family)
        try persist(ownership)
        return true
    }

    public func restoreAll() throws -> [FlannelForwardingFamily] {
        try withMutationLock {
            var restored: [FlannelForwardingFamily] = []
            var failures: [String] = []
            for family in FlannelForwardingFamily.allCases {
                do {
                    if try restoreLocked(family) {
                        restored.append(family)
                    }
                } catch {
                    failures.append("\(family.rawValue): \(error)")
                }
            }
            guard failures.isEmpty else {
                throw FlannelVXLANError.runtime(
                    "forwarding restoration incomplete: " + failures.joined(separator: "; ")
                )
            }
            return restored.sorted()
        }
    }

    public func ownedFamilies() throws -> Set<FlannelForwardingFamily> {
        try withMutationLock {
            guard let persistedOwnership = try ownershipStore.load() else {
                return []
            }
            guard
                let ownership = try currentBootOwnership(
                    persistedOwnership,
                    for: normalizedBootSessionID()
                )
            else {
                return []
            }
            return ownership.families
        }
    }

    private func currentBootOwnership(
        _ persistedOwnership: FlannelForwardingOwnership,
        for bootSessionID: String
    ) throws -> FlannelForwardingOwnership? {
        guard persistedOwnership.bootSessionID == bootSessionID else {
            // A boot-scoped claim cannot authorize sysctl mutation after a reboot.
            try ownershipStore.remove()
            return nil
        }
        return persistedOwnership
    }

    private func normalizedBootSessionID() throws -> String {
        let value = try bootSessionProvider()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else {
            throw FlannelVXLANError.runtime("host boot session identifier is empty")
        }
        return value
    }

    private func read(_ family: FlannelForwardingFamily) throws -> Bool {
        let value = try commandRunner("/usr/sbin/sysctl", ["-n", family.sysctlName])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "0":
            return false
        case "1":
            return true
        default:
            throw FlannelVXLANError.runtime(
                "\(family.sysctlName) returned unexpected value \(String(reflecting: value))"
            )
        }
    }

    private func writeAndVerify(
        _ enabled: Bool,
        family: FlannelForwardingFamily,
        operation: String
    ) throws {
        let target = enabled ? "1" : "0"
        do {
            _ = try commandRunner("/usr/sbin/sysctl", ["-w", "\(family.sysctlName)=\(target)"])
        } catch {
            let writeError = error
            do {
                guard try read(family) == enabled else {
                    throw FlannelVXLANError.runtime("readback does not match \(target)")
                }
            } catch {
                throw FlannelVXLANError.runtime(
                    "\(operation) \(family.rawValue) forwarding failed: \(writeError); readback failed: \(error)"
                )
            }
            return
        }
        guard try read(family) == enabled else {
            throw FlannelVXLANError.runtime(
                "\(operation) \(family.rawValue) forwarding did not reach value \(target)"
            )
        }
    }

    private func persist(_ ownership: FlannelForwardingOwnership) throws {
        if ownership.isEmpty {
            try ownershipStore.remove()
        } else {
            try ownershipStore.save(ownership)
        }
    }

    private func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }

        let lockURL = URL(fileURLWithPath: advisoryLockPath)
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw FlannelVXLANError.persistence(
                "failed to create forwarding lock directory: \(error)"
            )
        }

        let descriptor = open(advisoryLockPath, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw FlannelVXLANError.persistence(
                "failed to open forwarding advisory lock at \(advisoryLockPath): \(Self.posixErrorDescription())"
            )
        }
        defer { close(descriptor) }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw FlannelVXLANError.persistence(
                "failed to secure forwarding advisory lock at \(advisoryLockPath): \(Self.posixErrorDescription())"
            )
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw FlannelVXLANError.persistence(
                "failed to configure forwarding advisory lock at \(advisoryLockPath): \(Self.posixErrorDescription())"
            )
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw FlannelVXLANError.persistence(
                    "failed to acquire forwarding advisory lock at \(advisoryLockPath): \(Self.posixErrorDescription())"
                )
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }

    private static func currentBootSessionID() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            throw FlannelVXLANError.runtime("failed to query kern.bootsessionuuid")
        }

        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            throw FlannelVXLANError.runtime("failed to read kern.bootsessionuuid")
        }
        let value = String(
            decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlannelVXLANError.runtime("kern.bootsessionuuid returned an empty value")
        }
        return value
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw FlannelVXLANError.runtime("failed to run \(executable): \(error)")
        }
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FlannelVXLANError.runtime(
                "\(executable) \(arguments.joined(separator: " ")) failed with status "
                    + "\(process.terminationStatus): \(message)"
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
