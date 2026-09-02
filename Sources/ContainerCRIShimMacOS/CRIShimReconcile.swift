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

import ContainerKit
import ContainerResource
import Foundation

public struct CRIShimRuntimeInventory: Codable, Equatable, Sendable {
    public var sandboxes: [CRIShimRuntimeSandboxInventory]
    public var containers: [CRIShimRuntimeContainerInventory]

    public init(
        sandboxes: [CRIShimRuntimeSandboxInventory] = [],
        containers: [CRIShimRuntimeContainerInventory] = []
    ) {
        self.sandboxes = sandboxes
        self.containers = containers
    }
}

public enum CRIShimRuntimeObjectState: String, Codable, Sendable, Equatable {
    case live
    case released
}

public struct CRIShimRuntimeSandboxInventory: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var state: CRIShimRuntimeObjectState
    public var fingerprint: String

    public init(id: String, state: CRIShimRuntimeObjectState, fingerprint: String) {
        self.id = id
        self.state = state
        self.fingerprint = fingerprint
    }
}

public struct CRIShimRuntimeContainerInventory: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var state: CRIShimRuntimeObjectState
    public var fingerprint: String

    public init(id: String, state: CRIShimRuntimeObjectState, fingerprint: String) {
        self.id = id
        self.state = state
        self.fingerprint = fingerprint
    }
}

public struct CRIShimReconcilePlan: Codable, Equatable, Sendable {
    public var sandboxSteps: [CRIShimReconcileStep]
    public var containerSteps: [CRIShimReconcileStep]

    public init(
        sandboxSteps: [CRIShimReconcileStep] = [],
        containerSteps: [CRIShimReconcileStep] = []
    ) {
        self.sandboxSteps = sandboxSteps
        self.containerSteps = containerSteps
    }

    public var isEmpty: Bool {
        sandboxSteps.isEmpty && containerSteps.isEmpty
    }
}

public struct CRIShimReconcileStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case sandbox
        case container
    }

    public enum Action: String, Codable, Sendable, Equatable {
        case create
        case update
        case delete
        case release
    }

    public var kind: Kind
    public var action: Action
    public var id: String
    public var reason: String
    public var storeFingerprint: String?
    public var runtimeFingerprint: String?

    public init(
        kind: Kind,
        action: Action,
        id: String,
        reason: String,
        storeFingerprint: String? = nil,
        runtimeFingerprint: String? = nil
    ) {
        self.kind = kind
        self.action = action
        self.id = id
        self.reason = reason
        self.storeFingerprint = storeFingerprint
        self.runtimeFingerprint = runtimeFingerprint
    }
}

public struct CRIShimReconciler {
    public init() {}

    public func makePlan(
        store: CRIShimMetadataSnapshot,
        inventory: CRIShimRuntimeInventory
    ) -> CRIShimReconcilePlan {
        let sandboxSteps = reconcile(
            kind: .sandbox,
            stored: store.sandboxes.map {
                (id: $0.id, fingerprint: $0.reconcileFingerprint, canDelete: $0.state == .released)
            },
            runtime: inventory.sandboxes.map { ($0.id, $0.state, $0.fingerprint) }
        )
        let containerSteps = reconcile(
            kind: .container,
            stored: store.containers.map {
                (id: $0.id, fingerprint: $0.reconcileFingerprint, canDelete: $0.state == .removed)
            },
            runtime: inventory.containers.map { ($0.id, $0.state, $0.fingerprint) }
        )
        return CRIShimReconcilePlan(sandboxSteps: sandboxSteps, containerSteps: containerSteps)
    }

    private func reconcile(
        kind: CRIShimReconcileStep.Kind,
        stored: [(id: String, fingerprint: String, canDelete: Bool)],
        runtime: [(String, CRIShimRuntimeObjectState, String)]
    ) -> [CRIShimReconcileStep] {
        let storedByID = Dictionary(
            stored.map { ($0.id, (fingerprint: $0.fingerprint, canDelete: $0.canDelete)) },
            uniquingKeysWith: { _, new in new }
        )
        let runtimeByID = Dictionary(runtime.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { _, new in new })
        let ids = Set(storedByID.keys).union(runtimeByID.keys).sorted()
        var steps: [CRIShimReconcileStep] = []

        for id in ids {
            let storedEntry = storedByID[id]
            let runtimeEntry = runtimeByID[id]
            switch (storedEntry, runtimeEntry) {
            case (nil, nil):
                continue
            case (nil, let runtimeEntry?):
                steps.append(
                    CRIShimReconcileStep(
                        kind: kind,
                        action: runtimeEntry.0 == .released ? .release : .create,
                        id: id,
                        reason: runtimeEntry.0 == .released ? "runtime reported released \(kind.rawValue)" : "runtime entry missing from store",
                        runtimeFingerprint: runtimeEntry.1
                    )
                )
            case (let storedEntry?, nil) where storedEntry.canDelete:
                steps.append(
                    CRIShimReconcileStep(
                        kind: kind,
                        action: .delete,
                        id: id,
                        reason: "terminal stored \(kind.rawValue) missing from runtime inventory",
                        storeFingerprint: storedEntry.fingerprint
                    )
                )
            case (_?, nil):
                continue
            case (let storedEntry?, let runtimeEntry?):
                if runtimeEntry.0 == .released {
                    steps.append(
                        CRIShimReconcileStep(
                            kind: kind,
                            action: .release,
                            id: id,
                            reason: "runtime reported released \(kind.rawValue)",
                            storeFingerprint: storedEntry.fingerprint,
                            runtimeFingerprint: runtimeEntry.1
                        )
                    )
                } else if storedEntry.fingerprint != runtimeEntry.1 {
                    steps.append(
                        CRIShimReconcileStep(
                            kind: kind,
                            action: .update,
                            id: id,
                            reason: "stored \(kind.rawValue) metadata differs from runtime inventory",
                            storeFingerprint: storedEntry.fingerprint,
                            runtimeFingerprint: runtimeEntry.1
                        )
                    )
                }
            }
        }

        return steps
    }
}

public struct CRIShimRuntimeSnapshotInventory: Sendable {
    public var sandboxes: [SandboxSnapshot]

    public init(sandboxes: [SandboxSnapshot] = []) {
        self.sandboxes = sandboxes
    }

    public func makeInventory(
        store: CRIShimMetadataSnapshot,
        now: Date = Date()
    ) -> CRIShimRuntimeInventory {
        let storedSandboxes = Dictionary(uniqueKeysWithValues: store.sandboxes.map { ($0.id, $0) })
        let storedContainers = Dictionary(uniqueKeysWithValues: store.containers.map { ($0.id, $0) })
        var sandboxInventory: [CRIShimRuntimeSandboxInventory] = []
        var containerInventory: [CRIShimRuntimeContainerInventory] = []

        for sandboxSnapshot in sandboxes {
            guard let sandboxID = sandboxSnapshot.criShimSandboxID else {
                continue
            }
            let sandboxMetadata =
                storedSandboxes[sandboxID]?.applying(sandboxSnapshot: sandboxSnapshot)
                ?? makeCRIShimSandboxMetadata(sandboxSnapshot: sandboxSnapshot, now: now)
            guard let sandboxMetadata else {
                continue
            }
            sandboxInventory.append(
                CRIShimRuntimeSandboxInventory(
                    id: sandboxID,
                    state: .live,
                    fingerprint: sandboxMetadata.reconcileFingerprint
                )
            )

            for workloadSnapshot in sandboxSnapshot.workloads {
                let containerMetadata =
                    storedContainers[workloadSnapshot.id]?.applying(
                        workloadSnapshot: workloadSnapshot,
                        observedAt: now
                    )
                    ?? makeCRIShimContainerMetadata(
                        workloadSnapshot: workloadSnapshot,
                        sandboxID: sandboxID,
                        sandboxMetadata: sandboxMetadata,
                        now: now
                    )
                guard let containerMetadata = containerMetadata?.applyingReconciledLogPath() else {
                    continue
                }
                containerInventory.append(
                    CRIShimRuntimeContainerInventory(
                        id: workloadSnapshot.id,
                        state: .live,
                        fingerprint: containerMetadata.reconcileFingerprint
                    )
                )
            }
        }

        return CRIShimRuntimeInventory(
            sandboxes: sandboxInventory.sorted(by: { $0.id < $1.id }),
            containers: containerInventory.sorted(by: { $0.id < $1.id })
        )
    }
}

public struct CRIShimReconcileExecutionResult: Sendable {
    public var plan: CRIShimReconcilePlan
    public var appliedSteps: [CRIShimReconcileStep]
    public var skippedSteps: [CRIShimReconcileStep]

    public init(
        plan: CRIShimReconcilePlan,
        appliedSteps: [CRIShimReconcileStep] = [],
        skippedSteps: [CRIShimReconcileStep] = []
    ) {
        self.plan = plan
        self.appliedSteps = appliedSteps
        self.skippedSteps = skippedSteps
    }
}

public struct CRIShimReconcileExecutor {
    public var reconciler: CRIShimReconciler

    public init(reconciler: CRIShimReconciler = CRIShimReconciler()) {
        self.reconciler = reconciler
    }

    @discardableResult
    public func execute(
        metadataStore: CRIShimMetadataStore,
        runtimeSnapshots: CRIShimRuntimeSnapshotInventory,
        now: Date = Date()
    ) throws -> CRIShimReconcileExecutionResult {
        let storeSnapshot = try metadataStore.snapshot()
        let plan = reconciler.makePlan(
            store: storeSnapshot,
            inventory: runtimeSnapshots.makeInventory(store: storeSnapshot, now: now)
        )

        var context = CRIShimReconcileExecutionContext(
            metadataStore: metadataStore,
            runtimeSnapshots: runtimeSnapshots,
            now: now
        )
        for step in plan.sandboxSteps {
            try context.applySandboxStep(step)
        }
        for step in plan.containerSteps {
            try context.applyContainerStep(step)
        }

        return CRIShimReconcileExecutionResult(
            plan: plan,
            appliedSteps: context.appliedSteps,
            skippedSteps: context.skippedSteps
        )
    }
}

public struct CRIShimMetadataReconcileStartupTask: CRIShimServerStartupTask {
    private let metadataStore: CRIShimMetadataStore
    private let runtimeManager: any CRIShimRuntimeManaging
    private let executor: CRIShimReconcileExecutor
    private let machineStatePolicy: MachineStateConfig?
    private let machineStateLeaseReconciler: CRIShimMachineStateLeaseReconciler

    public init(
        metadataStore: CRIShimMetadataStore,
        runtimeManager: any CRIShimRuntimeManaging,
        executor: CRIShimReconcileExecutor = CRIShimReconcileExecutor(),
        machineStatePolicy: MachineStateConfig? = nil
    ) {
        self.metadataStore = metadataStore
        self.runtimeManager = runtimeManager
        self.executor = executor
        self.machineStatePolicy = machineStatePolicy
        self.machineStateLeaseReconciler = CRIShimMachineStateLeaseReconciler()
    }

    public func run() async throws {
        var machineStateLeases: [CRIShimMachineStateLease] = []
        var admissionLocks: [CRIShimMachineStateAdmissionLock] = []
        var lockedPersistenceIDs: Set<String> = []
        if let machineStatePolicy, machineStatePolicy.enabled {
            machineStateLeases = try CRIShimMachineStateLeaseStore.list(policy: machineStatePolicy)
            admissionLocks = try machineStateLeases.map {
                try CRIShimMachineStateLeaseStore.acquireAdmissionLock(
                    policy: machineStatePolicy,
                    persistenceID: $0.persistenceID
                )
            }
            lockedPersistenceIDs = Set(machineStateLeases.map(\.persistenceID))
            machineStateLeases = try CRIShimMachineStateLeaseStore.list(policy: machineStatePolicy)
                .filter { lockedPersistenceIDs.contains($0.persistenceID) }
        }
        var snapshots = try await runtimeManager.listSandboxSnapshots()
        if let machineStatePolicy, machineStatePolicy.enabled {
            let recoveredIncompleteAdmission = try await recoverIncompleteMachineStateAdmissions(
                policy: machineStatePolicy,
                leases: machineStateLeases
            )
            if recoveredIncompleteAdmission {
                machineStateLeases = try CRIShimMachineStateLeaseStore.list(policy: machineStatePolicy)
                    .filter { lockedPersistenceIDs.contains($0.persistenceID) }
                snapshots = try await runtimeManager.listSandboxSnapshots()
            }
            try validateMachineStateLeaseCoverage(
                metadataStore: metadataStore,
                runtimeSnapshots: snapshots,
                leases: machineStateLeases
            )
            try machineStateLeaseReconciler.reconcile(
                policy: machineStatePolicy,
                metadataStore: metadataStore,
                runtimeSnapshots: snapshots,
                leases: machineStateLeases
            )
        }
        try executor.execute(
            metadataStore: metadataStore,
            runtimeSnapshots: CRIShimRuntimeSnapshotInventory(sandboxes: snapshots)
        )
        withExtendedLifetime(admissionLocks) {}
    }

    private func recoverIncompleteMachineStateAdmissions(
        policy: MachineStateConfig,
        leases: [CRIShimMachineStateLease]
    ) async throws -> Bool {
        let metadataByID = Dictionary(
            uniqueKeysWithValues: try metadataStore.listSandboxes().map { ($0.id, $0) }
        )
        var recovered = false
        for lease in leases.sorted(by: { $0.persistenceID < $1.persistenceID }) {
            let metadata = metadataByID[lease.sandboxID]
            let shouldRecover: Bool
            switch lease.admissionState {
            case .runtimeDeletionConfirmed:
                shouldRecover = true
            case .runtimeCreationStarted, nil:
                shouldRecover = metadata == nil || metadata?.state == .pending || metadata?.state == .released
            case .reserved:
                shouldRecover = false
            }
            guard shouldRecover else {
                continue
            }

            let cleanupConfirmation = try await CRIShimMachineStateRuntimeCleaner(
                runtimeManager: runtimeManager
            ).cleanup(lease: lease, policy: policy)
            for container in try metadataStore.listContainers().filter({ $0.sandboxID == lease.sandboxID }) {
                try metadataStore.deleteContainer(id: container.id)
            }
            if try metadataStore.sandbox(id: lease.sandboxID) != nil {
                try metadataStore.deleteSandbox(id: lease.sandboxID)
            }
            try metadataStore.synchronizeEntityDirectories()
            try CRIShimMachineStateLeaseStore.release(
                policy: policy,
                expected: cleanupConfirmation.lease
            )
            withExtendedLifetime(cleanupConfirmation) {}
            recovered = true
        }
        return recovered
    }
}

private struct CRIShimReconcileExecutionContext {
    let metadataStore: CRIShimMetadataStore
    let runtimeSnapshots: CRIShimRuntimeSnapshotInventory
    let now: Date
    var appliedSteps: [CRIShimReconcileStep] = []
    var skippedSteps: [CRIShimReconcileStep] = []

    private var sandboxSnapshotsByID: [String: SandboxSnapshot] {
        Dictionary(
            runtimeSnapshots.sandboxes.compactMap { snapshot in
                snapshot.criShimSandboxID.map { ($0, snapshot) }
            },
            uniquingKeysWith: { _, new in new }
        )
    }

    private var workloadSnapshotsByID: [String: (sandboxID: String, snapshot: WorkloadSnapshot)] {
        var result: [String: (sandboxID: String, snapshot: WorkloadSnapshot)] = [:]
        for sandboxSnapshot in runtimeSnapshots.sandboxes {
            guard let sandboxID = sandboxSnapshot.criShimSandboxID else {
                continue
            }
            for workloadSnapshot in sandboxSnapshot.workloads {
                result[workloadSnapshot.id] = (sandboxID: sandboxID, snapshot: workloadSnapshot)
            }
        }
        return result
    }

    mutating func applySandboxStep(_ step: CRIShimReconcileStep) throws {
        switch step.action {
        case .create:
            try createSandboxMetadata(step)
        case .update:
            try updateSandboxMetadata(step)
        case .delete:
            try deleteSandboxMetadata(step)
        case .release:
            try releaseSandboxMetadata(step)
        }
    }

    mutating func applyContainerStep(_ step: CRIShimReconcileStep) throws {
        switch step.action {
        case .create:
            try createContainerMetadata(step)
        case .update:
            try updateContainerMetadata(step)
        case .delete:
            try deleteContainerMetadata(step)
        case .release:
            try releaseContainerMetadata(step)
        }
    }

    private mutating func createSandboxMetadata(_ step: CRIShimReconcileStep) throws {
        guard
            let snapshot = sandboxSnapshotsByID[step.id],
            let metadata = makeCRIShimSandboxMetadata(sandboxSnapshot: snapshot, now: now)
        else {
            skippedSteps.append(step)
            return
        }
        try metadataStore.upsertSandbox(metadata)
        appliedSteps.append(step)
    }

    private mutating func updateSandboxMetadata(_ step: CRIShimReconcileStep) throws {
        guard let snapshot = sandboxSnapshotsByID[step.id] else {
            skippedSteps.append(step)
            return
        }
        let updatedMetadata = try metadataStore.updateSandbox(id: step.id) { metadata in
            metadata = metadata.applying(sandboxSnapshot: snapshot)
            metadata.updatedAt = now
        }
        guard updatedMetadata != nil else {
            skippedSteps.append(step)
            return
        }
        appliedSteps.append(step)
    }

    private mutating func deleteSandboxMetadata(_ step: CRIShimReconcileStep) throws {
        let containers = try metadataStore.listContainers().filter { $0.sandboxID == step.id }
        guard containers.allSatisfy({ $0.state == .removed }) else {
            skippedSteps.append(step)
            return
        }
        for container in containers {
            try? metadataStore.deleteContainer(id: container.id)
        }
        try? metadataStore.deleteSandbox(id: step.id)
        appliedSteps.append(step)
    }

    private mutating func releaseSandboxMetadata(_ step: CRIShimReconcileStep) throws {
        let updatedMetadata = try metadataStore.updateSandbox(id: step.id) { metadata in
            metadata.state = .released
            metadata.updatedAt = now
        }
        guard updatedMetadata != nil else {
            skippedSteps.append(step)
            return
        }
        appliedSteps.append(step)
    }

    private mutating func createContainerMetadata(_ step: CRIShimReconcileStep) throws {
        guard let workload = workloadSnapshotsByID[step.id] else {
            skippedSteps.append(step)
            return
        }

        let sandboxMetadata =
            try metadataStore.sandbox(id: workload.sandboxID)
            ?? sandboxSnapshotsByID[workload.sandboxID].flatMap { makeCRIShimSandboxMetadata(sandboxSnapshot: $0, now: now) }
        guard
            let sandboxMetadata,
            let metadata = makeCRIShimContainerMetadata(
                workloadSnapshot: workload.snapshot,
                sandboxID: workload.sandboxID,
                sandboxMetadata: sandboxMetadata,
                now: now
            )
        else {
            skippedSteps.append(step)
            return
        }

        try metadataStore.upsertContainer(metadata)
        appliedSteps.append(step)
    }

    private mutating func updateContainerMetadata(_ step: CRIShimReconcileStep) throws {
        guard let workload = workloadSnapshotsByID[step.id] else {
            skippedSteps.append(step)
            return
        }
        let updatedMetadata = try metadataStore.updateContainer(id: step.id) { metadata in
            metadata =
                metadata
                .applying(workloadSnapshot: workload.snapshot, observedAt: now)
                .applyingReconciledLogPath()
        }
        guard updatedMetadata != nil else {
            skippedSteps.append(step)
            return
        }
        appliedSteps.append(step)
    }

    private mutating func deleteContainerMetadata(_ step: CRIShimReconcileStep) throws {
        try? metadataStore.deleteContainer(id: step.id)
        appliedSteps.append(step)
    }

    private mutating func releaseContainerMetadata(_ step: CRIShimReconcileStep) throws {
        let updatedMetadata = try metadataStore.updateContainer(id: step.id) { metadata in
            metadata.state = .removed
            metadata.exitedAt = metadata.exitedAt ?? now
        }
        guard updatedMetadata != nil else {
            skippedSteps.append(step)
            return
        }
        appliedSteps.append(step)
    }
}

extension SandboxSnapshot {
    var criShimSandboxID: String? {
        configuration?.id.trimmed.nonEmpty
            ?? containers.first?.id.trimmed.nonEmpty
    }
}

private func makeCRIShimSandboxMetadata(
    sandboxSnapshot: SandboxSnapshot,
    now: Date
) -> CRIShimSandboxMetadata? {
    guard let sandboxID = sandboxSnapshot.criShimSandboxID else {
        return nil
    }

    if var metadata = sandboxSnapshot.configuration.flatMap({ decodeCRIShimCoreSandboxMetadataLabel($0.labels) }) {
        metadata.id = sandboxID
        metadata = metadata.applying(sandboxSnapshot: sandboxSnapshot)
        metadata.updatedAt = now
        return metadata
    }

    guard let configuration = sandboxSnapshot.configuration else {
        return nil
    }

    let networkNames = sandboxSnapshot.networks.map(\.network).filter { !$0.trimmed.isEmpty }
    return CRIShimSandboxMetadata(
        id: sandboxID,
        runtimeHandler: configuration.runtimeHandler == "container-runtime-macos" ? "" : configuration.runtimeHandler,
        sandboxImage: configuration.image.reference,
        network: networkNames.first,
        labels: removeCRIShimCoreLabels(configuration.labels),
        annotations: [:],
        networkAttachments: networkNames,
        state: makeCRIShimSandboxMetadataState(sandboxSnapshot.status),
        createdAt: now,
        updatedAt: now
    )
}

private func makeCRIShimContainerMetadata(
    workloadSnapshot: WorkloadSnapshot,
    sandboxID: String,
    sandboxMetadata: CRIShimSandboxMetadata,
    now: Date
) -> CRIShimContainerMetadata? {
    let process = workloadSnapshot.configuration.processConfiguration
    let image =
        [
            workloadSnapshot.configuration.workloadImageReference,
            workloadSnapshot.configuration.workloadImageDigest,
            sandboxMetadata.sandboxImage,
        ]
        .compactMap { $0?.trimmed.nonEmpty }
        .first ?? sandboxMetadata.sandboxImage

    var metadata = CRIShimContainerMetadata(
        id: workloadSnapshot.id,
        sandboxID: sandboxID,
        name: workloadSnapshot.id,
        image: image,
        runtimeHandler: sandboxMetadata.runtimeHandler,
        command: [process.executable].filter { !$0.trimmed.isEmpty },
        args: process.arguments,
        workingDirectory: process.workingDirectory,
        logPath: makeReconciledContainerLogPath(containerID: workloadSnapshot.id),
        state: makeCRIShimContainerMetadataState(workloadSnapshot.status),
        createdAt: workloadSnapshot.startedDate ?? workloadSnapshot.exitedAt ?? now,
        startedAt: workloadSnapshot.startedDate,
        exitedAt: workloadSnapshot.exitedAt
    )
    metadata = metadata.applying(workloadSnapshot: workloadSnapshot, observedAt: now)
    return metadata
}

private let reconciledContainerLogRoot = "/var/log/pods/.container-cri-shim-macos-reconciled"

private func makeReconciledContainerLogPath(containerID: String) -> String {
    URL(fileURLWithPath: reconciledContainerLogRoot, isDirectory: true)
        .appendingPathComponent(containerID, isDirectory: true)
        .appendingPathComponent("0.log", isDirectory: false)
        .path
}

extension CRIShimContainerMetadata {
    fileprivate func applyingReconciledLogPath() -> CRIShimContainerMetadata {
        guard logPath?.trimmed.nonEmpty == nil else {
            return self
        }
        var metadata = self
        metadata.logPath = makeReconciledContainerLogPath(containerID: id)
        return metadata
    }
}

private func makeCRIShimSandboxMetadataState(_ status: RuntimeStatus) -> CRIShimSandboxMetadata.State {
    switch status {
    case .running:
        .running
    case .stopping, .stopped:
        .stopped
    case .unknown:
        .pending
    }
}

private func makeCRIShimContainerMetadataState(_ status: RuntimeStatus) -> CRIShimContainerMetadata.State {
    switch status {
    case .running, .stopping:
        .running
    case .stopped:
        .exited
    case .unknown:
        .created
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
