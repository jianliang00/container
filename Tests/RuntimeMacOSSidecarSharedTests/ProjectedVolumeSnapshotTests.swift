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

@testable import RuntimeMacOSSidecarShared

struct ProjectedVolumeSnapshotTests {
    @Test func capturesOnlyTheActiveGenerationIncludingNestedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["..A", "..B"] {
            let nested = root.appendingPathComponent(version).appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: nested.appendingPathComponent("value"))
        }
        let link = root.appendingPathComponent("..data")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "..B")
        let snapshot = try ProjectedVolumeSnapshot.capture(at: root)
        #expect(snapshot.generation == "..B")
        #expect(snapshot.entries.map(\.path) == ["nested", "nested/value"])
        #expect(snapshot.entries.last?.data == Data("..B".utf8))
    }

    @Test func rejectsSymlinksInsideGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = root.appendingPathComponent("..A")
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("..data").path, withDestinationPath: "..A")
        try FileManager.default.createSymbolicLink(atPath: generation.appendingPathComponent("outside").path, withDestinationPath: "/etc/passwd")
        #expect(throws: (any Error).self) { try ProjectedVolumeSnapshot.capture(at: root) }
    }
}
