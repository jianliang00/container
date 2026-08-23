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

struct CRIShimStatusMappingTests {
    @Test
    func networkInvalidationForcesReadySandboxToStopped() {
        let metadata = readyMetadata()
        let snapshot = SandboxSnapshot(
            status: .stopped,
            networks: [],
            containers: [],
            failureReason: .networkInvalidated
        )

        #expect(metadata.applying(sandboxSnapshot: snapshot).state == .stopped)
    }

    @Test
    func ordinaryStoppedSnapshotPreservesReadyUntilFirstWorkloadStarts() {
        let metadata = readyMetadata()
        let snapshot = SandboxSnapshot(
            status: .stopped,
            networks: [],
            containers: []
        )

        #expect(metadata.applying(sandboxSnapshot: snapshot).state == .ready)
    }

    private func readyMetadata() -> CRIShimSandboxMetadata {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return CRIShimSandboxMetadata(
            id: "sandbox-1",
            runtimeHandler: "macos",
            sandboxImage: "example.com/macos/sandbox:latest",
            state: .ready,
            createdAt: now,
            updatedAt: now
        )
    }
}
