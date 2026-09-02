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

@Suite
struct CRIShimProcessLockTests {
    @Test
    func stateDirectoryHasOneProcessOwner() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cri-shim-process-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        var first: CRIShimProcessLock? = try CRIShimProcessLock.acquire(stateDirectory: root.path)
        #expect(first != nil)
        #expect(throws: CRIShimError.self) {
            _ = try CRIShimProcessLock.acquire(stateDirectory: root.path)
        }

        first = nil
        let successor = try CRIShimProcessLock.acquire(stateDirectory: root.path)
        withExtendedLifetime(successor) {}
    }
}
