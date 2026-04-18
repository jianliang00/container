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
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let imageManager = RecordingImageManager(
            images: [
                CRIShimImageRecord(
                    reference: "example.com/macos/workload:latest",
                    digest: "sha256:abc123",
                    size: 4096,
                    annotations: ["org.opencontainers.image.ref.name": "example.com/macos/workload:latest"]
                )
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
        let server = CRIShimGRPCServer(
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
            imageManager: imageManager
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

        let imageClient = Runtime_V1_ImageServiceAsyncClient(channel: channel)
        let listImages = try await imageClient.listImages(Runtime_V1_ListImagesRequest())
        #expect(listImages.images.count == 1)
        #expect(listImages.images[0].id == "sha256:abc123")
        #expect(listImages.images[0].repoTags == ["example.com/macos/workload:latest"])
        #expect(listImages.images[0].repoDigests == ["example.com/macos/workload@sha256:abc123"])

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

private final class RecordingRuntimeManager: CRIShimRuntimeManaging, @unchecked Sendable {
    var execSyncResult: ExecSyncResult
    private(set) var execSyncCalls: [RecordingExecSyncCall] = []

    init(execSyncResult: ExecSyncResult) {
        self.execSyncResult = execSyncResult
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

private func shutdown(_ group: MultiThreadedEventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
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
