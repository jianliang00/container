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

public struct FlannelStateManifestIdentity: Codable, Sendable, Equatable {
    public var nodeName: String
    public var networkName: String
    public var networkPlugin: String
    public var networkVariant: String
    public var annotationPrefix: String

    public init(
        nodeName: String,
        networkName: String,
        networkPlugin: String,
        networkVariant: String,
        annotationPrefix: String
    ) {
        self.nodeName = nodeName
        self.networkName = networkName
        self.networkPlugin = networkPlugin
        self.networkVariant = networkVariant
        self.annotationPrefix = annotationPrefix
    }
}

public struct FlannelManagedStatePaths: Codable, Sendable, Equatable {
    public var dataplaneOwnership: String
    public var networkOwnership: String
    public var hostIPv6GatewayOwnership: String
    public var forwardingOwnership: String
    public var ready: String

    public init(
        dataplaneOwnership: String,
        networkOwnership: String,
        hostIPv6GatewayOwnership: String,
        forwardingOwnership: String,
        ready: String
    ) {
        self.dataplaneOwnership = dataplaneOwnership
        self.networkOwnership = networkOwnership
        self.hostIPv6GatewayOwnership = hostIPv6GatewayOwnership
        self.forwardingOwnership = forwardingOwnership
        self.ready = ready
    }

    public var all: [String] {
        [
            dataplaneOwnership,
            networkOwnership,
            hostIPv6GatewayOwnership,
            forwardingOwnership,
            ready,
        ]
    }
}

public struct FlannelStateManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maximumEncodedSize = 16 * 1024

    public var schemaVersion: Int
    public var configPath: String
    public var identity: FlannelStateManifestIdentity
    public var statePaths: FlannelManagedStatePaths

    public init(
        schemaVersion: Int = FlannelStateManifest.currentSchemaVersion,
        configPath: String,
        identity: FlannelStateManifestIdentity,
        statePaths: FlannelManagedStatePaths
    ) {
        self.schemaVersion = schemaVersion
        self.configPath = configPath
        self.identity = identity
        self.statePaths = statePaths
    }

    public init(configPath: String, config: FlannelVXLANMacOSConfig) throws {
        try config.validateConfigurationFilePath(configPath)
        self.init(
            configPath: FlannelVXLANMacOSConfig.canonicalFilePath(configPath),
            identity: FlannelStateManifestIdentity(
                nodeName: config.nodeName,
                networkName: config.networkName,
                networkPlugin: config.networkPlugin,
                networkVariant: config.networkVariant,
                annotationPrefix: config.annotationPrefix
            ),
            statePaths: config.managedStatePaths
        )
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FlannelVXLANError.persistence(
                "unsupported Flannel state manifest schema version \(schemaVersion)"
            )
        }
        guard configPath.hasPrefix("/") else {
            throw FlannelVXLANError.persistence("Flannel state manifest configPath must be absolute")
        }
        for (name, value) in [
            ("nodeName", identity.nodeName),
            ("networkName", identity.networkName),
            ("networkPlugin", identity.networkPlugin),
            ("networkVariant", identity.networkVariant),
            ("annotationPrefix", identity.annotationPrefix),
        ] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FlannelVXLANError.persistence(
                    "Flannel state manifest \(name) must not be empty"
                )
            }
        }
        var canonicalPaths: [String] = []
        for path in statePaths.all {
            guard path.hasPrefix("/") else {
                throw FlannelVXLANError.persistence(
                    "Flannel state manifest contains a non-absolute state path"
                )
            }
            let canonicalPath = FlannelVXLANMacOSConfig.canonicalFilePath(path)
            for existingPath in canonicalPaths
            where FlannelVXLANMacOSConfig.filePathsOverlap(
                canonicalPath,
                existingPath
            ) {
                throw FlannelVXLANError.persistence(
                    "Flannel state manifest contains overlapping state paths"
                )
            }
            guard
                !FlannelVXLANMacOSConfig.filePathsOverlap(
                    canonicalPath,
                    FlannelVXLANMacOSConfig.defaultStateManifestPath
                )
            else {
                throw FlannelVXLANError.persistence(
                    "Flannel state manifest cannot track its own file"
                )
            }
            guard !FlannelVXLANMacOSConfig.filePathsOverlap(canonicalPath, configPath) else {
                throw FlannelVXLANError.persistence(
                    "Flannel state manifest configPath overlaps managed state"
                )
            }
            canonicalPaths.append(canonicalPath)
        }
    }
}

public protocol FlannelStateManifestStoring: Sendable {
    func load() throws -> FlannelStateManifest?
    func save(_ manifest: FlannelStateManifest) throws
    func remove() throws
}

public struct FlannelStateManifestStore: FlannelStateManifestStoring, Sendable {
    public let url: URL
    private let requiredOwnerID: uid_t

    public init(
        path: String = FlannelVXLANMacOSConfig.defaultStateManifestPath,
        requiredOwnerID: uid_t = 0
    ) {
        self.url = URL(fileURLWithPath: path)
        self.requiredOwnerID = requiredOwnerID
    }

    public init(url: URL, requiredOwnerID: uid_t = 0) {
        self.url = url
        self.requiredOwnerID = requiredOwnerID
    }

    public func load() throws -> FlannelStateManifest? {
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
            guard data.count <= FlannelStateManifest.maximumEncodedSize else {
                throw FlannelVXLANError.persistence(
                    "Flannel state manifest at \(url.path) exceeds the size limit"
                )
            }
            let manifest = try JSONDecoder().decode(FlannelStateManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence(
                "failed to read Flannel state manifest at \(url.path): \(error)"
            )
        }
    }

    public func save(_ manifest: FlannelStateManifest) throws {
        try manifest.validate()
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(manifest)
        } catch {
            throw FlannelVXLANError.persistence("failed to encode Flannel state manifest: \(error)")
        }
        guard data.count <= FlannelStateManifest.maximumEncodedSize else {
            throw FlannelVXLANError.persistence("Flannel state manifest exceeds the size limit")
        }

        guard let directoryDescriptor = try openDirectory(createIfMissing: true) else {
            throw FlannelVXLANError.persistence(
                "failed to create Flannel state manifest directory at \(url.deletingLastPathComponent().path)"
            )
        }
        defer { close(directoryDescriptor) }
        try validateExistingManifest(in: directoryDescriptor)

        let temporaryName = ".state-manifest-\(UUID().uuidString).tmp"
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
                    "failed to create Flannel state manifest directory at \(directoryURL.path): \(error)"
                )
            }
        }

        var information = stat()
        guard lstat(directoryURL.path, &information) == 0 else {
            if errno == ENOENT, !createIfMissing {
                return nil
            }
            throw FlannelVXLANError.persistence(
                "failed to inspect Flannel state manifest directory at \(directoryURL.path): "
                    + Self.posixErrorDescription(errno)
            )
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw FlannelVXLANError.persistence(
                "Flannel state manifest directory at \(directoryURL.path) is not a directory"
            )
        }
        guard information.st_uid == requiredOwnerID else {
            throw FlannelVXLANError.persistence(
                "Flannel state manifest directory at \(directoryURL.path) has an unexpected owner"
            )
        }
        guard information.st_mode & mode_t(0o022) == 0 else {
            throw FlannelVXLANError.persistence(
                "Flannel state manifest directory at \(directoryURL.path) is group or world writable"
            )
        }

        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FlannelVXLANError.persistence(
                "failed to open Flannel state manifest directory at \(directoryURL.path): "
                    + Self.posixErrorDescription(errno)
            )
        }
        return descriptor
    }

    private func validateExistingManifest(in directoryDescriptor: Int32) throws {
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
                "Flannel state manifest at \(url.path) is not a regular file"
            )
        }
        guard information.st_uid == requiredOwnerID else {
            throw FlannelVXLANError.persistence(
                "Flannel state manifest at \(url.path) has an unexpected owner"
            )
        }
        guard information.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw FlannelVXLANError.persistence(
                "Flannel state manifest at \(url.path) must have mode 0600"
            )
        }
        guard information.st_size >= 0,
            information.st_size <= off_t(FlannelStateManifest.maximumEncodedSize)
        else {
            throw FlannelVXLANError.persistence(
                "Flannel state manifest at \(url.path) exceeds the size limit"
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
                        "failed to write Flannel state manifest: write made no progress"
                    )
                }
                offset += count
            }
        }
    }

    private func persistenceError(_ operation: String, errno errorNumber: Int32) -> FlannelVXLANError {
        .persistence(
            "\(operation) Flannel state manifest at \(url.path): "
                + Self.posixErrorDescription(errorNumber)
        )
    }

    private static func posixErrorDescription(_ errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
    }
}

public enum FlannelMissingConfigurationState: Sendable, Equatable {
    case noManifest
    case noManagedState(expectedConfigPath: String)
    case managedStateRemains(expectedConfigPath: String, paths: [String])
}

public struct FlannelStateManifestCoordinator: Sendable {
    private let store: any FlannelStateManifestStoring

    public init(
        store: any FlannelStateManifestStoring = FlannelStateManifestStore()
    ) {
        self.store = store
    }

    @discardableResult
    public func claim(
        configPath: String,
        config: FlannelVXLANMacOSConfig,
        whileHolding lifetimeLock: FlannelDaemonLifetimeLock
    ) throws -> FlannelStateManifest {
        try lifetimeLock.requireHeld()
        let candidate = try FlannelStateManifest(configPath: configPath, config: config)
        guard let existing = try store.load() else {
            try store.save(candidate)
            return candidate
        }
        guard existing != candidate else {
            return existing
        }

        let remainingPaths = try (existing.statePaths.all + candidate.statePaths.all)
            .uniqued()
            .filter(Self.statePathExists)
        guard remainingPaths.isEmpty else {
            throw FlannelVXLANError.invalidConfiguration(
                "Flannel state manifest does not match the requested configuration while managed state remains at "
                    + remainingPaths.sorted().joined(separator: ", ")
            )
        }
        try store.save(candidate)
        return candidate
    }

    public func validateClaim(
        configPath: String,
        config: FlannelVXLANMacOSConfig,
        whileHolding lifetimeLock: FlannelDaemonLifetimeLock
    ) throws {
        try lifetimeLock.requireHeld()
        let candidate = try FlannelStateManifest(configPath: configPath, config: config)
        guard let existing = try store.load(), existing != candidate else {
            return
        }
        let remainingPaths = try (existing.statePaths.all + candidate.statePaths.all)
            .uniqued()
            .filter(Self.statePathExists)
        guard remainingPaths.isEmpty else {
            throw FlannelVXLANError.invalidConfiguration(
                "Flannel state manifest does not match the requested configuration while managed state remains at "
                    + remainingPaths.sorted().joined(separator: ", ")
            )
        }
    }

    @discardableResult
    public func requireExactClaim(
        configPath: String,
        config: FlannelVXLANMacOSConfig,
        whileHolding lifetimeLock: FlannelDaemonLifetimeLock
    ) throws -> FlannelStateManifest {
        try lifetimeLock.requireHeld()
        let candidate = try FlannelStateManifest(configPath: configPath, config: config)
        guard let existing = try store.load() else {
            throw FlannelVXLANError.invalidConfiguration(
                "Flannel state manifest is missing for the active configuration"
            )
        }
        guard existing == candidate else {
            throw FlannelVXLANError.invalidConfiguration(
                "Flannel state manifest does not match the active configuration"
            )
        }
        return candidate
    }

    public func discoverMissingConfiguration(
        requestedConfigPath: String,
        whileHolding lifetimeLock: FlannelDaemonLifetimeLock
    ) throws -> FlannelMissingConfigurationState {
        try lifetimeLock.requireHeld()
        guard let manifest = try store.load() else {
            return .noManifest
        }
        let requestedPath = FlannelVXLANMacOSConfig.canonicalFilePath(requestedConfigPath)
        guard requestedPath == manifest.configPath else {
            throw FlannelVXLANError.invalidConfiguration(
                "requested cleanup configuration \(requestedPath) does not match Flannel state manifest configuration "
                    + manifest.configPath
            )
        }
        let remainingPaths = try manifest.statePaths.all.filter(Self.statePathExists).sorted()
        guard remainingPaths.isEmpty else {
            return .managedStateRemains(
                expectedConfigPath: manifest.configPath,
                paths: remainingPaths
            )
        }
        return .noManagedState(expectedConfigPath: manifest.configPath)
    }

    @discardableResult
    public func removeIfUnowned(
        whileHolding lifetimeLock: FlannelDaemonLifetimeLock
    ) throws -> Bool {
        try lifetimeLock.requireHeld()
        guard let manifest = try store.load() else {
            return false
        }
        guard try manifest.statePaths.all.allSatisfy({ try !Self.statePathExists($0) }) else {
            return false
        }
        try store.remove()
        return true
    }

    private static func statePathExists(_ path: String) throws -> Bool {
        var information = stat()
        guard lstat(path, &information) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw FlannelVXLANError.persistence(
                "failed to inspect managed Flannel state at \(path): "
                    + String(cString: strerror(errno))
            )
        }
        return true
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
