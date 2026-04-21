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

import ContainerizationExtras
import Foundation
import GRPC
import NIO
import Testing

@testable import ContainerCRI
@testable import ContainerCRIShimMacOS
@testable import ContainerKit
@testable import ContainerResource

#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct CRIShimRuntimeServerTests {
    @Test
    func runnerCreatesServerAndRunsItAfterValidation() async throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        let factory = RecordingServerFactory()
        let runner = CRIShimRunner(config: config, serverFactory: factory)

        try await runner.run()

        #expect(factory.makeServerCallCount == 1)
        #expect(factory.receivedRuntimeEndpoint == "/var/run/container-cri-macos.sock")
        #expect(factory.server.runCallCount == 1)
    }

    @Test
    func grpcServerServesVersionOnUnixDomainSocket() async throws {
        let socketPath = "/tmp/cri-shim-grpc-\(UUID().uuidString.prefix(8)).sock"
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let criLogDirectory = stateDirectory.appendingPathComponent("cri-logs", isDirectory: true)
        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.stateDirectory = stateDirectory.path
        let metadataStore = try CRIShimMetadataStore(rootURL: stateDirectory)
        try metadataStore.upsertSandbox(
            CRIShimSandboxMetadata(
                id: "sandbox-1",
                podUID: "pod-uid",
                namespace: "default",
                name: "demo",
                attempt: 2,
                runtimeHandler: "macos",
                sandboxImage: "example.com/macos/sandbox:latest",
                network: "default",
                labels: ["app": "demo"],
                annotations: ["pod": "annotation"],
                state: .running,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ))
        try metadataStore.upsertContainer(
            CRIShimContainerMetadata(
                id: "container-1",
                sandboxID: "sandbox-1",
                name: "workload",
                attempt: 1,
                image: "example.com/macos/workload:latest",
                runtimeHandler: "macos",
                labels: ["app": "demo", "tier": "frontend"],
                annotations: ["container": "annotation"],
                command: ["/bin/echo"],
                args: ["hello"],
                workingDirectory: "/workspace",
                logPath: criLogDirectory.appendingPathComponent("workload/0.log").path,
                state: .running,
                createdAt: Date(timeIntervalSince1970: 1_700_000_010),
                startedAt: Date(timeIntervalSince1970: 1_700_000_020)
            ))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let imageManager = RecordingImageManager(
            images: [
                CRIShimImageRecord(
                    reference: "localhost/macos-sandbox:latest",
                    digest: "sha256:sandbox",
                    size: 16_384,
                    annotations: ["org.apple.container.macos.image.role": "sandbox"]
                ),
                CRIShimImageRecord(
                    reference: "example.com/macos/workload:latest",
                    digest: "sha256:abc123",
                    size: 4096,
                    annotations: MacOSImageContract.annotations(for: .workload)
                        .merging(["org.opencontainers.image.ref.name": "example.com/macos/workload:latest"]) { current, _ in current }
                ),
            ],
            pulledImage: CRIShimImageRecord(
                reference: "example.com/macos/pulled:latest",
                digest: "sha256:pulled",
                size: 8192
            ),
            filesystemUsage: CRIShimImageFilesystemUsage(
                mountpoint: "/var/lib/container-test",
                usedBytes: 65_536,
                timestampNanoseconds: 1_700_000_000_000_000_000
            ))
        let sandboxWorkloadSnapshot = WorkloadSnapshot(
            configuration: WorkloadConfiguration(
                id: "container-1",
                processConfiguration: ProcessConfiguration(executable: "/bin/echo", arguments: [], environment: [])
            ),
            status: .running,
            startedDate: Date(timeIntervalSince1970: 1_700_000_030)
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(
                exitCode: 7,
                stdout: Data("exec stdout".utf8),
                stderr: Data("exec stderr".utf8)
            ),
            logRootURL: stateDirectory.appendingPathComponent("workload-logs", isDirectory: true),
            sandboxSnapshots: [
                "sandbox-1": SandboxSnapshot(
                    configuration: try makeSandboxConfiguration(
                        id: "sandbox-1",
                        labels: ["app": "demo"]
                    ),
                    status: .running,
                    networks: [
                        try makeNetworkAttachment(
                            network: "default",
                            address: "192.168.64.20/24",
                            gateway: "192.168.64.1"
                        ),
                        try makeNetworkAttachment(
                            network: "secondary",
                            address: "192.168.65.20/24",
                            gateway: "192.168.65.1"
                        ),
                    ],
                    containers: [],
                    workloads: [sandboxWorkloadSnapshot]
                )
            ])
        let cniManager = RecordingCNIManager()
        let server = try CRIShimGRPCServer(
            socketPath: socketPath,
            config: config,
            versionInfo: CRIShimRuntimeVersionInfo(
                runtimeName: "container-macos-test",
                runtimeVersion: "1.2.3",
                runtimeAPIVersion: CRIProtocol.runtimeAPIVersion
            ),
            eventLoopGroup: group,
            readinessChecker: StaticReadinessChecker(
                snapshot: CRIShimReadinessSnapshot(
                    runtime: CRIShimRuntimeConditionSnapshot(
                        type: CRIShimRuntimeConditionType.runtimeReady,
                        status: true,
                        reason: "RuntimeHealthOK",
                        message: "test runtime ready"
                    ),
                    network: CRIShimRuntimeConditionSnapshot(
                        type: CRIShimRuntimeConditionType.networkReady,
                        status: false,
                        reason: "NetworkNotRunning",
                        message: "test network not ready"
                    ),
                    info: ["runtime": #"{"test":"ready"}"#]
                )
            ),
            runtimeManager: runtimeManager,
            imageManager: imageManager,
            cniManager: cniManager
        )
        let serverTask = Task {
            try await server.run()
        }
        defer {
            serverTask.cancel()
            _ = try? FileManager.default.removeItem(atPath: socketPath)
        }

        try await waitForSocket(at: socketPath)

        let channel = ClientConnection.insecure(group: group)
            .withConnectedSocket(try connectedUnixSocket(path: socketPath))
        let client = Runtime_V1_RuntimeServiceAsyncClient(channel: channel)

        let version = try await client.version(Runtime_V1_VersionRequest())

        #expect(version.version == CRIProtocol.runtimeAPIVersion)
        #expect(version.runtimeName == "container-macos-test")
        #expect(version.runtimeVersion == "1.2.3")
        #expect(version.runtimeApiVersion == CRIProtocol.runtimeAPIVersion)

        var statusRequest = Runtime_V1_StatusRequest()
        statusRequest.verbose = true
        let status = try await client.status(statusRequest)
        #expect(
            status.status.conditions.map(\.type) == [
                CRIShimRuntimeConditionType.runtimeReady,
                CRIShimRuntimeConditionType.networkReady,
            ])
        #expect(status.status.conditions[0].status)
        #expect(!status.status.conditions[1].status)
        #expect(status.status.conditions[1].reason == "NetworkNotRunning")
        #expect(status.runtimeHandlers.map(\.name) == ["", "macos"])
        #expect(status.info["runtime"] == #"{"test":"ready"}"#)

        var execSyncRequest = Runtime_V1_ExecSyncRequest()
        execSyncRequest.containerID = "container-1"
        execSyncRequest.cmd = ["/bin/echo", "hello"]
        execSyncRequest.timeout = 3
        let execSync = try await client.execSync(execSyncRequest)
        #expect(execSync.exitCode == 7)
        #expect(execSync.stdout == Data("exec stdout".utf8))
        #expect(execSync.stderr == Data("exec stderr".utf8))
        #expect(runtimeManager.execSyncCalls.count == 1)
        #expect(runtimeManager.execSyncCalls[0].containerID == "container-1")
        #expect(runtimeManager.execSyncCalls[0].configuration.executable == "/bin/echo")
        #expect(runtimeManager.execSyncCalls[0].configuration.arguments == ["hello"])
        #expect(runtimeManager.execSyncCalls[0].timeout == .seconds(3))

        var execRequest = Runtime_V1_ExecRequest()
        execRequest.containerID = "container-1"
        execRequest.cmd = ["/bin/cat"]
        execRequest.stdin = true
        execRequest.stdout = true
        execRequest.stderr = false
        execRequest.tty = true
        let exec = try await client.exec(execRequest)
        let execTask = try makeWebSocketTask(
            from: exec.url,
            protocols: ["v5.channel.k8s.io"]
        )
        try await resumeWebSocketTask(execTask)

        try await execTask.send(
            .data(Data([4]) + Data(#"{"Width":120,"Height":42}"#.utf8))
        )
        try await execTask.send(
            .data(Data([0]) + Data("hello exec\n".utf8))
        )

        let execOutput = try await receiveBinaryMessage(from: execTask)
        #expect(execOutput.first == 1)
        #expect(String(decoding: execOutput.dropFirst(), as: UTF8.self) == "stdout:hello exec\n")

        try await execTask.send(.data(Data([255])))
        let execStatus = try await receiveBinaryMessage(from: execTask)
        #expect(execStatus.first == 3)
        #expect(String(decoding: execStatus.dropFirst(), as: UTF8.self).contains(#""status":"Success""#))

        let recordedProcess = try #require(runtimeManager.streamExecProcesses["container-1"])
        #expect(recordedProcess.started)
        #expect(recordedProcess.resizeCalls == [CRIShimTerminalSize(width: 120, height: 42)])

        var portForwardRequest = Runtime_V1_PortForwardRequest()
        portForwardRequest.podSandboxID = "sandbox-1"
        portForwardRequest.port = [8080, 8081]
        let portForward = try await client.portForward(portForwardRequest)
        let portForwardTask = try makeWebSocketTask(
            from: portForward.url,
            protocols: ["portforward.k8s.io"]
        )
        try await resumeWebSocketTask(portForwardTask)

        try await portForwardTask.send(
            .data(Data([0]) + portPrefixData(8080) + Data("ping0".utf8))
        )
        try await portForwardTask.send(
            .data(Data([2]) + portPrefixData(8081) + Data("ping1".utf8))
        )

        let firstPortForwardMessage = try await receiveBinaryMessage(from: portForwardTask)
        let secondPortForwardMessage = try await receiveBinaryMessage(from: portForwardTask)
        let portForwardMessages = [firstPortForwardMessage, secondPortForwardMessage]
        let observedPortForwardMessages = Set(
            portForwardMessages.map(ObservedPortForwardMessage.init)
        )
        let expectedPortForwardMessages: Set<ObservedPortForwardMessage> = [
            ObservedPortForwardMessage(
                stream: 0,
                forwardedPort: 8080,
                payload: "echo:8080:ping0"
            ),
            ObservedPortForwardMessage(
                stream: 2,
                forwardedPort: 8081,
                payload: "echo:8081:ping1"
            ),
        ]
        #expect(observedPortForwardMessages == expectedPortForwardMessages)
        #expect(
            runtimeManager.portForwardCalls == [
                RecordingPortForwardCall(sandboxID: "sandbox-1", port: 8080),
                RecordingPortForwardCall(sandboxID: "sandbox-1", port: 8081),
            ]
        )
        execTask.cancel(with: .normalClosure, reason: nil)
        portForwardTask.cancel(with: .normalClosure, reason: nil)

        let runtimeConfig = try await client.runtimeConfig(Runtime_V1_RuntimeConfigRequest())
        #expect(!runtimeConfig.hasLinux)

        _ = try await client.updateRuntimeConfig(Runtime_V1_UpdateRuntimeConfigRequest())

        var runSandboxRequest = Runtime_V1_RunPodSandboxRequest()
        runSandboxRequest.runtimeHandler = "macos"
        runSandboxRequest.config.metadata.uid = "created-pod-uid"
        runSandboxRequest.config.metadata.namespace = "default"
        runSandboxRequest.config.metadata.name = "created-pod"
        runSandboxRequest.config.metadata.attempt = 1
        runSandboxRequest.config.labels = ["app": "created-pod"]
        runSandboxRequest.config.annotations = ["pod": "created"]
        let runSandbox = try await client.runPodSandbox(runSandboxRequest)
        #expect(!runSandbox.podSandboxID.isEmpty)
        #expect(runtimeManager.createSandboxCalls.count == 1)
        let createSandboxCall = try #require(runtimeManager.createSandboxCalls.first)
        #expect(createSandboxCall.id == runSandbox.podSandboxID)
        #expect(createSandboxCall.image.reference == "localhost/macos-sandbox:latest")
        #expect(createSandboxCall.image.digest == "sha256:sandbox")
        #expect(createSandboxCall.platform.os == "darwin")
        #expect(createSandboxCall.platform.architecture == "arm64")
        #expect(createSandboxCall.runtimeHandler == "container-runtime-macos")
        #expect(createSandboxCall.macosGuest?.networkBackend == .vmnetShared)
        #expect(cniManager.addCalls.count == 1)
        let cniAddCall = try #require(cniManager.addCalls.first)
        #expect(cniAddCall.sandboxID == runSandbox.podSandboxID)
        #expect(cniAddCall.networkName == "default")
        #expect(runtimeManager.startSandboxCalls.count == 1)
        let startSandboxCall = try #require(runtimeManager.startSandboxCalls.first)
        #expect(startSandboxCall.id == runSandbox.podSandboxID)
        #expect(!startSandboxCall.presentGUI)

        var createdSandboxStatusRequest = Runtime_V1_PodSandboxStatusRequest()
        createdSandboxStatusRequest.podSandboxID = runSandbox.podSandboxID
        createdSandboxStatusRequest.verbose = true
        let createdSandboxStatus = try await client.podSandboxStatus(createdSandboxStatusRequest)
        #expect(createdSandboxStatus.status.id == runSandbox.podSandboxID)
        #expect(createdSandboxStatus.status.metadata.name == "created-pod")
        #expect(createdSandboxStatus.status.metadata.uid == "created-pod-uid")
        #expect(createdSandboxStatus.status.state == .sandboxReady)
        #expect(createdSandboxStatus.status.runtimeHandler == "macos")
        let createdSandboxStatusInfo = try #require(createdSandboxStatus.info["metadata"])
        let createdSandboxStatusMetadata = try JSONDecoder.criShimMetadataDecoder.decode(
            CRIShimSandboxMetadata.self,
            from: Data(createdSandboxStatusInfo.utf8)
        )
        #expect(createdSandboxStatusMetadata.networkLeaseID == "macvmnet://sandbox/\(runSandbox.podSandboxID)")
        #expect(createdSandboxStatusMetadata.networkAttachments == ["default"])

        var stopSandboxRequest = Runtime_V1_StopPodSandboxRequest()
        stopSandboxRequest.podSandboxID = runSandbox.podSandboxID
        _ = try await client.stopPodSandbox(stopSandboxRequest)
        #expect(runtimeManager.stopSandboxCalls.count == 1)
        let stopSandboxCall = try #require(runtimeManager.stopSandboxCalls.first)
        #expect(stopSandboxCall.id == runSandbox.podSandboxID)
        #expect(stopSandboxCall.options.timeoutInSeconds == 5)
        #expect(cniManager.deleteCalls.count == 1)
        let cniDeleteCall = try #require(cniManager.deleteCalls.first)
        #expect(cniDeleteCall.sandboxID == runSandbox.podSandboxID)
        #expect(cniDeleteCall.networkName == "default")
        #expect(runtimeManager.removeSandboxPolicyCalls == [runSandbox.podSandboxID])

        let stoppedSandboxStatus = try await client.podSandboxStatus(createdSandboxStatusRequest)
        #expect(stoppedSandboxStatus.status.state == .sandboxNotready)

        var removeSandboxRequest = Runtime_V1_RemovePodSandboxRequest()
        removeSandboxRequest.podSandboxID = runSandbox.podSandboxID
        _ = try await client.removePodSandbox(removeSandboxRequest)
        #expect(runtimeManager.removeSandboxCalls.count == 1)
        let removeSandboxCall = try #require(runtimeManager.removeSandboxCalls.first)
        #expect(removeSandboxCall.id == runSandbox.podSandboxID)
        #expect(removeSandboxCall.force)
        #expect(try metadataStore.sandbox(id: runSandbox.podSandboxID) == nil)

        var sandboxFilter = Runtime_V1_PodSandboxFilter()
        sandboxFilter.labelSelector = ["app": "demo"]
        let sandboxListRequest = Runtime_V1_ListPodSandboxRequest.with {
            $0.filter = sandboxFilter
        }
        let sandboxes = try await client.listPodSandbox(sandboxListRequest)
        #expect(sandboxes.items.count == 1)
        #expect(sandboxes.items[0].id == "sandbox-1")
        #expect(sandboxes.items[0].metadata.name == "demo")
        #expect(sandboxes.items[0].metadata.uid == "pod-uid")
        #expect(sandboxes.items[0].metadata.namespace == "default")
        #expect(sandboxes.items[0].metadata.attempt == 2)
        #expect(sandboxes.items[0].state == .sandboxReady)
        #expect(sandboxes.items[0].runtimeHandler == "macos")
        #expect(runtimeManager.inspectSandboxCalls.contains("sandbox-1"))

        var sandboxStatusRequest = Runtime_V1_PodSandboxStatusRequest()
        sandboxStatusRequest.podSandboxID = "sandbox-1"
        sandboxStatusRequest.verbose = true
        let sandboxStatus = try await client.podSandboxStatus(sandboxStatusRequest)
        #expect(sandboxStatus.status.id == "sandbox-1")
        #expect(sandboxStatus.status.metadata.attempt == 2)
        #expect(sandboxStatus.status.state == .sandboxReady)
        #expect(sandboxStatus.status.hasNetwork)
        #expect(sandboxStatus.status.network.ip == "192.168.64.20")
        #expect(sandboxStatus.status.network.additionalIps.map(\.ip) == ["192.168.65.20"])
        #expect(sandboxStatus.containersStatuses.map(\.id) == ["container-1"])
        #expect(sandboxStatus.containersStatuses[0].startedAt == 1_700_000_030_000_000_000)
        #expect(sandboxStatus.info["metadata"]?.contains(#""runtimeHandler":"macos""#) == true)
        #expect(sandboxStatus.info["sandboxSnapshot"]?.contains(#""status":"running""#) == true)

        var containerFilter = Runtime_V1_ContainerFilter()
        containerFilter.podSandboxID = "sandbox-1"
        containerFilter.labelSelector = ["tier": "frontend"]
        let containerListRequest = Runtime_V1_ListContainersRequest.with {
            $0.filter = containerFilter
        }
        let containers = try await client.listContainers(containerListRequest)
        #expect(containers.containers.count == 1)
        #expect(containers.containers[0].id == "container-1")
        #expect(containers.containers[0].podSandboxID == "sandbox-1")
        #expect(containers.containers[0].metadata.name == "workload")
        #expect(containers.containers[0].metadata.attempt == 1)
        #expect(containers.containers[0].image.image == "example.com/macos/workload:latest")
        #expect(containers.containers[0].state == .containerRunning)

        var containerStatusRequest = Runtime_V1_ContainerStatusRequest()
        containerStatusRequest.containerID = "container-1"
        containerStatusRequest.verbose = true
        let containerStatus = try await client.containerStatus(containerStatusRequest)
        #expect(containerStatus.status.id == "container-1")
        #expect(containerStatus.status.metadata.name == "workload")
        #expect(containerStatus.status.metadata.attempt == 1)
        #expect(containerStatus.status.state == .containerRunning)
        #expect(containerStatus.status.startedAt == 1_700_000_030_000_000_000)
        #expect(containerStatus.status.logPath == criLogDirectory.appendingPathComponent("workload/0.log").path)
        #expect(containerStatus.info["metadata"]?.contains(#""sandboxID":"sandbox-1""#) == true)

        var containerStatsRequest = Runtime_V1_ContainerStatsRequest()
        containerStatsRequest.containerID = "container-1"
        let containerStats = try await client.containerStats(containerStatsRequest)
        #expect(containerStats.stats.attributes.id == "container-1")
        #expect(containerStats.stats.attributes.metadata.name == "workload")

        var listContainerStatsRequest = Runtime_V1_ListContainerStatsRequest()
        listContainerStatsRequest.filter.podSandboxID = "sandbox-1"
        listContainerStatsRequest.filter.labelSelector = ["tier": "frontend"]
        let containerStatsList = try await client.listContainerStats(listContainerStatsRequest)
        #expect(containerStatsList.stats.map(\.attributes.id) == ["container-1"])

        var podSandboxStatsRequest = Runtime_V1_PodSandboxStatsRequest()
        podSandboxStatsRequest.podSandboxID = "sandbox-1"
        let podSandboxStats = try await client.podSandboxStats(podSandboxStatsRequest)
        #expect(podSandboxStats.stats.attributes.id == "sandbox-1")
        #expect(podSandboxStats.stats.attributes.metadata.name == "demo")

        var listPodSandboxStatsRequest = Runtime_V1_ListPodSandboxStatsRequest()
        listPodSandboxStatsRequest.filter.labelSelector = ["app": "demo"]
        let podSandboxStatsList = try await client.listPodSandboxStats(listPodSandboxStatsRequest)
        #expect(podSandboxStatsList.stats.map(\.attributes.id) == ["sandbox-1"])

        var createRequest = Runtime_V1_CreateContainerRequest()
        createRequest.podSandboxID = "sandbox-1"
        createRequest.sandboxConfig.logDirectory = criLogDirectory.path
        createRequest.config.metadata.name = "created-workload"
        createRequest.config.metadata.attempt = 4
        createRequest.config.image.image = "example.com/macos/workload:latest"
        createRequest.config.command = ["/usr/bin/python3"]
        createRequest.config.args = ["-c", "print('hello')"]
        createRequest.config.envs = [keyValue("HELLO", "world")]
        createRequest.config.workingDir = "/workspace"
        createRequest.config.labels = ["app": "created"]
        createRequest.config.annotations = ["note": "created"]
        createRequest.config.logPath = "created/0.log"
        let created = try await client.createContainer(createRequest)
        #expect(!created.containerID.isEmpty)
        #expect(runtimeManager.createWorkloadCalls.count == 1)
        let createCall = try #require(runtimeManager.createWorkloadCalls.first)
        #expect(createCall.sandboxID == "sandbox-1")
        #expect(createCall.configuration.id == created.containerID)
        #expect(createCall.configuration.workloadImageReference == "example.com/macos/workload:latest")
        #expect(createCall.configuration.workloadImageDigest == "sha256:abc123")
        #expect(createCall.configuration.processConfiguration.executable == "/usr/bin/python3")
        #expect(createCall.configuration.processConfiguration.arguments == ["-c", "print('hello')"])
        #expect(createCall.configuration.processConfiguration.environment == ["HELLO=world"])
        #expect(createCall.configuration.processConfiguration.workingDirectory == "/workspace")

        var createdStatusRequest = Runtime_V1_ContainerStatusRequest()
        createdStatusRequest.containerID = created.containerID
        let createdStatus = try await client.containerStatus(createdStatusRequest)
        #expect(createdStatus.status.id == created.containerID)
        #expect(createdStatus.status.metadata.name == "created-workload")
        #expect(createdStatus.status.metadata.attempt == 4)
        #expect(createdStatus.status.state == .containerCreated)
        #expect(createdStatus.status.logPath == criLogDirectory.appendingPathComponent("created/0.log").path)

        var startRequest = Runtime_V1_StartContainerRequest()
        startRequest.containerID = created.containerID
        _ = try await client.startContainer(startRequest)
        #expect(runtimeManager.startWorkloadCalls.count == 1)
        let startCall = try #require(runtimeManager.startWorkloadCalls.first)
        #expect(startCall.sandboxID == "sandbox-1")
        #expect(startCall.workloadID == created.containerID)

        let createdLogPath = criLogDirectory.appendingPathComponent("created/0.log").path
        try runtimeManager.appendStdout("hello stdout\n", workloadID: created.containerID)
        try runtimeManager.appendStderr("oops stderr\n", workloadID: created.containerID)
        let initialCRIContent = try await waitForFileContent(
            at: createdLogPath,
            containing: [
                " stdout F hello stdout",
                " stderr F oops stderr",
            ]
        )
        #expect(initialCRIContent.contains(" stdout F hello stdout"))
        #expect(initialCRIContent.contains(" stderr F oops stderr"))

        let rotatedLogPath = criLogDirectory.appendingPathComponent("created/0.log.1").path
        try FileManager.default.moveItem(atPath: createdLogPath, toPath: rotatedLogPath)
        _ = FileManager.default.createFile(atPath: createdLogPath, contents: nil)

        var reopenRequest = Runtime_V1_ReopenContainerLogRequest()
        reopenRequest.containerID = created.containerID
        _ = try await client.reopenContainerLog(reopenRequest)

        try runtimeManager.appendStdout("after rotate\n", workloadID: created.containerID)
        let reopenedCRIContent = try await waitForFileContent(
            at: createdLogPath,
            containing: [" stdout F after rotate"]
        )
        #expect(reopenedCRIContent.contains(" stdout F after rotate"))
        let rotatedCRIContent = try String(contentsOfFile: rotatedLogPath, encoding: .utf8)
        #expect(!rotatedCRIContent.contains("after rotate"))

        let runningStatus = try await client.containerStatus(createdStatusRequest)
        #expect(runningStatus.status.state == .containerRunning)
        #expect(runningStatus.status.startedAt > 0)

        var stopRequest = Runtime_V1_StopContainerRequest()
        stopRequest.containerID = created.containerID
        stopRequest.timeout = 2
        _ = try await client.stopContainer(stopRequest)
        #expect(runtimeManager.stopWorkloadCalls.count == 1)
        let stopCall = try #require(runtimeManager.stopWorkloadCalls.first)
        #expect(stopCall.sandboxID == "sandbox-1")
        #expect(stopCall.workloadID == created.containerID)
        #expect(stopCall.options.timeoutInSeconds == 2)
        #expect(stopCall.options.signal == Int32(SIGTERM))

        let stoppedStatus = try await client.containerStatus(createdStatusRequest)
        #expect(stoppedStatus.status.state == .containerExited)
        #expect(stoppedStatus.status.finishedAt > 0)
        #expect(stoppedStatus.status.exitCode == 42)

        var removeRequest = Runtime_V1_RemoveContainerRequest()
        removeRequest.containerID = created.containerID
        _ = try await client.removeContainer(removeRequest)
        #expect(runtimeManager.removeWorkloadCalls.count == 1)
        let removeCall = try #require(runtimeManager.removeWorkloadCalls.first)
        #expect(removeCall.sandboxID == "sandbox-1")
        #expect(removeCall.workloadID == created.containerID)

        let imageClient = Runtime_V1_ImageServiceAsyncClient(channel: channel)
        let listImages = try await imageClient.listImages(Runtime_V1_ListImagesRequest())
        #expect(listImages.images.count == 2)
        let listedWorkloadImage = try #require(
            listImages.images.first { $0.id == "sha256:abc123" }
        )
        #expect(listedWorkloadImage.repoTags == ["example.com/macos/workload:latest"])
        #expect(listedWorkloadImage.repoDigests == ["example.com/macos/workload@sha256:abc123"])

        var imageStatusRequest = Runtime_V1_ImageStatusRequest()
        imageStatusRequest.image.image = "sha256:abc123"
        imageStatusRequest.verbose = true
        let imageStatus = try await imageClient.imageStatus(imageStatusRequest)
        #expect(imageStatus.image.id == "sha256:abc123")
        #expect(imageStatus.info["image"]?.contains(#""reference""#) == true)
        #expect(imageStatus.info["image"]?.contains("example.com") == true)

        var removeImageRequest = Runtime_V1_RemoveImageRequest()
        removeImageRequest.image.image = "example.com/macos/workload:latest"
        _ = try await imageClient.removeImage(removeImageRequest)

        let imageFsInfo = try await imageClient.imageFsInfo(Runtime_V1_ImageFsInfoRequest())
        #expect(imageFsInfo.imageFilesystems.count == 1)
        #expect(imageFsInfo.imageFilesystems[0].timestamp == 1_700_000_000_000_000_000)
        #expect(imageFsInfo.imageFilesystems[0].fsID.mountpoint == "/var/lib/container-test")
        #expect(imageFsInfo.imageFilesystems[0].usedBytes.value == 65_536)
        #expect(!imageFsInfo.imageFilesystems[0].hasInodesUsed)

        var pullImageRequest = Runtime_V1_PullImageRequest()
        pullImageRequest.image.image = "example.com/macos/pulled:latest"
        pullImageRequest.auth.auth = Data("cri-user:cri-password".utf8).base64EncodedString()
        let pullImage = try await imageClient.pullImage(pullImageRequest)
        #expect(pullImage.imageRef == "sha256:pulled")
        #expect(imageManager.pulledReferences == ["example.com/macos/pulled:latest"])
        #expect(imageManager.pulledAuthentications == [.basic(username: "cri-user", password: "cri-password")])

        let metricDescriptors = try await client.listMetricDescriptors(Runtime_V1_ListMetricDescriptorsRequest())
        #expect(metricDescriptors.descriptors.isEmpty)

        let sandboxMetrics = try await client.listPodSandboxMetrics(Runtime_V1_ListPodSandboxMetricsRequest())
        #expect(sandboxMetrics.podMetrics.isEmpty)

        _ = try await client.updateContainerResources(Runtime_V1_UpdateContainerResourcesRequest())
        _ = try await client.updatePodSandboxResources(Runtime_V1_UpdatePodSandboxResourcesRequest())

        var events: [Runtime_V1_ContainerEventResponse] = []
        for try await event in client.getContainerEvents(Runtime_V1_GetEventsRequest()) {
            events.append(event)
        }
        #expect(events.isEmpty)

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        await shutdown(group)
    }

    @Test
    func execStreamingTimeoutKillsIdleProcess() async throws {
        let socketPath = "/tmp/cri-shim-timeout-\(UUID().uuidString.prefix(8)).sock"
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.stateDirectory = stateDirectory.path

        let metadataStore = try CRIShimMetadataStore(rootURL: stateDirectory)
        try metadataStore.upsertSandbox(
            CRIShimSandboxMetadata(
                id: "sandbox-1",
                podUID: "pod-uid",
                namespace: "default",
                name: "timeout-demo",
                attempt: 1,
                runtimeHandler: "macos",
                sandboxImage: "example.com/macos/sandbox:latest",
                network: "default",
                state: .running,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ))
        try metadataStore.upsertContainer(
            CRIShimContainerMetadata(
                id: "container-1",
                sandboxID: "sandbox-1",
                name: "workload",
                attempt: 1,
                image: "example.com/macos/workload:latest",
                runtimeHandler: "macos",
                command: ["/bin/cat"],
                args: [],
                logPath: stateDirectory.appendingPathComponent("cri.log").path,
                state: .running,
                createdAt: Date(timeIntervalSince1970: 1_700_000_010),
                startedAt: Date(timeIntervalSince1970: 1_700_000_020)
            ))

        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(
                exitCode: 0,
                stdout: Data(),
                stderr: Data()
            )
        )
        let imageManager = RecordingImageManager(images: [])
        let cniManager = RecordingCNIManager()
        let logManager = CRIShimLogManager(stateDirectoryURL: stateDirectory)
        let streamingServer = CRIShimStreamingServer(
            config: config,
            runtimeManager: runtimeManager,
            activeSessionIdleTimeoutSeconds: 0.5
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = CRIShimGRPCServer(
            socketPath: socketPath,
            serviceProviders: [
                CRIShimRuntimeServiceProvider(
                    config: config,
                    metadataStore: metadataStore,
                    runtimeManager: runtimeManager,
                    imageManager: imageManager,
                    cniManager: cniManager,
                    logManager: logManager,
                    streamingServer: streamingServer
                ),
                CRIShimImageServiceProvider(imageManager: imageManager),
            ],
            eventLoopGroup: group,
            startupTasks: [],
            streamingServer: streamingServer
        )
        let serverTask = Task {
            try await server.run()
        }
        defer {
            serverTask.cancel()
            _ = try? FileManager.default.removeItem(atPath: socketPath)
        }

        try await waitForSocket(at: socketPath)

        let channel = ClientConnection.insecure(group: group)
            .withConnectedSocket(try connectedUnixSocket(path: socketPath))
        let client = Runtime_V1_RuntimeServiceAsyncClient(channel: channel)

        var execRequest = Runtime_V1_ExecRequest()
        execRequest.containerID = "container-1"
        execRequest.cmd = ["/bin/cat"]
        execRequest.stdin = true
        execRequest.stdout = true
        execRequest.tty = true
        let exec = try await client.exec(execRequest)
        let execTask = try makeWebSocketTask(
            from: exec.url,
            protocols: ["v5.channel.k8s.io"]
        )
        try await resumeWebSocketTask(execTask)

        let process = try await waitForValue(description: "stream exec process") {
            runtimeManager.streamExecProcesses["container-1"]
        }
        try await waitForCondition(description: "stream exec process start") {
            process.started
        }

        let timeoutStatus = try await receiveBinaryMessage(from: execTask)
        #expect(timeoutStatus.first == 3)
        #expect(
            String(decoding: timeoutStatus.dropFirst(), as: UTF8.self)
                .contains("timed out due to inactivity")
        )

        try await waitForCondition(description: "stream exec process kill") {
            process.killSignals == [Int32(SIGTERM)]
        }

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        await shutdown(group)
    }

    @Test
    func runtimeOperationSurfaceHasDeterministicUnsupportedMessages() {
        for operation in CRIRuntimeOperationSurface.all {
            #expect(!CRIRuntimeOperationSurface.unsupportedReason(for: operation).isEmpty)
        }
        #expect(CRIRuntimeOperationSurface.all.contains(.version))
        #expect(CRIRuntimeOperationSurface.all.contains(.status))
        #expect(CRIRuntimeOperationSurface.all.contains(.runPodSandbox))
        #expect(CRIRuntimeOperationSurface.all.contains(.stopPodSandbox))
        #expect(CRIRuntimeOperationSurface.all.contains(.portForward))
    }
}

private final class RecordingServerFactory: CRIShimServerFactory, @unchecked Sendable {
    private(set) var makeServerCallCount = 0
    private(set) var receivedRuntimeEndpoint: String?
    private(set) var server = RecordingServer()

    func makeServer(config: CRIShimConfig) throws -> any CRIShimServerLifecycle {
        makeServerCallCount += 1
        receivedRuntimeEndpoint = config.normalizedRuntimeEndpoint
        return server
    }
}

private final class RecordingServer: CRIShimServerLifecycle, @unchecked Sendable {
    private(set) var runCallCount = 0
    private(set) var stopCallCount = 0

    func run() async throws {
        runCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
    }
}

private struct StaticReadinessChecker: CRIShimReadinessChecking {
    var snapshot: CRIShimReadinessSnapshot

    func snapshot(config: CRIShimConfig) async -> CRIShimReadinessSnapshot {
        snapshot
    }
}

private struct RecordingExecSyncCall {
    var containerID: String
    var configuration: ProcessConfiguration
    var timeout: Duration?
}

private struct RecordingStreamExecCall {
    var containerID: String
    var configuration: ProcessConfiguration
}

private struct RecordingPortForwardCall: Equatable {
    var sandboxID: String
    var port: UInt32
}

private struct ObservedPortForwardMessage: Hashable {
    var stream: UInt8
    var forwardedPort: UInt16
    var payload: String

    init(stream: UInt8, forwardedPort: UInt16, payload: String) {
        self.stream = stream
        self.forwardedPort = forwardedPort
        self.payload = payload
    }

    init(_ message: Data) {
        stream = message[0]
        forwardedPort = UInt16(message[1]) | (UInt16(message[2]) << 8)
        payload = String(decoding: message.dropFirst(3), as: UTF8.self)
    }
}

private struct RecordingCreateWorkloadCall {
    var sandboxID: String
    var configuration: WorkloadConfiguration
}

private struct RecordingStopWorkloadCall {
    var sandboxID: String
    var workloadID: String
    var options: ContainerStopOptions
}

private final class RecordingStreamingProcess: CRIShimStreamingProcess, @unchecked Sendable {
    let stdin: FileHandle?
    let stdout: FileHandle?
    let stderr: FileHandle?
    private(set) var started = false
    private(set) var resizeCalls: [CRIShimTerminalSize] = []
    private(set) var killSignals: [Int32] = []
    private let stateLock = NSLock()
    private var waitTask: Task<Int32, Never>?

    init(
        stdin: FileHandle?,
        stdout: FileHandle?,
        stderr: FileHandle?
    ) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    func start() async throws {
        started = true
        waitTask = Task {
            if let stderr {
                try? stderr.close()
            }

            if let stdin, let stdout {
                for await data in fileHandleStream(stdin) {
                    try? stdout.write(contentsOf: Data("stdout:".utf8) + data)
                }
            }

            try? stdout?.close()
            try? stdin?.close()
            return 0
        }
    }

    func resize(_ size: CRIShimTerminalSize) async throws {
        stateLock.withLock {
            resizeCalls.append(size)
        }
    }

    func kill(_ signal: Int32) async throws {
        stateLock.withLock {
            killSignals.append(signal)
        }
        try? stdin?.close()
        try? stdout?.close()
        try? stderr?.close()
        if waitTask == nil {
            waitTask = Task { 128 + signal }
        }
    }

    func wait() async throws -> Int32 {
        await waitTask?.value ?? 0
    }
}

private final class RecordingPortForwardConnection: @unchecked Sendable {
    let forwardedHandle: FileHandle
    let peerHandle: FileHandle

    init(forwardedHandle: FileHandle, peerHandle: FileHandle) {
        self.forwardedHandle = forwardedHandle
        self.peerHandle = peerHandle
    }

    func startEcho(port: UInt32) {
        Task {
            for await data in fileHandleStream(peerHandle) {
                try? peerHandle.write(contentsOf: Data("echo:\(port):".utf8) + data)
            }
        }
    }
}

private final class RecordingRuntimeManager: CRIShimRuntimeManaging, @unchecked Sendable {
    var execSyncResult: ExecSyncResult
    private let logRootURL: URL
    private var sandboxSnapshots: [String: SandboxSnapshot]
    private var workloadConfigurations: [String: WorkloadConfiguration] = [:]
    private var workloadSnapshots: [String: WorkloadSnapshot] = [:]
    private(set) var streamExecProcesses: [String: RecordingStreamingProcess] = [:]
    private(set) var portForwardConnections: [UInt32: RecordingPortForwardConnection] = [:]
    private(set) var createSandboxCalls: [ContainerConfiguration] = []
    private(set) var startSandboxCalls: [(id: String, presentGUI: Bool)] = []
    private(set) var stopSandboxCalls: [(id: String, options: ContainerStopOptions)] = []
    private(set) var removeSandboxCalls: [(id: String, force: Bool)] = []
    private(set) var removeSandboxPolicyCalls: [String] = []
    private(set) var inspectSandboxCalls: [String] = []
    private(set) var createWorkloadCalls: [RecordingCreateWorkloadCall] = []
    private(set) var startWorkloadCalls: [(sandboxID: String, workloadID: String)] = []
    private(set) var stopWorkloadCalls: [RecordingStopWorkloadCall] = []
    private(set) var removeWorkloadCalls: [(sandboxID: String, workloadID: String)] = []
    private(set) var execSyncCalls: [RecordingExecSyncCall] = []
    private(set) var streamExecCalls: [RecordingStreamExecCall] = []
    private(set) var portForwardCalls: [RecordingPortForwardCall] = []

    init(
        execSyncResult: ExecSyncResult,
        logRootURL: URL = makeTemporaryDirectory(),
        sandboxSnapshots: [String: SandboxSnapshot] = [:],
        workloadSnapshots: [String: WorkloadSnapshot] = [:]
    ) {
        self.execSyncResult = execSyncResult
        self.logRootURL = logRootURL
        self.sandboxSnapshots = sandboxSnapshots
        self.workloadSnapshots = workloadSnapshots
        try? FileManager.default.createDirectory(at: logRootURL, withIntermediateDirectories: true)
    }

    func createSandbox(
        configuration: ContainerConfiguration
    ) async throws {
        sandboxSnapshots[configuration.id] = SandboxSnapshot(
            configuration: SandboxConfiguration(containerConfiguration: configuration),
            status: .stopped,
            networks: [],
            containers: [],
            workloads: []
        )
        createSandboxCalls.append(configuration)
    }

    func startSandbox(
        id: String,
        presentGUI: Bool
    ) async throws {
        if var snapshot = sandboxSnapshots[id] {
            snapshot.status = .running
            sandboxSnapshots[id] = snapshot
        }
        startSandboxCalls.append((id: id, presentGUI: presentGUI))
    }

    func stopSandbox(
        id: String,
        options: ContainerStopOptions
    ) async throws {
        if var snapshot = sandboxSnapshots[id] {
            snapshot.status = .stopped
            sandboxSnapshots[id] = snapshot
        }
        stopSandboxCalls.append((id: id, options: options))
    }

    func removeSandbox(
        id: String,
        force: Bool
    ) async throws {
        sandboxSnapshots.removeValue(forKey: id)
        removeSandboxCalls.append((id: id, force: force))
    }

    func removeSandboxPolicy(
        sandboxID: String
    ) async throws {
        removeSandboxPolicyCalls.append(sandboxID)
    }

    func inspectSandbox(
        id: String
    ) async throws -> SandboxSnapshot {
        inspectSandboxCalls.append(id)
        guard let snapshot = sandboxSnapshots[id] else {
            throw CRIShimError.notFound("sandbox \(id) not found")
        }
        return snapshot
    }

    func listSandboxSnapshots() async throws -> [SandboxSnapshot] {
        sandboxSnapshots.values.sorted {
            ($0.configuration?.id ?? "") < ($1.configuration?.id ?? "")
        }
    }

    func createWorkload(
        sandboxID: String,
        configuration: WorkloadConfiguration
    ) async throws {
        workloadConfigurations[configuration.id] = configuration
        let logDirectory = logRootURL.appendingPathComponent(configuration.id, isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let stdoutLogURL = logDirectory.appendingPathComponent("stdout.log", isDirectory: false)
        let stderrLogURL = logDirectory.appendingPathComponent("stderr.log", isDirectory: false)
        if !FileManager.default.fileExists(atPath: stdoutLogURL.path) {
            _ = FileManager.default.createFile(atPath: stdoutLogURL.path, contents: nil)
        }
        if !FileManager.default.fileExists(atPath: stderrLogURL.path) {
            _ = FileManager.default.createFile(atPath: stderrLogURL.path, contents: nil)
        }
        let snapshot = WorkloadSnapshot(
            configuration: configuration,
            status: .unknown,
            stdoutLogPath: stdoutLogURL.path,
            stderrLogPath: stderrLogURL.path
        )
        workloadSnapshots[configuration.id] = snapshot
        replaceWorkloadSnapshot(snapshot, sandboxID: sandboxID)
        createWorkloadCalls.append(
            RecordingCreateWorkloadCall(
                sandboxID: sandboxID,
                configuration: configuration
            ))
    }

    func startWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws {
        let configuration =
            workloadConfigurations[workloadID]
            ?? WorkloadConfiguration(
                id: workloadID,
                processConfiguration: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [])
            )
        let existingSnapshot = workloadSnapshots[workloadID]
        let snapshot = WorkloadSnapshot(
            configuration: configuration,
            status: .running,
            startedDate: Date(),
            stdoutLogPath: existingSnapshot?.stdoutLogPath,
            stderrLogPath: existingSnapshot?.stderrLogPath
        )
        workloadSnapshots[workloadID] = snapshot
        replaceWorkloadSnapshot(snapshot, sandboxID: sandboxID)
        startWorkloadCalls.append((sandboxID: sandboxID, workloadID: workloadID))
    }

    func stopWorkload(
        sandboxID: String,
        workloadID: String,
        options: ContainerStopOptions
    ) async throws {
        let configuration =
            workloadConfigurations[workloadID]
            ?? WorkloadConfiguration(
                id: workloadID,
                processConfiguration: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [])
            )
        let existingSnapshot = workloadSnapshots[workloadID]
        let snapshot = WorkloadSnapshot(
            configuration: configuration,
            status: .stopped,
            exitCode: 42,
            startedDate: existingSnapshot?.startedDate,
            exitedAt: Date(),
            stdoutLogPath: existingSnapshot?.stdoutLogPath,
            stderrLogPath: existingSnapshot?.stderrLogPath
        )
        workloadSnapshots[workloadID] = snapshot
        replaceWorkloadSnapshot(snapshot, sandboxID: sandboxID)
        stopWorkloadCalls.append(
            RecordingStopWorkloadCall(
                sandboxID: sandboxID,
                workloadID: workloadID,
                options: options
            ))
    }

    func removeWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws {
        workloadConfigurations.removeValue(forKey: workloadID)
        workloadSnapshots.removeValue(forKey: workloadID)
        removeWorkloadSnapshot(workloadID, sandboxID: sandboxID)
        removeWorkloadCalls.append((sandboxID: sandboxID, workloadID: workloadID))
    }

    func inspectWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws -> WorkloadSnapshot {
        guard let snapshot = workloadSnapshots[workloadID] else {
            throw CRIShimError.notFound("workload \(workloadID) not found")
        }
        return snapshot
    }

    func execSync(
        containerID: String,
        configuration: ProcessConfiguration,
        timeout: Duration?
    ) async throws -> ExecSyncResult {
        execSyncCalls.append(
            RecordingExecSyncCall(
                containerID: containerID,
                configuration: configuration,
                timeout: timeout
            ))
        return execSyncResult
    }

    func streamExec(
        containerID: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> any CRIShimStreamingProcess {
        let process = RecordingStreamingProcess(
            stdin: stdio[0],
            stdout: stdio[1],
            stderr: stdio[2]
        )
        streamExecCalls.append(
            RecordingStreamExecCall(
                containerID: containerID,
                configuration: configuration
            )
        )
        streamExecProcesses[containerID] = process
        return process
    }

    func streamPortForward(
        sandboxID: String,
        port: UInt32
    ) async throws -> FileHandle {
        let (forwardedHandle, peerHandle) = try makeSocketPair()
        let connection = RecordingPortForwardConnection(
            forwardedHandle: forwardedHandle,
            peerHandle: peerHandle
        )
        connection.startEcho(port: port)
        portForwardCalls.append(RecordingPortForwardCall(sandboxID: sandboxID, port: port))
        portForwardConnections[port] = connection
        return forwardedHandle
    }

    func appendStdout(_ text: String, workloadID: String) throws {
        try appendLog(text, workloadID: workloadID, stream: \.stdoutLogPath)
    }

    func appendStderr(_ text: String, workloadID: String) throws {
        try appendLog(text, workloadID: workloadID, stream: \.stderrLogPath)
    }

    private func replaceWorkloadSnapshot(_ workload: WorkloadSnapshot, sandboxID: String) {
        guard var sandboxSnapshot = sandboxSnapshots[sandboxID] else {
            return
        }
        sandboxSnapshot.workloads.removeAll { $0.id == workload.id }
        sandboxSnapshot.workloads.append(workload)
        sandboxSnapshots[sandboxID] = sandboxSnapshot
    }

    private func removeWorkloadSnapshot(_ workloadID: String, sandboxID: String) {
        guard var sandboxSnapshot = sandboxSnapshots[sandboxID] else {
            return
        }
        sandboxSnapshot.workloads.removeAll { $0.id == workloadID }
        sandboxSnapshots[sandboxID] = sandboxSnapshot
    }

    private func appendLog(
        _ text: String,
        workloadID: String,
        stream: KeyPath<WorkloadSnapshot, String?>
    ) throws {
        guard let snapshot = workloadSnapshots[workloadID] else {
            throw CRIShimError.notFound("workload \(workloadID) not found")
        }
        guard let path = snapshot[keyPath: stream] else {
            throw CRIShimError.notFound("log path for workload \(workloadID) not found")
        }
        let data = Data(text.utf8)
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private final class RecordingCNIManager: CRIShimCNIManaging, @unchecked Sendable {
    private(set) var addCalls: [(sandboxID: String, networkName: String)] = []
    private(set) var deleteCalls: [(sandboxID: String, networkName: String)] = []

    func add(
        sandboxID: String,
        networkName: String,
        config: CRIShimConfig
    ) async throws -> CRIShimCNIResult {
        addCalls.append((sandboxID: sandboxID, networkName: networkName))
        return CRIShimCNIResult(
            networkName: networkName,
            interfaceName: "eth0",
            sandboxURI: "macvmnet://sandbox/\(sandboxID)",
            podIPs: ["192.168.64.10/24"]
        )
    }

    func delete(
        sandboxID: String,
        networkName: String,
        config: CRIShimConfig
    ) async throws {
        deleteCalls.append((sandboxID: sandboxID, networkName: networkName))
    }
}

private final class RecordingImageManager: CRIShimImageManaging, @unchecked Sendable {
    var images: [CRIShimImageRecord]
    var pulledImage: CRIShimImageRecord
    var filesystemUsage: CRIShimImageFilesystemUsage
    private(set) var pulledReferences: [String] = []
    private(set) var pulledAuthentications: [CRIShimImagePullAuthentication?] = []
    private(set) var removedReferences: [String] = []

    init(
        images: [CRIShimImageRecord],
        pulledImage: CRIShimImageRecord = CRIShimImageRecord(
            reference: "example.com/macos/pulled:latest",
            digest: "sha256:pulled",
            size: 0
        ),
        filesystemUsage: CRIShimImageFilesystemUsage = CRIShimImageFilesystemUsage(
            mountpoint: "/var/lib/container-test",
            usedBytes: 0,
            timestampNanoseconds: 1
        )
    ) {
        self.images = images
        self.pulledImage = pulledImage
        self.filesystemUsage = filesystemUsage
    }

    func listImages() async throws -> [CRIShimImageRecord] {
        images
    }

    func pullImage(
        reference: String,
        authentication: CRIShimImagePullAuthentication?
    ) async throws -> CRIShimImageRecord {
        pulledReferences.append(reference)
        pulledAuthentications.append(authentication)
        return pulledImage
    }

    func removeImage(reference: String) async throws {
        removedReferences.append(reference)
    }

    func imageFilesystemUsage() async throws -> CRIShimImageFilesystemUsage {
        filesystemUsage
    }
}

private func waitForSocket(at path: String) async throws {
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: path) {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CRIShimRuntimeServerTestError.socketDidNotStart(path)
}

private func waitForFileContent(
    at path: String,
    containing expectedFragments: [String]
) async throws -> String {
    for _ in 0..<200 {
        if let data = FileManager.default.contents(atPath: path),
            let content = String(data: data, encoding: .utf8),
            expectedFragments.allSatisfy(content.contains)
        {
            return content
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw CRIShimRuntimeServerTestError.fileDidNotContainExpectedContent(path)
}

private func waitForValue<T>(
    description: String,
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(10),
    _ body: () -> T?
) async throws -> T {
    let timeoutNanoseconds =
        max(timeout.components.seconds, 0) * 1_000_000_000
        + Int64(timeout.components.attoseconds / 1_000_000_000)
    let pollNanoseconds = max(
        Int64(pollInterval.components.seconds) * 1_000_000_000
            + Int64(pollInterval.components.attoseconds / 1_000_000_000),
        1_000_000
    )
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(timeoutNanoseconds, 1))

    while DispatchTime.now().uptimeNanoseconds <= deadline {
        if let value = body() {
            return value
        }
        try await Task.sleep(nanoseconds: UInt64(pollNanoseconds))
    }

    throw CRIShimRuntimeServerTestError.timedOut(description)
}

private func waitForCondition(
    description: String,
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(10),
    _ body: () -> Bool
) async throws {
    _ = try await waitForValue(
        description: description,
        timeout: timeout,
        pollInterval: pollInterval
    ) {
        body() ? true : nil
    }
}

private func fileHandleStream(_ handle: FileHandle) -> AsyncStream<Data> {
    AsyncStream { continuation in
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(data)
        }
    }
}

private func makeSocketPair() throws -> (FileHandle, FileHandle) {
    var fileDescriptors = [Int32](repeating: 0, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fileDescriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    return (
        FileHandle(fileDescriptor: fileDescriptors[0], closeOnDealloc: true),
        FileHandle(fileDescriptor: fileDescriptors[1], closeOnDealloc: true)
    )
}

private func makeWebSocketTask(
    from urlString: String,
    protocols: [String]
) throws -> URLSessionWebSocketTask {
    guard var components = URLComponents(string: urlString) else {
        throw POSIXError(.EINVAL)
    }
    if components.scheme == "http" {
        components.scheme = "ws"
    } else if components.scheme == "https" {
        components.scheme = "wss"
    }
    guard let url = components.url else {
        throw POSIXError(.EINVAL)
    }
    return URLSession.shared.webSocketTask(with: url, protocols: protocols)
}

private func resumeWebSocketTask(
    _ task: URLSessionWebSocketTask,
    connectDelay: Duration = .milliseconds(50)
) async throws {
    task.resume()
    try await Task.sleep(for: connectDelay)
}

private func receiveBinaryMessage(
    from task: URLSessionWebSocketTask
) async throws -> Data {
    let message = try await task.receive()
    switch message {
    case .data(let data):
        return data
    case .string(let string):
        throw CRIShimRuntimeServerTestError.unexpectedTextFrame(string)
    @unknown default:
        throw CRIShimRuntimeServerTestError.unexpectedFrame
    }
}

private func portPrefixData(_ port: UInt16) -> Data {
    Data(
        [
            UInt8(truncatingIfNeeded: port & 0x00FF),
            UInt8(truncatingIfNeeded: (port & 0xFF00) >> 8),
        ]
    )
}

private enum CRIShimRuntimeServerTestError: Error {
    case socketDidNotStart(String)
    case fileDidNotContainExpectedContent(String)
    case timedOut(String)
    case unexpectedTextFrame(String)
    case unexpectedFrame
}

extension NSLock {
    fileprivate func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func connectedUnixSocket(path: String) throws -> NIOBSDSocket.Handle {
    #if os(Linux)
    let socketType = CInt(SOCK_STREAM.rawValue)
    #else
    let socketType = SOCK_STREAM
    #endif
    let socket = socket(AF_UNIX, socketType, 0)
    guard socket >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let address = try SocketAddress(unixDomainSocketPath: path)
    try address.withSockAddr { pointer, size in
        guard connect(socket, pointer, UInt32(size)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = close(socket)
            throw error
        }
    }
    return socket
}

private func keyValue(_ key: String, _ value: String) -> Runtime_V1_KeyValue {
    var result = Runtime_V1_KeyValue()
    result.key = key
    result.value = value
    return result
}

private func makeNetworkAttachment(
    network: String,
    address: String,
    gateway: String
) throws -> ContainerResource.Attachment {
    ContainerResource.Attachment(
        network: network,
        hostname: "demo",
        ipv4Address: try CIDRv4(address),
        ipv4Gateway: try IPv4Address(gateway),
        ipv6Address: nil,
        macAddress: nil
    )
}

private func makeSandboxConfiguration(
    id: String,
    labels: [String: String] = [:]
) throws -> SandboxConfiguration {
    let imageJSON = """
        {
          "reference": "example.com/macos/sandbox:latest",
          "descriptor": {
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "digest": "sha256:sandbox",
            "size": 1
          }
        }
        """
    let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
    let process = ProcessConfiguration(
        executable: "/usr/bin/true",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
    var configuration = ContainerConfiguration(id: id, image: image, process: process)
    configuration.runtimeHandler = "container-runtime-macos"
    configuration.labels = labels
    return SandboxConfiguration(containerConfiguration: configuration)
}

private func shutdown(_ group: MultiThreadedEventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CRIShimRuntimeServerTests-\(UUID().uuidString)", isDirectory: true)
}

private let validConfigJSON = """
    {
      "runtimeEndpoint": "/var/run/container-cri-macos.sock",
      "streaming": {
        "address": "127.0.0.1",
        "port": 0
      },
      "cni": {
        "binDir": "/opt/cni/bin",
        "confDir": "/etc/cni/net.d",
        "plugin": "macvmnet"
      },
      "defaults": {
        "sandboxImage": "localhost/macos-sandbox:latest",
        "workloadPlatform": {
          "os": "darwin",
          "architecture": "arm64"
        },
        "network": "default",
        "networkBackend": "vmnetShared",
        "guiEnabled": false
      },
      "runtimeHandlers": {
        "macos": {
          "sandboxImage": "localhost/macos-sandbox:latest",
          "network": "default",
          "networkBackend": "vmnetShared",
          "guiEnabled": false
        }
      },
      "networkPolicy": {
        "enabled": true,
        "kubeconfig": "/etc/kubernetes/kubelet.conf",
        "nodeName": "macos-node-1",
        "resyncSeconds": 30
      },
      "kubeProxy": {
        "enabled": true,
        "configPath": "/etc/kubernetes/kube-proxy.conf"
      }
    }
    """
