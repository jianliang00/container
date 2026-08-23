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

import ContainerResource
import Foundation

public struct CRIShimVMNetRecoveryController: Sendable {
    public let mode: ContainerConfiguration.MacOSGuestOptions.VMNetDisconnectRecovery
    public let networkName: String?
    public let statePath: String?
    public let requestPath: String?
    public let bootSessionID: String?

    private let stateStore: VMNetRecoveryStateStore?
    private let requestStore: VMNetRecoveryRequestStore?

    public init(
        config: CRIShimConfig,
        bootSessionID: String? = try? VMNetBootSession.current()
    ) {
        let mode =
            config.podNetwork?.enabled == true
            ? config.podNetwork?.vmnetDisconnectRecovery ?? .disabled
            : .disabled
        self.mode = mode
        self.networkName = config.podNetwork?.networkName?.trimmed
        if mode == .rebootNode {
            let recovery = config.resolvedVMNetRecoveryConfig
            self.statePath = recovery.statePath
            self.requestPath = recovery.requestPath
            self.bootSessionID = bootSessionID
            self.stateStore = recovery.statePath.map(VMNetRecoveryStateStore.init(path:))
            self.requestStore = recovery.requestPath.map(VMNetRecoveryRequestStore.init(path:))
        } else {
            self.statePath = nil
            self.requestPath = nil
            self.bootSessionID = nil
            self.stateStore = nil
            self.requestStore = nil
        }
    }

    public func requireAdmission() throws {
        guard mode == .rebootNode else {
            return
        }
        guard let networkName, !networkName.isEmpty, let stateStore, let requestStore, let bootSessionID else {
            throw CRIShimError.unavailable("vmnet recovery admission is not configured")
        }
        do {
            try requestStore.requireNoPendingRequest(networkName: networkName)
            try stateStore.requireHealthy(
                networkName: networkName,
                expectedBootSessionID: bootSessionID
            )
        } catch let error as VMNetRecoveryStateError {
            throw CRIShimError.unavailable(error.description)
        } catch {
            throw CRIShimError.unavailable("vmnet recovery admission state is unavailable")
        }
    }

    public func apply(to snapshot: CRIShimReadinessSnapshot) -> CRIShimReadinessSnapshot {
        guard mode == .rebootNode else {
            return snapshot
        }
        guard let networkName, !networkName.isEmpty, let stateStore, let requestStore, let bootSessionID else {
            return unavailableSnapshot(
                snapshot,
                reason: "VMNetRecoveryNotConfigured",
                message: "vmnet recovery admission is not configured"
            )
        }

        do {
            if try requestStore.hasPendingRequest() {
                return unavailableSnapshot(
                    snapshot,
                    reason: "VMNetRecoveryRequestPending",
                    message: "vmnet recovery is processing a node-wide network failure request"
                )
            }
            guard let state = try stateStore.load() else {
                return unavailableSnapshot(
                    snapshot,
                    reason: "VMNetRecoveryStateMissing",
                    message: "vmnet recovery has not established a healthy network baseline"
                )
            }
            guard state.networkName == networkName else {
                return unavailableSnapshot(
                    snapshot,
                    reason: "VMNetRecoveryStateInvalid",
                    message: "vmnet recovery state does not match the configured network"
                )
            }
            var result = snapshot
            result.info["vmnetRecovery"] = recoveryJSONString([
                "networkInstanceID": state.networkInstanceID ?? "",
                "networkName": state.networkName,
                "phase": state.phase.rawValue,
                "rebootAttempts": String(state.rebootAttempts),
            ])
            guard state.phase != .healthy else {
                guard state.bootSessionID == bootSessionID else {
                    return unavailableSnapshot(
                        result,
                        reason: "VMNetRecoveryBootChanged",
                        message: "vmnet recovery is validating the network after a host reboot"
                    )
                }
                return result
            }
            result.network = CRIShimRuntimeConditionSnapshot(
                type: CRIShimRuntimeConditionType.networkReady,
                status: false,
                reason: "VMNetRecoveryFenced",
                message: "vmnet network \(networkName) is fenced in phase \(state.phase.rawValue)"
            )
            return result
        } catch {
            return unavailableSnapshot(
                snapshot,
                reason: "VMNetRecoveryStateInvalid",
                message: "vmnet recovery state could not be read"
            )
        }
    }

    private func unavailableSnapshot(
        _ snapshot: CRIShimReadinessSnapshot,
        reason: String,
        message: String
    ) -> CRIShimReadinessSnapshot {
        var result = snapshot
        result.network = CRIShimRuntimeConditionSnapshot(
            type: CRIShimRuntimeConditionType.networkReady,
            status: false,
            reason: reason,
            message: message
        )
        return result
    }
}

private func recoveryJSONString(_ value: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}
