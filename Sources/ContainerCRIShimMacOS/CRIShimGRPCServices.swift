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
import ContainerResource
import ContainerVersion
import Foundation
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
    private let runtimeManager: any CRIShimRuntimeManaging
    private let handlerLogger: CRIShimGRPCHandlerLogger

    public init(
        config: CRIShimConfig,
        versionInfo: CRIShimRuntimeVersionInfo = CRIShimRuntimeVersionInfo(),
        readinessChecker: any CRIShimReadinessChecking = ContainerKitCRIShimReadinessChecker(),
        runtimeManager: any CRIShimRuntimeManaging = ContainerKitCRIShimRuntimeManager(),
        handlerLogger: CRIShimGRPCHandlerLogger = .runtimeService()
    ) {
        self.config = config
        self.versionInfo = versionInfo
        self.readinessChecker = readinessChecker
        self.runtimeManager = runtimeManager
        self.handlerLogger = handlerLogger
    }

    public func version(
        request: Runtime_V1_VersionRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_VersionResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.version.rawValue) {
            var response = Runtime_V1_VersionResponse()
            response.version = versionInfo.runtimeAPIVersion
            response.runtimeName = versionInfo.runtimeName
            response.runtimeVersion = versionInfo.runtimeVersion
            response.runtimeApiVersion = versionInfo.runtimeAPIVersion
            return response
        }
    }

    public func status(
        request: Runtime_V1_StatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StatusResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.status.rawValue) {
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
    }

    public func runtimeConfig(
        request: Runtime_V1_RuntimeConfigRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RuntimeConfigResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.runtimeConfig.rawValue) {
            Runtime_V1_RuntimeConfigResponse()
        }
    }

    public func updateRuntimeConfig(
        request: Runtime_V1_UpdateRuntimeConfigRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_UpdateRuntimeConfigResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.updateRuntimeConfig.rawValue) {
            Runtime_V1_UpdateRuntimeConfigResponse()
        }
    }

    public func execSync(
        request: Runtime_V1_ExecSyncRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ExecSyncResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.execSync.rawValue) {
            let invocation = try makeCRIShimExecSyncInvocation(request)
            let result = try await runtimeManager.execSync(
                containerID: invocation.containerID,
                configuration: invocation.configuration,
                timeout: invocation.timeout
            )
            return makeCRIShimExecSyncResponse(result)
        }
    }
}

public final class CRIShimImageServiceProvider: Runtime_V1_ImageServiceAsyncProvider, @unchecked Sendable {
    private let imageManager: any CRIShimImageManaging
    private let handlerLogger: CRIShimGRPCHandlerLogger

    public init(
        imageManager: any CRIShimImageManaging = ContainerKitCRIShimImageManager(),
        handlerLogger: CRIShimGRPCHandlerLogger = .imageService()
    ) {
        self.imageManager = imageManager
        self.handlerLogger = handlerLogger
    }

    public func listImages(
        request: Runtime_V1_ListImagesRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListImagesResponse {
        try await handlerLogger.handle(operation: CRIImageOperation.listImages.rawValue) {
            var response = Runtime_V1_ListImagesResponse()
            let images = try await imageManager.listImages()
            response.images = filteredImages(images, request: request).map(makeCRIImage)
            return response
        }
    }

    public func imageStatus(
        request: Runtime_V1_ImageStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ImageStatusResponse {
        try await handlerLogger.handle(operation: CRIImageOperation.imageStatus.rawValue) {
            do {
                let reference = try CRIShimImageReference.resolve(request.image)
                let image = try await findImage(reference: reference)
                var response = Runtime_V1_ImageStatusResponse()
                response.image = makeCRIImage(image)
                if request.verbose {
                    response.info = ["image": jsonString(image.info)]
                }
                return response
            } catch CRIShimError.notFound {
                return Runtime_V1_ImageStatusResponse()
            }
        }
    }

    public func removeImage(
        request: Runtime_V1_RemoveImageRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RemoveImageResponse {
        try await handlerLogger.handle(operation: CRIImageOperation.removeImage.rawValue) {
            let reference = try CRIShimImageReference.resolve(request.image)
            try await imageManager.removeImage(reference: reference)
            return Runtime_V1_RemoveImageResponse()
        }
    }

    public func pullImage(
        request: Runtime_V1_PullImageRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PullImageResponse {
        try await handlerLogger.handle(operation: CRIImageOperation.pullImage.rawValue) {
            let reference = try CRIShimImageReference.resolve(request.image)
            let authentication = try CRIShimImagePullAuthentication.resolve(request)
            let image = try await imageManager.pullImage(reference: reference, authentication: authentication)
            var response = Runtime_V1_PullImageResponse()
            response.imageRef = image.digest.isEmpty ? image.reference : image.digest
            return response
        }
    }

    public func imageFsInfo(
        request: Runtime_V1_ImageFsInfoRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ImageFsInfoResponse {
        try await handlerLogger.handle(operation: CRIImageOperation.imageFsInfo.rawValue) {
            let usage = try await imageManager.imageFilesystemUsage()
            var response = Runtime_V1_ImageFsInfoResponse()
            response.imageFilesystems = [makeCRIFilesystemUsage(usage)]
            return response
        }
    }

    private func findImage(reference: String) async throws -> CRIShimImageRecord {
        let images = try await imageManager.listImages()
        guard let image = images.first(where: { $0.matches(reference: reference) }) else {
            throw CRIShimError.notFound("image not found: \(reference)")
        }
        return image
    }
}

public enum CRIShimGRPCStatusMapper {
    public static func unsupportedError(_ operation: CRIRuntimeOperation) -> CRIShimError {
        CRIShimError.unsupported(CRIRuntimeOperationSurface.unsupportedReason(for: operation))
    }

    public static func unsupportedError(_ operation: CRIImageOperation) -> CRIShimError {
        CRIShimError.unsupported(CRIImageOperationSurface.unsupportedReason(for: operation))
    }

    public static func unsupported(_ operation: CRIRuntimeOperation) -> GRPCStatus {
        status(for: unsupportedError(operation))
    }

    public static func unsupported(_ operation: CRIImageOperation) -> GRPCStatus {
        status(for: unsupportedError(operation))
    }

    public static func status(for error: any Error) -> GRPCStatus {
        if let status = error as? GRPCStatus {
            return status
        }

        let disposition = CRIShimErrorMapper.disposition(for: error)
        let code: GRPCStatus.Code =
            switch disposition.kind {
            case .unsupported:
                .unimplemented
            case .invalidArgument:
                .invalidArgument
            case .notFound:
                .notFound
            case .internalError:
                .internalError
            }
        return GRPCStatus(code: code, message: disposition.message)
    }
}

extension Runtime_V1_RuntimeServiceAsyncProvider {
    public func runPodSandbox(
        request: Runtime_V1_RunPodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RunPodSandboxResponse {
        try await unsupportedRuntime(.runPodSandbox)
    }

    public func stopPodSandbox(
        request: Runtime_V1_StopPodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StopPodSandboxResponse {
        try await unsupportedRuntime(.stopPodSandbox)
    }

    public func removePodSandbox(
        request: Runtime_V1_RemovePodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RemovePodSandboxResponse {
        try await unsupportedRuntime(.removePodSandbox)
    }

    public func podSandboxStatus(
        request: Runtime_V1_PodSandboxStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PodSandboxStatusResponse {
        try await unsupportedRuntime(.podSandboxStatus)
    }

    public func listPodSandbox(
        request: Runtime_V1_ListPodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListPodSandboxResponse {
        try await unsupportedRuntime(.listPodSandbox)
    }

    public func createContainer(
        request: Runtime_V1_CreateContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_CreateContainerResponse {
        try await unsupportedRuntime(.createContainer)
    }

    public func startContainer(
        request: Runtime_V1_StartContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StartContainerResponse {
        try await unsupportedRuntime(.startContainer)
    }

    public func stopContainer(
        request: Runtime_V1_StopContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StopContainerResponse {
        try await unsupportedRuntime(.stopContainer)
    }

    public func removeContainer(
        request: Runtime_V1_RemoveContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RemoveContainerResponse {
        try await unsupportedRuntime(.removeContainer)
    }

    public func listContainers(
        request: Runtime_V1_ListContainersRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListContainersResponse {
        try await unsupportedRuntime(.listContainers)
    }

    public func containerStatus(
        request: Runtime_V1_ContainerStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ContainerStatusResponse {
        try await unsupportedRuntime(.containerStatus)
    }

    public func updateContainerResources(
        request: Runtime_V1_UpdateContainerResourcesRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_UpdateContainerResourcesResponse {
        try await CRIShimGRPCHandlerLogger.runtimeService().handle(
            operation: CRIRuntimeOperation.updateContainerResources.rawValue
        ) {
            Runtime_V1_UpdateContainerResourcesResponse()
        }
    }

    public func reopenContainerLog(
        request: Runtime_V1_ReopenContainerLogRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ReopenContainerLogResponse {
        try await unsupportedRuntime(.reopenContainerLog)
    }

    public func execSync(
        request: Runtime_V1_ExecSyncRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ExecSyncResponse {
        try await unsupportedRuntime(.execSync)
    }

    public func exec(
        request: Runtime_V1_ExecRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ExecResponse {
        try await unsupportedRuntime(.exec)
    }

    public func attach(
        request: Runtime_V1_AttachRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_AttachResponse {
        try await unsupportedRuntime(.attach)
    }

    public func portForward(
        request: Runtime_V1_PortForwardRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PortForwardResponse {
        try await unsupportedRuntime(.portForward)
    }

    public func containerStats(
        request: Runtime_V1_ContainerStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ContainerStatsResponse {
        try await unsupportedRuntime(.containerStats)
    }

    public func listContainerStats(
        request: Runtime_V1_ListContainerStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListContainerStatsResponse {
        try await unsupportedRuntime(.listContainerStats)
    }

    public func podSandboxStats(
        request: Runtime_V1_PodSandboxStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PodSandboxStatsResponse {
        try await unsupportedRuntime(.podSandboxStats)
    }

    public func listPodSandboxStats(
        request: Runtime_V1_ListPodSandboxStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListPodSandboxStatsResponse {
        try await unsupportedRuntime(.listPodSandboxStats)
    }

    public func checkpointContainer(
        request: Runtime_V1_CheckpointContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_CheckpointContainerResponse {
        try await unsupportedRuntime(.checkpointContainer)
    }

    public func getContainerEvents(
        request: Runtime_V1_GetEventsRequest,
        responseStream: GRPCAsyncResponseStreamWriter<Runtime_V1_ContainerEventResponse>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        let _: Void = try await CRIShimGRPCHandlerLogger.runtimeService().handle(
            operation: CRIRuntimeOperation.getContainerEvents.rawValue
        ) {}
    }

    public func listMetricDescriptors(
        request: Runtime_V1_ListMetricDescriptorsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListMetricDescriptorsResponse {
        try await CRIShimGRPCHandlerLogger.runtimeService().handle(
            operation: CRIRuntimeOperation.listMetricDescriptors.rawValue
        ) {
            Runtime_V1_ListMetricDescriptorsResponse()
        }
    }

    public func listPodSandboxMetrics(
        request: Runtime_V1_ListPodSandboxMetricsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListPodSandboxMetricsResponse {
        try await CRIShimGRPCHandlerLogger.runtimeService().handle(
            operation: CRIRuntimeOperation.listPodSandboxMetrics.rawValue
        ) {
            Runtime_V1_ListPodSandboxMetricsResponse()
        }
    }

    public func updatePodSandboxResources(
        request: Runtime_V1_UpdatePodSandboxResourcesRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_UpdatePodSandboxResourcesResponse {
        try await CRIShimGRPCHandlerLogger.runtimeService().handle(
            operation: CRIRuntimeOperation.updatePodSandboxResources.rawValue
        ) {
            Runtime_V1_UpdatePodSandboxResourcesResponse()
        }
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

private func filteredImages(
    _ images: [CRIShimImageRecord],
    request: Runtime_V1_ListImagesRequest
) -> [CRIShimImageRecord] {
    guard request.hasFilter, request.filter.hasImage else {
        return images
    }

    guard let reference = try? CRIShimImageReference.resolve(request.filter.image) else {
        return images
    }

    return images.filter { $0.matches(reference: reference) }
}

private func makeCRIImage(_ image: CRIShimImageRecord) -> Runtime_V1_Image {
    var result = Runtime_V1_Image()
    result.id = image.digest
    if image.reference.contains("@") {
        result.repoDigests = [image.reference]
    } else {
        result.repoTags = [image.reference]
        result.repoDigests = image.repoDigests
    }
    result.size = image.size
    result.spec = makeImageSpec(image)
    result.pinned = image.pinned
    return result
}

private func makeImageSpec(_ image: CRIShimImageRecord) -> Runtime_V1_ImageSpec {
    var spec = Runtime_V1_ImageSpec()
    spec.image = image.reference
    spec.annotations = image.annotations
    return spec
}

private func makeCRIFilesystemUsage(_ usage: CRIShimImageFilesystemUsage) -> Runtime_V1_FilesystemUsage {
    var filesystem = Runtime_V1_FilesystemUsage()
    filesystem.timestamp = usage.timestampNanoseconds

    var identifier = Runtime_V1_FilesystemIdentifier()
    identifier.mountpoint = usage.mountpoint
    filesystem.fsID = identifier

    var usedBytes = Runtime_V1_UInt64Value()
    usedBytes.value = usage.usedBytes
    filesystem.usedBytes = usedBytes

    if let inodesUsedValue = usage.inodesUsed {
        var inodesUsed = Runtime_V1_UInt64Value()
        inodesUsed.value = inodesUsedValue
        filesystem.inodesUsed = inodesUsed
    }

    return filesystem
}

extension CRIShimImageRecord {
    fileprivate var info: [String: String] {
        [
            "digest": digest,
            "reference": reference,
            "size": String(size),
        ]
    }
}

private func jsonString(_ value: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}
