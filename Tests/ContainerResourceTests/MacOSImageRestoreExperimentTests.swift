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

/// Opt-in local experiment using the production RAW rebuilder and clone path.
/// Inputs are prepared outside the measured interval. This never uses global caches.
struct MacOSImageRestoreExperimentTests {
    private struct Request: Decodable {
        let sample: String
        let cache: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACOS_IMAGE_RESTORE_EXPERIMENT"] != nil))
    func measureOwnedFixture() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACOS_IMAGE_RESTORE_EXPERIMENT"])
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let fm = FileManager.default
        try #require(root == root.resolvingSymlinksInPath())
        let attributes = try fm.attributesOfItem(atPath: root.path)
        try #require((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        try #require(((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0)
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
        for name in [request.sample, request.cache] {
            try #require(name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil)
        }
        let layout = try JSONDecoder().decode(DiskLayout.self, from: Data(contentsOf: root.appendingPathComponent("layout.json")))
        let blobs = root.appendingPathComponent("oci/blobs/sha256")
        var paths: [String: URL] = [:]
        for chunk in layout.chunks {
            try #require(chunk.layerDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil)
            let file = blobs.appendingPathComponent(String(chunk.layerDigest.dropFirst(7)))
            try #require(file == file.resolvingSymlinksInPath())
            try #require(fm.fileExists(atPath: file.path))
            paths[chunk.layerDigest] = file
        }
        let cached = root.appendingPathComponent(request.cache).appendingPathComponent("Disk.img")
        let instance = root.appendingPathComponent(request.sample)
        try #require(!fm.fileExists(atPath: instance.path))
        try #require(cached == cached.resolvingSymlinksInPath())
        let started = DispatchTime.now().uptimeNanoseconds
        let hit = MacOSDiskRebuilder.cacheExists(at: cached)
        if hit {
            try MacOSGuestCache.cleanInterruptedRebuilds(in: cached.deletingLastPathComponent())
        } else {
            try MacOSDiskRebuilder.rebuild(layout: layout, chunkBlobPaths: paths, outputPath: cached)
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: cached.path)
        }
        let rebuilt = DispatchTime.now().uptimeNanoseconds
        try fm.createDirectory(at: instance, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let disk = instance.appendingPathComponent("Disk.img")
        let clone = try FilesystemClone.cloneOrCopyItem(at: cached, to: disk)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: disk.path)
        for name in ["HardwareModel.bin", "AuxiliaryStorage", "MachineIdentifier.bin"] {
            let source = root.appendingPathComponent("identity").appendingPathComponent(name)
            try #require(source == source.resolvingSymlinksInPath())
            try FilesystemClone.cloneOrCopyItem(at: source, to: instance.appendingPathComponent(name))
        }
        let runtime: [String: Any] = ["backend": "raw", "readOnly": [String](), "writable": "Disk.img"]
        try JSONSerialization.data(withJSONObject: runtime).write(to: instance.appendingPathComponent("runtime.json"))
        try JSONSerialization.data(withJSONObject: [
            "format": "container.macos.asif-mvp.v1", "runtime": runtime,
            "immutable": [String: String](), "sealAllowed": true,
        ]).write(to: instance.appendingPathComponent("instance.json"))
        let finished = DispatchTime.now().uptimeNanoseconds
        let result: [String: Any] = [
            "cacheHit": hit, "rebuildSeconds": Double(rebuilt - started) / 1e9,
            "cloneAndMetadataSeconds": Double(finished - rebuilt) / 1e9,
            "materializeSeconds": Double(finished - started) / 1e9,
            "cloned": clone == .cloned, "logicalBytes": layout.logicalSize,
            "implementation": "MacOSDiskRebuilder + FilesystemClone; automatic parallelism",
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent(request.sample + ".json"))
        #expect(clone == .cloned)
        #expect((try fm.attributesOfItem(atPath: disk.path)[.size] as? NSNumber)?.int64Value == layout.logicalSize)
    }
}
