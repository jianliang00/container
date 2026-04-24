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
import ContainerKit
import ContainerResource
import Foundation

func makeCRIPodSandbox(_ metadata: CRIShimSandboxMetadata) -> Runtime_V1_PodSandbox {
    var sandbox = Runtime_V1_PodSandbox()
    sandbox.id = metadata.id
    sandbox.metadata = makeCRIPodSandboxMetadata(metadata)
    sandbox.state = makeCRIPodSandboxState(metadata.state)
    sandbox.createdAt = makeCRITimestamp(metadata.createdAt)
    sandbox.labels = metadata.labels
    sandbox.annotations = metadata.annotations
    sandbox.runtimeHandler = metadata.runtimeHandler
    return sandbox
}

func makeCRIPodSandbox(
    _ metadata: CRIShimSandboxMetadata,
    sandboxSnapshot: SandboxSnapshot?
) -> Runtime_V1_PodSandbox {
    makeCRIPodSandbox(metadata.applying(sandboxSnapshot: sandboxSnapshot))
}

func makeCRIPodSandboxStatus(_ metadata: CRIShimSandboxMetadata) -> Runtime_V1_PodSandboxStatus {
    var status = Runtime_V1_PodSandboxStatus()
    status.id = metadata.id
    status.metadata = makeCRIPodSandboxMetadata(metadata)
    status.state = makeCRIPodSandboxState(metadata.state)
    status.createdAt = makeCRITimestamp(metadata.createdAt)
    status.labels = metadata.labels
    status.annotations = metadata.annotations
    status.runtimeHandler = metadata.runtimeHandler
    return status
}

func makeCRIPodSandboxStatus(
    _ metadata: CRIShimSandboxMetadata,
    sandboxSnapshot: SandboxSnapshot?
) -> Runtime_V1_PodSandboxStatus {
    var status = makeCRIPodSandboxStatus(metadata.applying(sandboxSnapshot: sandboxSnapshot))
    if let network = makeCRIPodSandboxNetworkStatus(sandboxSnapshot) {
        status.network = network
    }
    return status
}

func makeCRIContainer(_ metadata: CRIShimContainerMetadata) -> Runtime_V1_Container {
    var container = Runtime_V1_Container()
    container.id = metadata.id
    container.podSandboxID = metadata.sandboxID
    container.metadata = makeCRIContainerMetadata(metadata)
    container.image = makeCRIImageSpec(metadata.image)
    container.imageRef = metadata.image
    container.imageID = metadata.image
    container.state = makeCRIContainerState(metadata.state)
    container.createdAt = makeCRITimestamp(metadata.createdAt)
    container.labels = metadata.labels
    container.annotations = metadata.annotations
    return container
}

func makeCRIContainer(
    _ metadata: CRIShimContainerMetadata,
    workloadSnapshot: WorkloadSnapshot?
) -> Runtime_V1_Container {
    makeCRIContainer(metadata.applying(workloadSnapshot: workloadSnapshot))
}

func makeCRIContainerStatus(_ metadata: CRIShimContainerMetadata) -> Runtime_V1_ContainerStatus {
    var status = Runtime_V1_ContainerStatus()
    status.id = metadata.id
    status.metadata = makeCRIContainerMetadata(metadata)
    status.state = makeCRIContainerState(metadata.state)
    status.createdAt = makeCRITimestamp(metadata.createdAt)
    status.startedAt = makeCRITimestamp(metadata.startedAt)
    status.finishedAt = makeCRITimestamp(metadata.exitedAt)
    status.image = makeCRIImageSpec(metadata.image)
    status.imageRef = metadata.image
    status.imageID = metadata.image
    status.labels = metadata.labels
    status.annotations = metadata.annotations
    status.logPath = metadata.logPath ?? ""
    return status
}

func makeCRIContainerStatus(
    _ metadata: CRIShimContainerMetadata,
    workloadSnapshot: WorkloadSnapshot?
) -> Runtime_V1_ContainerStatus {
    var status = makeCRIContainerStatus(metadata.applying(workloadSnapshot: workloadSnapshot))
    if let exitCode = workloadSnapshot?.exitCode {
        status.exitCode = exitCode
    }
    return status
}

func makeCRIContainerStats(_ metadata: CRIShimContainerMetadata) -> Runtime_V1_ContainerStats {
    var stats = Runtime_V1_ContainerStats()
    var attributes = Runtime_V1_ContainerAttributes()
    attributes.id = metadata.id
    attributes.metadata = makeCRIContainerMetadata(metadata)
    attributes.labels = metadata.labels
    attributes.annotations = metadata.annotations
    stats.attributes = attributes
    return stats
}

func makeCRIPodSandboxStats(_ metadata: CRIShimSandboxMetadata) -> Runtime_V1_PodSandboxStats {
    var stats = Runtime_V1_PodSandboxStats()
    var attributes = Runtime_V1_PodSandboxAttributes()
    attributes.id = metadata.id
    attributes.metadata = makeCRIPodSandboxMetadata(metadata)
    attributes.labels = metadata.labels
    attributes.annotations = metadata.annotations
    stats.attributes = attributes
    return stats
}

func filterCRIPodSandboxes(
    _ sandboxes: [CRIShimSandboxMetadata],
    request: Runtime_V1_ListPodSandboxRequest
) -> [CRIShimSandboxMetadata] {
    guard request.hasFilter else {
        return sandboxes.sorted(by: sandboxSort)
    }

    let filter = request.filter
    return
        sandboxes
        .filter { sandbox in
            if !filter.id.isEmpty, sandbox.id != filter.id {
                return false
            }
            if filter.hasState, makeCRIPodSandboxState(sandbox.state) != filter.state.state {
                return false
            }
            return labelsMatch(filter.labelSelector, labels: sandbox.labels)
        }
        .sorted(by: sandboxSort)
}

func filterCRIContainers(
    _ containers: [CRIShimContainerMetadata],
    request: Runtime_V1_ListContainersRequest
) -> [CRIShimContainerMetadata] {
    guard request.hasFilter else {
        return containers.sorted(by: containerSort)
    }

    let filter = request.filter
    return
        containers
        .filter { container in
            if !filter.id.isEmpty, container.id != filter.id {
                return false
            }
            if !filter.podSandboxID.isEmpty, container.sandboxID != filter.podSandboxID {
                return false
            }
            if filter.hasState, makeCRIContainerState(container.state) != filter.state.state {
                return false
            }
            return labelsMatch(filter.labelSelector, labels: container.labels)
        }
        .sorted(by: containerSort)
}

func filterCRIContainers(
    _ containers: [CRIShimContainerMetadata],
    request: Runtime_V1_ListContainerStatsRequest
) -> [CRIShimContainerMetadata] {
    guard request.hasFilter else {
        return containers.sorted(by: containerSort)
    }

    let filter = request.filter
    return
        containers
        .filter { container in
            if !filter.id.isEmpty, container.id != filter.id {
                return false
            }
            if !filter.podSandboxID.isEmpty, container.sandboxID != filter.podSandboxID {
                return false
            }
            return labelsMatch(filter.labelSelector, labels: container.labels)
        }
        .sorted(by: containerSort)
}

func filterCRIPodSandboxes(
    _ sandboxes: [CRIShimSandboxMetadata],
    request: Runtime_V1_ListPodSandboxStatsRequest
) -> [CRIShimSandboxMetadata] {
    guard request.hasFilter else {
        return sandboxes.sorted(by: sandboxSort)
    }

    let filter = request.filter
    return
        sandboxes
        .filter { sandbox in
            if !filter.id.isEmpty, sandbox.id != filter.id {
                return false
            }
            return labelsMatch(filter.labelSelector, labels: sandbox.labels)
        }
        .sorted(by: sandboxSort)
}

func makeCRIStatusInfo<T: Encodable>(_ value: T) -> [String: String] {
    ["metadata": makeCRIStatusJSONString(value)]
}

func makeCRIPodSandboxStatusInfo(
    _ metadata: CRIShimSandboxMetadata,
    sandboxSnapshot: SandboxSnapshot?
) -> [String: String] {
    var info = makeCRIStatusInfo(metadata)
    if let sandboxSnapshot {
        info["sandboxSnapshot"] = makeCRIStatusJSONString(sandboxSnapshot)
    }
    return info
}

private func makeCRIPodSandboxMetadata(_ metadata: CRIShimSandboxMetadata) -> Runtime_V1_PodSandboxMetadata {
    var result = Runtime_V1_PodSandboxMetadata()
    result.name = metadata.name ?? ""
    result.uid = metadata.podUID ?? ""
    result.namespace = metadata.namespace ?? ""
    result.attempt = metadata.attempt
    return result
}

private func makeCRIContainerMetadata(_ metadata: CRIShimContainerMetadata) -> Runtime_V1_ContainerMetadata {
    var result = Runtime_V1_ContainerMetadata()
    result.name = metadata.name
    result.attempt = metadata.attempt
    return result
}

private func makeCRIImageSpec(_ reference: String) -> Runtime_V1_ImageSpec {
    var image = Runtime_V1_ImageSpec()
    image.image = reference
    return image
}

private func makeCRIPodSandboxNetworkStatus(_ sandboxSnapshot: SandboxSnapshot?) -> Runtime_V1_PodSandboxNetworkStatus? {
    guard let sandboxSnapshot else {
        return nil
    }
    let ips = sandboxSnapshot.networks.map(\.ipv4Address.address.description)
    return makeCRIPodSandboxNetworkStatus(ips: ips)
}

private func makeCRIPodSandboxNetworkStatus(ips rawIPs: [String]) -> Runtime_V1_PodSandboxNetworkStatus? {
    let ips = rawIPs.map(\.trimmed).filter { !$0.isEmpty }
    guard let primaryIP = ips.first else {
        return nil
    }

    var network = Runtime_V1_PodSandboxNetworkStatus()
    network.ip = primaryIP
    network.additionalIps = ips.dropFirst().map { ip in
        var podIP = Runtime_V1_PodIP()
        podIP.ip = ip
        return podIP
    }
    return network
}

private func makeCRIPodSandboxState(_ state: CRIShimSandboxMetadata.State) -> Runtime_V1_PodSandboxState {
    switch state {
    case .ready, .running:
        .sandboxReady
    case .pending, .stopped, .released:
        .sandboxNotready
    }
}

private func makeCRIContainerState(_ state: CRIShimContainerMetadata.State) -> Runtime_V1_ContainerState {
    switch state {
    case .created:
        .containerCreated
    case .running:
        .containerRunning
    case .exited, .removed:
        .containerExited
    }
}

extension CRIShimSandboxMetadata {
    func applying(sandboxSnapshot: SandboxSnapshot?) -> CRIShimSandboxMetadata {
        guard let sandboxSnapshot else {
            return self
        }

        var metadata = self
        switch sandboxSnapshot.status {
        case .running:
            metadata.state = .running
        case .stopping:
            metadata.state = .stopped
        case .stopped:
            if metadata.state != .ready {
                metadata.state = .stopped
            }
        case .unknown:
            break
        }

        let networks = sandboxSnapshot.networks.map(\.network).filter { !$0.trimmed.isEmpty }
        if !networks.isEmpty {
            metadata.networkAttachments = networks
        }
        return metadata
    }
}

extension CRIShimContainerMetadata {
    func applying(workloadSnapshot: WorkloadSnapshot?) -> CRIShimContainerMetadata {
        guard let workloadSnapshot else {
            return self
        }

        var metadata = self
        switch workloadSnapshot.status {
        case .running, .stopping:
            metadata.state = .running
        case .stopped:
            metadata.state = .exited
        case .unknown:
            break
        }

        metadata.startedAt = workloadSnapshot.startedDate ?? metadata.startedAt
        metadata.exitedAt = workloadSnapshot.exitedAt ?? metadata.exitedAt
        return metadata
    }
}

private func makeCRITimestamp(_ date: Date?) -> Int64 {
    guard let date else {
        return 0
    }
    return Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
}

private func labelsMatch(_ selector: [String: String], labels: [String: String]) -> Bool {
    selector.allSatisfy { key, value in labels[key] == value }
}

private func sandboxSort(_ lhs: CRIShimSandboxMetadata, _ rhs: CRIShimSandboxMetadata) -> Bool {
    if lhs.createdAt == rhs.createdAt {
        return lhs.id < rhs.id
    }
    return lhs.createdAt < rhs.createdAt
}

private func containerSort(_ lhs: CRIShimContainerMetadata, _ rhs: CRIShimContainerMetadata) -> Bool {
    if lhs.createdAt == rhs.createdAt {
        return lhs.id < rhs.id
    }
    return lhs.createdAt < rhs.createdAt
}

private func makeCRIStatusJSONString<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder.criShimMetadataEncoder
    encoder.outputFormatting.insert(.sortedKeys)
    guard let data = try? encoder.encode(value) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}
