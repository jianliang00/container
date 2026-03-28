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

/// A read-only file that should be staged into a sandbox bundle and injected into the guest.
public struct ReadOnlyFileInjection: Sendable, Codable, Equatable {
    /// Host source file to snapshot into the sandbox bundle.
    public var source: String
    /// Absolute guest destination path.
    public var destination: String
    /// Optional mode override for the injected file. When omitted, the source mode is copied with write bits removed.
    public var mode: UInt32?
    /// Whether the injection may replace an existing guest file.
    public var overwrite: Bool

    public init(
        source: String,
        destination: String,
        mode: UInt32? = nil,
        overwrite: Bool = true
    ) {
        self.source = source
        self.destination = destination
        self.mode = mode
        self.overwrite = overwrite
    }
}

public enum MacOSReadOnlyFileInjectionStore {
    public struct PreparedEntry: Sendable, Equatable {
        public let sourceURL: URL
        public let destination: String
        public let mode: UInt32
        public let overwrite: Bool

        public init(sourceURL: URL, destination: String, mode: UInt32, overwrite: Bool) {
            self.sourceURL = sourceURL
            self.destination = destination
            self.mode = mode
            self.overwrite = overwrite
        }
    }

    public enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case sourceNotRegularFile(String)
        case destinationNotAbsolute(String)
        case stagedFileMissing(String)

        public var errorDescription: String? {
            switch self {
            case .sourceNotRegularFile(let path):
                return "macOS guest read-only injection source must be an existing regular file: \(path)"
            case .destinationNotAbsolute(let path):
                return "macOS guest read-only injection destination must be an absolute path: \(path)"
            case .stagedFileMissing(let path):
                return "macOS guest read-only injection staged file is missing: \(path)"
            }
        }
    }

    struct Manifest: Codable, Sendable, Equatable {
        var entries: [ManifestEntry]
    }

    struct ManifestEntry: Codable, Sendable, Equatable {
        var stagedPath: String
        var destination: String
        var mode: UInt32
        var overwrite: Bool
    }

    public static func stage(
        _ injections: [ReadOnlyFileInjection],
        in layout: MacOSSandboxLayout,
        fileManager: FileManager = .default
    ) throws {
        try layout.prepareBaseDirectories(fileManager: fileManager)

        let stagedFilesDirectory = layout.readonlyInjectionDirectoryURL.appendingPathComponent("files")
        if fileManager.fileExists(atPath: stagedFilesDirectory.path) {
            try fileManager.removeItem(at: stagedFilesDirectory)
        }
        try fileManager.createDirectory(at: stagedFilesDirectory, withIntermediateDirectories: true)

        guard !injections.isEmpty else {
            try? fileManager.removeItem(at: layout.readonlyInjectionManifestURL)
            return
        }

        var manifestEntries: [ManifestEntry] = []
        manifestEntries.reserveCapacity(injections.count)

        for (index, injection) in injections.enumerated() {
            let sourceURL = URL(fileURLWithPath: injection.source).standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw Error.sourceNotRegularFile(sourceURL.path)
            }
            guard injection.destination.hasPrefix("/") else {
                throw Error.destinationNotAbsolute(injection.destination)
            }

            let stagedName = stagedFileName(for: sourceURL, index: index)
            let stagedPath = "files/\(stagedName)"
            let stagedURL = layout.readonlyInjectionDirectoryURL.appendingPathComponent(stagedPath)
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: stagedURL, options: .atomic)

            let resolvedMode = try injection.mode ?? defaultMode(for: sourceURL, fileManager: fileManager)
            manifestEntries.append(
                .init(
                    stagedPath: stagedPath,
                    destination: URL(fileURLWithPath: injection.destination).standardizedFileURL.path,
                    mode: resolvedMode,
                    overwrite: injection.overwrite
                )
            )
        }

        let manifest = Manifest(entries: manifestEntries)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: layout.readonlyInjectionManifestURL, options: .atomic)
    }

    public static func load(
        from layout: MacOSSandboxLayout,
        fileManager: FileManager = .default
    ) throws -> [PreparedEntry] {
        guard fileManager.fileExists(atPath: layout.readonlyInjectionManifestURL.path) else {
            return []
        }

        let data = try Data(contentsOf: layout.readonlyInjectionManifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        return try manifest.entries.map { entry in
            let sourceURL = layout.readonlyInjectionDirectoryURL.appendingPathComponent(entry.stagedPath)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw Error.stagedFileMissing(sourceURL.path)
            }
            return PreparedEntry(
                sourceURL: sourceURL,
                destination: entry.destination,
                mode: entry.mode,
                overwrite: entry.overwrite
            )
        }
    }

    private static func stagedFileName(for sourceURL: URL, index: Int) -> String {
        let basename = sanitize(sourceURL.lastPathComponent.isEmpty ? "file" : sourceURL.lastPathComponent)
        return String(format: "%03d-%@", index, basename)
    }

    private static func sanitize(_ value: String) -> String {
        let mapped = value.map { character -> Character in
            if character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" {
                return character
            }
            return "-"
        }
        let collapsed = String(mapped).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return trimmed.isEmpty ? "file" : trimmed
    }

    private static func defaultMode(for sourceURL: URL, fileManager: FileManager) throws -> UInt32 {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let rawMode = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        let readOnlyMode = rawMode & ~UInt32(0o222)
        return readOnlyMode == 0 ? 0o444 : readOnlyMode
    }
}
