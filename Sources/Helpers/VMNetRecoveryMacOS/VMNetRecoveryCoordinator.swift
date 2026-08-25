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

import ContainerCRIShimMacOS
import ContainerNetworkClient
import ContainerResource
import Foundation
import Logging

struct VMNetRecoveryVerification: Sendable, Equatable {
    let networkInstanceID: String
}

enum VMNetRecoveryCoordinatorResult: Sendable, Equatable {
    case disabled
    case idle
    case initialized(networkInstanceID: String)
    case rebootRequested
    case waitingForReboot
    case waitingForHealthyProbe(attempt: Int, reason: String)
    case waitingForVerification(String)
    case recovered(networkInstanceID: String)
    case blocked(String)
}

struct VMNetRecoveryCoordinatorDependencies: Sendable {
    var currentBootSessionID: @Sendable () throws -> String
    var now: @Sendable () -> Date
    var reboot: @Sendable () async throws -> Void
    var observe: @Sendable (CRIShimConfig) async throws -> VMNetRecoveryVerification
    var verify: @Sendable (CRIShimConfig, String?) async throws -> VMNetRecoveryVerification

    static let live = VMNetRecoveryCoordinatorDependencies(
        currentBootSessionID: { try VMNetBootSession.current() },
        now: Date.init,
        reboot: VMNetRecoverySystem.reboot,
        observe: VMNetRecoverySystem.observe,
        verify: VMNetRecoverySystem.verify
    )
}

private actor VMNetRecoveryHealthyProbeTracker {
    private var consecutiveFailures = 0

    func recordSuccess() {
        consecutiveFailures = 0
    }

    func recordFailure() -> Int {
        consecutiveFailures += 1
        return consecutiveFailures
    }
}

struct VMNetRecoveryCoordinator: Sendable {
    let config: CRIShimConfig
    let dependencies: VMNetRecoveryCoordinatorDependencies
    let log: Logger
    private let healthyProbeTracker: VMNetRecoveryHealthyProbeTracker
    private let statusRecorder: VMNetRecoveryStatusRecorder?

    init(
        config: CRIShimConfig,
        dependencies: VMNetRecoveryCoordinatorDependencies = .live,
        statusRecorder: VMNetRecoveryStatusRecorder? = nil,
        log: Logger
    ) {
        self.config = config
        self.dependencies = dependencies
        self.healthyProbeTracker = VMNetRecoveryHealthyProbeTracker()
        let recovery = config.resolvedVMNetRecoveryConfig
        if let statusRecorder {
            self.statusRecorder = statusRecorder
        } else if recovery.statusPath == CRIShimConfigDefaults.vmnetRecoveryStatusURL.path {
            self.statusRecorder = VMNetRecoveryStatusRecorder(
                store: VMNetRecoveryStatusFileStore(url: CRIShimConfigDefaults.vmnetRecoveryStatusURL)
            )
        } else {
            self.statusRecorder = nil
        }
        self.log = log
    }

    func run() async throws {
        let pollSeconds = max(1, config.resolvedVMNetRecoveryConfig.pollIntervalSeconds)
        recordStatusBestEffort(
            event: .starting,
            currentBootSessionID: try? dependencies.currentBootSessionID()
        )
        defer { removeStatusBestEffort() }
        var previousResult: VMNetRecoveryCoordinatorResult?
        while !Task.isCancelled {
            let result: VMNetRecoveryCoordinatorResult
            do {
                result = try await reconcileOnce()
            } catch {
                if error is CancellationError {
                    throw error
                }
                result = .blocked("reconciliation failed: \(error)")
            }
            if result == .disabled {
                removeStatusBestEffort()
            } else {
                recordStatusBestEffort(
                    event: .result(result),
                    currentBootSessionID: try? dependencies.currentBootSessionID()
                )
            }
            if result != previousResult {
                logResult(result)
                previousResult = result
            }
            try await Task.sleep(for: .seconds(pollSeconds))
        }
    }

    func reconcileOnce() async throws -> VMNetRecoveryCoordinatorResult {
        guard let podNetwork = config.podNetwork,
            podNetwork.enabled == true,
            podNetwork.vmnetDisconnectRecovery == .rebootNode,
            let networkName = podNetwork.networkName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !networkName.isEmpty,
            let statePath = config.resolvedVMNetRecoveryConfig.statePath,
            let requestPath = config.resolvedVMNetRecoveryConfig.requestPath
        else {
            return .disabled
        }

        let recovery = config.resolvedVMNetRecoveryConfig
        let store = VMNetRecoveryStateStore(path: statePath)
        let requestStore = VMNetRecoveryRequestStore(path: requestPath)
        let bootSessionID = try dependencies.currentBootSessionID()
        let now = dependencies.now()
        do {
            try consumePendingRequest(
                requestStore: requestStore,
                stateStore: store,
                networkName: networkName,
                currentBootSessionID: bootSessionID,
                recovery: recovery
            )
        } catch {
            return .blocked("pending vmnet recovery request is invalid: \(error)")
        }
        guard var state = try store.load() else {
            return await initializeHealthyBaseline(
                store: store,
                networkName: networkName,
                bootSessionID: bootSessionID,
                recovery: recovery,
                now: now
            )
        }
        guard state.networkName == networkName else {
            return .blocked("recovery state network does not match configured network")
        }
        if state.phase == .healthy {
            if state.bootSessionID != bootSessionID {
                return await refreshHealthyBaseline(
                    state: state,
                    store: store,
                    networkName: networkName,
                    bootSessionID: bootSessionID,
                    recovery: recovery,
                    now: now
                )
            }
            let observation: VMNetRecoveryVerification?
            do {
                observation = try await dependencies.observe(config)
            } catch {
                let attempt = await healthyProbeTracker.recordFailure()
                guard attempt >= recovery.healthyProbeFailureThreshold else {
                    return .waitingForHealthyProbe(
                        attempt: attempt,
                        reason: String(describing: error)
                    )
                }
                state = try store.recordFence(
                    networkName: networkName,
                    networkInstanceID: state.networkInstanceID,
                    failureReason: "vmnet helper status probe failed repeatedly",
                    bootSessionID: bootSessionID,
                    attemptWindow: TimeInterval(recovery.attemptWindowSeconds),
                    now: now
                )
                recordStatusBestEffort(event: .fenced, currentBootSessionID: bootSessionID)
                await healthyProbeTracker.recordSuccess()
                observation = nil
            }
            if let observation {
                await healthyProbeTracker.recordSuccess()
                state = try store.recordHealthyObservation(
                    networkName: networkName,
                    networkInstanceID: observation.networkInstanceID,
                    bootSessionID: bootSessionID,
                    attemptWindow: TimeInterval(recovery.attemptWindowSeconds),
                    now: now
                )
                if state.phase == .healthy {
                    return .idle
                }
                recordStatusBestEffort(event: .fenced, currentBootSessionID: bootSessionID)
            }
        } else {
            await healthyProbeTracker.recordSuccess()
        }

        switch state.phase {
        case .healthy:
            return .idle
        case .fenced:
            if state.bootSessionID != bootSessionID {
                state = try store.beginVerification(
                    networkName: networkName,
                    currentBootSessionID: bootSessionID,
                    now: now
                )
                recordStatusBestEffort(event: .verificationStarted, currentBootSessionID: bootSessionID)
                return await verify(
                    state: state,
                    store: store,
                    networkName: networkName,
                    bootSessionID: bootSessionID,
                    recovery: recovery,
                    now: now
                )
            }
            recordStatusBestEffort(event: .fenced, currentBootSessionID: bootSessionID)
            do {
                _ = try store.requestReboot(
                    networkName: networkName,
                    currentBootSessionID: bootSessionID,
                    maxAttempts: recovery.maxRebootAttempts,
                    minimumInterval: TimeInterval(recovery.minimumRebootIntervalSeconds),
                    maximumRequestAge: TimeInterval(recovery.maximumRequestAgeSeconds),
                    now: now
                )
            } catch let error as VMNetRecoveryStateError {
                switch error {
                case .rebootAttemptBudgetExhausted, .rebootIntervalNotElapsed, .rebootRequestTooOld:
                    return .blocked(error.description)
                default:
                    throw error
                }
            }
            try await requestHostReboot(currentBootSessionID: bootSessionID)
            return .rebootRequested
        case .rebootRequested:
            if state.bootSessionID == bootSessionID {
                do {
                    _ = try store.requestReboot(
                        networkName: networkName,
                        currentBootSessionID: bootSessionID,
                        maxAttempts: recovery.maxRebootAttempts,
                        minimumInterval: TimeInterval(recovery.minimumRebootIntervalSeconds),
                        maximumRequestAge: TimeInterval(recovery.maximumRequestAgeSeconds),
                        now: now
                    )
                } catch let error as VMNetRecoveryStateError {
                    switch error {
                    case .rebootIntervalNotElapsed:
                        return .waitingForReboot
                    case .rebootAttemptBudgetExhausted, .rebootRequestTooOld:
                        return .blocked(error.description)
                    default:
                        throw error
                    }
                }
                try await requestHostReboot(currentBootSessionID: bootSessionID)
                return .rebootRequested
            }
            state = try store.beginVerification(
                networkName: networkName,
                currentBootSessionID: bootSessionID,
                now: now
            )
            recordStatusBestEffort(event: .verificationStarted, currentBootSessionID: bootSessionID)
            return await verify(
                state: state,
                store: store,
                networkName: networkName,
                bootSessionID: bootSessionID,
                recovery: recovery,
                now: now
            )
        case .verifying:
            guard state.bootSessionID != bootSessionID else {
                return .blocked("verification requires a new host boot session")
            }
            recordStatusBestEffort(event: .verificationStarted, currentBootSessionID: bootSessionID)
            return await verify(
                state: state,
                store: store,
                networkName: networkName,
                bootSessionID: bootSessionID,
                recovery: recovery,
                now: now
            )
        }
    }

    private func consumePendingRequest(
        requestStore: VMNetRecoveryRequestStore,
        stateStore: VMNetRecoveryStateStore,
        networkName: String,
        currentBootSessionID: String,
        recovery: VMNetRecoveryConfig
    ) throws {
        guard let request = try requestStore.load(expectedWriterUID: recovery.requestWriterUID) else {
            return
        }
        guard request.networkName == networkName else {
            throw VMNetRecoveryStateError.networkMismatch(
                expected: networkName,
                actual: request.networkName
            )
        }
        guard request.bootSessionID.lowercased() == currentBootSessionID.lowercased() else {
            throw VMNetRecoveryStateError.bootSessionMismatch(
                expected: currentBootSessionID,
                actual: request.bootSessionID
            )
        }
        let requestAge = dependencies.now().timeIntervalSince(request.observedAt)
        guard requestAge >= 0,
            requestAge <= TimeInterval(recovery.maximumRequestAgeSeconds)
        else {
            throw VMNetRecoveryStateError.rebootRequestTooOld
        }
        _ = try stateStore.recordFence(
            networkName: networkName,
            networkInstanceID: request.networkInstanceID,
            failureReason: request.failureReason,
            bootSessionID: request.bootSessionID,
            attemptWindow: TimeInterval(recovery.attemptWindowSeconds),
            now: request.observedAt
        )
        recordStatusBestEffort(event: .fenced, currentBootSessionID: currentBootSessionID)
        try requestStore.remove()
    }

    private func initializeHealthyBaseline(
        store: VMNetRecoveryStateStore,
        networkName: String,
        bootSessionID: String,
        recovery: VMNetRecoveryConfig,
        now: Date
    ) async -> VMNetRecoveryCoordinatorResult {
        do {
            let verification = try await dependencies.verify(config, nil)
            _ = try store.recordHealthyObservation(
                networkName: networkName,
                networkInstanceID: verification.networkInstanceID,
                bootSessionID: bootSessionID,
                attemptWindow: TimeInterval(recovery.attemptWindowSeconds),
                now: now
            )
            return .initialized(networkInstanceID: verification.networkInstanceID)
        } catch {
            return .waitingForVerification(String(describing: error))
        }
    }

    private func refreshHealthyBaseline(
        state: VMNetRecoveryStateV1,
        store: VMNetRecoveryStateStore,
        networkName: String,
        bootSessionID: String,
        recovery: VMNetRecoveryConfig,
        now: Date
    ) async -> VMNetRecoveryCoordinatorResult {
        recordStatusBestEffort(event: .verificationStarted, currentBootSessionID: bootSessionID)
        do {
            let verification = try await dependencies.verify(config, state.networkInstanceID)
            _ = try store.recordHealthyObservation(
                networkName: networkName,
                networkInstanceID: verification.networkInstanceID,
                bootSessionID: bootSessionID,
                attemptWindow: TimeInterval(recovery.attemptWindowSeconds),
                now: now
            )
            recordStatusBestEffort(event: .recovered, currentBootSessionID: bootSessionID)
            return .recovered(networkInstanceID: verification.networkInstanceID)
        } catch {
            return .waitingForVerification(String(describing: error))
        }
    }

    private func verify(
        state: VMNetRecoveryStateV1,
        store: VMNetRecoveryStateStore,
        networkName: String,
        bootSessionID: String,
        recovery: VMNetRecoveryConfig,
        now: Date
    ) async -> VMNetRecoveryCoordinatorResult {
        let verificationAge = now.timeIntervalSince(state.updatedAt)
        guard verificationAge >= 0,
            verificationAge <= TimeInterval(recovery.verificationTimeoutSeconds)
        else {
            return .blocked("vmnet recovery verification timed out")
        }
        do {
            let verification = try await dependencies.verify(config, state.networkInstanceID)
            _ = try store.completeVerification(
                networkName: networkName,
                networkInstanceID: verification.networkInstanceID,
                currentBootSessionID: bootSessionID,
                now: now
            )
            recordStatusBestEffort(event: .recovered, currentBootSessionID: bootSessionID)
            return .recovered(networkInstanceID: verification.networkInstanceID)
        } catch {
            return .waitingForVerification(String(describing: error))
        }
    }

    private func requestHostReboot(currentBootSessionID: String) async throws {
        recordStatusBestEffort(event: .rebootCommandRequested, currentBootSessionID: currentBootSessionID)
        do {
            try await dependencies.reboot()
            recordStatusBestEffort(event: .rebootCommandAccepted, currentBootSessionID: currentBootSessionID)
        } catch {
            recordStatusBestEffort(
                event: .rebootCommandFailed(String(describing: error)),
                currentBootSessionID: currentBootSessionID
            )
            throw error
        }
    }

    private func recordStatusBestEffort(
        event: VMNetRecoveryStatusEvent,
        currentBootSessionID: String?
    ) {
        do {
            try statusRecorder?.record(
                event: event,
                config: config,
                currentBootSessionID: currentBootSessionID
            )
        } catch {
            log.error(
                "failed to publish vmnet recovery status",
                metadata: ["reason": "\(error)"]
            )
        }
    }

    private func removeStatusBestEffort() {
        do {
            try statusRecorder?.remove()
        } catch {
            log.error(
                "failed to remove vmnet recovery status",
                metadata: ["reason": "\(error)"]
            )
        }
    }

    private func logResult(_ result: VMNetRecoveryCoordinatorResult) {
        switch result {
        case .initialized(let networkInstanceID):
            log.notice(
                "vmnet recovery healthy baseline initialized",
                metadata: ["network_instance_id": "\(networkInstanceID)"]
            )
        case .rebootRequested:
            log.critical("requested host reboot for vmnet recovery")
        case .recovered(let networkInstanceID):
            log.notice(
                "vmnet recovery verification passed",
                metadata: ["network_instance_id": "\(networkInstanceID)"]
            )
        case .blocked(let reason):
            log.error("vmnet recovery is blocked", metadata: ["reason": "\(reason)"])
        case .waitingForVerification(let reason):
            log.warning("waiting for vmnet recovery verification", metadata: ["reason": "\(reason)"])
        case .waitingForHealthyProbe(let attempt, let reason):
            log.warning(
                "vmnet helper status probe failed",
                metadata: [
                    "attempt": "\(attempt)",
                    "reason": "\(reason)",
                ]
            )
        case .disabled, .idle, .waitingForReboot:
            break
        }
    }
}

enum VMNetRecoverySystem {
    static func reboot() async throws {
        guard geteuid() == 0 else {
            throw VMNetRecoveryStateError.invalidValue("vmnet recovery coordinator must run as root")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
        process.arguments = ["-r", "now"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VMNetRecoveryStateError.io("host reboot command exited with status \(process.terminationStatus)")
        }
    }

    static func verify(
        config: CRIShimConfig,
        failedNetworkInstanceID: String?
    ) async throws -> VMNetRecoveryVerification {
        guard let runtimeEndpoint = config.normalizedRuntimeEndpoint,
            FileManager.default.fileExists(atPath: runtimeEndpoint)
        else {
            throw VMNetRecoveryStateError.invalidValue("CRI socket is not ready")
        }
        try requireRunningLaunchdService("com.apple.container.cri-shim-macos")
        if config.podNetwork?.enabled == true {
            try requireRunningLaunchdService("com.apple.container.flannel-vxlan-macos")
        }
        if config.kubeProxy?.enabled == true {
            try requireRunningLaunchdService("com.apple.container.kube-proxy-macos")
        }

        let readiness = await ContainerKitCRIShimReadinessChecker().snapshot(config: config)
        guard readiness.runtime.status else {
            throw VMNetRecoveryStateError.invalidValue("container runtime is not ready: \(readiness.runtime.reason)")
        }
        guard readiness.network.status else {
            throw VMNetRecoveryStateError.invalidValue("pod network is not ready: \(readiness.network.reason)")
        }

        let observation = try await observe(config: config)
        let instanceID = observation.networkInstanceID
        if let failedInstanceID = failedNetworkInstanceID, failedInstanceID == instanceID {
            throw VMNetRecoveryStateError.staleNetworkInstance(expected: "a new network instance", actual: instanceID)
        }
        return observation
    }

    static func observe(config: CRIShimConfig) async throws -> VMNetRecoveryVerification {
        guard let networkName = config.podNetwork?.networkName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !networkName.isEmpty
        else {
            throw VMNetRecoveryStateError.invalidValue("pod network name is not configured")
        }
        let status = try await NetworkClient(id: networkName, plugin: "container-network-vmnet").status()
        guard let instanceID = status.networkInstanceID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !instanceID.isEmpty
        else {
            throw VMNetRecoveryStateError.invalidValue("vmnet helper did not publish a network instance id")
        }
        return VMNetRecoveryVerification(networkInstanceID: instanceID)
    }

    private static func requireRunningLaunchdService(_ label: String) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard process.terminationStatus == 0, text.contains("state = running") else {
            throw VMNetRecoveryStateError.invalidValue("launchd service \(label) is not running")
        }
    }
}
