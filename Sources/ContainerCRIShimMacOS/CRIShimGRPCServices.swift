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
import ContainerVersion
import ContainerizationError
import Darwin
import Foundation
import GRPC

public struct CRIShimRuntimeVersionInfo: Equatable, Sendable {
    public var runtimeName: String
    public var runtimeVersion: String
    public var runtimeAPIVersion: String

    public init(
        runtimeName: String = "container-macos",
        runtimeVersion: String = ReleaseVersion.version(),
        runtimeAPIVersion: String = CRIProtocol.runtimeImplementationAPIVersion
    ) {
        self.runtimeName = runtimeName
        self.runtimeVersion = runtimeVersion
        self.runtimeAPIVersion = runtimeAPIVersion
    }
}

private let criShimPodSandboxStopOptions = ContainerStopOptions(timeoutInSeconds: 0, signal: SIGKILL)
private let criShimLifecycleConfirmationAttempts = 3
private let criShimLifecycleConfirmationInterval = Duration.milliseconds(100)

private actor CRIShimLifecycleCoordinator {
    private var lockedKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        guard lockedKeys.contains(key) else {
            lockedKeys.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        guard var queuedWaiters = waiters[key], !queuedWaiters.isEmpty else {
            lockedKeys.remove(key)
            waiters.removeValue(forKey: key)
            return
        }
        let next = queuedWaiters.removeFirst()
        if queuedWaiters.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            waiters[key] = queuedWaiters
        }
        next.resume()
    }
}

private enum CRIShimWorkloadObservation {
    case snapshot(WorkloadSnapshot)
    case missing
}

private enum CRIShimStoppedWorkloadObservation {
    case snapshot(WorkloadSnapshot)
    case missing
}

private enum CRIShimSandboxObservation {
    case snapshot(SandboxSnapshot)
    case missing
}

public enum CRIShimPodAnnotation {
    public static let sandboxImage = "container-macos.io/sandbox-image"
}

public final class CRIShimRuntimeServiceProvider: Runtime_V1_RuntimeServiceAsyncProvider, @unchecked Sendable {
    public var versionInfo: CRIShimRuntimeVersionInfo
    public var config: CRIShimConfig
    private let metadataStore: CRIShimMetadataStore
    private let readinessChecker: any CRIShimReadinessChecking
    private let runtimeManager: any CRIShimRuntimeManaging
    private let imageManager: any CRIShimImageManaging
    private let cniManager: any CRIShimCNIManaging
    private let logManager: any CRIShimLogManaging
    private let podNetworkStateStore: PodNetworkStateStore
    private let vmnetRecoveryController: CRIShimVMNetRecoveryController
    private let streamingServer: CRIShimStreamingServer?
    private let handlerLogger: CRIShimGRPCHandlerLogger
    private let lifecycleCoordinator = CRIShimLifecycleCoordinator()

    public init(
        config: CRIShimConfig,
        metadataStore: CRIShimMetadataStore,
        versionInfo: CRIShimRuntimeVersionInfo = CRIShimRuntimeVersionInfo(),
        readinessChecker: any CRIShimReadinessChecking = ContainerKitCRIShimReadinessChecker(),
        runtimeManager: any CRIShimRuntimeManaging = ContainerKitCRIShimRuntimeManager(),
        imageManager: any CRIShimImageManaging = ContainerKitCRIShimImageManager(),
        cniManager: any CRIShimCNIManaging = ProcessCRIShimCNIManager(),
        logManager: (any CRIShimLogManaging)? = nil,
        podNetworkStateStore: PodNetworkStateStore = PodNetworkStateStore(),
        vmnetRecoveryController: CRIShimVMNetRecoveryController? = nil,
        streamingServer: CRIShimStreamingServer? = nil,
        handlerLogger: CRIShimGRPCHandlerLogger = .runtimeService()
    ) {
        self.config = config
        self.versionInfo = versionInfo
        self.metadataStore = metadataStore
        self.readinessChecker = readinessChecker
        self.runtimeManager = runtimeManager
        self.imageManager = imageManager
        self.cniManager = cniManager
        self.podNetworkStateStore = podNetworkStateStore
        self.vmnetRecoveryController =
            vmnetRecoveryController
            ?? CRIShimVMNetRecoveryController(
                config: config,
                admissionRejectionRecorder: VMNetRecoveryAdmissionRejectionJournal()
            )
        self.logManager =
            logManager
            ?? CRIShimLogManager(
                stateDirectoryURL: URL(fileURLWithPath: config.normalizedStateDirectory)
            )
        self.streamingServer = streamingServer
        self.handlerLogger = handlerLogger
    }

    public func version(
        request: Runtime_V1_VersionRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_VersionResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.version.rawValue) {
            var response = Runtime_V1_VersionResponse()
            response.version =
                request.version.isEmpty ? CRIProtocol.kubeletRuntimeAPIVersion : request.version
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
            let snapshot = vmnetRecoveryController.apply(
                to: await readinessChecker.snapshot(config: config)
            )
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
                response.info[CRIShimRestoreInfoKey.capabilities] = makeCRIStatusJSONString(
                    CRIShimRestoreCapabilities()
                )
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
            guard let podNetwork = config.podNetwork, podNetwork.enabled == true else {
                return Runtime_V1_UpdateRuntimeConfigResponse()
            }

            let configuredPodCIDRs = request.runtimeConfig.networkConfig.podCidr.trimmed
            guard !configuredPodCIDRs.isEmpty else {
                return Runtime_V1_UpdateRuntimeConfigResponse()
            }

            let podCIDRs: PodNetworkCIDRs
            do {
                podCIDRs = try canonicalPodNetworkCIDRs(
                    configuredPodCIDRs,
                    dualStackEnabled: podNetwork.dualStackEnabled
                )
            } catch {
                let requirement =
                    podNetwork.dualStackEnabled
                    ? "exactly one valid IPv4 CIDR and one valid IPv6 CIDR"
                    : "exactly one valid IPv4 CIDR"
                throw CRIShimError.invalidArgument("pod CIDRs must contain \(requirement)")
            }

            guard let networkName = podNetwork.networkName?.trimmed,
                !networkName.isEmpty,
                let runtimeStatePath = podNetwork.runtimeStatePath?.trimmed,
                !runtimeStatePath.isEmpty
            else {
                throw CRIShimError.internalError("pod network runtime state is not configured")
            }

            do {
                try await podNetworkStateStore.updateRuntimeState(
                    networkName: networkName,
                    podCIDRs: podCIDRs,
                    path: runtimeStatePath
                )
            } catch let error as PodNetworkStateError
                where error == .invalidIPv4PodCIDR
                || error == .invalidIPv6PodCIDR
                || error == .invalidPodCIDRList
            {
                let requirement =
                    podNetwork.dualStackEnabled
                    ? "exactly one valid IPv4 CIDR and one valid IPv6 CIDR"
                    : "exactly one valid IPv4 CIDR"
                throw CRIShimError.invalidArgument("pod CIDRs must contain \(requirement)")
            } catch {
                throw CRIShimError.internalError("failed to persist pod network runtime state")
            }
            return Runtime_V1_UpdateRuntimeConfigResponse()
        }
    }

    public func runPodSandbox(
        request: Runtime_V1_RunPodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RunPodSandboxResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.runPodSandbox.rawValue) {
            let admissionAttemptID = UUID()
            try vmnetRecoveryController.requireAdmission(
                gate: .beforeRequestValidation,
                attemptID: admissionAttemptID
            )
            try CRIShimUnsupportedFieldValidator.validate(request)

            var handler = try config.resolveRuntimeHandler(request.runtimeHandler)
            handler.sandboxImage = try sandboxImageReference(request: request, handler: handler)
            let proposedSandboxID = UUID().uuidString.lowercased()
            let sandboxImage = try await resolveSandboxImage(reference: handler.sandboxImage)
            try validateCRIShimImage(
                sandboxImage,
                expectedRole: .sandbox,
                requestedReference: handler.sandboxImage
            )
            let networkMTUOverride = try await resolvePodNetworkMTUOverride(handler: handler)
            let machineState = try makeCRIShimMachineStateMapping(
                annotations: request.config.annotations,
                nodeConfig: config.machineState
            )
            let provision = {
                try await self.provisionPodSandbox(
                    request: request,
                    handler: handler,
                    sandboxImage: sandboxImage,
                    networkMTUOverride: networkMTUOverride,
                    machineState: machineState,
                    proposedSandboxID: proposedSandboxID,
                    admissionAttemptID: admissionAttemptID
                )
            }
            guard let resolved = machineState.machineState else {
                return try await provision()
            }
            guard let policy = config.machineState else {
                throw CRIShimError.internalError("machine-state policy disappeared during admission")
            }
            return try await withLifecycleLock(key: "machine-state:\(resolved.persistenceID)") {
                let admissionLock = try CRIShimMachineStateLeaseStore.acquireAdmissionLock(
                    policy: policy,
                    persistenceID: resolved.persistenceID
                )
                defer { withExtendedLifetime(admissionLock) {} }
                return try await provision()
            }
        }
    }

    private func provisionPodSandbox(
        request: Runtime_V1_RunPodSandboxRequest,
        handler: ResolvedRuntimeHandler,
        sandboxImage: CRIShimImageRecord,
        networkMTUOverride: UInt32?,
        machineState: CRIShimMachineStateMapping,
        proposedSandboxID: String,
        admissionAttemptID: UUID
    ) async throws -> Runtime_V1_RunPodSandboxResponse {
        var leaseAcquisition: CRIShimMachineStateLeaseAcquisition?
        if let resolved = machineState.machineState {
            guard let policy = config.machineState else {
                throw CRIShimError.internalError("machine-state policy disappeared during admission")
            }
            if try CRIShimMachineStateLeaseStore.load(
                policy: policy,
                persistenceID: resolved.persistenceID
            ) == nil {
                try await validateFreshMachineStateAdmission(resolved, policy: policy)
            }
            var acquisition = try CRIShimMachineStateLeaseStore.acquire(
                policy: policy,
                machineState: resolved,
                podUID: request.config.metadata.uid,
                proposedSandboxID: proposedSandboxID
            )
            if !acquisition.created, try metadataStore.sandbox(id: acquisition.lease.sandboxID) == nil {
                let runtimeSnapshots = try await runtimeManager.listSandboxSnapshots()
                let reconciliation = try CRIShimMachineStateLeaseReconciler().reconcile(
                    policy: policy,
                    metadataStore: metadataStore,
                    runtimeSnapshots: runtimeSnapshots,
                    leases: [acquisition.lease]
                )
                if reconciliation.released == [acquisition.lease] {
                    acquisition = try CRIShimMachineStateLeaseStore.acquire(
                        policy: policy,
                        machineState: resolved,
                        podUID: request.config.metadata.uid,
                        proposedSandboxID: proposedSandboxID
                    )
                    guard acquisition.created else {
                        throw CRIShimError.unavailable(
                            "machine-state persistence id \(resolved.persistenceID) changed while reconciling an orphan lease"
                        )
                    }
                }
            }
            leaseAcquisition = acquisition
        }

        let sandboxID = leaseAcquisition?.lease.sandboxID ?? proposedSandboxID
        if let leaseAcquisition, !leaseAcquisition.created {
            guard let existing = try metadataStore.sandbox(id: sandboxID),
                existing.podUID == leaseAcquisition.lease.podUID,
                existing.state != .pending,
                existing.state != .released
            else {
                throw CRIShimError.unavailable(
                    "machine-state persistence id \(leaseAcquisition.lease.persistenceID) has a lease without a completed sandbox; refusing automatic takeover"
                )
            }
            var response = Runtime_V1_RunPodSandboxResponse()
            response.podSandboxID = sandboxID
            return response
        }
        var sandboxCreated = false
        var metadataPersisted = false
        var networkAttachAttempted = false

        do {
            var metadata = try makeCRIShimSandboxMetadata(
                id: sandboxID,
                request: request,
                handler: handler
            )
            var sandboxConfiguration = try makeCRIShimSandboxConfiguration(
                id: sandboxID,
                request: request,
                handler: handler,
                sandboxImage: sandboxImage,
                metadata: metadata,
                networkMTUOverride: networkMTUOverride,
                vmnetDisconnectRecovery: config.podNetwork?.vmnetDisconnectRecovery ?? .disabled,
                vmnetRecoveryStatePath: vmnetRecoveryController.statePath,
                vmnetRecoveryRequestPath: vmnetRecoveryController.requestPath,
                vmnetRecoveryBootSessionID: vmnetRecoveryController.bootSessionID,
                machineStateConfig: config.machineState
            )
            if let barrier = leaseAcquisition?.lease.sidecarLifecycleBarrier {
                guard sandboxConfiguration.macosGuest?.machineState != nil else {
                    throw CRIShimError.internalError("machine-state lifecycle barrier has no runtime configuration")
                }
                sandboxConfiguration.macosGuest?.machineState?.sidecarLifecycleBarrier = .init(
                    protocolVersion: barrier.protocolVersion,
                    bootNonce: barrier.bootNonce
                )
            }
            try vmnetRecoveryController.requireAdmission(
                gate: .beforeSandboxCreate,
                attemptID: admissionAttemptID
            )
            if var acquisition = leaseAcquisition, acquisition.created {
                guard let policy = config.machineState else {
                    throw CRIShimError.internalError("machine-state policy disappeared before runtime creation")
                }
                acquisition.lease = try CRIShimMachineStateLeaseStore.markRuntimeCreationStarted(
                    policy: policy,
                    expected: acquisition.lease
                )
                leaseAcquisition = acquisition
            }
            try await runtimeManager.createSandbox(configuration: sandboxConfiguration)
            sandboxCreated = true
            try metadataStore.upsertSandbox(metadata)
            metadataPersisted = true
            if handler.usesPodNetworking {
                try vmnetRecoveryController.requireAdmission(
                    gate: .beforeNetworkAttach,
                    attemptID: admissionAttemptID
                )
                networkAttachAttempted = true
                let network: CRIShimCNIResult
                if let identityManager = cniManager as? any CRIShimCNIIdentityManaging {
                    network = try await identityManager.add(
                        identity: cniSandboxIdentity(metadata),
                        networkName: handler.network,
                        config: config
                    )
                } else {
                    network = try await cniManager.add(
                        sandboxID: metadata.runtimeSandboxID,
                        networkName: handler.network,
                        config: config
                    )
                }
                metadata.networkLeaseID = network.sandboxURI
                metadata.networkAttachments = [network.networkName]
            }
            metadata.state = .ready
            metadata.updatedAt = Date()
            try metadataStore.upsertSandbox(metadata)
        } catch {
            let admissionError = error
            if networkAttachAttempted {
                let runtimeSandboxID = machineState.machineState?.persistenceID ?? sandboxID
                if let identityManager = cniManager as? any CRIShimCNIIdentityManaging {
                    try? await identityManager.delete(
                        identity: .init(
                            runtimeSandboxID: runtimeSandboxID,
                            criSandboxID: sandboxID,
                            restoreRequestID: request.config.annotations[CRIShimMachineStateAnnotation.restoreRequestID],
                            podUID: request.config.metadata.uid
                        ),
                        networkName: handler.network,
                        config: config
                    )
                } else {
                    try? await cniManager.delete(
                        sandboxID: runtimeSandboxID,
                        networkName: handler.network,
                        config: config
                    )
                }
            }
            if let leaseAcquisition, leaseAcquisition.created, let policy = config.machineState {
                switch leaseAcquisition.lease.admissionState {
                case .runtimeCreationStarted, nil:
                    let cleanupConfirmation = try await CRIShimMachineStateRuntimeCleaner(
                        runtimeManager: runtimeManager
                    ).cleanup(lease: leaseAcquisition.lease, policy: policy)
                    if metadataPersisted {
                        try metadataStore.deleteSandbox(id: sandboxID)
                    }
                    try CRIShimMachineStateLeaseStore.release(
                        policy: policy,
                        expected: cleanupConfirmation.lease
                    )
                    withExtendedLifetime(cleanupConfirmation) {}
                case .runtimeDeletionConfirmed:
                    if metadataPersisted {
                        try metadataStore.deleteSandbox(id: sandboxID)
                    }
                    try CRIShimMachineStateLeaseStore.release(
                        policy: policy,
                        expected: leaseAcquisition.lease
                    )
                case .reserved:
                    try CRIShimMachineStateLeaseStore.release(
                        policy: policy,
                        expected: leaseAcquisition.lease
                    )
                }
            } else {
                if sandboxCreated {
                    let runtimeSandboxID =
                        (try? metadataStore.sandbox(id: sandboxID))?.runtimeSandboxID
                        ?? machineState.machineState?.persistenceID
                        ?? sandboxID
                    try? await runtimeManager.removeSandbox(id: runtimeSandboxID, force: true)
                }
                if metadataPersisted {
                    try? metadataStore.deleteSandbox(id: sandboxID)
                }
            }
            throw admissionError
        }

        var response = Runtime_V1_RunPodSandboxResponse()
        response.podSandboxID = sandboxID
        return response
    }

    private func validateFreshMachineStateAdmission(
        _ machineState: ContainerConfiguration.MacOSGuestOptions.MachineState,
        policy: MachineStateConfig
    ) async throws {
        let snapshots = try await runtimeManager.listSandboxSnapshots()
        try validateMachineStateLeaseCoverage(
            metadataStore: metadataStore,
            runtimeSnapshots: snapshots,
            leases: try CRIShimMachineStateLeaseStore.list(policy: policy)
        )
        try requireControlSocketAbsent(machineState.controlSocketPath)
    }

    private func requireControlSocketAbsent(_ path: String) throws {
        var value = stat()
        if lstat(path, &value) == 0 {
            throw CRIShimError.unavailable(
                "machine-state control socket is still present"
            )
        }
        guard errno == ENOENT else {
            throw CRIShimError.internalError(
                "failed to verify the machine-state control socket before lease creation"
            )
        }
    }

    private func resolvePodNetworkMTUOverride(handler: ResolvedRuntimeHandler) async throws -> UInt32? {
        guard handler.usesPodNetworking,
            let podNetwork = config.podNetwork,
            podNetwork.enabled == true
        else {
            return nil
        }

        do {
            return try await podNetworkStateStore.resolveReadyLease(config: podNetwork).mtu
        } catch {
            throw CRIShimError.internalError("pod network MTU is unavailable: \(error)")
        }
    }

    public func stopPodSandbox(
        request: Runtime_V1_StopPodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StopPodSandboxResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.stopPodSandbox.rawValue) {
            let initialMetadata = try sandboxMetadata(
                id: request.podSandboxID,
                operation: "StopPodSandbox"
            )
            guard let lease = try machineStateLease(for: initialMetadata),
                let policy = config.machineState
            else {
                return try await stopPodSandboxWithLifecycleLock(id: request.podSandboxID)
            }
            return try await withLifecycleLock(key: "machine-state:\(lease.persistenceID)") {
                let admissionLock = try CRIShimMachineStateLeaseStore.acquireAdmissionLock(
                    policy: policy,
                    persistenceID: lease.persistenceID
                )
                defer { withExtendedLifetime(admissionLock) {} }
                _ = try CRIShimMachineStateLeaseStore.hasActiveBinding(policy: policy, expected: lease)
                return try await stopPodSandboxWithLifecycleLock(
                    id: request.podSandboxID,
                    expectedLease: lease
                )
            }
        }
    }

    private func stopPodSandboxWithLifecycleLock(
        id: String,
        expectedLease: CRIShimMachineStateLease? = nil
    ) async throws -> Runtime_V1_StopPodSandboxResponse {
        try await withSandboxLifecycleLock(id: id) {
            var metadata = try sandboxMetadata(
                id: id,
                operation: "StopPodSandbox"
            )
            if let expectedLease {
                guard let currentLease = try machineStateLease(for: metadata),
                    currentLease.hasSameBinding(as: expectedLease)
                else {
                    throw CRIShimError.unavailable(
                        "machine-state lease identity changed while stopping the sandbox"
                    )
                }
            }
            if metadata.state != .released {
                try await stopSandboxResources(metadata: &metadata)
            }
            return Runtime_V1_StopPodSandboxResponse()
        }
    }

    public func removePodSandbox(
        request: Runtime_V1_RemovePodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RemovePodSandboxResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.removePodSandbox.rawValue) {
            let initialMetadata = try sandboxMetadata(
                id: request.podSandboxID,
                operation: "RemovePodSandbox"
            )
            guard let lease = try machineStateLease(for: initialMetadata),
                let policy = config.machineState
            else {
                return try await withSandboxLifecycleLock(id: request.podSandboxID) {
                    let metadata = try sandboxMetadata(
                        id: request.podSandboxID,
                        operation: "RemovePodSandbox"
                    )
                    return try await removePodSandboxResources(metadata: metadata)
                }
            }

            return try await withLifecycleLock(key: "machine-state:\(lease.persistenceID)") {
                let admissionLock = try CRIShimMachineStateLeaseStore.acquireAdmissionLock(
                    policy: policy,
                    persistenceID: lease.persistenceID
                )
                defer { withExtendedLifetime(admissionLock) {} }
                return try await withSandboxLifecycleLock(id: request.podSandboxID) {
                    let metadata = try sandboxMetadata(
                        id: request.podSandboxID,
                        operation: "RemovePodSandbox"
                    )
                    guard let currentLease = try machineStateLease(for: metadata),
                        currentLease.hasSameBinding(as: lease)
                    else {
                        throw CRIShimError.unavailable(
                            "machine-state lease identity changed while removing the sandbox"
                        )
                    }
                    let persistedLease = try CRIShimMachineStateLeaseStore.load(
                        policy: policy,
                        persistenceID: currentLease.persistenceID
                    )
                    if let persistedLease, !persistedLease.hasSameBinding(as: currentLease) {
                        throw CRIShimError.unavailable(
                            "machine-state lease identity changed while removing the sandbox"
                        )
                    }
                    return try await removePodSandboxResources(
                        metadata: metadata,
                        lease: persistedLease ?? currentLease,
                        policy: policy,
                        leaseIsActive: persistedLease != nil
                    )
                }
            }
        }
    }

    private func removePodSandboxResources(
        metadata initialMetadata: CRIShimSandboxMetadata,
        lease: CRIShimMachineStateLease? = nil,
        policy: MachineStateConfig? = nil,
        leaseIsActive: Bool = false
    ) async throws -> Runtime_V1_RemovePodSandboxResponse {
        var metadata = initialMetadata
        let cleaner = CRIShimMachineStateRuntimeCleaner(runtimeManager: runtimeManager)
        let cleanupPreparation: CRIShimMachineStateRuntimeCleanupPreparation?
        if let lease, let policy {
            cleanupPreparation = try await cleaner.prepare(binding: lease, policy: policy)
        } else {
            cleanupPreparation = nil
        }
        if metadata.state != .released {
            try await stopSandboxResources(metadata: &metadata)
        }

        let leaseToRelease: CRIShimMachineStateLease?
        var cleanupConfirmation: CRIShimMachineStateRuntimeCleanupConfirmation?
        var runtimeCleanupProof: CRIShimMachineStateSidecarExitProof?
        if let lease, let policy {
            if leaseIsActive {
                let confirmation = try await cleaner.cleanup(
                    lease: lease,
                    policy: policy,
                    preparation: cleanupPreparation
                )
                cleanupConfirmation = confirmation
                leaseToRelease = confirmation.lease
            } else {
                runtimeCleanupProof = try await cleaner.cleanupRuntime(
                    binding: lease,
                    policy: policy,
                    preparation: cleanupPreparation
                )
                leaseToRelease = nil
            }
        } else {
            do {
                try await runtimeManager.removeSandbox(id: metadata.runtimeSandboxID, force: true)
            } catch {
                try throwUnlessNotFound(error)
            }
            leaseToRelease = nil
        }

        let containers = try metadataStore.listContainers()
            .filter { $0.sandboxID == metadata.id }
        for container in containers {
            await logManager.stop(containerID: container.id, removeState: true)
            try metadataStore.deleteContainer(id: container.id)
        }
        try metadataStore.deleteSandbox(id: metadata.id)
        if let leaseToRelease, let policy {
            try metadataStore.synchronizeEntityDirectories()
            try CRIShimMachineStateLeaseStore.release(policy: policy, expected: leaseToRelease)
        }
        withExtendedLifetime(cleanupPreparation) {}
        withExtendedLifetime(cleanupConfirmation) {}
        withExtendedLifetime(runtimeCleanupProof) {}
        return Runtime_V1_RemovePodSandboxResponse()
    }

    public func execSync(
        request: Runtime_V1_ExecSyncRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ExecSyncResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.execSync.rawValue) {
            var invocation = try makeCRIShimExecSyncInvocation(request)
            let metadata = try containerMetadata(id: invocation.containerID, operation: "ExecSync")
            let sandbox = try sandboxMetadata(id: metadata.sandboxID, operation: "ExecSync")
            let workload = try await runtimeManager.inspectWorkload(
                sandboxID: sandbox.runtimeSandboxID,
                workloadID: metadata.runtimeWorkloadID
            )
            invocation.containerID = sandbox.runtimeSandboxID
            invocation.configuration = makeCRIShimExecProcessConfiguration(
                requested: invocation.configuration,
                workload: workload
            )
            let result = try await runtimeManager.execSync(
                containerID: invocation.containerID,
                workloadID: metadata.runtimeWorkloadID,
                configuration: invocation.configuration,
                timeout: invocation.timeout
            )
            return makeCRIShimExecSyncResponse(result)
        }
    }

    public func exec(
        request: Runtime_V1_ExecRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ExecResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.exec.rawValue) {
            guard let streamingServer else {
                throw CRIShimError.internalError("streaming server is not configured")
            }
            var invocation = try makeCRIShimExecStreamingInvocation(request)
            let metadata = try containerMetadata(id: invocation.containerID, operation: "Exec")
            let sandbox = try sandboxMetadata(id: metadata.sandboxID, operation: "Exec")
            let workload = try await runtimeManager.inspectWorkload(
                sandboxID: sandbox.runtimeSandboxID,
                workloadID: metadata.runtimeWorkloadID
            )
            invocation.containerID = sandbox.runtimeSandboxID
            invocation.workloadID = metadata.runtimeWorkloadID
            invocation.configuration = makeCRIShimExecProcessConfiguration(
                requested: invocation.configuration,
                workload: workload
            )
            var response = Runtime_V1_ExecResponse()
            response.url = try await streamingServer.registerExecURL(invocation)
            return response
        }
    }

    public func portForward(
        request: Runtime_V1_PortForwardRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PortForwardResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.portForward.rawValue) {
            guard let streamingServer else {
                throw CRIShimError.internalError("streaming server is not configured")
            }
            var invocation = try makeCRIShimPortForwardInvocation(request)
            let sandbox = try sandboxMetadata(id: invocation.sandboxID, operation: "PortForward")
            invocation.sandboxID = sandbox.runtimeSandboxID
            var response = Runtime_V1_PortForwardResponse()
            response.url = try await streamingServer.registerPortForwardURL(invocation)
            return response
        }
    }

    public func podSandboxStatus(
        request: Runtime_V1_PodSandboxStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PodSandboxStatusResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.podSandboxStatus.rawValue) {
            let sandboxID = request.podSandboxID.trimmed
            guard !sandboxID.isEmpty else {
                throw CRIShimError.invalidArgument("PodSandboxStatus pod_sandbox_id is required")
            }

            let storedContainers = try metadataStore.listContainers()
                .filter { $0.sandboxID == sandboxID }
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id < rhs.id
                    }
                    return lhs.createdAt < rhs.createdAt
                })
            for container in storedContainers {
                _ = try await reconciledContainerMetadata(
                    container,
                    includeRuntimeDetailsForExitedContainer: true
                )
            }

            return try await withSandboxLifecycleLock(id: sandboxID) {
                guard let current = try metadataStore.sandbox(id: sandboxID) else {
                    throw CRIShimMetadataStoreError.notFound(kind: .sandbox, id: sandboxID)
                }
                let currentContainers = try metadataStore.listContainers()
                    .filter { $0.sandboxID == sandboxID }
                    .sorted(by: { lhs, rhs in
                        if lhs.createdAt == rhs.createdAt {
                            return lhs.id < rhs.id
                        }
                        return lhs.createdAt < rhs.createdAt
                    })
                let hasActiveContainers = currentContainers.contains {
                    $0.state == .created || $0.state == .running
                }
                let observation = try await reconciledSandboxObservationLocked(
                    for: current,
                    hasActiveContainers: hasActiveContainers
                )
                guard let metadata = observation?.metadata else {
                    throw CRIShimMetadataStoreError.notFound(kind: .sandbox, id: sandboxID)
                }
                let snapshot = observation?.snapshot
                let effectiveSnapshot =
                    snapshot?.status != .running
                        && hasActiveContainers
                    ? nil : snapshot

                var response = Runtime_V1_PodSandboxStatusResponse()
                response.status = makeCRIPodSandboxStatus(
                    metadata,
                    sandboxSnapshot: effectiveSnapshot,
                    dualStackEnabled: config.podNetwork?.dualStackEnabled == true
                )
                response.containersStatuses = currentContainers.map(makeCRIContainerStatus)
                response.timestamp = Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded())
                if request.verbose {
                    response.info = makeCRIPodSandboxStatusInfo(
                        metadata,
                        sandboxSnapshot: effectiveSnapshot,
                        containers: currentContainers,
                        machineStateConfig: config.machineState
                    )
                }
                return response
            }
        }
    }

    public func listPodSandbox(
        request: Runtime_V1_ListPodSandboxRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListPodSandboxResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.listPodSandbox.rawValue) {
            var response = Runtime_V1_ListPodSandboxResponse()
            var sandboxes: [CRIShimSandboxMetadata] = []
            let storedSandboxes = try metadataStore.listSandboxes()
            sandboxes.reserveCapacity(storedSandboxes.count)
            for metadata in storedSandboxes {
                let reconciled = try await withSandboxLifecycleLock(id: metadata.id) {
                    guard let current = try metadataStore.sandbox(id: metadata.id) else {
                        return nil as CRIShimSandboxMetadata?
                    }
                    let hasActiveContainers = try metadataStore.listContainers().contains {
                        $0.sandboxID == metadata.id && ($0.state == .created || $0.state == .running)
                    }
                    return try await reconciledSandboxObservationLocked(
                        for: current,
                        hasActiveContainers: hasActiveContainers
                    )?.metadata
                }
                if let reconciled {
                    sandboxes.append(reconciled)
                }
            }
            response.items = filterCRIPodSandboxes(sandboxes, request: request)
                .map(makeCRIPodSandbox)
            return response
        }
    }

    public func listContainers(
        request: Runtime_V1_ListContainersRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListContainersResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.listContainers.rawValue) {
            var response = Runtime_V1_ListContainersResponse()
            var candidateRequest = request
            if candidateRequest.hasFilter {
                var candidateFilter = candidateRequest.filter
                candidateFilter.clearState()
                candidateRequest.filter = candidateFilter
            }
            let storedContainers = try filterCRIContainers(
                metadataStore.listContainers(),
                request: candidateRequest
            )
            var containers: [CRIShimContainerMetadata] = []
            containers.reserveCapacity(storedContainers.count)
            for metadata in storedContainers {
                if let reconciled = try await reconciledContainerMetadata(metadata) {
                    containers.append(reconciled.metadata)
                }
            }
            response.containers = filterCRIContainers(containers, request: request)
                .map(makeCRIContainer)
            return response
        }
    }

    public func createContainer(
        request: Runtime_V1_CreateContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_CreateContainerResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.createContainer.rawValue) {
            try CRIShimUnsupportedFieldValidator.validate(request)

            let sandboxID = request.podSandboxID.trimmed
            guard !sandboxID.isEmpty else {
                throw CRIShimError.invalidArgument("CreateContainer pod_sandbox_id is required")
            }

            return try await withSandboxLifecycleLock(id: sandboxID) {
                guard let sandbox = try metadataStore.sandbox(id: sandboxID) else {
                    throw CRIShimMetadataStoreError.notFound(kind: .sandbox, id: sandboxID)
                }

                guard sandbox.state.allowsContainerCreation else {
                    throw CRIShimError.invalidArgument(
                        "CreateContainer requires a ready or running sandbox, got \(sandbox.state.rawValue)"
                    )
                }

                let containerID = UUID().uuidString.lowercased()
                let requestedImage = try CRIShimImageReference.resolve(request.config.image)
                let workloadImage = try await findImage(reference: requestedImage)
                try validateCRIShimImage(
                    workloadImage,
                    expectedRole: .workload,
                    requestedReference: requestedImage
                )
                let workloadImageDigest = workloadImage.digest.trimmed
                guard !workloadImageDigest.isEmpty else {
                    throw CRIShimError.invalidArgument("workload image \(requestedImage) is missing a resolved digest")
                }
                let metadata = try makeCRIShimContainerMetadata(
                    id: containerID,
                    request: request,
                    sandbox: sandbox
                )
                let workloadConfiguration = try makeCRIShimWorkloadConfiguration(
                    id: metadata.runtimeWorkloadID,
                    request: request,
                    workloadImageDigest: workloadImageDigest,
                    sandbox: sandbox
                )

                try await runtimeManager.createWorkload(
                    sandboxID: sandbox.runtimeSandboxID,
                    configuration: workloadConfiguration
                )

                do {
                    try metadataStore.upsertContainer(metadata)
                } catch {
                    try? await runtimeManager.removeWorkload(
                        sandboxID: sandbox.runtimeSandboxID,
                        workloadID: metadata.runtimeWorkloadID
                    )
                    throw error
                }

                var response = Runtime_V1_CreateContainerResponse()
                response.containerID = containerID
                return response
            }
        }
    }

    public func startContainer(
        request: Runtime_V1_StartContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StartContainerResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.startContainer.rawValue) {
            let initialContainer = try containerMetadata(
                id: request.containerID,
                operation: "StartContainer"
            )
            let initialSandbox = try sandboxMetadata(
                id: initialContainer.sandboxID,
                operation: "StartContainer"
            )
            guard let lease = try machineStateLease(for: initialSandbox),
                let policy = config.machineState
            else {
                return try await startContainerWithLifecycleLocks(request: request)
            }
            return try await withLifecycleLock(key: "machine-state:\(lease.persistenceID)") {
                let admissionLock = try CRIShimMachineStateLeaseStore.acquireAdmissionLock(
                    policy: policy,
                    persistenceID: lease.persistenceID
                )
                defer { withExtendedLifetime(admissionLock) {} }
                guard
                    let persistedLease = try CRIShimMachineStateLeaseStore.load(
                        policy: policy,
                        persistenceID: lease.persistenceID
                    ), persistedLease.hasSameBinding(as: lease)
                else {
                    throw CRIShimError.unavailable(
                        "machine-state persistence id \(lease.persistenceID) has no matching active lease; refusing VM start"
                    )
                }
                return try await startContainerWithLifecycleLocks(
                    request: request,
                    expectedLease: persistedLease
                )
            }
        }
    }

    private func startContainerWithLifecycleLocks(
        request: Runtime_V1_StartContainerRequest,
        expectedLease: CRIShimMachineStateLease? = nil
    ) async throws -> Runtime_V1_StartContainerResponse {
        try await withContainerLifecycleLock(id: request.containerID) {
            let initialMetadata = try containerMetadata(
                id: request.containerID,
                operation: "StartContainer"
            )
            return try await withSandboxLifecycleLock(id: initialMetadata.sandboxID) {
                let metadata = try containerMetadata(
                    id: request.containerID,
                    operation: "StartContainer"
                )
                guard metadata.state == .created else {
                    throw CRIShimError.invalidArgument(
                        "StartContainer requires a created container, got \(metadata.state.rawValue)"
                    )
                }
                let sandbox = try sandboxMetadata(id: metadata.sandboxID, operation: "StartContainer")
                guard sandbox.state.allowsContainerCreation else {
                    throw CRIShimError.invalidArgument(
                        "StartContainer requires a ready or running sandbox, got \(sandbox.state.rawValue)"
                    )
                }
                if let expectedLease {
                    guard let currentLease = try machineStateLease(for: sandbox),
                        currentLease.hasSameBinding(as: expectedLease),
                        let policy = config.machineState
                    else {
                        throw CRIShimError.unavailable(
                            "machine-state lease identity changed while starting the sandbox"
                        )
                    }
                    guard
                        let persistedLease = try CRIShimMachineStateLeaseStore.load(
                            policy: policy,
                            persistenceID: currentLease.persistenceID
                        ), persistedLease == expectedLease
                    else {
                        throw CRIShimError.unavailable(
                            "machine-state lease changed while starting the sandbox"
                        )
                    }
                }
                if sandbox.state == .ready {
                    let runtimeHandler = sandbox.runtimeHandler.trimmed.isEmpty ? nil : sandbox.runtimeHandler
                    let handler = try config.resolveRuntimeHandler(runtimeHandler)
                    if let expectedLease, let policy = config.machineState {
                        _ = try CRIShimMachineStateLeaseStore.markSidecarLaunchMayHaveStarted(
                            policy: policy,
                            expected: expectedLease
                        )
                    }
                    try await runtimeManager.startSandbox(id: sandbox.runtimeSandboxID, presentGUI: handler.guiEnabled)
                    _ = try metadataStore.updateSandbox(id: sandbox.id) { current in
                        if current.state == .ready {
                            current.state = .running
                            current.updatedAt = Date()
                        }
                    }
                }

                let workloadSnapshot = try await runtimeManager.inspectWorkload(
                    sandboxID: sandbox.runtimeSandboxID,
                    workloadID: metadata.runtimeWorkloadID
                )
                try await logManager.start(
                    container: metadata,
                    workloadSnapshot: workloadSnapshot
                )

                do {
                    try await runtimeManager.startWorkload(
                        sandboxID: sandbox.runtimeSandboxID,
                        workloadID: metadata.runtimeWorkloadID
                    )
                } catch {
                    await logManager.stop(containerID: metadata.id, removeState: false)
                    throw error
                }
                let startedWorkloadSnapshot = try await runtimeManager.inspectWorkload(
                    sandboxID: sandbox.runtimeSandboxID,
                    workloadID: metadata.runtimeWorkloadID
                )

                let startedAt = Date()
                guard
                    let updated = try metadataStore.updateContainer(
                        id: metadata.id,
                        expectedLifecycleVersion: metadata.lifecycleVersion,
                        { current in
                            guard current.state == .created else {
                                return
                            }
                            current.state = .running
                            current.startedAt = startedAt
                            current.exitedAt = nil
                            current.adoptionReceipt = startedWorkloadSnapshot.adoptionReceipt
                        })
                else {
                    throw CRIShimMetadataStoreError.notFound(kind: .container, id: metadata.id)
                }
                guard updated.state == .running else {
                    throw CRIShimError.internalError("container lifecycle changed while StartContainer was in progress")
                }
                return Runtime_V1_StartContainerResponse()
            }
        }
    }

    public func stopContainer(
        request: Runtime_V1_StopContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_StopContainerResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.stopContainer.rawValue) {
            try await withContainerLifecycleLock(id: request.containerID) {
                let initialMetadata = try containerMetadata(
                    id: request.containerID,
                    operation: "StopContainer"
                )
                return try await withSandboxLifecycleLock(id: initialMetadata.sandboxID) {
                    let metadata = try containerMetadata(
                        id: request.containerID,
                        operation: "StopContainer"
                    )
                    let options = try makeCRIShimStopOptions(request)
                    if metadata.state == .exited {
                        return Runtime_V1_StopContainerResponse()
                    }
                    guard metadata.state == .running else {
                        throw CRIShimError.invalidArgument(
                            "StopContainer requires a running container, got \(metadata.state.rawValue)"
                        )
                    }
                    let sandbox = try sandboxMetadata(id: metadata.sandboxID, operation: "StopContainer")

                    var stopError: (any Error)?
                    do {
                        try await runtimeManager.stopWorkload(
                            sandboxID: sandbox.runtimeSandboxID,
                            workloadID: metadata.runtimeWorkloadID,
                            options: options
                        )
                    } catch {
                        stopError = error
                    }

                    guard
                        let observation = await waitForStoppedWorkload(
                            metadata: metadata,
                            stopOptions: options
                        )
                    else {
                        if let stopError {
                            throw stopError
                        }
                        throw CRIShimError.internalError(
                            "workload did not reach a terminal state after StopContainer"
                        )
                    }

                    let observedAt = Date()
                    guard
                        let updated = try metadataStore.updateContainer(
                            id: metadata.id,
                            expectedLifecycleVersion: metadata.lifecycleVersion,
                            { current in
                                switch observation {
                                case .snapshot(let snapshot):
                                    current = current.applying(workloadSnapshot: snapshot)
                                case .missing:
                                    current.recordUnknownExit(at: observedAt)
                                }
                            })
                    else {
                        throw CRIShimMetadataStoreError.notFound(kind: .container, id: metadata.id)
                    }
                    guard updated.state == .exited || updated.state == .removed else {
                        throw CRIShimError.internalError(
                            "workload terminal state could not be persisted after StopContainer"
                        )
                    }
                    await logManager.stop(containerID: metadata.id, removeState: false)
                    return Runtime_V1_StopContainerResponse()
                }
            }
        }
    }

    public func removeContainer(
        request: Runtime_V1_RemoveContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_RemoveContainerResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.removeContainer.rawValue) {
            try await withContainerLifecycleLock(id: request.containerID) {
                let initialMetadata = try containerMetadata(
                    id: request.containerID,
                    operation: "RemoveContainer"
                )
                return try await withSandboxLifecycleLock(id: initialMetadata.sandboxID) {
                    let storedMetadata = try containerMetadata(
                        id: request.containerID,
                        operation: "RemoveContainer"
                    )
                    guard
                        let reconciled = try await reconciledContainerMetadataLocked(
                            storedMetadata,
                            includeRuntimeDetailsForExitedContainer: false
                        )
                    else {
                        throw CRIShimMetadataStoreError.notFound(kind: .container, id: storedMetadata.id)
                    }
                    let metadata = reconciled.metadata
                    guard metadata.state != .running else {
                        throw CRIShimError.invalidArgument("RemoveContainer requires a stopped container")
                    }

                    if let sandbox = try metadataStore.sandbox(id: metadata.sandboxID),
                        sandbox.state == .ready || sandbox.state == .running
                    {
                        do {
                            try await runtimeManager.removeWorkload(
                                sandboxID: sandbox.runtimeSandboxID,
                                workloadID: metadata.runtimeWorkloadID
                            )
                        } catch {
                            try throwUnlessNotFound(error)
                        }
                    }
                    await logManager.stop(containerID: metadata.id, removeState: true)
                    try metadataStore.deleteContainer(id: metadata.id)
                    return Runtime_V1_RemoveContainerResponse()
                }
            }
        }
    }

    public func containerStatus(
        request: Runtime_V1_ContainerStatusRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ContainerStatusResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.containerStatus.rawValue) {
            let containerID = request.containerID.trimmed
            guard !containerID.isEmpty else {
                throw CRIShimError.invalidArgument("ContainerStatus container_id is required")
            }

            guard let storedMetadata = try metadataStore.container(id: containerID) else {
                throw CRIShimMetadataStoreError.notFound(kind: .container, id: containerID)
            }
            guard
                let reconciled = try await reconciledContainerMetadata(
                    storedMetadata,
                    includeRuntimeDetailsForExitedContainer: true
                )
            else {
                throw CRIShimMetadataStoreError.notFound(kind: .container, id: containerID)
            }

            var response = Runtime_V1_ContainerStatusResponse()
            response.status = makeCRIContainerStatus(
                reconciled.metadata,
                workloadSnapshot: reconciled.workloadSnapshot
            )
            if request.verbose {
                response.info = makeCRIStatusInfo(reconciled.metadata)
            }
            return response
        }
    }

    public func containerStats(
        request: Runtime_V1_ContainerStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ContainerStatsResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.containerStats.rawValue) {
            let metadata = try containerMetadata(
                id: request.containerID,
                operation: "ContainerStats"
            )
            var response = Runtime_V1_ContainerStatsResponse()
            response.stats = makeCRIContainerStats(metadata)
            return response
        }
    }

    public func listContainerStats(
        request: Runtime_V1_ListContainerStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListContainerStatsResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.listContainerStats.rawValue) {
            var response = Runtime_V1_ListContainerStatsResponse()
            response.stats = try filterCRIContainers(metadataStore.listContainers(), request: request)
                .map(makeCRIContainerStats)
            return response
        }
    }

    public func podSandboxStats(
        request: Runtime_V1_PodSandboxStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_PodSandboxStatsResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.podSandboxStats.rawValue) {
            let metadata = try sandboxMetadata(
                id: request.podSandboxID,
                operation: "PodSandboxStats"
            )
            var response = Runtime_V1_PodSandboxStatsResponse()
            response.stats = makeCRIPodSandboxStats(metadata)
            return response
        }
    }

    public func listPodSandboxStats(
        request: Runtime_V1_ListPodSandboxStatsRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ListPodSandboxStatsResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.listPodSandboxStats.rawValue) {
            var response = Runtime_V1_ListPodSandboxStatsResponse()
            response.stats = try filterCRIPodSandboxes(metadataStore.listSandboxes(), request: request)
                .map(makeCRIPodSandboxStats)
            return response
        }
    }

    public func reopenContainerLog(
        request: Runtime_V1_ReopenContainerLogRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Runtime_V1_ReopenContainerLogResponse {
        try await handlerLogger.handle(operation: CRIRuntimeOperation.reopenContainerLog.rawValue) {
            let metadata = try containerMetadata(
                id: request.containerID,
                operation: "ReopenContainerLog"
            )
            try await logManager.reopen(container: metadata)
            return Runtime_V1_ReopenContainerLogResponse()
        }
    }

    private func containerMetadata(id rawID: String, operation: String) throws -> CRIShimContainerMetadata {
        let containerID = rawID.trimmed
        guard !containerID.isEmpty else {
            throw CRIShimError.invalidArgument("\(operation) container_id is required")
        }
        guard let metadata = try metadataStore.container(id: containerID) else {
            throw CRIShimMetadataStoreError.notFound(kind: .container, id: containerID)
        }
        return metadata
    }

    private func reconciledContainerMetadata(
        _ metadata: CRIShimContainerMetadata,
        includeRuntimeDetailsForExitedContainer: Bool = false
    ) async throws -> (metadata: CRIShimContainerMetadata, workloadSnapshot: WorkloadSnapshot?)? {
        try await withContainerLifecycleLock(id: metadata.id) {
            try await withSandboxLifecycleLock(id: metadata.sandboxID) {
                guard let current = try metadataStore.container(id: metadata.id) else {
                    return nil
                }
                return try await reconciledContainerMetadataLocked(
                    current,
                    includeRuntimeDetailsForExitedContainer: includeRuntimeDetailsForExitedContainer
                )
            }
        }
    }

    private func reconciledContainerMetadataLocked(
        _ metadata: CRIShimContainerMetadata,
        includeRuntimeDetailsForExitedContainer: Bool
    ) async throws -> (metadata: CRIShimContainerMetadata, workloadSnapshot: WorkloadSnapshot?)? {
        if !includeRuntimeDetailsForExitedContainer,
            metadata.state == .exited || metadata.state == .removed
        {
            return (metadata, nil)
        }

        let observation = try await confirmedWorkloadObservation(for: metadata)
        let observedAt = Date()
        guard
            let reconciledMetadata = try metadataStore.updateContainer(
                id: metadata.id,
                expectedLifecycleVersion: metadata.lifecycleVersion,
                { currentMetadata in
                    switch observation {
                    case .snapshot(let workloadSnapshot):
                        currentMetadata = currentMetadata.applying(workloadSnapshot: workloadSnapshot)
                    case .missing:
                        currentMetadata.recordUnknownExit(at: observedAt)
                    }
                })
        else {
            return nil
        }

        if metadata.state == .running, reconciledMetadata.state == .exited {
            await logManager.stop(containerID: metadata.id, removeState: false)
        }
        let workloadSnapshot: WorkloadSnapshot?
        switch observation {
        case .snapshot(let snapshot):
            workloadSnapshot = snapshot
        case .missing:
            workloadSnapshot = nil
        }
        return (reconciledMetadata, workloadSnapshot)
    }

    private func confirmedWorkloadObservation(
        for metadata: CRIShimContainerMetadata,
        confirmSuccessfulTerminal: Bool = false
    ) async throws -> CRIShimWorkloadObservation {
        let runtimeSandboxID =
            try metadataStore.sandbox(id: metadata.sandboxID)?.runtimeSandboxID
            ?? metadata.sandboxID
        let requiresConfirmation = metadata.state == .created || metadata.state == .running
        let attempts = requiresConfirmation ? criShimLifecycleConfirmationAttempts : 1
        var inconclusiveSnapshot: WorkloadSnapshot?
        var successfulTerminalSnapshot: WorkloadSnapshot?
        var consecutiveSuccessfulTerminalObservations = 0

        for attempt in 0..<attempts {
            do {
                let snapshot = try await runtimeManager.inspectWorkload(
                    sandboxID: runtimeSandboxID,
                    workloadID: metadata.runtimeWorkloadID
                )
                switch snapshot.status {
                case .running, .stopping:
                    return .snapshot(snapshot)
                case .stopped:
                    if hasCompleteRuntimeExit(snapshot) {
                        guard confirmSuccessfulTerminal, snapshot.exitCode == 0 else {
                            return .snapshot(snapshot)
                        }
                        successfulTerminalSnapshot = snapshot
                        consecutiveSuccessfulTerminalObservations += 1
                        if consecutiveSuccessfulTerminalObservations >= criShimLifecycleConfirmationAttempts {
                            return .snapshot(snapshot)
                        }
                    } else {
                        successfulTerminalSnapshot = nil
                        consecutiveSuccessfulTerminalObservations = 0
                        inconclusiveSnapshot = snapshot
                    }
                case .unknown:
                    successfulTerminalSnapshot = nil
                    consecutiveSuccessfulTerminalObservations = 0
                    inconclusiveSnapshot = snapshot
                }
            } catch {
                successfulTerminalSnapshot = nil
                consecutiveSuccessfulTerminalObservations = 0
                guard isNotFound(error) else {
                    throw error
                }
            }

            if attempt < attempts - 1 {
                try await Task.sleep(for: criShimLifecycleConfirmationInterval)
            }
        }

        if let successfulTerminalSnapshot {
            return .snapshot(successfulTerminalSnapshot)
        }
        if let inconclusiveSnapshot {
            return .snapshot(inconclusiveSnapshot)
        }
        return .missing
    }

    private func waitForStoppedWorkload(
        metadata: CRIShimContainerMetadata,
        stopOptions: ContainerStopOptions
    ) async -> CRIShimStoppedWorkloadObservation? {
        let runtimeSandboxID =
            (try? metadataStore.sandbox(id: metadata.sandboxID))?.runtimeSandboxID
            ?? metadata.sandboxID
        let confirmationSeconds = max(30, Int(stopOptions.timeoutInSeconds) + 5)
        let attempts = confirmationSeconds * 10
        var consecutiveMissingObservations = 0
        var consecutiveMissingSandboxObservations = 0
        var consecutiveStoppedSandboxObservations = 0
        var incompleteStoppedSnapshot: WorkloadSnapshot?
        var consecutiveIncompleteStoppedObservations = 0
        var successfulStoppedSnapshot: WorkloadSnapshot?
        var consecutiveSuccessfulStoppedObservations = 0
        let confirmSuccessfulTerminal = stopOptions.signal == String(SIGKILL)
        for attempt in 0..<attempts {
            do {
                let snapshot = try await runtimeManager.inspectWorkload(
                    sandboxID: runtimeSandboxID,
                    workloadID: metadata.runtimeWorkloadID
                )
                consecutiveMissingObservations = 0
                if snapshot.status == .stopped {
                    if hasCompleteRuntimeExit(snapshot) {
                        guard confirmSuccessfulTerminal, snapshot.exitCode == 0 else {
                            return .snapshot(snapshot)
                        }
                        successfulStoppedSnapshot = snapshot
                        consecutiveSuccessfulStoppedObservations += 1
                        if consecutiveSuccessfulStoppedObservations >= criShimLifecycleConfirmationAttempts {
                            return .snapshot(snapshot)
                        }
                    } else {
                        successfulStoppedSnapshot = nil
                        consecutiveSuccessfulStoppedObservations = 0
                        incompleteStoppedSnapshot = snapshot
                        consecutiveIncompleteStoppedObservations += 1
                        if consecutiveIncompleteStoppedObservations >= criShimLifecycleConfirmationAttempts {
                            return .snapshot(snapshot)
                        }
                    }
                } else {
                    successfulStoppedSnapshot = nil
                    consecutiveSuccessfulStoppedObservations = 0
                    incompleteStoppedSnapshot = nil
                    consecutiveIncompleteStoppedObservations = 0
                }
            } catch {
                successfulStoppedSnapshot = nil
                consecutiveSuccessfulStoppedObservations = 0
                if isNotFound(error) {
                    consecutiveMissingObservations += 1
                } else {
                    consecutiveMissingObservations = 0
                }
            }

            do {
                let sandboxSnapshot = try await runtimeManager.inspectSandbox(id: runtimeSandboxID)
                consecutiveMissingSandboxObservations = 0
                if sandboxSnapshot.status == .stopped {
                    consecutiveStoppedSandboxObservations += 1
                } else {
                    consecutiveStoppedSandboxObservations = 0
                }
            } catch {
                consecutiveStoppedSandboxObservations = 0
                if isNotFound(error) {
                    consecutiveMissingSandboxObservations += 1
                } else {
                    consecutiveMissingSandboxObservations = 0
                }
            }
            if consecutiveMissingObservations >= criShimLifecycleConfirmationAttempts
                || consecutiveMissingSandboxObservations >= criShimLifecycleConfirmationAttempts
                || consecutiveStoppedSandboxObservations >= criShimLifecycleConfirmationAttempts
            {
                if let successfulStoppedSnapshot {
                    return .snapshot(successfulStoppedSnapshot)
                }
                return incompleteStoppedSnapshot.map(CRIShimStoppedWorkloadObservation.snapshot) ?? .missing
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if let successfulStoppedSnapshot {
            return .snapshot(successfulStoppedSnapshot)
        }
        return incompleteStoppedSnapshot.map(CRIShimStoppedWorkloadObservation.snapshot)
    }

    private func waitForStoppedSandbox(
        metadata: CRIShimSandboxMetadata,
        stopOptions: ContainerStopOptions
    ) async -> Bool {
        let confirmationSeconds = max(30, Int(stopOptions.timeoutInSeconds) + 5)
        let attempts = confirmationSeconds * 10
        var consecutiveMissingObservations = 0
        for attempt in 0..<attempts {
            do {
                let snapshot = try await runtimeManager.inspectSandbox(id: metadata.runtimeSandboxID)
                consecutiveMissingObservations = 0
                if snapshot.status == .stopped {
                    return true
                }
            } catch {
                if isNotFound(error) {
                    consecutiveMissingObservations += 1
                    if consecutiveMissingObservations >= criShimLifecycleConfirmationAttempts {
                        return true
                    }
                } else {
                    consecutiveMissingObservations = 0
                }
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return false
    }

    private func reconciledSandboxObservationLocked(
        for metadata: CRIShimSandboxMetadata,
        hasActiveContainers: Bool
    ) async throws -> (metadata: CRIShimSandboxMetadata, snapshot: SandboxSnapshot?)? {
        switch try await confirmedSandboxObservation(for: metadata) {
        case .snapshot(let snapshot):
            var observed = metadata.applying(sandboxSnapshot: snapshot)
            if hasActiveContainers,
                snapshot.status != .running,
                snapshot.failureReason != .networkInvalidated
            {
                observed.state = metadata.state
            }
            return (observed, snapshot)
        case .missing:
            guard !hasActiveContainers else {
                return (metadata, nil)
            }
            let observedAt = Date()
            guard
                let updated = try metadataStore.updateSandbox(
                    id: metadata.id,
                    { current in
                        if current.state != .stopped, current.state != .released {
                            current.state = .stopped
                            current.updatedAt = observedAt
                        }
                    })
            else {
                return nil
            }
            return (updated, nil)
        }
    }

    private func confirmedSandboxObservation(
        for metadata: CRIShimSandboxMetadata
    ) async throws -> CRIShimSandboxObservation {
        let requiresConfirmation = metadata.state == .pending || metadata.state == .ready || metadata.state == .running
        let attempts = requiresConfirmation ? criShimLifecycleConfirmationAttempts : 1
        var inconclusiveSnapshot: SandboxSnapshot?
        for attempt in 0..<attempts {
            do {
                let snapshot = try await runtimeManager.inspectSandbox(id: metadata.runtimeSandboxID)
                if snapshot.status == .running {
                    return .snapshot(snapshot)
                }
                inconclusiveSnapshot = snapshot
            } catch {
                guard isNotFound(error) else {
                    throw error
                }
            }
            if attempt < attempts - 1 {
                try await Task.sleep(for: criShimLifecycleConfirmationInterval)
            }
        }
        if let inconclusiveSnapshot {
            return .snapshot(inconclusiveSnapshot)
        }
        return .missing
    }

    private func withContainerLifecycleLock<Result>(
        id: String,
        _ operation: () async throws -> Result
    ) async throws -> Result {
        try await withLifecycleLock(key: "container:\(id.trimmed)", operation)
    }

    private func withSandboxLifecycleLock<Result>(
        id: String,
        _ operation: () async throws -> Result
    ) async throws -> Result {
        try await withLifecycleLock(key: "sandbox:\(id.trimmed)", operation)
    }

    private func withLifecycleLock<Result>(
        key: String,
        _ operation: () async throws -> Result
    ) async throws -> Result {
        await lifecycleCoordinator.acquire(key)
        do {
            let result = try await operation()
            await lifecycleCoordinator.release(key)
            return result
        } catch {
            await lifecycleCoordinator.release(key)
            throw error
        }
    }

    private func sandboxMetadata(id rawID: String, operation: String) throws -> CRIShimSandboxMetadata {
        let sandboxID = rawID.trimmed
        guard !sandboxID.isEmpty else {
            throw CRIShimError.invalidArgument("\(operation) sandbox id is required")
        }
        guard let metadata = try metadataStore.sandbox(id: sandboxID) else {
            throw CRIShimMetadataStoreError.notFound(kind: .sandbox, id: sandboxID)
        }
        return metadata
    }

    private func machineStateLease(
        for metadata: CRIShimSandboxMetadata
    ) throws -> CRIShimMachineStateLease? {
        guard metadata.annotations[CRIShimMachineStateAnnotation.enabled] == "true" else {
            return nil
        }
        guard config.machineState != nil else {
            throw CRIShimError.internalError("persisted machine-state lease policy is unavailable")
        }
        let values = try decodeEnabledMachineStateAnnotationValues(metadata.annotations)
        guard let podUID = metadata.podUID?.trimmed, !podUID.isEmpty else {
            throw CRIShimError.internalError("persisted machine-state lease identity is incomplete")
        }
        return CRIShimMachineStateLease(
            persistenceID: values.persistenceID,
            podUID: podUID,
            sandboxID: metadata.id,
            runtimeSandboxID: metadata.runtimeSandboxID,
            restoreStateID: values.restoreStateID,
            restoreStateGeneration: values.restoreStateGeneration,
            storageGeneration: values.storageGeneration
        )
    }

    private func stopSandboxResources(metadata: inout CRIShimSandboxMetadata) async throws {
        var firstError: (any Error)?
        func record(_ error: any Error) {
            if firstError == nil {
                firstError = error
            }
        }

        let containers = try metadataStore.listContainers()
            .filter { $0.sandboxID == metadata.id }
        var sandboxStopped = metadata.state == .stopped

        if !sandboxStopped {
            do {
                try await runtimeManager.stopSandbox(
                    id: metadata.runtimeSandboxID,
                    options: criShimPodSandboxStopOptions
                )
                sandboxStopped = true
            } catch {
                let isStopped = await waitForStoppedSandbox(
                    metadata: metadata,
                    stopOptions: criShimPodSandboxStopOptions
                )
                if isStopped {
                    sandboxStopped = true
                } else {
                    record(error)
                }
            }
        }

        if sandboxStopped {
            let stoppedAt = Date()
            guard
                let stoppedMetadata = try metadataStore.updateSandbox(
                    id: metadata.id,
                    { current in
                        if current.state != .released {
                            current.state = .stopped
                            current.updatedAt = stoppedAt
                        }
                    })
            else {
                throw CRIShimMetadataStoreError.notFound(kind: .sandbox, id: metadata.id)
            }
            metadata = stoppedMetadata

            let finalSandboxObservation = try? await confirmedSandboxObservation(for: metadata)
            let finalSandboxSnapshot: SandboxSnapshot?
            if case .snapshot(let snapshot) = finalSandboxObservation {
                finalSandboxSnapshot = snapshot
            } else {
                finalSandboxSnapshot = nil
            }
            let finalWorkloads = workloadSnapshotsByID(finalSandboxSnapshot)
            for container in containers where container.state == .created || container.state == .running {
                var finalWorkloadSnapshot = finalWorkloads[container.runtimeWorkloadID]
                if finalWorkloadSnapshot.map(hasCompleteRuntimeExit) != true || finalWorkloadSnapshot?.exitCode == 0,
                    let observation = try? await confirmedWorkloadObservation(
                        for: container,
                        confirmSuccessfulTerminal: true
                    ),
                    case .snapshot(let snapshot) = observation
                {
                    finalWorkloadSnapshot = snapshot
                }

                _ = try metadataStore.updateContainer(id: container.id) { current in
                    if let finalWorkloadSnapshot, finalWorkloadSnapshot.status == .stopped {
                        current = current.applying(workloadSnapshot: finalWorkloadSnapshot)
                    } else if current.state == .created || current.state == .running {
                        current.recordUnknownExit(at: stoppedAt)
                    }
                }
                await logManager.stop(containerID: container.id, removeState: false)
            }
        }

        if config.networkPolicy?.enabled == true {
            do {
                try await runtimeManager.removeSandboxPolicy(sandboxID: metadata.runtimeSandboxID)
            } catch {
                if !isNotFound(error) {
                    record(error)
                }
            }
        }

        if let networkName = sandboxNetworkName(metadata) {
            do {
                if let identityManager = cniManager as? any CRIShimCNIIdentityManaging {
                    try await identityManager.delete(
                        identity: cniSandboxIdentity(metadata),
                        networkName: networkName,
                        config: config
                    )
                } else {
                    try await cniManager.delete(
                        sandboxID: metadata.runtimeSandboxID,
                        networkName: networkName,
                        config: config
                    )
                }
            } catch {
                record(error)
            }
        }

        if let firstError {
            throw firstError
        }

        guard
            let updatedMetadata = try metadataStore.updateSandbox(
                id: metadata.id,
                { current in
                    current.networkLeaseID = nil
                    current.networkAttachments = []
                    if current.state != .released {
                        current.state = .stopped
                        current.updatedAt = Date()
                    }
                })
        else {
            throw CRIShimMetadataStoreError.notFound(kind: .sandbox, id: metadata.id)
        }
        metadata = updatedMetadata
    }

    private func resolveSandboxImage(reference: String) async throws -> CRIShimImageRecord {
        if let image = try await findOptionalImage(reference: reference) {
            return image
        }
        return try await imageManager.pullImage(reference: reference, authentication: nil)
    }

    private func sandboxImageReference(
        request: Runtime_V1_RunPodSandboxRequest,
        handler: ResolvedRuntimeHandler
    ) throws -> String {
        guard let override = request.config.annotations[CRIShimPodAnnotation.sandboxImage] else {
            return handler.sandboxImage
        }
        let reference = override.trimmed
        guard !reference.isEmpty else {
            throw CRIShimError.invalidArgument("\(CRIShimPodAnnotation.sandboxImage) annotation must not be empty")
        }
        return reference
    }

    private func findImage(reference: String) async throws -> CRIShimImageRecord {
        if let image = try await findOptionalImage(reference: reference) {
            return image
        }
        throw CRIShimError.notFound("image not found: \(reference)")
    }

    private func findOptionalImage(reference: String) async throws -> CRIShimImageRecord? {
        let images = try await imageManager.listImages()
        return images.first(where: { $0.matches(reference: reference) })
    }
}

private func sandboxNetworkName(_ metadata: CRIShimSandboxMetadata) -> String? {
    guard metadata.networkLeaseID != nil || !metadata.networkAttachments.isEmpty else {
        return nil
    }
    if let network = metadata.network?.trimmed, !network.isEmpty {
        return network
    }
    return metadata.networkAttachments.first(where: { !$0.trimmed.isEmpty })
}

private func cniSandboxIdentity(_ metadata: CRIShimSandboxMetadata) -> CRIShimCNISandboxIdentity {
    CRIShimCNISandboxIdentity(
        runtimeSandboxID: metadata.runtimeSandboxID,
        criSandboxID: metadata.id,
        restoreRequestID: metadata.annotations[CRIShimMachineStateAnnotation.restoreRequestID],
        podUID: metadata.podUID
    )
}

private func workloadSnapshotsByID(_ sandboxSnapshot: SandboxSnapshot?) -> [String: WorkloadSnapshot] {
    guard let sandboxSnapshot else {
        return [:]
    }
    return sandboxSnapshot.workloads.reduce(into: [:]) { snapshots, workload in
        snapshots[workload.id] = workload
    }
}

private func hasCompleteRuntimeExit(_ snapshot: WorkloadSnapshot) -> Bool {
    snapshot.status == .stopped
        && snapshot.exitCode != nil
        && (snapshot.exitedAt?.timeIntervalSince1970 ?? 0) > 0
}

private func isNotFound(_ error: any Error) -> Bool {
    if CRIShimErrorMapper.disposition(for: error).kind == .notFound {
        return true
    }
    if let error = error as? ContainerizationError, let cause = error.cause {
        return isNotFound(cause)
    }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
        return true
    }
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(POSIXErrorCode.ENOENT.rawValue) {
        return true
    }
    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? any Error, isNotFound(underlyingError) {
        return true
    }
    let description = String(describing: error)
    if description.contains("notFound:") {
        return true
    }
    if description.contains("NSCocoaErrorDomain Code=\(NSFileNoSuchFileError)")
        || description.contains("NSPOSIXErrorDomain Code=\(Int(POSIXErrorCode.ENOENT.rawValue))")
        || description.contains("No such file or directory")
    {
        return true
    }
    return false
}

private func throwUnlessNotFound(_ error: any Error) throws {
    if !isNotFound(error) {
        throw error
    }
}

extension CRIShimSandboxMetadata.State {
    fileprivate var allowsContainerCreation: Bool {
        switch self {
        case .ready, .running:
            return true
        case .pending, .stopped, .released:
            return false
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
            let references = Array(
                Set(
                    try await imageManager.listImages()
                        .filter { $0.matches(reference: reference) }
                        .map(\.reference)
                )
            ).sorted()
            try await imageManager.removeImages(references: references)
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
            case .unavailable:
                .unavailable
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
        try await CRIShimGRPCHandlerLogger.runtimeService().handle(
            operation: CRIRuntimeOperation.runPodSandbox.rawValue
        ) {
            try CRIShimUnsupportedFieldValidator.validate(request)
            throw CRIShimGRPCStatusMapper.unsupportedError(.runPodSandbox)
        }
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
        try await CRIShimGRPCHandlerLogger.runtimeService().handle(
            operation: CRIRuntimeOperation.createContainer.rawValue
        ) {
            try CRIShimUnsupportedFieldValidator.validate(request)
            throw CRIShimGRPCStatusMapper.unsupportedError(.createContainer)
        }
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
