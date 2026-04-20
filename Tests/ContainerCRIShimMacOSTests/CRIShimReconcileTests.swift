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
@testable import ContainerKit
@testable import ContainerResource

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

    @Test
    func executorUpdatesMetadataFromRuntimeSnapshots() throws {
        let storeURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = try CRIShimMetadataStore(rootURL: storeURL)
        let oldStart = Date(timeIntervalSince1970: 1_700_000_010)
        let newStart = Date(timeIntervalSince1970: 1_700_000_020)
        let exitedAt = Date(timeIntervalSince1970: 1_700_000_030)
        let now = Date(timeIntervalSince1970: 1_700_000_040)

        try store.upsertSandbox(
            CRIShimSandboxMetadata(
                id: "sandbox-1",
                runtimeHandler: "macos",
                sandboxImage: "example.com/macos/sandbox:latest",
                network: "default",
                state: .running,
                createdAt: oldStart,
                updatedAt: oldStart
            ))
        try store.upsertContainer(
            CRIShimContainerMetadata(
                id: "container-1",
                sandboxID: "sandbox-1",
                name: "workload",
                image: "example.com/macos/workload:latest",
                runtimeHandler: "macos",
                state: .running,
                createdAt: oldStart,
                startedAt: oldStart
            ))

        let workloadSnapshot = WorkloadSnapshot(
            configuration: WorkloadConfiguration(
                id: "container-1",
                processConfiguration: ProcessConfiguration(executable: "/bin/echo", arguments: [], environment: []),
                workloadImageReference: "example.com/macos/workload:latest"
            ),
            status: .stopped,
            exitCode: 0,
            startedDate: newStart,
            exitedAt: exitedAt
        )
        let sandboxSnapshot = SandboxSnapshot(
            configuration: try makeSandboxConfiguration(id: "sandbox-1"),
            status: .stopped,
            networks: [],
            containers: [],
            workloads: [workloadSnapshot]
        )

        let result = try CRIShimReconcileExecutor().execute(
            metadataStore: store,
            runtimeSnapshots: CRIShimRuntimeSnapshotInventory(sandboxes: [sandboxSnapshot]),
            now: now
        )

        #expect(containsStep(result.appliedSteps, kind: .sandbox, action: .update, id: "sandbox-1"))
        #expect(containsStep(result.appliedSteps, kind: .container, action: .update, id: "container-1"))
        let sandboxMetadata = try store.sandbox(id: "sandbox-1")
        let sandbox = try #require(sandboxMetadata)
        #expect(sandbox.state == .stopped)
        #expect(sandbox.updatedAt == now)
        let containerMetadata = try store.container(id: "container-1")
        let container = try #require(containerMetadata)
        #expect(container.state == .exited)
        #expect(container.startedAt == newStart)
        #expect(container.exitedAt == exitedAt)
    }

    @Test
    func executorDeletesMetadataMissingFromRuntimeSnapshots() throws {
        let storeURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = try CRIShimMetadataStore(rootURL: storeURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsertSandbox(
            CRIShimSandboxMetadata(
                id: "sandbox-1",
                runtimeHandler: "macos",
                sandboxImage: "example.com/macos/sandbox:latest",
                state: .running,
                createdAt: now,
                updatedAt: now
            ))
        try store.upsertContainer(
            CRIShimContainerMetadata(
                id: "container-1",
                sandboxID: "sandbox-1",
                name: "workload",
                image: "example.com/macos/workload:latest",
                runtimeHandler: "macos",
                state: .running,
                createdAt: now
            ))

        let result = try CRIShimReconcileExecutor().execute(
            metadataStore: store,
            runtimeSnapshots: CRIShimRuntimeSnapshotInventory()
        )

        #expect(containsStep(result.appliedSteps, kind: .sandbox, action: .delete, id: "sandbox-1"))
        #expect(try store.sandbox(id: "sandbox-1") == nil)
        #expect(try store.container(id: "container-1") == nil)
    }
}

private func containsStep(
    _ steps: [CRIShimReconcileStep],
    kind: CRIShimReconcileStep.Kind,
    action: CRIShimReconcileStep.Action,
    id: String
) -> Bool {
    steps.contains { step in
        step.kind == kind && step.action == action && step.id == id
    }
}

private func makeSandboxConfiguration(id: String) throws -> SandboxConfiguration {
    let imageJSON = """
        {
          "reference": "example.com/macos/sandbox:latest",
          "descriptor": {
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "digest": "sha256:sandbox",
            "size": 1
          }
        }
        """
    let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
    let process = ProcessConfiguration(
        executable: "/usr/bin/true",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
    var configuration = ContainerConfiguration(id: id, image: image, process: process)
    configuration.runtimeHandler = "container-runtime-macos"
    return SandboxConfiguration(containerConfiguration: configuration)
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CRIShimReconcileTests-\(UUID().uuidString)", isDirectory: true)
}
