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

#if os(macOS)
import ContainerResource
import Containerization
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import container_runtime_macos

struct MacOSSandboxServiceWaiterTests {
    @Test
    func waitForMissingProcessThrowsNotFound() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)

        do {
            _ = try await service.testingWaitForProcess("missing-process")
            Issue.record("expected wait on unknown process to fail")
        } catch let error as ContainerizationError {
            #expect(error.code == .notFound)
        }
    }

    @Test
    func closeAllSessionsResumesOutstandingWaiters() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(id: "exec-1", config: baseProcessConfiguration())

        let waitTask = Task {
            try await service.testingWaitForProcess("exec-1")
        }
        try await waitUntilWaiterRegistered(service: service, id: "exec-1")

        await service.testingCloseAllSessions()

        let status = try await waitTask.value
        #expect(status.exitCode == 255)
        #expect(await service.testingWaiterCount(for: "exec-1") == 0)

        let snapshot = try await service.testingInspectWorkload("exec-1")
        #expect(snapshot.status == .stopped)
        #expect(snapshot.exitCode == 255)
    }

    @Test
    func timedWaitClearsRegisteredWaiter() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(id: "exec-timeout", config: baseProcessConfiguration())

        do {
            _ = try await service.testingWaitForProcess("exec-timeout", timeout: 1)
            Issue.record("expected timed wait to throw timeout")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
        }

        #expect(await service.testingWaiterCount(for: "exec-timeout") == 0)
    }

    @Test
    func workloadSnapshotReportsStatusExitCodeAndLogPaths() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(
            id: "exec-finished",
            config: baseProcessConfiguration(),
            started: true,
            exitCode: 17
        )

        let snapshot = try await service.testingInspectWorkload("exec-finished")

        #expect(snapshot.id == "exec-finished")
        #expect(snapshot.status == .stopped)
        #expect(snapshot.exitCode == 17)
        #expect(snapshot.startedDate != nil)
        #expect(snapshot.exitedAt != nil)
        #expect(snapshot.stdoutLogPath == tempRoot.appendingPathComponent("workloads/exec-finished/stdout.log").path)
        #expect(snapshot.stderrLogPath == tempRoot.appendingPathComponent("workloads/exec-finished/stderr.log").path)
        #expect(FileManager.default.fileExists(atPath: try #require(snapshot.stdoutLogPath)))
        #expect(FileManager.default.fileExists(atPath: try #require(snapshot.stderrLogPath)))
    }

    @Test
    func internalSessionsAreExcludedFromWorkloadSnapshots() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(
            id: "visible-workload",
            config: baseProcessConfiguration()
        )
        await service.testingAddSession(
            id: "__guest-agent-log__",
            config: baseProcessConfiguration(),
            includeInSnapshots: false
        )

        let snapshots = await service.testingWorkloadSnapshots()

        #expect(snapshots.map(\.id) == ["visible-workload"])
        #expect(await service.testingVisibleSessionCount() == 1)
    }

    @Test
    func workloadInspectUsesExternalIDWhenMappedToInternalSession() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(
            id: "visible-workload",
            config: baseProcessConfiguration(),
            started: true,
            sessionID: "__workload__internal"
        )

        let snapshot = try await service.testingInspectWorkload("visible-workload")

        #expect(await service.testingSessionID(for: "visible-workload") == "__workload__internal")
        #expect(snapshot.id == "visible-workload")
        #expect(snapshot.configuration.processConfiguration.executable == "/bin/sh")
        #expect(snapshot.stdoutLogPath == tempRoot.appendingPathComponent("workloads/visible-workload/stdout.log").path)
    }

    @Test
    func multipleVisibleWorkloadsKeepIndependentState() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(
            id: "exec-a",
            config: makeProcessConfiguration(
                executable: "/bin/echo",
                arguments: ["alpha"]
            ),
            started: true,
            sessionID: "__workload__exec-a"
        )
        await service.testingAddSession(
            id: "exec-b",
            config: makeProcessConfiguration(
                executable: "/usr/bin/env",
                arguments: ["printf", "beta"]
            ),
            started: true,
            sessionID: "__workload__exec-b"
        )

        let snapshots = await service.testingWorkloadSnapshots()
        let snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })

        #expect(snapshots.map(\.id) == ["exec-a", "exec-b"])
        #expect(await service.testingVisibleSessionCount() == 2)
        #expect(await service.testingSessionID(for: "exec-a") == "__workload__exec-a")
        #expect(await service.testingSessionID(for: "exec-b") == "__workload__exec-b")

        let execA = try #require(snapshotsByID["exec-a"])
        let execB = try #require(snapshotsByID["exec-b"])

        #expect(execA.status == .running)
        #expect(execA.configuration.processConfiguration.executable == "/bin/echo")
        #expect(execA.configuration.processConfiguration.arguments == ["alpha"])
        #expect(execB.status == .running)
        #expect(execB.configuration.processConfiguration.executable == "/usr/bin/env")
        #expect(execB.configuration.processConfiguration.arguments == ["printf", "beta"])
    }

    @Test
    func closingSandboxSessionsStopsAllVisibleWorkloadsAndPreservesRecordedExitCodes() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(
            id: "exec-running-a",
            config: makeProcessConfiguration(executable: "/bin/sleep", arguments: ["10"]),
            started: true,
            sessionID: "__workload__exec-running-a"
        )
        await service.testingAddSession(
            id: "exec-running-b",
            config: makeProcessConfiguration(executable: "/bin/sleep", arguments: ["20"]),
            started: true,
            sessionID: "__workload__exec-running-b"
        )
        await service.testingAddSession(
            id: "exec-finished",
            config: makeProcessConfiguration(executable: "/bin/echo", arguments: ["done"]),
            started: true,
            exitCode: 17,
            sessionID: "__workload__exec-finished"
        )

        let waitTaskA = Task {
            try await service.testingWaitForProcess("exec-running-a")
        }
        let waitTaskB = Task {
            try await service.testingWaitForProcess("exec-running-b")
        }
        try await waitUntilWaiterRegistered(service: service, id: "exec-running-a")
        try await waitUntilWaiterRegistered(service: service, id: "exec-running-b")

        await service.testingCloseAllSessions()

        let statusA = try await waitTaskA.value
        let statusB = try await waitTaskB.value

        #expect(statusA.exitCode == 255)
        #expect(statusB.exitCode == 255)
        #expect(await service.testingWaiterCount(for: "exec-running-a") == 0)
        #expect(await service.testingWaiterCount(for: "exec-running-b") == 0)
        #expect(await service.testingSessionID(for: "exec-running-a") == nil)
        #expect(await service.testingSessionID(for: "exec-running-b") == nil)
        #expect(await service.testingSessionID(for: "exec-finished") == nil)

        let runningA = try await service.testingInspectWorkload("exec-running-a")
        let runningB = try await service.testingInspectWorkload("exec-running-b")
        let finished = try await service.testingInspectWorkload("exec-finished")

        #expect(runningA.status == .stopped)
        #expect(runningA.exitCode == 255)
        #expect(runningB.status == .stopped)
        #expect(runningB.exitCode == 255)
        #expect(finished.status == .stopped)
        #expect(finished.exitCode == 17)
    }

    @Test
    func persistSandboxMetadataWritesSandboxAndInitWorkloadConfiguration() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        var containerConfiguration = try baseContainerConfiguration()
        let layout = MacOSSandboxLayout(root: tempRoot)

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let readonlySource = tempRoot.appendingPathComponent("config.env")
        try Data("FOO=bar\n".utf8).write(to: readonlySource)
        containerConfiguration.readOnlyFiles = [.init(source: readonlySource.path, destination: "/etc/container.env")]

        try await service.testingPersistSandboxMetadata(containerConfiguration)

        let sandboxData = try Data(contentsOf: layout.sandboxConfigurationURL)
        let workloadData = try Data(contentsOf: layout.workloadConfigurationURL(id: containerConfiguration.id))
        let sandbox = try JSONDecoder().decode(SandboxConfiguration.self, from: sandboxData)
        let workload = try JSONDecoder().decode(WorkloadConfiguration.self, from: workloadData)
        let readonlyEntries = try MacOSReadOnlyFileInjectionStore.load(from: layout)

        #expect(sandbox.id == containerConfiguration.id)
        #expect(sandbox.image.reference == containerConfiguration.image.reference)
        #expect(sandbox.readOnlyFiles == [.init(source: readonlySource.path, destination: "/etc/container.env")])
        #expect(workload.id == containerConfiguration.id)
        #expect(workload.processConfiguration.executable == containerConfiguration.initProcess.executable)
        #expect(readonlyEntries.count == 1)
        #expect(readonlyEntries[0].destination == "/etc/container.env")
    }

    @Test
    func persistedWorkloadConfigurationOverridesSessionFallbackInSnapshot() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        let sessionConfig = baseProcessConfiguration()
        let persistedConfig = ProcessConfiguration(
            executable: "/usr/bin/env",
            arguments: ["printf", "hello"],
            environment: ["FOO=bar"],
            workingDirectory: "/tmp",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        try await service.testingPersistWorkloadConfiguration(
            .init(id: "exec-with-meta", processConfiguration: persistedConfig)
        )
        await service.testingAddSession(id: "exec-with-meta", config: sessionConfig)

        let snapshot = try await service.testingInspectWorkload("exec-with-meta")

        #expect(snapshot.configuration.processConfiguration.executable == "/usr/bin/env")
        #expect(snapshot.configuration.processConfiguration.workingDirectory == "/tmp")
        #expect(snapshot.configuration.processConfiguration.environment == ["FOO=bar"])
    }
}

private func makeSandboxService(root: URL) -> MacOSSandboxService {
    MacOSSandboxService(
        root: root,
        connection: nil,
        log: Logger(label: "MacOSSandboxServiceWaiterTests")
    )
}

private func makeTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func baseProcessConfiguration() -> ProcessConfiguration {
    makeProcessConfiguration(executable: "/bin/sh")
}

private func makeProcessConfiguration(
    executable: String,
    arguments: [String] = [],
    environment: [String] = [],
    workingDirectory: String = "/",
    terminal: Bool = false
) -> ProcessConfiguration {
    ProcessConfiguration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        terminal: terminal,
        user: .id(uid: 0, gid: 0)
    )
}

private func baseContainerConfiguration() throws -> ContainerConfiguration {
    let imageJSON = """
        {
          "reference": "example/macos:latest",
          "descriptor": {
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "digest": "sha256:test",
            "size": 1
          }
        }
        """
    let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
    var configuration = ContainerConfiguration(
        id: "sandbox-under-test",
        image: image,
        process: baseProcessConfiguration()
    )
    configuration.runtimeHandler = "container-runtime-macos"
    configuration.platform = .init(arch: "arm64", os: "darwin")
    return configuration
}

private func waitUntilWaiterRegistered(
    service: MacOSSandboxService,
    id: String,
    attempts: Int = 100
) async throws {
    for _ in 0..<attempts {
        if await service.testingWaiterCount(for: id) > 0 {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    Issue.record("timed out waiting for waiter registration on \(id)")
}
#endif
