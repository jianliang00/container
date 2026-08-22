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
    @Test func operationAgentLabelIsStableAndOutsideTheManagedServicePrefix() {
        #expect(!MacOSKubeadmContainerSystem.operationLaunchdLabelPrefix.hasPrefix("com.apple.container."))
        #expect(!MacOSKubeadmContainerSystem.legacyGUIOperationLaunchdLabelPrefix.hasPrefix("com.apple.container."))
        #expect(
            MacOSKubeadmContainerSystem.operationLaunchdLabel(userID: 501)
                == "com.apple.container-macos-kubeadm.operation.501"
        )
        #expect(
            MacOSKubeadmContainerSystem.legacyGUIOperationLaunchdLabel(userID: 501)
                == "com.apple.container-macos-kubeadm.legacy-gui-operation.501"
        )
    }

    @Test func rootCommandsUseTheSystemDomainDispatcher() throws {
        #expect(
            try MacOSKubeadmContainerSystem.command(userID: 0, subcommand: "start") == [
                "/usr/local/bin/container-macos-kubeadm",
                "start-container-system",
                "--container-service-user",
                "0",
            ])
        #expect(
            try MacOSKubeadmContainerSystem.command(userID: 0, subcommand: "status") == [
                "/bin/launchctl",
                "asuser",
                "0",
                "/usr/local/bin/container",
                "system",
                "status",
            ])
    }

    @Test func nonRootCommandsUseTheBackgroundDomainDispatcher() throws {
        #expect(
            try MacOSKubeadmContainerSystem.command(userID: 501, subcommand: "start") == [
                "/usr/local/bin/container-macos-kubeadm",
                "start-container-system",
                "--container-service-user",
                "501",
            ])
        #expect(
            try MacOSKubeadmContainerSystem.command(userID: 501, subcommand: "stop") == [
                "/usr/local/bin/container-macos-kubeadm",
                "stop-container-system",
                "--container-service-user",
                "501",
            ])
        #expect(
            try MacOSKubeadmContainerSystem.command(userID: 501, subcommand: "status") == [
                "/bin/launchctl",
                "asuser",
                "501",
                "/usr/bin/sudo",
                "-H",
                "-u",
                "#501",
                "/usr/local/bin/container",
                "system",
                "status",
            ])
    }

    @Test func backgroundDispatcherBootstrapsExplicitUserDomainAndCleansAllFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var capturedPlist: [String: Any]?
        let launchctl = LaunchctlHarness(domainAvailable: false, domainBootstrapStatus: 36)
        launchctl.onAgentBootstrap = { plist in
            capturedPlist = plist
            try writeCompletion(from: plist, status: 0)
        }
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run
        )

        try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
            userID: 501,
            operation: .start,
            log: MacOSKubeadmLog(debugEnabled: false)
        )

        let plist = try #require(capturedPlist)
        #expect(plist["LimitLoadToSessionType"] as? String == "Background")
        #expect(plist["KeepAlive"] == nil)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(
            plist["EnvironmentVariables"] as? [String: String] == [
                "HOME": "/Users/service",
                "LOGNAME": "service",
                "USER": "service",
            ])
        let programArguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(programArguments.contains("execute-container-system"))
        #expect(programArguments.contains("start"))
        #expect(launchctl.domainPrintCount == 2)
        #expect(launchctl.commands.contains(["bootstrap", "user/501"]))
        #expect(!launchctl.commands.contains(["bootstrap", "gui/501"]))
        #expect(launchctl.commands.contains { $0.count == 3 && $0[0] == "bootstrap" && $0[1] == "user/501" })
        #expect(launchctl.commands.contains { $0.first == "bootout" && $0[1].hasPrefix("user/501/") })
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test func guiMigrationStopsAquaBeforeStartingBackground() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var invocations: [(session: String, operation: String)] = []
        let launchctl = LaunchctlHarness(guiDomainAvailable: true)
        launchctl.onAgentBootstrap = { plist in
            let arguments = try #require(plist["ProgramArguments"] as? [String])
            invocations.append(
                (
                    session: try value(after: "--expected-session-type", in: arguments),
                    operation: try value(after: "--operation", in: arguments)
                ))
            try writeCompletion(from: plist, status: 0)
        }

        try MacOSKubeadmContainerSystemOperationRunner(
            dependencies: makeOperationDependencies(
                operationRoot: directory.path,
                launchctl: launchctl.run
            )
        ).run(
            userID: 501,
            operation: .start,
            log: MacOSKubeadmLog(debugEnabled: false)
        )

        #expect(invocations.count == 2)
        #expect(invocations[0].session == "Aqua")
        #expect(invocations[0].operation == "stop")
        #expect(invocations[1].session == "Background")
        #expect(invocations[1].operation == "start")
        let guiBootstrap = try #require(
            launchctl.commands.firstIndex { $0.count == 3 && $0[0] == "bootstrap" && $0[1] == "gui/501" }
        )
        let backgroundBootstrap = try #require(
            launchctl.commands.firstIndex { $0.count == 3 && $0[0] == "bootstrap" && $0[1] == "user/501" }
        )
        #expect(guiBootstrap < backgroundBootstrap)
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test func guiMigrationFailureBlocksBackgroundStart() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchctl = LaunchctlHarness(guiDomainAvailable: true)
        launchctl.onAgentBootstrap = { plist in
            let arguments = try #require(plist["ProgramArguments"] as? [String])
            let session = try value(after: "--expected-session-type", in: arguments)
            #expect(session == "Aqua")
            try writeCompletion(from: plist, status: 1, error: "legacy GUI services remain")
        }

        #expect(throws: (any Error).self) {
            try MacOSKubeadmContainerSystemOperationRunner(
                dependencies: makeOperationDependencies(
                    operationRoot: directory.path,
                    launchctl: launchctl.run
                )
            ).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
        }
        #expect(launchctl.agentBootstrapCount == 1)
        #expect(
            !launchctl.commands.contains {
                $0.count == 3 && $0[0] == "bootstrap" && $0[1] == "user/501"
            }
        )
    }

    @Test func completionIsAcceptedOnlyAfterTheAgentExits() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchctl = LaunchctlHarness()
        launchctl.servicePrintOutputSequence = [
            "state = running\nruns = 1",
            "state = not running\nruns = 1\nlast exit code = 0",
        ]
        launchctl.onAgentBootstrap = { plist in
            try writeCompletion(from: plist, status: 0)
        }

        try MacOSKubeadmContainerSystemOperationRunner(
            dependencies: makeOperationDependencies(
                operationRoot: directory.path,
                launchctl: launchctl.run
            )
        ).run(
            userID: 501,
            operation: .start,
            log: MacOSKubeadmLog(debugEnabled: false)
        )

        #expect(launchctl.servicePrintOutputSequence.isEmpty)
    }

    @Test func signalExitWithoutCompletionFailsImmediately() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchctl = LaunchctlHarness()
        launchctl.bootstrappedServiceOutputOverride = "state = not running\nruns = 1\njob state = exited"
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run,
            completionTimeout: 60
        )

        do {
            try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
            Issue.record("expected signal exit failure")
        } catch MacOSKubeadmError.preflightFailed(let message) {
            #expect(message.contains("exited before writing a valid completion"))
        }
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test func backgroundDispatcherFailsWhenUserDomainCannotBeVerified() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchctl = LaunchctlHarness(
            domainAvailable: false,
            domainBecomesAvailable: false,
            domainBootstrapStatus: 55
        )
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run
        )

        do {
            try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
            Issue.record("expected user domain verification to fail")
        } catch MacOSKubeadmError.preflightFailed(let message) {
            #expect(message.contains("cannot establish launchd domain user/501"))
        }
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test func backgroundDispatcherPropagatesStructuredFailureAndCleansAgent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchctl = LaunchctlHarness()
        launchctl.onAgentBootstrap = { plist in
            try writeCompletion(from: plist, status: 64, error: "start failed")
        }
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run
        )

        do {
            try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
            Issue.record("expected structured operation failure")
        } catch MacOSKubeadmError.commandFailed(_, let status, let output) {
            #expect(status == 64)
            #expect(output == "start failed")
        }
        #expect(launchctl.bootoutCount == 1)
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test func backgroundDispatcherRejectsMismatchedCompletionContext() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchctl = LaunchctlHarness()
        launchctl.onAgentBootstrap = { plist in
            try writeCompletion(from: plist, status: 0) {
                $0.managerName = "Aqua"
            }
        }
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run
        )

        do {
            try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
            Issue.record("expected completion context mismatch")
        } catch MacOSKubeadmError.preflightFailed(let message) {
            #expect(message.contains("does not match the requested Background launchd context"))
        }
        #expect(launchctl.bootoutCount == 1)
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test(arguments: [MacOSKubeadmContainerSystemOperation.start, .stop])
    func rootDispatcherKeepsTheExistingSystemDomainPath(
        operation: MacOSKubeadmContainerSystemOperation
    ) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var capturedPlist: [String: Any]?
        let launchctl = LaunchctlHarness(userID: 0, backgroundDomain: "system")
        launchctl.onAgentBootstrap = { plist in
            capturedPlist = plist
            try writeCompletion(from: plist, status: 0)
        }
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            user: { userID in
                #expect(userID == 0)
                return MacOSKubeadmContainerSystemUser(name: "root", homeDirectory: "/var/root")
            },
            launchctl: launchctl.run
        )

        try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
            userID: 0,
            operation: operation,
            log: MacOSKubeadmLog(debugEnabled: false)
        )

        let plist = try #require(capturedPlist)
        #expect(plist["LimitLoadToSessionType"] == nil)
        #expect(launchctl.commands.contains { $0.count == 3 && $0[0] == "bootstrap" && $0[1] == "system" })
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test func backgroundExecutorRequiresMatchingUIDsAndSession() throws {
        struct Scenario {
            var actualUserID: uid_t
            var managerUserID: Int
            var managerName: String
        }
        let scenarios = [
            Scenario(actualUserID: 502, managerUserID: 501, managerName: "Background"),
            Scenario(actualUserID: 501, managerUserID: 502, managerName: "Background"),
            Scenario(actualUserID: 501, managerUserID: 501, managerName: "Aqua"),
        ]

        for scenario in scenarios {
            var didRunContainer = false
            var completion: MacOSKubeadmContainerSystemCompletion?
            let dependencies = MacOSKubeadmContainerSystemExecutorDependencies(
                effectiveUserID: { scenario.actualUserID },
                managerName: { scenario.managerName },
                managerUserID: { scenario.managerUserID },
                runCommand: { _ in
                    didRunContainer = true
                    return ""
                },
                managedServices: { [] },
                writeCompletion: { value, _ in completion = value }
            )

            #expect(throws: (any Error).self) {
                try MacOSKubeadmContainerSystemExecutor(dependencies: dependencies).run(
                    userID: 501,
                    operation: .start,
                    operationID: "request-1",
                    completionPath: "/tmp/completion",
                    log: MacOSKubeadmLog(debugEnabled: false)
                )
            }
            #expect(!didRunContainer)
            #expect(completion?.status == 1)
            #expect(completion?.actualUserID == Int(scenario.actualUserID))
            #expect(completion?.managerUserID == scenario.managerUserID)
            #expect(completion?.managerName == scenario.managerName)
        }
    }

    @Test func backgroundExecutorWritesStructuredSuccess() throws {
        var command: [String]?
        var completion: MacOSKubeadmContainerSystemCompletion?
        let dependencies = MacOSKubeadmContainerSystemExecutorDependencies(
            effectiveUserID: { 501 },
            managerName: { "Background" },
            managerUserID: { 501 },
            runCommand: { arguments in
                command = arguments
                return "started"
            },
            managedServices: { [] },
            writeCompletion: { value, _ in completion = value }
        )

        try MacOSKubeadmContainerSystemExecutor(dependencies: dependencies).run(
            userID: 501,
            operation: .start,
            operationID: "request-1",
            completionPath: "/tmp/completion",
            log: MacOSKubeadmLog(debugEnabled: false)
        )

        #expect(command == ["/usr/local/bin/container", "system", "start"])
        #expect(completion?.status == 0)
        #expect(completion?.actualUserID == 501)
        #expect(completion?.managerUserID == 501)
        #expect(completion?.managerName == "Background")
    }

    @Test func aquaMigrationExecutorAcceptsOnlyStop() throws {
        var command: [String]?
        var completion: MacOSKubeadmContainerSystemCompletion?
        let dependencies = MacOSKubeadmContainerSystemExecutorDependencies(
            effectiveUserID: { 501 },
            managerName: { "Aqua" },
            managerUserID: { 501 },
            runCommand: { arguments in
                command = arguments
                return ""
            },
            managedServices: { [] },
            writeCompletion: { value, _ in completion = value }
        )

        try MacOSKubeadmContainerSystemExecutor(dependencies: dependencies).run(
            userID: 501,
            operation: .stop,
            operationID: "request-1",
            completionPath: "/tmp/completion",
            expectedManagerName: "Aqua",
            log: MacOSKubeadmLog(debugEnabled: false)
        )
        #expect(command == ["/usr/local/bin/container", "system", "stop"])
        #expect(completion?.status == 0)
        #expect(completion?.managerName == "Aqua")

        #expect(throws: (any Error).self) {
            try MacOSKubeadmContainerSystemExecutor(dependencies: dependencies).run(
                userID: 501,
                operation: .start,
                operationID: "request-2",
                completionPath: "/tmp/completion",
                expectedManagerName: "Aqua",
                log: MacOSKubeadmLog(debugEnabled: false)
            )
        }
    }

    @Test func stopExecutorFailsWhenManagedServicesRemain() throws {
        var completion: MacOSKubeadmContainerSystemCompletion?
        let dependencies = MacOSKubeadmContainerSystemExecutorDependencies(
            effectiveUserID: { 501 },
            managerName: { "Background" },
            managerUserID: { 501 },
            runCommand: { _ in "" },
            managedServices: { ["com.apple.container.apiserver"] },
            writeCompletion: { value, _ in completion = value }
        )

        #expect(throws: (any Error).self) {
            try MacOSKubeadmContainerSystemExecutor(dependencies: dependencies).run(
                userID: 501,
                operation: .stop,
                operationID: "request-1",
                completionPath: "/tmp/completion",
                log: MacOSKubeadmLog(debugEnabled: false)
            )
        }
        #expect(completion?.status == 1)
        #expect(completion?.error?.contains("com.apple.container.apiserver") == true)
    }

    @Test func backgroundExecutorPreservesContainerExitStatus() throws {
        var completion: MacOSKubeadmContainerSystemCompletion?
        let dependencies = MacOSKubeadmContainerSystemExecutorDependencies(
            effectiveUserID: { 501 },
            managerName: { "Background" },
            managerUserID: { 501 },
            runCommand: { _ in
                throw MacOSKubeadmError.commandFailed(
                    command: "container system stop",
                    status: 64,
                    output: "failed"
                )
            },
            managedServices: { [] },
            writeCompletion: { value, _ in completion = value }
        )

        #expect(throws: (any Error).self) {
            try MacOSKubeadmContainerSystemExecutor(dependencies: dependencies).run(
                userID: 501,
                operation: .stop,
                operationID: "request-1",
                completionPath: "/tmp/completion",
                log: MacOSKubeadmLog(debugEnabled: false)
            )
        }
        #expect(completion?.status == 64)
    }

    @Test func backgroundDispatcherTimesOutThenRemovesTheAgentAndFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock: TimeInterval = 0
        let launchctl = LaunchctlHarness()
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run,
            monotonicTime: { clock },
            sleep: { clock += $0 },
            completionTimeout: 0.01,
            cleanupTimeout: 0.01,
            pollInterval: 0.001
        )

        do {
            try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
            Issue.record("expected operation timeout")
        } catch MacOSKubeadmError.timedOut(let message) {
            #expect(message.contains("container system start"))
        }
        #expect(launchctl.bootoutCount == 1)
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test func backgroundDispatcherPreservesFilesWhenAgentCannotBeRemoved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock: TimeInterval = 0
        let launchctl = LaunchctlHarness(serviceCanBeRemoved: false)
        launchctl.onAgentBootstrap = { plist in
            try writeCompletion(from: plist, status: 0)
        }
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run,
            monotonicTime: { clock },
            sleep: { clock += $0 },
            cleanupTimeout: 0.01,
            pollInterval: 0.001
        )

        #expect(throws: (any Error).self) {
            try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
        }
        let preserved = try transientOperationArtifacts(in: directory)
        #expect(preserved.count == 2)
        #expect(preserved.contains("501.background.plist"))
        #expect(preserved.contains("501.background.completion.json"))
    }

    @Test func nextDispatchRemovesAnOrphanedAgentBeforeStarting() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldPlist = directory.appendingPathComponent("501.background.plist")
        let oldCompletion = directory.appendingPathComponent("501.background.completion.json")
        try "old plist".write(to: oldPlist, atomically: true, encoding: .utf8)
        try "old completion".write(to: oldCompletion, atomically: true, encoding: .utf8)

        let launchctl = LaunchctlHarness(serviceLoaded: true)
        launchctl.onAgentBootstrap = { plist in
            #expect(!((try? String(contentsOf: oldPlist, encoding: .utf8)) == "old plist"))
            #expect(!((try? String(contentsOf: oldCompletion, encoding: .utf8)) == "old completion"))
            try writeCompletion(from: plist, status: 0)
        }
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run,
            operationID: { "new-request" }
        )

        try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
            userID: 501,
            operation: .stop,
            log: MacOSKubeadmLog(debugEnabled: false)
        )

        let firstBootout = try #require(launchctl.commands.firstIndex { $0.first == "bootout" })
        let bootstrap = try #require(launchctl.commands.firstIndex { $0.count == 3 && $0.first == "bootstrap" })
        #expect(firstBootout < bootstrap)
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test func nextDispatchRemovesAnOrphanedAgentWithoutArtifacts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchctl = LaunchctlHarness(serviceLoaded: true)
        launchctl.onAgentBootstrap = { plist in
            try writeCompletion(from: plist, status: 0)
        }
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run
        )

        try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
            userID: 501,
            operation: .start,
            log: MacOSKubeadmLog(debugEnabled: false)
        )

        let firstBootout = try #require(launchctl.commands.firstIndex { $0.first == "bootout" })
        let bootstrap = try #require(
            launchctl.commands.firstIndex { $0.count == 3 && $0.first == "bootstrap" }
        )
        #expect(firstBootout < bootstrap)
        #expect(launchctl.bootoutCount == 2)
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
    }

    @Test func cleanupRemovesSystemBackgroundAndGUIOperations() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifacts = [
            "0.lock",
            "0.system.plist",
            "0.system.completion.json",
            "501.lock",
            "501.background.plist",
            "501.background.completion.json",
            "501.legacy-gui.plist",
            "501.legacy-gui.completion.json",
        ]
        for name in artifacts {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let launchctl = LaunchctlHarness()
        let targets = [
            "system/\(MacOSKubeadmContainerSystem.operationLaunchdLabel(userID: 0))",
            "user/501/\(MacOSKubeadmContainerSystem.operationLaunchdLabel(userID: 501))",
            "gui/501/\(MacOSKubeadmContainerSystem.legacyGUIOperationLaunchdLabel(userID: 501))",
        ]
        for target in targets {
            launchctl.loadService(target)
        }
        let runner = MacOSKubeadmContainerSystemOperationRunner(
            dependencies: makeOperationDependencies(
                operationRoot: directory.path,
                launchctl: launchctl.run
            )
        )

        try runner.cleanupAll(log: MacOSKubeadmLog(debugEnabled: false))

        for target in targets {
            #expect(launchctl.commands.contains(["bootout", target]))
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == [".global.lock"])
    }

    @Test func operationRootSymlinkIsRejected() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        let link = parent.appendingPathComponent("operations", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            try MacOSKubeadmContainerSystemOperationRunner(
                dependencies: makeOperationDependencies(
                    operationRoot: link.path,
                    launchctl: LaunchctlHarness().run
                )
            ).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
        }
    }

    @Test func cleanupRejectsUnexpectedArtifacts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("unexpected"))
        let runner = MacOSKubeadmContainerSystemOperationRunner(
            dependencies: makeOperationDependencies(
                operationRoot: directory.path,
                launchctl: LaunchctlHarness().run
            )
        )

        #expect(throws: (any Error).self) {
            try runner.cleanupAll(log: MacOSKubeadmLog(debugEnabled: false))
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unexpected").path))
    }

    @Test func nextDispatchFailsClosedWhenAnOrphanedAgentCannotBeRemoved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldPlist = directory.appendingPathComponent("501.plist")
        let oldCompletion = directory.appendingPathComponent("501.completion.json")
        try "old plist".write(to: oldPlist, atomically: true, encoding: .utf8)
        try "old completion".write(to: oldCompletion, atomically: true, encoding: .utf8)

        var clock: TimeInterval = 0
        let launchctl = LaunchctlHarness(serviceLoaded: true, serviceCanBeRemoved: false)
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run,
            monotonicTime: { clock },
            sleep: { clock += $0 },
            cleanupTimeout: 0.01,
            pollInterval: 0.001
        )

        #expect(throws: (any Error).self) {
            try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
        }

        #expect(launchctl.agentBootstrapCount == 0)
        #expect(try String(contentsOf: oldPlist, encoding: .utf8) == "old plist")
        #expect(try String(contentsOf: oldCompletion, encoding: .utf8) == "old completion")
    }

    @Test func partialBootstrapStillAttemptsExplicitAgentCleanup() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchctl = LaunchctlHarness(agentBootstrapStatus: 5)
        let dependencies = makeOperationDependencies(
            operationRoot: directory.path,
            launchctl: launchctl.run
        )

        #expect(throws: (any Error).self) {
            try MacOSKubeadmContainerSystemOperationRunner(dependencies: dependencies).run(
                userID: 501,
                operation: .start,
                log: MacOSKubeadmLog(debugEnabled: false)
            )
        }
        #expect(launchctl.bootoutCount == 1)
        #expect(try transientOperationArtifacts(in: directory).isEmpty)
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

    private final class LaunchctlHarness {
        var commands: [[String]] = []
        var domainPrintCount = 0
        var bootoutCount = 0
        var agentBootstrapCount = 0
        var onAgentBootstrap: (([String: Any]) throws -> Void)?
        var bootstrappedServiceOutputOverride: String?
        var servicePrintOutputSequence: [String] = []

        private var domainAvailable: Bool
        private let domainBecomesAvailable: Bool
        private let domainBootstrapStatus: Int32
        private let guiDomainAvailable: Bool
        private let userID: Int
        private let backgroundDomain: String
        private var loadedServiceTargets: Set<String>
        private var serviceOutputs: [String: String]
        private let serviceCanBeRemoved: Bool
        private let agentBootstrapStatus: Int32

        init(
            domainAvailable: Bool = true,
            domainBecomesAvailable: Bool = true,
            domainBootstrapStatus: Int32 = 0,
            guiDomainAvailable: Bool = false,
            userID: Int = 501,
            backgroundDomain: String? = nil,
            serviceLoaded: Bool = false,
            serviceCanBeRemoved: Bool = true,
            agentBootstrapStatus: Int32 = 0
        ) {
            self.domainAvailable = domainAvailable
            self.domainBecomesAvailable = domainBecomesAvailable
            self.domainBootstrapStatus = domainBootstrapStatus
            self.guiDomainAvailable = guiDomainAvailable
            self.userID = userID
            self.backgroundDomain = backgroundDomain ?? "user/\(userID)"
            self.loadedServiceTargets =
                serviceLoaded
                ? [
                    "\(backgroundDomain ?? "user/\(userID)")/\(MacOSKubeadmContainerSystem.operationLaunchdLabel(userID: userID))"
                ]
                : []
            self.serviceOutputs = [:]
            self.serviceCanBeRemoved = serviceCanBeRemoved
            self.agentBootstrapStatus = agentBootstrapStatus
        }

        func loadService(_ target: String, output: String = "state = running\nruns = 1") {
            loadedServiceTargets.insert(target)
            serviceOutputs[target] = output
        }

        func run(_ arguments: [String]) throws -> MacOSKubeadmLaunchctlResult {
            commands.append(arguments)
            if arguments == ["print", backgroundDomain] {
                domainPrintCount += 1
                return MacOSKubeadmLaunchctlResult(status: domainAvailable ? 0 : 112, output: "")
            }
            if arguments == ["bootstrap", backgroundDomain] {
                domainAvailable = domainBecomesAvailable
                return MacOSKubeadmLaunchctlResult(status: domainBootstrapStatus, output: "")
            }
            if arguments == ["print", "gui/\(userID)"] {
                return MacOSKubeadmLaunchctlResult(status: guiDomainAvailable ? 0 : 112, output: "")
            }
            if arguments.count == 3, arguments[0] == "bootstrap" {
                agentBootstrapCount += 1
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
                guard
                    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                        as? [String: Any]
                else {
                    throw MacOSKubeadmError.preflightFailed("operation plist is invalid")
                }
                try onAgentBootstrap?(plist)
                let label = try #require(plist["Label"] as? String)
                if agentBootstrapStatus == 0 {
                    let serviceTarget = "\(arguments[1])/\(label)"
                    loadedServiceTargets.insert(serviceTarget)
                    let programArguments = try #require(plist["ProgramArguments"] as? [String])
                    let completionMarker = try #require(programArguments.firstIndex(of: "--completion-path"))
                    let completionPath = programArguments[programArguments.index(after: completionMarker)]
                    let completed = (try? Data(contentsOf: URL(fileURLWithPath: completionPath)))?.isEmpty == false
                    serviceOutputs[serviceTarget] =
                        bootstrappedServiceOutputOverride
                        ?? (completed
                            ? "state = not running\nruns = 1\nlast exit code = 0"
                            : "state = running\nruns = 1")
                }
                return MacOSKubeadmLaunchctlResult(status: agentBootstrapStatus, output: "")
            }
            if arguments.first == "bootout" {
                bootoutCount += 1
                if serviceCanBeRemoved {
                    loadedServiceTargets.remove(arguments[1])
                    serviceOutputs.removeValue(forKey: arguments[1])
                }
                return MacOSKubeadmLaunchctlResult(
                    status: serviceCanBeRemoved ? 0 : 5,
                    output: serviceCanBeRemoved ? "" : "still loaded"
                )
            }
            if arguments.first == "print",
                arguments.count == 2,
                arguments[1].contains(MacOSKubeadmContainerSystem.operationLaunchdLabelPrefix)
                    || arguments[1].contains(MacOSKubeadmContainerSystem.legacyGUIOperationLaunchdLabelPrefix)
            {
                let loaded = loadedServiceTargets.contains(arguments[1])
                let output =
                    if !loaded || servicePrintOutputSequence.isEmpty {
                        serviceOutputs[arguments[1]] ?? ""
                    } else {
                        servicePrintOutputSequence.removeFirst()
                    }
                return MacOSKubeadmLaunchctlResult(
                    status: loaded ? 0 : 113,
                    output: output
                )
            }
            return MacOSKubeadmLaunchctlResult(status: 58, output: "unexpected command")
        }
    }

    private func makeOperationDependencies(
        operationRoot: String,
        effectiveUserID: @escaping () -> uid_t = { 0 },
        user: @escaping (uid_t) -> MacOSKubeadmContainerSystemUser? = { _ in
            MacOSKubeadmContainerSystemUser(name: "service", homeDirectory: "/Users/service")
        },
        launchctl: @escaping ([String]) throws -> MacOSKubeadmLaunchctlResult,
        setOwner: @escaping (Int32, uid_t) throws -> uid_t = { descriptor, userID in
            if userID == geteuid() {
                guard fchown(descriptor, userID, gid_t.max) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return userID
            }
            return geteuid()
        },
        operationID: @escaping () -> String = { "request-1" },
        monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        completionTimeout: TimeInterval = 1,
        cleanupTimeout: TimeInterval = 1,
        pollInterval: TimeInterval = 0.001
    ) -> MacOSKubeadmContainerSystemOperationDependencies {
        MacOSKubeadmContainerSystemOperationDependencies(
            effectiveUserID: effectiveUserID,
            user: user,
            launchctl: launchctl,
            setOwner: setOwner,
            operationID: operationID,
            monotonicTime: monotonicTime,
            sleep: sleep,
            operationRoot: operationRoot,
            operationRootOwnerID: geteuid(),
            completionTimeout: { _ in completionTimeout },
            cleanupTimeout: cleanupTimeout,
            pollInterval: pollInterval
        )
    }

    private func writeCompletion(
        from plist: [String: Any],
        status: Int32,
        error: String? = nil,
        mutate: (inout MacOSKubeadmContainerSystemCompletion) -> Void = { _ in }
    ) throws {
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        let userID = try #require(Int(try value(after: "--container-service-user", in: arguments)))
        let operation = try #require(
            MacOSKubeadmContainerSystemOperation(rawValue: try value(after: "--operation", in: arguments))
        )
        let operationID = try value(after: "--operation-id", in: arguments)
        let completionPath = try value(after: "--completion-path", in: arguments)
        let managerName = try value(after: "--expected-session-type", in: arguments)
        var completion = MacOSKubeadmContainerSystemCompletion(
            operationID: operationID,
            userID: userID,
            operation: operation,
            actualUserID: userID,
            managerUserID: userID,
            managerName: managerName,
            status: status,
            error: error
        )
        mutate(&completion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(completion).write(to: URL(fileURLWithPath: completionPath))
    }

    private func value(after marker: String, in arguments: [String]) throws -> String {
        let index = try #require(arguments.firstIndex(of: marker))
        return arguments[arguments.index(after: index)]
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-macos-kubeadm-existing-user-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func transientOperationArtifacts(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasSuffix(".lock") }
    }

}
