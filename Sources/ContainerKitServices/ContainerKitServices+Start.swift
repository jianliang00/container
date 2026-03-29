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

import ContainerKit
import ContainerPlugin
import Foundation

public extension ContainerKitServices {
    func start(timeout: Duration = .seconds(10)) async throws {
        let plan = try registrationPlan()

        try FileManager.default.createDirectory(
            at: plan.plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plan.plistData.write(to: plan.plistURL)

        do {
            try ServiceManager.register(plistPath: plan.plistURL.path)
        } catch {
            throw diagnosticsError(
                action: "failed to register apiserver with launchd",
                error: error
            )
        }

        do {
            _ = try await kit.health(timeout: timeout)
        } catch {
            throw diagnosticsError(
                action: "failed to get a response from apiserver",
                error: error
            )
        }
    }
}

extension ContainerKitServices {
    func registrationPlan() throws -> APIServerRegistrationPlan {
        guard try installation.apiServerExecutableURL.checkResourceIsReachable() else {
            throw CocoaError(.fileNoSuchFile)
        }

        let apiServerDataURL = appRoot.appending(path: "apiserver")
        let executablePath = installation.apiServerExecutableURL.path(percentEncoded: false)

        var env = PluginLoader.filterEnvironment()
        env[ApplicationRoot.environmentName] = appRoot.path(percentEncoded: false)
        env[InstallRoot.environmentName] = installation.installRoot.path(percentEncoded: false)

        let plist = LaunchPlist(
            label: Self.apiServerServiceLabel,
            arguments: [executablePath, "start"],
            environment: env,
            limitLoadToSessionType: [.Aqua, .Background, .System],
            runAtLoad: true,
            machServices: [Self.apiServerServiceLabel]
        )

        return APIServerRegistrationPlan(
            plistURL: apiServerDataURL.appending(path: "apiserver.plist"),
            plistData: try plist.encode(),
            arguments: [executablePath, "start"],
            environment: env
        )
    }

    func diagnosticsError(action: String, error: any Error) -> NSError {
        NSError(
            domain: "ContainerKitServices",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: """
                    \(action): \(error)
                    \(collectAPIServerDiagnostics())
                    """,
                NSUnderlyingErrorKey: error as NSError,
            ]
        )
    }

    func collectAPIServerDiagnostics() -> String {
        var lines = ["apiserver launchd diagnostics:"]

        do {
            let domain = try ServiceManager.getDomainString()
            let fullLabel = "\(domain)/\(Self.apiServerServiceLabel)"
            let isRegistered = try ServiceManager.isRegistered(fullServiceLabel: Self.apiServerServiceLabel)
            lines.append("launchd domain: \(domain)")
            lines.append("service label: \(fullLabel)")
            lines.append("registered: \(isRegistered)")

            let domainResult = try Self.runLaunchctl(args: ["print", fullLabel])
            let preferred: (status: Int32, output: String)
            let dumpLabel: String
            if domainResult.status == 0 {
                preferred = domainResult
                dumpLabel = fullLabel
            } else {
                preferred = try Self.runLaunchctl(args: ["print", Self.apiServerServiceLabel])
                dumpLabel = Self.apiServerServiceLabel
            }

            let launchctlDump = preferred.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if launchctlDump.isEmpty {
                lines.append("launchctl print output is empty (status \(preferred.status))")
            } else {
                lines.append("launchctl print (\(dumpLabel), status \(preferred.status)):")
                lines.append(Self.trimLaunchctlOutput(launchctlDump, maxLines: Self.launchctlPrintLineLimit))
            }
        } catch {
            lines.append("failed to query launchd state: \(error)")
        }

        return lines.joined(separator: "\n")
    }

    private static func runLaunchctl(args: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            status: process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? ""
        )
    }

    private static func trimLaunchctlOutput(_ output: String, maxLines: Int) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count > maxLines else {
            return output
        }

        return lines.prefix(maxLines).joined(separator: "\n") + "\n..."
    }
}
