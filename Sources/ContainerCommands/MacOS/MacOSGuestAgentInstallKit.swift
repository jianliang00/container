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

import ArgumentParser
import ContainerAPIClient
import ContainerVersion
import ContainerizationError
import Foundation

extension Application {
    public struct MacOSGuestAgentCommand: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "guest-agent",
            abstract: "Manage tools for installing the macOS guest agent",
            subcommands: [
                MacOSGuestAgentInstallKit.self
            ]
        )

        @OptionGroup
        public var logOptions: Flags.Logging
    }

    public struct MacOSGuestAgentInstallKit: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "prepare",
            abstract: "Create a directory that can be mounted into a macOS guest to install the guest agent"
        )

        @Option(
            name: .shortAndLong,
            help: "Output directory for the install kit",
            completion: .directory,
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
            }
        )
        var output: URL

        @Flag(name: .long, help: "Overwrite output directory if present")
        var overwrite = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let sources = try Self.resolveSources(cliExecutableURL: CommandLine.executablePathUrl.standardizedFileURL)
            try Self.writeInstallKit(
                sources: sources,
                outputDirectory: output,
                overwrite: overwrite
            )

            print(output.path(percentEncoded: false))
            print("In the guest, mount this directory with virtiofs and run:")
            print("  sudo bash /Volumes/<tag>/install-in-guest-from-seed.sh")
            print("  (default tag is 'seed')")
        }

        struct Sources {
            let agentBinary: URL
            let installScript: URL
            let plistTemplate: URL
            let installFromSeedScript: URL
        }

        static func resolveSources(cliExecutableURL: URL) throws -> Sources {
            let fm = FileManager.default

            if let override = ProcessInfo.processInfo.environment["CONTAINER_MACOS_GUEST_AGENT_BIN"], !override.isEmpty {
                let url = URL(fileURLWithPath: override, relativeTo: .currentDirectory()).absoluteURL
                if fm.isExecutableFile(atPath: url.path) {
                    let scriptsDir = try resolveScriptsDir(cliExecutableURL: cliExecutableURL)
                    return try makeSources(agentBinary: url, scriptsDir: scriptsDir)
                }
                throw ContainerizationError(.notFound, message: "CONTAINER_MACOS_GUEST_AGENT_BIN points to a non-executable file: \(override)")
            }

            let scriptsDir = try resolveScriptsDir(cliExecutableURL: cliExecutableURL)
            let installRoot = cliExecutableURL.deletingLastPathComponent().appendingPathComponent("..").standardizedFileURL

            let candidates = [
                installRoot
                    .appendingPathComponent("libexec")
                    .appendingPathComponent("container")
                    .appendingPathComponent("macos-guest-agent")
                    .appendingPathComponent("bin")
                    .appendingPathComponent("container-macos-guest-agent")
            ]

            for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
                return try makeSources(agentBinary: candidate, scriptsDir: scriptsDir)
            }

            let candidatePaths = candidates.map { "  - \($0.path(percentEncoded: false))" }.joined(separator: "\n")
            throw ContainerizationError(
                .notFound,
                message: "container-macos-guest-agent not found. Checked:\n\(candidatePaths)"
            )
        }

        private static func resolveScriptsDir(cliExecutableURL: URL) throws -> URL {
            let fm = FileManager.default

            if let override = ProcessInfo.processInfo.environment["CONTAINER_MACOS_GUEST_AGENT_SCRIPTS_DIR"], !override.isEmpty {
                let url = URL(fileURLWithPath: override, relativeTo: .currentDirectory()).absoluteURL
                if fm.fileExists(atPath: url.path) {
                    return url
                }
                throw ContainerizationError(.notFound, message: "CONTAINER_MACOS_GUEST_AGENT_SCRIPTS_DIR points to a missing directory: \(override)")
            }

            let installRoot = cliExecutableURL.deletingLastPathComponent().appendingPathComponent("..").standardizedFileURL
            let candidates = [
                installRoot
                    .appendingPathComponent("libexec")
                    .appendingPathComponent("container")
                    .appendingPathComponent("macos-guest-agent")
                    .appendingPathComponent("share"),
                installRoot
                    .appendingPathComponent("scripts")
                    .appendingPathComponent("macos-guest-agent"),
            ]

            for candidate in candidates where fm.fileExists(atPath: candidate.path) {
                return candidate
            }

            let candidatePaths = candidates.map { "  - \($0.path(percentEncoded: false))" }.joined(separator: "\n")
            throw ContainerizationError(
                .notFound,
                message: "guest agent install scripts not found. Checked:\n\(candidatePaths)"
            )
        }

        private static func makeSources(agentBinary: URL, scriptsDir: URL) throws -> Sources {
            let fm = FileManager.default
            let installScript = scriptsDir.appendingPathComponent("install.sh")
            let plistTemplate = scriptsDir.appendingPathComponent("container-macos-guest-agent.plist")
            let installFromSeedScript = scriptsDir.appendingPathComponent("install-in-guest-from-seed.sh")
            let required = [installScript, plistTemplate, installFromSeedScript]
            let missing = required.filter { !fm.fileExists(atPath: $0.path) }
            if !missing.isEmpty {
                let missingList = missing.map { "  - \($0.path(percentEncoded: false))" }.joined(separator: "\n")
                throw ContainerizationError(.notFound, message: "guest agent install kit files missing:\n\(missingList)")
            }
            return Sources(
                agentBinary: agentBinary,
                installScript: installScript,
                plistTemplate: plistTemplate,
                installFromSeedScript: installFromSeedScript
            )
        }

        static func writeInstallKit(sources: Sources, outputDirectory: URL, overwrite: Bool) throws {
            let fm = FileManager.default
            if fm.fileExists(atPath: outputDirectory.path) {
                if overwrite {
                    try fm.removeItem(at: outputDirectory)
                } else {
                    throw ContainerizationError(.exists, message: "output directory already exists: \(outputDirectory.path(percentEncoded: false))")
                }
            }
            try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            let agentDest = outputDirectory.appendingPathComponent("container-macos-guest-agent")
            let installDest = outputDirectory.appendingPathComponent("install.sh")
            let plistDest = outputDirectory.appendingPathComponent("container-macos-guest-agent.plist")
            let installFromSeedDest = outputDirectory.appendingPathComponent("install-in-guest-from-seed.sh")

            try copyReplacingIfExists(from: sources.agentBinary, to: agentDest)
            try copyReplacingIfExists(from: sources.installScript, to: installDest)
            try copyReplacingIfExists(from: sources.plistTemplate, to: plistDest)
            try copyReplacingIfExists(from: sources.installFromSeedScript, to: installFromSeedDest)

            try setPermissions(0o755, url: agentDest)
            try setPermissions(0o755, url: installDest)
            try setPermissions(0o644, url: plistDest)
            try setPermissions(0o755, url: installFromSeedDest)
        }

        private static func copyReplacingIfExists(from: URL, to: URL) throws {
            let fm = FileManager.default
            if fm.fileExists(atPath: to.path) {
                try fm.removeItem(at: to)
            }
            try fm.copyItem(at: from, to: to)
        }

        private static func setPermissions(_ mode: Int, url: URL) throws {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }
}
