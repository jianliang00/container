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

import ContainerResource
import Foundation
import RuntimeMacOSSidecarShared

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Normalizes absolute paths without consulting the filesystem. Foundation's
/// path standardization resolves Darwin's system aliases after a path exists,
/// which is unsuitable for validating managed roots before they are created.
func criLexicallyNormalizedAbsolutePath(_ path: String) -> String? {
    MacOSManagedPath.lexicallyNormalizedAbsolutePath(path)
}

public enum CRIShimMachineStateAnnotation {
    public static let prefix = "io.container.runtime.macos.machine-state.v1/"
    public static let enabled = prefix + "enabled"
    public static let persistenceID = prefix + "persistence-id"
    public static let restoreStateID = prefix + "restore-state-id"
    public static let restoreStateGeneration = prefix + "restore-state-generation"
    public static let restorePairID = prefix + "restore-pair-id"
    public static let restoreManifestDigest = prefix + "restore-manifest-digest"
    public static let restoreRequestID = prefix + "restore-request-id"
    public static let storageGeneration = prefix + "storage-generation"
    public static let blockDevices = prefix + "block-devices"

    static let companionKeys = [
        persistenceID,
        restoreStateID,
        restoreStateGeneration,
        restorePairID,
        restoreManifestDigest,
        restoreRequestID,
        storageGeneration,
        blockDevices,
    ]
}

struct CRIShimMachineStateMapping: Equatable, Sendable {
    var machineState: ContainerConfiguration.MacOSGuestOptions.MachineState?
    var blockDevices: [ContainerConfiguration.MacOSGuestOptions.BlockDevice]

    static let disabled = CRIShimMachineStateMapping(machineState: nil, blockDevices: [])
}

struct CRIShimMachineStateAnnotationValues: Equatable, Sendable {
    var persistenceID: String
    var restoreStateID: String?
    var restoreStateGeneration: UInt64?
    var restorePairID: String?
    var restoreManifestDigest: String?
    var restoreRequestID: String?
    var storageGeneration: UInt64
}

private struct CRIShimNBDAnnotationDevice: Decodable {
    let identifier: String
    let unixSocket: String
    let exportName: String?
    let readOnly: Bool
    let timeoutSeconds: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier
        case unixSocket
        case exportName
        case readOnly
        case timeoutSeconds
    }

    init(from decoder: any Decoder) throws {
        let allKeys = try decoder.container(keyedBy: CRIShimAnyCodingKey.self).allKeys
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        if let unsupported = allKeys.map(\.stringValue).first(where: { !allowedKeys.contains($0) }) {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unsupported block device field \(unsupported)")
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        unixSocket = try container.decode(String.self, forKey: .unixSocket)
        exportName = try container.decodeIfPresent(String.self, forKey: .exportName)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 5
    }
}

private struct CRIShimAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

func makeCRIShimMachineStateMapping(
    annotations: [String: String],
    nodeConfig: MachineStateConfig?
) throws -> CRIShimMachineStateMapping {
    let enabledValue = annotations[CRIShimMachineStateAnnotation.enabled]
    let presentCompanionKeys = CRIShimMachineStateAnnotation.companionKeys.filter { annotations[$0] != nil }

    guard let enabledValue else {
        guard presentCompanionKeys.isEmpty else {
            throw CRIShimError.invalidArgument(
                "\(presentCompanionKeys[0]) requires \(CRIShimMachineStateAnnotation.enabled)=true"
            )
        }
        return .disabled
    }

    let enabled: Bool
    switch enabledValue {
    case "true":
        enabled = true
    case "false":
        enabled = false
    default:
        throw CRIShimError.invalidArgument(
            "\(CRIShimMachineStateAnnotation.enabled) must be exactly true or false"
        )
    }

    guard enabled else {
        guard presentCompanionKeys.isEmpty else {
            throw CRIShimError.invalidArgument(
                "\(presentCompanionKeys[0]) is not allowed when machine state is disabled"
            )
        }
        return .disabled
    }

    guard let nodeConfig, nodeConfig.enabled else {
        throw CRIShimError.unsupported("machine-state annotations are disabled by the node runtime configuration")
    }
    let values = try decodeEnabledMachineStateAnnotationValues(annotations)
    let blockDevices = try decodeBlockDevices(
        annotations[CRIShimMachineStateAnnotation.blockDevices],
        allowedRoots: nodeConfig.nbdSocketAllowedRoots
    )

    let storageRoot = try managedPathURL(nodeConfig.normalizedStorageRoot)
    let socketRoot = try managedPathURL(nodeConfig.normalizedControlSocketRoot)
    try preparePrivateDirectory(
        storageRoot,
        createIntermediates: true,
        ownerUID: nodeConfig.runtimeOwnerUID
    )
    try preparePrivateDirectory(
        socketRoot,
        createIntermediates: true,
        ownerUID: nodeConfig.runtimeOwnerUID
    )

    let storageDirectory = storageRoot.appendingPathComponent(values.persistenceID, isDirectory: true)
    try requireManagedDescendant(storageDirectory, below: storageRoot)
    try preparePrivateDirectory(
        storageDirectory,
        createIntermediates: false,
        ownerUID: nodeConfig.runtimeOwnerUID
    )

    let controlSocket = socketRoot.appendingPathComponent("\(values.persistenceID).sock", isDirectory: false)
    try requireManagedDescendant(controlSocket, below: socketRoot)
    let socketAddress = sockaddr_un()
    guard controlSocket.path.utf8.count < MemoryLayout.size(ofValue: socketAddress.sun_path) else {
        throw CRIShimError.invalidArgument("derived machine-state control socket path is too long")
    }

    return CRIShimMachineStateMapping(
        machineState: .init(
            protocolVersion:
                values.restoreStateID == nil
                ? MacOSSidecarProtocolVersion.machineState
                : MacOSSidecarProtocolVersion.durableCheckpointAdoption,
            persistenceID: values.persistenceID,
            storageDirectory: storageDirectory.path,
            controlSocketPath: controlSocket.path,
            restoreStateID: values.restoreStateID,
            restoreStateGeneration: values.restoreStateGeneration,
            storageGeneration: values.storageGeneration,
            pairID: values.restorePairID,
            adoptionManifestDigest: values.restoreManifestDigest,
            restoreRequestID: values.restoreRequestID
        ),
        blockDevices: blockDevices
    )
}

func decodeEnabledMachineStateAnnotationValues(
    _ annotations: [String: String]
) throws -> CRIShimMachineStateAnnotationValues {
    let persistenceID = try requireSafeIdentifier(
        annotations[CRIShimMachineStateAnnotation.persistenceID],
        annotation: CRIShimMachineStateAnnotation.persistenceID,
        maximumLength: 64
    )
    let storageGeneration = try requirePositiveGeneration(
        annotations[CRIShimMachineStateAnnotation.storageGeneration],
        annotation: CRIShimMachineStateAnnotation.storageGeneration
    )
    let restoreStateID: String?
    let restoreStateGeneration: UInt64?
    let restorePairID: String?
    let restoreManifestDigest: String?
    let restoreRequestID: String?
    switch (
        annotations[CRIShimMachineStateAnnotation.restoreStateID],
        annotations[CRIShimMachineStateAnnotation.restoreStateGeneration],
        annotations[CRIShimMachineStateAnnotation.restorePairID],
        annotations[CRIShimMachineStateAnnotation.restoreManifestDigest],
        annotations[CRIShimMachineStateAnnotation.restoreRequestID]
    ) {
    case (nil, nil, nil, nil, nil):
        restoreStateID = nil
        restoreStateGeneration = nil
        restorePairID = nil
        restoreManifestDigest = nil
        restoreRequestID = nil
    case (let rawStateID?, let rawGeneration?, let rawPairID?, let rawManifestDigest?, let rawRequestID?):
        restoreStateID = try requireSafeIdentifier(
            rawStateID,
            annotation: CRIShimMachineStateAnnotation.restoreStateID,
            maximumLength: 128
        )
        let selectedGeneration = try requirePositiveGeneration(
            rawGeneration,
            annotation: CRIShimMachineStateAnnotation.restoreStateGeneration
        )
        guard storageGeneration > selectedGeneration else {
            throw CRIShimError.invalidArgument(
                "\(CRIShimMachineStateAnnotation.storageGeneration) must be newer than \(CRIShimMachineStateAnnotation.restoreStateGeneration)"
            )
        }
        restoreStateGeneration = selectedGeneration
        restorePairID = try requireCanonicalSHA256(
            rawPairID,
            annotation: CRIShimMachineStateAnnotation.restorePairID
        )
        restoreManifestDigest = try requireCanonicalSHA256(
            rawManifestDigest,
            annotation: CRIShimMachineStateAnnotation.restoreManifestDigest
        )
        restoreRequestID = try requireSafeIdentifier(
            rawRequestID,
            annotation: CRIShimMachineStateAnnotation.restoreRequestID,
            maximumLength: 128
        )
    default:
        throw CRIShimError.invalidArgument(
            "machine-state warm restore annotations must be supplied as one complete set"
        )
    }
    return CRIShimMachineStateAnnotationValues(
        persistenceID: persistenceID,
        restoreStateID: restoreStateID,
        restoreStateGeneration: restoreStateGeneration,
        restorePairID: restorePairID,
        restoreManifestDigest: restoreManifestDigest,
        restoreRequestID: restoreRequestID,
        storageGeneration: storageGeneration
    )
}

private func requireCanonicalSHA256(
    _ value: String,
    annotation: String
) throws -> String {
    guard value.count == 64,
        value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
        throw CRIShimError.invalidArgument("\(annotation) must be a lowercase SHA-256 hex digest")
    }
    return value
}

private func requirePositiveGeneration(
    _ value: String?,
    annotation: String
) throws -> UInt64 {
    guard let value,
        !value.isEmpty,
        value.utf8.allSatisfy({ (48...57).contains($0) }),
        let generation = UInt64(value),
        generation > 0
    else {
        throw CRIShimError.invalidArgument("\(annotation) must be a positive base-10 UInt64")
    }
    return generation
}

private func decodeBlockDevices(
    _ value: String?,
    allowedRoots: [String]
) throws -> [ContainerConfiguration.MacOSGuestOptions.BlockDevice] {
    guard let value else {
        return []
    }
    guard !value.isEmpty, value.utf8.count <= 65_536 else {
        throw CRIShimError.invalidArgument(
            "\(CRIShimMachineStateAnnotation.blockDevices) must contain 1 to 65536 UTF-8 bytes"
        )
    }

    let decoded: [CRIShimNBDAnnotationDevice]
    do {
        decoded = try JSONDecoder().decode([CRIShimNBDAnnotationDevice].self, from: Data(value.utf8))
    } catch {
        throw CRIShimError.invalidArgument(
            "\(CRIShimMachineStateAnnotation.blockDevices) must be a valid v1 JSON device array: \(error.localizedDescription)"
        )
    }
    guard !decoded.isEmpty, decoded.count <= 16 else {
        throw CRIShimError.invalidArgument(
            "\(CRIShimMachineStateAnnotation.blockDevices) must contain between 1 and 16 devices"
        )
    }
    guard decoded[0].identifier == "root" else {
        throw CRIShimError.invalidArgument("the first block device must have identifier root")
    }

    var identifiers = Set<String>()
    return try decoded.map { device in
        let identifier = try requireSafeIdentifier(
            device.identifier,
            annotation: "block device identifier",
            maximumLength: 64
        )
        guard identifiers.insert(identifier).inserted else {
            throw CRIShimError.invalidArgument("block device identifiers must be unique")
        }
        guard device.timeoutSeconds.isFinite, (0.1...300).contains(device.timeoutSeconds) else {
            throw CRIShimError.invalidArgument("NBD timeoutSeconds must be between 0.1 and 300")
        }
        if let exportName = device.exportName {
            guard !exportName.isEmpty, exportName.utf8.count <= 255, !exportName.contains("\0") else {
                throw CRIShimError.invalidArgument("NBD exportName must contain 1 to 255 bytes without NUL")
            }
        }
        let socketPath = try validateAllowedUnixSocket(device.unixSocket, allowedRoots: allowedRoots)
        return .init(
            identifier: identifier,
            kind: .nbdUnixSocket,
            path: socketPath,
            exportName: device.exportName,
            readOnly: device.readOnly,
            timeoutSeconds: device.timeoutSeconds,
            synchronizationMode: .full
        )
    }
}

func requireSafeIdentifier(
    _ value: String?,
    annotation: String,
    maximumLength: Int
) throws -> String {
    guard let value else {
        throw CRIShimError.invalidArgument("\(annotation) is required")
    }
    return try requireSafeIdentifier(value, annotation: annotation, maximumLength: maximumLength)
}

func requireSafeIdentifier(
    _ value: String,
    annotation: String,
    maximumLength: Int
) throws -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !value.isEmpty,
        value.utf8.count <= maximumLength,
        value != ".",
        value != "..",
        value.unicodeScalars.allSatisfy(allowed.contains)
    else {
        throw CRIShimError.invalidArgument(
            "\(annotation) must contain 1 to \(maximumLength) letters, digits, dots, underscores, or hyphens"
        )
    }
    return value
}

private func preparePrivateDirectory(
    _ url: URL,
    createIntermediates: Bool,
    ownerUID: UInt32?
) throws {
    if ownerUID == UInt32.max {
        throw CRIShimError.invalidArgument("machineState.runtimeOwnerUID must be a valid uid")
    }
    try rejectSymbolicLinksInAbsolutePath(url)
    var value = stat()
    if lstat(url.path, &value) != 0 {
        guard errno == ENOENT else {
            throw CRIShimError.internalError("failed to inspect managed directory \(url.path): \(posixMessage())")
        }
        if createIntermediates {
            try createPrivateDirectoryHierarchy(url, ownerUID: ownerUID)
        } else {
            guard mkdir(url.path, mode_t(S_IRWXU)) == 0 || errno == EEXIST else {
                throw CRIShimError.internalError("failed to create managed directory \(url.path): \(posixMessage())")
            }
        }
    }

    if createIntermediates {
        try repairPrivateDirectoryAncestors(url, ownerUID: ownerUID)
    }
    try securePrivateDirectory(url, ownerUID: ownerUID)
    try rejectSymbolicLinksInAbsolutePath(url)
}

private func createPrivateDirectoryHierarchy(_ url: URL, ownerUID: UInt32?) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
        current.appendPathComponent(component, isDirectory: true)
        var value = stat()
        if lstat(current.path, &value) == 0 {
            continue
        }
        guard errno == ENOENT else {
            throw CRIShimError.internalError("failed to inspect managed directory \(current.path): \(posixMessage())")
        }
        guard mkdir(current.path, mode_t(S_IRWXU)) == 0 || errno == EEXIST else {
            throw CRIShimError.internalError("failed to create managed directory \(current.path): \(posixMessage())")
        }
        try securePrivateDirectory(current, ownerUID: ownerUID)
    }
}

private func repairPrivateDirectoryAncestors(_ url: URL, ownerUID: UInt32?) throws {
    guard let ownerUID else { return }
    let requestedOwner = uid_t(ownerUID)
    var child = url
    var current = child.deletingLastPathComponent()

    while current.path != "/" {
        var value = stat()
        guard lstat(current.path, &value) == 0 else {
            throw CRIShimError.internalError("failed to inspect managed directory \(current.path): \(posixMessage())")
        }
        if (value.st_mode & S_IFMT) == S_IFLNK {
            return
        }
        guard (value.st_mode & S_IFMT) == S_IFDIR else {
            throw CRIShimError.invalidArgument("managed path ancestor must be a directory: \(current.path)")
        }

        let permissions = value.st_mode & mode_t(0o777)
        if (value.st_uid == requestedOwner && permissions & mode_t(S_IXUSR) != 0)
            || permissions & mode_t(S_IXOTH) != 0
        {
            return
        }

        // A previous recursive creation can leave a root-owned 0700 chain
        // above the runtime-owned leaf. Adopt only an unambiguous private
        // single-child chain; never broaden access to a shared ancestor.
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: current.path)
        } catch {
            throw CRIShimError.internalError(
                "failed to inspect managed directory contents \(current.path): \(error.localizedDescription)"
            )
        }
        guard value.st_uid == geteuid(),
            permissions == mode_t(S_IRWXU),
            entries.count == 1,
            entries[0] == child.lastPathComponent
        else {
            throw CRIShimError.invalidArgument(
                "managed directory ancestor is not traversable by runtime owner \(ownerUID): \(current.path)"
            )
        }
        try securePrivateDirectory(current, ownerUID: ownerUID)
        child = current
        current.deleteLastPathComponent()
    }
}

private func securePrivateDirectory(_ url: URL, ownerUID: UInt32?) throws {
    var value = stat()
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
        throw CRIShimError.internalError("failed to open managed directory \(url.path): \(posixMessage())")
    }
    defer { _ = close(fd) }
    guard fstat(fd, &value) == 0 else {
        throw CRIShimError.internalError("failed to inspect managed directory \(url.path): \(posixMessage())")
    }
    guard (value.st_mode & S_IFMT) == S_IFDIR else {
        throw CRIShimError.invalidArgument("managed path must be a directory and cannot be a symbolic link: \(url.path)")
    }
    if let ownerUID {
        let requestedOwner = uid_t(ownerUID)
        if value.st_uid != requestedOwner {
            let effectiveOwner = geteuid()
            guard effectiveOwner == 0, value.st_uid == effectiveOwner else {
                throw CRIShimError.invalidArgument(
                    "managed directory has unexpected owner \(value.st_uid): \(url.path)"
                )
            }
            guard fchown(fd, requestedOwner, gid_t.max) == 0 else {
                throw CRIShimError.internalError("failed to set owner on \(url.path): \(posixMessage())")
            }
        }
    }
    guard fchmod(fd, mode_t(S_IRWXU)) == 0 else {
        throw CRIShimError.internalError("failed to set private permissions on \(url.path): \(posixMessage())")
    }
}

private func requireManagedDescendant(_ candidate: URL, below root: URL) throws {
    guard
        let rootPath = MacOSManagedPath.canonicalPath(root.path),
        let candidatePath = MacOSManagedPath.canonicalPath(candidate.path)
    else {
        throw CRIShimError.invalidArgument("managed path must be absolute and lexically normalized")
    }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard candidatePath.hasPrefix(prefix) else {
        throw CRIShimError.invalidArgument("managed path escapes its configured root")
    }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let candidate = URL(fileURLWithPath: candidatePath, isDirectory: candidate.hasDirectoryPath)
    try rejectSymbolicLinksInAbsolutePath(root)
    try rejectSymbolicLinksInAbsolutePath(candidate)

    var current = root
    var rootValue = stat()
    guard lstat(root.path, &rootValue) == 0, (rootValue.st_mode & S_IFMT) == S_IFDIR else {
        throw CRIShimError.invalidArgument("managed root must be a directory and cannot be a symbolic link: \(root.path)")
    }
    for component in candidate.pathComponents.dropFirst(root.pathComponents.count) {
        current.appendPathComponent(component)
        var value = stat()
        if lstat(current.path, &value) != 0 {
            if errno == ENOENT { return }
            throw CRIShimError.internalError("failed to inspect managed path \(current.path): \(posixMessage())")
        }
        guard (value.st_mode & S_IFMT) != S_IFLNK else {
            throw CRIShimError.invalidArgument("symbolic links are not allowed in managed paths: \(current.path)")
        }
    }
}

private func managedPathURL(_ path: String) throws -> URL {
    guard let physicalPath = MacOSManagedPath.canonicalPath(path) else {
        throw CRIShimError.invalidArgument("managed path must be absolute and canonical with only trusted system aliases")
    }
    return URL(fileURLWithPath: physicalPath)
}

private func rejectSymbolicLinksInAbsolutePath(_ url: URL) throws {
    let physicalURL = try managedPathURL(url.path)
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in physicalURL.pathComponents.dropFirst() {
        current.appendPathComponent(component)
        var value = stat()
        if lstat(current.path, &value) != 0 {
            if errno == ENOENT { return }
            throw CRIShimError.internalError("failed to inspect managed path \(current.path): \(posixMessage())")
        }
        if (value.st_mode & S_IFMT) == S_IFLNK {
            throw CRIShimError.invalidArgument("symbolic links are not allowed in managed paths: \(current.path)")
        }
    }
}

private func validateAllowedUnixSocket(_ path: String, allowedRoots: [String]) throws -> String {
    guard let physicalPath = MacOSManagedPath.canonicalPath(path) else {
        throw CRIShimError.invalidArgument("NBD Unix socket must be an absolute canonical local path")
    }
    guard !allowedRoots.isEmpty else {
        throw CRIShimError.unsupported("NBD Unix sockets are disabled by the node runtime configuration")
    }

    let candidate = URL(fileURLWithPath: physicalPath)
    var matchedRoot: URL?
    for configuredRoot in allowedRoots {
        let root = try managedPathURL(configuredRoot)
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if candidate.path.hasPrefix(prefix) {
            matchedRoot = root
            break
        }
    }
    guard let matchedRoot else {
        throw CRIShimError.invalidArgument("NBD Unix socket is outside the configured allowlist")
    }
    try requireManagedDescendant(candidate, below: matchedRoot)

    var value = stat()
    guard lstat(physicalPath, &value) == 0 else {
        throw CRIShimError.unavailable("NBD Unix socket does not exist: \(path)")
    }
    guard (value.st_mode & S_IFMT) == S_IFSOCK else {
        throw CRIShimError.invalidArgument("NBD path is not a Unix socket: \(path)")
    }
    try probeUnixSocket(physicalPath)
    return physicalPath
}

private func probeUnixSocket(_ path: String) throws {
    #if os(Linux)
    let socketType = CInt(SOCK_STREAM.rawValue)
    #else
    let socketType = SOCK_STREAM
    #endif
    let fd = socket(AF_UNIX, socketType, 0)
    guard fd >= 0 else {
        throw CRIShimError.internalError("failed to create NBD probe socket: \(posixMessage())")
    }
    defer { _ = close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw CRIShimError.invalidArgument("NBD Unix socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        for (index, byte) in bytes.enumerated() {
            buffer[index] = byte
        }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, length)
        }
    }
    guard result == 0 else {
        throw CRIShimError.unavailable("failed to connect to NBD Unix socket \(path): \(posixMessage())")
    }
}

private func posixMessage() -> String {
    String(cString: strerror(errno))
}
