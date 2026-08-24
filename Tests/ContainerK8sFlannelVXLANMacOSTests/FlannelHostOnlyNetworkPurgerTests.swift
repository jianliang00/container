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

import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelHostOnlyNetworkPurgerTests {
    @Test
    func productionInspectorFindsConfiguredAndRuntimeAttachmentsInStableOrder() async throws {
        let configured = try makeContainerSnapshot(
            id: "sandbox-z",
            configuredNetworks: ["kubernetes-pod"],
            attachedNetworks: []
        )
        let attached = try makeContainerSnapshot(
            id: "container-a",
            configuredNetworks: [],
            attachedNetworks: ["kubernetes-pod"]
        )
        let unrelated = try makeContainerSnapshot(
            id: "unrelated",
            configuredNetworks: ["default"],
            attachedNetworks: ["default"]
        )
        let inspector = ContainerKitFlannelNetworkAttachmentInspector {
            [configured, unrelated, attached, configured]
        }

        let objectIDs = try await inspector.referringObjectIDs(networkName: "kubernetes-pod")

        #expect(objectIDs == ["container-a", "sandbox-z"])
    }

    @Test
    func missingOwnershipIsAFirstInstallNoOpWithoutContactingContainerKit() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        await fixture.attachmentInspector.failInspections(true)
        await fixture.networkManager.failValidations(true)

        let check = try await fixture.purger.checkPurge()
        #expect(
            check
                == FlannelHostOnlyNetworkPurgeCheckResult(
                    ownedNetworkName: nil,
                    networkWasPresent: false,
                    referringObjectIDs: []
                )
        )

        let purge = try await fixture.purger.purge()
        #expect(purge == FlannelHostOnlyNetworkPurgeResult(networkWasPresent: false, removed: false))
        #expect(await fixture.attachmentInspector.inspectionCalls == 0)
        #expect(await fixture.networkManager.validationCalls == 0)
        #expect(await fixture.networkManager.purgeCalls.isEmpty)
    }

    @Test
    func missingNetworkOwnershipWithDataplaneStateIsFailClosed() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.dataplaneStore.save(
            FlannelOwnershipState(
                interfaceName: "utun42",
                localPodCIDR: "10.250.22.0/24",
                routePodCIDRs: []
            )
        )

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.checkPurge()
        }
        #expect(await fixture.attachmentInspector.inspectionCalls == 0)
        #expect(await fixture.networkManager.validationCalls == 0)
    }

    @Test
    func missingNetworkOwnershipWithHostGatewayStateIsFailClosed() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.gatewayOwnershipStore.save(fixture.gatewayOwnership())

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.checkPurge()
        }
        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.purge()
        }

        #expect(await fixture.attachmentInspector.inspectionCalls == 0)
        #expect(await fixture.networkManager.validationCalls == 0)
        #expect(fixture.gatewayManager.removed.isEmpty)
        #expect(try fixture.gatewayOwnershipStore.load() != nil)
    }

    @Test
    func missingNetworkOwnershipWithForwardingStateIsFailClosed() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveForwardingOwnership()

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.checkPurge()
        }
        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.purge()
        }

        #expect(await fixture.attachmentInspector.inspectionCalls == 0)
        #expect(await fixture.networkManager.validationCalls == 0)
        #expect(try fixture.forwardingOwnershipStore.load() != nil)
    }

    @Test
    func readOnlyCheckAllowsActiveDataplaneButPurgeRequiresWithdrawal() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership()
        try fixture.dataplaneStore.save(
            FlannelOwnershipState(
                interfaceName: "utun42",
                localPodCIDR: "10.250.22.0/24",
                routePodCIDRs: ["10.250.5.0/24"]
            )
        )

        let check = try await fixture.purger.checkPurge()
        #expect(check.ownedNetworkName == "kubernetes-pod")
        #expect(check.networkWasPresent)

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.purge()
        }
        #expect(await fixture.networkManager.purgeCalls.isEmpty)

        try fixture.dataplaneStore.remove()
        let purge = try await fixture.purger.purge()
        #expect(purge == FlannelHostOnlyNetworkPurgeResult(networkWasPresent: true, removed: true))
        #expect(await fixture.networkManager.purgeCalls.count == 1)
        #expect(try fixture.networkOwnershipStore.load() == nil)
    }

    @Test
    func readOnlyCheckAllowsForwardingOwnershipButPurgeRequiresRestoration() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership()
        try fixture.forwardingOwnershipStore.save(
            FlannelForwardingOwnership(
                bootSessionID: "boot-a",
                ipv4: FlannelForwardingFamilyOwnership(
                    originalEnabled: false,
                    phase: .owned
                )
            )
        )

        let check = try await fixture.purger.checkPurge()
        #expect(check.ownedNetworkName == "kubernetes-pod")

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.purge()
        }
        #expect(await fixture.networkManager.purgeCalls.isEmpty)

        try fixture.forwardingOwnershipStore.remove()
        let purge = try await fixture.purger.purge()
        #expect(purge.removed)
        #expect(await fixture.networkManager.purgeCalls.count == 1)
    }

    @Test
    func purgeRechecksDataplaneOwnershipAfterAsyncPreflight() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership()
        let dataplaneStore = fixture.dataplaneStore
        await fixture.attachmentInspector.setInspectionHook {
            try! dataplaneStore.save(
                FlannelOwnershipState(
                    interfaceName: "utun42",
                    localPodCIDR: "10.250.22.0/24",
                    routePodCIDRs: []
                )
            )
        }

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.purge()
        }

        #expect(await fixture.networkManager.purgeCalls.isEmpty)
        #expect(try fixture.networkOwnershipStore.load() != nil)
    }

    @Test
    func purgeRechecksForwardingOwnershipAfterAsyncPreflight() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership()
        let forwardingOwnershipStore = fixture.forwardingOwnershipStore
        await fixture.attachmentInspector.setInspectionHook {
            try! forwardingOwnershipStore.save(Self.forwardingOwnership())
        }

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.purge()
        }

        #expect(await fixture.networkManager.purgeCalls.isEmpty)
        #expect(try fixture.networkOwnershipStore.load() != nil)
    }

    @Test
    func purgeRechecksGatewayOwnershipAfterAsyncPreflight() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership(ipv6PodCIDR: "fd42:10:244:22::/64")
        let gatewayOwnershipStore = fixture.gatewayOwnershipStore
        let gatewayOwnership = fixture.gatewayOwnership()
        await fixture.attachmentInspector.setInspectionHook {
            try! gatewayOwnershipStore.save(gatewayOwnership)
        }

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.purge()
        }

        #expect(fixture.gatewayManager.removed.isEmpty)
        #expect(await fixture.networkManager.purgeCalls.isEmpty)
        #expect(try fixture.networkOwnershipStore.load() != nil)
    }

    @Test
    func offlineRecoveryRestoresForwardingWithoutOtherDataplaneState() throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveForwardingOwnership()

        let lifetimeLock = try fixture.acquireLifetimeLock()
        let result = try fixture.forwardingRecovery().restoreIfForwardingOnly(
            whileHolding: lifetimeLock
        )

        #expect(result == .restored([.ipv4]))
        #expect(fixture.forwardingManager.restoreAllCalls == 1)
        #expect(try fixture.forwardingOwnershipStore.load() == nil)
    }

    @Test
    func offlineRecoveryDiscardsPreviousBootOwnershipWithoutTouchingCurrentSysctls() throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveForwardingOwnership()
        let commands = PurgerTestForwardingCommands()
        let forwardingManager = SystemFlannelForwardingManager(
            ownershipStore: fixture.forwardingOwnershipStore,
            advisoryLockPath: fixture.root.appendingPathComponent("forwarding.lock").path,
            bootSessionProvider: { "boot-b" },
            commandRunner: { [commands] executable, arguments in
                commands.run(executable: executable, arguments: arguments)
            }
        )
        let recovery = FlannelOfflineForwardingRecovery(
            dataplaneOwnershipStore: fixture.dataplaneStore,
            forwardingOwnershipStore: fixture.forwardingOwnershipStore,
            hostIPv6GatewayOwnershipStore: fixture.gatewayOwnershipStore,
            forwardingManager: forwardingManager,
            readyStateExists: { false }
        )

        let result = try recovery.restoreIfForwardingOnly(
            whileHolding: fixture.acquireLifetimeLock()
        )

        #expect(result == .restored([]))
        #expect(commands.calls.isEmpty)
        #expect(try fixture.forwardingOwnershipStore.load() == nil)
    }

    @Test(arguments: OfflineForwardingRecoveryBlockingState.allCases)
    func offlineRecoveryDoesNotRestoreBeforeOtherDataplaneStateIsGone(
        blockingState: OfflineForwardingRecoveryBlockingState
    ) throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveForwardingOwnership()
        switch blockingState {
        case .dataplane:
            try fixture.dataplaneStore.save(
                FlannelOwnershipState(
                    interfaceName: "utun42",
                    localPodCIDR: "10.250.22.0/24",
                    routePodCIDRs: []
                )
            )
        case .gateway:
            try fixture.gatewayOwnershipStore.save(fixture.gatewayOwnership())
        case .readyState:
            break
        }

        let lifetimeLock = try fixture.acquireLifetimeLock()
        let result = try fixture.forwardingRecovery(
            readyStateExists: blockingState == .readyState
        ).restoreIfForwardingOnly(whileHolding: lifetimeLock)

        #expect(result == .blockedByDataplaneState)
        #expect(fixture.forwardingManager.restoreAllCalls == 0)
        #expect(try fixture.forwardingOwnershipStore.load() != nil)
    }

    private static func forwardingOwnership() -> FlannelForwardingOwnership {
        FlannelForwardingOwnership(
            bootSessionID: "boot-a",
            ipv4: FlannelForwardingFamilyOwnership(
                originalEnabled: false,
                phase: .owned
            )
        )
    }

    @Test
    func daemonLifetimeLockIsExclusiveAndKeepsAStableInode() throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }

        let first = try fixture.acquireLifetimeLock()
        let initialInode = try #require(
            FileManager.default.attributesOfItem(atPath: fixture.lifetimeLockPath)[.systemFileNumber]
                as? NSNumber
        )
        let competingLock = try FlannelDaemonLifetimeLock.tryAcquire(path: fixture.lifetimeLockPath)
        #expect(competingLock == nil)

        first.release()
        let second = try fixture.acquireLifetimeLock()
        let reacquiredInode = try #require(
            FileManager.default.attributesOfItem(atPath: fixture.lifetimeLockPath)[.systemFileNumber]
                as? NSNumber
        )

        #expect(initialInode == reacquiredInode)
        second.release()
        #expect(FileManager.default.fileExists(atPath: fixture.lifetimeLockPath))
    }

    @Test
    func offlineRecoveryRefusesAReleasedDaemonLifetimeLock() throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveForwardingOwnership()
        let lifetimeLock = try fixture.acquireLifetimeLock()
        lifetimeLock.release()

        #expect(throws: FlannelVXLANError.self) {
            try fixture.forwardingRecovery().restoreIfForwardingOnly(
                whileHolding: lifetimeLock
            )
        }

        #expect(fixture.forwardingManager.restoreAllCalls == 0)
        #expect(try fixture.forwardingOwnershipStore.load() != nil)
    }

    @Test
    func attachmentReferencesFailClosedWithStableIDsAndAreRecheckedByPurge() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership()
        await fixture.attachmentInspector.setObjectIDs([])

        _ = try await fixture.purger.checkPurge()
        await fixture.attachmentInspector.setObjectIDs(["sandbox-z", "container-a", "sandbox-z"])

        do {
            _ = try await fixture.purger.purge()
            Issue.record("purge should reject network attachments created after the read-only check")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("container-a, sandbox-z"))
            #expect(!description.contains("sandbox-z, container-a"))
        }

        #expect(await fixture.attachmentInspector.inspectionCalls == 2)
        #expect(await fixture.networkManager.purgeCalls.isEmpty)
        #expect(try fixture.networkOwnershipStore.load() != nil)
    }

    @Test
    func attachmentInspectionAndOwnershipValidationFailuresAreFailClosed() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership()
        await fixture.networkManager.failValidations(true)

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.checkPurge()
        }
        #expect(await fixture.attachmentInspector.inspectionCalls == 0)

        await fixture.networkManager.failValidations(false)
        await fixture.attachmentInspector.failInspections(true)
        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.checkPurge()
        }
        #expect(await fixture.networkManager.purgeCalls.isEmpty)
        #expect(try fixture.networkOwnershipStore.load() != nil)
    }

    @Test
    func purgeRemovesExactHostGatewayOwnershipBeforeOwnedNetwork() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership(ipv6PodCIDR: "fd42:10:244:22::/64")
        let gatewayOwnership = fixture.gatewayOwnership()
        try fixture.gatewayOwnershipStore.save(gatewayOwnership)

        let result = try await fixture.purger.purge()

        #expect(result.removed)
        #expect(fixture.gatewayManager.removed == [gatewayOwnership])
        #expect(try fixture.gatewayOwnershipStore.load() == nil)
        #expect(await fixture.networkManager.purgeCalls.count == 1)
    }

    @Test
    func checkAndPurgeRefuseMismatchedHostGatewayCIDROwnership() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership(ipv6PodCIDR: "fd42:10:244:22::/64")
        try fixture.gatewayOwnershipStore.save(
            FlannelHostIPv6GatewayOwnership(
                networkName: "kubernetes-pod",
                networkOwnershipID: "b7656446-13bc-482b-b02c-22eb6e066a59",
                ipv4PodCIDR: "10.250.23.0/24",
                ipv6PodCIDR: "fd42:10:244:23::/64",
                interfaceName: "bridge101",
                ipv4Gateway: "10.250.23.1",
                ipv6Gateway: "fd42:10:244:23::1"
            ))

        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.checkPurge()
        }
        await #expect(throws: FlannelVXLANError.self) {
            try await fixture.purger.purge()
        }

        #expect(fixture.gatewayManager.removed.isEmpty)
        #expect(await fixture.networkManager.validationCalls == 0)
        #expect(await fixture.networkManager.purgeCalls.isEmpty)
        #expect(try fixture.gatewayOwnershipStore.load() != nil)
    }
}

private func makeContainerSnapshot(
    id: String,
    configuredNetworks: [String],
    attachedNetworks: [String]
) throws -> ContainerSnapshot {
    let image = ImageDescription(
        reference: "local/test:latest",
        descriptor: .init(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:test",
            size: 1
        )
    )
    let process = ProcessConfiguration(
        executable: "/usr/bin/true",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
    var configuration = ContainerConfiguration(id: id, image: image, process: process)
    configuration.networks = configuredNetworks.map {
        AttachmentConfiguration(network: $0, options: AttachmentOptions(hostname: id))
    }
    let attachments = try attachedNetworks.map {
        Attachment(
            network: $0,
            hostname: id,
            ipv4Address: try CIDRv4("10.250.22.2/24"),
            ipv4Gateway: try IPv4Address("10.250.22.1"),
            ipv6Address: nil,
            macAddress: nil
        )
    }
    return ContainerSnapshot(configuration: configuration, status: .stopped, networks: attachments)
}

private struct PurgerFixture {
    let root: URL
    let dataplaneStore: FlannelOwnershipStateStore
    let forwardingOwnershipStore: FlannelForwardingOwnershipStore
    let networkOwnershipStore: FlannelHostOnlyNetworkOwnershipStore
    let gatewayOwnershipStore: FlannelHostIPv6GatewayOwnershipStore
    let networkManager = PurgerTestNetworkManager()
    let attachmentInspector = PurgerTestAttachmentInspector()
    let gatewayManager = PurgerTestGatewayManager()
    let forwardingManager: PurgerTestForwardingManager

    var lifetimeLockPath: String {
        root.appendingPathComponent("daemon.lock").path
    }

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-purge-tests-\(UUID().uuidString)", isDirectory: true)
        dataplaneStore = FlannelOwnershipStateStore(url: root.appendingPathComponent("ownership.json"))
        forwardingOwnershipStore = FlannelForwardingOwnershipStore(
            url: root.appendingPathComponent("forwarding-ownership.json"),
            requiredOwnerID: geteuid()
        )
        networkOwnershipStore = FlannelHostOnlyNetworkOwnershipStore(
            url: root.appendingPathComponent("network-ownership.json")
        )
        gatewayOwnershipStore = FlannelHostIPv6GatewayOwnershipStore(
            url: root.appendingPathComponent("host-ipv6-gateway-ownership.json")
        )
        forwardingManager = PurgerTestForwardingManager(
            ownershipStore: forwardingOwnershipStore
        )
    }

    var purger: FlannelHostOnlyNetworkPurger {
        FlannelHostOnlyNetworkPurger(
            networkManager: networkManager,
            attachmentInspector: attachmentInspector,
            dataplaneOwnershipStore: dataplaneStore,
            forwardingOwnershipStore: forwardingOwnershipStore,
            networkOwnershipStore: networkOwnershipStore,
            hostIPv6GatewayManager: gatewayManager,
            hostIPv6GatewayOwnershipStore: gatewayOwnershipStore
        )
    }

    func saveNetworkOwnership(ipv6PodCIDR: String? = nil) throws {
        try networkOwnershipStore.save(
            FlannelHostOnlyNetworkOwnership(
                name: "kubernetes-pod",
                podCIDR: "10.250.22.0/24",
                ipv6PodCIDR: ipv6PodCIDR,
                plugin: "container-network-vmnet",
                variant: "reserved",
                ownershipID: "b7656446-13bc-482b-b02c-22eb6e066a59"
            )
        )
    }

    func saveForwardingOwnership() throws {
        try forwardingOwnershipStore.save(
            FlannelForwardingOwnership(
                bootSessionID: "boot-a",
                ipv4: FlannelForwardingFamilyOwnership(
                    originalEnabled: false,
                    phase: .owned
                )
            )
        )
    }

    func forwardingRecovery(
        readyStateExists: Bool = false
    ) -> FlannelOfflineForwardingRecovery {
        FlannelOfflineForwardingRecovery(
            dataplaneOwnershipStore: dataplaneStore,
            forwardingOwnershipStore: forwardingOwnershipStore,
            hostIPv6GatewayOwnershipStore: gatewayOwnershipStore,
            forwardingManager: forwardingManager,
            readyStateExists: { readyStateExists }
        )
    }

    func acquireLifetimeLock() throws -> FlannelDaemonLifetimeLock {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let lifetimeLock = try FlannelDaemonLifetimeLock.tryAcquire(path: lifetimeLockPath) else {
            throw FlannelVXLANError.runtime("test daemon lifetime lock is already held")
        }
        return lifetimeLock
    }

    func gatewayOwnership() -> FlannelHostIPv6GatewayOwnership {
        FlannelHostIPv6GatewayOwnership(
            networkName: "kubernetes-pod",
            networkOwnershipID: "b7656446-13bc-482b-b02c-22eb6e066a59",
            ipv4PodCIDR: "10.250.22.0/24",
            ipv6PodCIDR: "fd42:10:244:22::/64",
            interfaceName: "bridge100",
            ipv4Gateway: "10.250.22.1",
            ipv6Gateway: "fd42:10:244:22::1"
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum OfflineForwardingRecoveryBlockingState: CaseIterable, Sendable {
    case dataplane
    case gateway
    case readyState
}

private final class PurgerTestForwardingManager: FlannelForwardingManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let ownershipStore: FlannelForwardingOwnershipStore
    private var restoreAllCallCount = 0

    init(ownershipStore: FlannelForwardingOwnershipStore) {
        self.ownershipStore = ownershipStore
    }

    var restoreAllCalls: Int {
        lock.withLock { restoreAllCallCount }
    }

    func ensureEnabled(_: FlannelForwardingFamily) throws {
        throw FlannelVXLANError.runtime("unexpected forwarding enable")
    }

    func restore(_: FlannelForwardingFamily) throws -> Bool {
        throw FlannelVXLANError.runtime("unexpected single-family forwarding restore")
    }

    func restoreAll() throws -> [FlannelForwardingFamily] {
        lock.withLock { restoreAllCallCount += 1 }
        let families = try ownershipStore.load()?.families.sorted() ?? []
        try ownershipStore.remove()
        return families
    }

    func ownedFamilies() throws -> Set<FlannelForwardingFamily> {
        try ownershipStore.load()?.families ?? []
    }
}

private final class PurgerTestForwardingCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [[String]] = []

    var calls: [[String]] {
        lock.withLock { recordedCalls }
    }

    func run(executable: String, arguments: [String]) -> String {
        lock.withLock { recordedCalls.append([executable] + arguments) }
        return "0\n"
    }
}

private final class PurgerTestGatewayManager: FlannelHostIPv6GatewayManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var removedValues: [FlannelHostIPv6GatewayOwnership] = []

    var removed: [FlannelHostIPv6GatewayOwnership] {
        lock.withLock { removedValues }
    }

    func reconcile(
        networkOwnership _: FlannelHostOnlyNetworkOwnership,
        knownOwnership _: FlannelHostIPv6GatewayOwnership?
    ) throws -> FlannelHostIPv6GatewayReconcileResult {
        throw FlannelVXLANError.runtime("unexpected gateway reconciliation")
    }

    func remove(ownership: FlannelHostIPv6GatewayOwnership) throws {
        lock.withLock { removedValues.append(ownership) }
    }
}

private actor PurgerTestNetworkManager: FlannelNetworkManaging {
    var validationCalls = 0
    var purgeCalls: [FlannelHostOnlyNetworkOwnership] = []
    private var validationFails = false

    func ensureHostOnlyNetwork(
        name: String,
        podCIDR: String,
        plugin: String,
        variant: String,
        knownOwnership: FlannelHostOnlyNetworkOwnership?
    ) async throws -> FlannelHostOnlyNetworkReconcileResult {
        throw FlannelVXLANError.runtime("unexpected network reconciliation")
    }

    func validateOwnedHostOnlyNetwork(
        ownership: FlannelHostOnlyNetworkOwnership
    ) async throws -> Bool {
        validationCalls += 1
        if validationFails {
            throw FlannelVXLANError.runtime("injected ownership validation failure")
        }
        return true
    }

    func purgeHostOnlyNetwork(
        ownership: FlannelHostOnlyNetworkOwnership
    ) async throws -> FlannelHostOnlyNetworkPurgeResult {
        purgeCalls.append(ownership)
        return FlannelHostOnlyNetworkPurgeResult(networkWasPresent: true, removed: true)
    }

    func failValidations(_ value: Bool) {
        validationFails = value
    }
}

private actor PurgerTestAttachmentInspector: FlannelNetworkAttachmentInspecting {
    var inspectionCalls = 0
    private var objectIDs: [String] = []
    private var inspectionFails = false
    private var inspectionHook: (@Sendable () -> Void)?

    func referringObjectIDs(networkName: String) async throws -> [String] {
        inspectionCalls += 1
        if inspectionFails {
            throw FlannelVXLANError.runtime("injected attachment inspection failure")
        }
        let hook = inspectionHook
        inspectionHook = nil
        hook?()
        return objectIDs
    }

    func setObjectIDs(_ values: [String]) {
        objectIDs = values
    }

    func failInspections(_ value: Bool) {
        inspectionFails = value
    }

    func setInspectionHook(_ hook: @escaping @Sendable () -> Void) {
        inspectionHook = hook
    }
}
