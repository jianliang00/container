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

import Foundation
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimReconcileTests {
    @Test
    func planIncludesCreateUpdateDeleteAndReleaseOperations() {
        let storedSandbox = CRIShimSandboxMetadata(
            id: "sandbox-1",
            runtimeHandler: "macos",
            sandboxImage: "image:v1",
            network: "default",
            labels: ["app": "demo"],
            state: .running,
            createdAt: .init(),
            updatedAt: .init()
        )
        let storedContainer = CRIShimContainerMetadata(
            id: "container-1",
            sandboxID: "sandbox-1",
            name: "workload",
            image: "image:v1",
            runtimeHandler: "macos",
            state: .running,
            createdAt: .init(),
            startedAt: nil,
            exitedAt: nil
        )
        let snapshot = CRIShimMetadataSnapshot(
            sandboxes: [
                storedSandbox,
                CRIShimSandboxMetadata(
                    id: "sandbox-2",
                    runtimeHandler: "macos",
                    sandboxImage: "image:v1",
                    state: .running,
                    createdAt: .init(),
                    updatedAt: .init()
                ),
            ],
            containers: [
                storedContainer,
                CRIShimContainerMetadata(
                    id: "container-2",
                    sandboxID: "sandbox-1",
                    name: "sidecar",
                    image: "image:v1",
                    runtimeHandler: "macos",
                    state: .running,
                    createdAt: .init(),
                    startedAt: nil,
                    exitedAt: nil
                ),
            ]
        )

        let inventory = CRIShimRuntimeInventory(
            sandboxes: [
                CRIShimRuntimeSandboxInventory(
                    id: "sandbox-1",
                    state: .live,
                    fingerprint: storedSandbox.reconcileFingerprint + "-changed"
                ),
                CRIShimRuntimeSandboxInventory(
                    id: "sandbox-3",
                    state: .live,
                    fingerprint: "runtime-only"
                ),
                CRIShimRuntimeSandboxInventory(
                    id: "sandbox-4",
                    state: .released,
                    fingerprint: "released"
                ),
            ],
            containers: [
                CRIShimRuntimeContainerInventory(
                    id: "container-1",
                    state: .live,
                    fingerprint: storedContainer.reconcileFingerprint + "-changed"
                ),
                CRIShimRuntimeContainerInventory(
                    id: "container-3",
                    state: .live,
                    fingerprint: "runtime-only"
                ),
                CRIShimRuntimeContainerInventory(
                    id: "container-4",
                    state: .released,
                    fingerprint: "released"
                ),
            ]
        )

        let plan = CRIShimReconciler().makePlan(store: snapshot, inventory: inventory)

        #expect(plan.sandboxSteps.contains(where: { $0.id == "sandbox-1" && $0.action == .update }))
        #expect(plan.sandboxSteps.contains(where: { $0.id == "sandbox-2" && $0.action == .delete }))
        #expect(plan.sandboxSteps.contains(where: { $0.id == "sandbox-3" && $0.action == .create }))
        #expect(plan.sandboxSteps.contains(where: { $0.id == "sandbox-4" && $0.action == .release }))

        #expect(plan.containerSteps.contains(where: { $0.id == "container-1" && $0.action == .update }))
        #expect(plan.containerSteps.contains(where: { $0.id == "container-2" && $0.action == .delete }))
        #expect(plan.containerSteps.contains(where: { $0.id == "container-3" && $0.action == .create }))
        #expect(plan.containerSteps.contains(where: { $0.id == "container-4" && $0.action == .release }))
    }

    @Test
    func planIsEmptyWhenInventoryMatchesStore() {
        let sandbox = CRIShimSandboxMetadata(
            id: "sandbox-1",
            runtimeHandler: "macos",
            sandboxImage: "image:v1",
            state: .running,
            createdAt: .init(),
            updatedAt: .init()
        )
        let container = CRIShimContainerMetadata(
            id: "container-1",
            sandboxID: "sandbox-1",
            name: "workload",
            image: "image:v1",
            runtimeHandler: "macos",
            state: .running,
            createdAt: .init(),
            startedAt: nil,
            exitedAt: nil
        )
        let plan = CRIShimReconciler().makePlan(
            store: CRIShimMetadataSnapshot(sandboxes: [sandbox], containers: [container]),
            inventory: CRIShimRuntimeInventory(
                sandboxes: [.init(id: sandbox.id, state: .live, fingerprint: sandbox.reconcileFingerprint)],
                containers: [.init(id: container.id, state: .live, fingerprint: container.reconcileFingerprint)]
            )
        )

        #expect(plan.isEmpty)
    }
}
