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

import ContainerCRI
import ContainerVersion
import GRPC

public struct CRIShimRuntimeVersionInfo: Equatable, Sendable {
    public var runtimeName: String
    public var runtimeVersion: String
    public var runtimeAPIVersion: String

    public init(
        runtimeName: String = "container-macos",
        runtimeVersion: String = ReleaseVersion.version(),
        runtimeAPIVersion: String = CRIProtocol.runtimeAPIVersion
    ) {
        self.runtimeName = runtimeName
        self.runtimeVersion = runtimeVersion
        self.runtimeAPIVersion = runtimeAPIVersion
    }
}

public final class CRIShimRuntimeServiceProvider: Runtime_V1_RuntimeServiceAsyncProvider, @unchecked Sendable {
    public var versionInfo: CRIShimRuntimeVersionInfo
    public var config: CRIShimConfig
    private let readinessChecker: any CRIShimReadinessChecking

    public init(
        config: CRIShimConfig,
        versionInfo: CRIShimRuntimeVersionInfo = CRIShimRuntimeVersionInfo(),
        readinessChecker: any CRIShimReadinessChecking = ContainerKitCRIShimReadinessChecker()
    ) {
        self.config = config
        self.versionInfo = versionInfo
        self.readinessChecker = readinessChecker
    }

    public func version(
        request: Runtime_V1_VersionRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_VersionResponse {
        var response = Runtime_V1_VersionResponse()
        response.version = versionInfo.runtimeAPIVersion
        response.runtimeName = versionInfo.runtimeName
        response.runtimeVersion = versionInfo.runtimeVersion
        response.runtimeApiVersion = versionInfo.runtimeAPIVersion
        return response
    }

    public func status(
        request: Runtime_V1_StatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StatusResponse {
        let snapshot = await readinessChecker.snapshot(config: config)
        var response = Runtime_V1_StatusResponse()
        var status = Runtime_V1_RuntimeStatus()
        status.conditions = [
            makeRuntimeCondition(snapshot.runtime),
            makeRuntimeCondition(snapshot.network),
        ]
        response.status = status
        response.runtimeHandlers = runtimeHandlers(from: config)
        response.features = Runtime_V1_RuntimeFeatures()
        if request.verbose {
            response.info = snapshot.info
        }
        return response
    }

    public func runtimeConfig(
        request: Runtime_V1_RuntimeConfigRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RuntimeConfigResponse {
        Runtime_V1_RuntimeConfigResponse()
    }

    public func updateRuntimeConfig(
        request: Runtime_V1_UpdateRuntimeConfigRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_UpdateRuntimeConfigResponse {
        Runtime_V1_UpdateRuntimeConfigResponse()
    }
}

public final class CRIShimImageServiceProvider: Runtime_V1_ImageServiceAsyncProvider, @unchecked Sendable {
    public init() {}
}

public enum CRIShimGRPCStatusMapper {
    public static func unsupported(_ operation: CRIRuntimeOperation) -> GRPCStatus {
        GRPCStatus(
            code: .unimplemented,
            message: CRIRuntimeOperationSurface.unsupportedReason(for: operation)
        )
    }

    public static func unsupported(_ operation: CRIImageOperation) -> GRPCStatus {
        GRPCStatus(
            code: .unimplemented,
            message: CRIImageOperationSurface.unsupportedReason(for: operation)
        )
    }
}

extension Runtime_V1_RuntimeServiceAsyncProvider {
    public func runPodSandbox(
        request: Runtime_V1_RunPodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RunPodSandboxResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.runPodSandbox)
    }

    public func stopPodSandbox(
        request: Runtime_V1_StopPodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StopPodSandboxResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.stopPodSandbox)
    }

    public func removePodSandbox(
        request: Runtime_V1_RemovePodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RemovePodSandboxResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.removePodSandbox)
    }

    public func podSandboxStatus(
        request: Runtime_V1_PodSandboxStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PodSandboxStatusResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.podSandboxStatus)
    }

    public func listPodSandbox(
        request: Runtime_V1_ListPodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListPodSandboxResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.listPodSandbox)
    }

    public func createContainer(
        request: Runtime_V1_CreateContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_CreateContainerResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.createContainer)
    }

    public func startContainer(
        request: Runtime_V1_StartContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StartContainerResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.startContainer)
    }

    public func stopContainer(
        request: Runtime_V1_StopContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StopContainerResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.stopContainer)
    }

    public func removeContainer(
        request: Runtime_V1_RemoveContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RemoveContainerResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.removeContainer)
    }

    public func listContainers(
        request: Runtime_V1_ListContainersRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListContainersResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.listContainers)
    }

    public func containerStatus(
        request: Runtime_V1_ContainerStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ContainerStatusResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.containerStatus)
    }

    public func updateContainerResources(
        request: Runtime_V1_UpdateContainerResourcesRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_UpdateContainerResourcesResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.updateContainerResources)
    }

    public func reopenContainerLog(
        request: Runtime_V1_ReopenContainerLogRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ReopenContainerLogResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.reopenContainerLog)
    }

    public func execSync(
        request: Runtime_V1_ExecSyncRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ExecSyncResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.execSync)
    }

    public func exec(
        request: Runtime_V1_ExecRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ExecResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.exec)
    }

    public func attach(
        request: Runtime_V1_AttachRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_AttachResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.attach)
    }

    public func portForward(
        request: Runtime_V1_PortForwardRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PortForwardResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.portForward)
    }

    public func containerStats(
        request: Runtime_V1_ContainerStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ContainerStatsResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.containerStats)
    }

    public func listContainerStats(
        request: Runtime_V1_ListContainerStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListContainerStatsResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.listContainerStats)
    }

    public func podSandboxStats(
        request: Runtime_V1_PodSandboxStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PodSandboxStatsResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.podSandboxStats)
    }

    public func listPodSandboxStats(
        request: Runtime_V1_ListPodSandboxStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListPodSandboxStatsResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.listPodSandboxStats)
    }

    public func checkpointContainer(
        request: Runtime_V1_CheckpointContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_CheckpointContainerResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.checkpointContainer)
    }

    public func getContainerEvents(
        request: Runtime_V1_GetEventsRequest,
        responseStream: GRPCAsyncResponseStreamWriter<Runtime_V1_ContainerEventResponse>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        throw CRIShimGRPCStatusMapper.unsupported(.getContainerEvents)
    }

    public func listMetricDescriptors(
        request: Runtime_V1_ListMetricDescriptorsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListMetricDescriptorsResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.listMetricDescriptors)
    }

    public func listPodSandboxMetrics(
        request: Runtime_V1_ListPodSandboxMetricsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListPodSandboxMetricsResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.listPodSandboxMetrics)
    }

    public func updatePodSandboxResources(
        request: Runtime_V1_UpdatePodSandboxResourcesRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_UpdatePodSandboxResourcesResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.updatePodSandboxResources)
    }
}

private func makeRuntimeCondition(
    _ snapshot: CRIShimRuntimeConditionSnapshot
) -> Runtime_V1_RuntimeCondition {
    var condition = Runtime_V1_RuntimeCondition()
    condition.type = snapshot.type
    condition.status = snapshot.status
    condition.reason = snapshot.reason
    condition.message = snapshot.message
    return condition
}

private func runtimeHandlers(from config: CRIShimConfig) -> [Runtime_V1_RuntimeHandler] {
    var handlers: [Runtime_V1_RuntimeHandler] = [makeRuntimeHandler(name: "")]
    handlers.append(contentsOf: config.runtimeHandlers.keys.sorted().map { makeRuntimeHandler(name: $0) })
    return handlers
}

private func makeRuntimeHandler(name: String) -> Runtime_V1_RuntimeHandler {
    var handler = Runtime_V1_RuntimeHandler()
    handler.name = name
    handler.features = Runtime_V1_RuntimeHandlerFeatures()
    return handler
}

extension Runtime_V1_ImageServiceAsyncProvider {
    public func listImages(
        request: Runtime_V1_ListImagesRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListImagesResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.listImages)
    }

    public func imageStatus(
        request: Runtime_V1_ImageStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ImageStatusResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.imageStatus)
    }

    public func pullImage(
        request: Runtime_V1_PullImageRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PullImageResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.pullImage)
    }

    public func removeImage(
        request: Runtime_V1_RemoveImageRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RemoveImageResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.removeImage)
    }

    public func imageFsInfo(
        request: Runtime_V1_ImageFsInfoRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ImageFsInfoResponse {
        throw CRIShimGRPCStatusMapper.unsupported(.imageFsInfo)
    }
}
