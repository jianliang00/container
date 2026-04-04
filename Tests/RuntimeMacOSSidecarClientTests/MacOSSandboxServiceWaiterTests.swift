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
import Darwin
import Foundation
import Logging
import RuntimeMacOSSidecarShared
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
        let layout = MacOSSandboxLayout(root: tempRoot)
        #expect(snapshot.stdoutLogPath == layout.workloadStdoutLogURL(id: "exec-finished").path)
        #expect(snapshot.stderrLogPath == layout.workloadStderrLogURL(id: "exec-finished").path)
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
    func createProcessKeepsExecSessionsOutOfPersistedWorkloadState() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        try await service.testingPrepareSandbox(baseContainerConfiguration())

        let processID = "exec-hidden"
        try await service.testingCreateProcess(
            processID,
            config: makeProcessConfiguration(executable: "/usr/bin/id", arguments: ["-u"])
        )

        let layout = MacOSSandboxLayout(root: tempRoot)
        let snapshotIDs = (await service.testingWorkloadSnapshots()).map(\.id)
        #expect(!FileManager.default.fileExists(atPath: layout.workloadConfigurationURL(id: processID).path))
        #expect(!snapshotIDs.contains(processID))

        do {
            _ = try await service.testingInspectWorkload(processID)
            Issue.record("expected hidden exec session to stay out of workload inspect")
        } catch let error as ContainerizationError {
            #expect(error.code == .notFound)
        }
    }

    @Test
    func processHandlersUseExternalProcessIdentifiersWithoutCreatingWorkloads() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        try await service.testingPrepareSandbox(baseContainerConfiguration())

        let socketPath = tempRoot.appendingPathComponent("exec-sidecar.sock").path
        let server = try RecordingExecSidecarServer(
            socketPath: socketPath,
            exitOnSignalProcessIDs: ["exec-live"]
        )
        defer { server.stop() }
        server.start()

        await service.testingInstallSidecarClient(socketPath: socketPath)

        let processID = "exec-live"
        try await service.testingCreateProcess(
            processID,
            config: makeProcessConfiguration(executable: "/bin/sleep", arguments: ["5"])
        )
        try await service.testingStartProcess(processID)
        try await service.testingResizeExternalProcess(processID, width: 120, height: 40)
        try await service.testingSignalExternalProcess(processID, signal: SIGTERM)

        let status = try await service.testingWaitExternalProcess(processID)

        server.stop()
        try server.waitForCompletion()

        #expect(status.exitCode == 0)
        let processStillExists = await service.testingExternalProcessExists(processID)
        #expect(!processStillExists)

        let requests = server.recordedRequests()
        let sawStart = requests.contains { $0.method == .processStart && $0.processID == processID }
        let sawResize = requests.contains {
            $0.method == .processResize && $0.processID == processID && $0.width == 120 && $0.height == 40
        }
        let sawSignal = requests.contains {
            $0.method == .processSignal && $0.processID == processID && $0.signal == SIGTERM
        }
        let sawInternalWorkloadID = requests.contains { $0.processID == "__workload__\(processID)" }
        #expect(sawStart)
        #expect(sawResize)
        #expect(sawSignal)
        #expect(!sawInternalWorkloadID)
        let snapshotIDs = (await service.testingWorkloadSnapshots()).map(\.id)
        #expect(!snapshotIDs.contains(processID))
    }

    @Test
    func externalProcessStartDoesNotRetryNonTransientSidecarFailure() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        try await service.testingPrepareSandbox(baseContainerConfiguration())

        let processID = "exec-missing"
        let socketPath = "/tmp/exec-sidecar-failure-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingExecSidecarServer(
            socketPath: socketPath,
            processStartFailures: [
                processID: .init(
                    code: "invalidArgument",
                    message: """
                        guest-agent failed to start process \(processID): \
                        failed to start process: NSPOSIXErrorDomain Code=2 \
                        "The operation couldn’t be completed. No such file or directory"
                        """
                )
            ]
        )
        defer { server.stop() }
        server.start()

        await service.testingInstallSidecarClient(socketPath: socketPath)
        try await service.testingCreateProcess(
            processID,
            config: makeProcessConfiguration(executable: "/path/does/not/exist")
        )

        do {
            try await service.testingStartProcess(processID)
            Issue.record("expected startProcess to fail")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
            #expect(error.message.contains("No such file or directory"))
        }

        server.stop()
        try server.waitForCompletion()

        let startRequests = server.recordedRequests().filter {
            $0.method == .processStart && $0.processID == processID
        }
        #expect(startRequests.count == 1)
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
        let layout = MacOSSandboxLayout(root: tempRoot)
        #expect(snapshot.stdoutLogPath == layout.workloadStdoutLogURL(id: "visible-workload").path)
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
        #expect(sandbox.persistedSchemaVersion == SandboxConfiguration.schemaVersion)
        #expect(sandbox.image.reference == containerConfiguration.image.reference)
        #expect(sandbox.readOnlyFiles == [.init(source: readonlySource.path, destination: "/etc/container.env")])
        #expect(workload.id == containerConfiguration.id)
        #expect(workload.persistedSchemaVersion == WorkloadConfiguration.schemaVersion)
        #expect(workload.processConfiguration.executable == containerConfiguration.initProcess.executable)
        #expect(workload.injectionState == .notRequired)
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

    @Test
    func persistedImageBackedWorkloadConfigurationSurvivesSnapshotRebuild() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        let persistedConfig = WorkloadConfiguration(
            id: "exec-image-backed",
            processConfiguration: baseProcessConfiguration(),
            workloadImageReference: "registry.local/example/workload:latest",
            workloadImageDigest: "sha256:workload",
            guestPayloadPath: "/var/lib/container/workloads/exec-image-backed/rootfs",
            guestMetadataPath: "/var/lib/container/workloads/exec-image-backed/meta.json",
            injectionState: .injected
        )

        try await service.testingPersistWorkloadConfiguration(persistedConfig)
        await service.testingAddSession(id: "exec-image-backed", config: baseProcessConfiguration())

        let snapshot = try await service.testingInspectWorkload("exec-image-backed")

        #expect(snapshot.configuration.workloadImageReference == persistedConfig.workloadImageReference)
        #expect(snapshot.configuration.workloadImageDigest == persistedConfig.workloadImageDigest)
        #expect(snapshot.configuration.guestPayloadPath == persistedConfig.guestPayloadPath)
        #expect(snapshot.configuration.guestMetadataPath == persistedConfig.guestMetadataPath)
        #expect(snapshot.configuration.injectionState == .injected)
    }

    @Test
    func coldBootRecoveryResetsInjectedImageBackedWorkloadToPending() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        let persistedConfig = WorkloadConfiguration(
            id: "exec-image-cold-boot",
            processConfiguration: baseProcessConfiguration(),
            workloadImageReference: "registry.local/example/workload:latest",
            workloadImageDigest: "sha256:workload",
            guestPayloadPath: "/var/lib/container/workloads/exec-image-cold-boot/rootfs",
            guestMetadataPath: "/var/lib/container/workloads/exec-image-cold-boot/meta.json",
            injectionState: .injected
        )

        try await service.testingPersistWorkloadConfiguration(persistedConfig)
        try await service.testingPrepareSandbox(try baseContainerConfiguration(), state: "created")

        let snapshot = try await service.testingInspectWorkload("exec-image-cold-boot")

        #expect(snapshot.configuration.guestPayloadPath == persistedConfig.guestPayloadPath)
        #expect(snapshot.configuration.guestMetadataPath == persistedConfig.guestMetadataPath)
        #expect(snapshot.configuration.injectionState == .pending)
    }

    @Test
    func warmRecoveryKeepsInjectedImageBackedWorkloadInjected() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        let persistedConfig = WorkloadConfiguration(
            id: "exec-image-warm-recovery",
            processConfiguration: baseProcessConfiguration(),
            workloadImageReference: "registry.local/example/workload:latest",
            workloadImageDigest: "sha256:workload",
            guestPayloadPath: "/var/lib/container/workloads/exec-image-warm-recovery/rootfs",
            guestMetadataPath: "/var/lib/container/workloads/exec-image-warm-recovery/meta.json",
            injectionState: .injected
        )

        try await service.testingPersistWorkloadConfiguration(persistedConfig)
        try await service.testingPrepareSandbox(try baseContainerConfiguration(), state: "running")

        let snapshot = try await service.testingInspectWorkload("exec-image-warm-recovery")

        #expect(snapshot.configuration.guestPayloadPath == persistedConfig.guestPayloadPath)
        #expect(snapshot.configuration.guestMetadataPath == persistedConfig.guestMetadataPath)
        #expect(snapshot.configuration.injectionState == .injected)
    }

    @Test
    func persistingImageBackedWorkloadFillsDefaultGuestPathsAndPendingInjection() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        let persistedConfig = WorkloadConfiguration(
            id: "exec-image-defaulted",
            processConfiguration: baseProcessConfiguration(),
            workloadImageReference: "registry.local/example/workload:latest",
            workloadImageDigest: "sha256:workload"
        )
        let layout = MacOSSandboxLayout(root: tempRoot)

        try await service.testingPersistWorkloadConfiguration(persistedConfig)

        let workloadData = try Data(contentsOf: layout.workloadConfigurationURL(id: persistedConfig.id))
        let workload = try JSONDecoder().decode(WorkloadConfiguration.self, from: workloadData)

        #expect(workload.workloadImageReference == persistedConfig.workloadImageReference)
        #expect(workload.workloadImageDigest == persistedConfig.workloadImageDigest)
        #expect(workload.guestPayloadPath == "/var/lib/container/workloads/exec-image-defaulted/rootfs")
        #expect(workload.guestMetadataPath == "/var/lib/container/workloads/exec-image-defaulted/meta.json")
        #expect(workload.injectionState == .pending)
    }

    @Test
    func bootedSandboxStateReportsRunningForInspect() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        try await service.testingPrepareSandbox(try baseContainerConfiguration(), state: "booted")

        let snapshot = try await service.testingStateSnapshot()

        #expect(snapshot.status == .running)
        #expect(snapshot.configuration?.id == "sandbox-under-test")
        #expect(snapshot.workloads.contains(where: { $0.id == "sandbox-under-test" }))
    }

    @Test
    func sandboxEventLogExcludesWorkloadStdoutAndStderr() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        try await service.testingPrepareSandbox(try baseContainerConfiguration(), state: "booted")
        try await service.testingOpenLogs()
        await service.testingAddSession(
            id: "exec-logs",
            config: baseProcessConfiguration(),
            started: true,
            sessionID: "__workload__exec-logs"
        )

        await service.handleSidecarEvent(
            MacOSSidecarEvent(
                event: .processStdout,
                processID: "__workload__exec-logs",
                data: Data("hello stdout\n".utf8)
            )
        )
        await service.handleSidecarEvent(
            MacOSSidecarEvent(
                event: .processStderr,
                processID: "__workload__exec-logs",
                data: Data("hello stderr\n".utf8)
            )
        )

        let workload = try await service.testingInspectWorkload("exec-logs")
        let sandboxLog = try String(contentsOfFile: await service.testingContainerLogPath(), encoding: .utf8)
        let stdoutLog = try String(contentsOfFile: try #require(workload.stdoutLogPath), encoding: .utf8)
        let stderrLog = try String(contentsOfFile: try #require(workload.stderrLogPath), encoding: .utf8)

        #expect(stdoutLog.contains("hello stdout"))
        #expect(stderrLog.contains("hello stderr"))
        #expect(!sandboxLog.contains("hello stdout"))
        #expect(!sandboxLog.contains("hello stderr"))
    }

    @Test
    func workloadAttachFansOutLiveOutputWithoutReplay() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(
            id: "exec-attach-fanout",
            config: baseProcessConfiguration(),
            started: true,
            sessionID: "__workload__exec-attach-fanout"
        )

        await service.handleSidecarEvent(
            MacOSSidecarEvent(
                event: .processStdout,
                processID: "__workload__exec-attach-fanout",
                data: Data("before-attach\n".utf8)
            )
        )

        let readerA = Pipe()
        let readerB = Pipe()
        try await service.testingAttachWorkload(
            "exec-attach-fanout",
            attachmentID: "reader-a",
            options: .init(),
            stdio: [nil, readerA.fileHandleForWriting, nil]
        )
        try await service.testingAttachWorkload(
            "exec-attach-fanout",
            attachmentID: "reader-b",
            options: .init(),
            stdio: [nil, readerB.fileHandleForWriting, nil]
        )

        let replayA = await waitForPipeChunk(readerA.fileHandleForReading, timeout: .milliseconds(150))
        let replayB = await waitForPipeChunk(readerB.fileHandleForReading, timeout: .milliseconds(150))
        #expect(replayA == nil)
        #expect(replayB == nil)

        let readA = Task {
            await waitForPipeChunk(readerA.fileHandleForReading)
        }
        let readB = Task {
            await waitForPipeChunk(readerB.fileHandleForReading)
        }

        await service.handleSidecarEvent(
            MacOSSidecarEvent(
                event: .processStderr,
                processID: "__workload__exec-attach-fanout",
                data: Data("after-attach\n".utf8)
            )
        )

        let dataA = try #require(await readA.value)
        let dataB = try #require(await readB.value)
        #expect(String(data: dataA, encoding: .utf8) == "after-attach\n")
        #expect(String(data: dataB, encoding: .utf8) == "after-attach\n")
    }

    @Test
    func workloadAttachAllowsSingleControllerAndExtraReaders() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(
            id: "exec-attach-controller",
            config: baseProcessConfiguration(),
            started: true,
            sessionID: "__workload__exec-attach-controller"
        )

        let controllerPipe = Pipe()
        try await service.testingAttachWorkload(
            "exec-attach-controller",
            attachmentID: "controller",
            options: .init(takesControl: true),
            stdio: [nil, controllerPipe.fileHandleForWriting, nil]
        )

        let readerPipe = Pipe()
        try await service.testingAttachWorkload(
            "exec-attach-controller",
            attachmentID: "reader",
            options: .init(),
            stdio: [nil, readerPipe.fileHandleForWriting, nil]
        )

        #expect(await service.testingControllerAttachmentID(for: "exec-attach-controller") == "controller")
        #expect(await service.testingAttachmentIDs(for: "exec-attach-controller") == ["controller", "reader"])

        do {
            try await service.testingAttachWorkload(
                "exec-attach-controller",
                attachmentID: "controller-2",
                options: .init(takesControl: true),
                stdio: [nil, nil, nil]
            )
            Issue.record("expected second controlling attachment to fail")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
        }
    }

    @Test
    func workloadAttachControlOperationsRequireControllerAndDetachReleasesIt() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(
            id: "exec-attach-control",
            config: baseProcessConfiguration(),
            started: true,
            sessionID: "__workload__exec-attach-control"
        )

        let socketPath = tempRoot.appendingPathComponent("a.sock").path
        let server = try RecordingExecSidecarServer(socketPath: socketPath)
        defer { server.stop() }
        server.start()

        await service.testingInstallSidecarClient(socketPath: socketPath)

        let readerPipe = Pipe()
        try await service.testingAttachWorkload(
            "exec-attach-control",
            attachmentID: "reader",
            options: .init(),
            stdio: [nil, readerPipe.fileHandleForWriting, nil]
        )

        do {
            try await service.testingSignalWorkload(
                "exec-attach-control",
                signal: SIGUSR1,
                attachmentID: "reader"
            )
            Issue.record("expected output-only attachment signal to fail")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
        }

        try await service.testingAttachWorkload(
            "exec-attach-control",
            attachmentID: "controller-a",
            options: .init(takesControl: true),
            stdio: [nil, nil, nil]
        )
        try await service.testingResizeWorkload(
            "exec-attach-control",
            width: 120,
            height: 40,
            attachmentID: "controller-a"
        )
        try await service.testingSignalWorkload(
            "exec-attach-control",
            signal: SIGUSR1,
            attachmentID: "controller-a"
        )

        try await service.testingDetachWorkloadAttachment("controller-a", from: "exec-attach-control")
        #expect(await service.testingControllerAttachmentID(for: "exec-attach-control") == nil)

        try await service.testingAttachWorkload(
            "exec-attach-control",
            attachmentID: "controller-b",
            options: .init(takesControl: true),
            stdio: [nil, nil, nil]
        )
        #expect(await service.testingControllerAttachmentID(for: "exec-attach-control") == "controller-b")

        server.stop()
        try server.waitForCompletion()

        let requests = server.recordedRequests()
        let sawResize = requests.contains {
            $0.method == .processResize && $0.processID == "__workload__exec-attach-control" && $0.width == 120 && $0.height == 40
        }
        let sawSignal = requests.contains {
            $0.method == .processSignal && $0.processID == "__workload__exec-attach-control" && $0.signal == SIGUSR1
        }
        #expect(sawResize)
        #expect(sawSignal)
    }

    @Test
    func workloadAttachFailsForStoppedWorkload() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(
            id: "exec-attach-stopped",
            config: baseProcessConfiguration(),
            started: true,
            exitCode: 0,
            sessionID: "__workload__exec-attach-stopped"
        )

        do {
            try await service.testingAttachWorkload(
                "exec-attach-stopped",
                attachmentID: "reader",
                options: .init(),
                stdio: [nil, nil, nil]
            )
            Issue.record("expected attach to stopped workload to fail")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
        }
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

private final class RecordingExecSidecarServer: @unchecked Sendable {
    private let socketPath: String
    private let exitOnSignalProcessIDs: Set<String>
    private let processStartFailures: [String: MacOSSidecarErrorPayload]
    private let requests = LockedBox<[MacOSSidecarRequest]>([])
    private let errorBox = LockedBox<Error?>(nil)
    private let done = DispatchSemaphore(value: 0)
    private let listenFD = LockedBox<Int32?>(nil)
    private let clientFD = LockedBox<Int32?>(nil)

    init(
        socketPath: String,
        exitOnSignalProcessIDs: Set<String> = [],
        processStartFailures: [String: MacOSSidecarErrorPayload] = [:]
    ) throws {
        self.socketPath = socketPath
        self.exitOnSignalProcessIDs = exitOnSignalProcessIDs
        self.processStartFailures = processStartFailures
        let listeningFD = try makeUnixListener(path: socketPath)
        self.listenFD.withLock { $0 = listeningFD }
    }

    func start() {
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            do {
                guard let listeningFD = listenFD.withLock({ $0 }) else {
                    return
                }
                let accepted = Darwin.accept(listeningFD, nil, nil)
                guard accepted >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                clientFD.withLock { $0 = accepted }
                defer {
                    clientFD.withLock { fd in
                        if fd == accepted {
                            fd = nil
                        }
                    }
                    Darwin.close(accepted)
                }

                while true {
                    let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: accepted)
                    guard envelope.kind == .request, let request = envelope.request else {
                        continue
                    }
                    requests.withLock { $0.append(request) }

                    if request.method == .processStart,
                        let processID = request.processID,
                        let failure = processStartFailures[processID]
                    {
                        try writeResponse(
                            .failure(
                                requestID: request.requestID,
                                code: failure.code,
                                message: failure.message,
                                details: failure.details
                            ),
                            to: accepted
                        )
                    } else {
                        try writeResponse(.success(requestID: request.requestID), to: accepted)
                        if request.method == .processSignal,
                            let processID = request.processID,
                            exitOnSignalProcessIDs.contains(processID)
                        {
                            try writeEvent(.init(event: .processExit, processID: processID, exitCode: 0), to: accepted)
                        }
                    }
                }
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(ECONNABORTED) || nsError.code == Int(EBADF)) {
                    return
                }
                if nsError.localizedDescription.contains("unexpected EOF") {
                    return
                }
                errorBox.withLock { $0 = error }
            }
        }
    }

    func stop() {
        let listeningFD = listenFD.withLock { fd -> Int32? in
            let current = fd
            fd = nil
            return current
        }
        clientFD.withLock { fd in
            if let fd, fd >= 0 {
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
            fd = nil
        }
        if let listeningFD {
            _ = Darwin.shutdown(listeningFD, SHUT_RDWR)
            Darwin.close(listeningFD)
        }
        _ = unlink(socketPath)
    }

    func waitForCompletion(timeout: TimeInterval = 2.0) throws {
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = errorBox.withLock({ $0 }) {
            throw error
        }
    }

    func recordedRequests() -> [MacOSSidecarRequest] {
        requests.withLock { $0 }
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func makeUnixListener(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    _ = unlink(path)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
    let utf8 = Array(path.utf8)
    guard utf8.count < maxLength else {
        Darwin.close(fd)
        throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        buffer.initializeMemory(as: CChar.self, repeating: 0)
        for (index, byte) in utf8.enumerated() {
            buffer[index] = byte
        }
    }

    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + utf8.count + 1)
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            Darwin.bind(fd, pointer, addrLen)
        }
    }
    guard bindResult == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        throw error
    }
    guard Darwin.listen(fd, 8) == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        throw error
    }
    return fd
}

private func writeResponse(_ response: MacOSSidecarResponse, to fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.response(response), fd: fd)
}

private func writeEvent(_ event: MacOSSidecarEvent, to fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.event(event), fd: fd)
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

private func waitForPipeChunk(
    _ handle: FileHandle,
    timeout: Duration = .seconds(1)
) async -> Data? {
    final class PipeReadState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func complete(with body: () -> Void) {
            let shouldRun = lock.withLock { () -> Bool in
                guard !completed else {
                    return false
                }
                completed = true
                return true
            }
            guard shouldRun else {
                return
            }
            body()
        }
    }

    let state = PipeReadState()
    return await withCheckedContinuation { continuation in
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            fileHandle.readabilityHandler = nil
            state.complete {
                continuation.resume(returning: data.isEmpty ? nil : data)
            }
        }

        Task {
            try? await Task.sleep(for: timeout)
            handle.readabilityHandler = nil
            state.complete {
                continuation.resume(returning: nil)
            }
        }
    }
}
#endif
