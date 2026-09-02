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

struct CRIShimMetadataStoreTests {
    @Test
    func storesAndReloadsSandboxAndContainerMetadata() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = try CRIShimMetadataStore(rootURL: rootURL)
        let sandbox = CRIShimSandboxMetadata(
            id: "sandbox-1",
            podUID: "pod-uid-1",
            namespace: "default",
            name: "guest",
            runtimeHandler: "macos",
            sandboxImage: "localhost/macos-sandbox:latest",
            network: "default",
            labels: ["app": "demo"],
            annotations: ["annotation": "value"],
            networkLeaseID: "lease-1",
            networkAttachments: ["net-1"],
            state: .running,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_111.456)
        )
        let container = CRIShimContainerMetadata(
            id: "container-1",
            sandboxID: "sandbox-1",
            name: "workload",
            image: "localhost/workload:latest",
            runtimeHandler: "macos",
            labels: ["tier": "frontend"],
            annotations: ["annotation": "value"],
            command: ["/bin/sh"],
            args: ["-c", "echo hello"],
            workingDirectory: "/work",
            logPath: "/var/log/container.log",
            state: .running,
            createdAt: Date(timeIntervalSince1970: 1_700_000_222.789),
            startedAt: Date(timeIntervalSince1970: 1_700_000_333.012),
            exitedAt: nil
        )

        try store.upsertSandbox(sandbox)
        try store.upsertContainer(container)

        let reloaded = try CRIShimMetadataStore(rootURL: rootURL)
        #expect(try reloaded.sandbox(id: "sandbox-1") == sandbox)
        #expect(try reloaded.container(id: "container-1") == container)

        let snapshot = try reloaded.snapshot()
        #expect(snapshot.sandboxes == [sandbox])
        #expect(snapshot.containers == [container])
    }

    @Test
    func deleteRemovesPersistedMetadata() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = try CRIShimMetadataStore(rootURL: rootURL)
        let sandbox = CRIShimSandboxMetadata(
            id: "sandbox-delete",
            runtimeHandler: "macos",
            sandboxImage: "localhost/macos-sandbox:latest",
            state: .ready,
            createdAt: .init(),
            updatedAt: .init()
        )

        try store.upsertSandbox(sandbox)
        try store.deleteSandbox(id: sandbox.id)

        #expect(try store.sandbox(id: sandbox.id) == nil)
        #expect(throws: CRIShimMetadataStoreError.notFound(kind: .sandbox, id: sandbox.id)) {
            try store.deleteSandbox(id: sandbox.id)
        }
    }

    @Test
    func decodesLegacyExitedMetadataAsExplicitUnknownFailure() throws {
        let data = Data(
            """
            {
              "id": "container-legacy",
              "sandboxID": "sandbox-legacy",
              "name": "workload",
              "image": "localhost/workload:latest",
              "runtimeHandler": "macos",
              "state": "exited",
              "createdAt": "2023-11-14T22:13:20.000Z"
            }
            """.utf8
        )

        let metadata = try JSONDecoder.criShimMetadataDecoder.decode(CRIShimContainerMetadata.self, from: data)

        #expect(metadata.exitCode == CRIShimContainerMetadata.unknownExitCode)
        #expect(metadata.reason == CRIShimContainerMetadata.unknownExitReason)
        #expect(metadata.message == CRIShimContainerMetadata.unknownExitMessage)
        #expect(metadata.exitStatusSource == .unknown)
        #expect(metadata.exitTimeSource == .observed)
        #expect(metadata.exitedAt == metadata.createdAt)
        #expect(metadata.lifecycleVersion == 0)
    }

    @Test
    func monotonicUpsertPreservesRuntimeExitFactsFromStaleWriter() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = try CRIShimMetadataStore(rootURL: rootURL)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let exitedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let running = makeContainer(state: .running, createdAt: createdAt)
        try store.upsertContainer(running)

        _ = try store.updateContainer(id: running.id, expectedLifecycleVersion: 0) { metadata in
            metadata.recordRuntimeExit(code: 137, at: exitedAt, observedAt: exitedAt)
        }
        try store.upsertContainer(running)

        let stored = try #require(try store.container(id: running.id))
        #expect(stored.state == .exited)
        #expect(stored.exitedAt == exitedAt)
        #expect(stored.exitCode == 137)
        #expect(stored.reason == "Error")
        #expect(stored.exitStatusSource == .runtime)
        #expect(stored.exitTimeSource == .runtime)
        #expect(stored.lifecycleVersion == 1)
    }

    @Test
    func runtimeExitOverridesUnknownButCannotBeOverwrittenBySuccess() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = try CRIShimMetadataStore(rootURL: rootURL)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let unknownAt = Date(timeIntervalSince1970: 1_700_000_050)
        let exitedAt = Date(timeIntervalSince1970: 1_700_000_100)
        var metadata = makeContainer(state: .running, createdAt: createdAt)
        metadata.recordUnknownExit(at: unknownAt)
        try store.upsertContainer(metadata)

        _ = try store.updateContainer(id: metadata.id) { current in
            current.recordRuntimeExit(code: 137, at: exitedAt, observedAt: exitedAt)
        }
        _ = try store.updateContainer(id: metadata.id) { current in
            current.recordRuntimeExit(code: 0, at: exitedAt.addingTimeInterval(1), observedAt: exitedAt)
        }

        let stored = try #require(try store.container(id: metadata.id))
        #expect(stored.exitCode == 137)
        #expect(stored.exitedAt == exitedAt)
        #expect(stored.exitStatusSource == .runtime)
    }

    @Test
    func completeRuntimeExitTimeUpgradesEarlierObservedTime() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = try CRIShimMetadataStore(rootURL: rootURL)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let observedAt = Date(timeIntervalSince1970: 1_700_000_050)
        let runtimeExitedAt = Date(timeIntervalSince1970: 1_700_000_040)
        let metadata = makeContainer(state: .running, createdAt: createdAt)
        try store.upsertContainer(metadata)

        _ = try store.updateContainer(id: metadata.id) { current in
            current.recordRuntimeExit(code: 137, at: nil, observedAt: observedAt)
        }
        let incomplete = try #require(try store.container(id: metadata.id))
        #expect(incomplete.exitCode == 137)
        #expect(incomplete.exitStatusSource == .runtime)
        #expect(incomplete.exitedAt == observedAt)
        #expect(incomplete.exitTimeSource == .observed)

        _ = try store.updateContainer(id: metadata.id) { current in
            current.recordRuntimeExit(code: 137, at: runtimeExitedAt, observedAt: observedAt)
        }
        let complete = try #require(try store.container(id: metadata.id))
        #expect(complete.exitCode == 137)
        #expect(complete.exitedAt == runtimeExitedAt)
        #expect(complete.exitTimeSource == .runtime)
        #expect(complete.lifecycleVersion == 2)
    }

    @Test
    func runtimeFailureReplacesEarlierSuccessfulExitTime() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = try CRIShimMetadataStore(rootURL: rootURL)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let successfulExitAt = Date(timeIntervalSince1970: 1_700_000_040)
        let failedExitAt = Date(timeIntervalSince1970: 1_700_000_050)
        let metadata = makeContainer(state: .running, createdAt: createdAt)
        try store.upsertContainer(metadata)

        _ = try store.updateContainer(id: metadata.id) { current in
            current.recordRuntimeExit(code: 0, at: successfulExitAt, observedAt: successfulExitAt)
        }
        _ = try store.updateContainer(id: metadata.id) { current in
            current.recordRuntimeExit(code: 137, at: failedExitAt, observedAt: failedExitAt)
        }

        let stored = try #require(try store.container(id: metadata.id))
        #expect(stored.exitCode == 137)
        #expect(stored.exitedAt == failedExitAt)
        #expect(stored.exitStatusSource == .runtime)
        #expect(stored.exitTimeSource == .runtime)
    }

    @Test
    func incompleteFailureAfterSuccessCanUpgradeToRuntimeExitTime() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = try CRIShimMetadataStore(rootURL: rootURL)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let successfulExitAt = Date(timeIntervalSince1970: 1_700_000_040)
        let failureObservedAt = Date(timeIntervalSince1970: 1_700_000_060)
        let failedExitAt = Date(timeIntervalSince1970: 1_700_000_050)
        let metadata = makeContainer(state: .running, createdAt: createdAt)
        try store.upsertContainer(metadata)

        _ = try store.updateContainer(id: metadata.id) { current in
            current.recordRuntimeExit(code: 0, at: successfulExitAt, observedAt: successfulExitAt)
        }
        _ = try store.updateContainer(id: metadata.id) { current in
            current.recordRuntimeExit(code: 137, at: nil, observedAt: failureObservedAt)
        }
        let incomplete = try #require(try store.container(id: metadata.id))
        #expect(incomplete.exitCode == 137)
        #expect(incomplete.exitedAt == failureObservedAt)
        #expect(incomplete.exitTimeSource == .observed)

        _ = try store.updateContainer(id: metadata.id) { current in
            current.recordRuntimeExit(code: 137, at: failedExitAt, observedAt: failureObservedAt)
        }
        let complete = try #require(try store.container(id: metadata.id))
        #expect(complete.exitCode == 137)
        #expect(complete.exitedAt == failedExitAt)
        #expect(complete.exitTimeSource == .runtime)
    }

    @Test
    func sourceLessPersistedFailureCannotBeDowngradedToUnknown() {
        let exitedAt = Date(timeIntervalSince1970: 1_700_000_100)
        var metadata = makeContainer(state: .exited, createdAt: exitedAt.addingTimeInterval(-10))
        metadata.exitedAt = exitedAt
        metadata.exitCode = 137

        metadata.recordUnknownExit(at: exitedAt.addingTimeInterval(1))

        #expect(metadata.exitCode == 137)
        #expect(metadata.exitedAt == exitedAt)
        #expect(metadata.exitStatusSource == .runtime)
    }

    @Test
    func expectedLifecycleVersionRejectsStaleTransition() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = try CRIShimMetadataStore(rootURL: rootURL)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let exitedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let metadata = makeContainer(state: .running, createdAt: createdAt)
        try store.upsertContainer(metadata)

        _ = try store.updateContainer(id: metadata.id, expectedLifecycleVersion: 0) { current in
            current.recordRuntimeExit(code: 137, at: exitedAt, observedAt: exitedAt)
        }
        _ = try store.updateContainer(id: metadata.id, expectedLifecycleVersion: 0) { current in
            current.state = .running
            current.exitedAt = nil
            current.exitCode = nil
        }

        let stored = try #require(try store.container(id: metadata.id))
        #expect(stored.state == .exited)
        #expect(stored.exitCode == 137)
        #expect(stored.lifecycleVersion == 1)
    }

    @Test
    func sandboxUpdatesCannotRegressTerminalState() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = try CRIShimMetadataStore(rootURL: rootURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sandbox = CRIShimSandboxMetadata(
            id: "sandbox-monotonic",
            runtimeHandler: "macos",
            sandboxImage: "localhost/macos-sandbox:latest",
            networkAttachments: ["current-network"],
            state: .stopped,
            createdAt: now,
            updatedAt: now
        )
        try store.upsertSandbox(sandbox)

        var stale = sandbox
        stale.state = .running
        stale.networkLeaseID = "stale-lease"
        stale.networkAttachments = ["stale-network"]
        stale.updatedAt = now.addingTimeInterval(10)
        try store.upsertSandbox(stale)
        _ = try store.updateSandbox(id: sandbox.id) { metadata in
            metadata.state = .running
        }

        let stored = try #require(try store.sandbox(id: sandbox.id))
        #expect(stored.state == .stopped)
        #expect(stored.networkLeaseID == nil)
        #expect(stored.networkAttachments == ["current-network"])
        #expect(stored.updatedAt == now)
    }

    private func makeContainer(
        state: CRIShimContainerMetadata.State,
        createdAt: Date
    ) -> CRIShimContainerMetadata {
        CRIShimContainerMetadata(
            id: "container-monotonic",
            sandboxID: "sandbox-monotonic",
            name: "workload",
            image: "localhost/workload:latest",
            runtimeHandler: "macos",
            state: state,
            createdAt: createdAt,
            startedAt: state == .created ? nil : createdAt
        )
    }
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CRIShimMetadataStoreTests-\(UUID().uuidString)", isDirectory: true)
}
