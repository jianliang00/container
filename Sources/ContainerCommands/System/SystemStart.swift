//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import ContainerPersistence
import ContainerPlugin
import ContainerizationError
import Foundation
import TerminalProgress

extension Application {
    public struct SystemStart: AsyncLoggableCommand {
        private static let apiServerServiceLabel = "com.apple.container.apiserver"
        private static let launchctlPrintLineLimit = 30

        public static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start `container` services"
        )

        @Option(
            name: .shortAndLong,
            help: "Path to the root directory for application data",
            transform: { URL(filePath: $0) })
        var appRoot = ApplicationRoot.defaultURL

        @Option(
            name: .long,
            help: "Path to the root directory for application executables and plugins",
            transform: { URL(filePath: $0) })
        var installRoot = InstallRoot.defaultURL

        @Flag(
            name: .long,
            inversion: .prefixedEnableDisable,
            help: "Specify whether the default kernel should be installed or not (default: prompt user)")
        var kernelInstall: Bool?

        @Option(
            name: .long,
            help: "Number of seconds to wait for API service to become responsive")
        var timeout: Double = 10.0

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            // Without the true path to the binary in the plist, `container-apiserver` won't launch properly.
            // TODO: Can we use the plugin loader to bootstrap the API server?
            let executableUrl = CommandLine.executablePathUrl
                .deletingLastPathComponent()
                .appendingPathComponent("container-apiserver")
                .resolvingSymlinksInPath()

            var args = [executableUrl.absolutePath()]

            args.append("start")
            if logOptions.debug {
                args.append("--debug")
            }

            let apiServerDataUrl = appRoot.appending(path: "apiserver")
            try! FileManager.default.createDirectory(at: apiServerDataUrl, withIntermediateDirectories: true)

            var env = PluginLoader.filterEnvironment()
            env[ApplicationRoot.environmentName] = appRoot.path(percentEncoded: false)
            env[InstallRoot.environmentName] = installRoot.path(percentEncoded: false)

            let plist = LaunchPlist(
                label: "com.apple.container.apiserver",
                arguments: args,
                environment: env,
                limitLoadToSessionType: [.Aqua, .Background, .System],
                runAtLoad: true,
                machServices: ["com.apple.container.apiserver"]
            )

            let plistURL = apiServerDataUrl.appending(path: "apiserver.plist")
            let data = try plist.encode()
            try data.write(to: plistURL)

            print("Registering API server with launchd...")
            do {
                try ServiceManager.register(plistPath: plistURL.path)
            } catch {
                let diagnostics = self.collectAPIServerDiagnostics()
                throw ContainerizationError(
                    .internalError,
                    message: """
                        failed to register apiserver with launchd: \(error)
                        \(diagnostics)
                        """
                )
            }

            // Now ping our friendly daemon. Fail if we don't get a response.
            do {
                print("Verifying apiserver is running...")
                _ = try await ClientHealthCheck.ping(timeout: .seconds(timeout))
            } catch {
                let diagnostics = self.collectAPIServerDiagnostics()
                throw ContainerizationError(
                    .internalError,
                    message: """
                        failed to get a response from apiserver: \(error)
                        \(diagnostics)
                        """
                )
            }

            if await !initImageExists() {
                try? await installInitialFilesystem()
            }

            guard await !kernelExists() else {
                return
            }
            try await installDefaultKernel()
        }

        private func installInitialFilesystem() async throws {
            let dep = Dependencies.initFs
            var pullCommand = try ImagePull.parse()
            pullCommand.reference = dep.source
            print("Installing base container filesystem...")
            do {
                try await pullCommand.run()
            } catch {
                log.error("failed to install base container filesystem: \(error)")
            }
        }

        private func installDefaultKernel() async throws {
            let kernelDependency = Dependencies.kernel
            let defaultKernelURL = kernelDependency.source
            let defaultKernelBinaryPath = DefaultsStore.get(key: .defaultKernelBinaryPath)

            var shouldInstallKernel = false
            if kernelInstall == nil {
                print("No default kernel configured.")
                print("Install the recommended default kernel from [\(kernelDependency.source)]? [Y/n]: ", terminator: "")
                guard let read = readLine(strippingNewline: true) else {
                    throw ContainerizationError(.internalError, message: "failed to read user input")
                }
                guard read.lowercased() == "y" || read.count == 0 else {
                    print("Please use the `container system kernel set --recommended` command to configure the default kernel")
                    return
                }
                shouldInstallKernel = true
            } else {
                shouldInstallKernel = kernelInstall ?? false
            }
            guard shouldInstallKernel else {
                return
            }
            print("Installing kernel...")
            try await KernelSet.downloadAndInstallWithProgressBar(tarRemoteURL: defaultKernelURL, kernelFilePath: defaultKernelBinaryPath, force: true)
        }

        private func initImageExists() async -> Bool {
            do {
                let img = try await ClientImage.get(reference: Dependencies.initFs.source)
                let _ = try await img.getSnapshot(platform: .current)
                return true
            } catch {
                return false
            }
        }

        private func kernelExists() async -> Bool {
            do {
                try await ClientKernel.getDefaultKernel(for: .current)
                return true
            } catch {
                return false
            }
        }

        private func collectAPIServerDiagnostics() -> String {
            var lines = ["apiserver launchd diagnostics:"]
            do {
                let domain = try ServiceManager.getDomainString()
                let fullLabel = "\(domain)/\(Self.apiServerServiceLabel)"
                let isRegistered = try ServiceManager.isRegistered(fullServiceLabel: Self.apiServerServiceLabel)
                lines.append("launchd domain: \(domain)")
                lines.append("service label: \(fullLabel)")
                lines.append("registered: \(isRegistered)")

                let domainResult = try runLaunchctl(args: ["print", fullLabel])
                let preferred: (status: Int32, output: String)
                let dumpLabel: String
                if domainResult.status == 0 {
                    preferred = domainResult
                    dumpLabel = fullLabel
                } else {
                    preferred = try runLaunchctl(args: ["print", Self.apiServerServiceLabel])
                    dumpLabel = Self.apiServerServiceLabel
                }

                let launchctlDump = preferred.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if launchctlDump.isEmpty {
                    lines.append("launchctl print output is empty (status \(preferred.status))")
                } else {
                    let preview = trimLaunchctlOutput(launchctlDump, maxLines: Self.launchctlPrintLineLimit)
                    lines.append("launchctl print (\(dumpLabel), status \(preferred.status)):")
                    lines.append(preview)
                }
            } catch {
                lines.append("failed to query launchd state: \(error)")
            }
            lines.append("hint: run `container system logs --last 5m` for detailed service logs")
            return lines.joined(separator: "\n")
        }

        private func runLaunchctl(args: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = args

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            return (status: process.terminationStatus, output: output)
        }

        private func trimLaunchctlOutput(_ output: String, maxLines: Int) -> String {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count > maxLines else {
                return output
            }
            let head = lines.prefix(maxLines).joined(separator: "\n")
            let remaining = lines.count - maxLines
            return "\(head)\n... (\(remaining) more lines)"
        }
    }

    private enum Dependencies: String {
        case kernel
        case initFs

        var source: String {
            switch self {
            case .initFs:
                return DefaultsStore.get(key: .defaultInitImage)
            case .kernel:
                return DefaultsStore.get(key: .defaultKernelURL)
            }
        }
    }
}
