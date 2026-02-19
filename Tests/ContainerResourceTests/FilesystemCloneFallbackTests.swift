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

@testable import ContainerResource

struct FilesystemCloneFallbackTests {
    @Test
    func fallbackToCopyWhenCloneFails() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("clone-fallback-\(UUID().uuidString)")
        let src = tempDir.appendingPathComponent("src.bin")
        let dst = tempDir.appendingPathComponent("dst.bin")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let payload = Data("hello-macos-template".utf8)
        try payload.write(to: src)

        let result = try FilesystemClone.cloneOrCopyItem(
            at: src,
            to: dst,
            cloneImpl: { _, _, _ in -1 }
        )

        #expect(result == .copied)
        let copied = try Data(contentsOf: dst)
        #expect(copied == payload)
    }
}
