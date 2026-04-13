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

extension ContainerKitServices {
    public func start(
        timeout: Duration = .seconds(10),
        installDefaultKernel: Bool = false
    ) async throws {
        let plan = try registrationPlan()

        try dependencies.createDirectory(plan.plistURL.deletingLastPathComponent())
        try dependencies.writeData(plan.plistData, plan.plistURL)

        do {
            try dependencies.registerService(plan.plistURL.path)
        } catch {
            throw diagnosticsError(
                action: "failed to register apiserver with launchd",
                error: error
            )
        }

        do {
            _ = try await dependencies.healthCheck(timeout)
        } catch {
            throw diagnosticsError(
                action: "failed to get a response from apiserver",
                error: error
            )
        }

        guard installDefaultKernel else {
            return
        }

        do {
            try await ensureDefaultKernelInstalled()
        } catch {
            throw diagnosticsError(
                action: "failed to install default kernel",
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

    func ensureDefaultKernelInstalled() async throws {
        guard try await !dependencies.defaultKernelExists() else {
            return
        }
        try await dependencies.installRecommendedKernel()
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
            let domain = try dependencies.domainString()
            let fullLabel = "\(domain)/\(Self.apiServerServiceLabel)"
            let isRegistered = try dependencies.isServiceRegistered(Self.apiServerServiceLabel)
            lines.append("launchd domain: \(domain)")
            lines.append("service label: \(fullLabel)")
            lines.append("registered: \(isRegistered)")

            let domainResult = try dependencies.runLaunchctl(["print", fullLabel])
            let preferred: (status: Int32, output: String)
            let dumpLabel: String
            if domainResult.status == 0 {
                preferred = domainResult
                dumpLabel = fullLabel
            } else {
                preferred = try dependencies.runLaunchctl(["print", Self.apiServerServiceLabel])
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

    private static func trimLaunchctlOutput(_ output: String, maxLines: Int) -> String {
        let lines =
            output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count > maxLines else {
            return output
        }

        return lines.prefix(maxLines).joined(separator: "\n") + "\n..."
    }
}
