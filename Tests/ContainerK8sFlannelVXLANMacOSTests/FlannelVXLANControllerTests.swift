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

import ContainerCRIShimMacOS
import Foundation
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelVXLANControllerTests {
    @Test
    func reconcilesPodCIDRNetworkTunnelRoutesAnnotationsAndReadiness() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.19/24")
        let controller = try fixture.makeController()

        let first = try await controller.runOnce()
        let second = try await controller.runOnce()

        #expect(first.localNetwork.podCIDR == "10.250.22.0/24")
        #expect(first.underlay.ipv4Address == "192.0.2.24")
        #expect(first.mtu == 1450)
        #expect(first.peers.map(\.nodeName) == ["linux-a", "windows-a"])
        #expect(second.interfaceName == first.interfaceName)
        #expect(fixture.tunnelBox.createdConfigurations.count == 1)
        #expect(fixture.tunnelBox.tunnel.peerUpdates.count == 2)
        #expect(Set(fixture.system.addedRoutes.map(\.podCIDR)) == ["10.250.2.0/24", "10.250.5.0/24"])
        #expect(fixture.system.ensuredRoutes.count == 4)
        #expect(
            fixture.system.validatedUnderlayRoutes.map { "\($0.destination)|\($0.interface)" } == [
                "198.18.55.8|en7",
                "198.51.100.140|en7",
                "198.18.55.8|en7",
                "198.51.100.140|en7",
            ])
        #expect(fixture.system.tunnelLocalAddress == "10.250.22.0")

        let networkCalls = await fixture.networkManager.calls
        #expect(networkCalls.count == 2)
        #expect(networkCalls.first?.name == "kubernetes-pod")
        #expect(networkCalls.first?.podCIDR == "10.250.22.0/24")
        #expect(fixture.hostIPv6GatewayManager.reconcileCount == 0)

        let patches = await fixture.kubernetes.patches
        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        #expect(patches.count == 2)
        #expect(patches.last?.values[keys.publicIP] == "192.0.2.24")
        #expect(patches.last?.values[keys.backendType] == "vxlan")
        #expect(patches.last?.values[keys.backendData]?.contains("4096") == true)
        #expect(patches.last?.removals.contains(keys.publicIPv6) == true)
        #expect(patches.last?.removals.contains(keys.backendV6Data) == true)

        let ready = try await fixture.stateStore.loadReadyState(path: fixture.config.readyStatePath)
        #expect(ready?.networkName == "kubernetes-pod")
        #expect(ready?.podCIDR == "10.250.22.0/24")
        #expect(ready?.runtimeGeneration == 1)
        #expect(ready?.mtu == 1_450)
        #expect(ready?.ipv4Ready == true)
        #expect(ready?.ipv6Ready == nil)
        #expect(ready?.expiresAtUnixSeconds == 1_700_000_020)

        let ownershipStore = FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath)
        let loadedOwnership = try ownershipStore.load()
        let ownership = try #require(loadedOwnership)
        #expect(ownership.interfaceName == first.interfaceName)
        #expect(ownership.localPodCIDR == "10.250.22.0/24")
        #expect(ownership.routePodCIDRs == ["10.250.2.0/24", "10.250.5.0/24"])
        #expect(ownership.schemaVersion == 1)

        let cleanup = try await controller.shutdown()
        #expect(cleanup.removedRoutes == ["10.250.2.0/24", "10.250.5.0/24"])
        #expect(cleanup.restoredForwardingFamilies == [.ipv4])
        #expect(cleanup.stoppedTunnel)
        #expect(cleanup.removedNodeAnnotations)
        #expect(cleanup.nodeAnnotationAttempts == 1)
        #expect(fixture.system.removedRoutes.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.config.readyStatePath))
        #expect(try ownershipStore.load() == nil)
        let networkOwnershipStore = FlannelHostOnlyNetworkOwnershipStore(path: fixture.config.networkOwnershipStatePath)
        #expect(try networkOwnershipStore.load()?.name == "kubernetes-pod")
        let finalPatches = await fixture.kubernetes.patches
        #expect(finalPatches.last?.removals.contains(keys.backendData) == true)
    }

    @Test
    func reconcilesFeatureGatedDualStackIndependently() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.19/24",
            ipv6PodCIDR: "fd42:10:244:22::19/64"
        )
        let controller = try fixture.makeController()

        let result = try await controller.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == true)
        #expect(result.mtu == 1_430)
        #expect(result.localIPv6Network?.podCIDR == "fd42:10:244:22::/64")
        #expect(result.ipv6InterfaceName == "utun43")
        #expect(result.ipv6Peers.map(\.nodeName) == ["linux-a"])
        #expect(
            result.issues.contains {
                $0.id == "local/host-ipv6-gateway" && $0.severity == .warning
            }
        )
        #expect(fixture.hostIPv6GatewayManager.reconcileCount == 1)
        #expect(
            result.issues.contains {
                $0.id == "node/windows-a/ipv6-unsupported" && $0.severity == .warning
            }
        )

        let networkCalls = await fixture.networkManager.calls
        #expect(networkCalls.count == 1)
        #expect(networkCalls.first?.ipv6PodCIDR == "fd42:10:244:22::/64")
        #expect(fixture.forwardingManager.ensureCalls == [.ipv4, .ipv6])
        #expect(fixture.system.ipv6TunnelLocalAddress == "fd42:10:244:22::")
        #expect(
            fixture.system.validatedIPv6UnderlayRoutes.map { "\($0.destination)|\($0.interface)" }
                == ["fd31::8|en7"]
        )
        #expect(
            fixture.system.ensuredIPv6Routes.map { "\($0.podCIDR)|\($0.interface)" }
                == ["fd42:10:244:2::/64|utun43"]
        )

        let configuration = try #require(fixture.ipv6TunnelBox.createdConfigurations.first)
        #expect(configuration.mtu == 1_430)
        #expect(configuration.bindIPv6 == "fd31::24")
        #expect(configuration.localPodCIDR == "fd42:10:244:22::/64")
        #expect(configuration.localVTEPMAC == "02:aa:bb:cc:dd:ff")
        #expect(fixture.ipv6TunnelBox.tunnel.peerUpdates.first?.map(\.nodeName) == ["linux-a"])

        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.values[keys.publicIPv6] == "fd31::24")
        #expect(patch.values[keys.backendV6Data]?.contains("02:aa:bb:cc:dd:ff") == true)
        #expect(!patch.removals.contains(keys.publicIPv6))

        let ready = try #require(
            await fixture.stateStore.loadReadyState(path: fixture.config.readyStatePath)
        )
        #expect(ready.podCIDRs.ipv4 == "10.250.22.0/24")
        #expect(ready.podCIDRs.ipv6 == "fd42:10:244:22::/64")
        #expect(ready.ipv4Ready)
        #expect(ready.ipv6Ready == true)

        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.ipv6InterfaceName == "utun43")
        #expect(ownership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(ownership.ipv6RoutePodCIDRs == ["fd42:10:244:2::/64"])
        #expect(ownership.schemaVersion == 2)

        let cleanup = try await controller.shutdown()
        #expect(cleanup.removedIPv6Routes == ["fd42:10:244:2::/64"])
        #expect(cleanup.restoredForwardingFamilies == [.ipv4, .ipv6])
        #expect(cleanup.stoppedIPv6Tunnel)
        #expect(fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        #expect(fixture.forwardingManager.restoreCalls == [.ipv4, .ipv6])
        #expect(try fixture.forwardingManager.ownedFamilies().isEmpty)
    }

    @Test
    func keepsBootstrapReadyWhileGatewayDADIsPending() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        fixture.hostIPv6GatewayManager.mode = .dadPending
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )

        let controller = try fixture.makeController()
        let result = try await controller.runOnce()

        #expect(result.ipv6Ready == true)
        #expect(
            result.issues.contains {
                $0.id == "local/host-ipv6-gateway" && $0.severity == .warning
            }
        )
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load()?.phase == .owned)

        _ = try await controller.shutdown()
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load() == nil)
        #expect(fixture.hostIPv6GatewayManager.removeCount == 1)
    }

    @Test
    func marksIPv6NotReadyAndWithdrawsAnnotationOnGatewayHardFailure() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        fixture.hostIPv6GatewayManager.mode = .failureAfterWriteAhead
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )

        let result = try await fixture.makeController().runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == false)
        #expect(result.ipv6InterfaceName == nil)
        #expect(fixture.ipv6TunnelBox.createdConfigurations.isEmpty)
        #expect(fixture.system.ensuredIPv6Routes.isEmpty)
        #expect(fixture.hostIPv6GatewayManager.removeAttemptCount == 1)
        #expect(fixture.hostIPv6GatewayManager.removeCount == 1)
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load() == nil)
        #expect(
            result.issues.contains {
                $0.id == "local/host-ipv6-gateway" && $0.severity == .error
            }
        )
        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.values[keys.publicIPv6] == nil)
        #expect(patch.removals.contains(keys.publicIPv6))
        let ready = try #require(
            await fixture.stateStore.loadReadyState(path: fixture.config.readyStatePath)
        )
        #expect(ready.ipv6Ready == false)
    }

    @Test
    func gatewayHardFailureWithdrawsExistingIPv6Dataplane() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        fixture.hostIPv6GatewayManager.mode = .ready
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        let ready = try await controller.runOnce()
        #expect(ready.ipv6Ready == true)
        #expect(ready.ipv6InterfaceName == "utun43")
        fixture.hostIPv6GatewayManager.mode = .failureAfterWriteAhead

        let degraded = try await controller.runOnce()

        #expect(degraded.ipv4Ready)
        #expect(degraded.ipv6Ready == false)
        #expect(degraded.ipv6InterfaceName == nil)
        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.ipv6TunnelBox.createdConfigurations.count == 1)
        #expect(fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        #expect(
            fixture.system.removedIPv6Routes.map { "\($0.podCIDR)|\($0.interface)" }
                == ["fd42:10:244:2::/64|utun43"]
        )
        #expect(fixture.hostIPv6GatewayManager.removeAttemptCount == 1)
        #expect(fixture.hostIPv6GatewayManager.removeCount == 1)
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load() == nil)
        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 1)
        #expect(ownership.ipv6InterfaceName == nil)
        #expect(ownership.ipv6RoutePodCIDRs == nil)
    }

    @Test
    func ipv4OnlyRestartRefusesPersistedHostIPv6GatewayOwnership() async throws {
        let fixture = try ControllerFixture()
        try fixture.hostIPv6GatewayOwnershipStore.save(
            FlannelHostIPv6GatewayOwnership(
                networkName: "kubernetes-pod",
                networkOwnershipID: "b7656446-13bc-482b-b02c-22eb6e066a59",
                ipv4PodCIDR: "10.250.22.0/24",
                ipv6PodCIDR: "fd42:10:244:22::/64",
                interfaceName: "bridge100",
                ipv4Gateway: "10.250.22.1",
                ipv6Gateway: "fd42:10:244:22::1"
            ))
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.makeController().runOnce()
        }

        #expect(fixture.hostIPv6GatewayManager.reconcileCount == 0)
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load() != nil)
        #expect(
            try await fixture.stateStore.loadReadyState(path: fixture.config.readyStatePath) == nil
        )
    }

    @Test
    func degradesOnlyIPv6WhenItsUnderlayRouteFails() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        fixture.system.failIPv6UnderlayRouteValidation()
        let controller = try fixture.makeController()

        let result = try await controller.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == false)
        #expect(result.issues.contains { $0.id == "local/ipv6-dataplane" && $0.severity == .error })
        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.tunnelBox.tunnel.peerUpdates.count == 1)
        #expect(fixture.ipv6TunnelBox.createdConfigurations.isEmpty)

        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.values[keys.publicIP] == "192.0.2.24")
        #expect(patch.values[keys.publicIPv6] == nil)
        #expect(patch.removals.contains(keys.publicIPv6))
        #expect(patch.removals.contains(keys.backendV6Data))

        let ready = try #require(
            await fixture.stateStore.loadReadyState(path: fixture.config.readyStatePath)
        )
        #expect(ready.ipv4Ready)
        #expect(ready.ipv6Ready == false)
        #expect(ready.podCIDRs.ipv6 == "fd42:10:244:22::/64")
    }

    @Test
    func withdrawsPreviouslyReadyIPv6DataplaneWhenItDegrades() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        let ready = try await controller.runOnce()
        #expect(ready.ipv6Ready == true)
        fixture.system.failIPv6UnderlayRouteValidation()

        let degraded = try await controller.runOnce()

        #expect(degraded.ipv4Ready)
        #expect(degraded.ipv6Ready == false)
        #expect(degraded.ipv6InterfaceName == nil)
        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        #expect(
            fixture.system.removedIPv6Routes.map(\.podCIDR)
                == ["fd42:10:244:2::/64"]
        )
        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.ipv6InterfaceName == nil)
        #expect(ownership.schemaVersion == 1)
        #expect(fixture.forwardingManager.restoreCalls == [.ipv6])
        #expect(try fixture.forwardingManager.ownedFamilies() == [.ipv4])

        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.removals.contains(keys.publicIPv6))
        #expect(patch.removals.contains(keys.backendV6Data))
    }

    @Test
    func retriesFailedIPv6ForwardingRestorationWithoutWithdrawingIPv4() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        fixture.forwardingManager.failRestore(.ipv6)
        fixture.system.failIPv6UnderlayRouteValidation()

        let firstDegraded = try await controller.runOnce()

        #expect(firstDegraded.ipv4Ready)
        #expect(firstDegraded.ipv6Ready == false)
        #expect(firstDegraded.issues.contains { $0.id == "local/ipv6-family-withdrawal" })
        #expect(fixture.forwardingManager.restoreCalls == [.ipv6])
        #expect(try fixture.forwardingManager.ownedFamilies() == [.ipv4, .ipv6])

        fixture.forwardingManager.failRestore(.ipv6, enabled: false)
        let secondDegraded = try await controller.runOnce()

        #expect(secondDegraded.ipv4Ready)
        #expect(secondDegraded.ipv6Ready == false)
        #expect(fixture.forwardingManager.restoreCalls == [.ipv6, .ipv6])
        #expect(try fixture.forwardingManager.ownedFamilies() == [.ipv4])
    }

    @Test
    func withdrawsReadyIPv6DataplaneWhenClusterDisablesIPv6() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        let ready = try await controller.runOnce()
        #expect(ready.ipv6Ready == true)
        let ipv4PeerUpdates = fixture.tunnelBox.tunnel.peerUpdates.count
        let removedIPv4Routes = fixture.system.removedRoutes.count
        await fixture.kubernetes.setNetworkConfig(
            #"{"Network":"10.250.0.0/16","EnableIPv4":true,"EnableIPv6":false,"Backend":{"Type":"vxlan","VNI":4096,"Port":4789,"MTU":1480}}"#
        )

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.runOnce()
        }

        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.tunnelBox.tunnel.peerUpdates.count == ipv4PeerUpdates)
        #expect(fixture.system.removedRoutes.count == removedIPv4Routes)
        #expect(fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        #expect(fixture.system.removedIPv6Routes.map(\.podCIDR) == ["fd42:10:244:2::/64"])
        #expect(!FileManager.default.fileExists(atPath: fixture.config.readyStatePath))

        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 1)
        #expect(ownership.ipv6InterfaceName == nil)
        #expect(ownership.ipv6RoutePodCIDRs == nil)

        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.values.isEmpty)
        #expect(patch.removals == [keys.publicIPv6, keys.backendV6Data])
    }

    @Test
    func withdrawsReadyIPv6DataplaneWhenRuntimeIPv6Disappears() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        let ready = try await controller.runOnce()
        #expect(ready.ipv6Ready == true)
        let ipv4PeerUpdates = fixture.tunnelBox.tunnel.peerUpdates.count
        let removedIPv4Routes = fixture.system.removedRoutes.count
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.runOnce()
        }

        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.tunnelBox.tunnel.peerUpdates.count == ipv4PeerUpdates)
        #expect(fixture.system.removedRoutes.count == removedIPv4Routes)
        #expect(fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        #expect(fixture.system.removedIPv6Routes.map(\.podCIDR) == ["fd42:10:244:2::/64"])
        #expect(!FileManager.default.fileExists(atPath: fixture.config.readyStatePath))

        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 1)
        #expect(ownership.ipv6InterfaceName == nil)
        #expect(ownership.ipv6RoutePodCIDRs == nil)

        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.values.isEmpty)
        #expect(patch.removals == [keys.publicIPv6, keys.backendV6Data])
    }

    @Test
    func invalidIPv6IntentRemovesOwnedHostGateway() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        fixture.hostIPv6GatewayManager.mode = .ready
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load() != nil)
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.runOnce()
        }

        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        #expect(fixture.hostIPv6GatewayManager.removeAttemptCount == 1)
        #expect(fixture.hostIPv6GatewayManager.removeCount == 1)
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load() == nil)
        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 1)
        #expect(ownership.ipv6InterfaceName == nil)
        #expect(ownership.ipv6RoutePodCIDRs == nil)
    }

    @Test
    func invalidIPv6IntentRetainsGatewayOwnershipAndRetriesRemoval() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        fixture.hostIPv6GatewayManager.mode = .ready
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        fixture.hostIPv6GatewayManager.failNextRemovals(1)
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")

        do {
            _ = try await controller.runOnce()
            Issue.record("invalid IPv6 intent unexpectedly completed after gateway removal failure")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("remove owned host IPv6 gateway"))
            #expect(message.contains("IPv6 family withdrawal incomplete"))
        }

        #expect(fixture.hostIPv6GatewayManager.removeAttemptCount == 1)
        #expect(fixture.hostIPv6GatewayManager.removeCount == 0)
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load() != nil)

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.runOnce()
        }

        #expect(fixture.hostIPv6GatewayManager.removeAttemptCount == 2)
        #expect(fixture.hostIPv6GatewayManager.removeCount == 1)
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load() == nil)
    }

    @Test
    func invalidIPv6IntentRetainsCleanupOwnershipWhenWithdrawalFails() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        fixture.ipv6TunnelBox.tunnel.failStops(true)
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")

        do {
            _ = try await controller.runOnce()
            Issue.record("invalid IPv6 intent unexpectedly remained ready")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("IPv6 intent validation failed"))
            #expect(message.contains("IPv6 family withdrawal incomplete"))
            #expect(message.contains("IPv4 dataplane was retained"))
        }

        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.ipv6TunnelBox.tunnel.isRunning)
        #expect(!FileManager.default.fileExists(atPath: fixture.config.readyStatePath))
        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 2)
        #expect(ownership.ipv6InterfaceName == "utun43")
        #expect(ownership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(ownership.ipv6RoutePodCIDRs == ["fd42:10:244:2::/64"])

        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.removals == [keys.publicIPv6, keys.backendV6Data])
    }

    @Test
    func invalidIPv6IntentRetainsCleanupOwnershipWhenAnnotationRemovalFails() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        await fixture.kubernetes.failNextAnnotationPatches(1)
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")

        do {
            _ = try await controller.runOnce()
            Issue.record("invalid IPv6 intent unexpectedly remained ready")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("IPv6 family withdrawal incomplete"))
            #expect(message.contains("remove IPv6 Node annotations"))
            #expect(message.contains("IPv4 dataplane was retained"))
        }

        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        #expect(!FileManager.default.fileExists(atPath: fixture.config.readyStatePath))
        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 2)
        #expect(ownership.ipv6InterfaceName == "utun43")
        #expect(ownership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(ownership.ipv6RoutePodCIDRs == ["fd42:10:244:2::/64"])

        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.removals == [keys.publicIPv6, keys.backendV6Data])
    }

    @Test
    func rollsBackFailedIPv6TunnelWithoutStoppingIPv4() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        fixture.hostIPv6GatewayManager.mode = .ready
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        fixture.ipv6TunnelBox.tunnel.failPeerUpdates(true)
        let controller = try fixture.makeController()

        let result = try await controller.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == false)
        #expect(result.ipv6InterfaceName == nil)
        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        #expect(fixture.hostIPv6GatewayManager.removeAttemptCount == 1)
        #expect(fixture.hostIPv6GatewayManager.removeCount == 1)
        #expect(try fixture.hostIPv6GatewayOwnershipStore.load() == nil)
        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.ipv6InterfaceName == nil)
        #expect(ownership.ipv6RoutePodCIDRs == nil)
        #expect(ownership.schemaVersion == 1)
    }

    @Test
    func retainsIPv6OwnershipWhenDegradedCleanupFails() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        fixture.ipv6TunnelBox.tunnel.failPeerUpdates(true)
        fixture.ipv6TunnelBox.tunnel.failStops(true)
        let controller = try fixture.makeController()

        let result = try await controller.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == false)
        #expect(result.issues.contains { $0.id == "local/ipv6-dataplane-cleanup" })
        #expect(result.issues.contains { $0.id == "local/ipv6-family-withdrawal" })
        #expect(fixture.ipv6TunnelBox.tunnel.isRunning)
        #expect(!fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.ipv6InterfaceName == "utun43")
        #expect(ownership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(ownership.schemaVersion == 2)
    }

    @Test
    func crashRestartKeepsNewIPv6OwnershipWhenRebuildCleanupFailsAfterOldInterfaceDisappears() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let originalController = try fixture.makeController()
        _ = try await originalController.runOnce()

        let restartedIPv4TunnelBox = MockTunnelBox()
        let restartedIPv6TunnelBox = MockIPv6TunnelBox(interfaceName: "utun44")
        restartedIPv6TunnelBox.tunnel.failPeerUpdates(true)
        restartedIPv6TunnelBox.tunnel.failStops(true)
        let recordingOwnershipStore = RecordingOwnershipStateStore(
            path: fixture.config.ownershipStatePath
        )
        let restartedController = try fixture.makeController(
            tunnelBox: restartedIPv4TunnelBox,
            ipv6TunnelBox: restartedIPv6TunnelBox,
            ownershipStateStore: recordingOwnershipStore
        )

        let result = try await restartedController.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == false)
        #expect(result.issues.contains { $0.id == "local/ipv6-dataplane-cleanup" })
        #expect(result.issues.contains { $0.id == "local/ipv6-family-withdrawal" })
        #expect(restartedIPv4TunnelBox.tunnel.isRunning)
        #expect(restartedIPv6TunnelBox.createdConfigurations.count == 1)
        #expect(restartedIPv6TunnelBox.tunnel.isRunning)
        #expect(fixture.system.removedRoutes.isEmpty)
        #expect(
            fixture.system.removedIPv6Routes.map { "\($0.podCIDR)|\($0.interface)" }
                == ["fd42:10:244:2::/64|utun43"]
        )
        #expect(recordingOwnershipStore.savedStates.first?.schemaVersion == 2)
        #expect(recordingOwnershipStore.savedStates.first?.ipv6InterfaceName == "utun43")

        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 2)
        #expect(ownership.ipv6InterfaceName == "utun44")
        #expect(ownership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(ownership.ipv6RoutePodCIDRs == [])
    }

    @Test
    func crashRestartRefusesToReplacePersistedIPv6InterfaceThatStillExists() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let originalController = try fixture.makeController()
        _ = try await originalController.runOnce()
        fixture.system.setInterface("utun43", exists: true)

        let restartedIPv4TunnelBox = MockTunnelBox()
        let restartedIPv6TunnelBox = MockIPv6TunnelBox(interfaceName: "utun44")
        let restartedController = try fixture.makeController(
            tunnelBox: restartedIPv4TunnelBox,
            ipv6TunnelBox: restartedIPv6TunnelBox
        )

        let result = try await restartedController.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == false)
        #expect(result.issues.contains { $0.id == "local/ipv6-dataplane-cleanup" })
        #expect(result.issues.contains { $0.id == "local/ipv6-family-withdrawal" })
        #expect(restartedIPv4TunnelBox.tunnel.isRunning)
        #expect(restartedIPv6TunnelBox.createdConfigurations.isEmpty)
        #expect(fixture.system.removedRoutes.isEmpty)

        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 2)
        #expect(ownership.ipv6InterfaceName == "utun43")
        #expect(ownership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(ownership.ipv6RoutePodCIDRs == ["fd42:10:244:2::/64"])
    }

    @Test
    func crashRestartRetainsPersistedIPv6OwnershipWhenRouteCleanupFails() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let originalController = try fixture.makeController()
        _ = try await originalController.runOnce()
        fixture.system.failNextIPv6RouteRemovals(1)

        let restartedIPv4TunnelBox = MockTunnelBox()
        let restartedIPv6TunnelBox = MockIPv6TunnelBox(interfaceName: "utun44")
        let restartedController = try fixture.makeController(
            tunnelBox: restartedIPv4TunnelBox,
            ipv6TunnelBox: restartedIPv6TunnelBox
        )

        let result = try await restartedController.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == false)
        #expect(result.issues.contains { $0.id == "local/ipv6-dataplane-cleanup" })
        #expect(result.issues.contains { $0.id == "local/ipv6-family-withdrawal" })
        #expect(restartedIPv4TunnelBox.tunnel.isRunning)
        #expect(restartedIPv6TunnelBox.createdConfigurations.isEmpty)
        #expect(fixture.system.removedRoutes.isEmpty)
        #expect(fixture.system.removedIPv6Routes.isEmpty)

        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 2)
        #expect(ownership.ipv6InterfaceName == "utun43")
        #expect(ownership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(ownership.ipv6RoutePodCIDRs == ["fd42:10:244:2::/64"])

        let recovered = try await restartedController.runOnce()

        #expect(recovered.ipv4Ready)
        #expect(recovered.ipv6Ready == true)
        #expect(recovered.ipv6InterfaceName == "utun44")
        #expect(restartedIPv6TunnelBox.createdConfigurations.count == 1)
        #expect(
            fixture.system.removedIPv6Routes.map { "\($0.podCIDR)|\($0.interface)" }
                == ["fd42:10:244:2::/64|utun43"]
        )
        let recoveredOwnership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(recoveredOwnership.schemaVersion == 2)
        #expect(recoveredOwnership.ipv6InterfaceName == "utun44")
        #expect(recoveredOwnership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(recoveredOwnership.ipv6RoutePodCIDRs == ["fd42:10:244:2::/64"])
    }

    @Test
    func destroyedIPv6WrapperDoesNotReplacePersistedInterfaceAcrossReconcileRounds() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        fixture.system.setInterface("utun43", exists: true)
        fixture.system.setIPv6UnderlayRouteValidationFailure(true)

        let firstDegraded = try await controller.runOnce()

        #expect(firstDegraded.ipv4Ready)
        #expect(firstDegraded.ipv6Ready == false)
        #expect(firstDegraded.issues.contains { $0.id == "local/ipv6-dataplane-cleanup" })
        #expect(firstDegraded.issues.contains { $0.id == "local/ipv6-family-withdrawal" })
        #expect(fixture.ipv6TunnelBox.tunnel.wasDestroyed)
        #expect(!fixture.ipv6TunnelBox.tunnel.isRunning)
        #expect(fixture.ipv6TunnelBox.createdConfigurations.count == 1)
        var ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 2)
        #expect(ownership.ipv6InterfaceName == "utun43")
        #expect(ownership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(ownership.ipv6RoutePodCIDRs == ["fd42:10:244:2::/64"])

        fixture.system.setIPv6UnderlayRouteValidationFailure(false)
        let secondDegraded = try await controller.runOnce()

        #expect(secondDegraded.ipv4Ready)
        #expect(secondDegraded.ipv6Ready == false)
        #expect(secondDegraded.issues.contains { $0.id == "local/ipv6-dataplane-cleanup" })
        #expect(secondDegraded.issues.contains { $0.id == "local/ipv6-family-withdrawal" })
        #expect(fixture.ipv6TunnelBox.createdConfigurations.count == 1)
        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.system.removedRoutes.isEmpty)
        ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.schemaVersion == 2)
        #expect(ownership.ipv6InterfaceName == "utun43")
        #expect(ownership.localIPv6PodCIDR == "fd42:10:244:22::/64")
        #expect(ownership.ipv6RoutePodCIDRs == ["fd42:10:244:2::/64"])
    }

    @Test
    func missingIPv6PeerBackendAnnotationSkipsPeerButPublishesLocalReadiness() async throws {
        let fixture = try ControllerFixture(
            dualStackEnabled: true,
            includeLinuxIPv6BackendData: false
        )
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()

        let result = try await controller.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == true)
        #expect(result.ipv6Peers.isEmpty)
        #expect(result.issues.contains { $0.id == "node/linux-a/backend-v6-data" })
        #expect(!result.issues.contains { $0.id == "local/ipv6-dataplane" })
        #expect(fixture.ipv6TunnelBox.createdConfigurations.count == 1)
        #expect(fixture.ipv6TunnelBox.tunnel.peerUpdates == [[]])

        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.values[keys.publicIPv6] == "fd31::24")
        #expect(patch.values[keys.backendV6Data] != nil)
        #expect(!patch.removals.contains(keys.publicIPv6))
    }

    @Test
    func missingNodeInternalIPv6UsesValidatedUnderlayWithWarning() async throws {
        let fixture = try ControllerFixture(
            dualStackEnabled: true,
            includeNodeInternalIPv6: false
        )
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()

        let result = try await controller.runOnce()

        #expect(result.ipv6Ready == true)
        #expect(
            result.issues.contains {
                $0.id == "local/internal-ipv6" && $0.severity == .warning
            }
        )
        #expect(fixture.ipv6TunnelBox.createdConfigurations.first?.bindIPv6 == "fd31::24")
    }

    @Test
    func mismatchedNodeInternalIPv6DegradesOnlyIPv6() async throws {
        let fixture = try ControllerFixture(
            dualStackEnabled: true,
            nodeInternalIPv6Override: "fd31::99"
        )
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()

        let result = try await controller.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == false)
        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.ipv6TunnelBox.createdConfigurations.isEmpty)
        #expect(
            result.issues.contains {
                $0.id == "local/ipv6-dataplane"
                    && $0.message.contains("Node InternalIPv6 fd31::99 does not match")
            }
        )
    }

    @Test
    func rejectsIPv6VXLANMTUThatExceedsUnderlay() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true, dualStackBackendMTU: 1_500)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()

        let result = try await controller.runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == false)
        #expect(
            result.issues.contains {
                $0.id == "local/ipv6-dataplane"
                    && $0.message.contains("set Backend.MTU to 1480 or lower")
            }
        )
        #expect(fixture.ipv6TunnelBox.createdConfigurations.isEmpty)
        #expect(fixture.system.validatedIPv6UnderlayRoutes.isEmpty)
    }

    @Test
    func dualStackGateRequiresRuntimeIPv6BeforeMutatingIPv4() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        let controller = try fixture.makeController()

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.runOnce()
        }

        #expect(await fixture.networkManager.calls.isEmpty)
        #expect(fixture.tunnelBox.createdConfigurations.isEmpty)
        #expect(fixture.ipv6TunnelBox.createdConfigurations.isEmpty)
    }

    @Test
    func disabledGateIgnoresClusterIPv6AndWithdrawsStaleAnnotations() async throws {
        let fixture = try ControllerFixture(
            dualStackEnabled: false,
            clusterDualStackEnabled: true
        )
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()

        let result = try await controller.runOnce()

        #expect(result.ipv6Ready == nil)
        #expect(result.localIPv6Network == nil)
        #expect(result.ipv6Peers.isEmpty)
        #expect(result.issues.allSatisfy { !$0.id.contains("ipv6") })
        #expect(await fixture.networkManager.calls.first?.ipv6PodCIDR == nil)
        #expect(fixture.ipv6TunnelBox.createdConfigurations.isEmpty)
        #expect(fixture.forwardingManager.ensureCalls == [.ipv4])

        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        let patch = try #require(await fixture.kubernetes.patches.last)
        #expect(patch.removals.contains(keys.publicIPv6))
        #expect(patch.removals.contains(keys.backendV6Data))
        let ready = try #require(
            await fixture.stateStore.loadReadyState(path: fixture.config.readyStatePath)
        )
        #expect(ready.podCIDRs.ipv6 == nil)
        #expect(ready.ipv6Ready == nil)
    }

    @Test
    func disabledGateRestoresResidualIPv6ForwardingBeforeReconcilingIPv4() async throws {
        let fixture = try ControllerFixture(
            dualStackEnabled: false,
            clusterDualStackEnabled: true
        )
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        try fixture.forwardingManager.ensureEnabled(.ipv6)

        let result = try await fixture.makeController().runOnce()

        #expect(result.ipv4Ready)
        #expect(result.ipv6Ready == nil)
        #expect(fixture.forwardingManager.restoreCalls == [.ipv6])
        #expect(try fixture.forwardingManager.ownedFamilies() == [.ipv4])
    }

    @Test
    func disabledGateRefusesToOverwritePersistedIPv6Ownership() async throws {
        let fixture = try ControllerFixture()
        try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).save(
            FlannelOwnershipState(
                interfaceName: "utun77",
                localPodCIDR: "10.250.22.0/24",
                routePodCIDRs: [],
                ipv6InterfaceName: "utun78",
                localIPv6PodCIDR: "fd42:10:244:22::/64",
                ipv6RoutePodCIDRs: ["fd42:10:244:2::/64"]
            ))
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        let controller = try fixture.makeController()

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.runOnce()
        }

        #expect(await fixture.networkManager.calls.isEmpty)
        let ownership = try #require(
            try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load()
        )
        #expect(ownership.ipv6InterfaceName == "utun78")
        #expect(ownership.ipv6RoutePodCIDRs == ["fd42:10:244:2::/64"])
    }

    @Test
    func rejectsKubeletAndNodePodCIDRMismatchAndClearsReadyState() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.250.99.0/24")
        try await fixture.stateStore.writeReadyState(
            PodNetworkReadyState(
                networkName: "kubernetes-pod",
                podCIDR: "10.250.99.0/24",
                runtimeGeneration: 1,
                mtu: 1450,
                expiresAtUnixSeconds: Int64.max
            ),
            path: fixture.config.readyStatePath
        )
        let controller = try fixture.makeController()

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.runOnce()
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.config.readyStatePath))
        #expect(fixture.tunnelBox.createdConfigurations.isEmpty)
        #expect(await fixture.networkManager.calls.isEmpty)
    }

    @Test
    func clearsReadyStateWithoutMutatingDataplaneWhenPeerUnderlayRouteIsLost() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        let networkCallsBeforeFailure = await fixture.networkManager.calls.count
        let patchesBeforeFailure = await fixture.kubernetes.patches.count
        let routeWritesBeforeFailure = fixture.system.ensuredRoutes.count
        let peerUpdatesBeforeFailure = fixture.tunnelBox.tunnel.peerUpdates.count
        fixture.system.failUnderlayRouteValidation()

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.runOnce()
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.config.readyStatePath))
        #expect(fixture.tunnelBox.createdConfigurations.count == 1)
        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.tunnelBox.tunnel.peerUpdates.count == peerUpdatesBeforeFailure)
        #expect(fixture.system.ensuredRoutes.count == routeWritesBeforeFailure)
        #expect(await fixture.networkManager.calls.count == networkCallsBeforeFailure)
        #expect(await fixture.kubernetes.patches.count == patchesBeforeFailure)
    }

    @Test
    func retriesAnnotationCleanupAndKeepsOwnershipStateUntilRetrySucceeds() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        await fixture.kubernetes.failNextAnnotationPatches(3)

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.shutdown()
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.config.readyStatePath))
        let ownershipStore = FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath)
        #expect(try ownershipStore.load() != nil)
        #expect(await fixture.kubernetes.patches.count == 4)
        #expect(fixture.system.removedRoutes.isEmpty)
        #expect(fixture.tunnelBox.tunnel.isRunning)

        let retry = try await controller.cleanup()
        #expect(retry.nodeAnnotationAttempts == 1)
        #expect(retry.removedNodeAnnotations)
        #expect(try ownershipStore.load() == nil)
        #expect(await fixture.kubernetes.patches.count == 5)
    }

    @Test
    func retriesTransientAnnotationCleanupBeforeReturning() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        await fixture.kubernetes.failNextAnnotationPatches(2)

        let cleanup = try await controller.shutdown()

        #expect(cleanup.removedNodeAnnotations)
        #expect(cleanup.nodeAnnotationAttempts == 3)
        #expect(await fixture.kubernetes.patches.count == 4)
        let ownershipStore = FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath)
        #expect(try ownershipStore.load() == nil)
    }

    @Test
    func treatsMissingNodeAsSuccessfulAnnotationRemoval() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        await fixture.kubernetes.failNextAnnotationPatchAsNotFound()

        let cleanup = try await controller.shutdown()

        #expect(cleanup.removedNodeAnnotations)
        #expect(cleanup.nodeAnnotationAttempts == 1)
        #expect(!fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.system.removedRoutes.count == 2)
        #expect(try FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath).load() == nil)
    }

    @Test
    func keepsOwnershipStateUntilFailedRouteCleanupCanBeRetried() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        fixture.system.failNextRouteRemovals(1)

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.shutdown()
        }

        let ownershipStore = FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath)
        #expect(try ownershipStore.load() != nil)
        #expect(fixture.tunnelBox.tunnel.isRunning)

        let retry = try await controller.cleanup()
        #expect(retry.removedRoutes == ["10.250.2.0/24", "10.250.5.0/24"])
        #expect(!fixture.tunnelBox.tunnel.isRunning)
        #expect(try ownershipStore.load() == nil)
    }

    @Test
    func keepsControllerAndOwnershipWhenTunnelStopFailsUntilCleanupRetry() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        fixture.tunnelBox.tunnel.failStops(true)

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.shutdown()
        }

        let ownershipStore = FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath)
        #expect(try ownershipStore.load() != nil)
        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(!fixture.tunnelBox.tunnel.wasDestroyed)

        fixture.tunnelBox.tunnel.failStops(false)
        let retry = try await controller.cleanup()
        #expect(retry.stoppedTunnel)
        #expect(fixture.tunnelBox.tunnel.wasDestroyed)
        #expect(try ownershipStore.load() == nil)
    }

    @Test
    func cleanupRetriesOnlyForwardingFamiliesWhoseRestorationFailed() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        fixture.forwardingManager.failRestore(.ipv6)

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.cleanup()
        }

        #expect(fixture.forwardingManager.restoreCalls == [.ipv4, .ipv6])
        #expect(try fixture.forwardingManager.ownedFamilies() == [.ipv6])

        fixture.forwardingManager.failRestore(.ipv6, enabled: false)
        let retry = try await controller.cleanup()

        #expect(retry.restoredForwardingFamilies == [.ipv6])
        #expect(fixture.forwardingManager.restoreCalls == [.ipv4, .ipv6, .ipv4, .ipv6])
        #expect(try fixture.forwardingManager.ownedFamilies().isEmpty)
    }

    @Test
    func cleanupValidatesForwardingOwnershipBeforeMutatingDataplane() async throws {
        let fixture = try ControllerFixture(dualStackEnabled: true)
        try await fixture.writeRuntimeState(
            podCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64"
        )
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        let patchCount = await fixture.kubernetes.patches.count
        fixture.forwardingManager.failOwnedFamiliesInspection()

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.cleanup()
        }

        #expect(fixture.system.removedRoutes.isEmpty)
        #expect(fixture.system.removedIPv6Routes.isEmpty)
        #expect(fixture.tunnelBox.tunnel.isRunning)
        #expect(fixture.ipv6TunnelBox.tunnel.isRunning)
        #expect(FileManager.default.fileExists(atPath: fixture.config.readyStatePath))
        #expect(await fixture.kubernetes.patches.count == patchCount)

        fixture.forwardingManager.failOwnedFamiliesInspection(false)
        _ = try await controller.cleanup()
    }

    @Test
    func purgesOwnedNetworkOnlyAfterDataplaneCleanup() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.250.22.0/24")
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        let purger = FlannelHostOnlyNetworkPurger(
            networkManager: fixture.networkManager,
            attachmentInspector: EmptyFlannelNetworkAttachmentInspector(),
            dataplaneOwnershipStore: FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath),
            forwardingOwnershipStore: FlannelForwardingOwnershipStore(
                path: fixture.config.forwardingOwnershipStatePath,
                requiredOwnerID: geteuid()
            ),
            networkOwnershipStore: FlannelHostOnlyNetworkOwnershipStore(path: fixture.config.networkOwnershipStatePath)
        )

        await #expect(throws: FlannelVXLANError.self) {
            try await purger.purge()
        }
        #expect(await fixture.networkManager.purgeCalls.isEmpty)

        _ = try await controller.shutdown()
        let result = try await purger.purge()
        #expect(result.networkWasPresent)
        #expect(result.removed)
        #expect(await fixture.networkManager.purgeCalls.count == 1)
        let ownershipStore = FlannelHostOnlyNetworkOwnershipStore(path: fixture.config.networkOwnershipStatePath)
        #expect(try ownershipStore.load() == nil)
    }

    @Test
    func cleansPersistedOfflineStateIdempotently() async throws {
        let fixture = try ControllerFixture()
        let ownershipStore = FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath)
        try ownershipStore.save(
            FlannelOwnershipState(
                interfaceName: "utun77",
                localPodCIDR: "10.250.22.0/24",
                routePodCIDRs: ["10.250.5.0/24", "10.250.2.0/24"],
                ipv6InterfaceName: "utun78",
                localIPv6PodCIDR: "fd42:10:244:22::/64",
                ipv6RoutePodCIDRs: ["fd42:10:244:5::/64", "fd42:10:244:2::/64"]
            ))
        try await fixture.stateStore.writeReadyState(
            PodNetworkReadyState(
                networkName: "kubernetes-pod",
                podCIDR: "10.250.22.0/24",
                runtimeGeneration: 1,
                mtu: 1450,
                expiresAtUnixSeconds: Int64.max
            ),
            path: fixture.config.readyStatePath
        )
        let controller = try fixture.makeController()

        let first = try await controller.cleanup()
        let second = try await controller.cleanup()

        #expect(first.removedRoutes == ["10.250.2.0/24", "10.250.5.0/24"])
        #expect(first.removedIPv6Routes == ["fd42:10:244:2::/64", "fd42:10:244:5::/64"])
        #expect(!first.stoppedTunnel)
        #expect(!first.stoppedIPv6Tunnel)
        #expect(first.removedNodeAnnotations)
        #expect(second.removedRoutes.isEmpty)
        #expect(second.removedIPv6Routes.isEmpty)
        #expect(second.removedNodeAnnotations)
        #expect(fixture.system.removedRoutes.map(\.interface) == ["utun77", "utun77"])
        #expect(fixture.system.removedIPv6Routes.map(\.interface) == ["utun78", "utun78"])
        #expect(!FileManager.default.fileExists(atPath: fixture.config.readyStatePath))
        #expect(try ownershipStore.load() == nil)
    }

    @Test
    func refusesOfflineCleanupWhileRecordedTunnelIsActive() async throws {
        let fixture = try ControllerFixture()
        let ownershipStore = FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath)
        try ownershipStore.save(
            FlannelOwnershipState(
                interfaceName: "utun77",
                localPodCIDR: "10.250.22.0/24",
                routePodCIDRs: ["10.250.2.0/24"]
            ))
        fixture.system.setInterface("utun77", exists: true)
        let controller = try fixture.makeController()

        await #expect(throws: FlannelVXLANError.self) {
            try await controller.cleanup()
        }

        #expect(fixture.system.removedRoutes.isEmpty)
        #expect(await fixture.kubernetes.patches.isEmpty)
        #expect(try ownershipStore.load() != nil)
    }

    @Test
    func decodesNewRuntimeDefaultsFromOlderConfiguration() throws {
        let data = Data(
            #"{"kubeconfig":"/etc/kubernetes/flannel.kubeconfig","nodeName":"mac-a","syncPeriodSeconds":10}"#.utf8
        )

        let config = try JSONDecoder().decode(FlannelVXLANMacOSConfig.self, from: data)

        #expect(config.nodeKubeconfig == "/etc/kubernetes/kubelet.conf")
        #expect(config.networkName == "kubernetes-pod")
        #expect(config.runtimeStatePath == "/var/lib/container/cri-shim-macos/pod-network.json")
        #expect(config.readyStatePath == "/var/lib/container/flannel-vxlan/ready.json")
        #expect(config.ownershipStatePath == "/var/lib/container/flannel-vxlan/ownership.json")
        #expect(config.underlayInterface == nil)
        try config.validate()
    }
}

private struct ControllerFixture {
    let root: URL
    let config: FlannelVXLANMacOSConfig
    let stateStore = PodNetworkStateStore()
    let kubernetes: MockFlannelKubernetes
    let networkManager = MockFlannelNetworkManager()
    let system = MockFlannelSystemManager()
    let forwardingManager = MockFlannelForwardingManager()
    let tunnelBox = MockTunnelBox()
    let ipv6TunnelBox = MockIPv6TunnelBox()
    let hostIPv6GatewayManager: MockHostIPv6GatewayManager
    let hostIPv6GatewayOwnershipStore: ControllerGatewayOwnershipStore

    init(
        dualStackEnabled: Bool = false,
        clusterDualStackEnabled: Bool? = nil,
        includeNodeInternalIPv6: Bool = true,
        nodeInternalIPv6Override: String? = nil,
        includeLinuxIPv6BackendData: Bool = true,
        dualStackBackendMTU: Int = 1_480
    ) throws {
        let hostIPv6GatewayOwnershipStore = ControllerGatewayOwnershipStore()
        self.hostIPv6GatewayOwnershipStore = hostIPv6GatewayOwnershipStore
        self.hostIPv6GatewayManager = MockHostIPv6GatewayManager(
            ownershipStore: hostIPv6GatewayOwnershipStore
        )
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clusterDualStack = clusterDualStackEnabled ?? dualStackEnabled
        config = FlannelVXLANMacOSConfig(
            kubeconfig: root.appendingPathComponent("kubeconfig").path,
            nodeName: "mac-a",
            vtepMACPath: root.appendingPathComponent("vtep-mac").path,
            dualStackEnabled: dualStackEnabled,
            runtimeStatePath: root.appendingPathComponent("runtime.json").path,
            readyStatePath: root.appendingPathComponent("ready.json").path,
            ownershipStatePath: root.appendingPathComponent("ownership.json").path
        )
        kubernetes = try MockFlannelKubernetes(
            nodes: [
                makeControllerNode(
                    name: "mac-a",
                    podCIDR: "10.250.22.0/24",
                    ipv6PodCIDR: clusterDualStack ? "fd42:10:244:22::/64" : nil,
                    internalIP: "192.0.2.24",
                    internalIPv6: clusterDualStack && includeNodeInternalIPv6
                        ? nodeInternalIPv6Override ?? "fd31::24"
                        : nil
                ),
                makeControllerManagedNode(
                    name: "linux-a",
                    podCIDR: "10.250.2.0/24",
                    ipv6PodCIDR: clusterDualStack ? "fd42:10:244:2::/64" : nil,
                    publicIP: "198.18.55.8",
                    publicIPv6: clusterDualStack ? "fd31::8" : nil,
                    vtepMAC: "02:00:00:00:00:02",
                    vtepMACIPv6: clusterDualStack && includeLinuxIPv6BackendData ? "02:00:00:00:10:02" : nil,
                    operatingSystem: "linux"
                ),
                makeControllerManagedNode(
                    name: "windows-a",
                    podCIDR: "10.250.5.0/24",
                    ipv6PodCIDR: clusterDualStack ? "fd42:10:244:5::/64" : nil,
                    publicIP: "198.51.100.140",
                    publicIPv6: clusterDualStack ? "fd31::5" : nil,
                    vtepMAC: "02:00:00:00:00:05",
                    vtepMACIPv6: clusterDualStack ? "02:00:00:00:10:05" : nil,
                    operatingSystem: "windows"
                ),
            ],
            configMap: FlannelConfigMap(
                metadata: FlannelObjectMeta(namespace: "kube-flannel", name: "kube-flannel-cfg"),
                data: [
                    "net-conf.json":
                        clusterDualStack
                        ? #"{"Network":"10.250.0.0/16","IPv6Network":"fd42:10:244::/56","EnableIPv4":true,"EnableIPv6":true,"Backend":{"Type":"vxlan","VNI":4096,"Port":4789,"MTU":\#(dualStackBackendMTU)}}"#
                        : #"{"Network":"10.250.0.0/16","EnableIPv4":true,"Backend":{"Type":"vxlan","VNI":4096,"Port":4789}}"#
                ]
            )
        )
    }

    func writeRuntimeState(podCIDR: String, ipv6PodCIDR: String? = nil) async throws {
        _ = try await stateStore.updateRuntimeState(
            networkName: config.networkName,
            podCIDRs: PodNetworkCIDRs(ipv4: podCIDR, ipv6: ipv6PodCIDR),
            path: config.runtimeStatePath
        )
    }

    func makeController(
        tunnelBox: MockTunnelBox? = nil,
        ipv6TunnelBox: MockIPv6TunnelBox? = nil,
        ownershipStateStore: (any FlannelOwnershipStateStoring)? = nil
    ) throws -> FlannelVXLANController {
        let selectedTunnelBox = tunnelBox ?? self.tunnelBox
        let selectedIPv6TunnelBox = ipv6TunnelBox ?? self.ipv6TunnelBox
        return try FlannelVXLANController(
            config: config,
            kubernetes: kubernetes,
            networkManager: networkManager,
            system: system,
            forwardingManager: forwardingManager,
            podNetworkStateStore: stateStore,
            vtepMACStore: StaticVTEPMACStore(),
            vtepMACIPv6Store: StaticVTEPMACStore("02:aa:bb:cc:dd:ff"),
            ownershipStateStore: ownershipStateStore,
            hostIPv6GatewayManager: hostIPv6GatewayManager,
            hostIPv6GatewayOwnershipStore: hostIPv6GatewayOwnershipStore,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            cleanupRetryDelay: .zero,
            makeTunnel: { configuration in
                selectedTunnelBox.make(configuration)
            },
            makeIPv6Tunnel: { configuration in
                selectedIPv6TunnelBox.make(configuration)
            }
        )
    }
}

private final class MockHostIPv6GatewayManager: FlannelHostIPv6GatewayManaging, @unchecked Sendable {
    enum Mode {
        case bridgePending
        case dadPending
        case ready
        case failureAfterWriteAhead
    }

    private let lock = NSLock()
    private let ownershipStore: any FlannelHostIPv6GatewayOwnershipStoring
    private var modeValue: Mode = .bridgePending
    private var reconcileCountValue = 0
    private var removeAttemptCountValue = 0
    private var removeFailuresRemaining = 0
    private var removedValues: [FlannelHostIPv6GatewayOwnership] = []

    init(ownershipStore: any FlannelHostIPv6GatewayOwnershipStoring) {
        self.ownershipStore = ownershipStore
    }

    var mode: Mode {
        get { lock.withLock { modeValue } }
        set { lock.withLock { modeValue = newValue } }
    }

    var reconcileCount: Int {
        lock.withLock { reconcileCountValue }
    }

    var removeCount: Int {
        lock.withLock { removedValues.count }
    }

    var removeAttemptCount: Int {
        lock.withLock { removeAttemptCountValue }
    }

    func failNextRemovals(_ count: Int) {
        lock.withLock { removeFailuresRemaining = count }
    }

    func reconcile(
        networkOwnership: FlannelHostOnlyNetworkOwnership,
        knownOwnership _: FlannelHostIPv6GatewayOwnership?
    ) throws -> FlannelHostIPv6GatewayReconcileResult {
        let mode = lock.withLock {
            reconcileCountValue += 1
            return modeValue
        }
        switch mode {
        case .bridgePending:
            return .bridgePending
        case .dadPending:
            return .dadPending(try ownership(networkOwnership))
        case .ready:
            return .ready(try ownership(networkOwnership))
        case .failureAfterWriteAhead:
            try ownershipStore.save(try ownership(networkOwnership, phase: .adding))
            throw FlannelVXLANError.runtime("injected host gateway failure after write-ahead ownership")
        }
    }

    func remove(ownership: FlannelHostIPv6GatewayOwnership) throws {
        try lock.withLock {
            removeAttemptCountValue += 1
            if removeFailuresRemaining > 0 {
                removeFailuresRemaining -= 1
                throw FlannelVXLANError.runtime("injected host gateway removal failure")
            }
            removedValues.append(ownership)
        }
    }

    private func ownership(
        _ networkOwnership: FlannelHostOnlyNetworkOwnership,
        phase: FlannelHostIPv6GatewayOwnershipPhase = .owned
    ) throws -> FlannelHostIPv6GatewayOwnership {
        FlannelHostIPv6GatewayOwnership(
            networkName: networkOwnership.name,
            networkOwnershipID: networkOwnership.ownershipID,
            ipv4PodCIDR: networkOwnership.podCIDR,
            ipv6PodCIDR: try #require(networkOwnership.ipv6PodCIDR),
            interfaceName: "bridge100",
            ipv4Gateway: "10.250.22.1",
            ipv6Gateway: "fd42:10:244:22::1",
            phase: phase
        )
    }
}

private final class ControllerGatewayOwnershipStore: FlannelHostIPv6GatewayOwnershipStoring, @unchecked Sendable {
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

private final class RecordingOwnershipStateStore: FlannelOwnershipStateStoring, @unchecked Sendable {
    private let store: FlannelOwnershipStateStore
    private let lock = NSLock()
    private var savedStateValues: [FlannelOwnershipState] = []

    init(path: String) {
        store = FlannelOwnershipStateStore(path: path)
    }

    var savedStates: [FlannelOwnershipState] {
        lock.withLock { savedStateValues }
    }

    func load() throws -> FlannelOwnershipState? {
        try store.load()
    }

    func save(_ state: FlannelOwnershipState) throws {
        try store.save(state)
        if let saved = try store.load() {
            lock.withLock {
                savedStateValues.append(saved)
            }
        }
    }

    func remove() throws {
        try store.remove()
    }
}

private actor MockFlannelKubernetes: FlannelKubernetesReading, FlannelKubernetesWriting {
    let nodeValues: [FlannelNode]
    var configMapValue: FlannelConfigMap
    var patches: [FlannelNodeAnnotationPatch] = []
    private var patchFailuresRemaining = 0
    private var nextPatchIsNotFound = false

    init(nodes: [FlannelNode], configMap: FlannelConfigMap) {
        nodeValues = nodes
        configMapValue = configMap
    }

    func nodes() async throws -> [FlannelNode] {
        nodeValues
    }

    func configMap(namespace: String, name: String) async throws -> FlannelConfigMap {
        configMapValue
    }

    func setNetworkConfig(_ value: String) {
        configMapValue.data?["net-conf.json"] = value
    }

    func patchOwnNodeAnnotations(_ patch: FlannelNodeAnnotationPatch) async throws -> FlannelNode {
        patches.append(patch)
        if nextPatchIsNotFound {
            nextPatchIsNotFound = false
            throw FlannelVXLANError.kubernetesAPIStatus(
                code: 404,
                path: "PATCH /api/v1/nodes/mac-a/status",
                message: "not found"
            )
        }
        if patchFailuresRemaining > 0 {
            patchFailuresRemaining -= 1
            throw FlannelVXLANError.kubernetesAPI("injected annotation patch failure")
        }
        return nodeValues[0]
    }

    func failNextAnnotationPatches(_ count: Int) {
        patchFailuresRemaining = count
    }

    func failNextAnnotationPatchAsNotFound() {
        nextPatchIsNotFound = true
    }
}

private actor MockFlannelNetworkManager: FlannelNetworkManaging {
    struct Call: Sendable {
        var name: String
        var podCIDR: String
        var ipv6PodCIDR: String?
        var plugin: String
        var variant: String
    }

    var calls: [Call] = []
    var purgeCalls: [FlannelHostOnlyNetworkOwnership] = []

    func ensureHostOnlyNetwork(
        name: String,
        podCIDR: String,
        plugin: String,
        variant: String,
        knownOwnership: FlannelHostOnlyNetworkOwnership?
    ) async throws -> FlannelHostOnlyNetworkReconcileResult {
        try await ensureHostOnlyNetwork(
            name: name,
            podCIDR: podCIDR,
            ipv6PodCIDR: nil,
            plugin: plugin,
            variant: variant,
            knownOwnership: knownOwnership
        )
    }

    func ensureHostOnlyNetwork(
        name: String,
        podCIDR: String,
        ipv6PodCIDR: String?,
        plugin: String,
        variant: String,
        knownOwnership: FlannelHostOnlyNetworkOwnership?
    ) async throws -> FlannelHostOnlyNetworkReconcileResult {
        calls.append(
            Call(
                name: name,
                podCIDR: podCIDR,
                ipv6PodCIDR: ipv6PodCIDR,
                plugin: plugin,
                variant: variant
            ))
        let ownership =
            knownOwnership
            ?? FlannelHostOnlyNetworkOwnership(
                name: name,
                podCIDR: podCIDR,
                ipv6PodCIDR: ipv6PodCIDR,
                plugin: plugin,
                variant: variant,
                ownershipID: "b7656446-13bc-482b-b02c-22eb6e066a59"
            )
        return FlannelHostOnlyNetworkReconcileResult(created: knownOwnership == nil, ownership: ownership)
    }

    func purgeHostOnlyNetwork(
        ownership: FlannelHostOnlyNetworkOwnership
    ) async throws -> FlannelHostOnlyNetworkPurgeResult {
        purgeCalls.append(ownership)
        return FlannelHostOnlyNetworkPurgeResult(networkWasPresent: true, removed: true)
    }

    func validateOwnedHostOnlyNetwork(
        ownership: FlannelHostOnlyNetworkOwnership
    ) async throws -> Bool {
        true
    }
}

private struct EmptyFlannelNetworkAttachmentInspector: FlannelNetworkAttachmentInspecting {
    func referringObjectIDs(networkName: String) async throws -> [String] {
        []
    }
}

private final class MockFlannelForwardingManager: FlannelForwardingManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var families: Set<FlannelForwardingFamily> = []
    private var ensureCallValues: [FlannelForwardingFamily] = []
    private var restoreCallValues: [FlannelForwardingFamily] = []
    private var restoreFailures: Set<FlannelForwardingFamily> = []
    private var ownedFamiliesInspectionFails = false

    var ensureCalls: [FlannelForwardingFamily] {
        lock.withLock { ensureCallValues }
    }

    var restoreCalls: [FlannelForwardingFamily] {
        lock.withLock { restoreCallValues }
    }

    func failRestore(_ family: FlannelForwardingFamily, enabled: Bool = true) {
        lock.withLock {
            if enabled {
                restoreFailures.insert(family)
            } else {
                restoreFailures.remove(family)
            }
        }
    }

    func failOwnedFamiliesInspection(_ enabled: Bool = true) {
        lock.withLock {
            ownedFamiliesInspectionFails = enabled
        }
    }

    func ensureEnabled(_ family: FlannelForwardingFamily) throws {
        lock.withLock {
            ensureCallValues.append(family)
            families.insert(family)
        }
    }

    @discardableResult
    func restore(_ family: FlannelForwardingFamily) throws -> Bool {
        try lock.withLock {
            restoreCallValues.append(family)
            guard families.contains(family) else {
                return false
            }
            if restoreFailures.contains(family) {
                throw FlannelVXLANError.runtime("injected \(family.rawValue) forwarding restore failure")
            }
            return families.remove(family) != nil
        }
    }

    func restoreAll() throws -> [FlannelForwardingFamily] {
        var restored: [FlannelForwardingFamily] = []
        var failures: [String] = []
        for family in FlannelForwardingFamily.allCases {
            do {
                if try restore(family) {
                    restored.append(family)
                }
            } catch {
                failures.append(String(describing: error))
            }
        }
        guard failures.isEmpty else {
            throw FlannelVXLANError.runtime(failures.joined(separator: "; "))
        }
        return restored.sorted()
    }

    func ownedFamilies() throws -> Set<FlannelForwardingFamily> {
        try lock.withLock {
            if ownedFamiliesInspectionFails {
                throw FlannelVXLANError.runtime("injected forwarding ownership inspection failure")
            }
            return families
        }
    }
}

private final class MockFlannelSystemManager: FlannelSystemManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var ensuredRouteValues: [(podCIDR: String, interface: String)] = []
    private var removedRouteValues: [(podCIDR: String, interface: String)] = []
    private var ensuredIPv6RouteValues: [(podCIDR: String, interface: String)] = []
    private var removedIPv6RouteValues: [(podCIDR: String, interface: String)] = []
    private var validatedUnderlayRouteValues: [(destination: String, interface: String)] = []
    private var validatedIPv6UnderlayRouteValues: [(destination: String, interface: String)] = []
    private var tunnelLocalAddressValue: String?
    private var ipv6TunnelLocalAddressValue: String?
    private var existingInterfaces: Set<String> = []
    private var routeRemovalFailuresRemaining = 0
    private var ipv6RouteRemovalFailuresRemaining = 0
    private var underlayRouteValidationFails = false
    private var ipv6UnderlayRouteValidationFails = false

    var addedRoutes: [(podCIDR: String, interface: String)] {
        lock.withLock { ensuredRouteValues }
    }

    var ensuredRoutes: [(podCIDR: String, interface: String)] {
        lock.withLock { ensuredRouteValues }
    }

    var removedRoutes: [(podCIDR: String, interface: String)] {
        lock.withLock { removedRouteValues }
    }

    var ensuredIPv6Routes: [(podCIDR: String, interface: String)] {
        lock.withLock { ensuredIPv6RouteValues }
    }

    var removedIPv6Routes: [(podCIDR: String, interface: String)] {
        lock.withLock { removedIPv6RouteValues }
    }

    var tunnelLocalAddress: String? {
        lock.withLock { tunnelLocalAddressValue }
    }

    var ipv6TunnelLocalAddress: String? {
        lock.withLock { ipv6TunnelLocalAddressValue }
    }

    var validatedUnderlayRoutes: [(destination: String, interface: String)] {
        lock.withLock { validatedUnderlayRouteValues }
    }

    var validatedIPv6UnderlayRoutes: [(destination: String, interface: String)] {
        lock.withLock { validatedIPv6UnderlayRouteValues }
    }

    func inspectUnderlayInterface(_ name: String) throws -> FlannelUnderlayInterface {
        FlannelUnderlayInterface(
            name: name,
            ipv4Address: "192.0.2.24",
            ipv6Address: "fd31::24",
            mtu: 1500
        )
    }

    func resolveUnderlayInterface(nodeInternalIP: String?) throws -> FlannelUnderlayInterface {
        FlannelUnderlayInterface(
            name: "en7",
            ipv4Address: nodeInternalIP ?? "192.0.2.24",
            ipv6Address: "fd31::24",
            mtu: 1500
        )
    }

    func validateUnderlayRoute(destination: String, interface: String) throws {
        try lock.withLock {
            if underlayRouteValidationFails {
                throw FlannelVXLANError.runtime("injected underlay route validation failure")
            }
            validatedUnderlayRouteValues.append((destination, interface))
        }
    }

    func failUnderlayRouteValidation() {
        lock.withLock {
            underlayRouteValidationFails = true
        }
    }

    func validateIPv6UnderlayRoute(destination: String, interface: String) throws {
        try lock.withLock {
            if ipv6UnderlayRouteValidationFails {
                throw FlannelVXLANError.runtime("injected IPv6 underlay route validation failure")
            }
            validatedIPv6UnderlayRouteValues.append((destination, interface))
        }
    }

    func failIPv6UnderlayRouteValidation() {
        setIPv6UnderlayRouteValidationFailure(true)
    }

    func setIPv6UnderlayRouteValidationFailure(_ value: Bool) {
        lock.withLock {
            ipv6UnderlayRouteValidationFails = value
        }
    }

    func interfaceExists(_ name: String) throws -> Bool {
        lock.withLock { existingInterfaces.contains(name) }
    }

    func setInterface(_ name: String, exists: Bool) {
        lock.withLock {
            if exists {
                existingInterfaces.insert(name)
            } else {
                existingInterfaces.remove(name)
            }
        }
    }

    func failNextRouteRemovals(_ count: Int) {
        lock.withLock {
            routeRemovalFailuresRemaining = count
        }
    }

    func failNextIPv6RouteRemovals(_ count: Int) {
        lock.withLock {
            ipv6RouteRemovalFailuresRemaining = count
        }
    }

    func configureTunnelInterface(_ name: String, localAddress: String, mtu: Int) throws {
        lock.withLock {
            tunnelLocalAddressValue = localAddress
        }
    }

    func configureIPv6TunnelInterface(_ name: String, localAddress: String, mtu: Int) throws {
        lock.withLock {
            ipv6TunnelLocalAddressValue = localAddress
        }
    }

    func ensureRoute(podCIDR: String, interface: String) throws {
        lock.withLock {
            ensuredRouteValues.append((podCIDR, interface))
        }
    }

    func removeRoute(podCIDR: String, interface: String) throws {
        try lock.withLock {
            if routeRemovalFailuresRemaining > 0 {
                routeRemovalFailuresRemaining -= 1
                throw FlannelVXLANError.runtime("injected route removal failure")
            }
            removedRouteValues.append((podCIDR, interface))
        }
    }

    func ensureIPv6Route(podCIDR: String, interface: String) throws {
        lock.withLock {
            ensuredIPv6RouteValues.append((podCIDR, interface))
        }
    }

    func removeIPv6Route(podCIDR: String, interface: String) throws {
        try lock.withLock {
            if ipv6RouteRemovalFailuresRemaining > 0 {
                ipv6RouteRemovalFailuresRemaining -= 1
                throw FlannelVXLANError.runtime("injected IPv6 route removal failure")
            }
            removedIPv6RouteValues.append((podCIDR, interface))
        }
    }
}

private final class MockTunnelBox: @unchecked Sendable {
    private let lock = NSLock()
    let tunnel = MockFlannelTunnel()
    private var configurations: [FlannelTunnelConfiguration] = []

    var createdConfigurations: [FlannelTunnelConfiguration] {
        lock.withLock { configurations }
    }

    func make(_ configuration: FlannelTunnelConfiguration) -> any FlannelTunnelControlling {
        lock.withLock {
            configurations.append(configuration)
        }
        return tunnel
    }
}

private final class MockIPv6TunnelBox: @unchecked Sendable {
    private let lock = NSLock()
    let tunnel: MockFlannelIPv6Tunnel
    private var configurations: [FlannelIPv6TunnelConfiguration] = []

    init(interfaceName: String = "utun43") {
        tunnel = MockFlannelIPv6Tunnel(interfaceName: interfaceName)
    }

    var createdConfigurations: [FlannelIPv6TunnelConfiguration] {
        lock.withLock { configurations }
    }

    func make(_ configuration: FlannelIPv6TunnelConfiguration) -> any FlannelIPv6TunnelControlling {
        lock.withLock {
            configurations.append(configuration)
        }
        return tunnel
    }
}

private final class MockFlannelTunnel: FlannelTunnelControlling, @unchecked Sendable {
    let interfaceName = "utun42"
    private let lock = NSLock()
    private var running = true
    private var stopFails = false
    private var destroyed = false
    private var updates: [[FlannelPeer]] = []

    var isRunning: Bool {
        lock.withLock { running }
    }

    var peerUpdates: [[FlannelPeer]] {
        lock.withLock { updates }
    }

    var wasDestroyed: Bool {
        lock.withLock { destroyed }
    }

    func setPeers(_ peers: [FlannelPeer]) throws {
        lock.withLock {
            updates.append(peers)
        }
    }

    func start() throws {
        lock.withLock {
            running = true
        }
    }

    func stop() {
        lock.withLock {
            if !stopFails {
                running = false
            }
        }
    }

    func destroy() {
        lock.withLock {
            destroyed = true
            running = false
        }
    }

    func failStops(_ value: Bool) {
        lock.withLock {
            stopFails = value
        }
    }

    func statistics() -> FlannelTunnelStatistics {
        FlannelTunnelStatistics(
            transmittedPackets: 0,
            transmittedBytes: 0,
            receivedPackets: 0,
            receivedBytes: 0,
            unknownPeerPackets: 0,
            invalidPackets: 0,
            oversizedPackets: 0,
            sourceCIDRMismatches: 0
        )
    }
}

private final class MockFlannelIPv6Tunnel: FlannelIPv6TunnelControlling, @unchecked Sendable {
    let interfaceName: String
    private let lock = NSLock()
    private var running = true
    private var destroyed = false
    private var peerUpdatesFail = false
    private var stopFails = false
    private var updates: [[FlannelIPv6Peer]] = []

    init(interfaceName: String = "utun43") {
        self.interfaceName = interfaceName
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var peerUpdates: [[FlannelIPv6Peer]] {
        lock.withLock { updates }
    }

    var wasDestroyed: Bool {
        lock.withLock { destroyed }
    }

    func setPeers(_ peers: [FlannelIPv6Peer]) throws {
        try lock.withLock {
            if peerUpdatesFail {
                throw FlannelVXLANError.runtime("injected IPv6 peer update failure")
            }
            updates.append(peers)
        }
    }

    func start() throws {
        lock.withLock {
            running = true
        }
    }

    func stop() {
        lock.withLock {
            if !stopFails {
                running = false
            }
        }
    }

    func destroy() {
        lock.withLock {
            destroyed = true
            running = false
        }
    }

    func failPeerUpdates(_ value: Bool) {
        lock.withLock {
            peerUpdatesFail = value
        }
    }

    func failStops(_ value: Bool) {
        lock.withLock {
            stopFails = value
        }
    }

    func statistics() -> FlannelTunnelStatistics {
        FlannelTunnelStatistics(
            transmittedPackets: 0,
            transmittedBytes: 0,
            receivedPackets: 0,
            receivedBytes: 0,
            unknownPeerPackets: 0,
            invalidPackets: 0,
            oversizedPackets: 0,
            sourceCIDRMismatches: 0
        )
    }
}

private struct StaticVTEPMACStore: FlannelVTEPMACStoring {
    let value: String

    init(_ value: String = "02:aa:bb:cc:dd:ee") {
        self.value = value
    }

    func load() throws -> String? {
        value
    }

    func loadOrCreate() throws -> String {
        value
    }
}

private func makeControllerNode(
    name: String,
    podCIDR: String,
    ipv6PodCIDR: String? = nil,
    internalIP: String? = nil,
    internalIPv6: String? = nil,
    annotations: [String: String]? = nil,
    operatingSystem: String? = nil
) -> FlannelNode {
    let podCIDRs = [podCIDR, ipv6PodCIDR].compactMap { $0 }
    let addresses = [
        internalIP.map { FlannelNodeAddress(type: "InternalIP", address: $0) },
        internalIPv6.map { FlannelNodeAddress(type: "InternalIP", address: $0) },
    ].compactMap { $0 }
    return FlannelNode(
        metadata: FlannelObjectMeta(
            name: name,
            labels: operatingSystem.map { ["kubernetes.io/os": $0] },
            annotations: annotations
        ),
        spec: FlannelNodeSpec(podCIDR: podCIDR, podCIDRs: podCIDRs),
        status: addresses.isEmpty ? nil : FlannelNodeStatus(addresses: addresses)
    )
}

private func makeControllerManagedNode(
    name: String,
    podCIDR: String,
    ipv6PodCIDR: String? = nil,
    publicIP: String,
    publicIPv6: String? = nil,
    vtepMAC: String,
    vtepMACIPv6: String? = nil,
    operatingSystem: String
) throws -> FlannelNode {
    let keys = try FlannelAnnotationKeys(prefix: "flannel.alpha.coreos.com")
    let backendData = String(
        decoding: try JSONEncoder().encode(FlannelBackendLeaseData(vni: 4096, vtepMAC: vtepMAC)),
        as: UTF8.self
    )
    var annotations = [
        keys.kubeSubnetManager: "true",
        keys.backendType: "vxlan",
        keys.publicIP: publicIP,
        keys.backendData: backendData,
    ]
    if let publicIPv6 {
        annotations[keys.publicIPv6] = publicIPv6
    }
    if let vtepMACIPv6 {
        annotations[keys.backendV6Data] = String(
            decoding: try JSONEncoder().encode(
                FlannelBackendLeaseData(vni: 4096, vtepMAC: vtepMACIPv6)
            ),
            as: UTF8.self
        )
    }
    return makeControllerNode(
        name: name,
        podCIDR: podCIDR,
        ipv6PodCIDR: ipv6PodCIDR,
        annotations: annotations,
        operatingSystem: operatingSystem
    )
}
