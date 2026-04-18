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

public enum CRIProtocol {
    public static let runtimeAPIVersion = "runtime.v1"
}

public enum CRIRuntimeOperation: String, CaseIterable, Sendable {
    case version = "Version"
    case status = "Status"
    case runtimeConfig = "RuntimeConfig"
    case updateRuntimeConfig = "UpdateRuntimeConfig"
    case runPodSandbox = "RunPodSandbox"
    case stopPodSandbox = "StopPodSandbox"
    case removePodSandbox = "RemovePodSandbox"
    case podSandboxStatus = "PodSandboxStatus"
    case listPodSandbox = "ListPodSandbox"
    case createContainer = "CreateContainer"
    case startContainer = "StartContainer"
    case stopContainer = "StopContainer"
    case removeContainer = "RemoveContainer"
    case containerStatus = "ContainerStatus"
    case listContainers = "ListContainers"
    case updateContainerResources = "UpdateContainerResources"
    case updatePodSandboxResources = "UpdatePodSandboxResources"
    case reopenContainerLog = "ReopenContainerLog"
    case execSync = "ExecSync"
    case exec = "Exec"
    case attach = "Attach"
    case portForward = "PortForward"
    case containerStats = "ContainerStats"
    case listContainerStats = "ListContainerStats"
    case podSandboxStats = "PodSandboxStats"
    case listPodSandboxStats = "ListPodSandboxStats"
    case checkpointContainer = "CheckpointContainer"
    case getContainerEvents = "GetContainerEvents"
    case listMetricDescriptors = "ListMetricDescriptors"
    case listPodSandboxMetrics = "ListPodSandboxMetrics"
}

public enum CRIRuntimeOperationSurface {
    public static let all: [CRIRuntimeOperation] = CRIRuntimeOperation.allCases

    public static func unsupportedReason(for operation: CRIRuntimeOperation) -> String {
        switch operation {
        case .version:
            return "Version is implemented by the protobuf-backed CRI server"
        case .status:
            return "Status is implemented by the protobuf-backed CRI server"
        case .runtimeConfig:
            return "RuntimeConfig is implemented by the protobuf-backed CRI server"
        case .updateRuntimeConfig:
            return "UpdateRuntimeConfig is implemented by the protobuf-backed CRI server"
        case .runPodSandbox:
            return "RunPodSandbox is not wired to sandbox lifecycle yet"
        case .stopPodSandbox:
            return "StopPodSandbox is not wired to sandbox lifecycle yet"
        case .removePodSandbox:
            return "RemovePodSandbox is not wired to sandbox lifecycle yet"
        case .podSandboxStatus:
            return "PodSandboxStatus is not wired to sandbox inspection yet"
        case .listPodSandbox:
            return "ListPodSandbox is not wired to sandbox inventory yet"
        case .createContainer:
            return "CreateContainer is not wired to workload creation yet"
        case .startContainer:
            return "StartContainer is not wired to workload start yet"
        case .stopContainer:
            return "StopContainer is not wired to workload stop yet"
        case .removeContainer:
            return "RemoveContainer is not wired to workload removal yet"
        case .containerStatus:
            return "ContainerStatus is not wired to workload inspection yet"
        case .listContainers:
            return "ListContainers is not wired to workload inventory yet"
        case .updateContainerResources:
            return "UpdateContainerResources is not wired to resource handling yet"
        case .updatePodSandboxResources:
            return "UpdatePodSandboxResources is not wired to resource handling yet"
        case .reopenContainerLog:
            return "ReopenContainerLog is not wired to log rotation yet"
        case .execSync:
            return "ExecSync is not wired to workload exec yet"
        case .exec:
            return "Exec is not wired to the streaming server yet"
        case .attach:
            return "Attach is not supported for macOS guest workloads"
        case .portForward:
            return "PortForward is not wired to the streaming server yet"
        case .containerStats:
            return "ContainerStats is not wired to workload stats yet"
        case .listContainerStats:
            return "ListContainerStats is not wired to workload stats yet"
        case .podSandboxStats:
            return "PodSandboxStats is not wired to sandbox stats yet"
        case .listPodSandboxStats:
            return "ListPodSandboxStats is not wired to sandbox stats yet"
        case .checkpointContainer:
            return "CheckpointContainer is not supported for macOS guest workloads"
        case .getContainerEvents:
            return "GetContainerEvents is not wired to workload event streaming yet"
        case .listMetricDescriptors:
            return "ListMetricDescriptors is not wired to runtime metrics yet"
        case .listPodSandboxMetrics:
            return "ListPodSandboxMetrics is not wired to sandbox metrics yet"
        }
    }
}

public enum CRIImageOperation: String, CaseIterable, Sendable {
    case listImages = "ListImages"
    case imageStatus = "ImageStatus"
    case pullImage = "PullImage"
    case removeImage = "RemoveImage"
    case imageFsInfo = "ImageFsInfo"
}

public enum CRIImageOperationSurface {
    public static let all: [CRIImageOperation] = CRIImageOperation.allCases

    public static func unsupportedReason(for operation: CRIImageOperation) -> String {
        switch operation {
        case .listImages:
            return "ListImages is implemented by the protobuf-backed CRI server"
        case .imageStatus:
            return "ImageStatus is implemented by the protobuf-backed CRI server"
        case .pullImage:
            return "PullImage is not wired to container image pull support yet"
        case .removeImage:
            return "RemoveImage is implemented by the protobuf-backed CRI server"
        case .imageFsInfo:
            return "ImageFsInfo is implemented by the protobuf-backed CRI server"
        }
    }
}
