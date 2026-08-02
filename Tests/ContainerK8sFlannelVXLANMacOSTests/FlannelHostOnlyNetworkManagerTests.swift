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

import ContainerKit
import ContainerResource
import ContainerizationExtras
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelHostOnlyNetworkManagerTests {
    @Test
    func createsTracksPurgesAndRecreatesOwnedNetworkWithNewCIDR() async throws {
        let backend = MockFlannelNetworkBackend()
        let manager = ContainerKitFlannelNetworkManager(backend: backend)

        let first = try await manager.ensureHostOnlyNetwork(
            name: "kubernetes-pod",
            podCIDR: "10.250.22.19/24",
            plugin: "container-network-vmnet",
            variant: "reserved",
            knownOwnership: nil
        )
        let firstOwnership = try #require(first.ownership)
        #expect(first.created)
        #expect(firstOwnership.podCIDR == "10.250.22.0/24")
        #expect(
            await backend.networks.first?.configuration.options[
                ContainerKitFlannelNetworkManager.ownershipOptionKey
            ] == firstOwnership.ownershipID
        )
        #expect(try await manager.validateOwnedHostOnlyNetwork(ownership: firstOwnership))

        let existing = try await manager.ensureHostOnlyNetwork(
            name: "kubernetes-pod",
            podCIDR: "10.250.22.0/24",
            plugin: "container-network-vmnet",
            variant: "reserved",
            knownOwnership: firstOwnership
        )
        #expect(!existing.created)
        #expect(existing.ownership == firstOwnership)

        let purge = try await manager.purgeHostOnlyNetwork(ownership: firstOwnership)
        #expect(purge == FlannelHostOnlyNetworkPurgeResult(networkWasPresent: true, removed: true))
        #expect(await backend.networks.isEmpty)
        #expect(try await !manager.validateOwnedHostOnlyNetwork(ownership: firstOwnership))

        let second = try await manager.ensureHostOnlyNetwork(
            name: "kubernetes-pod",
            podCIDR: "10.250.31.0/24",
            plugin: "container-network-vmnet",
            variant: "reserved",
            knownOwnership: nil
        )
        #expect(second.created)
        #expect(second.ownership?.podCIDR == "10.250.31.0/24")
        #expect(second.ownership?.ownershipID != firstOwnership.ownershipID)
    }

    @Test
    func neverAdoptsOrPurgesAnUnmarkedExistingNetwork() async throws {
        let existing = try makeNetwork(
            name: "kubernetes-pod",
            podCIDR: "10.250.22.0/24",
            plugin: "container-network-vmnet",
            variant: "reserved",
            ownershipID: nil
        )
        let backend = MockFlannelNetworkBackend(networks: [existing])
        let manager = ContainerKitFlannelNetworkManager(backend: backend)
        let recorded = FlannelHostOnlyNetworkOwnership(
            name: "kubernetes-pod",
            podCIDR: "10.250.22.0/24",
            plugin: "container-network-vmnet",
            variant: "reserved",
            ownershipID: "b7656446-13bc-482b-b02c-22eb6e066a59"
        )

        let result = try await manager.ensureHostOnlyNetwork(
            name: "kubernetes-pod",
            podCIDR: "10.250.22.0/24",
            plugin: "container-network-vmnet",
            variant: "reserved",
            knownOwnership: recorded
        )
        #expect(!result.created)
        #expect(result.ownership == nil)

        await #expect(throws: FlannelVXLANError.self) {
            try await manager.validateOwnedHostOnlyNetwork(ownership: recorded)
        }
        await #expect(throws: FlannelVXLANError.self) {
            try await manager.purgeHostOnlyNetwork(ownership: recorded)
        }
        #expect(await backend.deleteCalls.isEmpty)
        #expect(await backend.networks.count == 1)
    }

    @Test
    func occupiedNetworkDeletionFailureIsFailClosed() async throws {
        let ownership = FlannelHostOnlyNetworkOwnership(
            name: "kubernetes-pod",
            podCIDR: "10.250.22.0/24",
            plugin: "container-network-vmnet",
            variant: "reserved",
            ownershipID: "b7656446-13bc-482b-b02c-22eb6e066a59"
        )
        let existing = try makeNetwork(
            name: ownership.name,
            podCIDR: ownership.podCIDR,
            plugin: ownership.plugin,
            variant: ownership.variant,
            ownershipID: ownership.ownershipID
        )
        let backend = MockFlannelNetworkBackend(networks: [existing])
        await backend.failDeletion(true)
        let manager = ContainerKitFlannelNetworkManager(backend: backend)

        await #expect(throws: FlannelVXLANError.self) {
            try await manager.purgeHostOnlyNetwork(ownership: ownership)
        }
        #expect(await backend.networks.count == 1)
        #expect(await backend.deleteCalls == ["kubernetes-pod"])
    }
}

private actor MockFlannelNetworkBackend: FlannelNetworkBackend {
    var networks: [NetworkState]
    var deleteCalls: [String] = []
    private var deletionFails = false

    init(networks: [NetworkState] = []) {
        self.networks = networks
    }

    func listNetworks() async throws -> [NetworkState] {
        networks
    }

    func createNetwork(configuration: NetworkConfiguration) async throws -> NetworkState {
        let podCIDR = try #require(configuration.ipv4Subnet?.description)
        let network = try makeNetwork(
            name: configuration.name,
            podCIDR: podCIDR,
            plugin: configuration.plugin,
            variant: try #require(configuration.options["variant"]),
            ownershipID: configuration.options[ContainerKitFlannelNetworkManager.ownershipOptionKey]
        )
        networks.append(network)
        return network
    }

    func deleteNetwork(id: String) async throws {
        deleteCalls.append(id)
        if deletionFails {
            throw FlannelVXLANError.runtime("network has active sandbox attachments")
        }
        networks.removeAll { $0.id == id }
    }

    func failDeletion(_ value: Bool) {
        deletionFails = value
    }
}

private func makeNetwork(
    name: String,
    podCIDR: String,
    plugin: String,
    variant: String,
    ownershipID: String?
) throws -> NetworkState {
    var options = ["variant": variant]
    options[ContainerKitFlannelNetworkManager.ownershipOptionKey] = ownershipID
    let configuration = try NetworkConfiguration(
        name: name,
        mode: .hostOnly,
        ipv4Subnet: try CIDRv4(podCIDR),
        plugin: plugin,
        options: options
    )
    return NetworkState(
        configuration: configuration,
        status: NetworkStatus(
            ipv4Subnet: try CIDRv4(podCIDR),
            ipv4Gateway: try IPv4Address("10.250.22.1"),
            ipv6Subnet: nil
        )
    )
}
