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
import RuntimeMacOSSidecarShared

public enum CRIShimRestoreInfoKey {
    public static let capabilities = "kross.macos.restore.capabilities.v3"
    public static let receipt = "kross.macos.restore.receipt.v3"
}

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
    sandboxSnapshot: SandboxSnapshot?,
    dualStackEnabled: Bool = false
) -> Runtime_V1_PodSandboxStatus {
    var status = makeCRIPodSandboxStatus(metadata.applying(sandboxSnapshot: sandboxSnapshot))
    if let network = makeCRIPodSandboxNetworkStatus(
        sandboxSnapshot,
        dualStackEnabled: dualStackEnabled
    ) {
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
    let metadata = metadata.normalizedTerminalStatus()
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
    status.exitCode = metadata.exitCode ?? 0
    status.reason = metadata.reason ?? ""
    status.message = metadata.message ?? ""
    return status
}

func makeCRIContainerStatus(
    _ metadata: CRIShimContainerMetadata,
    workloadSnapshot: WorkloadSnapshot?
) -> Runtime_V1_ContainerStatus {
    makeCRIContainerStatus(metadata.applying(workloadSnapshot: workloadSnapshot))
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
    sandboxSnapshot: SandboxSnapshot?,
    containers: [CRIShimContainerMetadata] = [],
    machineStateConfig: MachineStateConfig? = nil
) -> [String: String] {
    var info = makeCRIStatusInfo(metadata)
    if metadata.annotations[CRIShimMachineStateAnnotation.enabled] == "true",
        let persistenceID = metadata.annotations[CRIShimMachineStateAnnotation.persistenceID]
    {
        info["machineState"] = makeCRIStatusJSONString(
            CRIShimMachineStateStatusInfo(
                persistenceID: persistenceID,
                storageGeneration: metadata.annotations[CRIShimMachineStateAnnotation.storageGeneration]
                    .flatMap(UInt64.init),
                restoreStateID: metadata.annotations[CRIShimMachineStateAnnotation.restoreStateID],
                restoreStateGeneration: metadata.annotations[CRIShimMachineStateAnnotation.restoreStateGeneration]
                    .flatMap(UInt64.init)
            )
        )
    }
    if let sandboxSnapshot {
        info["sandboxSnapshot"] = makeCRIStatusJSONString(sandboxSnapshot)
    }
    if let receipt = makeCRIShimRestoreReceipt(
        metadata,
        containers: containers,
        sandboxSnapshot: sandboxSnapshot,
        machineStateConfig: machineStateConfig
    ) {
        info[CRIShimRestoreInfoKey.receipt] = makeCRIStatusJSONString(receipt)
    }
    return info
}

struct CRIShimRestoreCapabilities: Encodable, Equatable, Sendable {
    let schemaVersion = 1
    let protocolVersion = 3
    let durablePair = true
    let stableRuntimeIDs = true
    let workloadAdoption = true
    let eventReplay = true
}

struct CRIShimRestoreReceiptInfo: Encodable, Equatable, Sendable {
    struct RootStorage: Encodable, Equatable, Sendable {
        let writable: Bool
        let sourceGeneration: UInt64
        let storageGeneration: UInt64
    }

    struct Network: Encodable, Equatable, Sendable {
        let reservationID: String?
        let attachments: [String]
        let ready: Bool
    }

    let schemaVersion = 1
    let protocolVersion = 3
    let status: String
    let restoreRequestID: String
    let stateID: String
    let pairID: String
    let adoptionManifestDigest: String
    let sourcePodUID: String?
    let targetPodUID: String?
    let criSandboxID: String
    let runtimeSandboxID: String
    let expectedWorkloadCount: Int
    let adoptedWorkloadCount: Int
    let rootStorage: RootStorage
    let network: Network
    let workloads: [WorkloadAdoptionReceipt]
    let failureCode: String?
    let failureMessage: String?
}

private func makeCRIShimRestoreReceipt(
    _ metadata: CRIShimSandboxMetadata,
    containers: [CRIShimContainerMetadata],
    sandboxSnapshot: SandboxSnapshot?,
    machineStateConfig: MachineStateConfig?
) -> CRIShimRestoreReceiptInfo? {
    guard metadata.annotations[CRIShimMachineStateAnnotation.enabled] == "true",
        let stateID = metadata.annotations[CRIShimMachineStateAnnotation.restoreStateID],
        let sourceGeneration = metadata.annotations[CRIShimMachineStateAnnotation.restoreStateGeneration]
            .flatMap(UInt64.init),
        let storageGeneration = metadata.annotations[CRIShimMachineStateAnnotation.storageGeneration]
            .flatMap(UInt64.init),
        let pairID = metadata.annotations[CRIShimMachineStateAnnotation.restorePairID],
        let manifestDigest = metadata.annotations[CRIShimMachineStateAnnotation.restoreManifestDigest],
        let restoreRequestID = metadata.annotations[CRIShimMachineStateAnnotation.restoreRequestID]
    else {
        return nil
    }

    let persistedReceipt = machineStateConfig.flatMap {
        loadMachineStateReceipt(
            config: $0,
            persistenceID: metadata.annotations[CRIShimMachineStateAnnotation.persistenceID] ?? "",
            stateID: stateID
        )
    }
    let receiptMatches =
        persistedReceipt?.committed == true
        && persistedReceipt?.pair.pairID == pairID
        && persistedReceipt?.pair.adoptionManifestDigest == manifestDigest
        && persistedReceipt?.pair.stateID == stateID
        && persistedReceipt?.pair.stateGeneration == sourceGeneration
        && persistedReceipt?.pair.persistenceID
            == metadata.annotations[CRIShimMachineStateAnnotation.persistenceID]

    let expected = persistedReceipt?.adoption.workloads ?? []
    let receipts = containers.compactMap(\.adoptionReceipt)
        .sorted { $0.runtimeWorkloadID < $1.runtimeWorkloadID }
    let receiptsByRuntimeID = Dictionary(
        receipts.map { ($0.runtimeWorkloadID, $0) },
        uniquingKeysWith: { _, new in new }
    )
    let adoptedCount = expected.reduce(into: 0) { count, workload in
        guard let receipt = receiptsByRuntimeID[workload.runtimeWorkloadID],
            receipt.executionID == workload.guestProcessID,
            receipt.trustedLaunchFingerprint == workload.trustedLaunchFingerprint,
            receipt.guestLaunchFingerprint == workload.guestLaunchFingerprint,
            receipt.processIncarnation == workload.processIncarnation,
            receipt.sourceStorageGeneration == sourceGeneration,
            receipt.storageGeneration == storageGeneration,
            receipt.processIdentifier == workload.processIdentifier,
            receipt.eventSequence >= workload.lastPersistedEventSequence,
            receipt.oldestAvailableEventSequence <= workload.lastPersistedEventSequence + 1,
            !receipt.replayTruncated,
            receipt.state == "running"
        else {
            return
        }
        count += 1
    }
    let networkReady =
        metadata.network == nil
        || (metadata.networkLeaseID != nil && !(sandboxSnapshot?.networks.isEmpty ?? true))
    let rootStorageReady =
        receiptMatches
        && storageGeneration > sourceGeneration
        && sandboxSnapshot?.status == .running
    let adopted =
        receiptMatches
        && rootStorageReady
        && networkReady
        && !expected.isEmpty
        && containers.count == expected.count
        && receipts.count == expected.count
        && adoptedCount == expected.count
    let failureCode = receiptMatches ? nil : "DURABLE_PAIR_RECEIPT_MISMATCH"
    let failureMessage = receiptMatches ? nil : "persisted machine-state receipt does not match the restore contract"
    return CRIShimRestoreReceiptInfo(
        status: adopted ? "adopted" : (failureCode == nil ? "restoring" : "failed"),
        restoreRequestID: restoreRequestID,
        stateID: stateID,
        pairID: pairID,
        adoptionManifestDigest: manifestDigest,
        sourcePodUID: persistedReceipt?.adoption.sourcePodUID,
        targetPodUID: metadata.podUID,
        criSandboxID: metadata.id,
        runtimeSandboxID: metadata.runtimeSandboxID,
        expectedWorkloadCount: expected.count,
        adoptedWorkloadCount: adoptedCount,
        rootStorage: .init(
            writable: rootStorageReady,
            sourceGeneration: sourceGeneration,
            storageGeneration: storageGeneration
        ),
        network: .init(
            reservationID: metadata.networkLeaseID,
            attachments: metadata.networkAttachments.sorted(),
            ready: networkReady
        ),
        workloads: receipts,
        failureCode: failureCode,
        failureMessage: failureMessage
    )
}

private func loadMachineStateReceipt(
    config: MachineStateConfig,
    persistenceID: String,
    stateID: String
) -> MacOSMachineStateReceipt? {
    guard !persistenceID.isEmpty, !stateID.isEmpty else {
        return nil
    }
    let url = URL(fileURLWithPath: config.normalizedStorageRoot, isDirectory: true)
        .appendingPathComponent(persistenceID, isDirectory: true)
        .appendingPathComponent("MachineStates", isDirectory: true)
        .appendingPathComponent(stateID, isDirectory: true)
        .appendingPathComponent("manifest.json", isDirectory: false)
    guard let data = try? Data(contentsOf: url, options: .uncached),
        data.count <= 1024 * 1024
    else {
        return nil
    }
    return try? JSONDecoder().decode(MacOSMachineStateReceipt.self, from: data)
}

private struct CRIShimMachineStateStatusInfo: Encodable {
    struct Restore: Encodable {
        let supported = true
        let status: String
        let stateID: String?
        let stateGeneration: UInt64?
    }

    let schemaVersion = 1
    let protocolVersion = 2
    let persistenceID: String
    let storageGeneration: UInt64?
    let restore: Restore

    init(
        persistenceID: String,
        storageGeneration: UInt64?,
        restoreStateID: String?,
        restoreStateGeneration: UInt64?
    ) {
        self.persistenceID = persistenceID
        self.storageGeneration = storageGeneration
        self.restore = Restore(
            status: restoreStateID == nil ? "notRequested" : "requested",
            stateID: restoreStateID,
            stateGeneration: restoreStateGeneration
        )
    }
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

private func makeCRIPodSandboxNetworkStatus(
    _ sandboxSnapshot: SandboxSnapshot?,
    dualStackEnabled: Bool
) -> Runtime_V1_PodSandboxNetworkStatus? {
    guard let attachments = sandboxSnapshot?.networks, let primaryAttachment = attachments.first else {
        return nil
    }
    guard dualStackEnabled else {
        return makeCRIPodSandboxNetworkStatus(
            ips: attachments.map(\.ipv4Address.address.description)
        )
    }

    var primaryIPs = [primaryAttachment.ipv4Address.address.description]
    if primaryAttachment.ipv6Gateway != nil,
        let ipv6Address = primaryAttachment.ipv6Address?.address.description
    {
        primaryIPs.append(ipv6Address)
    }
    return makeCRIPodSandboxNetworkStatus(ips: primaryIPs)
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
        if sandboxSnapshot.failureReason == .networkInvalidated {
            if metadata.state.lifecycleRank < State.stopped.lifecycleRank {
                metadata.state = .stopped
            }
            return metadata.applyingNetworkAttachments(from: sandboxSnapshot)
        }
        let observedState: State?
        switch sandboxSnapshot.status {
        case .running:
            observedState = .running
        case .stopping:
            observedState = .stopped
        case .stopped:
            let preservesIncompleteMachineStateAdmission =
                metadata.state == .pending
                && metadata.annotations[CRIShimMachineStateAnnotation.enabled] == "true"
            observedState = metadata.state == .ready || preservesIncompleteMachineStateAdmission ? nil : .stopped
        case .unknown:
            observedState = nil
        }
        if let observedState,
            observedState.lifecycleRank >= metadata.state.lifecycleRank
        {
            metadata.state = observedState
        }

        return metadata.applyingNetworkAttachments(from: sandboxSnapshot)
    }

    private func applyingNetworkAttachments(from sandboxSnapshot: SandboxSnapshot) -> CRIShimSandboxMetadata {
        var metadata = self
        let networks = sandboxSnapshot.networks.map(\.network).filter { !$0.trimmed.isEmpty }
        if !networks.isEmpty {
            metadata.networkAttachments = networks
        }
        return metadata
    }
}

extension CRIShimContainerMetadata {
    func applying(
        workloadSnapshot: WorkloadSnapshot?,
        observedAt: Date = Date()
    ) -> CRIShimContainerMetadata {
        guard let workloadSnapshot else {
            return self
        }

        var metadata = self
        switch workloadSnapshot.status {
        case .running, .stopping:
            if metadata.state != .exited, metadata.state != .removed {
                metadata.state = .running
            }
        case .stopped:
            if let exitCode = workloadSnapshot.exitCode {
                if exitCode != 0 || (workloadSnapshot.exitedAt?.timeIntervalSince1970 ?? 0) > 0 {
                    metadata.recordRuntimeExit(
                        code: exitCode,
                        at: workloadSnapshot.exitedAt,
                        observedAt: observedAt
                    )
                } else {
                    metadata.recordUnknownExit(at: observedAt)
                }
            } else {
                metadata.recordUnknownExit(at: workloadSnapshot.exitedAt ?? observedAt)
            }
        case .unknown:
            break
        }

        metadata.startedAt = workloadSnapshot.startedDate ?? metadata.startedAt
        metadata.adoptionReceipt = workloadSnapshot.adoptionReceipt ?? metadata.adoptionReceipt
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

func makeCRIStatusJSONString<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder.criShimMetadataEncoder
    encoder.outputFormatting.insert(.sortedKeys)
    guard let data = try? encoder.encode(value) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}
