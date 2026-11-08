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
import RuntimeMacOSSidecarShared
import Testing

@testable import container_runtime_macos

struct MacOSNativeDiskCreationTests {
    @Test
    func platformCreatorBuildsASIFOrRejectsBeforeMutation() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-platform-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base.img")
        let overlay = root.appendingPathComponent("active.asif")
        #expect(FileManager.default.createFile(atPath: base.path, contents: nil))
        let file = try FileHandle(forWritingTo: base)
        try file.truncate(atOffset: 64 << 20)
        try file.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: base.path)
        if MacOSNativeDisk.available {
            try createNativeASIFOverlay(base: base, output: overlay)
            #expect((try overlay.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0)
            // A second create cannot overwrite the first overlay.
            #expect(throws: (any Error).self) { try createNativeASIFOverlay(base: base, output: overlay) }
        } else {
            #expect(throws: (any Error).self) { try createNativeASIFOverlay(base: base, output: overlay) }
            #expect(!FileManager.default.fileExists(atPath: overlay.path))
        }
    }
}
