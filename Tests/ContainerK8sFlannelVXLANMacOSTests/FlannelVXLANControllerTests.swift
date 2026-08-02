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
        try await fixture.writeRuntimeState(podCIDR: "10.244.22.19/24")
        let controller = try fixture.makeController()

        let first = try await controller.runOnce()
        let second = try await controller.runOnce()

        #expect(first.localNetwork.podCIDR == "10.244.22.0/24")
        #expect(first.underlay.ipv4Address == "10.31.252.24")
        #expect(first.mtu == 1450)
        #expect(first.peers.map(\.nodeName) == ["linux-a", "windows-a"])
        #expect(second.interfaceName == first.interfaceName)
        #expect(fixture.tunnelBox.createdConfigurations.count == 1)
        #expect(fixture.tunnelBox.tunnel.peerUpdates.count == 2)
        #expect(Set(fixture.system.addedRoutes.map(\.podCIDR)) == ["10.244.2.0/24", "10.244.5.0/24"])
        #expect(fixture.system.ensuredRoutes.count == 4)
        #expect(
            fixture.system.validatedUnderlayRoutes.map { "\($0.destination)|\($0.interface)" } == [
                "10.185.55.8|en7",
                "10.19.121.140|en7",
                "10.185.55.8|en7",
                "10.19.121.140|en7",
            ])
        #expect(fixture.system.tunnelLocalAddress == "10.244.22.0")

        let networkCalls = await fixture.networkManager.calls
        #expect(networkCalls.count == 2)
        #expect(networkCalls.first?.name == "kubernetes-pod")
        #expect(networkCalls.first?.podCIDR == "10.244.22.0/24")

        let patches = await fixture.kubernetes.patches
        let keys = try FlannelAnnotationKeys(prefix: fixture.config.annotationPrefix)
        #expect(patches.count == 2)
        #expect(patches.last?.values[keys.publicIP] == "10.31.252.24")
        #expect(patches.last?.values[keys.backendType] == "vxlan")
        #expect(patches.last?.values[keys.backendData]?.contains("4096") == true)

        let ready = try await fixture.stateStore.loadReadyState(path: fixture.config.readyStatePath)
        #expect(ready?.networkName == "kubernetes-pod")
        #expect(ready?.podCIDR == "10.244.22.0/24")
        #expect(ready?.runtimeGeneration == 1)
        #expect(ready?.mtu == 1_450)
        #expect(ready?.expiresAtUnixSeconds == 1_700_000_020)

        let ownershipStore = FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath)
        let loadedOwnership = try ownershipStore.load()
        let ownership = try #require(loadedOwnership)
        #expect(ownership.interfaceName == first.interfaceName)
        #expect(ownership.localPodCIDR == "10.244.22.0/24")
        #expect(ownership.routePodCIDRs == ["10.244.2.0/24", "10.244.5.0/24"])

        let cleanup = try await controller.shutdown()
        #expect(cleanup.removedRoutes == ["10.244.2.0/24", "10.244.5.0/24"])
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
    func rejectsKubeletAndNodePodCIDRMismatchAndClearsReadyState() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.244.99.0/24")
        try await fixture.stateStore.writeReadyState(
            PodNetworkReadyState(
                networkName: "kubernetes-pod",
                podCIDR: "10.244.99.0/24",
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
        try await fixture.writeRuntimeState(podCIDR: "10.244.22.0/24")
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
        try await fixture.writeRuntimeState(podCIDR: "10.244.22.0/24")
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
        try await fixture.writeRuntimeState(podCIDR: "10.244.22.0/24")
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
        try await fixture.writeRuntimeState(podCIDR: "10.244.22.0/24")
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
        try await fixture.writeRuntimeState(podCIDR: "10.244.22.0/24")
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
        #expect(retry.removedRoutes == ["10.244.2.0/24", "10.244.5.0/24"])
        #expect(!fixture.tunnelBox.tunnel.isRunning)
        #expect(try ownershipStore.load() == nil)
    }

    @Test
    func keepsControllerAndOwnershipWhenTunnelStopFailsUntilCleanupRetry() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.244.22.0/24")
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
    func purgesOwnedNetworkOnlyAfterDataplaneCleanup() async throws {
        let fixture = try ControllerFixture()
        try await fixture.writeRuntimeState(podCIDR: "10.244.22.0/24")
        let controller = try fixture.makeController()
        _ = try await controller.runOnce()
        let purger = FlannelHostOnlyNetworkPurger(
            networkManager: fixture.networkManager,
            attachmentInspector: EmptyFlannelNetworkAttachmentInspector(),
            dataplaneOwnershipStore: FlannelOwnershipStateStore(path: fixture.config.ownershipStatePath),
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
                localPodCIDR: "10.244.22.0/24",
                routePodCIDRs: ["10.244.5.0/24", "10.244.2.0/24"]
            ))
        try await fixture.stateStore.writeReadyState(
            PodNetworkReadyState(
                networkName: "kubernetes-pod",
                podCIDR: "10.244.22.0/24",
                runtimeGeneration: 1,
                mtu: 1450,
                expiresAtUnixSeconds: Int64.max
            ),
            path: fixture.config.readyStatePath
        )
        let controller = try fixture.makeController()

        let first = try await controller.cleanup()
        let second = try await controller.cleanup()

        #expect(first.removedRoutes == ["10.244.2.0/24", "10.244.5.0/24"])
        #expect(!first.stoppedTunnel)
        #expect(first.removedNodeAnnotations)
        #expect(second.removedRoutes.isEmpty)
        #expect(second.removedNodeAnnotations)
        #expect(fixture.system.removedRoutes.map(\.interface) == ["utun77", "utun77"])
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
                localPodCIDR: "10.244.22.0/24",
                routePodCIDRs: ["10.244.2.0/24"]
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
    let tunnelBox = MockTunnelBox()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        config = FlannelVXLANMacOSConfig(
            kubeconfig: root.appendingPathComponent("kubeconfig").path,
            nodeName: "mac-a",
            vtepMACPath: root.appendingPathComponent("vtep-mac").path,
            runtimeStatePath: root.appendingPathComponent("runtime.json").path,
            readyStatePath: root.appendingPathComponent("ready.json").path,
            ownershipStatePath: root.appendingPathComponent("ownership.json").path
        )
        kubernetes = try MockFlannelKubernetes(
            nodes: [
                makeControllerNode(
                    name: "mac-a",
                    podCIDR: "10.244.22.0/24",
                    internalIP: "10.31.252.24"
                ),
                makeControllerManagedNode(
                    name: "linux-a",
                    podCIDR: "10.244.2.0/24",
                    publicIP: "10.185.55.8",
                    vtepMAC: "02:00:00:00:00:02",
                    operatingSystem: "linux"
                ),
                makeControllerManagedNode(
                    name: "windows-a",
                    podCIDR: "10.244.5.0/24",
                    publicIP: "10.19.121.140",
                    vtepMAC: "02:00:00:00:00:05",
                    operatingSystem: "windows"
                ),
            ],
            configMap: FlannelConfigMap(
                metadata: FlannelObjectMeta(namespace: "kube-flannel", name: "kube-flannel-cfg"),
                data: [
                    "net-conf.json":
                        #"{"Network":"10.244.0.0/16","EnableIPv4":true,"Backend":{"Type":"vxlan","VNI":4096,"Port":4789}}"#
                ]
            )
        )
    }

    func writeRuntimeState(podCIDR: String) async throws {
        _ = try await stateStore.updateRuntimeState(
            networkName: config.networkName,
            podCIDR: podCIDR,
            path: config.runtimeStatePath
        )
    }

    func makeController() throws -> FlannelVXLANController {
        try FlannelVXLANController(
            config: config,
            kubernetes: kubernetes,
            networkManager: networkManager,
            system: system,
            podNetworkStateStore: stateStore,
            vtepMACStore: StaticVTEPMACStore(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            cleanupRetryDelay: .zero,
            makeTunnel: { configuration in
                tunnelBox.make(configuration)
            }
        )
    }
}

private actor MockFlannelKubernetes: FlannelKubernetesReading, FlannelKubernetesWriting {
    let nodeValues: [FlannelNode]
    let configMapValue: FlannelConfigMap
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
        calls.append(Call(name: name, podCIDR: podCIDR, plugin: plugin, variant: variant))
        let ownership =
            knownOwnership
            ?? FlannelHostOnlyNetworkOwnership(
                name: name,
                podCIDR: podCIDR,
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

private final class MockFlannelSystemManager: FlannelSystemManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var ensuredRouteValues: [(podCIDR: String, interface: String)] = []
    private var removedRouteValues: [(podCIDR: String, interface: String)] = []
    private var validatedUnderlayRouteValues: [(destination: String, interface: String)] = []
    private var tunnelLocalAddressValue: String?
    private var existingInterfaces: Set<String> = []
    private var routeRemovalFailuresRemaining = 0
    private var underlayRouteValidationFails = false

    var addedRoutes: [(podCIDR: String, interface: String)] {
        lock.withLock { ensuredRouteValues }
    }

    var ensuredRoutes: [(podCIDR: String, interface: String)] {
        lock.withLock { ensuredRouteValues }
    }

    var removedRoutes: [(podCIDR: String, interface: String)] {
        lock.withLock { removedRouteValues }
    }

    var tunnelLocalAddress: String? {
        lock.withLock { tunnelLocalAddressValue }
    }

    var validatedUnderlayRoutes: [(destination: String, interface: String)] {
        lock.withLock { validatedUnderlayRouteValues }
    }

    func inspectUnderlayInterface(_ name: String) throws -> FlannelUnderlayInterface {
        FlannelUnderlayInterface(name: name, ipv4Address: "10.31.252.24", mtu: 1500)
    }

    func resolveUnderlayInterface(nodeInternalIP: String?) throws -> FlannelUnderlayInterface {
        FlannelUnderlayInterface(name: "en7", ipv4Address: nodeInternalIP ?? "10.31.252.24", mtu: 1500)
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

    func enableIPv4Forwarding() throws {}

    func configureTunnelInterface(_ name: String, localAddress: String, mtu: Int) throws {
        lock.withLock {
            tunnelLocalAddressValue = localAddress
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

private struct StaticVTEPMACStore: FlannelVTEPMACStoring {
    func load() throws -> String? {
        "02:aa:bb:cc:dd:ee"
    }

    func loadOrCreate() throws -> String {
        "02:aa:bb:cc:dd:ee"
    }
}

private func makeControllerNode(
    name: String,
    podCIDR: String,
    internalIP: String? = nil,
    annotations: [String: String]? = nil,
    operatingSystem: String? = nil
) -> FlannelNode {
    FlannelNode(
        metadata: FlannelObjectMeta(
            name: name,
            labels: operatingSystem.map { ["kubernetes.io/os": $0] },
            annotations: annotations
        ),
        spec: FlannelNodeSpec(podCIDR: podCIDR, podCIDRs: [podCIDR]),
        status: internalIP.map { FlannelNodeStatus(addresses: [.init(type: "InternalIP", address: $0)]) }
    )
}

private func makeControllerManagedNode(
    name: String,
    podCIDR: String,
    publicIP: String,
    vtepMAC: String,
    operatingSystem: String
) throws -> FlannelNode {
    let keys = try FlannelAnnotationKeys(prefix: "flannel.alpha.coreos.com")
    let backendData = String(
        decoding: try JSONEncoder().encode(FlannelBackendLeaseData(vni: 4096, vtepMAC: vtepMAC)),
        as: UTF8.self
    )
    return makeControllerNode(
        name: name,
        podCIDR: podCIDR,
        annotations: [
            keys.kubeSubnetManager: "true",
            keys.backendType: "vxlan",
            keys.publicIP: publicIP,
            keys.backendData: backendData,
        ],
        operatingSystem: operatingSystem
    )
}
