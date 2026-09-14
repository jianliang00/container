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

import ContainerizationError
import ContainerizationExtras
import Foundation
import GRPC
import NIO
import RuntimeMacOSSidecarShared
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

@Suite
struct CRIShimRuntimeServerTests {
    @Test
    func runnerCreatesServerAndRunsItAfterValidation() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.stateDirectory = stateDirectory.path
        let factory = RecordingServerFactory()
        let runner = CRIShimRunner(config: config, serverFactory: factory)

        try await runner.run()

        #expect(factory.makeServerCallCount == 1)
        #expect(factory.receivedRuntimeEndpoint == "/var/run/container-cri-macos.sock")
        #expect(factory.server.runCallCount == 1)
    }

    @Test
    func restartedContainerUsesReconciledStateAndQueuesTTYResizeUntilExecStarts() async throws {
        let socketPath = "/tmp/cri-shim-list-reconcile-\(UUID().uuidString.prefix(8)).sock"
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.stateDirectory = stateDirectory.path
        let metadataStore = try CRIShimMetadataStore(rootURL: stateDirectory)
        try metadataStore.upsertSandbox(
            CRIShimSandboxMetadata(
                id: "sandbox-1",
                runtimeHandler: "macos",
                sandboxImage: "example.com/macos/sandbox:latest",
                state: .running,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ))

        let oldContainerID = "old-attempt"
        let newContainerID = "new-attempt"
        for (id, attempt, createdAt) in [
            (oldContainerID, UInt32(0), Date(timeIntervalSince1970: 1_700_000_010)),
            (newContainerID, UInt32(1), Date(timeIntervalSince1970: 1_700_000_020)),
        ] {
            try metadataStore.upsertContainer(
                CRIShimContainerMetadata(
                    id: id,
                    sandboxID: "sandbox-1",
                    name: "workload",
                    attempt: attempt,
                    image: "example.com/macos/workload:latest",
                    runtimeHandler: "macos",
                    logPath: stateDirectory.appendingPathComponent("\(id)/0.log").path,
                    state: .running,
                    createdAt: createdAt,
                    startedAt: createdAt
                ))
        }

        let oldExitDate = Date(timeIntervalSince1970: 1_700_000_030)
        let oldSnapshot = WorkloadSnapshot(
            configuration: WorkloadConfiguration(
                id: oldContainerID,
                processConfiguration: ProcessConfiguration(
                    executable: "/bin/true",
                    arguments: [],
                    environment: []
                )
            ),
            status: .stopped,
            exitCode: 42,
            startedDate: Date(timeIntervalSince1970: 1_700_000_010),
            exitedAt: oldExitDate
        )
        let newSnapshot = WorkloadSnapshot(
            configuration: WorkloadConfiguration(
                id: newContainerID,
                processConfiguration: ProcessConfiguration(
                    executable: "/bin/sleep",
                    arguments: ["infinity"],
                    environment: []
                )
            ),
            status: .running,
            startedDate: Date(timeIntervalSince1970: 1_700_000_020)
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            workloadSnapshots: [
                oldContainerID: oldSnapshot,
                newContainerID: newSnapshot,
            ]
        )
        runtimeManager.streamExecWaitsForStartPermission = true
        runtimeManager.streamExecRejectsResizeBeforeStart = true
        defer { runtimeManager.permitStreamExecStarts() }
        let logManager = RecordingLogManager()
        let streamingServer = CRIShimStreamingServer(
            config: config,
            runtimeManager: runtimeManager
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = CRIShimGRPCServer(
            socketPath: socketPath,
            serviceProviders: [
                CRIShimRuntimeServiceProvider(
                    config: config,
                    metadataStore: metadataStore,
                    runtimeManager: runtimeManager,
                    imageManager: RecordingImageManager(images: []),
                    cniManager: RecordingCNIManager(),
                    logManager: logManager,
                    streamingServer: streamingServer
                )
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

        var runningState = Runtime_V1_ContainerStateValue()
        runningState.state = .containerRunning
        var filter = Runtime_V1_ContainerFilter()
        filter.podSandboxID = "sandbox-1"
        filter.state = runningState
        var listRequest = Runtime_V1_ListContainersRequest()
        listRequest.filter = filter
        let response = try await client.listContainers(listRequest)

        #expect(response.containers.map(\.id) == [newContainerID])
        let oldMetadata = try #require(try metadataStore.container(id: oldContainerID))
        #expect(oldMetadata.state == .exited)
        #expect(oldMetadata.exitedAt == oldExitDate)
        let newMetadata = try #require(try metadataStore.container(id: newContainerID))
        #expect(newMetadata.state == .running)
        #expect(await logManager.stopCalls() == [RecordingLogStopCall(containerID: oldContainerID, removeState: false)])

        var execRequest = Runtime_V1_ExecRequest()
        execRequest.containerID = newContainerID
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

        let process = try await waitForValue(description: "restarted workload exec process") {
            runtimeManager.streamExecProcesses["sandbox-1"]
        }
        try await waitForCondition(description: "restarted workload exec start") {
            process.startCalled
        }
        let terminalSize = CRIShimTerminalSize(width: 120, height: 42)
        try await execTask.send(
            .data(Data([4]) + Data(#"{"Width":120,"Height":42}"#.utf8))
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(process.resizeAttemptsBeforeStart == 0)

        process.permitStart()
        try await waitForCondition(description: "restarted workload exec resize") {
            process.resizeCalls == [terminalSize]
        }
        try await execTask.send(
            .data(Data([0]) + Data("hello after restart\n".utf8))
        )
        let execOutput = try await receiveBinaryMessage(from: execTask)
        #expect(execOutput.first == 1)
        #expect(String(decoding: execOutput.dropFirst(), as: UTF8.self) == "stdout:hello after restart\n")

        try await execTask.send(.data(Data([255])))
        let execStatus = try await receiveBinaryMessage(from: execTask)
        #expect(execStatus.first == 3)
        #expect(String(decoding: execStatus.dropFirst(), as: UTF8.self).contains(#""status":"Success""#))
        let streamExecCall = try #require(runtimeManager.streamExecCalls.last)
        #expect(streamExecCall.containerID == "sandbox-1")
        #expect(streamExecCall.workloadID == newContainerID)

        var statusRequest = Runtime_V1_ContainerStatusRequest()
        statusRequest.containerID = oldContainerID
        let status = try await client.containerStatus(statusRequest)
        #expect(status.status.state == .containerExited)
        #expect(status.status.exitCode == 42)

        var removeRequest = Runtime_V1_RemoveContainerRequest()
        removeRequest.containerID = oldContainerID
        _ = try await client.removeContainer(removeRequest)
        #expect(try metadataStore.container(id: oldContainerID) == nil)

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        await shutdown(group)
    }

    @Test
    func updateRuntimeConfigIgnoresPodCIDRsWhenPodNetworkingIsDisabled() async throws {
        for podNetwork in [nil, PodNetworkConfig(enabled: false)] {
            let socketPath = "/tmp/cri-shim-update-config-\(UUID().uuidString.prefix(8)).sock"
            let stateDirectory = makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: stateDirectory)
                try? FileManager.default.removeItem(atPath: socketPath)
            }

            var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
            config.stateDirectory = stateDirectory.path
            config.podNetwork = podNetwork
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let server = try CRIShimGRPCServer(
                socketPath: socketPath,
                config: config,
                versionInfo: CRIShimRuntimeVersionInfo(),
                eventLoopGroup: group,
                runtimeManager: RecordingRuntimeManager(
                    execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
                ),
                imageManager: RecordingImageManager(images: []),
                cniManager: RecordingCNIManager()
            )
            let serverTask = Task {
                try await server.run()
            }
            defer {
                serverTask.cancel()
            }

            try await waitForSocket(at: socketPath)
            let channel = ClientConnection.insecure(group: group)
                .withConnectedSocket(try connectedUnixSocket(path: socketPath))
            let client = Runtime_V1_RuntimeServiceAsyncClient(channel: channel)
            var request = Runtime_V1_UpdateRuntimeConfigRequest()
            request.runtimeConfig.networkConfig.podCidr = "fd00:42::/64"

            _ = try await client.updateRuntimeConfig(request)
            try await channel.close().get()
            await server.stop()
            try await serverTask.value
            await shutdown(group)
        }
    }

    @Test
    func podSandboxStatusRequiresIPv6GatewayOnPrimaryAttachment() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = CRIShimSandboxMetadata(
            id: "sandbox-1",
            runtimeHandler: "macos",
            sandboxImage: "example.com/macos/sandbox:latest",
            state: .running,
            createdAt: now,
            updatedAt: now
        )
        let snapshot = SandboxSnapshot(
            status: .running,
            networks: [
                try makeNetworkAttachment(
                    network: "primary",
                    address: "192.168.64.20/24",
                    gateway: "192.168.64.1",
                    ipv6Address: "fd42:25e3:5eb4:24a4::20/64"
                ),
                try makeNetworkAttachment(
                    network: "secondary",
                    address: "192.168.65.20/24",
                    gateway: "192.168.65.1",
                    ipv6Address: "fd42:10:244:16::20/64",
                    ipv6Gateway: "fd42:10:244:16::1"
                ),
            ],
            containers: []
        )

        let status = makeCRIPodSandboxStatus(
            metadata,
            sandboxSnapshot: snapshot,
            dualStackEnabled: true
        )
        #expect(status.hasNetwork)
        #expect(status.network.ip == "192.168.64.20")
        #expect(status.network.additionalIps.isEmpty)
    }

    @Test
    func podSandboxStatusPreservesSecondaryIPv4AttachmentsWhenDualStackIsDisabled() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = CRIShimSandboxMetadata(
            id: "sandbox-1",
            runtimeHandler: "macos",
            sandboxImage: "example.com/macos/sandbox:latest",
            state: .running,
            createdAt: now,
            updatedAt: now
        )
        let snapshot = SandboxSnapshot(
            status: .running,
            networks: [
                try makeNetworkAttachment(
                    network: "primary",
                    address: "192.168.64.20/24",
                    gateway: "192.168.64.1"
                ),
                try makeNetworkAttachment(
                    network: "secondary",
                    address: "192.168.65.20/24",
                    gateway: "192.168.65.1"
                ),
            ],
            containers: []
        )

        let status = makeCRIPodSandboxStatus(metadata, sandboxSnapshot: snapshot)
        #expect(status.network.ip == "192.168.64.20")
        #expect(status.network.additionalIps.map(\.ip) == ["192.168.65.20"])
    }

    @Test
    func grpcServerServesVersionOnUnixDomainSocket() async throws {
        let socketPath = "/tmp/cri-shim-grpc-\(UUID().uuidString.prefix(8)).sock"
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let criLogDirectory = stateDirectory.appendingPathComponent("cri-logs", isDirectory: true)
        let podNetworkRuntimeStateURL = stateDirectory.appendingPathComponent("pod-network/runtime.json")
        let podNetworkReadyStateURL = stateDirectory.appendingPathComponent("pod-network/ready.json")
        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.stateDirectory = stateDirectory.path
        config.podNetwork = PodNetworkConfig(
            enabled: true,
            dualStackEnabled: true,
            networkName: "kubernetes-pods",
            runtimeStatePath: podNetworkRuntimeStateURL.path,
            readyStatePath: podNetworkReadyStateURL.path
        )
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
                CRIShimImageRecord(
                    reference: "example.com/macos/workload:stable",
                    digest: "sha256:abc123",
                    size: 4096,
                    annotations: MacOSImageContract.annotations(for: .workload)
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
                processConfiguration: ProcessConfiguration(
                    executable: "/bin/echo",
                    arguments: [],
                    environment: ["USER=admin", "HOME=/Users/admin"],
                    workingDirectory: "/workspace",
                    user: .raw(userString: "admin"),
                    supplementalGroups: [20]
                ),
                workloadImageReference: "example.com/macos/workload:latest",
                workloadImageDigest: "sha256:abc123",
                guestPayloadPath: "/var/lib/container/workloads/container-1/rootfs",
                guestMetadataPath: "/var/lib/container/workloads/container-1/meta.json",
                injectionState: .injected
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
                            gateway: "192.168.64.1",
                            ipv6Address: "fd42:10:244:16::20/64",
                            ipv6Gateway: "fd42:10:244:16::1"
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
            ],
            workloadSnapshots: ["container-1": sandboxWorkloadSnapshot]
        )
        let cniManager = RecordingCNIManager()
        let server = try CRIShimGRPCServer(
            socketPath: socketPath,
            config: config,
            versionInfo: CRIShimRuntimeVersionInfo(
                runtimeName: "container-macos-test",
                runtimeVersion: "1.2.3",
                runtimeAPIVersion: CRIProtocol.runtimeImplementationAPIVersion
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

        #expect(version.version == CRIProtocol.kubeletRuntimeAPIVersion)
        #expect(version.runtimeName == "container-macos-test")
        #expect(version.runtimeVersion == "1.2.3")
        #expect(version.runtimeApiVersion == CRIProtocol.runtimeImplementationAPIVersion)

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
        #expect(runtimeManager.execSyncCalls[0].containerID == "sandbox-1")
        #expect(runtimeManager.execSyncCalls[0].workloadID == "container-1")
        #expect(runtimeManager.execSyncCalls[0].configuration.executable == "/bin/echo")
        #expect(runtimeManager.execSyncCalls[0].configuration.arguments == ["hello"])
        #expect(runtimeManager.execSyncCalls[0].configuration.environment == ["USER=admin", "HOME=/Users/admin"])
        #expect(runtimeManager.execSyncCalls[0].configuration.workingDirectory == "/workspace")
        #expect(runtimeManager.execSyncCalls[0].configuration.user == .raw(userString: "admin"))
        #expect(runtimeManager.execSyncCalls[0].configuration.supplementalGroups == [20])
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

        let recordedProcess = try #require(runtimeManager.streamExecProcesses["sandbox-1"])
        #expect(recordedProcess.started)
        let streamExecCall = try #require(runtimeManager.streamExecCalls.last)
        #expect(streamExecCall.containerID == "sandbox-1")
        #expect(streamExecCall.workloadID == "container-1")
        #expect(streamExecCall.configuration.environment == ["USER=admin", "HOME=/Users/admin"])
        #expect(streamExecCall.configuration.workingDirectory == "/workspace")
        #expect(streamExecCall.configuration.user == .raw(userString: "admin"))
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

        var dynamicPortForwardRequest = Runtime_V1_PortForwardRequest()
        dynamicPortForwardRequest.podSandboxID = "sandbox-1"
        let dynamicPortForward = try await client.portForward(dynamicPortForwardRequest)
        let dynamicPortForwardTask = try makeWebSocketTask(
            from: dynamicPortForward.url,
            protocols: ["portforward.k8s.io"]
        )
        try await resumeWebSocketTask(dynamicPortForwardTask)
        try await dynamicPortForwardTask.send(
            .data(Data([0]) + portPrefixData(9090) + Data("dynamic".utf8))
        )
        let dynamicPortForwardMessage = try await receiveBinaryMessage(from: dynamicPortForwardTask)
        #expect(
            ObservedPortForwardMessage(dynamicPortForwardMessage)
                == ObservedPortForwardMessage(
                    stream: 0,
                    forwardedPort: 9090,
                    payload: "echo:9090:dynamic"
                )
        )
        #expect(
            runtimeManager.portForwardCalls == [
                RecordingPortForwardCall(sandboxID: "sandbox-1", port: 8080),
                RecordingPortForwardCall(sandboxID: "sandbox-1", port: 8081),
                RecordingPortForwardCall(sandboxID: "sandbox-1", port: 9090),
            ]
        )
        execTask.cancel(with: .normalClosure, reason: nil)
        portForwardTask.cancel(with: .normalClosure, reason: nil)
        dynamicPortForwardTask.cancel(with: .normalClosure, reason: nil)

        let runtimeConfig = try await client.runtimeConfig(Runtime_V1_RuntimeConfigRequest())
        #expect(!runtimeConfig.hasLinux)

        _ = try await client.updateRuntimeConfig(Runtime_V1_UpdateRuntimeConfigRequest())
        let podNetworkStateStore = PodNetworkStateStore()
        #expect(try await podNetworkStateStore.loadRuntimeState(path: podNetworkRuntimeStateURL.path) == nil)

        var updateRuntimeConfigRequest = Runtime_V1_UpdateRuntimeConfigRequest()
        updateRuntimeConfigRequest.runtimeConfig.networkConfig.podCidr = "fd42:10:244:16::/64,10.42.1.0/24"
        _ = try await client.updateRuntimeConfig(updateRuntimeConfigRequest)
        let firstPodNetworkState = try #require(
            try await podNetworkStateStore.loadRuntimeState(path: podNetworkRuntimeStateURL.path)
        )
        #expect(firstPodNetworkState.networkName == "kubernetes-pods")
        #expect(firstPodNetworkState.podCIDR == "10.42.1.0/24")
        #expect(firstPodNetworkState.podCIDRs.ipv6 == "fd42:10:244:16::/64")
        #expect(firstPodNetworkState.generation == 1)

        updateRuntimeConfigRequest.runtimeConfig.networkConfig.podCidr = "10.42.1.0/24,fd42:10:244:16::/64"
        _ = try await client.updateRuntimeConfig(updateRuntimeConfigRequest)
        #expect(
            try await podNetworkStateStore.loadRuntimeState(path: podNetworkRuntimeStateURL.path)
                == firstPodNetworkState
        )

        updateRuntimeConfigRequest.runtimeConfig.networkConfig.podCidr = "10.42.2.0/24,fd42:10:244:17::/64"
        _ = try await client.updateRuntimeConfig(updateRuntimeConfigRequest)
        let secondPodNetworkState = try #require(
            try await podNetworkStateStore.loadRuntimeState(path: podNetworkRuntimeStateURL.path)
        )
        #expect(secondPodNetworkState.podCIDR == "10.42.2.0/24")
        #expect(secondPodNetworkState.podCIDRs.ipv6 == "fd42:10:244:17::/64")
        #expect(secondPodNetworkState.generation == 2)
        try await podNetworkStateStore.writeReadyState(
            PodNetworkReadyState(
                networkName: "kubernetes-pods",
                podCIDRs: PodNetworkCIDRs(
                    ipv4: "10.42.2.0/24",
                    ipv6: "fd42:10:244:17::/64"
                ),
                runtimeGeneration: secondPodNetworkState.generation,
                mtu: 1_420,
                expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970.rounded(.down)) + 300,
                ipv4Ready: true,
                ipv6Ready: true
            ),
            path: podNetworkReadyStateURL.path
        )

        let invalidPodCIDR = "fd00:42::/64"
        updateRuntimeConfigRequest.runtimeConfig.networkConfig.podCidr = invalidPodCIDR
        do {
            _ = try await client.updateRuntimeConfig(updateRuntimeConfigRequest)
            Issue.record("expected UpdateRuntimeConfig to reject a non-IPv4 pod CIDR")
        } catch let status as GRPCStatus {
            #expect(status.code == .invalidArgument)
            #expect(!(status.message ?? "").contains(invalidPodCIDR))
        }

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
        #expect(createSandboxCall.initProcess.executable == "/bin/sh")
        #expect(createSandboxCall.initProcess.arguments == ["-c", "trap : TERM INT; while :; do sleep 3600; done"])
        #expect(createSandboxCall.platform.os == "darwin")
        #expect(createSandboxCall.platform.architecture == "arm64")
        #expect(createSandboxCall.runtimeHandler == "container-runtime-macos")
        #expect(createSandboxCall.resources.cpus == 4)
        #expect(createSandboxCall.resources.memoryInBytes == RuntimeResources.defaultMacOSMemoryInBytes)
        #expect(createSandboxCall.macosGuest?.networkBackend == .vmnetShared)
        #expect(createSandboxCall.networks.map(\.network) == ["default"])
        #expect(createSandboxCall.networks.map(\.options.hostname) == [runSandbox.podSandboxID])
        #expect(createSandboxCall.networks.map(\.options.mtu) == [1_420])
        #expect(cniManager.addCalls.count == 1)
        let cniAddCall = try #require(cniManager.addCalls.first)
        #expect(cniAddCall.sandboxID == runSandbox.podSandboxID)
        #expect(cniAddCall.networkName == "default")
        #expect(runtimeManager.startSandboxCalls.isEmpty)

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
        #expect(stopSandboxCall.options.timeoutInSeconds == 0)
        #expect(stopSandboxCall.options.signal == String(SIGKILL))
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
        #expect(sandboxStatus.status.network.additionalIps.map(\.ip) == ["fd42:10:244:16::20"])
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
        let mountedHostPath = stateDirectory.appendingPathComponent("mounted-host", isDirectory: true)
        try FileManager.default.createDirectory(at: mountedHostPath, withIntermediateDirectories: true)
        let hostsPath = stateDirectory.appendingPathComponent("etc-hosts")
        try "127.0.0.1 localhost\n".write(to: hostsPath, atomically: true, encoding: .utf8)
        var mount = Runtime_V1_Mount()
        mount.hostPath = mountedHostPath.path
        mount.containerPath = "/Users/demo/workspace"
        mount.readonly = true
        var hostsMount = Runtime_V1_Mount()
        hostsMount.hostPath = hostsPath.path
        hostsMount.containerPath = "/etc/hosts"
        createRequest.config.mounts = [mount, hostsMount]
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
        #expect(createCall.configuration.mounts.count == 1)
        #expect(createCall.configuration.mounts[0].source == normalizedDirectoryPath(mountedHostPath))
        #expect(createCall.configuration.mounts[0].destination == "/Users/demo/workspace")
        #expect(createCall.configuration.mounts[0].options == ["ro"])
        #expect(createCall.configuration.readOnlyFiles.count == 1)
        #expect(createCall.configuration.readOnlyFiles[0].source == hostsPath.path)
        #expect(createCall.configuration.readOnlyFiles[0].destination == "/etc/hosts")

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
        runtimeManager.stopWorkloadError = CRIShimError.internalError("stopWorkload timed out after workload stopped")
        _ = try await client.stopContainer(stopRequest)
        #expect(runtimeManager.stopWorkloadCalls.count == 1)
        let stopCall = try #require(runtimeManager.stopWorkloadCalls.first)
        #expect(stopCall.sandboxID == "sandbox-1")
        #expect(stopCall.workloadID == created.containerID)
        #expect(stopCall.options.timeoutInSeconds == 2)
        #expect(stopCall.options.signal == String(SIGTERM))

        let stoppedStatus = try await client.containerStatus(createdStatusRequest)
        #expect(stoppedStatus.status.state == .containerExited)
        #expect(stoppedStatus.status.finishedAt > 0)
        #expect(stoppedStatus.status.exitCode == 42)

        var removeRequest = Runtime_V1_RemoveContainerRequest()
        removeRequest.containerID = created.containerID
        runtimeManager.removeWorkloadError = ContainerizationError(
            .internalError,
            message: "failed to remove workload from sandbox",
            cause: OpaqueCRIShimError(
                description: #"internalError: "failed to remove workload" (cause: "notFound: "workload already removed"")"#
            )
        )
        _ = try await client.removeContainer(removeRequest)
        #expect(runtimeManager.removeWorkloadCalls.count == 1)
        let removeCall = try #require(runtimeManager.removeWorkloadCalls.first)
        #expect(removeCall.sandboxID == "sandbox-1")
        #expect(removeCall.workloadID == created.containerID)

        try metadataStore.upsertSandbox(
            CRIShimSandboxMetadata(
                id: "stopped-sandbox",
                runtimeHandler: "macos",
                sandboxImage: "localhost/macos-sandbox:latest",
                state: .stopped,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ))
        try metadataStore.upsertContainer(
            CRIShimContainerMetadata(
                id: "stopped-container",
                sandboxID: "stopped-sandbox",
                name: "workload",
                image: "example.com/macos/workload:latest",
                runtimeHandler: "macos",
                logPath: "/var/log/pods/stopped/workload/0.log",
                state: .exited,
                createdAt: Date(timeIntervalSince1970: 1_700_000_010),
                exitedAt: Date(timeIntervalSince1970: 1_700_000_020)
            ))
        let removeWorkloadCallCount = runtimeManager.removeWorkloadCalls.count
        removeRequest.containerID = "stopped-container"
        _ = try await client.removeContainer(removeRequest)
        #expect(runtimeManager.removeWorkloadCalls.count == removeWorkloadCallCount)
        #expect(try metadataStore.container(id: "stopped-container") == nil)

        let imageClient = Runtime_V1_ImageServiceAsyncClient(channel: channel)
        let listImages = try await imageClient.listImages(Runtime_V1_ListImagesRequest())
        #expect(listImages.images.count == 3)
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
        removeImageRequest.image.image = "sha256:abc123"
        _ = try await imageClient.removeImage(removeImageRequest)
        #expect(
            imageManager.removedReferences == [
                "example.com/macos/workload:latest",
                "example.com/macos/workload:stable",
            ]
        )

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
    func virtualizationNATRunPodSandboxSkipsCNI() async throws {
        let socketPath = "/tmp/cri-shim-nat-\(UUID().uuidString.prefix(8)).sock"
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            stateDirectory: stateDirectory.path,
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            defaults: RuntimeProfile(
                sandboxImage: "localhost/macos-sandbox:latest",
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "virtualizationNAT",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos-compat": RuntimeProfile(networkBackend: "virtualizationNAT")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: false),
            kubeProxy: KubeProxyConfig(enabled: false)
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let imageManager = RecordingImageManager(images: [
            CRIShimImageRecord(
                reference: "localhost/macos-sandbox:latest",
                digest: "sha256:sandbox",
                size: 16_384,
                annotations: ["org.apple.container.macos.image.role": "sandbox"]
            )
        ])
        let cniManager = RecordingCNIManager()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try CRIShimGRPCServer(
            socketPath: socketPath,
            config: config,
            versionInfo: CRIShimRuntimeVersionInfo(),
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
                        status: true,
                        reason: "NATReady",
                        message: "test network ready"
                    )
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

        var runSandboxRequest = Runtime_V1_RunPodSandboxRequest()
        runSandboxRequest.runtimeHandler = "macos-compat"
        runSandboxRequest.config.metadata.uid = "nat-pod-uid"
        runSandboxRequest.config.metadata.namespace = "default"
        runSandboxRequest.config.metadata.name = "nat-pod"
        runSandboxRequest.config.metadata.attempt = 1
        let runSandbox = try await client.runPodSandbox(runSandboxRequest)

        #expect(!runSandbox.podSandboxID.isEmpty)
        #expect(runtimeManager.createSandboxCalls.count == 1)
        let createSandboxCall = try #require(runtimeManager.createSandboxCalls.first)
        #expect(createSandboxCall.macosGuest?.networkBackend == .virtualizationNAT)
        #expect(createSandboxCall.networks.isEmpty)
        #expect(cniManager.addCalls.isEmpty)
        #expect(cniManager.deleteCalls.isEmpty)

        var statusRequest = Runtime_V1_PodSandboxStatusRequest()
        statusRequest.podSandboxID = runSandbox.podSandboxID
        statusRequest.verbose = true
        let status = try await client.podSandboxStatus(statusRequest)
        let metadataInfo = try #require(status.info["metadata"])
        let metadata = try JSONDecoder.criShimMetadataDecoder.decode(
            CRIShimSandboxMetadata.self,
            from: Data(metadataInfo.utf8)
        )
        #expect(metadata.networkLeaseID == nil)
        #expect(metadata.networkAttachments.isEmpty)

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        await shutdown(group)
    }

    @Test
    func stopPodSandboxStopsSandboxWithoutRedundantWorkloadCalls() async throws {
        let socketPath = "/tmp/cri-shim-stop-missing-options-\(UUID().uuidString.prefix(8)).sock"
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            stateDirectory: stateDirectory.path,
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            defaults: RuntimeProfile(
                sandboxImage: "localhost/macos-sandbox:latest",
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "virtualizationNAT",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos-compat": RuntimeProfile(networkBackend: "virtualizationNAT")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: false),
            kubeProxy: KubeProxyConfig(enabled: false)
        )
        let metadataStore = try CRIShimMetadataStore(rootURL: stateDirectory)
        try metadataStore.upsertSandbox(
            CRIShimSandboxMetadata(
                id: "sandbox-1",
                podUID: "pod-uid",
                namespace: "default",
                name: "stop-missing-options",
                attempt: 1,
                runtimeHandler: "macos-compat",
                sandboxImage: "localhost/macos-sandbox:latest",
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
                runtimeHandler: "macos-compat",
                command: ["/bin/true"],
                args: [],
                logPath: stateDirectory.appendingPathComponent("workload/0.log").path,
                state: .running,
                createdAt: Date(timeIntervalSince1970: 1_700_000_010),
                startedAt: Date(timeIntervalSince1970: 1_700_000_020)
            ))

        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.stopWorkloadError = ContainerizationError(
            .internalError,
            message: "failed to stop workload in sandbox",
            cause: OpaqueCRIShimError(
                description:
                    #"unknown: "Error Domain=NSCocoaErrorDomain Code=260 "options.json missing" UserInfo={NSFilePath=/Users/example/Library/Application Support/com.apple.container/containers/container-1/options.json, NSUnderlyingError=0x1 {Error Domain=NSPOSIXErrorDomain Code=2 "No such file or directory"}}"#
            )
        )
        let imageManager = RecordingImageManager(images: [])
        let cniManager = RecordingCNIManager()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = CRIShimGRPCServer(
            socketPath: socketPath,
            serviceProviders: [
                CRIShimRuntimeServiceProvider(
                    config: config,
                    metadataStore: metadataStore,
                    runtimeManager: runtimeManager,
                    imageManager: imageManager,
                    cniManager: cniManager
                ),
                CRIShimImageServiceProvider(imageManager: imageManager),
            ],
            eventLoopGroup: group,
            startupTasks: []
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

        var stopRequest = Runtime_V1_StopPodSandboxRequest()
        stopRequest.podSandboxID = "sandbox-1"
        _ = try await client.stopPodSandbox(stopRequest)

        #expect(runtimeManager.stopWorkloadCalls.isEmpty)
        #expect(runtimeManager.stopSandboxCalls.count == 1)
        let stopSandboxCall = try #require(runtimeManager.stopSandboxCalls.first)
        #expect(stopSandboxCall.options.timeoutInSeconds == 0)
        #expect(stopSandboxCall.options.signal == String(SIGKILL))
        #expect(cniManager.deleteCalls.isEmpty)
        let container = try #require(try metadataStore.container(id: "container-1"))
        #expect(container.state == .exited)
        let sandbox = try #require(try metadataStore.sandbox(id: "sandbox-1"))
        #expect(sandbox.state == .stopped)

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        await shutdown(group)
    }

    @Test
    func stopRequestsTreatStoppedOrMissingRuntimeAsAlreadyStopped() async throws {
        let socketPath = "/tmp/cri-shim-stop-runtime-stopped-\(UUID().uuidString.prefix(8)).sock"
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            stateDirectory: stateDirectory.path,
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            defaults: RuntimeProfile(
                sandboxImage: "localhost/macos-sandbox:latest",
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "virtualizationNAT",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos-compat": RuntimeProfile(networkBackend: "virtualizationNAT")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: false),
            kubeProxy: KubeProxyConfig(enabled: false)
        )
        let metadataStore = try CRIShimMetadataStore(rootURL: stateDirectory)
        try metadataStore.upsertSandbox(
            CRIShimSandboxMetadata(
                id: "sandbox-1",
                podUID: "pod-uid",
                namespace: "default",
                name: "stop-runtime-stopped",
                attempt: 1,
                runtimeHandler: "macos-compat",
                sandboxImage: "localhost/macos-sandbox:latest",
                state: .running,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ))
        for containerID in ["container-1", "container-2"] {
            try metadataStore.upsertContainer(
                CRIShimContainerMetadata(
                    id: containerID,
                    sandboxID: "sandbox-1",
                    name: containerID,
                    attempt: 1,
                    image: "example.com/macos/workload:latest",
                    runtimeHandler: "macos-compat",
                    command: ["/bin/true"],
                    args: [],
                    logPath: stateDirectory.appendingPathComponent("\(containerID)/0.log").path,
                    state: .running,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_010),
                    startedAt: Date(timeIntervalSince1970: 1_700_000_020)
                ))
        }

        let container1Snapshot = WorkloadSnapshot(
            configuration: WorkloadConfiguration(
                id: "container-1",
                processConfiguration: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [])
            ),
            status: .running,
            startedDate: Date(timeIntervalSince1970: 1_700_000_020)
        )
        let container2Snapshot = WorkloadSnapshot(
            configuration: WorkloadConfiguration(
                id: "container-2",
                processConfiguration: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [])
            ),
            status: .running,
            startedDate: Date(timeIntervalSince1970: 1_700_000_020)
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": SandboxSnapshot(
                    configuration: try makeSandboxConfiguration(id: "sandbox-1"),
                    status: .stopped,
                    networks: [],
                    containers: [],
                    workloads: [container1Snapshot, container2Snapshot]
                )
            ],
            workloadSnapshots: [
                "container-1": container1Snapshot,
                "container-2": container2Snapshot,
            ]
        )
        let stoppedRuntimeError = ContainerizationError(
            .internalError,
            message: "failed to stop workload in sandbox",
            cause: ContainerizationError(.invalidState, message: "sandbox not started")
        )
        runtimeManager.stopWorkloadChangesState = false
        runtimeManager.stopWorkloadError = stoppedRuntimeError
        runtimeManager.stopSandboxChangesState = false
        runtimeManager.stopSandboxError = stoppedRuntimeError

        let imageManager = RecordingImageManager(images: [])
        let cniManager = RecordingCNIManager()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = CRIShimGRPCServer(
            socketPath: socketPath,
            serviceProviders: [
                CRIShimRuntimeServiceProvider(
                    config: config,
                    metadataStore: metadataStore,
                    runtimeManager: runtimeManager,
                    imageManager: imageManager,
                    cniManager: cniManager
                ),
                CRIShimImageServiceProvider(imageManager: imageManager),
            ],
            eventLoopGroup: group,
            startupTasks: []
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

        var stopContainerRequest = Runtime_V1_StopContainerRequest()
        stopContainerRequest.containerID = "container-1"
        _ = try await client.stopContainer(stopContainerRequest)
        _ = try await client.stopContainer(stopContainerRequest)

        #expect(runtimeManager.stopWorkloadCalls.count == 1)
        let container1 = try #require(try metadataStore.container(id: "container-1"))
        #expect(container1.state == .exited)

        runtimeManager.inspectWorkloadError = CRIShimError.notFound("workload missing from runtime")
        runtimeManager.inspectSandboxError = CRIShimError.notFound("sandbox missing from runtime")
        stopContainerRequest.containerID = "container-2"
        _ = try await client.stopContainer(stopContainerRequest)
        _ = try await client.stopContainer(stopContainerRequest)

        #expect(runtimeManager.stopWorkloadCalls.map(\.workloadID) == ["container-1", "container-2"])
        let container2 = try #require(try metadataStore.container(id: "container-2"))
        #expect(container2.state == .exited)

        var stopSandboxRequest = Runtime_V1_StopPodSandboxRequest()
        stopSandboxRequest.podSandboxID = "sandbox-1"
        _ = try await client.stopPodSandbox(stopSandboxRequest)

        #expect(runtimeManager.stopWorkloadCalls.map(\.workloadID) == ["container-1", "container-2"])
        #expect(runtimeManager.stopSandboxCalls.count == 1)
        #expect(cniManager.deleteCalls.isEmpty)
        let sandbox = try #require(try metadataStore.sandbox(id: "sandbox-1"))
        #expect(sandbox.state == .stopped)

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        await shutdown(group)
    }

    @Test
    func vmnetRecoveryFenceRejectsRunPodSandboxBeforeImageRuntimeOrCNIWork() async throws {
        let result = try await runVMNetRecoveryAdmissionRejectionScenario(
            gate: .beforeRequestValidation
        )

        #expect(result.grpcCode == .unavailable)
        #expect(result.grpcMessage.contains("state is missing"))
        #expect(result.events.count == 1)
        #expect(result.events.first?.gate == .beforeRequestValidation)
        #expect(result.events.first?.reason == .stateMissing)
        #expect(result.imagePullCount == 0)
        #expect(result.createSandboxCount == 0)
        #expect(result.cniAddCount == 0)
        #expect(result.cniDeleteCount == 0)
        #expect(result.removeSandboxCount == 0)
    }

    @Test
    func vmnetRecoveryFenceRacesAreAttributedAndCleanedUpAtLaterAdmissionGates() async throws {
        let beforeCreate = try await runVMNetRecoveryAdmissionRejectionScenario(
            gate: .beforeSandboxCreate
        )
        #expect(beforeCreate.grpcCode == .unavailable)
        #expect(beforeCreate.events.count == 1)
        #expect(beforeCreate.events.first?.gate == .beforeSandboxCreate)
        #expect(beforeCreate.events.first?.reason == .stateFenced)
        #expect(beforeCreate.createSandboxCount == 0)
        #expect(beforeCreate.cniAddCount == 0)
        #expect(beforeCreate.cniDeleteCount == 0)
        #expect(beforeCreate.removeSandboxCount == 0)

        let beforeNetwork = try await runVMNetRecoveryAdmissionRejectionScenario(
            gate: .beforeNetworkAttach
        )
        #expect(beforeNetwork.grpcCode == .unavailable)
        #expect(beforeNetwork.events.count == 1)
        #expect(beforeNetwork.events.first?.gate == .beforeNetworkAttach)
        #expect(beforeNetwork.events.first?.reason == .stateFenced)
        #expect(beforeNetwork.createSandboxCount == 1)
        #expect(beforeNetwork.cniAddCount == 0)
        #expect(beforeNetwork.cniDeleteCount == 0)
        #expect(beforeNetwork.removeSandboxCount == 1)
    }

    @Test(arguments: [false, true])
    func preparedOrActiveLaunchWithMissingRuntimeRequiresExitProofBeforeRetirement(active: Bool) async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("cri-ms-prepared-cleanup-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(root.path, mode_t(0o700)) == 0)
        let policy = MachineStateConfig(
            enabled: true,
            storageRoot: root.appendingPathComponent("states").path,
            controlSocketRoot: root.appendingPathComponent("control").path,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: [root.appendingPathComponent("nbd").path],
            leaseRoot: root.appendingPathComponent("leases").path
        )
        try CRIShimMachineStateDirectories.prepare(policy: policy)
        let persistenceID = "workload-prepared"
        let storageDirectory = URL(
            fileURLWithPath: policy.normalizedStorageRoot,
            isDirectory: true
        ).appendingPathComponent(persistenceID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(storageDirectory.path, mode_t(0o700)) == 0)
        let acquired = try CRIShimMachineStateLeaseStore.acquire(
            policy: policy,
            machineState: .init(
                persistenceID: persistenceID,
                storageDirectory: storageDirectory.path,
                controlSocketPath: URL(
                    fileURLWithPath: policy.normalizedControlSocketRoot,
                    isDirectory: true
                ).appendingPathComponent("\(persistenceID).sock").path,
                storageGeneration: 1
            ),
            podUID: "pod-prepared",
            proposedSandboxID: "sandbox-prepared"
        )
        let creationStarted = try CRIShimMachineStateLeaseStore.markRuntimeCreationStarted(
            policy: policy,
            expected: acquired.lease
        )
        let launchMarked = try CRIShimMachineStateLeaseStore.markSidecarLaunchMayHaveStarted(
            policy: policy,
            expected: creationStarted
        )

        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let barrier = try #require(launchMarked.sidecarLifecycleBarrier)
        let storageFD = open(storageDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #expect(storageFD >= 0)
        defer { Darwin.close(storageFD) }
        func attestation() throws -> MacOSSidecarLifecycleAttestation {
            try MacOSSidecarLifecycleLock.readAttestation(directoryFD: storageFD, expectedOwnerUID: geteuid())
        }
        let linkedParent = root.appendingPathComponent("linked-states")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: storageDirectory.deletingLastPathComponent())
        #expect(throws: POSIXError.self) {
            _ = try MacOSSidecarLifecycleLock(
                protocolVersion: barrier.protocolVersion,
                persistenceID: persistenceID,
                sandboxID: launchMarked.effectiveRuntimeSandboxID,
                bootNonce: barrier.bootNonce,
                storageDirectory: linkedParent.appendingPathComponent(persistenceID).path
            )
        }
        #expect(try attestation().state == .prepared)
        var sidecarLock: MacOSSidecarLifecycleLock?
        if active {
            sidecarLock = try MacOSSidecarLifecycleLock(
                protocolVersion: barrier.protocolVersion,
                persistenceID: persistenceID,
                sandboxID: launchMarked.effectiveRuntimeSandboxID,
                bootNonce: barrier.bootNonce,
                storageDirectory: String(storageDirectory.path.dropFirst("/private".count))
            )
        }
        runtimeManager.removeSandboxError = ContainerizationError(
            .internalError, message: "failed to delete container",
            cause: ContainerizationError(.notFound, message: "container is absent")
        )
        let cleaner = CRIShimMachineStateRuntimeCleaner(runtimeManager: runtimeManager)
        let invalidOwnerUIDs: [UInt32?] = [nil, .max, UInt32(geteuid()) &+ 1, geteuid() == 0 ? 501 : 0]
        for ownerUID in invalidOwnerUIDs {
            var invalidPolicy = policy
            invalidPolicy.runtimeOwnerUID = ownerUID
            do {
                _ = try await cleaner.cleanup(lease: launchMarked, policy: invalidPolicy)
                Issue.record("cleanup accepted an absent or mismatched runtime owner")
            } catch {
                #expect(!criRuntimeObjectIsNotFound(error))
            }
            #expect(runtimeManager.removeSandboxCalls.isEmpty)
            #expect(runtimeManager.removeSandboxRuntimeServiceCalls.isEmpty)
            #expect(runtimeManager.removeMachineStateSidecarCalls.isEmpty)
            #expect(runtimeManager.confirmSandboxRuntimeRemovedCalls.isEmpty)
            #expect(try CRIShimMachineStateLeaseStore.load(policy: policy, persistenceID: persistenceID)?.admissionState == .runtimeCreationStarted)
            #expect(try attestation().state == (active ? .active : .prepared))
        }
        let trustedPreparation = try await cleaner.prepare(binding: launchMarked, policy: policy)
        var changedPolicy = policy
        changedPolicy.runtimeOwnerUID = UInt32(geteuid()) &+ 1
        await #expect(throws: CRIShimError.unavailable("machine-state runtime owner changed after cleanup preparation")) {
            _ = try await cleaner.cleanupRuntime(binding: launchMarked, policy: changedPolicy, preparation: trustedPreparation)
        }
        #expect(runtimeManager.removeSandboxCalls.isEmpty)
        if active {
            do {
                _ = try await cleaner.cleanup(lease: launchMarked, policy: policy)
                Issue.record("active sidecar lock did not fence cleanup")
            } catch {
                #expect(CRIShimErrorMapper.disposition(for: error).kind == .unavailable)
            }
            #expect(try CRIShimMachineStateLeaseStore.load(policy: policy, persistenceID: persistenceID)?.admissionState == .runtimeCreationStarted)
            #expect(try attestation().state == .active)
            withExtendedLifetime(sidecarLock) {}
            sidecarLock = nil
        }
        let missingRuntimeError = runtimeManager.removeSandboxError
        let failures: [any Error] = [
            POSIXError(.EACCES), POSIXError(.ECONNREFUSED), POSIXError(.ENOENT),
            ContainerizationError(.internalError, message: "untyped notFound: diagnostic"),
        ]
        for failure in failures {
            runtimeManager.removeSandboxError = failure
            do {
                _ = try await cleaner.cleanup(lease: launchMarked, policy: policy)
                Issue.record("uncertain runtime removal released the lease")
            } catch {
                #expect(!criRuntimeObjectIsNotFound(error))
            }
            #expect(try CRIShimMachineStateLeaseStore.load(policy: policy, persistenceID: persistenceID)?.admissionState == .runtimeCreationStarted)
            #expect(try attestation().state == (active ? .active : .prepared))
        }
        runtimeManager.removeSandboxError = missingRuntimeError
        let domainFailure = ContainerizationError(.internalError, message: "launchctl failed with status 125: Domain does not support specified action")
        for failConfirmation in [false, true] {
            runtimeManager.removeSandboxRuntimeServiceError = failConfirmation ? nil : domainFailure
            runtimeManager.confirmSandboxRuntimeRemovedError = failConfirmation ? domainFailure : nil
            do {
                _ = try await cleaner.cleanup(lease: launchMarked, policy: policy)
                Issue.record("launchd domain error allowed lease release")
            } catch let error as ContainerizationError {
                #expect(error == domainFailure)
            }
            #expect(try CRIShimMachineStateLeaseStore.load(policy: policy, persistenceID: persistenceID)?.admissionState == .runtimeCreationStarted)
            #expect(try attestation().state == (active ? .active : .prepared))
        }
        runtimeManager.removeSandboxRuntimeServiceError = nil
        runtimeManager.confirmSandboxRuntimeRemovedError = nil
        let confirmation = try await CRIShimMachineStateRuntimeCleaner(runtimeManager: runtimeManager).cleanup(
            lease: launchMarked,
            policy: policy
        )

        #expect(confirmation.lease.admissionState == .runtimeDeletionConfirmed)
        #expect(try attestation().state == .retired)
        #expect(try attestation().bootNonce == barrier.bootNonce)
        #expect(runtimeManager.removeSandboxCalls.last?.id == launchMarked.effectiveRuntimeSandboxID)
        #expect(runtimeManager.removeSandboxRuntimeServiceCalls.last == launchMarked.effectiveRuntimeSandboxID)
        #expect(runtimeManager.removeSandboxRuntimeServiceOwnerUIDs.last == policy.runtimeOwnerUID)
        #expect(runtimeManager.removeMachineStateSidecarCalls.last?.persistenceID == persistenceID)
        #expect(runtimeManager.confirmSandboxRuntimeRemovedCalls.last?.id == launchMarked.effectiveRuntimeSandboxID)
        #expect(runtimeManager.confirmSandboxRuntimeRemovedCalls.last?.machineStateOwnerUID == policy.runtimeOwnerUID)
        try CRIShimMachineStateLeaseStore.release(policy: policy, expected: confirmation.lease)
        #expect(
            try CRIShimMachineStateLeaseStore.load(policy: policy, persistenceID: persistenceID) == nil
        )

        #expect(throws: (any Error).self) {
            _ = try MacOSSidecarLifecycleLock(
                protocolVersion: barrier.protocolVersion,
                persistenceID: persistenceID,
                sandboxID: launchMarked.effectiveRuntimeSandboxID,
                bootNonce: barrier.bootNonce,
                storageDirectory: storageDirectory.path
            )
        }
    }

    @Test
    func legacyMachineStateCleanupAlwaysRetainsLeaseWithoutProcessAttestation() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("cri-ms-legacy-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(root.path, mode_t(0o700)) == 0)
        let policy = MachineStateConfig(
            enabled: true,
            storageRoot: root.appendingPathComponent("states").path,
            controlSocketRoot: root.appendingPathComponent("control").path,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: [root.appendingPathComponent("nbd").path],
            leaseRoot: root.appendingPathComponent("leases").path
        )
        try CRIShimMachineStateDirectories.prepare(policy: policy)
        let lease = CRIShimMachineStateLease(
            schemaVersion: 1,
            persistenceID: "legacy-workload",
            podUID: "legacy-pod",
            sandboxID: "legacy-sandbox",
            restoreStateID: nil,
            restoreStateGeneration: nil,
            storageGeneration: 1,
            admissionState: nil,
            sidecarLifecycleBarrier: nil
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let cleaner = CRIShimMachineStateRuntimeCleaner(runtimeManager: runtimeManager)

        await #expect(throws: CRIShimError.self) {
            _ = try await cleaner.cleanupRuntime(binding: lease, policy: policy)
        }
        #expect(runtimeManager.stopAndQuitMachineStateSidecarCalls.isEmpty)
        #expect(runtimeManager.removeSandboxCalls.isEmpty)

        let socketPath = URL(fileURLWithPath: policy.normalizedControlSocketRoot, isDirectory: true)
            .appendingPathComponent("legacy-workload.sock", isDirectory: false).path
        let listener = try MachineStateLegacySocketFixture(path: socketPath)
        defer { listener.closeAndRemove() }
        runtimeManager.stopAndQuitMachineStateSidecarHook = { _ in
            listener.closeAndRemove()
        }
        do {
            _ = try await cleaner.cleanupRuntime(binding: lease, policy: policy)
            Issue.record("legacy sidecar cleanup released without a trusted process attestation")
        } catch let error as CRIShimError {
            #expect(error.description.contains("no trusted process-exit proof"))
        }
        #expect(runtimeManager.stopAndQuitMachineStateSidecarCalls == [socketPath])
        #expect(runtimeManager.removeSandboxCalls.last?.id == lease.sandboxID)
        #expect(runtimeManager.confirmSandboxRuntimeRemovedCalls.last?.id == lease.sandboxID)
    }

    @Test
    func machineStateOrphanLeaseIsRecoveredAcrossRestartAndPodRecreation() async throws {
        let socketPath = "/tmp/cri-shim-machine-restart-\(UUID().uuidString.prefix(8)).sock"
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("cri-ms-restart-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(root.path, mode_t(0o700)) == 0)
        let machineRoot = root.appendingPathComponent("machine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: machineRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(machineRoot.path, mode_t(0o700)) == 0)
        let machineStatePolicy = MachineStateConfig(
            enabled: true,
            storageRoot: machineRoot.appendingPathComponent("states").path,
            controlSocketRoot: machineRoot.appendingPathComponent("control").path,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: [machineRoot.appendingPathComponent("nbd").path],
            leaseRoot: machineRoot.appendingPathComponent("leases").path
        )
        try CRIShimMachineStateDirectories.prepare(policy: machineStatePolicy)
        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            stateDirectory: root.appendingPathComponent("metadata").path,
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            defaults: RuntimeProfile(
                sandboxImage: "example.com/macos/sandbox:latest",
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "virtualizationNAT",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos-compat": RuntimeProfile(networkBackend: "virtualizationNAT")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: false),
            kubeProxy: KubeProxyConfig(enabled: false),
            machineState: machineStatePolicy
        )
        let metadataStore = try CRIShimMetadataStore(
            rootURL: URL(fileURLWithPath: config.normalizedStateDirectory, isDirectory: true)
        )
        let crashedStorageDirectory = machineRoot.appendingPathComponent("states/workload-42", isDirectory: true)
        try FileManager.default.createDirectory(
            at: crashedStorageDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(crashedStorageDirectory.path, mode_t(0o700)) == 0)
        let crashedReservation = try CRIShimMachineStateLeaseStore.acquire(
            policy: machineStatePolicy,
            machineState: .init(
                persistenceID: "workload-42",
                storageDirectory: crashedStorageDirectory.path,
                controlSocketPath: machineRoot.appendingPathComponent("control/workload-42.sock").path,
                storageGeneration: 1
            ),
            podUID: "pod-recreated",
            proposedSandboxID: "sandbox-from-crashed-admission"
        )
        #expect(crashedReservation.created)
        let crashedLease = try CRIShimMachineStateLeaseStore.markRuntimeCreationStarted(
            policy: machineStatePolicy,
            expected: crashedReservation.lease
        )

        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let imageManager = RecordingImageManager(
            images: [
                CRIShimImageRecord(
                    reference: "example.com/macos/sandbox:latest",
                    digest: "sha256:sandbox",
                    size: 16_384,
                    annotations: ["org.apple.container.macos.image.role": "sandbox"]
                )
            ]
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = CRIShimGRPCServer(
            socketPath: socketPath,
            serviceProviders: [
                CRIShimRuntimeServiceProvider(
                    config: config,
                    metadataStore: metadataStore,
                    readinessChecker: StaticReadinessChecker(snapshot: readyReadinessSnapshot()),
                    runtimeManager: runtimeManager,
                    imageManager: imageManager,
                    cniManager: RecordingCNIManager()
                )
            ],
            eventLoopGroup: group,
            startupTasks: [
                CRIShimMetadataReconcileStartupTask(
                    metadataStore: metadataStore,
                    runtimeManager: runtimeManager,
                    machineStatePolicy: machineStatePolicy
                )
            ]
        )
        let serverTask = Task { try await server.run() }
        defer {
            serverTask.cancel()
            _ = try? FileManager.default.removeItem(atPath: socketPath)
        }
        try await waitForSocket(at: socketPath)

        let channel = ClientConnection.insecure(group: group)
            .withConnectedSocket(try connectedUnixSocket(path: socketPath))
        let client = Runtime_V1_RuntimeServiceAsyncClient(channel: channel)
        var request = Runtime_V1_RunPodSandboxRequest()
        request.runtimeHandler = "macos-compat"
        request.config.metadata.uid = "pod-recreated"
        request.config.metadata.namespace = "default"
        request.config.metadata.name = "machine-state"
        request.config.annotations = [
            CRIShimMachineStateAnnotation.enabled: "true",
            CRIShimMachineStateAnnotation.persistenceID: "workload-42",
            CRIShimMachineStateAnnotation.storageGeneration: "1",
        ]

        let recovered = try await client.runPodSandbox(request)
        #expect(recovered.podSandboxID != crashedLease.sandboxID)
        #expect(runtimeManager.createSandboxCalls.count == 1)
        #expect(runtimeManager.removeSandboxRuntimeServiceCalls == [crashedLease.effectiveRuntimeSandboxID])
        #expect(runtimeManager.removeMachineStateSidecarCalls.first?.persistenceID == "workload-42")
        let activeLease = try #require(try CRIShimMachineStateLeaseStore.list(policy: machineStatePolicy).first)
        #expect(activeLease.sandboxID == recovered.podSandboxID)
        #expect(activeLease.podUID == "pod-recreated")

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        await shutdown(group)
    }

    @Test(arguments: [false, true])
    func machineStateBindingLeaseMakesACKLossRetryIdempotentAndRefusesTakeover(bootstrapFails: Bool) async throws {
        let socketPath = "/tmp/cri-shim-machine-lease-\(UUID().uuidString.prefix(8)).sock"
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("cri-ms-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(root.path, mode_t(0o700)) == 0)
        let machineRoot = root.appendingPathComponent("machine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: machineRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(machineRoot.path, mode_t(0o700)) == 0)
        let machineStatePolicy = MachineStateConfig(
            enabled: true,
            storageRoot: machineRoot.appendingPathComponent("states").path,
            controlSocketRoot: machineRoot.appendingPathComponent("control").path,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: [machineRoot.appendingPathComponent("nbd").path],
            leaseRoot: machineRoot.appendingPathComponent("leases").path
        )
        try CRIShimMachineStateDirectories.prepare(policy: machineStatePolicy)

        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            stateDirectory: root.appendingPathComponent("metadata").path,
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            defaults: RuntimeProfile(
                sandboxImage: "example.com/macos/sandbox:latest",
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "virtualizationNAT",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos-compat": RuntimeProfile(networkBackend: "virtualizationNAT")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: false),
            kubeProxy: KubeProxyConfig(enabled: false),
            machineState: machineStatePolicy
        )
        let metadataStore = try CRIShimMetadataStore(
            rootURL: URL(fileURLWithPath: config.normalizedStateDirectory, isDirectory: true)
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let imageManager = RecordingImageManager(
            images: [
                CRIShimImageRecord(
                    reference: "example.com/macos/sandbox:latest",
                    digest: "sha256:sandbox",
                    size: 16_384,
                    annotations: ["org.apple.container.macos.image.role": "sandbox"]
                ),
                CRIShimImageRecord(
                    reference: "example.com/macos/workload:latest",
                    digest: "sha256:workload",
                    size: 4096,
                    annotations: MacOSImageContract.annotations(for: .workload)
                ),
            ]
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = CRIShimGRPCServer(
            socketPath: socketPath,
            serviceProviders: [
                CRIShimRuntimeServiceProvider(
                    config: config,
                    metadataStore: metadataStore,
                    readinessChecker: StaticReadinessChecker(snapshot: readyReadinessSnapshot()),
                    runtimeManager: runtimeManager,
                    imageManager: imageManager,
                    cniManager: RecordingCNIManager()
                )
            ],
            eventLoopGroup: group,
            startupTasks: []
        )
        let serverTask = Task { try await server.run() }
        defer {
            serverTask.cancel()
            _ = try? FileManager.default.removeItem(atPath: socketPath)
        }
        try await waitForSocket(at: socketPath)

        let channel = ClientConnection.insecure(group: group)
            .withConnectedSocket(try connectedUnixSocket(path: socketPath))
        let client = Runtime_V1_RuntimeServiceAsyncClient(channel: channel)
        func request(podUID: String, storageGeneration: UInt64) -> Runtime_V1_RunPodSandboxRequest {
            var request = Runtime_V1_RunPodSandboxRequest()
            request.runtimeHandler = "macos-compat"
            request.config.metadata.uid = podUID
            request.config.metadata.namespace = "default"
            request.config.metadata.name = "machine-state"
            request.config.annotations = [
                CRIShimMachineStateAnnotation.enabled: "true",
                CRIShimMachineStateAnnotation.persistenceID: "workload-42",
                CRIShimMachineStateAnnotation.storageGeneration: String(storageGeneration),
            ]
            return request
        }

        let first = try await client.runPodSandbox(request(podUID: "pod-a", storageGeneration: 1))
        let retry = try await client.runPodSandbox(request(podUID: "pod-a", storageGeneration: 1))
        #expect(retry.podSandboxID == first.podSandboxID)
        #expect(runtimeManager.createSandboxCalls.count == 1)

        for fenced in [
            request(podUID: "pod-b", storageGeneration: 1),
            request(podUID: "pod-a", storageGeneration: 2),
        ] {
            do {
                _ = try await client.runPodSandbox(fenced)
                Issue.record("different owner unexpectedly took over a machine-state binding")
            } catch let status as GRPCStatus {
                #expect(status.code == .unavailable)
                #expect((status.message ?? "").contains("fenced"))
            }
        }
        #expect(runtimeManager.createSandboxCalls.count == 1)

        var createContainer = Runtime_V1_CreateContainerRequest()
        createContainer.podSandboxID = first.podSandboxID
        createContainer.config.metadata.name = "workload"
        createContainer.config.image.image = "example.com/macos/workload:latest"
        let createdContainer = try await client.createContainer(createContainer)
        let firstLease = try #require(
            try CRIShimMachineStateLeaseStore.load(
                policy: machineStatePolicy,
                persistenceID: "workload-42"
            )
        )
        let configuredBarrier = try #require(
            runtimeManager.createSandboxCalls.first?.macosGuest?.machineState?.sidecarLifecycleBarrier
        )
        #expect(configuredBarrier.bootNonce == firstLease.sidecarLifecycleBarrier?.bootNonce)
        #expect(throws: CRIShimError.self) {
            try CRIShimMachineStateLeaseStore.release(policy: machineStatePolicy, expected: firstLease)
        }
        var startContainer = Runtime_V1_StartContainerRequest()
        startContainer.containerID = createdContainer.containerID
        runtimeManager.startSandboxHook = {
            throw CRIShimError.unavailable("injected failure at the sandbox start boundary")
        }
        do {
            _ = try await client.startContainer(startContainer)
            Issue.record("injected sandbox start boundary failure was ignored")
        } catch let status as GRPCStatus {
            #expect(status.code == .unavailable)
            #expect((status.message ?? "").contains("injected failure"))
        }
        let launchStartedLease = try #require(
            try CRIShimMachineStateLeaseStore.load(
                policy: machineStatePolicy,
                persistenceID: "workload-42"
            )
        )
        #expect(launchStartedLease.sidecarLifecycleBarrier?.launchMayHaveStarted == true)
        #expect(runtimeManager.startSandboxCalls.count == 1)

        runtimeManager.startSandboxHook = nil
        if !bootstrapFails {
            _ = try await client.startContainer(startContainer)
        }
        try writeTestSidecarLifecycleAttestation(
            policy: machineStatePolicy,
            lease: launchStartedLease,
            state: .active
        )
        if bootstrapFails {
            try await runtimeManager.removeSandbox(id: firstLease.effectiveRuntimeSandboxID, force: true)
            runtimeManager.stopSandboxChangesState = false
            runtimeManager.stopSandboxError = ContainerizationError(
                .internalError, message: "failed to stop container",
                cause: ContainerizationError(.notFound, message: "container is absent")
            )
            runtimeManager.removeSandboxError = ContainerizationError(
                .internalError, message: "failed to delete container",
                cause: ContainerizationError(.notFound, message: "container is absent")
            )
        }

        var remove = Runtime_V1_RemovePodSandboxRequest()
        remove.podSandboxID = first.podSandboxID
        runtimeManager.retainedMachineStateSidecars.insert("workload-42")
        runtimeManager.removeMachineStateSidecarError = CRIShimError.unavailable(
            "machine-state sidecar cleanup is blocked"
        )
        let confirmationsBeforeBlockedCleanup = runtimeManager.confirmSandboxRuntimeRemovedCalls.count
        do {
            _ = try await client.removePodSandbox(remove)
            Issue.record("machine-state lease was released while its sidecar remained present")
        } catch let status as GRPCStatus {
            #expect(status.code == .unavailable)
            #expect((status.message ?? "").contains("sidecar cleanup is blocked"))
        }
        #expect(
            try CRIShimMachineStateLeaseStore.load(
                policy: machineStatePolicy,
                persistenceID: "workload-42"
            ) != nil
        )
        #expect(runtimeManager.confirmSandboxRuntimeRemovedCalls.count == confirmationsBeforeBlockedCleanup)
        #expect(runtimeManager.removeMachineStateSidecarCalls.last?.persistenceID == "workload-42")

        runtimeManager.removeMachineStateSidecarError = nil
        runtimeManager.retainedMachineStateSidecars.remove("workload-42")
        _ = try await client.removePodSandbox(remove)
        #expect(runtimeManager.confirmSandboxRuntimeRemovedCalls.last?.machineStatePersistenceID == "workload-42")
        #expect(
            try CRIShimMachineStateLeaseStore.load(
                policy: machineStatePolicy,
                persistenceID: "workload-42"
            ) == nil
        )

        let removalsAfterRetirement = runtimeManager.removeSandboxCalls.count
        var stop = Runtime_V1_StopPodSandboxRequest()
        stop.podSandboxID = first.podSandboxID
        for _ in 0..<3 {
            _ = try await client.stopPodSandbox(stop)
            _ = try await client.removePodSandbox(remove)
        }
        #expect(runtimeManager.removeSandboxCalls.count == removalsAfterRetirement)
        #expect(try metadataStore.sandbox(id: first.podSandboxID) == nil)
        #expect(try metadataStore.listContainers().filter { $0.sandboxID == first.podSandboxID }.isEmpty)
        runtimeManager.stopSandboxError = nil
        runtimeManager.stopSandboxChangesState = true
        runtimeManager.removeSandboxError = nil

        let successor = try await client.runPodSandbox(request(podUID: "pod-b", storageGeneration: 2))
        #expect(successor.podSandboxID != first.podSandboxID)
        #expect(runtimeManager.createSandboxCalls.count == 2)
        remove.podSandboxID = successor.podSandboxID
        _ = try await client.removePodSandbox(remove)

        let orphan = try await client.runPodSandbox(request(podUID: "pod-b", storageGeneration: 3))
        #expect(orphan.podSandboxID != successor.podSandboxID)
        #expect(runtimeManager.createSandboxCalls.count == 3)

        try metadataStore.deleteSandbox(id: orphan.podSandboxID)
        remove.podSandboxID = orphan.podSandboxID
        do {
            _ = try await client.removePodSandbox(remove)
            Issue.record("missing metadata hid an unreleased durable lease")
        } catch let status as GRPCStatus {
            #expect(status.code == .unavailable)
        }
        do {
            _ = try await client.runPodSandbox(request(podUID: "pod-b", storageGeneration: 3))
            Issue.record("lease without completed metadata was automatically taken over")
        } catch let status as GRPCStatus {
            #expect(status.code == .unavailable)
            #expect((status.message ?? "").contains("refusing automatic takeover"))
        }
        #expect(runtimeManager.createSandboxCalls.count == 3)

        try await runtimeManager.removeSandbox(id: orphan.podSandboxID, force: true)
        do {
            _ = try await client.runPodSandbox(request(podUID: "pod-b", storageGeneration: 3))
            Issue.record("lease was automatically released after runtime creation could have started")
        } catch let status as GRPCStatus {
            #expect(status.code == .unavailable)
            #expect((status.message ?? "").contains("refusing automatic takeover"))
        }
        #expect(runtimeManager.createSandboxCalls.count == 3)

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        await shutdown(group)
    }

    @Test
    func runPodSandboxPullsSandboxImageWhenMissing() async throws {
        let socketPath = "/tmp/cri-shim-sandbox-pull-\(UUID().uuidString.prefix(8)).sock"
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let sandboxImageReference = "ghcr.io/jianliang00/macos-base:15.2"
        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            stateDirectory: stateDirectory.path,
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            defaults: RuntimeProfile(
                sandboxImage: sandboxImageReference,
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "virtualizationNAT",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos-compat": RuntimeProfile(networkBackend: "virtualizationNAT")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: false),
            kubeProxy: KubeProxyConfig(enabled: false)
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let imageManager = RecordingImageManager(
            images: [],
            pulledImage: CRIShimImageRecord(
                reference: sandboxImageReference,
                digest: "sha256:sandbox",
                size: 16_384,
                annotations: ["org.apple.container.macos.image.role": "sandbox"]
            )
        )
        let cniManager = RecordingCNIManager()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try CRIShimGRPCServer(
            socketPath: socketPath,
            config: config,
            versionInfo: CRIShimRuntimeVersionInfo(),
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
                        status: true,
                        reason: "NATReady",
                        message: "test network ready"
                    )
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

        var runSandboxRequest = Runtime_V1_RunPodSandboxRequest()
        runSandboxRequest.runtimeHandler = "macos-compat"
        runSandboxRequest.config.metadata.uid = "pull-pod-uid"
        runSandboxRequest.config.metadata.namespace = "default"
        runSandboxRequest.config.metadata.name = "pull-pod"
        runSandboxRequest.config.metadata.attempt = 1
        let runSandbox = try await client.runPodSandbox(runSandboxRequest)

        #expect(!runSandbox.podSandboxID.isEmpty)
        #expect(imageManager.pulledReferences == [sandboxImageReference])
        #expect(imageManager.pulledAuthentications == [nil])
        #expect(runtimeManager.createSandboxCalls.count == 1)
        let createSandboxCall = try #require(runtimeManager.createSandboxCalls.first)
        #expect(createSandboxCall.image.reference == sandboxImageReference)
        #expect(createSandboxCall.image.digest == "sha256:sandbox")
        #expect(createSandboxCall.networks.isEmpty)
        #expect(cniManager.addCalls.isEmpty)

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        await shutdown(group)
    }

    @Test
    func runPodSandboxAnnotationOverridesSandboxImage() async throws {
        let socketPath = "/tmp/cri-shim-sandbox-annotation-\(UUID().uuidString.prefix(8)).sock"
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let handlerImageReference = "ghcr.io/jianliang00/macos-base:15.2"
        let overrideImageReference = "ghcr.io/jianliang00/macos-base:15.4"
        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            stateDirectory: stateDirectory.path,
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            defaults: RuntimeProfile(
                sandboxImage: "localhost/macos-sandbox:latest",
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "virtualizationNAT",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos-15-2": RuntimeProfile(
                    sandboxImage: handlerImageReference,
                    networkBackend: "virtualizationNAT"
                )
            ],
            networkPolicy: NetworkPolicyConfig(enabled: false),
            kubeProxy: KubeProxyConfig(enabled: false)
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let imageManager = RecordingImageManager(images: [
            CRIShimImageRecord(
                reference: overrideImageReference,
                digest: "sha256:sandbox-154",
                size: 16_384,
                annotations: ["org.apple.container.macos.image.role": "sandbox"]
            )
        ])
        let cniManager = RecordingCNIManager()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try CRIShimGRPCServer(
            socketPath: socketPath,
            config: config,
            versionInfo: CRIShimRuntimeVersionInfo(),
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
                        status: true,
                        reason: "NATReady",
                        message: "test network ready"
                    )
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

        var runSandboxRequest = Runtime_V1_RunPodSandboxRequest()
        runSandboxRequest.runtimeHandler = "macos-15-2"
        runSandboxRequest.config.metadata.uid = "override-pod-uid"
        runSandboxRequest.config.metadata.namespace = "default"
        runSandboxRequest.config.metadata.name = "override-pod"
        runSandboxRequest.config.metadata.attempt = 1
        runSandboxRequest.config.annotations = [
            CRIShimPodAnnotation.sandboxImage: overrideImageReference
        ]
        let runSandbox = try await client.runPodSandbox(runSandboxRequest)

        #expect(!runSandbox.podSandboxID.isEmpty)
        #expect(imageManager.pulledReferences.isEmpty)
        #expect(runtimeManager.createSandboxCalls.count == 1)
        let createSandboxCall = try #require(runtimeManager.createSandboxCalls.first)
        #expect(createSandboxCall.image.reference == overrideImageReference)
        #expect(createSandboxCall.image.digest == "sha256:sandbox-154")
        #expect(createSandboxCall.networks.isEmpty)
        #expect(cniManager.addCalls.isEmpty)

        var statusRequest = Runtime_V1_PodSandboxStatusRequest()
        statusRequest.podSandboxID = runSandbox.podSandboxID
        statusRequest.verbose = true
        let status = try await client.podSandboxStatus(statusRequest)
        let metadataInfo = try #require(status.info["metadata"])
        let metadata = try JSONDecoder.criShimMetadataDecoder.decode(
            CRIShimSandboxMetadata.self,
            from: Data(metadataInfo.utf8)
        )
        #expect(metadata.runtimeHandler == "macos-15-2")
        #expect(metadata.sandboxImage == overrideImageReference)

        try await channel.close().get()
        await server.stop()
        try await serverTask.value
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

        let workloadSnapshot = WorkloadSnapshot(
            configuration: WorkloadConfiguration(
                id: "container-1",
                processConfiguration: ProcessConfiguration(
                    executable: "/bin/cat",
                    arguments: [],
                    environment: []
                )
            ),
            status: .running,
            startedDate: Date(timeIntervalSince1970: 1_700_000_020)
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(
                exitCode: 0,
                stdout: Data(),
                stderr: Data()
            ),
            workloadSnapshots: ["container-1": workloadSnapshot]
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
            runtimeManager.streamExecProcesses["sandbox-1"]
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
    func spdyPortForwardClientWriteFINPreservesBackendResponse() async throws {
        let response = Data("port-forward-response-ready\n".utf8)
        #expect(response.count == 28)

        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardStartDelays[18_080] = .milliseconds(50)
        runtimeManager.portForwardResponsesAfterClientEOF[18_080] = response

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_080]) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.openPortForwardPair(
                requestID: "0",
                port: 18_080,
                errorStreamID: 1,
                dataStreamID: 3,
                closeClientWrite: true
            )

            let result = try await connection.readPortForwardResult(errorStreamID: 1, dataStreamID: 3)
            #expect(result.error.isEmpty)
            #expect(result.data == response)
            #expect(result.errorFinished)
            #expect(result.dataFinished)
            #expect(!result.receivedBackendDataAfterTerminal)
        }

        #expect(
            runtimeManager.portForwardCalls == [
                RecordingPortForwardCall(sandboxID: "sandbox-1", port: 18_080)
            ]
        )
    }

    @Test
    func spdyPortForwardBuffersClientDataUntilDelayedDialCompletes() async throws {
        let request = Data("GET /ready HTTP/1.1\r\nHost: pod\r\n\r\n".utf8)
        let response = Data("port-forward-response-ready\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardStartDelays[18_083] = .milliseconds(50)
        runtimeManager.portForwardResponsesAfterClientEOF[18_083] = response

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_083]) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.openPortForwardPair(
                requestID: "0",
                port: 18_083,
                errorStreamID: 1,
                dataStreamID: 3,
                clientDataChunks: [
                    Data(request.prefix(9)),
                    Data(request.dropFirst(9).prefix(17)),
                    Data(request.dropFirst(26)),
                ],
                closeClientWrite: true
            )

            let result = try await connection.readPortForwardResult(errorStreamID: 1, dataStreamID: 3)
            #expect(result.error.isEmpty)
            #expect(result.data == response)
            #expect(result.dataFinished)
            #expect(!result.receivedBackendDataAfterTerminal)
            let backend = try #require(runtimeManager.portForwardConnections[18_083])
            #expect(backend.receivedInput() == request)
        }
    }

    @Test
    func spdyPortForwardPendingInputOverflowFailsOnlyThatPair() async throws {
        let response = Data("port-forward-response-ready\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardStartDelays[18_084] = .milliseconds(100)
        runtimeManager.portForwardResponsesAfterClientEOF[18_085] = response

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_084, 18_085]) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.openPortForwardPair(
                requestID: "0",
                port: 18_084,
                errorStreamID: 1,
                dataStreamID: 3,
                clientDataChunks: [Data(repeating: 0x61, count: (1 << 20) + 1)],
                closeClientWrite: true
            )

            let overflow = try await connection.readPortForwardResult(errorStreamID: 1, dataStreamID: 3)
            #expect(String(decoding: overflow.error, as: UTF8.self).contains("1048576"))
            #expect(overflow.data.isEmpty)
            #expect(overflow.terminalStreamOrder == [1, 3])
            #expect(!overflow.receivedBackendDataAfterTerminal)

            try await connection.openPortForwardPair(
                requestID: "1",
                port: 18_085,
                errorStreamID: 5,
                dataStreamID: 7,
                closeClientWrite: true
            )
            let recovery = try await connection.readPortForwardResult(errorStreamID: 5, dataStreamID: 7)
            #expect(recovery.error.isEmpty)
            #expect(recovery.data == response)
        }
    }

    @Test
    func spdyPortForwardTinyFrameBacklogIsElementBoundedAndReturnsQuota() async throws {
        let blockedPort: UInt32 = 18_091
        let recoveryPort: UInt32 = 18_092
        let response = Data("port-forward-response-ready\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardNoReadPorts.insert(blockedPort)
        runtimeManager.portForwardResponsesAfterClientEOF[recoveryPort] = response

        try await withSPDYPortForwardServer(
            runtimeManager: runtimeManager,
            ports: [blockedPort, recoveryPort]
        ) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.openPortForwardPair(
                requestID: "tiny-backlog",
                port: blockedPort,
                errorStreamID: 1,
                dataStreamID: 3,
                clientDataChunks: [Data(repeating: 0x61, count: 64 * 1024)],
                closeClientWrite: false
            )
            let blockedConnection = try await waitForValue(
                description: "SPDY tiny-frame blocked backend"
            ) {
                runtimeManager.portForwardConnections[blockedPort]
            }
            try await waitForCondition(description: "SPDY tiny-frame writer blocked") {
                blockedConnection.hasUnreadPeerData()
            }

            for index in 0..<256 {
                try await connection.writeClientData(
                    dataStreamID: 3,
                    payload: Data([UInt8(truncatingIfNeeded: index)])
                )
            }
            let overflow = try await connection.readPortForwardResult(errorStreamID: 1, dataStreamID: 3)
            #expect(String(decoding: overflow.error, as: UTF8.self).contains("256 chunks"))
            #expect(overflow.data.isEmpty)
            #expect(overflow.terminalStreamOrder == [1, 3])
            #expect(!overflow.receivedBackendDataAfterTerminal)
            try await waitForCondition(description: "SPDY tiny-frame writer teardown") {
                blockedConnection.drainPeerAndCheckEOF()
            }

            try await connection.openPortForwardPair(
                requestID: "tiny-backlog-recovery",
                port: recoveryPort,
                errorStreamID: 5,
                dataStreamID: 7,
                closeClientWrite: true
            )
            let recovery = try await connection.readPortForwardResult(errorStreamID: 5, dataStreamID: 7)
            #expect(recovery.error.isEmpty)
            #expect(recovery.data == response)
        }
    }

    @Test
    func spdyPortForwardBackendWriteFailureFailsOnlyThatPair() async throws {
        let response = Data("port-forward-response-ready\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardReadyOnlyPorts.insert(18_086)
        runtimeManager.portForwardHighDescriptorPorts.insert(18_086)
        runtimeManager.portForwardResponsesAfterClientEOF[18_087] = response

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_086, 18_087]) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.openPortForwardPair(
                requestID: "0",
                port: 18_086,
                errorStreamID: 1,
                dataStreamID: 3,
                closeClientWrite: false
            )
            #expect(try await connection.readDataPayload(dataStreamID: 3) == Data("R".utf8))

            let backend = try #require(runtimeManager.portForwardConnections[18_086])
            let (sentinelSource, sentinelPeer) = try makeSocketPair()
            let sentinelSourceFileDescriptor = sentinelSource.fileDescriptor
            let sentinelPeerFileDescriptor = sentinelPeer.fileDescriptor
            let releasedFileDescriptor = backend.shutdownForwardedWriteAndCloseHandle()
            let reusedFileDescriptor = Darwin.fcntl(
                sentinelSourceFileDescriptor,
                F_DUPFD_CLOEXEC,
                releasedFileDescriptor
            )
            guard reusedFileDescriptor >= 0 else {
                throw currentPOSIXError()
            }
            guard reusedFileDescriptor == releasedFileDescriptor else {
                _ = Darwin.close(reusedFileDescriptor)
                throw POSIXError(.EBUSY)
            }
            let reusedHandle = FileHandle(
                fileDescriptor: reusedFileDescriptor,
                closeOnDealloc: true
            )
            try await connection.writeClientData(dataStreamID: 3, payload: Data("request".utf8))

            let failure = try await connection.readPortForwardResult(errorStreamID: 1, dataStreamID: 3)
            #expect(!failure.error.isEmpty)
            #expect(failure.terminalStreamOrder == [1, 3])
            #expect(!failure.receivedBackendDataAfterTerminal)

            var sentinelByte: UInt8 = 0
            let sentinelRead = Darwin.recv(
                sentinelPeerFileDescriptor,
                &sentinelByte,
                1,
                MSG_DONTWAIT
            )
            let sentinelErrno = errno
            #expect(sentinelRead == -1)
            #expect(sentinelErrno == EAGAIN || sentinelErrno == EWOULDBLOCK)
            _ = reusedHandle

            try await connection.openPortForwardPair(
                requestID: "1",
                port: 18_087,
                errorStreamID: 5,
                dataStreamID: 7,
                closeClientWrite: true
            )
            let recovery = try await connection.readPortForwardResult(errorStreamID: 5, dataStreamID: 7)
            #expect(recovery.error.isEmpty)
            #expect(recovery.data == response)
        }
    }

    @Test
    func spdyPortForwardDialFailureFinishesDataStreamAndKeepsSessionUsable() async throws {
        let recoveryResponse = Data("port-forward-response-ready\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardFailurePorts.insert(18_081)
        runtimeManager.portForwardResponsesAfterClientEOF[18_082] = recoveryResponse

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_081, 18_082]) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.openPortForwardPair(
                requestID: "0",
                port: 18_081,
                errorStreamID: 1,
                dataStreamID: 3,
                closeClientWrite: false
            )

            // client-go v1.27.2 waits for the remote data copy to finish before
            // it consumes the error stream. This helper follows that ordering.
            let failure = try await connection.readPortForwardResult(errorStreamID: 1, dataStreamID: 3)
            #expect(!failure.error.isEmpty)
            #expect(failure.data.isEmpty)
            #expect(failure.errorFinished)
            #expect(failure.dataFinished)
            #expect(failure.terminalStreamOrder == [1, 3])
            #expect(!failure.receivedBackendDataAfterTerminal)

            try await connection.openPortForwardPair(
                requestID: "1",
                port: 18_082,
                errorStreamID: 5,
                dataStreamID: 7,
                closeClientWrite: true
            )
            let recovery = try await connection.readPortForwardResult(errorStreamID: 5, dataStreamID: 7)
            #expect(recovery.error.isEmpty)
            #expect(recovery.data == recoveryResponse)
            #expect(recovery.dataFinished)
        }

        #expect(
            runtimeManager.portForwardCalls == [
                RecordingPortForwardCall(sandboxID: "sandbox-1", port: 18_081),
                RecordingPortForwardCall(sandboxID: "sandbox-1", port: 18_082),
            ]
        )
    }

    @Test
    func spdyPortForwardBlockedBackendDoesNotBlockPingOrAnotherPair() async throws {
        let response = Data("second-pair-ready\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardReadyOnlyPorts.insert(18_088)
        runtimeManager.portForwardResponsesAfterClientEOF[18_089] = response

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_088, 18_089]) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.openPortForwardPair(
                requestID: "blocked",
                port: 18_088,
                errorStreamID: 1,
                dataStreamID: 3,
                closeClientWrite: false
            )
            #expect(try await connection.readDataPayload(dataStreamID: 3) == Data("R".utf8))

            try await connection.writeClientData(
                dataStreamID: 3,
                payload: Data(repeating: 0x61, count: 1 << 20)
            )
            try await connection.writePing(id: 42)
            try await connection.readPing(id: 42)

            try await connection.openPortForwardPair(
                requestID: "second",
                port: 18_089,
                errorStreamID: 5,
                dataStreamID: 7,
                closeClientWrite: true
            )
            let second = try await connection.readPortForwardResult(errorStreamID: 5, dataStreamID: 7)
            #expect(second.error.isEmpty)
            #expect(second.data == response)
            #expect(!second.receivedBackendDataAfterTerminal)
        }
    }

    @Test
    func spdyPortForwardRejectsDuplicateOrMismatchedSYNWithoutStartingExtraDial() async throws {
        let response = Data("validated-pair-ready\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardResponsesAfterClientEOF[18_090] = response

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_090, 18_091]) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.writePortForwardSYN(
                streamID: 1,
                requestID: "validated",
                port: 18_090,
                kind: "error",
                closeStream: true
            )
            try await connection.writePortForwardSYN(
                streamID: 1,
                requestID: "other",
                port: 18_090,
                kind: "error"
            )
            try await connection.writePortForwardSYN(
                streamID: 3,
                requestID: "validated",
                port: 18_090,
                kind: "error"
            )
            try await connection.writePortForwardSYN(
                streamID: 5,
                requestID: "validated",
                port: 18_091,
                kind: "data"
            )

            #expect(try await connection.readControlStreamID(type: 3) == 1)
            #expect(try await connection.readControlStreamID(type: 3) == 3)
            #expect(try await connection.readControlStreamID(type: 3) == 5)

            try await connection.writePortForwardSYN(
                streamID: 7,
                requestID: "",
                port: 18_090,
                kind: "error"
            )
            try await connection.writePortForwardSYN(
                streamID: 9,
                requestID: String(repeating: "x", count: 257),
                port: 18_090,
                kind: "error"
            )
            #expect(try await connection.readControlStreamID(type: 3) == 7)
            #expect(try await connection.readControlStreamID(type: 3) == 9)

            try await connection.writePortForwardSYN(
                streamID: 11,
                requestID: "validated",
                port: 18_090,
                kind: "data",
                closeStream: true
            )
            let result = try await connection.readPortForwardResult(errorStreamID: 1, dataStreamID: 11)
            #expect(result.error.isEmpty)
            #expect(result.data == response)
            #expect(!result.receivedBackendDataAfterTerminal)
        }

        #expect(
            runtimeManager.portForwardCalls == [
                RecordingPortForwardCall(sandboxID: "sandbox-1", port: 18_090)
            ]
        )
    }

    @Test
    func spdyPortForwardEnforcesAggregatePendingInputLimitPerSession() async throws {
        let blockedPorts = Array(UInt32(18_100)...UInt32(18_104))
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardReadyOnlyPorts = Set(blockedPorts)

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: blockedPorts) { url in
            let connection = try await TestSPDYConnection(url: url)
            for index in 0..<4 {
                let firstStreamID = UInt32(1 + index * 4)
                try await connection.openPortForwardPair(
                    requestID: "aggregate-\(index)",
                    port: blockedPorts[index],
                    errorStreamID: firstStreamID,
                    dataStreamID: firstStreamID + 2,
                    clientDataChunks: [Data(repeating: UInt8(index), count: 1 << 20)],
                    closeClientWrite: false
                )
            }

            try await connection.openPortForwardPair(
                requestID: "aggregate-overflow",
                port: blockedPorts[4],
                errorStreamID: 17,
                dataStreamID: 19,
                clientDataChunks: [Data([0xFF])],
                closeClientWrite: false
            )
            let overflow = try await connection.readPortForwardResult(errorStreamID: 17, dataStreamID: 19)
            #expect(String(decoding: overflow.error, as: UTF8.self).contains("4194304"))
            #expect(overflow.data.isEmpty)
            #expect(overflow.terminalStreamOrder == [17, 19])
            #expect(!overflow.receivedBackendDataAfterTerminal)

            try await connection.writePing(id: 43)
            try await connection.readPing(id: 43)
        }
    }

    @Test
    func spdyPortForwardBoundsAggregateTinyFrameBacklogAndReturnsQuota() async throws {
        let blockedPorts = Array(UInt32(18_105)...UInt32(18_108))
        let overflowPort: UInt32 = 18_109
        let recoveryPort: UInt32 = 18_111
        let response = Data("aggregate-elements-recovered\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardNoReadPorts = Set(blockedPorts)
        runtimeManager.portForwardResponsesAfterClientEOF[recoveryPort] = response

        try await withSPDYPortForwardServer(
            runtimeManager: runtimeManager,
            ports: blockedPorts + [overflowPort, recoveryPort]
        ) { url in
            let connection = try await TestSPDYConnection(url: url)
            var blockedConnections: [RecordingPortForwardConnection] = []
            for (index, port) in blockedPorts.enumerated() {
                let errorStreamID = UInt32(1 + index * 4)
                let dataStreamID = errorStreamID + 2
                try await connection.openPortForwardPair(
                    requestID: "aggregate-elements-\(index)",
                    port: port,
                    errorStreamID: errorStreamID,
                    dataStreamID: dataStreamID,
                    clientDataChunks: [Data(repeating: UInt8(index), count: 64 * 1024)],
                    closeClientWrite: false
                )
                let backend = try await waitForValue(
                    description: "SPDY aggregate tiny-frame backend \(port)"
                ) {
                    runtimeManager.portForwardConnections[port]
                }
                try await waitForCondition(description: "SPDY aggregate writer blocked \(port)") {
                    backend.hasUnreadPeerData()
                }
                blockedConnections.append(backend)
                for tinyIndex in 0..<255 {
                    try await connection.writeClientData(
                        dataStreamID: dataStreamID,
                        payload: Data([UInt8(truncatingIfNeeded: tinyIndex)])
                    )
                }
            }

            try await connection.openPortForwardPair(
                requestID: "aggregate-elements-overflow",
                port: overflowPort,
                errorStreamID: 17,
                dataStreamID: 19,
                clientDataChunks: [Data([0xFF])],
                closeClientWrite: false
            )
            let overflow = try await connection.readPortForwardResult(errorStreamID: 17, dataStreamID: 19)
            #expect(String(decoding: overflow.error, as: UTF8.self).contains("1024 chunks"))
            #expect(overflow.terminalStreamOrder == [17, 19])

            try await connection.writeRSTStream(streamID: 3)
            try await waitForCondition(description: "SPDY aggregate tiny-frame quota return") {
                blockedConnections[0].drainPeerAndCheckEOF()
            }

            try await connection.openPortForwardPair(
                requestID: "aggregate-elements-recovery",
                port: recoveryPort,
                errorStreamID: 21,
                dataStreamID: 23,
                closeClientWrite: true
            )
            let recovery = try await connection.readPortForwardResult(errorStreamID: 21, dataStreamID: 23)
            #expect(recovery.error.isEmpty)
            #expect(recovery.data == response)
        }
    }

    @Test
    func spdyPortForwardCapsActivePairsAndReturnsQuotaAfterRST() async throws {
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_110]) { url in
            let connection = try await TestSPDYConnection(url: url)
            for index in 0..<64 {
                try await connection.writePortForwardSYN(
                    streamID: UInt32(1 + index * 2),
                    requestID: "active-\(index)",
                    port: 18_110,
                    kind: "error",
                    closeStream: true
                )
            }
            try await connection.writePortForwardSYN(
                streamID: 129,
                requestID: "active-overflow",
                port: 18_110,
                kind: "error"
            )
            #expect(try await connection.readControlStreamID(type: 3) == 129)

            try await connection.writeRSTStream(streamID: 1)
            try await connection.writePortForwardSYN(
                streamID: 131,
                requestID: "active-replacement",
                port: 18_110,
                kind: "error"
            )
            #expect(try await connection.readControlStreamID(type: 2) == 131)
            #expect(runtimeManager.portForwardCalls.isEmpty)
        }
    }

    @Test
    func spdyPortForwardEnforcesAndReturnsServerWideTunnelLeaseAcrossSessions() async throws {
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardReadyOnlyPorts.insert(18_115)

        try await withSPDYPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[18_115], [18_115]],
            maximumActivePortForwardTunnels: 1
        ) { urls in
            let first = try await TestSPDYConnection(url: urls[0])
            let second = try await TestSPDYConnection(url: urls[1])

            try await first.openPortForwardPair(
                requestID: "first-session",
                port: 18_115,
                errorStreamID: 1,
                dataStreamID: 3,
                closeClientWrite: false
            )
            #expect(try await first.readDataPayload(dataStreamID: 3) == Data("R".utf8))

            try await second.writePortForwardSYN(
                streamID: 1,
                requestID: "second-session",
                port: 18_115,
                kind: "error",
                closeStream: true
            )
            try await second.writePortForwardSYN(
                streamID: 3,
                requestID: "second-session",
                port: 18_115,
                kind: "data"
            )
            #expect(try await second.readControlStreamID(type: 3) == 3)

            try await first.writeRSTStream(streamID: 3)
            try await first.writePing(id: 44)
            try await first.readPing(id: 44)

            try await second.writePortForwardSYN(
                streamID: 5,
                requestID: "second-session",
                port: 18_115,
                kind: "data"
            )
            #expect(try await second.readDataPayload(dataStreamID: 5) == Data("R".utf8))
        }

        #expect(runtimeManager.portForwardCalls.count == 2)
    }

    @Test
    func spdyOpeningTunnelLeaseSurvivesRSTUntilCancellationInsensitiveDialReturns() async throws {
        let delayedPort: UInt32 = 18_116
        let recoveryPort: UInt32 = 18_117
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let delayedCallGate = RecordingPortForwardCallGate()
        defer { delayedCallGate.release() }
        runtimeManager.portForwardCallGates[delayedPort] = delayedCallGate
        runtimeManager.portForwardReadyOnlyPorts.insert(recoveryPort)

        try await withSPDYPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[delayedPort], [recoveryPort]],
            maximumActivePortForwardTunnels: 1
        ) { urls in
            let delayed = try await TestSPDYConnection(url: urls[0])
            try await delayed.openPortForwardPair(
                requestID: "cancellation-insensitive-opening",
                port: delayedPort,
                errorStreamID: 1,
                dataStreamID: 3,
                closeClientWrite: false
            )
            try await waitForCondition(description: "SPDY delayed dial entered") {
                delayedCallGate.hasEntered
            }
            try await delayed.writeRSTStream(streamID: 3)

            let recovery = try await TestSPDYConnection(url: urls[1])
            try await recovery.writePortForwardSYN(
                streamID: 1,
                requestID: "opening-lease-recovery",
                port: recoveryPort,
                kind: "error",
                closeStream: true
            )
            try await recovery.writePortForwardSYN(
                streamID: 3,
                requestID: "opening-lease-recovery",
                port: recoveryPort,
                kind: "data"
            )
            #expect(try await recovery.readControlStreamID(type: 3) == 3)
            #expect(
                runtimeManager.portForwardCalls.filter { $0.port == recoveryPort }.isEmpty
            )

            delayedCallGate.release()
            let abandonedBackend = try await waitForValue(
                description: "SPDY cancellation-insensitive dial returned",
                timeout: .seconds(2)
            ) {
                runtimeManager.portForwardConnections[delayedPort]
            }
            try await waitForCondition(description: "SPDY abandoned backend closed") {
                abandonedBackend.drainPeerAndCheckEOF()
            }
            try await Task.sleep(for: .milliseconds(10))

            try await recovery.writePortForwardSYN(
                streamID: 5,
                requestID: "opening-lease-recovery",
                port: recoveryPort,
                kind: "data"
            )
            #expect(try await recovery.readDataPayload(dataStreamID: 5) == Data("R".utf8))
        }
    }

    @Test
    func spdyPortForwardRejectsMalformedFallbackStreamIDsWithoutLosingCompressionState() async throws {
        let response = Data("fallback-ready\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardResponsesAfterClientEOF[18_120] = response

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_120]) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.writePortForwardSYN(
                streamID: 0,
                requestID: nil,
                port: 18_120,
                kind: "data"
            )
            try await connection.writePortForwardSYN(
                streamID: 1,
                requestID: nil,
                port: 18_120,
                kind: "data"
            )
            try await connection.writePortForwardSYN(
                streamID: 2,
                requestID: nil,
                port: 18_120,
                kind: "error"
            )
            #expect(try await connection.readControlStreamID(type: 3) == 0)
            #expect(try await connection.readControlStreamID(type: 3) == 1)
            #expect(try await connection.readControlStreamID(type: 3) == 2)

            try await connection.writePortForwardSYN(
                streamID: 3,
                requestID: nil,
                port: 18_120,
                kind: "error",
                closeStream: true
            )
            try await connection.writePortForwardSYN(
                streamID: 5,
                requestID: nil,
                port: 18_120,
                kind: "data",
                closeStream: true
            )
            let result = try await connection.readPortForwardResult(errorStreamID: 3, dataStreamID: 5)
            #expect(result.error.isEmpty)
            #expect(result.data == response)
            #expect(!result.receivedBackendDataAfterTerminal)
        }
    }

    @Test
    func spdyPortForwardRejectsCompressedHeaderExpansionBeforeDial() async throws {
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_121]) { url in
            let connection = try await TestSPDYConnection(url: url)
            try await connection.writePortForwardSYN(
                streamID: 1,
                requestID: String(repeating: "x", count: 70 * 1024),
                port: 18_121,
                kind: "error"
            )
            try await connection.waitForTransportEOF()
        }

        #expect(runtimeManager.portForwardCalls.isEmpty)
    }

    @Test
    func spdyHeaderInflaterRejectsDecompressedBlocksLargerThan64KiB() throws {
        let deflater = try CRIShimSPDYHeaderDeflater()
        let inflater = try CRIShimSPDYHeaderInflater()
        let compressed = try deflater.compress(Data(repeating: 0x41, count: 70 * 1024))
        #expect(compressed.count < 1024)
        #expect(throws: (any Error).self) {
            _ = try inflater.decompress(compressed)
        }
    }

    @Test
    func spdyPortForwardReclaimsCompletedPairsAcrossManySequentialConnections() async throws {
        let response = Data("x".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardResponsesAfterClientEOF[18_130] = response

        try await withSPDYPortForwardServer(runtimeManager: runtimeManager, ports: [18_130]) { url in
            let connection = try await TestSPDYConnection(url: url)
            for index in 0..<70 {
                let errorStreamID = UInt32(1 + index * 4)
                let dataStreamID = errorStreamID + 2
                try await connection.openPortForwardPair(
                    requestID: "sequential-\(index)",
                    port: 18_130,
                    errorStreamID: errorStreamID,
                    dataStreamID: dataStreamID,
                    closeClientWrite: true
                )
                let result = try await connection.readPortForwardResult(
                    errorStreamID: errorStreamID,
                    dataStreamID: dataStreamID
                )
                #expect(result.error.isEmpty)
                #expect(result.data == response)
                #expect(result.dataFinished)
                #expect(result.errorFinished)
                #expect(!result.receivedBackendDataAfterTerminal)
            }
        }

        #expect(runtimeManager.portForwardCalls.count == 70)
    }

    @Test
    func spdyPendingInputStorageCompactsWithContinuousBacklog() {
        verifyPendingInputStorageCompaction(seed: 0x51)
    }

    @Test
    func websocketPendingInputStorageCompactsWithContinuousBacklog() {
        verifyPendingInputStorageCompaction(seed: 0xA7)
    }

    @Test
    func websocketDynamicPortForwardSerializesInitialFramesAndReturnsTunnelQuota() async throws {
        let firstPort: UInt16 = 18_140
        let secondPort: UInt16 = 18_141
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let firstCallGate = RecordingPortForwardCallGate()
        defer { firstCallGate.release() }
        runtimeManager.portForwardCallGates[UInt32(firstPort)] = firstCallGate
        runtimeManager.portForwardRecordingPorts.insert(UInt32(firstPort))

        try await withObservedWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[]],
            maximumActivePortForwardTunnels: 1
        ) { urls, server in
            let task = try makeWebSocketTask(
                from: urls[0],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(task)
            defer { task.cancel(with: .normalClosure, reason: nil) }

            try await task.send(
                .data(Data([0]) + portPrefixData(firstPort) + Data("first-".utf8))
            )
            try await waitForCondition(description: "first websocket port-forward dial entered") {
                firstCallGate.hasEntered
            }
            try await task.send(
                .data(Data([0]) + portPrefixData(firstPort) + Data("second".utf8))
            )
            try await task.send(
                .data(Data([2]) + portPrefixData(secondPort) + Data("quota".utf8))
            )

            #expect(
                runtimeManager.portForwardCalls.filter { $0.port == UInt32(firstPort) }.count == 1
            )
            #expect(
                ObservedPortForwardMessage(
                    try await receiveBinaryMessage(from: task, timeout: .seconds(2))
                )
                    == ObservedPortForwardMessage(
                        stream: 3,
                        forwardedPort: secondPort,
                        payload: "port-forward server active tunnel limit reached"
                    )
            )
            #expect(runtimeManager.portForwardCalls.count == 1)

            firstCallGate.release()
            try await waitForCondition(description: "ordered websocket port-forward input") {
                runtimeManager.portForwardConnections[UInt32(firstPort)]?.receivedInput()
                    == Data("first-second".utf8)
            }

            let firstConnection = try #require(
                runtimeManager.portForwardConnections[UInt32(firstPort)]
            )
            firstConnection.closePeerConnection()
            try await waitForCondition(description: "websocket port-forward tunnel lease returned") {
                server.activePortForwardTunnelCount == 0
            }

            try await task.send(
                .data(Data([4]) + portPrefixData(secondPort) + Data("second-stream".utf8))
            )
            #expect(
                ObservedPortForwardMessage(
                    try await receiveBinaryMessage(from: task, timeout: .seconds(2))
                )
                    == ObservedPortForwardMessage(
                        stream: 4,
                        forwardedPort: secondPort,
                        payload: "echo:\(secondPort):second-stream"
                    )
            )
            #expect(runtimeManager.portForwardCalls.count == 2)
        }
    }

    @Test
    func websocketPortForwardBlockedStreamDoesNotBlockAnotherStreamAndTearsDownWriter() async throws {
        let blockedPort: UInt16 = 18_145
        let healthyPort: UInt16 = 18_146
        let reuseFirstPort: UInt16 = 18_147
        let reuseSecondPort: UInt16 = 18_148
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardNoReadPorts.insert(UInt32(blockedPort))

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[], []],
            maximumActivePortForwardTunnels: 2
        ) { urls in
            let blockedTask = try makeWebSocketTask(
                from: urls[0],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(blockedTask)

            let blockedInput = Data(repeating: 0x41, count: (1 << 20) - 3)
            try await blockedTask.send(
                .data(Data([0]) + portPrefixData(blockedPort) + blockedInput)
            )
            let blockedConnection = try await waitForValue(
                description: "blocked websocket port-forward connection"
            ) {
                runtimeManager.portForwardConnections[UInt32(blockedPort)]
            }
            try await waitForCondition(description: "blocked websocket backend input") {
                blockedConnection.hasUnreadPeerData()
            }

            try await blockedTask.send(
                .data(Data([2]) + portPrefixData(healthyPort) + Data("healthy".utf8))
            )
            let healthyResponse = try await receiveBinaryMessage(
                from: blockedTask,
                timeout: .seconds(2)
            )
            #expect(
                ObservedPortForwardMessage(healthyResponse)
                    == ObservedPortForwardMessage(
                        stream: 2,
                        forwardedPort: healthyPort,
                        payload: "echo:\(healthyPort):healthy"
                    )
            )

            blockedTask.cancel(with: .normalClosure, reason: nil)
            try await waitForCondition(description: "blocked websocket writer teardown") {
                blockedConnection.drainPeerAndCheckEOF()
            }

            let reuseTask = try makeWebSocketTask(
                from: urls[1],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(reuseTask)
            defer { reuseTask.cancel(with: .normalClosure, reason: nil) }

            try await reuseTask.send(
                .data(Data([0]) + portPrefixData(reuseFirstPort) + Data("one".utf8))
            )
            let firstReuseResponse = try await receiveBinaryMessage(
                from: reuseTask,
                timeout: .seconds(2)
            )
            #expect(
                ObservedPortForwardMessage(firstReuseResponse)
                    == ObservedPortForwardMessage(
                        stream: 0,
                        forwardedPort: reuseFirstPort,
                        payload: "echo:\(reuseFirstPort):one"
                    )
            )

            try await reuseTask.send(
                .data(Data([2]) + portPrefixData(reuseSecondPort) + Data("two".utf8))
            )
            let secondReuseResponse = try await receiveBinaryMessage(
                from: reuseTask,
                timeout: .seconds(2)
            )
            #expect(
                ObservedPortForwardMessage(secondReuseResponse)
                    == ObservedPortForwardMessage(
                        stream: 2,
                        forwardedPort: reuseSecondPort,
                        payload: "echo:\(reuseSecondPort):two"
                    )
            )
        }
    }

    @Test
    func websocketPortForwardPendingInputOverflowFailsOnlyTheAffectedStream() async throws {
        let blockedPort: UInt16 = 18_149
        let healthyPort: UInt16 = 18_150
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardNoReadPorts.insert(UInt32(blockedPort))

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[]],
            maximumActivePortForwardTunnels: 2
        ) { urls in
            let task = try makeWebSocketTask(
                from: urls[0],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(task)
            defer { task.cancel(with: .normalClosure, reason: nil) }

            try await task.send(
                .data(
                    Data([0]) + portPrefixData(blockedPort)
                        + Data(repeating: 0x42, count: 768 * 1024)
                )
            )
            let blockedConnection = try await waitForValue(
                description: "quota websocket port-forward connection"
            ) {
                runtimeManager.portForwardConnections[UInt32(blockedPort)]
            }
            try await waitForCondition(description: "quota websocket backend input") {
                blockedConnection.hasUnreadPeerData()
            }

            try await task.send(
                .data(
                    Data([0]) + portPrefixData(blockedPort)
                        + Data(repeating: 0x43, count: 300 * 1024)
                )
            )
            try await task.send(
                .data(Data([2]) + portPrefixData(healthyPort) + Data("still-healthy".utf8))
            )

            let messages = try await [
                receiveBinaryMessage(from: task, timeout: .seconds(2)),
                receiveBinaryMessage(from: task, timeout: .seconds(2)),
            ]
            let observed = messages.map(ObservedPortForwardMessage.init)
            let failure = try #require(observed.first { $0.stream == 1 })
            #expect(failure.forwardedPort == blockedPort)
            #expect(failure.payload.contains("pending input exceeded 1048576 bytes"))
            #expect(
                observed.contains(
                    ObservedPortForwardMessage(
                        stream: 2,
                        forwardedPort: healthyPort,
                        payload: "echo:\(healthyPort):still-healthy"
                    ))
            )
            try await waitForCondition(description: "overflowed websocket writer teardown") {
                blockedConnection.drainPeerAndCheckEOF()
            }
        }
    }

    @Test
    func websocketPortForwardTinyFrameBacklogIsElementBoundedAndReturnsQuota() async throws {
        let blockedPort: UInt16 = 18_157
        let healthyPort: UInt16 = 18_158
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardNoReadPorts.insert(UInt32(blockedPort))

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[]],
            maximumActivePortForwardTunnels: 2
        ) { urls in
            let task = try makeWebSocketTask(
                from: urls[0],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(task)
            defer { task.cancel(with: .normalClosure, reason: nil) }

            try await task.send(
                .data(
                    Data([0]) + portPrefixData(blockedPort)
                        + Data(repeating: 0x41, count: 64 * 1024)
                )
            )
            let blockedConnection = try await waitForValue(
                description: "tiny-frame websocket blocked backend"
            ) {
                runtimeManager.portForwardConnections[UInt32(blockedPort)]
            }
            try await waitForCondition(description: "tiny-frame websocket writer blocked") {
                blockedConnection.hasUnreadPeerData()
            }

            for index in 0..<256 {
                try await task.send(
                    .data(
                        Data([0]) + portPrefixData(blockedPort)
                            + Data([UInt8(truncatingIfNeeded: index)])
                    )
                )
            }
            try await task.send(
                .data(Data([2]) + portPrefixData(healthyPort) + Data("healthy".utf8))
            )

            let messages = try await [
                receiveBinaryMessage(from: task, timeout: .seconds(2)),
                receiveBinaryMessage(from: task, timeout: .seconds(2)),
            ]
            let observed = messages.map(ObservedPortForwardMessage.init)
            let failure = try #require(observed.first { $0.stream == 1 })
            #expect(failure.forwardedPort == blockedPort)
            #expect(failure.payload.contains("256 chunks"))
            #expect(
                observed.contains(
                    ObservedPortForwardMessage(
                        stream: 2,
                        forwardedPort: healthyPort,
                        payload: "echo:\(healthyPort):healthy"
                    ))
            )
            try await waitForCondition(description: "tiny-frame websocket writer teardown") {
                blockedConnection.drainPeerAndCheckEOF()
            }
        }
    }

    @Test
    func websocketPortForwardAggregatePendingInputOverflowFailsOnlyNewStream() async throws {
        let blockedPorts: [UInt16] = [18_151, 18_152, 18_153, 18_154]
        let overflowPort: UInt16 = 18_155
        let healthyPort: UInt16 = 18_156
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardNoReadPorts = Set(blockedPorts.map(UInt32.init))

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[]],
            maximumActivePortForwardTunnels: 5
        ) { urls in
            let task = try makeWebSocketTask(
                from: urls[0],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(task)
            defer { task.cancel(with: .normalClosure, reason: nil) }

            var blockedConnections: [RecordingPortForwardConnection] = []
            for (index, port) in blockedPorts.enumerated() {
                let stream = UInt8(index * 2)
                try await task.send(
                    .data(
                        Data([stream]) + portPrefixData(port)
                            + Data(repeating: stream, count: (1 << 20) - 3)
                    )
                )
                let connection = try await waitForValue(
                    description: "aggregate websocket port-forward connection \(port)"
                ) {
                    runtimeManager.portForwardConnections[UInt32(port)]
                }
                try await waitForCondition(
                    description: "aggregate websocket backend input \(port)"
                ) {
                    connection.hasUnreadPeerData()
                }
                blockedConnections.append(connection)
            }

            try await task.send(
                .data(Data([8]) + portPrefixData(overflowPort) + Data(repeating: 0x45, count: 13))
            )
            try await task.send(
                .data(Data([10]) + portPrefixData(healthyPort) + Data("x".utf8))
            )

            let messages = try await [
                receiveBinaryMessage(from: task, timeout: .seconds(2)),
                receiveBinaryMessage(from: task, timeout: .seconds(2)),
            ]
            let observed = messages.map(ObservedPortForwardMessage.init)
            let failure = try #require(observed.first { $0.stream == 9 })
            #expect(failure.forwardedPort == overflowPort)
            #expect(failure.payload.contains("session pending input exceeded 4194304 bytes"))
            #expect(
                observed.contains(
                    ObservedPortForwardMessage(
                        stream: 10,
                        forwardedPort: healthyPort,
                        payload: "echo:\(healthyPort):x"
                    ))
            )

            task.cancel(with: .normalClosure, reason: nil)
            for (index, connection) in blockedConnections.enumerated() {
                try await waitForCondition(
                    description: "aggregate websocket writer teardown \(blockedPorts[index])"
                ) {
                    connection.drainPeerAndCheckEOF()
                }
            }
        }
    }

    @Test
    func websocketPortForwardBoundsAggregateTinyFramesAndReusesReleasedQuota() async throws {
        let blockedPorts: [UInt16] = [18_160, 18_161, 18_162, 18_163]
        let overflowPort: UInt16 = 18_164
        let healthyPort: UInt16 = 18_165
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardNoReadPorts = Set(blockedPorts.map(UInt32.init))

        try await withObservedWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[]],
            maximumActivePortForwardTunnels: 5
        ) { urls, server in
            let task = try makeWebSocketTask(
                from: urls[0],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(task)
            defer { task.cancel(with: .normalClosure, reason: nil) }

            var blockedConnections: [RecordingPortForwardConnection] = []
            for (index, port) in blockedPorts.enumerated() {
                let stream = UInt8(index * 2)
                try await task.send(
                    .data(
                        Data([stream]) + portPrefixData(port)
                            + Data(repeating: stream, count: 64 * 1024)
                    )
                )
                let connection = try await waitForValue(
                    description: "aggregate tiny-frame websocket backend \(port)"
                ) {
                    runtimeManager.portForwardConnections[UInt32(port)]
                }
                try await waitForCondition(
                    description: "aggregate tiny-frame websocket writer \(port)"
                ) {
                    connection.hasUnreadPeerData()
                }
                blockedConnections.append(connection)
                for tinyIndex in 0..<255 {
                    try await task.send(
                        .data(
                            Data([stream]) + portPrefixData(port)
                                + Data([UInt8(truncatingIfNeeded: tinyIndex)])
                        )
                    )
                }
            }

            try await task.send(
                .data(Data([8]) + portPrefixData(overflowPort) + Data([0xFF]))
            )
            let failureMessage = try await receiveBinaryMessage(from: task, timeout: .seconds(2))
            let failure = ObservedPortForwardMessage(failureMessage)
            #expect(failure.stream == 9)
            #expect(failure.forwardedPort == overflowPort)
            #expect(failure.payload.contains("1024 chunks"))

            blockedConnections[0].closePeerConnection()
            try await waitForCondition(description: "aggregate tiny-frame quota return") {
                server.activePortForwardTunnelCount == 3
            }
            try await task.send(
                .data(Data([10]) + portPrefixData(healthyPort) + Data("recovered".utf8))
            )
            var recoveryMessage: ObservedPortForwardMessage?
            for _ in 0..<2 {
                let message = ObservedPortForwardMessage(
                    try await receiveBinaryMessage(from: task, timeout: .seconds(2))
                )
                if message.stream == 10 {
                    recoveryMessage = message
                    break
                }
                #expect(message.stream == 1)
                #expect(message.forwardedPort == blockedPorts[0])
            }
            #expect(
                recoveryMessage
                    == ObservedPortForwardMessage(
                        stream: 10,
                        forwardedPort: healthyPort,
                        payload: "echo:\(healthyPort):recovered"
                    )
            )
        }
    }

    @Test
    func websocketFixedPortSlowDialBoundsPredispatchBytesAndReturnsLease() async throws {
        let delayedPort: UInt16 = 18_300
        let recoveryPort: UInt16 = 18_301
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardStartDelays[UInt32(delayedPort)] = .seconds(5)

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[UInt32(delayedPort)], [UInt32(recoveryPort)]],
            maximumActivePortForwardTunnels: 1
        ) { urls in
            let delayed = try await TestRawWebSocketConnection(
                url: urls[0],
                protocolName: "portforward.k8s.io"
            )
            let fullFrame =
                Data([0]) + portPrefixData(delayedPort)
                + Data(repeating: 0x41, count: (1 << 20) - 3)
            for _ in 0..<4 {
                try await delayed.sendBinary(fullFrame)
            }
            try? await delayed.sendBinary(Data([0]) + portPrefixData(delayedPort) + Data([0x42]))

            try await waitForCondition(
                description: "websocket predispatch byte overflow cancels dial",
                timeout: .seconds(5)
            ) {
                runtimeManager.cancelledPortForwardCalls.contains(
                    RecordingPortForwardCall(
                        sandboxID: "sandbox-1",
                        port: UInt32(delayedPort)
                    ))
            }

            let recovery = try makeWebSocketTask(
                from: urls[1],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(recovery)
            defer { recovery.cancel(with: .normalClosure, reason: nil) }
            try await recovery.send(
                .data(Data([0]) + portPrefixData(recoveryPort) + Data("recovered".utf8))
            )
            let message = try await receiveBinaryMessage(from: recovery, timeout: .seconds(2))
            #expect(
                ObservedPortForwardMessage(message)
                    == ObservedPortForwardMessage(
                        stream: 0,
                        forwardedPort: recoveryPort,
                        payload: "echo:\(recoveryPort):recovered"
                    )
            )
        }
    }

    @Test
    func websocketFixedPortSlowDialBoundsPredispatchFrameCountAndReturnsLease() async throws {
        let delayedPort: UInt16 = 18_302
        let recoveryPort: UInt16 = 18_303
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardStartDelays[UInt32(delayedPort)] = .seconds(5)

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[UInt32(delayedPort)], [UInt32(recoveryPort)]],
            maximumActivePortForwardTunnels: 1
        ) { urls in
            let delayed = try await TestRawWebSocketConnection(
                url: urls[0],
                protocolName: "portforward.k8s.io"
            )
            let tinyFrame = Data([0]) + portPrefixData(delayedPort)
            for _ in 0..<257 {
                try? await delayed.sendBinary(tinyFrame)
            }

            try await waitForCondition(
                description: "websocket predispatch frame overflow cancels dial",
                timeout: .seconds(5)
            ) {
                runtimeManager.cancelledPortForwardCalls.contains(
                    RecordingPortForwardCall(
                        sandboxID: "sandbox-1",
                        port: UInt32(delayedPort)
                    ))
            }

            let recovery = try makeWebSocketTask(
                from: urls[1],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(recovery)
            defer { recovery.cancel(with: .normalClosure, reason: nil) }
            try await recovery.send(
                .data(Data([0]) + portPrefixData(recoveryPort) + Data("recovered".utf8))
            )
            let message = try await receiveBinaryMessage(from: recovery, timeout: .seconds(2))
            #expect(
                ObservedPortForwardMessage(message)
                    == ObservedPortForwardMessage(
                        stream: 0,
                        forwardedPort: recoveryPort,
                        payload: "echo:\(recoveryPort):recovered"
                    )
            )
        }
    }

    @Test
    func websocketSlowReaderFatalFrameStopsBackendOutputAndReturnsLease() async throws {
        let outputPort: UInt16 = 18_304
        let recoveryPort: UInt16 = 18_305
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardContinuousOutputPorts.insert(UInt32(outputPort))

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[UInt32(outputPort)], [UInt32(recoveryPort)]],
            maximumActivePortForwardTunnels: 1
        ) { urls in
            let slowReader = try await TestRawWebSocketConnection(
                url: urls[0],
                protocolName: "portforward.k8s.io"
            )
            try await slowReader.limitReceiveBuffer(to: 4 * 1024)
            let outputConnection = try await waitForValue(
                description: "websocket continuous-output backend"
            ) {
                runtimeManager.portForwardConnections[UInt32(outputPort)]
            }

            var lastByteCount = -1
            var stableSamples = 0
            try await waitForCondition(
                description: "websocket slow-reader output backpressure",
                timeout: .seconds(5),
                pollInterval: .milliseconds(50)
            ) {
                let byteCount = outputConnection.outputByteCount
                if byteCount > 0, byteCount == lastByteCount {
                    stableSamples += 1
                } else {
                    stableSamples = 0
                    lastByteCount = byteCount
                }
                return stableSamples >= 4
            }

            try await slowReader.sendText("unsupported")
            try await waitForCondition(
                description: "websocket slow-reader backend output teardown",
                timeout: .seconds(5)
            ) {
                outputConnection.outputHasStopped
            }

            let recovery = try makeWebSocketTask(
                from: urls[1],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(recovery)
            defer { recovery.cancel(with: .normalClosure, reason: nil) }
            try await recovery.send(
                .data(Data([0]) + portPrefixData(recoveryPort) + Data("recovered".utf8))
            )
            let message = try await receiveBinaryMessage(from: recovery, timeout: .seconds(2))
            #expect(
                ObservedPortForwardMessage(message)
                    == ObservedPortForwardMessage(
                        stream: 0,
                        forwardedPort: recoveryPort,
                        payload: "echo:\(recoveryPort):recovered"
                    )
            )
        }
    }

    @Test
    func websocketStreamFailureOrdersTerminalAfterInflightDataAndRejectsLateData() async throws {
        let failingPort: UInt16 = 18_310
        let recoveryPort: UInt16 = 18_311
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardContinuousOutputPorts.insert(UInt32(failingPort))

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[UInt32(failingPort)], [UInt32(recoveryPort)]],
            maximumActivePortForwardTunnels: 1
        ) { urls in
            let slowReader = try await TestRawWebSocketConnection(
                url: urls[0],
                protocolName: "portforward.k8s.io"
            )
            try await slowReader.limitReceiveBuffer(to: 4 * 1024)
            let failingConnection = try await waitForValue(
                description: "websocket ordered-terminal backend"
            ) {
                runtimeManager.portForwardConnections[UInt32(failingPort)]
            }

            var lastByteCount = -1
            var stableSamples = 0
            try await waitForCondition(
                description: "websocket ordered-terminal blocked output",
                timeout: .seconds(5),
                pollInterval: .milliseconds(50)
            ) {
                let byteCount = failingConnection.outputByteCount
                if byteCount > 0, byteCount == lastByteCount {
                    stableSamples += 1
                } else {
                    stableSamples = 0
                    lastByteCount = byteCount
                }
                return stableSamples >= 4
            }

            try await slowReader.sendBinary(
                Data([0]) + portPrefixData(failingPort)
                    + Data(repeating: 0x61, count: (1 << 20) - 3)
            )
            try await slowReader.sendBinary(
                Data([0]) + portPrefixData(failingPort) + Data(repeating: 0x62, count: 4)
            )

            var sawDataBeforeTerminal = false
            var sawTerminal = false
            for _ in 0..<256 {
                let frame = try await slowReader.readServerFrame()
                guard frame.opcode == 0x02, let stream = frame.payload.first else {
                    continue
                }
                if stream == 0 {
                    sawDataBeforeTerminal = true
                } else if stream == 1 {
                    sawTerminal = true
                    break
                }
            }
            #expect(sawDataBeforeTerminal)
            #expect(sawTerminal)

            try await slowReader.sendPing()
            var sawLateData = false
            var sawPong = false
            for _ in 0..<32 {
                let frame = try await slowReader.readServerFrame()
                if frame.opcode == 0x0A {
                    sawPong = true
                    break
                }
                if frame.opcode == 0x02, frame.payload.first == 0 {
                    sawLateData = true
                }
            }
            #expect(sawPong)
            #expect(!sawLateData)
            try await waitForCondition(description: "websocket ordered-terminal backend stopped") {
                failingConnection.outputHasStopped
            }

            let recovery = try makeWebSocketTask(
                from: urls[1],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(recovery)
            defer { recovery.cancel(with: .normalClosure, reason: nil) }
            try await recovery.send(
                .data(Data([0]) + portPrefixData(recoveryPort) + Data("recovered".utf8))
            )
            let recoveryMessage = try await receiveBinaryMessage(
                from: recovery,
                timeout: .seconds(2)
            )
            #expect(
                ObservedPortForwardMessage(recoveryMessage)
                    == ObservedPortForwardMessage(
                        stream: 0,
                        forwardedPort: recoveryPort,
                        payload: "echo:\(recoveryPort):recovered"
                    )
            )
        }
    }

    @Test
    func websocketPortForwardOutboundSequenceOrdersTerminalAndCancelsQueuedWork() async throws {
        let sequence = CRIShimPortForwardOutboundSequence()
        let dataGate = RecordingPortForwardCallGate()
        let recorder = PortForwardOutboundOperationRecorder()

        let dataTask = Task {
            await sequence.sendData {
                await dataGate.wait()
                recorder.append("data")
                return true
            }
        }
        try await waitForCondition(description: "outbound DATA operation entered") {
            dataGate.hasEntered
        }

        let terminalTask = Task {
            await sequence.sendTerminal {
                recorder.append("terminal")
            }
        }
        try await waitForCondition(description: "outbound terminal queued") {
            sequence.pendingWorkCount == 2
        }
        #expect(recorder.events.isEmpty)

        dataGate.release()
        let dataResult = await dataTask.value
        await terminalTask.value
        #expect(dataResult == true)
        #expect(recorder.events == ["data", "terminal"])

        let lateResult = await sequence.sendData {
            recorder.append("late-data")
            return true
        }
        #expect(lateResult == nil)
        #expect(recorder.events == ["data", "terminal"])

        let stoppedSequence = CRIShimPortForwardOutboundSequence()
        let stoppedGate = RecordingPortForwardCallGate()
        let stoppedRecorder = PortForwardOutboundOperationRecorder()
        let blockingTask = Task {
            await stoppedSequence.sendData {
                await stoppedGate.wait()
                stoppedRecorder.append("blocking-data")
                return true
            }
        }
        try await waitForCondition(description: "stopped outbound DATA operation entered") {
            stoppedGate.hasEntered
        }
        let queuedTask = Task {
            await stoppedSequence.sendData {
                stoppedRecorder.append("queued-data")
                return true
            }
        }
        try await waitForCondition(description: "stopped outbound work queued") {
            stoppedSequence.pendingWorkCount == 2
        }

        stoppedSequence.stop()
        #expect(stoppedSequence.pendingWorkCount == 0)
        stoppedGate.release()
        _ = await blockingTask.value
        _ = await queuedTask.value
        #expect(!stoppedRecorder.events.contains("queued-data"))
    }

    @Test
    func spdyControlWriteGateCapsPendingResponsesAndFailsOnce() {
        let capacityGate = CRIShimSPDYControlWriteGate()
        for _ in 0..<64 {
            #expect(capacityGate.reserve(isActive: true, isWritable: true))
        }
        #expect(!capacityGate.reserve(isActive: true, isWritable: true))
        for _ in 0..<64 {
            #expect(!capacityGate.complete(succeeded: true))
        }

        let failureGate = CRIShimSPDYControlWriteGate()
        #expect(failureGate.reserve(isActive: true, isWritable: true))
        #expect(failureGate.complete(succeeded: false))
        #expect(!failureGate.complete(succeeded: false))
        #expect(!failureGate.reserve(isActive: true, isWritable: true))

        let unwritableGate = CRIShimSPDYControlWriteGate()
        #expect(!unwritableGate.reserve(isActive: true, isWritable: false))
        #expect(!unwritableGate.reserve(isActive: true, isWritable: true))
    }

    @Test
    func spdyPingFloodWithoutReadsRemainsBoundedAndReturnsLease() async throws {
        let floodPort: UInt32 = 18_306
        let recoveryPort: UInt32 = 18_307
        let response = Data("spdy-control-recovered\n".utf8)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardNoReadPorts.insert(floodPort)
        runtimeManager.portForwardResponsesAfterClientEOF[recoveryPort] = response

        try await withSPDYPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[floodPort], [recoveryPort]],
            maximumActivePortForwardTunnels: 1
        ) { urls in
            let flooded = try await TestSPDYConnection(url: urls[0])
            try await flooded.limitReceiveBuffer(to: 4 * 1024)
            try await flooded.openPortForwardPair(
                requestID: "control-flood",
                port: floodPort,
                errorStreamID: 1,
                dataStreamID: 3,
                closeClientWrite: false
            )
            let floodBackend = try await waitForValue(description: "SPDY control-flood backend") {
                runtimeManager.portForwardConnections[floodPort]
            }
            try await flooded.writePingBurst(count: 256)
            flooded.closeTransport()
            try await waitForCondition(
                description: "SPDY control-flood cleanup",
                timeout: .seconds(5)
            ) {
                floodBackend.drainPeerAndCheckEOF()
            }

            let recovery = try await TestSPDYConnection(url: urls[1])
            try await recovery.openPortForwardPair(
                requestID: "control-flood-recovery",
                port: recoveryPort,
                errorStreamID: 1,
                dataStreamID: 3,
                closeClientWrite: true
            )
            let result = try await recovery.readPortForwardResult(errorStreamID: 1, dataStreamID: 3)
            #expect(result.error.isEmpty)
            #expect(result.data == response)
        }
    }

    @Test
    func websocketPingFloodWithoutReadsRemainsBoundedAndReturnsLease() async throws {
        let floodPort: UInt16 = 18_308
        let recoveryPort: UInt16 = 18_309
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        runtimeManager.portForwardRecordingPorts.insert(UInt32(floodPort))

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[UInt32(floodPort)], [UInt32(recoveryPort)]],
            maximumActivePortForwardTunnels: 1
        ) { urls in
            let flooded = try await TestRawWebSocketConnection(
                url: urls[0],
                protocolName: "portforward.k8s.io"
            )
            try await flooded.limitReceiveBuffer(to: 4 * 1024)
            let floodBackend = try await waitForValue(description: "websocket ping-flood backend") {
                runtimeManager.portForwardConnections[UInt32(floodPort)]
            }
            try await flooded.sendPingBurst(count: 256)
            try await flooded.sendBinary(
                Data([0]) + portPrefixData(floodPort) + Data("after-flood".utf8)
            )
            try await waitForCondition(
                description: "websocket ping-flood input remains live",
                timeout: .seconds(5)
            ) {
                floodBackend.receivedInput() == Data("after-flood".utf8)
            }
            flooded.closeTransport()
            try await waitForCondition(description: "websocket ping-flood cleanup") {
                floodBackend.drainPeerAndCheckEOF()
            }

            let recovery = try makeWebSocketTask(
                from: urls[1],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(recovery)
            defer { recovery.cancel(with: .normalClosure, reason: nil) }
            try await recovery.send(
                .data(Data([0]) + portPrefixData(recoveryPort) + Data("recovered".utf8))
            )
            let message = try await receiveBinaryMessage(from: recovery, timeout: .seconds(2))
            #expect(
                ObservedPortForwardMessage(message)
                    == ObservedPortForwardMessage(
                        stream: 0,
                        forwardedPort: recoveryPort,
                        payload: "echo:\(recoveryPort):recovered"
                    )
            )
        }
    }

    @Test
    func websocketDynamicPortForwardRejectsPortChangeWithoutSecondDial() async throws {
        let firstPort: UInt16 = 18_143
        let changedPort: UInt16 = 18_144
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[]],
            maximumActivePortForwardTunnels: 2
        ) { urls in
            let task = try makeWebSocketTask(
                from: urls[0],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(task)
            defer { task.cancel(with: .normalClosure, reason: nil) }

            try await task.send(
                .data(Data([0]) + portPrefixData(firstPort) + Data("first".utf8))
            )
            let response = try await receiveBinaryMessage(from: task, timeout: .seconds(2))
            #expect(
                ObservedPortForwardMessage(response)
                    == ObservedPortForwardMessage(
                        stream: 0,
                        forwardedPort: firstPort,
                        payload: "echo:\(firstPort):first"
                    )
            )

            try await task.send(
                .data(Data([0]) + portPrefixData(changedPort) + Data("changed".utf8))
            )
            try await expectWebSocketReceiveFailure(task)
            #expect(runtimeManager.portForwardCalls.count == 1)
        }
    }

    @Test
    func websocketPortForwardRejectsMoreThanRepresentableStreams() async throws {
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )
        let ports = Array(UInt32(18_200)...UInt32(18_328))
        #expect(ports.count == 129)

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [ports],
            maximumActivePortForwardTunnels: 256
        ) { urls in
            let task = try makeWebSocketTask(
                from: urls[0],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(task)
            defer { task.cancel(with: .normalClosure, reason: nil) }

            try await expectWebSocketReceiveFailure(task)
            #expect(runtimeManager.portForwardCalls.isEmpty)
        }
    }

    @Test
    func websocketBinaryReceiveTimeoutCancelsUnderlyingTask() async throws {
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )

        try await withWebSocketPortForwardServer(
            runtimeManager: runtimeManager,
            portSets: [[]],
            maximumActivePortForwardTunnels: 1
        ) { urls in
            let task = try makeWebSocketTask(
                from: urls[0],
                protocols: ["portforward.k8s.io"]
            )
            try await resumeWebSocketTask(task)
            defer { task.cancel(with: .normalClosure, reason: nil) }

            do {
                _ = try await receiveBinaryMessage(from: task, timeout: .milliseconds(100))
                Issue.record("expected websocket receive to time out")
            } catch CRIShimRuntimeServerTestError.timedOut(let description) {
                #expect(description == "websocket binary message")
            } catch {
                Issue.record("expected websocket receive timeout, got \(error)")
            }
        }
    }

    @Test
    func backendControlConnectionIgnoresDelayedShutdownAfterDescriptorReuse() async throws {
        var controlledDescriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &controlledDescriptors) == 0 else {
            throw currentPOSIXError()
        }
        let minimum = try criShimHighDescriptorMinimum()
        let controlledFileDescriptor = Darwin.fcntl(
            controlledDescriptors[0],
            F_DUPFD_CLOEXEC,
            minimum
        )
        let duplicateErrno = errno
        _ = Darwin.close(controlledDescriptors[0])
        guard controlledFileDescriptor >= 0 else {
            _ = Darwin.close(controlledDescriptors[1])
            throw POSIXError(POSIXErrorCode(rawValue: duplicateErrno) ?? .EIO)
        }
        let controlledPeerFileDescriptor = controlledDescriptors[1]
        defer { _ = Darwin.close(controlledPeerFileDescriptor) }
        let controlConnection = CRIShimBackendControlConnection(owning: controlledFileDescriptor)

        let (sentinelSource, sentinelPeer) = try makeSocketPair()
        let sentinelPeerFileDescriptor = sentinelPeer.fileDescriptor
        controlConnection.shutdownAllAndClose()
        let reusedFileDescriptor = Darwin.fcntl(
            sentinelSource.fileDescriptor,
            F_DUPFD_CLOEXEC,
            controlledFileDescriptor
        )
        guard reusedFileDescriptor >= 0 else {
            throw currentPOSIXError()
        }
        guard reusedFileDescriptor == controlledFileDescriptor else {
            _ = Darwin.close(reusedFileDescriptor)
            throw POSIXError(.EBUSY)
        }
        let reusedHandle = FileHandle(
            fileDescriptor: reusedFileDescriptor,
            closeOnDealloc: true
        )

        let delayedShutdown = Task.detached {
            try? controlConnection.shutdownWrite()
        }
        _ = await delayedShutdown.result

        var sentinelByte: UInt8 = 0
        let sentinelRead = Darwin.recv(
            sentinelPeerFileDescriptor,
            &sentinelByte,
            1,
            MSG_DONTWAIT
        )
        let sentinelErrno = errno
        #expect(sentinelRead == -1)
        #expect(sentinelErrno == EAGAIN || sentinelErrno == EWOULDBLOCK)
        _ = reusedHandle
    }

    @Test
    func fileHandleStreamYieldsSmallWriteBeforeEOFAndCancels() async throws {
        let pipe = Pipe()
        let input = try fileHandleStream(pipe.fileHandleForReading)
        let recorder = FileHandleStreamRecorder()
        let consumer = Task {
            for await data in input.bytes {
                recorder.append(data)
            }
            recorder.markConsumerFinished()
        }
        defer {
            input.cancel()
            consumer.cancel()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        let expected = Data("small-output".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: expected)
        try await waitForCondition(
            description: "small file handle stream write",
            timeout: .seconds(30)
        ) {
            recorder.snapshot().data == expected
        }

        input.cancel()
        try await waitForCondition(description: "file handle stream cancellation") {
            recorder.snapshot().consumerFinished
        }
        _ = await consumer.result

        #expect(recorder.snapshot().data == expected)
    }

    @Test
    func fileHandleStreamBoundsPendingBytesAndElementsAndResumesAfterAcknowledgement() async throws {
        do {
            let (source, sink) = try makeSocketPair()
            let input = try fileHandleStream(
                source,
                maximumPendingBytes: 4,
                maximumPendingElements: 256
            )
            defer {
                input.cancel()
                try? source.close()
                try? sink.close()
            }

            try sink.write(contentsOf: Data([1, 2, 3, 4]))
            try await waitForCondition(description: "file stream byte quota") {
                input.pendingByteCount == 4 && input.pendingElementCount == 1
            }
            try sink.write(contentsOf: Data([5, 6, 7, 8]))
            try await Task.sleep(for: .milliseconds(50))
            #expect(input.pendingByteCount == 4)
            #expect(input.pendingElementCount == 1)

            var iterator = input.bytes.makeAsyncIterator()
            let first = await iterator.next()
            #expect(first == Data([1, 2, 3, 4]))
            input.acknowledge(first?.count ?? 0)
            try await waitForCondition(description: "file stream byte quota resume") {
                input.pendingByteCount == 4 && input.pendingElementCount == 1
            }

            input.cancel()
            #expect(input.pendingByteCount == 0)
            #expect(input.pendingElementCount == 0)
        }

        do {
            let (source, sink) = try makeSocketPair()
            let input = try fileHandleStream(
                source,
                maximumPendingBytes: 1 << 20,
                maximumPendingElements: 4
            )
            defer {
                input.cancel()
                try? source.close()
                try? sink.close()
            }

            for index in 0..<4 {
                try sink.write(contentsOf: Data([UInt8(index)]))
                try await waitForCondition(description: "file stream element quota \(index)") {
                    input.pendingElementCount == index + 1
                }
            }
            #expect(input.pendingByteCount == 4)
            #expect(input.pendingElementCount == 4)

            try sink.write(contentsOf: Data([4]))
            try await Task.sleep(for: .milliseconds(50))
            #expect(input.pendingByteCount == 4)
            #expect(input.pendingElementCount == 4)

            var iterator = input.bytes.makeAsyncIterator()
            let first = await iterator.next()
            #expect(first == Data([0]))
            input.acknowledge(first?.count ?? 0)
            try await waitForCondition(description: "file stream element quota resume") {
                input.pendingByteCount == 4 && input.pendingElementCount == 4
            }

            input.cancel()
            #expect(input.pendingByteCount == 0)
            #expect(input.pendingElementCount == 0)
        }
    }

    @Test
    func fileHandleStreamReadsDataWrittenAfterAcknowledgementAndIdleGap() async throws {
        let (source, sink) = try makeSocketPair()
        let input = try fileHandleStream(
            source,
            maximumPendingBytes: 4,
            maximumPendingElements: 1
        )
        let recorder = FileHandleStreamRecorder()
        let consumer = Task {
            for await data in input.bytes {
                recorder.append(data)
                input.acknowledge(data.count)
            }
            recorder.markConsumerFinished()
        }
        defer {
            input.cancel()
            consumer.cancel()
            try? source.close()
            try? sink.close()
        }

        let first = Data([1, 2, 3, 4])
        try sink.write(contentsOf: first)
        try await waitForCondition(description: "file stream first acknowledged write") {
            recorder.snapshot().data == first
                && input.pendingByteCount == 0
                && input.pendingElementCount == 0
        }

        try await Task.sleep(for: .milliseconds(100))
        let second = Data([5, 6, 7, 8])
        try sink.write(contentsOf: second)
        try await waitForCondition(description: "file stream write after idle gap") {
            recorder.snapshot().data == first + second
                && input.pendingByteCount == 0
                && input.pendingElementCount == 0
        }

        input.cancel()
        try await waitForCondition(description: "file stream idle-gap cancellation") {
            recorder.snapshot().consumerFinished
        }
        _ = await consumer.result
    }

    @Test
    func fileHandleStreamOwnsDuplicateAfterOriginalHandleCloses() async throws {
        let pipe = Pipe()
        let input = try fileHandleStream(pipe.fileHandleForReading)
        let recorder = FileHandleStreamRecorder()
        let consumer = Task {
            for await data in input.bytes {
                recorder.append(data)
            }
            recorder.markConsumerFinished()
        }
        defer {
            input.cancel()
            consumer.cancel()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        try pipe.fileHandleForReading.close()
        let expected = Data("duplicate-owned-output".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: expected)
        try pipe.fileHandleForWriting.close()

        try await waitForCondition(
            description: "duplicate file descriptor EOF",
            timeout: .seconds(30)
        ) {
            recorder.snapshot().consumerFinished
        }
        _ = await consumer.result

        #expect(recorder.snapshot().data == expected)
    }

    @Test
    func fileHandleStreamReadsPastChunkBoundaryAndFinishesAtEOF() async throws {
        let pipe = Pipe()
        let input = try fileHandleStream(pipe.fileHandleForReading)
        let recorder = FileHandleStreamRecorder()
        let consumer = Task {
            for await data in input.bytes {
                recorder.append(data)
            }
            recorder.markConsumerFinished()
        }
        defer {
            input.cancel()
            consumer.cancel()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        let expected = Data(repeating: 0xA5, count: 128 * 1024 + 17)
        let writeDescriptor = pipe.fileHandleForWriting.fileDescriptor
        let writeFlags = Darwin.fcntl(writeDescriptor, F_GETFL)
        guard writeFlags >= 0, Darwin.fcntl(writeDescriptor, F_SETFL, writeFlags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let producer = Task {
            do {
                var offset = 0
                while offset < expected.count {
                    try Task.checkCancellation()
                    let result = expected.withUnsafeBytes { buffer in
                        Darwin.write(
                            writeDescriptor,
                            buffer.baseAddress?.advanced(by: offset),
                            buffer.count - offset
                        )
                    }
                    if result > 0 {
                        offset += result
                        continue
                    }
                    if result < 0, errno == EINTR {
                        continue
                    }
                    if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        try await Task.sleep(for: .milliseconds(1))
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try pipe.fileHandleForWriting.close()
                recorder.markProducerFinished(errorDescription: nil)
            } catch {
                try? pipe.fileHandleForWriting.close()
                recorder.markProducerFinished(errorDescription: String(describing: error))
            }
        }

        do {
            try await waitForCondition(
                description: "large file handle stream transfer",
                timeout: .seconds(30)
            ) {
                let snapshot = recorder.snapshot()
                return snapshot.producerFinished && snapshot.consumerFinished
            }
        } catch {
            input.cancel()
            consumer.cancel()
            producer.cancel()
            try? pipe.fileHandleForReading.close()
            _ = await producer.result
            _ = await consumer.result
            throw error
        }
        _ = await producer.result
        _ = await consumer.result

        let snapshot = recorder.snapshot()
        #expect(snapshot.producerErrorDescription == nil)
        #expect(snapshot.data == expected)
    }

    @Test
    func fileHandleStreamSurvivesCancellationAndCloseRaces() async throws {
        for iteration in 0..<256 {
            let pipe = Pipe()
            let input = try fileHandleStream(pipe.fileHandleForReading)
            let recorder = FileHandleStreamRecorder()
            let consumer = Task {
                for await data in input.bytes {
                    recorder.append(data)
                }
                recorder.markConsumerFinished()
            }

            try pipe.fileHandleForWriting.write(contentsOf: Data([UInt8(iteration & 0xFF)]))
            async let cancelInput: Void = input.cancel()
            async let closeReader: Void = { try? pipe.fileHandleForReading.close() }()
            async let closeWriter: Void = { try? pipe.fileHandleForWriting.close() }()
            _ = await (cancelInput, closeReader, closeWriter)

            try await waitForCondition(
                description: "file handle stream close race iteration \(iteration)",
                timeout: .seconds(1)
            ) {
                recorder.snapshot().consumerFinished
            }
            _ = await consumer.result
        }
    }

    @Test
    func streamingProcessKillWhileStartIsBlockedDoesNotReadClosedHandle() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let process = RecordingStreamingProcess(
            stdin: stdinPipe.fileHandleForReading,
            stdout: stdoutPipe.fileHandleForWriting,
            stderr: nil,
            waitsForStartPermission: true
        )
        let startTask = Task {
            try await process.start()
        }
        func teardown() async {
            process.permitStart()
            startTask.cancel()
            _ = await startTask.result
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            _ = try? await process.wait()
        }

        do {
            try await waitForCondition(description: "blocked streaming process start") {
                process.startCalled
            }
            try await process.kill(SIGTERM)
            process.permitStart()
            try await startTask.value

            #expect(try await process.wait() == 128 + SIGTERM)
        } catch {
            await teardown()
            throw error
        }

        await teardown()
    }

    @Test
    func synchronizedStreamingProcessCompletesStartAfterConcurrentKillFails() async throws {
        let rawProcess = ControlledStreamingProcess()
        let process = CRIShimStartSynchronizedStreamingProcess(process: rawProcess)
        let startRecorder = StreamingOperationRecorder()
        let startTask = Task {
            do {
                try await process.start()
                startRecorder.finish(errorDescription: nil)
            } catch {
                startRecorder.finish(errorDescription: String(describing: error))
            }
        }
        var killTask: Task<String?, Never>?
        do {
            try await waitForCondition(description: "controlled streaming process start") {
                rawProcess.startCallCount == 1
            }
            killTask = Task {
                do {
                    try await process.kill(SIGTERM)
                    return nil
                } catch {
                    return String(describing: error)
                }
            }
            try await waitForCondition(description: "controlled streaming process kill") {
                rawProcess.killCallCount == 1
            }

            rawProcess.completeStart()
            try await waitForAsyncCondition(description: "start waiting for kill outcome") {
                await process.isWaitingForTerminationOutcome
            }
            #expect(!startRecorder.snapshot().finished)

            rawProcess.failKill()
            try await waitForCondition(description: "streaming process start after failed kill") {
                startRecorder.snapshot().finished
            }
            _ = await startTask.result
            #expect(startRecorder.snapshot().errorDescription == nil)
            #expect(await killTask?.value != nil)

            let size = CRIShimTerminalSize(width: 120, height: 40)
            try await process.resize(size)
            #expect(rawProcess.resizeCalls == [size])
        } catch {
            rawProcess.completeStart()
            rawProcess.failKill()
            _ = await startTask.result
            _ = await killTask?.result
            throw error
        }
    }

    @Test
    func concurrentLifecycleQueriesPreserveRunningAfterTransientWorkloadGap() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .running,
                    workloads: [runningWorkload]
                )
            ],
            workloadSnapshots: ["container-1": runningWorkload]
        )
        runtimeManager.inspectWorkloadResults["container-1"] = [nil, runningWorkload]

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            async let listed = client.listContainers(Runtime_V1_ListContainersRequest())
            async let containerStatus = client.containerStatus(
                Runtime_V1_ContainerStatusRequest.with { $0.containerID = "container-1" }
            )
            async let sandboxStatus = client.podSandboxStatus(
                Runtime_V1_PodSandboxStatusRequest.with { $0.podSandboxID = "sandbox-1" }
            )

            let (listResponse, containerResponse, sandboxResponse) = try await (
                listed,
                containerStatus,
                sandboxStatus
            )
            #expect(listResponse.containers.map(\.state) == [.containerRunning])
            #expect(containerResponse.status.state == .containerRunning)
            #expect(containerResponse.status.finishedAt == 0)
            #expect(sandboxResponse.status.state == .sandboxReady)
            #expect(sandboxResponse.containersStatuses.map(\.state) == [.containerRunning])
        }

        let stored = try #require(try metadataStore.container(id: "container-1"))
        #expect(stored.state == .running)
        #expect(stored.exitedAt == nil)
        #expect(stored.exitCode == nil)
    }

    @Test
    func sandboxStatusAndListPreserveReadyAfterTransientRuntimeGap() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let runningSandbox = makeLifecycleSandboxSnapshot(
            status: .running,
            workloads: [runningWorkload]
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: ["sandbox-1": runningSandbox],
            workloadSnapshots: ["container-1": runningWorkload]
        )
        runtimeManager.inspectSandboxResults["sandbox-1"] = [nil, runningSandbox]

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            let status = try await client.podSandboxStatus(
                Runtime_V1_PodSandboxStatusRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            #expect(status.status.state == .sandboxReady)

            runtimeManager.inspectSandboxResults["sandbox-1"] = [nil, runningSandbox]
            let listed = try await client.listPodSandbox(Runtime_V1_ListPodSandboxRequest())
            #expect(listed.items.map(\.state) == [.sandboxReady])
        }

        #expect(try metadataStore.sandbox(id: "sandbox-1")?.state == .running)
    }

    @Test
    func confirmedMissingSandboxPreservesReadyWhenWorkloadIsRunning() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            workloadSnapshots: ["container-1": runningWorkload]
        )

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            let status = try await client.podSandboxStatus(
                Runtime_V1_PodSandboxStatusRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            #expect(status.status.state == .sandboxReady)
            #expect(status.containersStatuses.map(\.state) == [.containerRunning])

            let listed = try await client.listPodSandbox(Runtime_V1_ListPodSandboxRequest())
            #expect(listed.items.map(\.state) == [.sandboxReady])
        }

        #expect(try metadataStore.sandbox(id: "sandbox-1")?.state == .running)
    }

    @Test
    func stoppedSandboxSnapshotPreservesReadyWithCreatedWorkload() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(
            at: stateDirectory,
            containerState: .created
        )
        let unknownWorkload = makeLifecycleWorkloadSnapshot(status: .unknown)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .stopped,
                    workloads: [unknownWorkload]
                )
            ],
            workloadSnapshots: ["container-1": unknownWorkload]
        )

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            let status = try await client.podSandboxStatus(
                Runtime_V1_PodSandboxStatusRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            #expect(status.status.state == .sandboxReady)
            #expect(status.containersStatuses.map(\.state) == [.containerCreated])
        }

        #expect(try metadataStore.sandbox(id: "sandbox-1")?.state == .running)
    }

    @Test
    func confirmedMissingSandboxPersistsStoppedWithoutActiveWorkloads() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        try metadataStore.deleteContainer(id: "container-1")
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
        )

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            let status = try await client.podSandboxStatus(
                Runtime_V1_PodSandboxStatusRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            #expect(status.status.state == .sandboxNotready)

            let listed = try await client.listPodSandbox(Runtime_V1_ListPodSandboxRequest())
            #expect(listed.items.map(\.state) == [.sandboxNotready])
        }

        #expect(try metadataStore.sandbox(id: "sandbox-1")?.state == .stopped)
    }

    @Test
    func podSandboxStatusUsesStateAfterConcurrentStop() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .running,
                    workloads: [runningWorkload]
                )
            ],
            workloadSnapshots: ["container-1": runningWorkload]
        )
        runtimeManager.stopSandboxWorkloadExitCode = 137
        runtimeManager.stopSandboxWorkloadExitedAt = Date(timeIntervalSince1970: 1_780_000_321)
        let workloadGate = RecordingPortForwardCallGate()
        runtimeManager.inspectWorkloadHook = {
            await workloadGate.wait()
        }

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            let statusTask = Task {
                try await client.podSandboxStatus(
                    Runtime_V1_PodSandboxStatusRequest.with { $0.podSandboxID = "sandbox-1" }
                )
            }
            try await waitForCondition(description: "sandbox status workload observation") {
                workloadGate.hasEntered
            }
            let stopTask = Task {
                try await client.stopPodSandbox(
                    Runtime_V1_StopPodSandboxRequest.with { $0.podSandboxID = "sandbox-1" }
                )
            }
            try await Task.sleep(for: .milliseconds(50))
            workloadGate.release()

            _ = try await stopTask.value
            let status = try await statusTask.value
            #expect(status.status.state == .sandboxNotready)
            #expect(status.containersStatuses.map(\.exitCode) == [137])
        }
    }

    @Test
    func confirmedMissingWorkloadUsesExplicitUnknownFailureStatus() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(status: .running)
            ]
        )

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            let response = try await client.containerStatus(
                Runtime_V1_ContainerStatusRequest.with { $0.containerID = "container-1" }
            )
            #expect(response.status.state == .containerExited)
            #expect(response.status.exitCode == CRIShimContainerMetadata.unknownExitCode)
            #expect(response.status.finishedAt > 0)
            #expect(response.status.reason == CRIShimContainerMetadata.unknownExitReason)
            #expect(!response.status.message.isEmpty)
        }
    }

    @Test
    func runtimeExit137SurvivesLaterWorkloadDisappearance() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let exitedAt = Date(timeIntervalSince1970: 1_780_000_123)
        let stoppedWorkload = makeLifecycleWorkloadSnapshot(
            status: .stopped,
            exitCode: 137,
            exitedAt: exitedAt
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .running,
                    workloads: [stoppedWorkload]
                )
            ],
            workloadSnapshots: ["container-1": stoppedWorkload]
        )

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            let request = Runtime_V1_ContainerStatusRequest.with { $0.containerID = "container-1" }
            let first = try await client.containerStatus(request)
            #expect(first.status.exitCode == 137)
            #expect(first.status.finishedAt == 1_780_000_123_000_000_000)

            runtimeManager.inspectWorkloadError = CRIShimError.notFound("workload missing from runtime")
            let second = try await client.containerStatus(request)
            #expect(second.status.exitCode == 137)
            #expect(second.status.finishedAt == first.status.finishedAt)
            #expect(second.status.reason == "Error")
        }
    }

    @Test
    func stopContainerPersistsRuntimeExit137AndTimestamp() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .running,
                    workloads: [runningWorkload]
                )
            ],
            workloadSnapshots: ["container-1": runningWorkload]
        )
        runtimeManager.stopWorkloadExitCode = 137
        runtimeManager.stopWorkloadExitedAt = Date(timeIntervalSince1970: 1_780_000_456)

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            _ = try await client.stopContainer(
                Runtime_V1_StopContainerRequest.with {
                    $0.containerID = "container-1"
                    $0.timeout = 0
                }
            )
            let response = try await client.containerStatus(
                Runtime_V1_ContainerStatusRequest.with { $0.containerID = "container-1" }
            )
            #expect(response.status.state == .containerExited)
            #expect(response.status.exitCode == 137)
            #expect(response.status.finishedAt == 1_780_000_456_000_000_000)
        }
    }

    @Test
    func stopContainerPrefersConfirmedFailureOverTransientSuccess() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let transientSuccess = makeLifecycleWorkloadSnapshot(
            status: .stopped,
            exitCode: 0,
            exitedAt: Date(timeIntervalSince1970: 1_780_000_500)
        )
        let confirmedFailure = makeLifecycleWorkloadSnapshot(
            status: .stopped,
            exitCode: 137,
            exitedAt: Date(timeIntervalSince1970: 1_780_000_501)
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .running,
                    workloads: [runningWorkload]
                )
            ],
            workloadSnapshots: ["container-1": runningWorkload]
        )
        runtimeManager.stopWorkloadChangesState = false
        runtimeManager.inspectWorkloadResults["container-1"] = [transientSuccess, confirmedFailure]

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            _ = try await client.stopContainer(
                Runtime_V1_StopContainerRequest.with {
                    $0.containerID = "container-1"
                    $0.timeout = 0
                }
            )
            let status = try await client.containerStatus(
                Runtime_V1_ContainerStatusRequest.with { $0.containerID = "container-1" }
            )
            #expect(status.status.exitCode == 137)
            #expect(status.status.finishedAt == 1_780_000_501_000_000_000)
        }
    }

    @Test
    func stopContainerIgnoresTransientWorkloadAndSandboxNotFound() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let exitedAt = Date(timeIntervalSince1970: 1_780_000_654)
        let stoppedWorkload = makeLifecycleWorkloadSnapshot(
            status: .stopped,
            exitCode: 137,
            exitedAt: exitedAt
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .running,
                    workloads: [runningWorkload]
                )
            ],
            workloadSnapshots: ["container-1": runningWorkload]
        )
        runtimeManager.stopWorkloadChangesState = false
        runtimeManager.stopWorkloadError = CRIShimError.notFound("workload temporarily unavailable")
        runtimeManager.inspectWorkloadResults["container-1"] = [nil, runningWorkload, stoppedWorkload]
        runtimeManager.inspectSandboxResults["sandbox-1"] = [nil]

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            _ = try await client.stopContainer(
                Runtime_V1_StopContainerRequest.with {
                    $0.containerID = "container-1"
                    $0.timeout = 0
                }
            )
            let status = try await client.containerStatus(
                Runtime_V1_ContainerStatusRequest.with { $0.containerID = "container-1" }
            )
            #expect(status.status.exitCode == 137)
            #expect(status.status.finishedAt == 1_780_000_654_000_000_000)
        }
    }

    @Test
    func stopContainerRetriesIncompleteStoppedSnapshotForRuntimeExitFacts() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let incompleteStoppedWorkload = makeLifecycleWorkloadSnapshot(status: .stopped)
        let exitedAt = Date(timeIntervalSince1970: 1_780_000_655)
        let completeStoppedWorkload = makeLifecycleWorkloadSnapshot(
            status: .stopped,
            exitCode: 137,
            exitedAt: exitedAt
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .running,
                    workloads: [runningWorkload]
                )
            ],
            workloadSnapshots: ["container-1": runningWorkload]
        )
        runtimeManager.stopWorkloadChangesState = false
        runtimeManager.inspectWorkloadResults["container-1"] = [
            incompleteStoppedWorkload,
            completeStoppedWorkload,
        ]

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            _ = try await client.stopContainer(
                Runtime_V1_StopContainerRequest.with {
                    $0.containerID = "container-1"
                    $0.timeout = 0
                }
            )
            let status = try await client.containerStatus(
                Runtime_V1_ContainerStatusRequest.with { $0.containerID = "container-1" }
            )
            #expect(status.status.exitCode == 137)
            #expect(status.status.finishedAt == 1_780_000_655_000_000_000)
        }
    }

    @Test
    func stopPodSandboxPersistsRuntimeExit137AndTimestamp() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .running,
                    workloads: [runningWorkload]
                )
            ],
            workloadSnapshots: ["container-1": runningWorkload]
        )
        runtimeManager.stopSandboxWorkloadExitCode = 137
        runtimeManager.stopSandboxWorkloadExitedAt = Date(timeIntervalSince1970: 1_780_000_789)

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            _ = try await client.stopPodSandbox(
                Runtime_V1_StopPodSandboxRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            let response = try await client.podSandboxStatus(
                Runtime_V1_PodSandboxStatusRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            #expect(response.status.state == .sandboxNotready)
            #expect(response.containersStatuses.map(\.exitCode) == [137])
            #expect(response.containersStatuses.map(\.finishedAt) == [1_780_000_789_000_000_000])
        }
    }

    @Test
    func stopPodSandboxConfirmsTransientNotFoundBeforeStopping() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let runningWorkload = makeLifecycleWorkloadSnapshot(status: .running)
        let runningSandbox = makeLifecycleSandboxSnapshot(
            status: .running,
            workloads: [runningWorkload]
        )
        let stoppedSandbox = makeLifecycleSandboxSnapshot(status: .stopped)
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: ["sandbox-1": runningSandbox],
            workloadSnapshots: ["container-1": runningWorkload]
        )
        runtimeManager.stopSandboxChangesState = false
        runtimeManager.stopSandboxError = CRIShimError.notFound("sandbox temporarily unavailable")
        runtimeManager.inspectSandboxResults["sandbox-1"] = [nil, runningSandbox, stoppedSandbox]

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            _ = try await client.stopPodSandbox(
                Runtime_V1_StopPodSandboxRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            let status = try await client.podSandboxStatus(
                Runtime_V1_PodSandboxStatusRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            #expect(status.status.state == .sandboxNotready)
        }

        #expect(runtimeManager.inspectSandboxCalls.count >= 4)
    }

    @Test
    func stopPodSandboxRetriesIncompleteSnapshotForRuntimeExitFacts() async throws {
        let stateDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let metadataStore = try makeRunningLifecycleMetadataStore(at: stateDirectory)
        let incompleteStoppedWorkload = makeLifecycleWorkloadSnapshot(status: .stopped)
        let exitedAt = Date(timeIntervalSince1970: 1_780_000_790)
        let completeStoppedWorkload = makeLifecycleWorkloadSnapshot(
            status: .stopped,
            exitCode: 137,
            exitedAt: exitedAt
        )
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data()),
            sandboxSnapshots: [
                "sandbox-1": makeLifecycleSandboxSnapshot(
                    status: .running,
                    workloads: [incompleteStoppedWorkload]
                )
            ],
            workloadSnapshots: ["container-1": incompleteStoppedWorkload]
        )
        runtimeManager.inspectWorkloadResults["container-1"] = [
            incompleteStoppedWorkload,
            completeStoppedWorkload,
        ]

        try await withLifecycleRuntimeClient(
            stateDirectory: stateDirectory,
            metadataStore: metadataStore,
            runtimeManager: runtimeManager
        ) { client in
            _ = try await client.stopPodSandbox(
                Runtime_V1_StopPodSandboxRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            let status = try await client.podSandboxStatus(
                Runtime_V1_PodSandboxStatusRequest.with { $0.podSandboxID = "sandbox-1" }
            )
            #expect(status.containersStatuses.map(\.exitCode) == [137])
            #expect(status.containersStatuses.map(\.finishedAt) == [1_780_000_790_000_000_000])
        }
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

private func makeRunningLifecycleMetadataStore(
    at stateDirectory: URL,
    containerState: CRIShimContainerMetadata.State = .running
) throws -> CRIShimMetadataStore {
    let metadataStore = try CRIShimMetadataStore(rootURL: stateDirectory)
    try metadataStore.upsertSandbox(
        CRIShimSandboxMetadata(
            id: "sandbox-1",
            runtimeHandler: "macos",
            sandboxImage: "example.com/macos/sandbox:latest",
            state: .running,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_001)
        )
    )
    try metadataStore.upsertContainer(
        CRIShimContainerMetadata(
            id: "container-1",
            sandboxID: "sandbox-1",
            name: "workload",
            image: "example.com/macos/workload:latest",
            runtimeHandler: "macos",
            state: containerState,
            createdAt: Date(timeIntervalSince1970: 1_780_000_010),
            startedAt: containerState == .running ? Date(timeIntervalSince1970: 1_780_000_011) : nil
        )
    )
    return metadataStore
}

private func makeLifecycleWorkloadSnapshot(
    status: RuntimeStatus,
    exitCode: Int32? = nil,
    exitedAt: Date? = nil
) -> WorkloadSnapshot {
    WorkloadSnapshot(
        configuration: WorkloadConfiguration(
            id: "container-1",
            processConfiguration: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "while :; do sleep 60; done"],
                environment: []
            )
        ),
        status: status,
        exitCode: exitCode,
        startedDate: Date(timeIntervalSince1970: 1_780_000_011),
        exitedAt: exitedAt
    )
}

private func makeLifecycleSandboxSnapshot(
    status: RuntimeStatus,
    workloads: [WorkloadSnapshot] = []
) -> SandboxSnapshot {
    SandboxSnapshot(
        status: status,
        networks: [],
        containers: [],
        workloads: workloads
    )
}

private func withLifecycleRuntimeClient<Result>(
    stateDirectory: URL,
    metadataStore: CRIShimMetadataStore,
    runtimeManager: RecordingRuntimeManager,
    _ operation: (Runtime_V1_RuntimeServiceAsyncClient) async throws -> Result
) async throws -> Result {
    let socketPath = "/tmp/cri-shim-lifecycle-\(UUID().uuidString.prefix(8)).sock"
    var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
    config.stateDirectory = stateDirectory.path
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = CRIShimGRPCServer(
        socketPath: socketPath,
        serviceProviders: [
            CRIShimRuntimeServiceProvider(
                config: config,
                metadataStore: metadataStore,
                runtimeManager: runtimeManager,
                imageManager: RecordingImageManager(images: []),
                cniManager: RecordingCNIManager()
            )
        ],
        eventLoopGroup: group,
        startupTasks: []
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
    do {
        let result = try await operation(client)
        try await channel.close().get()
        await server.stop()
        try await serverTask.value
        await shutdown(group)
        return result
    } catch {
        try? await channel.close().get()
        await server.stop()
        _ = try? await serverTask.value
        await shutdown(group)
        throw error
    }
}

private final class FileHandleStreamRecorder: @unchecked Sendable {
    struct Snapshot {
        var data: Data
        var consumerFinished: Bool
        var producerFinished: Bool
        var producerErrorDescription: String?
    }

    private let lock = NSLock()
    private var data = Data()
    private var consumerFinished = false
    private var producerFinished = false
    private var producerErrorDescription: String?

    func append(_ data: Data) {
        lock.withLock {
            self.data.append(data)
        }
    }

    func markConsumerFinished() {
        lock.withLock {
            consumerFinished = true
        }
    }

    func markProducerFinished(errorDescription: String?) {
        lock.withLock {
            producerFinished = true
            producerErrorDescription = errorDescription
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                data: data,
                consumerFinished: consumerFinished,
                producerFinished: producerFinished,
                producerErrorDescription: producerErrorDescription
            )
        }
    }
}

private final class StreamingOperationRecorder: @unchecked Sendable {
    struct Snapshot {
        var finished: Bool
        var errorDescription: String?
    }

    private let lock = NSLock()
    private var finished = false
    private var errorDescription: String?

    func finish(errorDescription: String?) {
        lock.withLock {
            finished = true
            self.errorDescription = errorDescription
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(finished: finished, errorDescription: errorDescription)
        }
    }
}

private final class PortForwardOutboundOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    func append(_ event: String) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}

private final class ControlledStreamingProcess: CRIShimStreamingProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var killContinuation: CheckedContinuation<Void, Error>?
    private var recordedResizeCalls: [CRIShimTerminalSize] = []
    private var recordedStartCallCount = 0
    private var recordedKillCallCount = 0
    private var completeStartWhenRegistered = false
    private var failKillWhenRegistered = false

    var startCallCount: Int {
        lock.withLock { recordedStartCallCount }
    }

    var killCallCount: Int {
        lock.withLock { recordedKillCallCount }
    }

    var resizeCalls: [CRIShimTerminalSize] {
        lock.withLock { recordedResizeCalls }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let shouldComplete = lock.withLock { () -> Bool in
                recordedStartCallCount += 1
                if completeStartWhenRegistered {
                    completeStartWhenRegistered = false
                    return true
                }
                startContinuation = continuation
                return false
            }
            if shouldComplete {
                continuation.resume()
            }
        }
    }

    func resize(_ size: CRIShimTerminalSize) async throws {
        lock.withLock {
            recordedResizeCalls.append(size)
        }
    }

    func kill(_ signal: Int32) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let shouldFail = lock.withLock { () -> Bool in
                recordedKillCallCount += 1
                if failKillWhenRegistered {
                    failKillWhenRegistered = false
                    return true
                }
                killContinuation = continuation
                return false
            }
            if shouldFail {
                continuation.resume(throwing: OpaqueCRIShimError(description: "controlled kill failure"))
            }
        }
    }

    func wait() async throws -> Int32 {
        0
    }

    func completeStart() {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard let startContinuation else {
                completeStartWhenRegistered = true
                return nil
            }
            let continuation = startContinuation
            self.startContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func failKill() {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard let killContinuation else {
                failKillWhenRegistered = true
                return nil
            }
            let continuation = killContinuation
            self.killContinuation = nil
            return continuation
        }
        continuation?.resume(throwing: OpaqueCRIShimError(description: "controlled kill failure"))
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
    var workloadID: String?
    var configuration: ProcessConfiguration
    var timeout: Duration?
}

private struct RecordingStreamExecCall {
    var containerID: String
    var workloadID: String?
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

private struct RecordingLogStopCall: Equatable, Sendable {
    var containerID: String
    var removeState: Bool
}

private actor RecordingLogManager: CRIShimLogManaging {
    private var recordedStopCalls: [RecordingLogStopCall] = []

    func start(
        container: CRIShimContainerMetadata,
        workloadSnapshot: WorkloadSnapshot?
    ) async throws {}

    func reopen(container: CRIShimContainerMetadata) async throws {}

    func stop(containerID: String, removeState: Bool) async {
        recordedStopCalls.append(
            RecordingLogStopCall(
                containerID: containerID,
                removeState: removeState
            ))
    }

    func stopCalls() -> [RecordingLogStopCall] {
        recordedStopCalls
    }
}

private final class RecordingStreamingProcess: CRIShimStreamingProcess, @unchecked Sendable {
    let stdin: FileHandle?
    let stdout: FileHandle?
    let stderr: FileHandle?
    private let stateLock = NSLock()
    private let rejectsResizeBeforeStart: Bool
    private var hasStarted = false
    private var hasReceivedStart = false
    private var startPermitted: Bool
    private var recordedResizeCalls: [CRIShimTerminalSize] = []
    private var recordedResizeAttemptsBeforeStart = 0
    private var recordedKillSignals: [Int32] = []
    private var terminationSignal: Int32?
    private var stdinInput: FileHandleByteStream?
    private var waitTask: Task<Int32, Never>?

    var started: Bool {
        stateLock.withLock { hasStarted }
    }

    var startCalled: Bool {
        stateLock.withLock { hasReceivedStart }
    }

    var resizeCalls: [CRIShimTerminalSize] {
        stateLock.withLock { recordedResizeCalls }
    }

    var resizeAttemptsBeforeStart: Int {
        stateLock.withLock { recordedResizeAttemptsBeforeStart }
    }

    var killSignals: [Int32] {
        stateLock.withLock { recordedKillSignals }
    }

    init(
        stdin: FileHandle?,
        stdout: FileHandle?,
        stderr: FileHandle?,
        waitsForStartPermission: Bool = false,
        rejectsResizeBeforeStart: Bool = false
    ) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.rejectsResizeBeforeStart = rejectsResizeBeforeStart
        self.startPermitted = !waitsForStartPermission
    }

    func start() async throws {
        stateLock.withLock {
            hasReceivedStart = true
        }
        while true {
            let startState = stateLock.withLock {
                (permitted: startPermitted, terminated: terminationSignal != nil)
            }
            if startState.terminated {
                return
            }
            if startState.permitted {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        let inputState = try stateLock.withLock {
            () throws -> (shouldStart: Bool, input: FileHandleByteStream?) in
            guard terminationSignal == nil else {
                return (false, nil)
            }
            return (true, try stdin.map { try fileHandleStream($0) })
        }
        guard inputState.shouldStart else {
            return
        }
        let stdinInput = inputState.input
        let outputQueue = DispatchQueue(label: "container.cri.tests.streaming-process-output.\(UUID().uuidString)")
        let task = Task<Int32, Never> {
            if let stderr {
                try? stderr.close()
            }

            if let stdinInput, let stdout {
                for await data in stdinInput.bytes {
                    try? await performBlockingIO(on: outputQueue) {
                        try stdout.write(contentsOf: Data("stdout:".utf8) + data)
                    }
                }
            }

            try? stdout?.close()
            try? stdin?.close()
            return Int32(0)
        }
        let shouldCancel = stateLock.withLock { () -> Bool in
            hasStarted = true
            guard waitTask == nil else {
                return true
            }
            self.stdinInput = stdinInput
            waitTask = task
            return false
        }
        if shouldCancel {
            stdinInput?.cancel()
            task.cancel()
        }
    }

    func permitStart() {
        stateLock.withLock {
            startPermitted = true
        }
    }

    func resize(_ size: CRIShimTerminalSize) async throws {
        try stateLock.withLock {
            if rejectsResizeBeforeStart && !hasStarted {
                recordedResizeAttemptsBeforeStart += 1
                throw CRIShimError.notFound("streaming process is not registered")
            }
            recordedResizeCalls.append(size)
        }
    }

    func kill(_ signal: Int32) async throws {
        let cancellationState = stateLock.withLock {
            () -> (input: FileHandleByteStream?, task: Task<Int32, Never>?) in
            recordedKillSignals.append(signal)
            terminationSignal = signal
            if waitTask == nil {
                waitTask = Task<Int32, Never> { 128 + signal }
            }
            let cancellationState = (input: stdinInput, task: waitTask)
            stdinInput = nil
            return cancellationState
        }
        cancellationState.input?.cancel()
        cancellationState.task?.cancel()
        try? stdin?.close()
        try? stdout?.close()
        try? stderr?.close()
    }

    func wait() async throws -> Int32 {
        let task = stateLock.withLock { waitTask }
        return await task?.value ?? 0
    }
}

private final class RecordingPortForwardConnection: @unchecked Sendable {
    let forwardedHandle: FileHandle
    let peerHandle: FileHandle
    private let stateLock = NSLock()
    private let ioQueue = DispatchQueue(label: "container.cri.tests.port-forward-backend.\(UUID().uuidString)")
    private var input: FileHandleByteStream?
    private var task: Task<Void, Never>?
    private var continuousOutputWorkItem: DispatchWorkItem?
    private var continuousOutputCancelled = false
    private var received = Data()
    private var continuousOutputBytes = 0
    private var continuousOutputStopped = false

    init(forwardedHandle: FileHandle, peerHandle: FileHandle) {
        self.forwardedHandle = forwardedHandle
        self.peerHandle = peerHandle
    }

    deinit {
        input?.cancel()
        task?.cancel()
        continuousOutputWorkItem?.cancel()
    }

    func startEcho(port: UInt32) throws {
        let input = try fileHandleStream(peerHandle)
        let peerHandle = peerHandle
        let ioQueue = ioQueue
        self.input = input
        self.task = Task {
            for await data in input.bytes {
                try? await performBlockingIO(on: ioQueue) {
                    try peerHandle.write(contentsOf: Data("echo:\(port):".utf8) + data)
                }
            }
        }
    }

    func startResponseAfterClientEOF(_ response: Data) throws {
        let input = try fileHandleStream(peerHandle)
        let peerHandle = peerHandle
        let ioQueue = ioQueue
        self.input = input
        self.task = Task { [weak self] in
            for await data in input.bytes {
                guard let self else {
                    return
                }
                self.stateLock.withLock {
                    self.received.append(data)
                }
            }
            try? await performBlockingIO(on: ioQueue) {
                try peerHandle.write(contentsOf: response)
                try peerHandle.close()
            }
        }
    }

    func startRecording() throws {
        let input = try fileHandleStream(peerHandle)
        self.input = input
        self.task = Task { [weak self] in
            for await data in input.bytes {
                guard let self else {
                    return
                }
                self.stateLock.withLock {
                    self.received.append(data)
                }
            }
        }
    }

    func receivedInput() -> Data {
        stateLock.withLock { received }
    }

    func sendReadyByte() throws {
        try peerHandle.write(contentsOf: Data("R".utf8))
    }

    func startContinuousOutput() {
        let peerHandle = peerHandle
        var sendBufferSize: Int32 = 4 * 1024
        _ = Darwin.setsockopt(
            peerHandle.fileDescriptor,
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBufferSize,
            socklen_t(MemoryLayout.size(ofValue: sendBufferSize))
        )
        let chunk = Data(repeating: 0x5A, count: 64 * 1024)
        let workItem = DispatchWorkItem { [weak self] in
            defer {
                self?.stateLock.withLock {
                    self?.continuousOutputStopped = true
                }
            }
            while true {
                guard
                    let self,
                    !self.stateLock.withLock({ self.continuousOutputCancelled })
                else {
                    return
                }
                do {
                    try peerHandle.write(contentsOf: chunk)
                    self.stateLock.withLock {
                        self.continuousOutputBytes += chunk.count
                    }
                } catch {
                    return
                }
            }
        }
        stateLock.withLock {
            continuousOutputWorkItem = workItem
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    var outputByteCount: Int {
        stateLock.withLock { continuousOutputBytes }
    }

    var outputHasStopped: Bool {
        stateLock.withLock { continuousOutputStopped }
    }

    func limitForwardedSendBuffer(to byteCount: Int32) throws {
        var byteCount = byteCount
        guard
            Darwin.setsockopt(
                forwardedHandle.fileDescriptor,
                SOL_SOCKET,
                SO_SNDBUF,
                &byteCount,
                socklen_t(MemoryLayout.size(ofValue: byteCount))
            ) == 0
        else {
            throw currentPOSIXError()
        }
    }

    func hasUnreadPeerData() -> Bool {
        var byte: UInt8 = 0
        return Darwin.recv(
            peerHandle.fileDescriptor,
            &byte,
            1,
            MSG_DONTWAIT | MSG_PEEK
        ) > 0
    }

    func drainPeerAndCheckEOF() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let received = Darwin.recv(
                peerHandle.fileDescriptor,
                &buffer,
                buffer.count,
                MSG_DONTWAIT
            )
            if received > 0 {
                continue
            }
            if received == 0 {
                return true
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            }
            return errno == ECONNRESET || errno == ENOTCONN
        }
    }

    func shutdownForwardedWriteAndCloseHandle() -> Int32 {
        let fileDescriptor = forwardedHandle.fileDescriptor
        _ = Darwin.shutdown(fileDescriptor, SHUT_WR)
        try? forwardedHandle.close()
        return fileDescriptor
    }

    func closePeerConnection() {
        let resources = stateLock.withLock {
            () -> (FileHandleByteStream?, Task<Void, Never>?, DispatchWorkItem?) in
            continuousOutputCancelled = true
            let resources = (input, task, continuousOutputWorkItem)
            input = nil
            task = nil
            continuousOutputWorkItem = nil
            return resources
        }
        resources.0?.cancel()
        resources.1?.cancel()
        resources.2?.cancel()
        try? peerHandle.close()
    }
}

private final class RecordingPortForwardCallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasEntered: Bool {
        lock.withLock { entered }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                entered = true
                guard !released else {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !released else {
                return nil
            }
            released = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private func writeTestSidecarLifecycleAttestation(
    policy: MachineStateConfig,
    lease: CRIShimMachineStateLease,
    state: MacOSSidecarLifecycleAttestationState
) throws {
    guard let barrier = lease.sidecarLifecycleBarrier else {
        throw CRIShimError.internalError("test lease has no sidecar lifecycle barrier")
    }
    let directory = URL(
        fileURLWithPath: policy.normalizedStorageRoot,
        isDirectory: true
    ).appendingPathComponent(lease.persistenceID, isDirectory: true)
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(directoryFD) }
    let lockFD = openat(
        directoryFD,
        MacOSSidecarLifecycleBarrierProtocol.lockFileName,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard lockFD >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(lockFD) }
    var value = stat()
    guard fstat(lockFD, &value) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try MacOSSidecarLifecycleLock.persistAttestation(
        MacOSSidecarLifecycleAttestation(
            protocolVersion: barrier.protocolVersion,
            persistenceID: lease.persistenceID,
            sandboxID: lease.effectiveRuntimeSandboxID,
            bootNonce: barrier.bootNonce,
            processID: getpid(),
            lockDevice: UInt64(value.st_dev),
            lockInode: UInt64(value.st_ino),
            state: state
        ),
        directoryFD: directoryFD,
        ownerUID: geteuid()
    )
}

private final class MachineStateLegacySocketFixture: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32
    private let path: String

    init(path: String) throws {
        self.path = path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            descriptor = -1
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length)
            }
        }
        guard bindResult == 0, listen(descriptor, 1) == 0, chmod(path, mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            descriptor = -1
            _ = unlink(path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit {
        closeAndRemove()
    }

    func closeAndRemove() {
        stateLock.withLock {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
            _ = unlink(path)
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
    private let portForwardStateLock = NSLock()
    private var recordedPortForwardConnections: [UInt32: RecordingPortForwardConnection] = [:]
    private var configuredPortForwardFailurePorts: Set<UInt32> = []
    private var configuredPortForwardReadyOnlyPorts: Set<UInt32> = []
    private var configuredPortForwardHighDescriptorPorts: Set<UInt32> = []
    private var configuredPortForwardRecordingPorts: Set<UInt32> = []
    private var configuredPortForwardNoReadPorts: Set<UInt32> = []
    private var configuredPortForwardContinuousOutputPorts: Set<UInt32> = []
    private var configuredPortForwardCallGates: [UInt32: RecordingPortForwardCallGate] = [:]
    private var configuredPortForwardStartDelays: [UInt32: Duration] = [:]
    private var configuredPortForwardResponsesAfterClientEOF: [UInt32: Data] = [:]
    private var recordedPortForwardCalls: [RecordingPortForwardCall] = []
    private var recordedCancelledPortForwardCalls: [RecordingPortForwardCall] = []
    private(set) var createSandboxCalls: [ContainerConfiguration] = []
    private(set) var startSandboxCalls: [(id: String, presentGUI: Bool)] = []
    private(set) var stopSandboxCalls: [(id: String, options: ContainerStopOptions)] = []
    private(set) var removeSandboxCalls: [(id: String, force: Bool)] = []
    private(set) var removeSandboxRuntimeServiceCalls: [String] = []
    private(set) var removeSandboxRuntimeServiceOwnerUIDs: [UInt32] = []
    private(set) var removeMachineStateSidecarCalls: [(sandboxID: String, persistenceID: String, effectiveUserID: UInt32)] = []
    private(set) var stopAndQuitMachineStateSidecarCalls: [String] = []
    private(set) var confirmSandboxRuntimeRemovedCalls: [(id: String, machineStatePersistenceID: String?, machineStateOwnerUID: UInt32?)] = []
    private(set) var removeSandboxPolicyCalls: [String] = []
    private(set) var inspectSandboxCalls: [String] = []
    private(set) var createWorkloadCalls: [RecordingCreateWorkloadCall] = []
    private(set) var startWorkloadCalls: [(sandboxID: String, workloadID: String)] = []
    private(set) var stopWorkloadCalls: [RecordingStopWorkloadCall] = []
    private(set) var removeWorkloadCalls: [(sandboxID: String, workloadID: String)] = []
    private(set) var execSyncCalls: [RecordingExecSyncCall] = []
    private(set) var streamExecCalls: [RecordingStreamExecCall] = []
    var stopSandboxChangesState = true
    var stopSandboxError: (any Error)?
    var removeSandboxError: (any Error)?
    var stopSandboxWorkloadExitCode: Int32?
    var stopSandboxWorkloadExitedAt: Date?
    var stopWorkloadChangesState = true
    var stopWorkloadError: (any Error)?
    var stopWorkloadExitCode: Int32 = 42
    var stopWorkloadExitedAt: Date?
    var removeWorkloadError: (any Error)?
    var inspectSandboxError: (any Error)?
    var inspectSandboxResults: [String: [SandboxSnapshot?]] = [:]
    var inspectWorkloadError: (any Error)?
    var inspectWorkloadResults: [String: [WorkloadSnapshot?]] = [:]
    var inspectWorkloadHook: (@Sendable () async -> Void)?
    var streamExecWaitsForStartPermission = false
    var streamExecRejectsResizeBeforeStart = false
    var createSandboxHook: (@Sendable () throws -> Void)?
    var startSandboxHook: (@Sendable () throws -> Void)?
    var stopAndQuitMachineStateSidecarHook: (@Sendable (String) throws -> Void)?
    var removeSandboxRuntimeServiceError: (any Error)?
    var confirmSandboxRuntimeRemovedError: (any Error)?
    var removeMachineStateSidecarError: (any Error)?
    var stopAndQuitMachineStateSidecarError: (any Error)?
    var retainedMachineStateSidecars: Set<String> = []

    var portForwardConnections: [UInt32: RecordingPortForwardConnection] {
        portForwardStateLock.withLock { recordedPortForwardConnections }
    }

    var portForwardFailurePorts: Set<UInt32> {
        get { portForwardStateLock.withLock { configuredPortForwardFailurePorts } }
        set { portForwardStateLock.withLock { configuredPortForwardFailurePorts = newValue } }
    }

    var portForwardReadyOnlyPorts: Set<UInt32> {
        get { portForwardStateLock.withLock { configuredPortForwardReadyOnlyPorts } }
        set { portForwardStateLock.withLock { configuredPortForwardReadyOnlyPorts = newValue } }
    }

    var portForwardHighDescriptorPorts: Set<UInt32> {
        get { portForwardStateLock.withLock { configuredPortForwardHighDescriptorPorts } }
        set {
            portForwardStateLock.withLock {
                configuredPortForwardHighDescriptorPorts = newValue
            }
        }
    }

    var portForwardRecordingPorts: Set<UInt32> {
        get { portForwardStateLock.withLock { configuredPortForwardRecordingPorts } }
        set { portForwardStateLock.withLock { configuredPortForwardRecordingPorts = newValue } }
    }

    var portForwardNoReadPorts: Set<UInt32> {
        get { portForwardStateLock.withLock { configuredPortForwardNoReadPorts } }
        set { portForwardStateLock.withLock { configuredPortForwardNoReadPorts = newValue } }
    }

    var portForwardContinuousOutputPorts: Set<UInt32> {
        get { portForwardStateLock.withLock { configuredPortForwardContinuousOutputPorts } }
        set { portForwardStateLock.withLock { configuredPortForwardContinuousOutputPorts = newValue } }
    }

    var portForwardCallGates: [UInt32: RecordingPortForwardCallGate] {
        get { portForwardStateLock.withLock { configuredPortForwardCallGates } }
        set { portForwardStateLock.withLock { configuredPortForwardCallGates = newValue } }
    }

    var portForwardStartDelays: [UInt32: Duration] {
        get { portForwardStateLock.withLock { configuredPortForwardStartDelays } }
        set { portForwardStateLock.withLock { configuredPortForwardStartDelays = newValue } }
    }

    var portForwardResponsesAfterClientEOF: [UInt32: Data] {
        get { portForwardStateLock.withLock { configuredPortForwardResponsesAfterClientEOF } }
        set {
            portForwardStateLock.withLock {
                configuredPortForwardResponsesAfterClientEOF = newValue
            }
        }
    }

    var portForwardCalls: [RecordingPortForwardCall] {
        portForwardStateLock.withLock { recordedPortForwardCalls }
    }

    var cancelledPortForwardCalls: [RecordingPortForwardCall] {
        portForwardStateLock.withLock { recordedCancelledPortForwardCalls }
    }

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
        try createSandboxHook?()
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
        try startSandboxHook?()
    }

    func stopSandbox(
        id: String,
        options: ContainerStopOptions
    ) async throws {
        if stopSandboxChangesState, var snapshot = sandboxSnapshots[id] {
            snapshot.status = .stopped
            sandboxSnapshots[id] = snapshot
        }
        if let stopSandboxWorkloadExitCode {
            let exitedAt = stopSandboxWorkloadExitedAt ?? Date()
            for workloadID in workloadSnapshots.keys.sorted() {
                guard var workload = workloadSnapshots[workloadID] else {
                    continue
                }
                workload.status = .stopped
                workload.exitCode = stopSandboxWorkloadExitCode
                workload.exitedAt = exitedAt
                workloadSnapshots[workloadID] = workload
                replaceWorkloadSnapshot(workload, sandboxID: id)
            }
        }
        stopSandboxCalls.append((id: id, options: options))
        if let stopSandboxError {
            throw stopSandboxError
        }
    }

    func removeSandbox(
        id: String,
        force: Bool
    ) async throws {
        sandboxSnapshots.removeValue(forKey: id)
        removeSandboxCalls.append((id: id, force: force))
        if let removeSandboxError { throw removeSandboxError }
    }

    func removeSandboxRuntimeService(
        id: String
    ) async throws {
        removeSandboxRuntimeServiceCalls.append(id)
        if let removeSandboxRuntimeServiceError {
            throw removeSandboxRuntimeServiceError
        }
    }

    func removeSandboxRuntimeService(id: String, machineStateOwnerUID: UInt32) async throws {
        removeSandboxRuntimeServiceOwnerUIDs.append(machineStateOwnerUID)
        try await removeSandboxRuntimeService(id: id)
    }

    func removeMachineStateSidecar(
        sandboxID: String,
        persistenceID: String,
        effectiveUserID: UInt32
    ) async throws {
        removeMachineStateSidecarCalls.append((sandboxID, persistenceID, effectiveUserID))
        if let removeMachineStateSidecarError {
            throw removeMachineStateSidecarError
        }
        retainedMachineStateSidecars.remove(persistenceID)
    }

    func stopAndQuitMachineStateSidecar(
        controlSocketPath: String
    ) async throws {
        stopAndQuitMachineStateSidecarCalls.append(controlSocketPath)
        try stopAndQuitMachineStateSidecarHook?(controlSocketPath)
        if let stopAndQuitMachineStateSidecarError {
            throw stopAndQuitMachineStateSidecarError
        }
    }

    func confirmSandboxRuntimeRemoved(
        id: String,
        machineStatePersistenceID: String?,
        machineStateOwnerUID: UInt32?
    ) async throws {
        confirmSandboxRuntimeRemovedCalls.append((id, machineStatePersistenceID, machineStateOwnerUID))
        if let confirmSandboxRuntimeRemovedError { throw confirmSandboxRuntimeRemovedError }
        guard sandboxSnapshots[id] == nil else {
            throw CRIShimError.unavailable("sandbox runtime remains present after deletion")
        }
        if let machineStatePersistenceID,
            retainedMachineStateSidecars.contains(machineStatePersistenceID)
        {
            throw CRIShimError.unavailable("machine-state sidecar remains present after deletion")
        }
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
        if var results = inspectSandboxResults[id], !results.isEmpty {
            let result = results.removeFirst()
            inspectSandboxResults[id] = results
            guard let result else {
                throw CRIShimError.notFound("sandbox \(id) not found")
            }
            return result
        }
        if let inspectSandboxError {
            throw inspectSandboxError
        }
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
        if stopWorkloadChangesState {
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
                exitCode: stopWorkloadExitCode,
                startedDate: existingSnapshot?.startedDate,
                exitedAt: stopWorkloadExitedAt ?? Date(),
                stdoutLogPath: existingSnapshot?.stdoutLogPath,
                stderrLogPath: existingSnapshot?.stderrLogPath
            )
            workloadSnapshots[workloadID] = snapshot
            replaceWorkloadSnapshot(snapshot, sandboxID: sandboxID)
        }
        stopWorkloadCalls.append(
            RecordingStopWorkloadCall(
                sandboxID: sandboxID,
                workloadID: workloadID,
                options: options
            ))
        if let stopWorkloadError {
            throw stopWorkloadError
        }
    }

    func removeWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws {
        removeWorkloadCalls.append((sandboxID: sandboxID, workloadID: workloadID))
        if let removeWorkloadError {
            throw removeWorkloadError
        }
        workloadConfigurations.removeValue(forKey: workloadID)
        workloadSnapshots.removeValue(forKey: workloadID)
        removeWorkloadSnapshot(workloadID, sandboxID: sandboxID)
    }

    func inspectWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws -> WorkloadSnapshot {
        await inspectWorkloadHook?()
        if var results = inspectWorkloadResults[workloadID], !results.isEmpty {
            let result = results.removeFirst()
            inspectWorkloadResults[workloadID] = results
            guard let result else {
                throw CRIShimError.notFound("workload \(workloadID) not found")
            }
            return result
        }
        if let inspectWorkloadError {
            throw inspectWorkloadError
        }
        guard let snapshot = workloadSnapshots[workloadID] else {
            throw CRIShimError.notFound("workload \(workloadID) not found")
        }
        return snapshot
    }

    func execSync(
        containerID: String,
        workloadID: String?,
        configuration: ProcessConfiguration,
        timeout: Duration?
    ) async throws -> ExecSyncResult {
        execSyncCalls.append(
            RecordingExecSyncCall(
                containerID: containerID,
                workloadID: workloadID,
                configuration: configuration,
                timeout: timeout
            ))
        return execSyncResult
    }

    func streamExec(
        containerID: String,
        workloadID: String?,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> any CRIShimStreamingProcess {
        let process = RecordingStreamingProcess(
            stdin: stdio[0],
            stdout: stdio[1],
            stderr: stdio[2],
            waitsForStartPermission: streamExecWaitsForStartPermission,
            rejectsResizeBeforeStart: streamExecRejectsResizeBeforeStart
        )
        streamExecCalls.append(
            RecordingStreamExecCall(
                containerID: containerID,
                workloadID: workloadID,
                configuration: configuration
            )
        )
        streamExecProcesses[containerID] = process
        return process
    }

    func permitStreamExecStarts() {
        for process in streamExecProcesses.values {
            process.permitStart()
        }
    }

    func streamPortForward(
        sandboxID: String,
        port: UInt32
    ) async throws -> FileHandle {
        let behavior = portForwardStateLock.withLock {
            recordedPortForwardCalls.append(
                RecordingPortForwardCall(sandboxID: sandboxID, port: port)
            )
            return (
                delay: configuredPortForwardStartDelays[port],
                fails: configuredPortForwardFailurePorts.contains(port),
                usesHighDescriptor: configuredPortForwardHighDescriptorPorts.contains(port),
                doesNotRead: configuredPortForwardNoReadPorts.contains(port),
                continuouslyOutputs: configuredPortForwardContinuousOutputPorts.contains(port),
                gate: configuredPortForwardCallGates[port],
                responseAfterEOF: configuredPortForwardResponsesAfterClientEOF[port],
                recordsInput: configuredPortForwardRecordingPorts.contains(port),
                sendsReadyByte: configuredPortForwardReadyOnlyPorts.contains(port)
            )
        }
        if let gate = behavior.gate {
            await gate.wait()
        }
        if let delay = behavior.delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                portForwardStateLock.withLock {
                    recordedCancelledPortForwardCalls.append(
                        RecordingPortForwardCall(sandboxID: sandboxID, port: port)
                    )
                }
                throw error
            }
        }
        if behavior.fails {
            throw POSIXError(.ECONNREFUSED)
        }
        let (forwardedHandle, peerHandle) = try makeSocketPair(
            firstDescriptorMinimum: behavior.usesHighDescriptor
                ? try criShimHighDescriptorMinimum(reservedFromLimit: 128)
                : nil
        )
        let connection = RecordingPortForwardConnection(
            forwardedHandle: forwardedHandle,
            peerHandle: peerHandle
        )
        if behavior.doesNotRead {
            try connection.limitForwardedSendBuffer(to: 4 * 1024)
        } else if behavior.continuouslyOutputs {
            connection.startContinuousOutput()
        } else if let response = behavior.responseAfterEOF {
            try connection.startResponseAfterClientEOF(response)
        } else if behavior.recordsInput {
            try connection.startRecording()
        } else if behavior.sendsReadyByte {
            try connection.sendReadyByte()
        } else {
            try connection.startEcho(port: port)
        }
        portForwardStateLock.withLock {
            recordedPortForwardConnections[port] = connection
        }
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
    var listImagesHook: (@Sendable () throws -> Void)?

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
        try listImagesHook?()
        return images
    }

    func pullImage(
        reference: String,
        authentication: CRIShimImagePullAuthentication?
    ) async throws -> CRIShimImageRecord {
        pulledReferences.append(reference)
        pulledAuthentications.append(authentication)
        return pulledImage
    }

    func removeImages(references: [String]) async throws {
        removedReferences.append(contentsOf: references)
    }

    func imageFilesystemUsage() async throws -> CRIShimImageFilesystemUsage {
        filesystemUsage
    }
}

private struct VMNetRecoveryAdmissionRejectionScenarioResult {
    var grpcCode: GRPCStatus.Code
    var grpcMessage: String
    var events: [VMNetRecoveryAdmissionRejectionEventV1]
    var imagePullCount: Int
    var createSandboxCount: Int
    var removeSandboxCount: Int
    var cniAddCount: Int
    var cniDeleteCount: Int
}

private func runVMNetRecoveryAdmissionRejectionScenario(
    gate: VMNetRecoveryAdmissionGate
) async throws -> VMNetRecoveryAdmissionRejectionScenarioResult {
    let socketPath = "/tmp/cri-shim-vmnet-gate-\(UUID().uuidString.prefix(8)).sock"
    let stateDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }

    let statePath = stateDirectory.appendingPathComponent("vmnet-recovery.json").path
    let podNetworkRuntimeStatePath = stateDirectory.appendingPathComponent("pod-network.json").path
    let podNetworkReadyStatePath = stateDirectory.appendingPathComponent("flannel-ready.json").path
    let config = CRIShimConfig(
        runtimeEndpoint: "/var/run/container-cri-macos.sock",
        stateDirectory: stateDirectory.path,
        streaming: StreamingConfig(address: "127.0.0.1", port: 0),
        cni: CNIConfig(binDir: "/opt/cni/bin", confDir: "/etc/cni/net.d", plugin: "macvmnet"),
        defaults: RuntimeProfile(
            sandboxImage: "example.com/macos/sandbox:latest",
            workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
            network: "kubernetes-pod",
            networkBackend: "vmnetShared",
            guiEnabled: false
        ),
        runtimeHandlers: [
            "macos": RuntimeProfile(network: "kubernetes-pod", networkBackend: "vmnetShared")
        ],
        networkPolicy: NetworkPolicyConfig(enabled: false),
        kubeProxy: KubeProxyConfig(enabled: false),
        podNetwork: PodNetworkConfig(
            enabled: true,
            vmnetDisconnectRecovery: .rebootNode,
            networkName: "kubernetes-pod",
            runtimeStatePath: podNetworkRuntimeStatePath,
            readyStatePath: podNetworkReadyStatePath,
            vmnetRecovery: VMNetRecoveryConfig(
                statePath: statePath,
                requestPath: stateDirectory.appendingPathComponent("requests/fence.json").path,
                requestWriterUID: Int(geteuid())
            )
        )
    )
    let metadataStore = try CRIShimMetadataStore(rootURL: stateDirectory)
    let stateStore = VMNetRecoveryStateStore(path: statePath)
    if gate != .beforeRequestValidation {
        let podNetworkStateStore = PodNetworkStateStore()
        let runtimeState = try await podNetworkStateStore.updateRuntimeState(
            networkName: "kubernetes-pod",
            podCIDR: "10.42.1.0/24",
            path: podNetworkRuntimeStatePath
        )
        try await podNetworkStateStore.writeReadyState(
            PodNetworkReadyState(
                networkName: "kubernetes-pod",
                podCIDR: "10.42.1.0/24",
                runtimeGeneration: runtimeState.generation,
                mtu: 1_420,
                expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970) + 300
            ),
            path: podNetworkReadyStatePath
        )
        _ = try stateStore.recordHealthyObservation(
            networkName: "kubernetes-pod",
            networkInstanceID: "instance-a",
            bootSessionID: "boot-a"
        )
    }
    let runtimeManager = RecordingRuntimeManager(
        execSyncResult: ExecSyncResult(exitCode: 0, stdout: Data(), stderr: Data())
    )
    let imageManager = RecordingImageManager(
        images: [
            CRIShimImageRecord(
                reference: "example.com/macos/sandbox:latest",
                digest: "sha256:sandbox",
                size: 16_384,
                annotations: ["org.apple.container.macos.image.role": "sandbox"]
            )
        ]
    )
    let fence: @Sendable () throws -> Void = {
        _ = try stateStore.recordFence(
            networkName: "kubernetes-pod",
            networkInstanceID: "instance-a",
            failureReason: "helper disconnected",
            bootSessionID: "boot-a",
            attemptWindow: 3_600
        )
    }
    if gate == .beforeSandboxCreate {
        imageManager.listImagesHook = fence
    } else if gate == .beforeNetworkAttach {
        runtimeManager.createSandboxHook = fence
    }
    let cniManager = RecordingCNIManager()
    let telemetryPaths = VMNetRecoveryAdmissionTelemetryPaths(
        directoryURL: stateDirectory.appendingPathComponent("telemetry", isDirectory: true)
    )
    let controller = CRIShimVMNetRecoveryController(
        config: config,
        bootSessionID: "boot-a",
        admissionRejectionRecorder: VMNetRecoveryAdmissionRejectionJournal(
            paths: telemetryPaths,
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid()
        )
    )
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = CRIShimGRPCServer(
        socketPath: socketPath,
        serviceProviders: [
            CRIShimRuntimeServiceProvider(
                config: config,
                metadataStore: metadataStore,
                readinessChecker: StaticReadinessChecker(snapshot: readyReadinessSnapshot()),
                runtimeManager: runtimeManager,
                imageManager: imageManager,
                cniManager: cniManager,
                vmnetRecoveryController: controller
            )
        ],
        eventLoopGroup: group
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
    var request = Runtime_V1_RunPodSandboxRequest()
    request.runtimeHandler = "macos"
    request.config.metadata.uid = "fenced-pod-uid"
    request.config.metadata.namespace = "default"
    request.config.metadata.name = "fenced-pod"

    let grpcCode: GRPCStatus.Code
    let grpcMessage: String
    do {
        _ = try await client.runPodSandbox(request)
        Issue.record("expected vmnet recovery admission to reject the sandbox")
        grpcCode = .ok
        grpcMessage = ""
    } catch let status as GRPCStatus {
        grpcCode = status.code
        grpcMessage = status.message ?? ""
    }

    try await channel.close().get()
    await server.stop()
    try await serverTask.value
    await shutdown(group)

    let data = FileManager.default.contents(atPath: telemetryPaths.journalURL.path) ?? Data()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let events = try data.split(separator: 0x0A).map {
        try decoder.decode(VMNetRecoveryAdmissionRejectionEventV1.self, from: Data($0))
    }
    return VMNetRecoveryAdmissionRejectionScenarioResult(
        grpcCode: grpcCode,
        grpcMessage: grpcMessage,
        events: events,
        imagePullCount: imageManager.pulledReferences.count,
        createSandboxCount: runtimeManager.createSandboxCalls.count,
        removeSandboxCount: runtimeManager.removeSandboxCalls.count,
        cniAddCount: cniManager.addCalls.count,
        cniDeleteCount: cniManager.deleteCalls.count
    )
}

private func waitForSocket(at path: String) async throws {
    for _ in 0..<100 {
        do {
            let socket = try connectedUnixSocket(path: path)
            _ = close(socket)
            return
        } catch let error as POSIXError
            where error.code == .ENOENT || error.code == .ECONNREFUSED
        {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    throw CRIShimRuntimeServerTestError.socketDidNotStart(path)
}

private func verifyPendingInputStorageCompaction(seed: UInt8) {
    var buffer = CRIShimPendingInputBuffer()
    for index in 0..<256 {
        buffer.append(Data([seed &+ UInt8(truncatingIfNeeded: index)]))
    }
    #expect(buffer.count == 256)
    #expect(buffer.allocatedSlotCount == 256)
    for index in 0..<256 {
        #expect(buffer.removeFirst() == Data([seed &+ UInt8(truncatingIfNeeded: index)]))
    }
    #expect(buffer.isEmpty)
    #expect(buffer.allocatedSlotCount == 0)

    var expected = Data([seed])
    var orderPreserved = true
    var maximumAllocatedSlotCount = 0
    buffer.append(expected)

    for index in 1...10_000 {
        let next = Data([seed &+ UInt8(truncatingIfNeeded: index)])
        buffer.append(next)
        orderPreserved = orderPreserved && buffer.removeFirst() == expected
        orderPreserved = orderPreserved && buffer.first == next && !buffer.isEmpty
        maximumAllocatedSlotCount = max(
            maximumAllocatedSlotCount,
            buffer.allocatedSlotCount
        )
        expected = next
    }

    #expect(orderPreserved)
    #expect(maximumAllocatedSlotCount == 16)
    #expect(buffer.removeFirst() == expected)
    #expect(buffer.isEmpty)
    #expect(buffer.allocatedSlotCount == 0)
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

    while true {
        if let value = body() {
            return value
        }
        guard DispatchTime.now().uptimeNanoseconds <= deadline else {
            throw CRIShimRuntimeServerTestError.timedOut(description)
        }
        try await Task.sleep(nanoseconds: UInt64(pollNanoseconds))
    }
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

private func waitForAsyncCondition(
    description: String,
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(10),
    _ body: () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if await body() {
            return
        }
        guard clock.now <= deadline else {
            throw CRIShimRuntimeServerTestError.timedOut(description)
        }
        try await Task.sleep(for: pollInterval)
    }
}

private func makeSocketPair(
    firstDescriptorMinimum: Int32? = nil
) throws -> (FileHandle, FileHandle) {
    var fileDescriptors = [Int32](repeating: 0, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fileDescriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    if let firstDescriptorMinimum {
        let highDescriptor = Darwin.fcntl(
            fileDescriptors[0],
            F_DUPFD_CLOEXEC,
            firstDescriptorMinimum
        )
        let duplicateErrno = errno
        _ = Darwin.close(fileDescriptors[0])
        guard highDescriptor >= 0 else {
            _ = Darwin.close(fileDescriptors[1])
            throw POSIXError(POSIXErrorCode(rawValue: duplicateErrno) ?? .EIO)
        }
        fileDescriptors[0] = highDescriptor
    }

    #if !os(Linux)
    var noSignal = CInt(1)
    for fileDescriptor in fileDescriptors {
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<CInt>.size)
        )
    }
    #endif

    return (
        FileHandle(fileDescriptor: fileDescriptors[0], closeOnDealloc: true),
        FileHandle(fileDescriptor: fileDescriptors[1], closeOnDealloc: true)
    )
}

private func withSPDYPortForwardServer(
    runtimeManager: RecordingRuntimeManager,
    ports: [UInt32],
    body: (String) async throws -> Void
) async throws {
    let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = CRIShimStreamingServer(
        config: config,
        runtimeManager: runtimeManager,
        activeSessionIdleTimeoutSeconds: 0
    )

    do {
        try await server.start(eventLoopGroup: group)
    } catch {
        await shutdown(group)
        throw error
    }

    do {
        let url = try await server.registerPortForwardURL(
            CRIShimPortForwardInvocation(sandboxID: "sandbox-1", ports: ports)
        )
        try await body(url)
        await server.stop()
        await shutdown(group)
    } catch {
        await server.stop()
        await shutdown(group)
        throw error
    }
}

private func withObservedSPDYPortForwardServer(
    runtimeManager: RecordingRuntimeManager,
    portSets: [[UInt32]],
    maximumActivePortForwardTunnels: Int,
    body: ([String], CRIShimStreamingServer) async throws -> Void
) async throws {
    let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = CRIShimStreamingServer(
        config: config,
        runtimeManager: runtimeManager,
        activeSessionIdleTimeoutSeconds: 0,
        maximumActivePortForwardTunnels: maximumActivePortForwardTunnels
    )

    do {
        try await server.start(eventLoopGroup: group)
    } catch {
        await shutdown(group)
        throw error
    }

    do {
        var urls: [String] = []
        for ports in portSets {
            urls.append(
                try await server.registerPortForwardURL(
                    CRIShimPortForwardInvocation(sandboxID: "sandbox-1", ports: ports)
                ))
        }
        try await body(urls, server)
        await server.stop()
        await shutdown(group)
    } catch {
        await server.stop()
        await shutdown(group)
        throw error
    }
}

private func withSPDYPortForwardServer(
    runtimeManager: RecordingRuntimeManager,
    portSets: [[UInt32]],
    maximumActivePortForwardTunnels: Int,
    body: ([String]) async throws -> Void
) async throws {
    try await withObservedSPDYPortForwardServer(
        runtimeManager: runtimeManager,
        portSets: portSets,
        maximumActivePortForwardTunnels: maximumActivePortForwardTunnels
    ) { urls, _ in
        try await body(urls)
    }
}

private func withWebSocketPortForwardServer(
    runtimeManager: RecordingRuntimeManager,
    portSets: [[UInt32]],
    maximumActivePortForwardTunnels: Int,
    body: ([String]) async throws -> Void
) async throws {
    try await withSPDYPortForwardServer(
        runtimeManager: runtimeManager,
        portSets: portSets,
        maximumActivePortForwardTunnels: maximumActivePortForwardTunnels,
        body: body
    )
}

private func withObservedWebSocketPortForwardServer(
    runtimeManager: RecordingRuntimeManager,
    portSets: [[UInt32]],
    maximumActivePortForwardTunnels: Int,
    body: ([String], CRIShimStreamingServer) async throws -> Void
) async throws {
    try await withObservedSPDYPortForwardServer(
        runtimeManager: runtimeManager,
        portSets: portSets,
        maximumActivePortForwardTunnels: maximumActivePortForwardTunnels,
        body: body
    )
}

private struct TestSPDYPortForwardResult: Sendable {
    var error = Data()
    var data = Data()
    var errorFinished = false
    var dataFinished = false
    var terminalStreamOrder: [UInt32] = []
    var receivedBackendDataAfterTerminal = false
}

private struct TestSPDYFrame: Sendable {
    var streamID: UInt32?
    var controlType: UInt16?
    var flags: UInt8
    var payload: Data
}

private struct TestRawWebSocketFrame: Sendable {
    var opcode: UInt8
    var payload: Data
}

private final class TestRawWebSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let ioQueue: DispatchQueue
    private let stateLock = NSLock()
    private var closed = false

    init(url urlString: String, protocolName: String) async throws {
        guard
            let url = URL(string: urlString),
            let host = url.host,
            let port = url.port
        else {
            throw CRIShimRuntimeServerTestError.invalidHTTPResponse
        }

        #if os(Linux)
        let socketType = CInt(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, socketType, 0)
        guard fd >= 0 else {
            throw currentPOSIXError()
        }
        self.fd = fd
        self.ioQueue = DispatchQueue(label: "container.cri.tests.websocket.\(UUID().uuidString)")

        do {
            try await performBlockingIO(on: ioQueue) { [self] in
                var timeout = timeval(tv_sec: 15, tv_usec: 0)
                guard
                    setsockopt(
                        fd,
                        SOL_SOCKET,
                        SO_RCVTIMEO,
                        &timeout,
                        socklen_t(MemoryLayout<timeval>.size)
                    ) == 0
                else {
                    throw currentPOSIXError()
                }
                #if !os(Linux)
                var noSignal: Int32 = 1
                guard
                    setsockopt(
                        fd,
                        SOL_SOCKET,
                        SO_NOSIGPIPE,
                        &noSignal,
                        socklen_t(MemoryLayout<Int32>.size)
                    ) == 0
                else {
                    throw currentPOSIXError()
                }
                #endif
                let address = try SocketAddress(ipAddress: host, port: port)
                try address.withSockAddr { pointer, size in
                    guard connect(fd, pointer, UInt32(size)) == 0 else {
                        throw currentPOSIXError()
                    }
                }
                try upgrade(url: url, host: host, port: port, protocolName: protocolName)
            }
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    deinit {
        closeTransport()
    }

    func limitReceiveBuffer(to byteCount: Int32) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            var byteCount = byteCount
            guard
                Darwin.setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVBUF,
                    &byteCount,
                    socklen_t(MemoryLayout.size(ofValue: byteCount))
                ) == 0
            else {
                throw currentPOSIXError()
            }
        }
    }

    func sendBinary(_ payload: Data) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            try writeAll(makeMaskedFrame(opcode: 0x02, payload: payload))
        }
    }

    func sendText(_ text: String) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            try writeAll(makeMaskedFrame(opcode: 0x01, payload: Data(text.utf8)))
        }
    }

    func sendPingBurst(count: Int) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            let frame = makeMaskedFrame(opcode: 0x09, payload: Data())
            var burst = Data()
            burst.reserveCapacity(frame.count * count)
            for _ in 0..<count {
                burst.append(frame)
            }
            try writeAll(burst)
        }
    }

    func sendPing() async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            try writeAll(makeMaskedFrame(opcode: 0x09, payload: Data()))
        }
    }

    func readServerFrame() async throws -> TestRawWebSocketFrame {
        try await performBlockingIO(on: ioQueue) { [self] in
            try readServerFrameBlocking()
        }
    }

    private func readServerFrameBlocking() throws -> TestRawWebSocketFrame {
        let header = try readExactly(2)
        let opcode = header[0] & 0x0F
        let masked = (header[1] & 0x80) != 0
        let shortLength = Int(header[1] & 0x7F)
        let payloadLength: Int
        switch shortLength {
        case 126:
            let extended = try readExactly(2)
            payloadLength = (Int(extended[0]) << 8) | Int(extended[1])
        case 127:
            let extended = try readExactly(8)
            var length: UInt64 = 0
            for byte in extended {
                length = (length << 8) | UInt64(byte)
            }
            guard length <= UInt64(Int.max) else {
                throw CRIShimRuntimeServerTestError.unexpectedFrame
            }
            payloadLength = Int(length)
        default:
            payloadLength = shortLength
        }
        let mask = masked ? try readExactly(4) : Data()
        var payload = try readExactly(payloadLength)
        if masked {
            for index in payload.indices {
                payload[index] ^= mask[index % mask.count]
            }
        }
        return TestRawWebSocketFrame(opcode: opcode, payload: payload)
    }

    func closeTransport() {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard !closed else {
                return false
            }
            closed = true
            return true
        }
        guard shouldClose else {
            return
        }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
    }

    private func upgrade(
        url: URL,
        host: String,
        port: Int,
        protocolName: String
    ) throws {
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }
        let request = Data(
            """
            GET \(path) HTTP/1.1\r
            Host: \(host):\(port)\r
            Connection: Upgrade\r
            Upgrade: websocket\r
            Sec-WebSocket-Version: 13\r
            Sec-WebSocket-Key: AAECAwQFBgcICQoLDA0ODw==\r
            Sec-WebSocket-Protocol: \(protocolName)\r
            \r

            """.utf8
        )
        try writeAll(request)

        let terminator = Data("\r\n\r\n".utf8)
        var response = Data()
        while response.range(of: terminator) == nil {
            guard response.count < 16 * 1024 else {
                throw CRIShimRuntimeServerTestError.invalidHTTPResponse
            }
            response.append(try readExactly(1))
        }
        let text = String(decoding: response, as: UTF8.self).lowercased()
        guard
            text.contains("http/1.1 101"),
            text.contains("sec-websocket-protocol: \(protocolName.lowercased())")
        else {
            throw CRIShimRuntimeServerTestError.invalidHTTPResponse
        }
    }

    private func makeMaskedFrame(opcode: UInt8, payload: Data) -> Data {
        let mask: [UInt8] = [0x17, 0x29, 0x3B, 0x4D]
        var frame = Data([0x80 | opcode])
        switch payload.count {
        case 0...125:
            frame.append(0x80 | UInt8(payload.count))
        case 126...Int(UInt16.max):
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        default:
            frame.append(0x80 | 127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((count >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % mask.count])
        }
        return frame
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    fd,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                throw currentPOSIXError()
            }
        }
    }

    private func readExactly(_ length: Int) throws -> Data {
        var result = Data(count: length)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    fd,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count == 0 {
                    throw CRIShimRuntimeServerTestError.unexpectedEOF
                }
                if errno == EINTR {
                    continue
                }
                throw currentPOSIXError()
            }
        }
        return result
    }
}

private final class TestSPDYConnection: @unchecked Sendable {
    private let fd: Int32
    private let deflater: CRIShimSPDYHeaderDeflater
    private let ioQueue: DispatchQueue
    private let stateLock = NSLock()
    private var closed = false

    init(url urlString: String) async throws {
        guard
            let url = URL(string: urlString),
            let host = url.host,
            let port = url.port
        else {
            throw CRIShimRuntimeServerTestError.invalidHTTPResponse
        }

        #if os(Linux)
        let socketType = CInt(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, socketType, 0)
        guard fd >= 0 else {
            throw currentPOSIXError()
        }
        self.fd = fd
        self.deflater = try CRIShimSPDYHeaderDeflater()
        self.ioQueue = DispatchQueue(label: "container.cri.tests.spdy.\(UUID().uuidString)")

        do {
            try await performBlockingIO(on: ioQueue) { [self] in
                // Keep the socket timeout bounded without making these
                // loopback protocol tests depend on scheduler latency.
                var timeout = timeval(tv_sec: 15, tv_usec: 0)
                guard
                    setsockopt(
                        fd,
                        SOL_SOCKET,
                        SO_RCVTIMEO,
                        &timeout,
                        socklen_t(MemoryLayout<timeval>.size)
                    ) == 0
                else {
                    throw currentPOSIXError()
                }
                #if !os(Linux)
                var noSignal: Int32 = 1
                guard
                    setsockopt(
                        fd,
                        SOL_SOCKET,
                        SO_NOSIGPIPE,
                        &noSignal,
                        socklen_t(MemoryLayout<Int32>.size)
                    ) == 0
                else {
                    throw currentPOSIXError()
                }
                #endif

                let address = try SocketAddress(ipAddress: host, port: port)
                try address.withSockAddr { pointer, size in
                    guard connect(fd, pointer, UInt32(size)) == 0 else {
                        throw currentPOSIXError()
                    }
                }
                try upgrade(url: url, host: host, port: port)
            }
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    deinit {
        closeTransport()
    }

    func closeTransport() {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard !closed else {
                return false
            }
            closed = true
            return true
        }
        guard shouldClose else {
            return
        }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
    }

    func openPortForwardPair(
        requestID: String,
        port: UInt32,
        errorStreamID: UInt32,
        dataStreamID: UInt32,
        clientDataChunks: [Data] = [],
        closeClientWrite: Bool
    ) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            try writeSYNStream(
                streamID: errorStreamID,
                headers: [
                    "port": [String(port)],
                    "requestid": [requestID],
                    "streamtype": ["error"],
                ]
            )
            try writeDataFrame(streamID: errorStreamID, flags: 0x01, payload: Data())

            try writeSYNStream(
                streamID: dataStreamID,
                headers: [
                    "port": [String(port)],
                    "requestid": [requestID],
                    "streamtype": ["data"],
                ]
            )
            if clientDataChunks.isEmpty {
                if closeClientWrite {
                    try writeDataFrame(streamID: dataStreamID, flags: 0x01, payload: Data())
                }
                return
            }
            for (index, chunk) in clientDataChunks.enumerated() {
                let isLast = index == clientDataChunks.count - 1
                try writeDataFrame(
                    streamID: dataStreamID,
                    flags: closeClientWrite && isLast ? 0x01 : 0,
                    payload: chunk
                )
            }
        }
    }

    func writePortForwardSYN(
        streamID: UInt32,
        requestID: String?,
        port: UInt32,
        kind: String,
        closeStream: Bool = false
    ) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            var headers = [
                "port": [String(port)],
                "streamtype": [kind],
            ]
            if let requestID {
                headers["requestid"] = [requestID]
            }
            try writeSYNStream(streamID: streamID, headers: headers, flags: closeStream ? 0x01 : 0)
        }
    }

    func writeRSTStream(streamID: UInt32, status: UInt32 = 5) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            var payload = Data()
            appendSPDYUInt32(streamID & 0x7FFF_FFFF, to: &payload)
            appendSPDYUInt32(status, to: &payload)
            try writeControlFrame(type: 3, payload: payload)
        }
    }

    func writePing(id: UInt32) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            var payload = Data()
            appendSPDYUInt32(id, to: &payload)
            try writeControlFrame(type: 6, payload: payload)
        }
    }

    func writePingBurst(count: Int) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            var frame = Data()
            appendSPDYUInt32(0x8000_0000 | (UInt32(3) << 16) | UInt32(6), to: &frame)
            appendSPDYFlagsAndLength(flags: 0, length: 4, to: &frame)
            appendSPDYUInt32(1, to: &frame)
            var burst = Data()
            burst.reserveCapacity(frame.count * count)
            for _ in 0..<count {
                burst.append(frame)
            }
            try writeAll(burst)
        }
    }

    func limitReceiveBuffer(to byteCount: Int32) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            var byteCount = byteCount
            guard
                Darwin.setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVBUF,
                    &byteCount,
                    socklen_t(MemoryLayout.size(ofValue: byteCount))
                ) == 0
            else {
                throw currentPOSIXError()
            }
        }
    }

    func waitForTransportEOF() async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    continue
                }
                if count == 0 {
                    return
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CRIShimRuntimeServerTestError.timedOut("SPDY transport EOF")
                }
                throw currentPOSIXError()
            }
        }
    }

    func readControlStreamID(type: UInt16) async throws -> UInt32 {
        try await performBlockingIO(on: ioQueue) { [self] in
            for _ in 0..<256 {
                let frame = try readFrame()
                guard frame.controlType == type, frame.payload.count >= 4 else {
                    continue
                }
                return readSPDYUInt32(from: frame.payload, offset: 0) & 0x7FFF_FFFF
            }
            throw CRIShimRuntimeServerTestError.invalidSPDYFrame
        }
    }

    func readPing(id: UInt32) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            for _ in 0..<256 {
                let frame = try readFrame()
                guard frame.controlType == 6, frame.payload.count == 4 else {
                    continue
                }
                if readSPDYUInt32(from: frame.payload, offset: 0) == id {
                    return
                }
            }
            throw CRIShimRuntimeServerTestError.invalidSPDYFrame
        }
    }

    func readPortForwardResult(
        errorStreamID: UInt32,
        dataStreamID: UInt32
    ) async throws -> TestSPDYPortForwardResult {
        try await performBlockingIO(on: ioQueue) { [self] in
            var result = TestSPDYPortForwardResult()
            for _ in 0..<32 {
                let frame = try readFrame()
                guard let streamID = frame.streamID else {
                    continue
                }
                if !frame.payload.isEmpty, streamID == dataStreamID, !result.terminalStreamOrder.isEmpty {
                    result.receivedBackendDataAfterTerminal = true
                }
                if streamID == errorStreamID {
                    result.error.append(frame.payload)
                    if (frame.flags & 0x01) != 0, !result.errorFinished {
                        result.errorFinished = true
                        result.terminalStreamOrder.append(streamID)
                    }
                } else if streamID == dataStreamID {
                    result.data.append(frame.payload)
                    if (frame.flags & 0x01) != 0, !result.dataFinished {
                        result.dataFinished = true
                        result.terminalStreamOrder.append(streamID)
                    }
                }

                // client-go v1.27.2 first waits for the remote data copy and then
                // waits for the error reader. Both streams must therefore finish.
                if result.dataFinished && result.errorFinished {
                    return result
                }
            }
            throw CRIShimRuntimeServerTestError.invalidSPDYFrame
        }
    }

    func readDataPayload(dataStreamID: UInt32) async throws -> Data {
        try await performBlockingIO(on: ioQueue) { [self] in
            for _ in 0..<32 {
                let frame = try readFrame()
                if frame.streamID == dataStreamID, !frame.payload.isEmpty {
                    return frame.payload
                }
            }
            throw CRIShimRuntimeServerTestError.invalidSPDYFrame
        }
    }

    func writeClientData(
        dataStreamID: UInt32,
        payload: Data,
        closeClientWrite: Bool = false
    ) async throws {
        try await performBlockingIO(on: ioQueue) { [self] in
            try writeDataFrame(
                streamID: dataStreamID,
                flags: closeClientWrite ? 0x01 : 0,
                payload: payload
            )
        }
    }

    private func upgrade(url: URL, host: String, port: Int) throws {
        let path = url.path.isEmpty ? "/" : url.path
        let request = Data(
            """
            GET \(path) HTTP/1.1\r
            Host: \(host):\(port)\r
            Connection: Upgrade\r
            Upgrade: SPDY/3.1\r
            X-Stream-Protocol-Version: portforward.k8s.io\r
            \r

            """.utf8
        )
        try writeAll(request)

        let terminator = Data("\r\n\r\n".utf8)
        var response = Data()
        while response.range(of: terminator) == nil {
            guard response.count < 16 * 1024 else {
                throw CRIShimRuntimeServerTestError.invalidHTTPResponse
            }
            response.append(try readExactly(1))
        }
        let text = String(decoding: response, as: UTF8.self).lowercased()
        guard
            text.contains("http/1.1 101"),
            text.contains("x-stream-protocol-version: portforward.k8s.io")
        else {
            throw CRIShimRuntimeServerTestError.invalidHTTPResponse
        }
    }

    private func writeSYNStream(
        streamID: UInt32,
        headers: [String: [String]],
        flags: UInt8 = 0
    ) throws {
        var payload = Data()
        appendSPDYUInt32(streamID & 0x7FFF_FFFF, to: &payload)
        appendSPDYUInt32(0, to: &payload)
        payload.append(contentsOf: [0, 0])
        payload.append(try deflater.compress(makeSPDYHeaderBlock(headers)))

        var frame = Data()
        appendSPDYUInt32(0x8000_0000 | (UInt32(3) << 16) | UInt32(1), to: &frame)
        appendSPDYFlagsAndLength(flags: flags, length: payload.count, to: &frame)
        frame.append(payload)
        try writeAll(frame)
    }

    private func writeControlFrame(type: UInt16, payload: Data) throws {
        var frame = Data()
        appendSPDYUInt32(0x8000_0000 | (UInt32(3) << 16) | UInt32(type), to: &frame)
        appendSPDYFlagsAndLength(flags: 0, length: payload.count, to: &frame)
        frame.append(payload)
        try writeAll(frame)
    }

    private func writeDataFrame(
        streamID: UInt32,
        flags: UInt8,
        payload: Data
    ) throws {
        var frame = Data()
        appendSPDYUInt32(streamID & 0x7FFF_FFFF, to: &frame)
        appendSPDYFlagsAndLength(flags: flags, length: payload.count, to: &frame)
        frame.append(payload)
        try writeAll(frame)
    }

    private func readFrame() throws -> TestSPDYFrame {
        let header = try readExactly(8)
        let firstWord = readSPDYUInt32(from: header, offset: 0)
        let flags = header[4]
        let length =
            (Int(header[5]) << 16)
            | (Int(header[6]) << 8)
            | Int(header[7])
        let payload = try readExactly(length)
        let isControl = (firstWord & 0x8000_0000) != 0
        return TestSPDYFrame(
            streamID: isControl ? nil : firstWord & 0x7FFF_FFFF,
            controlType: isControl ? UInt16(firstWord & 0xFFFF) : nil,
            flags: flags,
            payload: payload
        )
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    fd,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                throw currentPOSIXError()
            }
        }
    }

    private func readExactly(_ length: Int) throws -> Data {
        guard length > 0 else {
            return Data()
        }
        var result = Data(count: length)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    fd,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count == 0 {
                    throw CRIShimRuntimeServerTestError.unexpectedEOF
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CRIShimRuntimeServerTestError.timedOut("SPDY frame")
                }
                throw currentPOSIXError()
            }
        }
        return result
    }
}

private func performBlockingIO<Value: Sendable>(
    on queue: DispatchQueue,
    _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do {
                continuation.resume(returning: try operation())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func appendSPDYUInt32(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ])
}

private func appendSPDYFlagsAndLength(
    flags: UInt8,
    length: Int,
    to data: inout Data
) {
    data.append(flags)
    data.append(UInt8((length >> 16) & 0xFF))
    data.append(UInt8((length >> 8) & 0xFF))
    data.append(UInt8(length & 0xFF))
}

private func readSPDYUInt32(from data: Data, offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24)
        | (UInt32(data[offset + 1]) << 16)
        | (UInt32(data[offset + 2]) << 8)
        | UInt32(data[offset + 3])
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func criShimHighDescriptorMinimum(
    reservedFromLimit: rlim_t = 96
) throws -> Int32 {
    var limit = rlimit()
    guard Darwin.getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
        throw currentPOSIXError()
    }
    let cappedLimit = min(limit.rlim_cur, rlim_t(32_768))
    guard cappedLimit > reservedFromLimit else {
        throw POSIXError(.EMFILE)
    }
    return Int32(cappedLimit - reservedFromLimit)
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
    from task: URLSessionWebSocketTask,
    timeout: Duration = .seconds(2)
) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        let completion = WebSocketBinaryReceiveCompletion(continuation: continuation)
        task.receive { result in
            switch result {
            case .success(.data(let data)):
                completion.resume(with: .success(data))
            case .success(.string(let string)):
                completion.resume(
                    with: .failure(CRIShimRuntimeServerTestError.unexpectedTextFrame(string))
                )
            case .failure(let error):
                completion.resume(with: .failure(error))
            @unknown default:
                completion.resume(with: .failure(CRIShimRuntimeServerTestError.unexpectedFrame))
            }
        }
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            completion.resume(
                with: .failure(CRIShimRuntimeServerTestError.timedOut("websocket binary message")),
                beforeContinuationResume: {
                    task.cancel(with: .goingAway, reason: nil)
                }
            )
        }
        completion.install(timeoutTask: timeoutTask)
    }
}

private func expectWebSocketReceiveFailure(
    _ task: URLSessionWebSocketTask,
    timeout: Duration = .seconds(2)
) async throws {
    do {
        _ = try await receiveBinaryMessage(from: task, timeout: timeout)
        Issue.record("expected websocket receive to fail")
    } catch CRIShimRuntimeServerTestError.timedOut {
        throw CRIShimRuntimeServerTestError.timedOut("websocket close")
    } catch {
        return
    }
}

private final class WebSocketBinaryReceiveCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func install(timeoutTask: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard continuation != nil else {
                return true
            }
            self.timeoutTask = timeoutTask
            return false
        }
        if shouldCancel {
            timeoutTask.cancel()
        }
    }

    func resume(
        with result: Result<Data, any Error>,
        beforeContinuationResume: () -> Void = {}
    ) {
        let resources = lock.withLock {
            () -> (CheckedContinuation<Data, any Error>?, Task<Void, Never>?) in
            let continuation = self.continuation
            self.continuation = nil
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            return (continuation, timeoutTask)
        }
        guard let continuation = resources.0 else {
            return
        }
        resources.1?.cancel()
        beforeContinuationResume()
        continuation.resume(with: result)
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
    case unexpectedEOF
    case invalidHTTPResponse
    case invalidSPDYFrame
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
    gateway: String,
    ipv6Address: String? = nil,
    ipv6Gateway: String? = nil
) throws -> ContainerResource.Attachment {
    ContainerResource.Attachment(
        network: network,
        hostname: "demo",
        ipv4Address: try CIDRv4(address),
        ipv4Gateway: try IPv4Address(gateway),
        ipv6Address: try ipv6Address.map { try CIDRv6($0) },
        ipv6Gateway: try ipv6Gateway.map { try IPv6Address($0) },
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

private func readyReadinessSnapshot() -> CRIShimReadinessSnapshot {
    CRIShimReadinessSnapshot(
        runtime: CRIShimRuntimeConditionSnapshot(
            type: CRIShimRuntimeConditionType.runtimeReady,
            status: true,
            reason: "RuntimeHealthOK",
            message: "test runtime ready"
        ),
        network: CRIShimRuntimeConditionSnapshot(
            type: CRIShimRuntimeConditionType.networkReady,
            status: true,
            reason: "NetworkReady",
            message: "test network ready"
        )
    )
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CRIShimRuntimeServerTests-\(UUID().uuidString)", isDirectory: true)
}

private func normalizedDirectoryPath(_ url: URL) -> String {
    url.standardizedFileURL.path
}

private struct OpaqueCRIShimError: Error, CustomStringConvertible {
    var description: String
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
