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

struct CRIShimImageGCProtectionTests {
    @Test
    func protectsConfiguredAndPersistedImagesUntilSandboxRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CRIShimMetadataStore(rootURL: root)
        let config = CRIShimConfig(defaults: RuntimeProfile(sandboxImage: "base:default"), runtimeHandlers: ["gui": RuntimeProfile(sandboxImage: "base:gui")])
        let protection = CRIShimImageGCProtection(config: config, metadataStore: store)
        try store.upsertSandbox(CRIShimSandboxMetadata(id: "stopped", runtimeHandler: "macos", sandboxImage: "base:old", state: .stopped, createdAt: Date(), updatedAt: Date()))
        #expect(try await protection.references() == ["base:default", "base:gui", "base:old"])
        try store.deleteSandbox(id: "stopped")
        #expect(try await protection.references() == ["base:default", "base:gui"])
    }

    @Test
    func protectsPreparationBeforeMetadataAndReleasesAfterFailure() async throws {
        let protection = CRIShimImageGCProtection()
        let admitted = ImageGCTestSignal()
        let finish = ImageGCTestSignal()
        let preparing = Task {
            try await protection.withProtectedImage("base:override") {
                await admitted.signal()
                await finish.wait()
                throw CRIShimError.internalError("failed to create")
            }
        }
        await admitted.wait()
        try await protection.withRemoval { references in
            #expect(references.contains("base:override"))
        }
        await finish.signal()
        do {
            _ = try await preparing.value
            Issue.record("expected creation failure")
        } catch {}
        #expect(try await protection.references().isEmpty)
    }

    @Test
    func creationWaitsForInProgressDeletionAndFailureReleasesGate() async throws {
        let protection = CRIShimImageGCProtection()
        let removing = ImageGCTestSignal()
        let finish = ImageGCTestSignal()
        let removal = Task {
            try await protection.withRemoval { _ in
                await removing.signal()
                await finish.wait()
                throw CRIShimError.internalError("delete failed")
            }
        }
        await removing.wait()
        let creation = Task {
            try await protection.withProtectedImage("base:new") {
                #expect(await finish.isSignalled)
            }
        }
        await finish.signal()
        do {
            _ = try await removal.value
            Issue.record("expected deletion failure")
        } catch {}
        try await creation.value
        #expect(try await protection.references().isEmpty)
    }
}

private actor ImageGCTestSignal {
    private(set) var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isSignalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        isSignalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
