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

import ContainerizationExtras
import Darwin
import Foundation
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelHostIPv6GatewayTests {
    @Test func bridgePendingDoesNotWriteHostOrOwnership() throws {
        let host = try FakeFlannelGatewayHost(includeBridge: false)

        let result = try host.manager.reconcile(
            networkOwnership: host.networkOwnership,
            knownOwnership: nil
        )

        #expect(result == .bridgePending)
        #expect(host.operations.isEmpty)
        #expect(try host.ownershipStore.load() == nil)
    }

    @Test func rejectsIPv4NetworkWithoutLowerPlusOneGateway() throws {
        let host = try FakeFlannelGatewayHost(includeBridge: false)
        let invalidOwnership = FlannelHostOnlyNetworkOwnership(
            name: "kubernetes-pod",
            podCIDR: "255.255.255.255/32",
            ipv6PodCIDR: "fd42:10:244:22::/64",
            plugin: "container-network-vmnet",
            variant: "reserved",
            ownershipID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )

        #expect(throws: FlannelVXLANError.self) {
            try host.manager.reconcile(networkOwnership: invalidOwnership, knownOwnership: nil)
        }
        #expect(host.operations.isEmpty)
        #expect(try host.ownershipStore.load() == nil)
    }

    @Test func addUsesWriteAheadOwnershipAndPublishesReadyOnlyAfterReadback() throws {
        let host = try FakeFlannelGatewayHost()

        let result = try host.manager.reconcile(
            networkOwnership: host.networkOwnership,
            knownOwnership: nil
        )

        let ownership = try #require(result.ownership)
        #expect(result.isReady)
        #expect(ownership.interfaceName == "bridge100")
        #expect(ownership.ipv4Gateway == "10.250.22.1")
        #expect(ownership.ipv6Gateway == "fd42:10:244:22::1")
        #expect(ownership.phase == .owned)
        #expect(try host.ownershipStore.load() == ownership)
        #expect(host.operations == [.add("bridge100", "fd42:10:244:22::1", 64)])
    }

    @Test func crashAfterAddRecoversOnlyFromExactWriteAheadOwnership() throws {
        let host = try FakeFlannelGatewayHost(includeGateway: true)
        let addingOwnership = host.expectedOwnership(phase: .adding)
        try host.ownershipStore.save(addingOwnership)

        let result = try host.manager.reconcile(
            networkOwnership: host.networkOwnership,
            knownOwnership: addingOwnership
        )

        let recovered = try #require(result.ownership)
        #expect(recovered.phase == .owned)
        #expect(try host.ownershipStore.load() == recovered)
        #expect(host.operations.isEmpty)

        let unowned = try FakeFlannelGatewayHost(includeGateway: true)
        #expect(throws: FlannelVXLANError.self) {
            try unowned.manager.reconcile(
                networkOwnership: unowned.networkOwnership,
                knownOwnership: nil
            )
        }
        #expect(unowned.operations.isEmpty)
    }

    @Test func absentAddressWithWriteAheadOwnershipRetriesAdd() throws {
        let host = try FakeFlannelGatewayHost()
        let addingOwnership = host.expectedOwnership(phase: .adding)
        try host.ownershipStore.save(addingOwnership)

        let result = try host.manager.reconcile(
            networkOwnership: host.networkOwnership,
            knownOwnership: addingOwnership
        )

        #expect(result.isReady)
        #expect(host.operations.count == 1)
        #expect(try host.ownershipStore.load()?.phase == .owned)
    }

    @Test func tentativeAddressPersistsOwnershipButIsNotEffectiveReady() throws {
        let host = try FakeFlannelGatewayHost(flags: 0x0002)

        let result = try host.manager.reconcile(
            networkOwnership: host.networkOwnership,
            knownOwnership: nil
        )

        guard case .dadPending(let ownership) = result else {
            Issue.record("expected DAD pending")
            return
        }
        #expect(ownership.phase == .owned)
        #expect(try host.ownershipStore.load() == ownership)
    }

    @Test func duplicateAddressRollsBackExactOwnedAlias() throws {
        let host = try FakeFlannelGatewayHost(flags: 0x0004)

        #expect(throws: FlannelVXLANError.self) {
            try host.manager.reconcile(
                networkOwnership: host.networkOwnership,
                knownOwnership: nil
            )
        }

        #expect(
            host.operations == [
                .add("bridge100", "fd42:10:244:22::1", 64),
                .remove("bridge100", "fd42:10:244:22::1", 64),
            ]
        )
        #expect(!host.hasGateway)
    }

    @Test func failedVerificationRetainsWriteAheadOwnershipUntilRollbackIsProven() throws {
        let host = try FakeFlannelGatewayHost(
            addedGatewayPrefixLength: 128,
            removeMutatesAddress: false
        )

        do {
            _ = try host.manager.reconcile(
                networkOwnership: host.networkOwnership,
                knownOwnership: nil
            )
            Issue.record("expected gateway verification to fail")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("rollback could not be verified"))
            #expect(description.contains("write-ahead ownership was retained"))
        }

        #expect(try host.ownershipStore.load() == host.expectedOwnership(phase: .adding))
        #expect(host.hasGateway)
        #expect(
            host.operations == [
                .add("bridge100", "fd42:10:244:22::1", 64),
                .remove("bridge100", "fd42:10:244:22::1", 64),
            ]
        )
    }

    @Test func physicalAmbiguousOrConflictingOwnersFailWithoutMutation() throws {
        for host in [
            try FakeFlannelGatewayHost(interfaceType: UInt8(IFT_ETHER)),
            try FakeFlannelGatewayHost(additionalGatewayInterface: "bridge101"),
            try FakeFlannelGatewayHost(includeGateway: true, gatewayInterface: "bridge101"),
            try FakeFlannelGatewayHost(includeGateway: true, gatewayPrefixLength: 128),
        ] {
            #expect(throws: FlannelVXLANError.self) {
                try host.manager.reconcile(
                    networkOwnership: host.networkOwnership,
                    knownOwnership: nil
                )
            }
            #expect(host.operations.isEmpty)
        }
    }

    @Test func removalRequiresExactPersistedBridgeOwnership() throws {
        let host = try FakeFlannelGatewayHost(includeGateway: true)
        let ownership = host.expectedOwnership(phase: .owned)
        try host.ownershipStore.save(ownership)

        try host.manager.remove(ownership: ownership)

        #expect(!host.hasGateway)
        #expect(host.operations == [.remove("bridge100", "fd42:10:244:22::1", 64)])

        let changed = try FakeFlannelGatewayHost(interfaceType: UInt8(IFT_ETHER), includeGateway: true)
        #expect(throws: FlannelVXLANError.self) {
            try changed.manager.remove(ownership: ownership)
        }
        #expect(changed.operations.isEmpty)
    }

    @Test func ownershipStoreRoundTripsCanonicalExactState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-gateway-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlannelHostIPv6GatewayOwnershipStore(url: directory.appendingPathComponent("ownership.json"))
        let host = try FakeFlannelGatewayHost(ownershipStore: store)
        let ownership = host.expectedOwnership(phase: .adding)

        try store.save(ownership)

        #expect(try store.load() == ownership)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try store.remove()
        #expect(try store.load() == nil)
    }
}

extension FlannelHostIPv6GatewayReconcileResult {
    fileprivate var ownership: FlannelHostIPv6GatewayOwnership? {
        switch self {
        case .bridgePending:
            nil
        case .dadPending(let ownership), .ready(let ownership):
            ownership
        }
    }

    fileprivate var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

private enum GatewayOperation: Equatable {
    case add(String, String, UInt8)
    case remove(String, String, UInt8)
}

private final class FakeFlannelGatewayHost: @unchecked Sendable {
    let networkOwnership: FlannelHostOnlyNetworkOwnership
    let ownershipStore: any FlannelHostIPv6GatewayOwnershipStoring

    private let lock = NSLock()
    private var addresses: [FlannelHostInterfaceAddress]
    private var recordedOperations: [GatewayOperation] = []
    private let flags: UInt32
    private let addedGatewayPrefixLength: UInt8?
    private let removeMutatesAddress: Bool

    init(
        includeBridge: Bool = true,
        interfaceType: UInt8 = UInt8(IFT_BRIDGE),
        additionalGatewayInterface: String? = nil,
        includeGateway: Bool = false,
        gatewayInterface: String = "bridge100",
        gatewayPrefixLength: UInt8 = 64,
        flags: UInt32 = 0,
        addedGatewayPrefixLength: UInt8? = nil,
        removeMutatesAddress: Bool = true,
        ownershipStore: (any FlannelHostIPv6GatewayOwnershipStoring)? = nil
    ) throws {
        networkOwnership = FlannelHostOnlyNetworkOwnership(
            name: "kubernetes-pod",
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64",
            plugin: "container-network-vmnet",
            variant: "reserved",
            ownershipID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let store = ownershipStore ?? MemoryGatewayOwnershipStore()
        self.ownershipStore = store
        self.flags = flags
        self.addedGatewayPrefixLength = addedGatewayPrefixLength
        self.removeMutatesAddress = removeMutatesAddress
        var addresses: [FlannelHostInterfaceAddress] = []
        if includeBridge {
            addresses = [
                .init(interfaceName: "bridge100", value: .link(type: interfaceType)),
                .init(interfaceName: "bridge100", value: .ipv4(try IPv4Address("10.250.22.1"))),
            ]
        }
        if let additionalGatewayInterface {
            addresses.append(.init(interfaceName: additionalGatewayInterface, value: .link(type: UInt8(IFT_BRIDGE))))
            addresses.append(.init(interfaceName: additionalGatewayInterface, value: .ipv4(try IPv4Address("10.250.22.1"))))
        }
        if includeGateway {
            if gatewayInterface != "bridge100" {
                addresses.append(.init(interfaceName: gatewayInterface, value: .link(type: UInt8(IFT_BRIDGE))))
            }
            addresses.append(
                .init(
                    interfaceName: gatewayInterface,
                    value: .ipv6(try IPv6Address("fd42:10:244:22::1"), prefixLength: gatewayPrefixLength)
                ))
        }
        self.addresses = addresses
    }

    var operations: [GatewayOperation] {
        lock.withLock { recordedOperations }
    }

    var hasGateway: Bool {
        lock.withLock {
            addresses.contains {
                guard case .ipv6(let address, _) = $0.value else { return false }
                return address.description == "fd42:10:244:22::1"
            }
        }
    }

    var manager: SystemFlannelHostIPv6GatewayManager {
        SystemFlannelHostIPv6GatewayManager(
            ownershipStore: ownershipStore,
            addressSnapshotProvider: { [self] in lock.withLock { addresses } },
            addAddress: { [self] interfaceName, address, prefixLength in
                lock.withLock {
                    recordedOperations.append(.add(interfaceName, address.description, prefixLength))
                    addresses.append(
                        .init(
                            interfaceName: interfaceName,
                            value: .ipv6(address, prefixLength: addedGatewayPrefixLength ?? prefixLength)
                        )
                    )
                }
                return 0
            },
            removeAddress: { [self] interfaceName, address, prefixLength in
                lock.withLock {
                    recordedOperations.append(.remove(interfaceName, address.description, prefixLength))
                    if removeMutatesAddress {
                        addresses.removeAll {
                            guard $0.interfaceName == interfaceName,
                                case .ipv6(let currentAddress, _) = $0.value
                            else { return false }
                            return currentAddress == address
                        }
                    }
                }
                return 0
            },
            flagsProvider: { [flags] _, _ in (0, flags) }
        )
    }

    func expectedOwnership(
        phase: FlannelHostIPv6GatewayOwnershipPhase
    ) -> FlannelHostIPv6GatewayOwnership {
        FlannelHostIPv6GatewayOwnership(
            networkName: networkOwnership.name,
            networkOwnershipID: networkOwnership.ownershipID,
            ipv4PodCIDR: networkOwnership.podCIDR,
            ipv6PodCIDR: networkOwnership.ipv6PodCIDR!,
            interfaceName: "bridge100",
            ipv4Gateway: "10.250.22.1",
            ipv6Gateway: "fd42:10:244:22::1",
            phase: phase
        )
    }
}

private final class MemoryGatewayOwnershipStore: FlannelHostIPv6GatewayOwnershipStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: FlannelHostIPv6GatewayOwnership?

    func load() throws -> FlannelHostIPv6GatewayOwnership? {
        lock.withLock { value }
    }

    func save(_ ownership: FlannelHostIPv6GatewayOwnership) throws {
        lock.withLock { value = ownership }
    }

    func remove() throws {
        lock.withLock { value = nil }
    }
}
