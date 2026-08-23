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
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimVMNetRecoveryStateTests {
    @Test
    func missingBaselineFailsAdmissionAndNetworkReadiness() throws {
        try withRecoveryController { controller, _ in
            #expect(
                throws: CRIShimError.unavailable(
                    "vmnet recovery state is missing for network kubernetes-pod"
                )
            ) {
                try controller.requireAdmission()
            }

            let result = controller.apply(to: readySnapshot())
            #expect(!result.network.status)
            #expect(result.network.reason == "VMNetRecoveryStateMissing")
        }
    }

    @Test
    func healthyBaselineFromCurrentBootAllowsAdmission() throws {
        try withRecoveryController { controller, store in
            _ = try store.recordHealthyObservation(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a"
            )

            try controller.requireAdmission()
            let result = controller.apply(to: readySnapshot())
            #expect(result.network.status)
            #expect(result.network.reason == "NetworkReady")
            #expect(result.info["vmnetRecovery"]?.contains(#""phase":"healthy""#) == true)
        }
    }

    @Test
    func previousBootBaselineStaysClosedUntilCoordinatorRefreshesIt() throws {
        try withRecoveryController { controller, store in
            _ = try store.recordHealthyObservation(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                bootSessionID: "boot-old"
            )

            #expect(
                throws: CRIShimError.unavailable(
                    "vmnet recovery boot session mismatch: expected boot-a, got boot-old"
                )
            ) {
                try controller.requireAdmission()
            }
            let result = controller.apply(to: readySnapshot())
            #expect(!result.network.status)
            #expect(result.network.reason == "VMNetRecoveryBootChanged")
        }
    }

    @Test
    func persistedFenceOverridesOtherwiseReadyNetwork() throws {
        try withRecoveryController { controller, store in
            _ = try store.recordFence(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                failureReason: "helper disconnected",
                bootSessionID: "boot-a",
                attemptWindow: 3600
            )

            let result = controller.apply(to: readySnapshot())
            #expect(!result.network.status)
            #expect(result.network.reason == "VMNetRecoveryFenced")
            #expect(result.network.message.contains("fenced"))
        }
    }

    @Test
    func pendingRuntimeRequestClosesAdmissionBeforeCoordinatorPersistsFence() throws {
        try withRecoveryController { controller, store in
            _ = try store.recordHealthyObservation(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a"
            )
            let requestPath = try #require(controller.requestPath)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: requestPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try VMNetRecoveryRequestStore(path: requestPath).submit(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                failureReason: "helper disconnected",
                bootSessionID: "boot-a"
            )

            #expect(throws: CRIShimError.self) {
                try controller.requireAdmission()
            }
            let result = controller.apply(to: readySnapshot())
            #expect(!result.network.status)
            #expect(result.network.reason == "VMNetRecoveryRequestPending")
        }
    }

    @Test
    func disabledModePreservesLegacyReadinessWithoutStateFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = recoveryConfig(root: root, mode: .disabled)
        let controller = CRIShimVMNetRecoveryController(config: config, bootSessionID: "boot-a")

        try controller.requireAdmission()
        #expect(controller.apply(to: readySnapshot()) == readySnapshot())
    }
}

private func withRecoveryController(
    _ body: (CRIShimVMNetRecoveryController, VMNetRecoveryStateStore) throws -> Void
) throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = recoveryConfig(root: root, mode: .rebootNode)
    let controller = CRIShimVMNetRecoveryController(config: config, bootSessionID: "boot-a")
    let store = VMNetRecoveryStateStore(path: config.resolvedVMNetRecoveryConfig.statePath!)
    try body(controller, store)
}

private func recoveryConfig(
    root: URL,
    mode: ContainerConfiguration.MacOSGuestOptions.VMNetDisconnectRecovery
) -> CRIShimConfig {
    CRIShimConfig(
        stateDirectory: root.path,
        podNetwork: PodNetworkConfig(
            enabled: true,
            vmnetDisconnectRecovery: mode,
            networkName: "kubernetes-pod",
            vmnetRecovery: VMNetRecoveryConfig(
                statePath: root.appendingPathComponent("recovery.json").path,
                requestPath: root.appendingPathComponent("requests/fence.json").path,
                requestWriterUID: Int(geteuid())
            )
        )
    )
}

private func readySnapshot() -> CRIShimReadinessSnapshot {
    CRIShimReadinessSnapshot(
        runtime: CRIShimRuntimeConditionSnapshot(
            type: CRIShimRuntimeConditionType.runtimeReady,
            status: true,
            reason: "RuntimeReady",
            message: "ready"
        ),
        network: CRIShimRuntimeConditionSnapshot(
            type: CRIShimRuntimeConditionType.networkReady,
            status: true,
            reason: "NetworkReady",
            message: "ready"
        )
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("CRIShimVMNetRecoveryStateTests-\(UUID().uuidString)", isDirectory: true)
}
