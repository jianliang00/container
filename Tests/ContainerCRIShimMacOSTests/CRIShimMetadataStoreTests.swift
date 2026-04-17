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
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CRIShimMetadataStoreTests-\(UUID().uuidString)", isDirectory: true)
}
