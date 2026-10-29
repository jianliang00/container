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

import CryptoKit
import Darwin
import Foundation
import Testing

@testable import RuntimeMacOSSidecarShared

struct MacOSLocalDiskBundleTests {
    @Test
    func coldImportClonesAllPlatformFilesAndSurvivesStagingGC() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.install()
        for name in MacOSLocalDiskBundle.fileNames {
            #expect(try Data(contentsOf: f.destination.appendingPathComponent(name)) == Data(name.utf8))
        }
        try Data("guest-modification".utf8).write(to: f.destination.appendingPathComponent("Disk.img"))
        #expect(try Data(contentsOf: f.source.appendingPathComponent("Disk.img")) == Data("Disk.img".utf8))
        try FileManager.default.removeItem(at: f.source)
        try f.install()
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("Disk.img")) == Data("guest-modification".utf8))
    }

    @Test(arguments: ["digest", "generation", "symlink", "existing", "member"])
    func rejectsInvalidImportsWithoutBootablePublication(mode: String) throws {
        let f = try Fixture()
        defer { f.remove() }
        switch mode {
        case "symlink":
            let file = f.source.appendingPathComponent("Disk.img")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.source.appendingPathComponent("AuxiliaryStorage"))
        case "existing": try Data("unrelated".utf8).write(to: f.destination.appendingPathComponent("Disk.img"))
        case "member": try FileManager.default.removeItem(at: f.source.appendingPathComponent("MachineIdentifier.bin"))
        default: break
        }
        #expect(throws: (any Error).self) { try f.install(digest: mode == "digest" ? String(repeating: "0", count: 64) : nil, generation: mode == "generation" ? 3 : 2) }
        #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("disk-bundle-imported").path))
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let digest: String
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            source = root.appendingPathComponent("state/disks/g2")
            destination = root.appendingPathComponent("runtime")
            let fm = FileManager.default
            try fm.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let files = MacOSLocalDiskBundle.fileNames.map { ["name": $0, "size": $0.utf8.count] as [String: Any] }
            let manifest: [String: Any] = ["version": 1, "persistenceID": "vm-test", "storageGeneration": 2, "files": files]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try data.write(to: source.appendingPathComponent("disk-bundle.json"))
            for name in MacOSLocalDiskBundle.fileNames { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        }
        func install(digest: String? = nil, generation: UInt64 = 2) throws {
            try MacOSLocalDiskBundle.install(
                storageDirectory: root.appendingPathComponent("state").path, persistenceID: "vm-test", generation: generation, digest: digest ?? self.digest,
                destination: destination)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
