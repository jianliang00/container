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

import ContainerPlugin
import Foundation
import Testing

@testable import ContainerKitServices

struct ContainerKitServicesTests {
    @Test
    func registrationPlanUsesExplicitInstallation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installRoot = root.appendingPathComponent("install", isDirectory: true)
        let appRoot = root.appendingPathComponent("app", isDirectory: true)
        let executableURL = installRoot.appendingPathComponent("bin/container-apiserver")

        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: executableURL.path, contents: Data())

        let services = ContainerKitServices(
            appRoot: appRoot,
            installation: ContainerInstallation(
                installRoot: installRoot,
                apiServerExecutableURL: executableURL
            ),
            environment: [
                "CONTAINER_REGISTRY_KEYCHAIN_DISABLED": "1"
            ]
        )

        let plan = try services.registrationPlan()
        #expect(plan.plistURL == appRoot.appending(path: "apiserver").appending(path: "apiserver.plist"))
        #expect(plan.arguments == [executableURL.path(percentEncoded: false), "start"])
        #expect(plan.environment[ApplicationRoot.environmentName] == appRoot.path(percentEncoded: false))
        #expect(plan.environment[InstallRoot.environmentName] == installRoot.path(percentEncoded: false))
        #expect(plan.environment["CONTAINER_REGISTRY_KEYCHAIN_DISABLED"] == "1")

        let plist = try #require(
            PropertyListSerialization.propertyList(from: plan.plistData, format: nil) as? [String: Any]
        )
        #expect(plist["Label"] as? String == "com.apple.container.apiserver")
        #expect(plist["ProgramArguments"] as? [String] == [executableURL.path(percentEncoded: false), "start"])
        let environmentVariables = try #require(plist["EnvironmentVariables"] as? [String: String])
        #expect(environmentVariables["CONTAINER_REGISTRY_KEYCHAIN_DISABLED"] == "1")
        #expect((plist["MachServices"] as? [String: Bool])?["com.apple.container.apiserver"] == true)
    }

    @Test
    func registrationPlanRequiresReachableExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installRoot = root.appendingPathComponent("install", isDirectory: true)
        let appRoot = root.appendingPathComponent("app", isDirectory: true)
        let executableURL = installRoot.appendingPathComponent("bin/container-apiserver")

        let services = ContainerKitServices(
            appRoot: appRoot,
            installation: ContainerInstallation(
                installRoot: installRoot,
                apiServerExecutableURL: executableURL
            )
        )

        #expect(throws: Error.self) {
            try services.registrationPlan()
        }
    }
}
