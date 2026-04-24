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

struct MacOSGuestMountMappingTests {
    @Test
    func defaultSeedPathUsesAutomountRoot() {
        #expect(MacOSGuestMountMapping.automountTag == "com.apple.virtio-fs.automount")
        #expect(MacOSGuestMountMapping.defaultSeedMountPath == "/Volumes/My Shared Files/seed")
    }

    @Test
    func hostPathSharesDeriveStableAutomountLocations() throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let workspace = tempRoot.appendingPathComponent("workspace")
        let cache = tempRoot.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let shares = try MacOSGuestMountMapping.hostPathShares(from: [
            .virtiofs(source: workspace.path, destination: "/Users/Shared/workspace", options: []),
            .virtiofs(source: cache.path, destination: "/var/cache/build", options: ["ro"]),
        ])

        #expect(
            shares == [
                .init(
                    name: "v-workspace",
                    source: workspace.path,
                    guestPath: "/Users/Shared/workspace",
                    readOnly: false
                ),
                .init(
                    name: "v-build",
                    source: cache.path,
                    guestPath: "/var/cache/build",
                    readOnly: true
                ),
            ]
        )
        #expect(shares[0].guestRealPath == "/Volumes/My Shared Files/v-workspace")
        #expect(shares[1].guestRealPath == "/Volumes/My Shared Files/v-build")
    }

    @Test
    func collidingBaseNamesReceiveStableUniqueSuffixes() throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let first = tempRoot.appendingPathComponent("first")
        let second = tempRoot.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let mounts = [
            Filesystem.virtiofs(source: first.path, destination: "/opt/workspace", options: []),
            Filesystem.virtiofs(source: second.path, destination: "/tmp/workspace", options: []),
        ]

        let sharesA = try MacOSGuestMountMapping.hostPathShares(from: mounts)
        let sharesB = try MacOSGuestMountMapping.hostPathShares(from: mounts)

        #expect(sharesA[0].name.starts(with: "v-workspace-"))
        #expect(sharesA[1].name.starts(with: "v-workspace-"))
        #expect(sharesA[0].name != sharesA[1].name)
        #expect(sharesA == sharesB)
    }

    @Test
    func mergeHostPathMountsDeduplicatesAndRejectsConflicts() throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sourceA = tempRoot.appendingPathComponent("source-a")
        let sourceB = tempRoot.appendingPathComponent("source-b")
        try FileManager.default.createDirectory(at: sourceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)

        let first = Filesystem.virtiofs(source: sourceA.path, destination: "/Users/demo/data", options: [])
        let duplicate = Filesystem.virtiofs(source: sourceA.path, destination: "/Users/demo/data", options: [])
        let second = Filesystem.virtiofs(source: sourceB.path, destination: "/opt/config", options: ["ro"])

        let merged = try MacOSGuestMountMapping.mergeHostPathMounts([[first], [duplicate, second]])
        #expect(merged.count == 2)
        #expect(merged[0].source == normalizedDirectoryPath(sourceA))
        #expect(merged[0].destination == "/Users/demo/data")
        #expect(merged[1].source == normalizedDirectoryPath(sourceB))
        #expect(merged[1].destination == "/opt/config")
        #expect(merged[1].options == ["ro"])

        #expect(throws: MacOSGuestMountMapping.Error.conflictingGuestPath("/Users/demo/data")) {
            try MacOSGuestMountMapping.mergeHostPathMounts([
                [first],
                [Filesystem.virtiofs(source: sourceB.path, destination: "/Users/demo/data", options: [])],
            ])
        }

        #expect(throws: MacOSGuestMountMapping.Error.conflictingHostPath(normalizedDirectoryPath(sourceA))) {
            try MacOSGuestMountMapping.mergeHostPathMounts([
                [first],
                [Filesystem.virtiofs(source: sourceA.path, destination: "/Users/demo/readonly", options: ["ro"])],
            ])
        }
    }

    @Test
    func rejectsUnsupportedMountShapes() throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let directory = tempRoot.appendingPathComponent("directory")
        let file = tempRoot.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))

        do {
            _ = try MacOSGuestMountMapping.hostPathShares(from: [
                .volume(name: "named", format: "raw", source: directory.path, destination: "/data", options: [])
            ])
            Issue.record("expected named volume mount to be rejected")
        } catch let error as MacOSGuestMountMapping.Error {
            #expect(error == .unsupportedMountType("volume(named):/data"))
        }

        do {
            _ = try MacOSGuestMountMapping.hostPathShares(from: [
                .virtiofs(source: file.path, destination: "/data", options: [])
            ])
            Issue.record("expected file source to be rejected")
        } catch let error as MacOSGuestMountMapping.Error {
            #expect(error == .hostPathNotDirectory(file.path))
        }

        do {
            _ = try MacOSGuestMountMapping.hostPathShares(from: [
                .virtiofs(source: directory.path, destination: "relative", options: [])
            ])
            Issue.record("expected relative guest path to be rejected")
        } catch let error as MacOSGuestMountMapping.Error {
            #expect(error == .guestPathNotAbsolute("relative"))
        }

        do {
            _ = try MacOSGuestMountMapping.hostPathShares(from: [
                .virtiofs(source: directory.path, destination: "/System/Library", options: [])
            ])
            Issue.record("expected reserved guest path to be rejected")
        } catch let error as MacOSGuestMountMapping.Error {
            #expect(error == .guestPathReserved("/System/Library"))
        }

        do {
            _ = try MacOSGuestMountMapping.hostPathShares(from: [
                .virtiofs(source: directory.path, destination: "/workspace", options: [])
            ])
            Issue.record("expected read-only root guest path to be rejected")
        } catch let error as MacOSGuestMountMapping.Error {
            #expect(error == .guestPathNotWritable("/workspace"))
        }
    }
}

private func makeTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MacOSGuestMountMappingTests-\(UUID().uuidString)")
}

private func normalizedDirectoryPath(_ url: URL) -> String {
    let path = url.path
    return path.hasSuffix("/") ? path : "\(path)/"
}
