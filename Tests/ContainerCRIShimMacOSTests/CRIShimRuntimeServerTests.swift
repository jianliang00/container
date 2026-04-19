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

import Foundation
import GRPC
import NIO
import Testing

@testable import ContainerCRI
@testable import ContainerCRIShimMacOS
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
                logPath: "/var/log/pods/default_demo_uid/workload/0.log",
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
                    annotations: ["org.opencontainers.image.ref.name": "example.com/macos/workload:latest"]
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
        let runtimeManager = RecordingRuntimeManager(
            execSyncResult: ExecSyncResult(
                exitCode: 7,
                stdout: Data("exec stdout".utf8),
                stderr: Data("exec stderr".utf8)
            ))
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

        var sandboxStatusRequest = Runtime_V1_PodSandboxStatusRequest()
        sandboxStatusRequest.podSandboxID = "sandbox-1"
        sandboxStatusRequest.verbose = true
        let sandboxStatus = try await client.podSandboxStatus(sandboxStatusRequest)
        #expect(sandboxStatus.status.id == "sandbox-1")
        #expect(sandboxStatus.status.metadata.attempt == 2)
        #expect(sandboxStatus.status.state == .sandboxReady)
        #expect(sandboxStatus.containersStatuses.map(\.id) == ["container-1"])
        #expect(sandboxStatus.info["metadata"]?.contains(#""runtimeHandler":"macos""#) == true)

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
        #expect(containerStatus.status.startedAt == 1_700_000_020_000_000_000)
        #expect(containerStatus.status.logPath == "/var/log/pods/default_demo_uid/workload/0.log")
        #expect(containerStatus.info["metadata"]?.contains(#""sandboxID":"sandbox-1""#) == true)

        var createRequest = Runtime_V1_CreateContainerRequest()
        createRequest.podSandboxID = "sandbox-1"
        createRequest.sandboxConfig.logDirectory = "/var/log/pods/default_demo_uid"
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
        #expect(createdStatus.status.logPath == "/var/log/pods/default_demo_uid/created/0.log")

        var startRequest = Runtime_V1_StartContainerRequest()
        startRequest.containerID = created.containerID
        _ = try await client.startContainer(startRequest)
        #expect(runtimeManager.startWorkloadCalls.count == 1)
        let startCall = try #require(runtimeManager.startWorkloadCalls.first)
        #expect(startCall.sandboxID == "sandbox-1")
        #expect(startCall.workloadID == created.containerID)

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

private struct RecordingCreateWorkloadCall {
    var sandboxID: String
    var configuration: WorkloadConfiguration
}

private struct RecordingStopWorkloadCall {
    var sandboxID: String
    var workloadID: String
    var options: ContainerStopOptions
}

private final class RecordingRuntimeManager: CRIShimRuntimeManaging, @unchecked Sendable {
    var execSyncResult: ExecSyncResult
    private var workloadConfigurations: [String: WorkloadConfiguration] = [:]
    private var workloadSnapshots: [String: WorkloadSnapshot] = [:]
    private(set) var createSandboxCalls: [ContainerConfiguration] = []
    private(set) var startSandboxCalls: [(id: String, presentGUI: Bool)] = []
    private(set) var stopSandboxCalls: [(id: String, options: ContainerStopOptions)] = []
    private(set) var removeSandboxCalls: [(id: String, force: Bool)] = []
    private(set) var removeSandboxPolicyCalls: [String] = []
    private(set) var createWorkloadCalls: [RecordingCreateWorkloadCall] = []
    private(set) var startWorkloadCalls: [(sandboxID: String, workloadID: String)] = []
    private(set) var stopWorkloadCalls: [RecordingStopWorkloadCall] = []
    private(set) var removeWorkloadCalls: [(sandboxID: String, workloadID: String)] = []
    private(set) var execSyncCalls: [RecordingExecSyncCall] = []

    init(execSyncResult: ExecSyncResult) {
        self.execSyncResult = execSyncResult
    }

    func createSandbox(
        configuration: ContainerConfiguration
    ) async throws {
        createSandboxCalls.append(configuration)
    }

    func startSandbox(
        id: String,
        presentGUI: Bool
    ) async throws {
        startSandboxCalls.append((id: id, presentGUI: presentGUI))
    }

    func stopSandbox(
        id: String,
        options: ContainerStopOptions
    ) async throws {
        stopSandboxCalls.append((id: id, options: options))
    }

    func removeSandbox(
        id: String,
        force: Bool
    ) async throws {
        removeSandboxCalls.append((id: id, force: force))
    }

    func removeSandboxPolicy(
        sandboxID: String
    ) async throws {
        removeSandboxPolicyCalls.append(sandboxID)
    }

    func createWorkload(
        sandboxID: String,
        configuration: WorkloadConfiguration
    ) async throws {
        workloadConfigurations[configuration.id] = configuration
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
        workloadSnapshots[workloadID] = WorkloadSnapshot(
            configuration: configuration,
            status: .running,
            startedDate: Date()
        )
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
        workloadSnapshots[workloadID] = WorkloadSnapshot(
            configuration: configuration,
            status: .stopped,
            exitCode: 42,
            startedDate: workloadSnapshots[workloadID]?.startedDate,
            exitedAt: Date()
        )
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

private enum CRIShimRuntimeServerTestError: Error {
    case socketDidNotStart(String)
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
