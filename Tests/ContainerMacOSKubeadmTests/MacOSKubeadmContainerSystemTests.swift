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

import Darwin
import Foundation
import Testing

@testable import ContainerMacOSKubeadm

struct MacOSKubeadmContainerSystemTests {
    @Test func rootCommandsUseTheRootBootstrapDomain() throws {
        #expect(try MacOSKubeadmContainerSystem.userDomainBootstrapCommand(userID: 0) == nil)
        #expect(
            try MacOSKubeadmContainerSystem.command(userID: 0, subcommand: "start") == [
                "/bin/launchctl",
                "asuser",
                "0",
                "/usr/local/bin/container",
                "system",
                "start",
            ])
    }

    @Test func nonRootCommandsSetCredentialsHomeAndBootstrapDomain() throws {
        let optionalDomainCommand = try MacOSKubeadmContainerSystem.userDomainBootstrapCommand(userID: 501)
        let domainCommand = try #require(optionalDomainCommand)
        #expect(domainCommand[0] == "/bin/sh")
        #expect(domainCommand[1] == "-c")
        #expect(domainCommand[2].contains("bootstrap"))
        #expect(domainCommand[2].contains("asuser"))
        #expect(domainCommand[4] == "/bin/launchctl")
        #expect(domainCommand[5] == "user/501")
        #expect(domainCommand[6] == "501")

        let startCommand = try MacOSKubeadmContainerSystem.command(userID: 501, subcommand: "start")
        #expect(
            startCommand == [
                "/bin/launchctl",
                "asuser",
                "501",
                "/usr/bin/sudo",
                "-H",
                "-u",
                "#501",
                "/usr/local/bin/container",
                "system",
                "start",
            ])

        #expect(try MacOSKubeadmContainerSystem.startCommands(userID: 501) == [domainCommand, startCommand])
    }

    @Test func userDomainBootstrapTreatsAnExistingDomainAsSuccess() throws {
        let launchctl = try makeLaunchctlStub(
            bootstrapExitStatus: 36,
            asUserExitStatus: 0
        )
        defer { try? FileManager.default.removeItem(at: launchctl.deletingLastPathComponent()) }

        let optionalCommand = try MacOSKubeadmContainerSystem.userDomainBootstrapCommand(
            userID: 501,
            launchctlPath: launchctl.path
        )
        let command = try #require(optionalCommand)
        #expect(try run(command) == 0)
    }

    @Test func userDomainBootstrapFailsClosedWhenDomainCreationAndUseFail() throws {
        let launchctl = try makeLaunchctlStub(
            bootstrapExitStatus: 55,
            asUserExitStatus: 56
        )
        defer { try? FileManager.default.removeItem(at: launchctl.deletingLastPathComponent()) }

        let optionalCommand = try MacOSKubeadmContainerSystem.userDomainBootstrapCommand(
            userID: 501,
            launchctlPath: launchctl.path
        )
        let command = try #require(optionalCommand)
        #expect(try run(command) == 56)
    }

    @Test func userDomainBootstrapReturnsImmediatelyAfterCreation() throws {
        let launchctl = try makeLaunchctlStub(
            bootstrapExitStatus: 0,
            asUserExitStatus: 57
        )
        defer { try? FileManager.default.removeItem(at: launchctl.deletingLastPathComponent()) }

        let optionalCommand = try MacOSKubeadmContainerSystem.userDomainBootstrapCommand(
            userID: 501,
            launchctlPath: launchctl.path
        )
        let command = try #require(optionalCommand)
        #expect(try run(command) == 0)
    }

    @Test func existingConfigurationAcceptsOnlyTheOriginalContainerServiceUser() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrapPlist = directory.appendingPathComponent("bootstrap.plist")
        let criShimPlist = directory.appendingPathComponent("cri.plist")
        let flannelConfiguration = directory.appendingPathComponent("flannel.json")
        try MacOSKubeadmRenderer.containerSystemBootstrapPlist(containerServiceUserID: 501)
            .write(to: bootstrapPlist, atomically: true, encoding: .utf8)
        try MacOSKubeadmRenderer.criShimPlist(containerServiceUserID: 501)
            .write(to: criShimPlist, atomically: true, encoding: .utf8)
        try #"{"containerServiceUserID":501}"#
            .write(to: flannelConfiguration, atomically: true, encoding: .utf8)

        try MacOSKubeadmContainerSystem.validateExistingConfiguration(
            requestedUserID: 501,
            bootstrapPlistPath: bootstrapPlist.path,
            criShimPlistPath: criShimPlist.path,
            flannelConfigurationPath: flannelConfiguration.path,
            userExists: { _ in true }
        )

        do {
            try MacOSKubeadmContainerSystem.validateExistingConfiguration(
                requestedUserID: 502,
                bootstrapPlistPath: bootstrapPlist.path,
                criShimPlistPath: criShimPlist.path,
                flannelConfigurationPath: flannelConfiguration.path
            )
            Issue.record("expected a container service user change to fail closed")
        } catch MacOSKubeadmError.preflightFailed(let message) {
            #expect(message.contains("uid 501 differs from requested uid 502"))
            #expect(message.contains("--container-service-user 501"))
        }
    }

    @Test func inconsistentExistingContainerServiceUsersFailClosed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrapPlist = directory.appendingPathComponent("bootstrap.plist")
        let criShimPlist = directory.appendingPathComponent("cri.plist")
        try MacOSKubeadmRenderer.containerSystemBootstrapPlist(containerServiceUserID: 501)
            .write(to: bootstrapPlist, atomically: true, encoding: .utf8)
        try MacOSKubeadmRenderer.criShimPlist(containerServiceUserID: 502)
            .write(to: criShimPlist, atomically: true, encoding: .utf8)

        do {
            try MacOSKubeadmContainerSystem.validateExistingConfiguration(
                requestedUserID: 501,
                bootstrapPlistPath: bootstrapPlist.path,
                criShimPlistPath: criShimPlist.path,
                flannelConfigurationPath: directory.appendingPathComponent("missing.json").path
            )
            Issue.record("expected inconsistent container service users to fail closed")
        } catch MacOSKubeadmError.preflightFailed(let message) {
            #expect(message.contains("configuration is inconsistent"))
            #expect(message.contains("reset the node before joining"))
        }
    }

    @Test(arguments: [(0, 501), (501, 0), (501, 502)])
    func existingContainerServiceUserChangesFailClosed(existing: Int, requested: Int) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let criShimPlist = directory.appendingPathComponent("cri.plist")
        try MacOSKubeadmRenderer.criShimPlist(containerServiceUserID: existing)
            .write(to: criShimPlist, atomically: true, encoding: .utf8)

        do {
            try MacOSKubeadmContainerSystem.validateExistingConfiguration(
                requestedUserID: requested,
                bootstrapPlistPath: directory.appendingPathComponent("missing-bootstrap.plist").path,
                criShimPlistPath: criShimPlist.path,
                flannelConfigurationPath: directory.appendingPathComponent("missing-flannel.json").path
            )
            Issue.record("expected a container service user change to fail closed")
        } catch MacOSKubeadmError.preflightFailed(let message) {
            #expect(message.contains("uid \(existing) differs from requested uid \(requested)"))
        }
    }

    @Test func legacyFlannelConfigurationDefaultsToRootContainerServiceUser() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let flannelConfiguration = directory.appendingPathComponent("flannel.json")
        try "{}".write(to: flannelConfiguration, atomically: true, encoding: .utf8)

        try MacOSKubeadmContainerSystem.validateExistingConfiguration(
            requestedUserID: 0,
            bootstrapPlistPath: directory.appendingPathComponent("missing-bootstrap.plist").path,
            criShimPlistPath: directory.appendingPathComponent("missing-cri.plist").path,
            flannelConfigurationPath: flannelConfiguration.path
        )
    }

    @Test func missingContainerServiceUserFailsBeforeJoinMutation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try MacOSKubeadmContainerSystem.validateExistingConfiguration(
                requestedUserID: 501,
                bootstrapPlistPath: directory.appendingPathComponent("missing-bootstrap.plist").path,
                criShimPlistPath: directory.appendingPathComponent("missing-cri.plist").path,
                flannelConfigurationPath: directory.appendingPathComponent("missing-flannel.json").path,
                userExists: { _ in false }
            )
            Issue.record("expected a missing local account to fail preflight")
        } catch MacOSKubeadmError.preflightFailed(let message) {
            #expect(message.contains("uid 501 does not identify a local account"))
        }
    }

    @Test func alternateInstallRootDoesNotUseHostAccountDatabase() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try MacOSKubeadmContainerSystem.validateExistingConfiguration(
            requestedUserID: 501,
            bootstrapPlistPath: directory.appendingPathComponent("missing-bootstrap.plist").path,
            criShimPlistPath: directory.appendingPathComponent("missing-cri.plist").path,
            flannelConfigurationPath: directory.appendingPathComponent("missing-flannel.json").path,
            requireLocalUser: false,
            userExists: { _ in false }
        )
    }

    @Test(arguments: [
        ("state = not running\nlast exit code = 0", "succeeded"),
        ("state = running\nlast exit code = 1", "running"),
        ("state = not running\nlast exit code = 64", "failed (last exit code 64)"),
        ("state = not running", "loaded"),
    ])
    func reportsContainerSystemBootstrapOutcome(output: String, expected: String) {
        #expect(MacOSKubeadmStatusRunner.bootstrapServiceStatus(output: output) == expected)
    }

    @Test func rejectsInvalidUsersAndSubcommands() {
        #expect(throws: MacOSKubeadmError.invalidInput("--container-service-user must be a non-negative uid")) {
            try MacOSKubeadmContainerSystem.command(userID: -1, subcommand: "start")
        }
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--container-service-user exceeds the maximum uid \(uid_t.max)"
            )
        ) {
            try MacOSKubeadmContainerSystem.command(userID: Int.max, subcommand: "start")
        }
        #expect(throws: MacOSKubeadmError.invalidInput("unsupported container system subcommand: restart")) {
            try MacOSKubeadmContainerSystem.command(userID: 501, subcommand: "restart")
        }
    }

    private func makeLaunchctlStub(
        bootstrapExitStatus: Int32,
        asUserExitStatus: Int32
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-macos-kubeadm-user-domain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("launchctl")
        let script = """
            #!/bin/sh
            case "$1" in
                bootstrap) exit \(bootstrapExitStatus) ;;
                asuser) exit \(asUserExitStatus) ;;
                *) exit 58 ;;
            esac
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-macos-kubeadm-existing-user-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func run(_ command: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
