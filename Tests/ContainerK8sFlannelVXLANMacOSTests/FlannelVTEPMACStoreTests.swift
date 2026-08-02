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

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelVTEPMACStoreTests {
    @Test
    func createsAndReusesPersistentLocallyAdministeredMAC() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state/vtep-mac")
        let store = FlannelVTEPMACStore(url: url)

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        #expect(first == second)
        #expect(FlannelVTEPMAC.isLocallyAdministeredUnicast(first))
        #expect(try String(contentsOf: url, encoding: .utf8) == "\(first)\n")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func normalizesLinuxAndWindowsMACRepresentations() {
        #expect(FlannelVTEPMAC.normalize("02:11:22:AA:BB:CC") == "02:11:22:aa:bb:cc")
        #expect(FlannelVTEPMAC.normalize("0E-2A-AA-BB-CC-DD") == "0e:2a:aa:bb:cc:dd")
        #expect(FlannelVTEPMAC.normalize("01:00:00:00:00:01") == nil)
        #expect(FlannelVTEPMAC.normalize("00:00:00:00:00:00") == nil)
    }

    @Test
    func rejectsInvalidStoredMACInsteadOfReplacingIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vtep-mac")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not-a-mac\n".write(to: url, atomically: true, encoding: .utf8)
        let store = FlannelVTEPMACStore(url: url)

        #expect(throws: FlannelVXLANError.persistence("stored VTEP MAC at \(url.path) is invalid")) {
            try store.loadOrCreate()
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not-a-mac\n")
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("container-flannel-vxlan-tests")
        .appendingPathComponent(UUID().uuidString)
}
