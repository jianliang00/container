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
import ContainerizationError
import ContainerVersion
import Foundation

extension Application {
    public struct MacOSPrepareBase: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "prepare-base",
            abstract: "Create a macOS guest template directory from an IPSW restore image"
        )

        private static let helperBinaryName = "container-macos-image-prepare"
        private static let helperBinaryEnvVar = "CONTAINER_MACOS_IMAGE_PREPARE_BIN"

        @Option(
            name: .long,
            help: "Path to an IPSW file",
            completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
            }
        )
        var ipsw: URL

        @Option(
            name: .shortAndLong,
            help: "Output template directory",
            completion: .directory,
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
            }
        )
        var output: URL

        @Option(name: [.customLong("disk-size-gib"), .long], help: "Disk image size in GiB")
        var diskSizeGiB: UInt64 = 64

        @Option(name: [.customLong("memory-mib"), .long], help: "Memory size in MiB")
        var memoryMiB: UInt64 = 8192

        @Option(name: .long, help: "vCPU count")
        var cpus: Int?

        @Flag(name: .long, help: "Overwrite output files if present")
        var overwrite = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let helperURL = try helperBinaryURL()
            let process = Process()
            process.executableURL = helperURL
            process.arguments = helperArguments()
            process.environment = ProcessInfo.processInfo.environment
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            do {
                try process.run()
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to start \(Self.helperBinaryName) at \(helperURL.path): \(error.localizedDescription)",
                    cause: error
                )
            }

            process.waitUntilExit()
            switch process.terminationReason {
            case .exit:
                if process.terminationStatus != 0 {
                    throw ArgumentParser.ExitCode(process.terminationStatus)
                }
            case .uncaughtSignal:
                throw ArgumentParser.ExitCode(process.terminationStatus + 128)
            @unknown default:
                throw ArgumentParser.ExitCode(1)
            }
        }

        private func helperArguments() -> [String] {
            var args: [String] = [
                "--ipsw", ipsw.standardizedFileURL.path,
                "--output", output.standardizedFileURL.path,
                "--disk-size-gib", String(diskSizeGiB),
                "--memory-mib", String(memoryMiB),
            ]

            if let cpus {
                args += ["--cpus", String(cpus)]
            }
            if overwrite {
                args.append("--overwrite")
            }
            return args
        }

        private func helperBinaryURL() throws -> URL {
            let fm = FileManager.default

            if let override = ProcessInfo.processInfo.environment[Self.helperBinaryEnvVar], !override.isEmpty {
                let url = URL(fileURLWithPath: override, relativeTo: .currentDirectory()).absoluteURL
                if fm.isExecutableFile(atPath: url.path) {
                    return url
                }
                throw ContainerizationError(
                    .notFound,
                    message: "\(Self.helperBinaryEnvVar) points to a non-executable file: \(override)"
                )
            }

            let executableURL = CommandLine.executablePathUrl.standardizedFileURL
            let executableDir = executableURL.deletingLastPathComponent()
            let installRoot = executableDir.appendingPathComponent("..").standardizedFileURL
            let candidates = [
                executableDir.appendingPathComponent(Self.helperBinaryName),
                installRoot
                    .appendingPathComponent("libexec")
                    .appendingPathComponent("container")
                    .appendingPathComponent("macos-image-prepare")
                    .appendingPathComponent("bin")
                    .appendingPathComponent(Self.helperBinaryName),
            ]

            for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }

            let candidatePaths = candidates.map { "  - \($0.path(percentEncoded: false))" }.joined(separator: "\n")
            throw ContainerizationError(
                .notFound,
                message: "\(Self.helperBinaryName) not found. Install it under the macos-image-prepare helper directory or set \(Self.helperBinaryEnvVar). Checked:\n\(candidatePaths)"
            )
        }
    }
}
