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

import Darwin
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import container_macos_guest_agent

@Suite(.serialized)
struct GuestAgentProjectedVolumeTests {
    private func snapshot(_ value: String, extra: Bool = false) -> ProjectedVolumeSnapshot {
        var entries: [ProjectedVolumeSnapshot.Entry] = [
            .init(path: "entry.sh", data: Data("#!/bin/sh\necho \(value)\n".utf8), mode: 0o755, uid: getuid(), gid: getgid()),
            .init(path: "nested", data: nil, mode: 0o755, uid: getuid(), gid: getgid()),
            .init(path: "nested/value", data: Data(value.utf8), mode: 0o640, uid: getuid(), gid: getgid()),
        ]
        if extra { entries.append(.init(path: "removed", data: Data(), mode: 0o600, uid: getuid(), gid: getgid())) }
        return .init(generation: value, entries: entries)
    }

    private func clean(_ root: URL) {
        if let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let path as URL in paths {
                if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                    _ = chflags(path.path, 0)
                    _ = chmod(path.path, 0o700)
                }
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func publishesCompleteVersionsAndRemovesDeletedKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { clean(root) }
        let mount = root.appendingPathComponent("mount")
        let store = root.appendingPathComponent("store")
        try GuestAgentProjectedVolume.publish(snapshot("A", extra: true), at: mount, storeRoot: store)
        let handle = try FileHandle(forReadingFrom: mount.appendingPathComponent("nested/value"))
        defer { try? handle.close() }
        try GuestAgentProjectedVolume.publish(snapshot("B"), at: mount, storeRoot: store)
        #expect(try String(contentsOf: mount.appendingPathComponent("nested/value"), encoding: .utf8) == "B")
        #expect(!FileManager.default.fileExists(atPath: mount.appendingPathComponent("removed").path))
        #expect(try handle.readToEnd() == Data("A".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: mount.appendingPathComponent("entry.sh").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint32Value == 0o755)
        #expect(throws: (any Error).self) { try Data("overwrite".utf8).write(to: mount.appendingPathComponent("entry.sh")) }
        let restricted = try FileManager.default.attributesOfItem(atPath: mount.appendingPathComponent("nested/value").path)
        #expect((restricted[.posixPermissions] as? NSNumber)?.uint32Value == 0o640)
        for version in 1...5 { try GuestAgentProjectedVolume.publish(snapshot("v\(version)"), at: mount, storeRoot: store) }
        let volumeStore = try #require(FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil).first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: volumeStore.path).filter { $0.hasPrefix("generation-") }.count == 2)
        #expect(try String(contentsOf: mount.appendingPathComponent("nested/value"), encoding: .utf8) == "v5")
    }

    @Test func invalidGenerationPreservesPublishedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { clean(root) }
        let mount = root.appendingPathComponent("mount")
        let store = root.appendingPathComponent("store")
        try GuestAgentProjectedVolume.publish(snapshot("A"), at: mount, storeRoot: store)
        let invalid = ProjectedVolumeSnapshot(generation: "B", entries: [.init(path: "../escape", data: Data(), mode: 0o644, uid: getuid(), gid: getgid())])
        #expect(throws: (any Error).self) { try GuestAgentProjectedVolume.publish(invalid, at: mount, storeRoot: store) }
        #expect(try String(contentsOf: mount.appendingPathComponent("nested/value"), encoding: .utf8) == "A")
    }

    @Test func refusesToReplaceExistingApplicationData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { clean(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mount = root.appendingPathComponent("mount")
        try Data("existing".utf8).write(to: mount)
        #expect(throws: (any Error).self) { try GuestAgentProjectedVolume.publish(snapshot("A"), at: mount, storeRoot: root.appendingPathComponent("store")) }
        #expect(try String(contentsOf: mount, encoding: .utf8) == "existing")
    }
}
