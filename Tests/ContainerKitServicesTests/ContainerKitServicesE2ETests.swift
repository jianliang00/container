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
import ContainerKitServices
import ContainerPlugin
import Foundation
import Testing

@Suite(.serialized, .enabled(if: isLaunchdE2EEnabled(), "requires CONTAINERKIT_ENABLE_LAUNCHD_E2E=1"))
struct ContainerKitServicesE2ETests {
    @Test
    func launchdStartStopRoundTrip() async throws {
        let installRoot = packageRoot()
        let appRoot = ApplicationRoot.defaultURL
        let executableURL =
            installRoot
            .appending(path: ".build")
            .appending(path: "arm64-apple-macosx")
            .appending(path: "debug")
            .appending(path: "container-apiserver")

        #expect(FileManager.default.isExecutableFile(atPath: executableURL.path(percentEncoded: false)))

        let services = ContainerKitServices(
            appRoot: appRoot,
            installation: ContainerInstallation(
                installRoot: installRoot,
                apiServerExecutableURL: executableURL
            )
        )

        do {
            try await services.stop()

            let stoppedStatus = try await services.status()
            #expect(!stoppedStatus.isRegistered)
            #expect(stoppedStatus.health == nil)

            try await services.start(timeout: .seconds(10))

            let startedStatus = try await services.status()
            #expect(startedStatus.isRegistered)

            let health = try #require(startedStatus.health)
            #expect(health.installRoot.standardizedFileURL == installRoot.standardizedFileURL)
            #expect(health.appRoot.standardizedFileURL == appRoot.standardizedFileURL)

            let pingHealth = try await ContainerKit().health()
            #expect(pingHealth.installRoot.standardizedFileURL == installRoot.standardizedFileURL)
            #expect(pingHealth.appRoot.standardizedFileURL == appRoot.standardizedFileURL)
        } catch {
            try? await services.start(timeout: .seconds(10))
            throw error
        }
    }
}

private func isLaunchdE2EEnabled() -> Bool {
    ProcessInfo.processInfo.environment["CONTAINERKIT_ENABLE_LAUNCHD_E2E"] == "1"
}

private func packageRoot(filePath: StaticString = #filePath) -> URL {
    URL(filePath: "\(filePath)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
