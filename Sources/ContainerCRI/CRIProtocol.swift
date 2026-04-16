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

public struct CRIRuntimeOperationDisposition: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case supported
        case unsupported
    }

    public var kind: Kind
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public static func supported(_ detail: String) -> CRIRuntimeOperationDisposition {
        CRIRuntimeOperationDisposition(kind: .supported, detail: detail)
    }

    public static func unsupported(_ detail: String) -> CRIRuntimeOperationDisposition {
        CRIRuntimeOperationDisposition(kind: .unsupported, detail: detail)
    }
}

public enum CRIRuntimeOperationSurface {
    public static let all: [CRIRuntimeOperation] = CRIRuntimeOperation.allCases

    public static func unsupportedReason(for operation: CRIRuntimeOperation) -> String {
        switch operation {
        case .version:
            return "Version is reserved for the protobuf-backed CRI server"
        case .status:
            return "Status is reserved for the protobuf-backed CRI server"
        case .runtimeConfig:
            return "RuntimeConfig is not wired without generated CRI protobuf bindings"
        case .updateRuntimeConfig:
            return "UpdateRuntimeConfig is not wired without generated CRI protobuf bindings"
        case .runPodSandbox:
            return "RunPodSandbox is not wired without generated CRI protobuf bindings"
        case .stopPodSandbox:
            return "StopPodSandbox is not wired without generated CRI protobuf bindings"
        case .removePodSandbox:
            return "RemovePodSandbox is not wired without generated CRI protobuf bindings"
        case .podSandboxStatus:
            return "PodSandboxStatus is not wired without generated CRI protobuf bindings"
        case .listPodSandbox:
            return "ListPodSandbox is not wired without generated CRI protobuf bindings"
        case .createContainer:
            return "CreateContainer is not wired without generated CRI protobuf bindings"
        case .startContainer:
            return "StartContainer is not wired without generated CRI protobuf bindings"
        case .stopContainer:
            return "StopContainer is not wired without generated CRI protobuf bindings"
        case .removeContainer:
            return "RemoveContainer is not wired without generated CRI protobuf bindings"
        case .containerStatus:
            return "ContainerStatus is not wired without generated CRI protobuf bindings"
        case .listContainers:
            return "ListContainers is not wired without generated CRI protobuf bindings"
        case .updateContainerResources:
            return "UpdateContainerResources is not wired without generated CRI protobuf bindings"
        case .updatePodSandboxResources:
            return "UpdatePodSandboxResources is not wired without generated CRI protobuf bindings"
        case .reopenContainerLog:
            return "ReopenContainerLog is not wired without generated CRI protobuf bindings"
        case .execSync:
            return "ExecSync is not wired without generated CRI protobuf bindings"
        case .exec:
            return "Exec is not wired without generated CRI protobuf bindings"
        case .attach:
            return "Attach is not wired without generated CRI protobuf bindings"
        case .portForward:
            return "PortForward is not wired without generated CRI protobuf bindings"
        case .containerStats:
            return "ContainerStats is not wired without generated CRI protobuf bindings"
        case .listContainerStats:
            return "ListContainerStats is not wired without generated CRI protobuf bindings"
        case .podSandboxStats:
            return "PodSandboxStats is not wired without generated CRI protobuf bindings"
        case .listPodSandboxStats:
            return "ListPodSandboxStats is not wired without generated CRI protobuf bindings"
        case .checkpointContainer:
            return "CheckpointContainer is not wired without generated CRI protobuf bindings"
        case .getContainerEvents:
            return "GetContainerEvents is not wired without generated CRI protobuf bindings"
        case .listMetricDescriptors:
            return "ListMetricDescriptors is not wired without generated CRI protobuf bindings"
        case .listPodSandboxMetrics:
            return "ListPodSandboxMetrics is not wired without generated CRI protobuf bindings"
        }
    }
}

public protocol CRIRuntimeService: Sendable {
    func disposition(for operation: CRIRuntimeOperation) -> CRIRuntimeOperationDisposition
}

public struct DeterministicUnsupportedCRIRuntimeService: CRIRuntimeService {
    public init() {}

    public func disposition(for operation: CRIRuntimeOperation) -> CRIRuntimeOperationDisposition {
        CRIRuntimeOperationDisposition.unsupported(CRIRuntimeOperationSurface.unsupportedReason(for: operation))
    }
}
