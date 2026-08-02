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

struct FlannelCleanupStateTests {
    @Test
    func persistsCanonicalOwnedStateAndRemovesItIdempotently() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-cleanup-state-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlannelOwnershipStateStore(url: directory.appendingPathComponent("state/ownership.json"))

        try store.save(
            FlannelOwnershipState(
                interfaceName: "utun42",
                localPodCIDR: "10.250.22.19/24",
                routePodCIDRs: ["10.250.5.9/24", "10.250.2.0/24", "10.250.5.0/24"]
            ))

        let loadedState = try store.load()
        let state = try #require(loadedState)
        #expect(state.localPodCIDR == "10.250.22.0/24")
        #expect(state.routePodCIDRs == ["10.250.2.0/24", "10.250.5.0/24"])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try store.remove()
        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test
    func rejectsStateThatCouldTargetAnUnownedInterfaceOrLocalRoute() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-cleanup-state-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlannelOwnershipStateStore(url: directory.appendingPathComponent("ownership.json"))

        #expect(throws: FlannelVXLANError.self) {
            try store.save(
                FlannelOwnershipState(
                    interfaceName: "en0",
                    localPodCIDR: "10.250.22.0/24",
                    routePodCIDRs: ["10.250.2.0/24"]
                ))
        }
        #expect(throws: FlannelVXLANError.self) {
            try store.save(
                FlannelOwnershipState(
                    interfaceName: "utun42",
                    localPodCIDR: "10.250.22.0/24",
                    routePodCIDRs: ["10.250.22.128/25"]
                ))
        }
    }

    @Test
    func persistsCanonicalHostOnlyNetworkOwnership() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-network-ownership-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlannelHostOnlyNetworkOwnershipStore(url: directory.appendingPathComponent("network.json"))

        try store.save(
            FlannelHostOnlyNetworkOwnership(
                name: "kubernetes-pod",
                podCIDR: "10.250.22.19/24",
                plugin: "container-network-vmnet",
                variant: "reserved",
                ownershipID: "B7656446-13BC-482B-B02C-22EB6E066A59"
            ))

        let loadedState = try store.load()
        let state = try #require(loadedState)
        #expect(state.podCIDR == "10.250.22.0/24")
        #expect(state.ownershipID == "b7656446-13bc-482b-b02c-22eb6e066a59")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func rejectsInvalidHostOnlyNetworkOwnership() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-network-ownership-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlannelHostOnlyNetworkOwnershipStore(url: directory.appendingPathComponent("network.json"))

        #expect(throws: FlannelVXLANError.self) {
            try store.save(
                FlannelHostOnlyNetworkOwnership(
                    name: "kubernetes-pod",
                    podCIDR: "10.250.22.0/24",
                    plugin: "container-network-vmnet",
                    variant: "reserved",
                    ownershipID: "not-an-id"
                ))
        }
    }
}
