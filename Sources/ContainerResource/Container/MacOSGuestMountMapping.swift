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

public enum MacOSGuestMountMapping {
    public static let automountTag = "com.apple.virtio-fs.automount"
    public static let automountRoot = "/Volumes/My Shared Files"
    public static let defaultSeedShareName = "seed"
    public static let defaultSeedMountPath = guestRealPath(forShareName: defaultSeedShareName)

    public struct HostPathShare: Sendable, Equatable {
        public let name: String
        public let source: String
        public let guestPath: String
        public let readOnly: Bool

        public init(name: String, source: String, guestPath: String, readOnly: Bool) {
            self.name = name
            self.source = source
            self.guestPath = guestPath
            self.readOnly = readOnly
        }

        public var guestRealPath: String {
            MacOSGuestMountMapping.guestRealPath(forShareName: name)
        }
    }

    public enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case unsupportedMountType(String)
        case hostPathNotDirectory(String)
        case guestPathNotAbsolute(String)
        case guestPathReserved(String)
        case guestPathNotWritable(String)
        case conflictingGuestPath(String)
        case conflictingHostPath(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedMountType(let description):
                return "macOS guest only supports hostPath directory mounts; unsupported mount: \(description)"
            case .hostPathNotDirectory(let path):
                return "macOS guest mount source must be an existing directory: \(path)"
            case .guestPathNotAbsolute(let path):
                return "macOS guest mount destination must be an absolute path: \(path)"
            case .guestPathReserved(let path):
                return "macOS guest mount destination is not supported: \(path)"
            case .guestPathNotWritable(let path):
                return """
                    macOS guest mount destination must be under a writable guest path \
                    (/Users/, /private/, /tmp/, /var/, /usr/local/, /opt/): \(path)
                    """
            case .conflictingGuestPath(let path):
                return "macOS guest mount destination has conflicting hostPath mappings: \(path)"
            case .conflictingHostPath(let path):
                return "macOS guest mount source has conflicting read-only mappings: \(path)"
            }
        }
    }

    public static func guestRealPath(forShareName shareName: String) -> String {
        "\(automountRoot)/\(shareName)"
    }

    public static func hostPathShares(from mounts: [Filesystem]) throws -> [HostPathShare] {
        guard !mounts.isEmpty else {
            return []
        }

        var baseNameCounts: [String: Int] = [:]
        var plannedMounts: [(source: String, guestPath: String, readOnly: Bool, baseName: String)] = []
        plannedMounts.reserveCapacity(mounts.count)

        for mount in mounts {
            guard mount.isVirtiofs else {
                throw Error.unsupportedMountType(describe(mount))
            }

            let sourceURL = URL(fileURLWithPath: mount.source).standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Error.hostPathNotDirectory(sourceURL.path)
            }

            guard mount.destination.hasPrefix("/") else {
                throw Error.guestPathNotAbsolute(mount.destination)
            }

            let guestPath = URL(fileURLWithPath: mount.destination).standardizedFileURL.path
            guard !isReservedGuestPath(guestPath) else {
                throw Error.guestPathReserved(guestPath)
            }
            guard isWritableGuestPath(guestPath) else {
                throw Error.guestPathNotWritable(guestPath)
            }

            let baseName = shareBaseName(forGuestPath: guestPath)
            baseNameCounts[baseName, default: 0] += 1
            plannedMounts.append(
                (source: sourceURL.path, guestPath: guestPath, readOnly: mount.options.readonly, baseName: baseName)
            )
        }

        return plannedMounts.map { planned in
            let mountKey = "\(planned.source)\u{0}\(planned.guestPath)\u{0}\(planned.readOnly)"
            let needsHashSuffix = (baseNameCounts[planned.baseName] ?? 0) > 1
            return HostPathShare(
                name: shareName(baseName: planned.baseName, mountKey: mountKey, needsHashSuffix: needsHashSuffix),
                source: planned.source,
                guestPath: planned.guestPath,
                readOnly: planned.readOnly
            )
        }
    }

    public static func mergeHostPathMounts(_ mountGroups: [[Filesystem]]) throws -> [Filesystem] {
        var merged: [Filesystem] = []
        var seenKeys: Set<String> = []
        var mappingsByGuestPath: [String: (source: String, readOnly: Bool)] = [:]
        var readOnlyByHostPath: [String: Bool] = [:]

        for mounts in mountGroups {
            for mount in mounts {
                let normalized = try normalizedHostPathMount(mount)
                let readOnly = normalized.options.readonly
                let guestPath = normalized.destination
                let hostPath = normalized.source

                if let existing = mappingsByGuestPath[guestPath],
                    existing.source != hostPath || existing.readOnly != readOnly
                {
                    throw Error.conflictingGuestPath(guestPath)
                }
                if let existingReadOnly = readOnlyByHostPath[hostPath],
                    existingReadOnly != readOnly
                {
                    throw Error.conflictingHostPath(hostPath)
                }

                mappingsByGuestPath[guestPath] = (source: hostPath, readOnly: readOnly)
                readOnlyByHostPath[hostPath] = readOnly

                let key = "\(hostPath)\u{0}\(guestPath)\u{0}\(readOnly)"
                if seenKeys.insert(key).inserted {
                    merged.append(normalized)
                }
            }
        }

        return merged
    }

    private static func normalizedHostPathMount(_ mount: Filesystem) throws -> Filesystem {
        _ = try hostPathShares(from: [mount])
        let source = URL(fileURLWithPath: mount.source).standardizedFileURL.path
        let destination = URL(fileURLWithPath: mount.destination).standardizedFileURL.path
        var options: MountOptions = []
        if mount.options.readonly {
            options.append("ro")
        }
        return .virtiofs(source: source, destination: destination, options: options)
    }

    private static func isReservedGuestPath(_ path: String) -> Bool {
        if path == "/" {
            return true
        }

        let blockedPrefixes = [
            automountRoot,
            "/System",
            "/bin",
            "/sbin",
            "/dev",
            "/Volumes",
        ]
        if blockedPrefixes.contains(where: { path == $0 || path.hasPrefix("\($0)/") }) {
            return true
        }

        if path == "/usr" || path.hasPrefix("/usr/") {
            return !(path == "/usr/local" || path.hasPrefix("/usr/local/"))
        }

        return false
    }

    private static func isWritableGuestPath(_ path: String) -> Bool {
        let writableRoots = [
            "/Users",
            "/private",
            "/tmp",
            "/var",
            "/usr/local",
            "/opt",
        ]
        return writableRoots.contains { root in
            path.hasPrefix("\(root)/")
        }
    }

    private static func describe(_ mount: Filesystem) -> String {
        switch mount.type {
        case .virtiofs:
            "virtiofs:\(mount.source)->\(mount.destination)"
        case .tmpfs:
            "tmpfs:\(mount.destination)"
        case .block(let format, _, _):
            "block(\(format)):\(mount.source)->\(mount.destination)"
        case .volume(let name, _, _, _):
            "volume(\(name)):\(mount.destination)"
        }
    }

    private static func shareBaseName(forGuestPath guestPath: String) -> String {
        let rawComponent =
            guestPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? "root"

        let sanitized = sanitize(rawComponent)
        return "v-\(sanitized.isEmpty ? "share" : sanitized)"
    }

    private static func sanitize(_ value: String) -> String {
        let mapped = value.lowercased().map { char -> Character in
            if char.isLetter || char.isNumber || char == "." || char == "_" || char == "-" {
                return char
            }
            return "-"
        }

        let collapsed = String(mapped).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if trimmed.isEmpty {
            return ""
        }
        if let first = trimmed.first, first.isLetter || first.isNumber {
            return trimmed
        }
        return "share-\(trimmed)"
    }

    private static func shareName(baseName: String, mountKey: String, needsHashSuffix: Bool) -> String {
        let maxLength = 63
        guard needsHashSuffix else {
            return String(baseName.prefix(maxLength))
        }

        let suffix = String(stableHashHex(mountKey).prefix(8))
        let trimmedBase = String(baseName.prefix(max(1, maxLength - suffix.count - 1)))
        return "\(trimmedBase)-\(suffix)"
    }

    private static func stableHashHex(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let text = String(hash, radix: 16, uppercase: false)
        if text.count >= 16 {
            return text
        }
        return String(repeating: "0", count: 16 - text.count) + text
    }
}
