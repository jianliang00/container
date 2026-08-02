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
                localPodCIDR: "10.244.22.0/24",
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
    func readOnlyCheckAllowsActiveDataplaneButPurgeRequiresWithdrawal() async throws {
        let fixture = PurgerFixture()
        defer { fixture.removeFiles() }
        try fixture.saveNetworkOwnership()
        try fixture.dataplaneStore.save(
            FlannelOwnershipState(
                interfaceName: "utun42",
                localPodCIDR: "10.244.22.0/24",
                routePodCIDRs: ["10.244.5.0/24"]
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
            ipv4Address: try CIDRv4("10.244.22.2/24"),
            ipv4Gateway: try IPv4Address("10.244.22.1"),
            ipv6Address: nil,
            macAddress: nil
        )
    }
    return ContainerSnapshot(configuration: configuration, status: .stopped, networks: attachments)
}

private struct PurgerFixture {
    let root: URL
    let dataplaneStore: FlannelOwnershipStateStore
    let networkOwnershipStore: FlannelHostOnlyNetworkOwnershipStore
    let networkManager = PurgerTestNetworkManager()
    let attachmentInspector = PurgerTestAttachmentInspector()

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-purge-tests-\(UUID().uuidString)", isDirectory: true)
        dataplaneStore = FlannelOwnershipStateStore(url: root.appendingPathComponent("ownership.json"))
        networkOwnershipStore = FlannelHostOnlyNetworkOwnershipStore(
            url: root.appendingPathComponent("network-ownership.json")
        )
    }

    var purger: FlannelHostOnlyNetworkPurger {
        FlannelHostOnlyNetworkPurger(
            networkManager: networkManager,
            attachmentInspector: attachmentInspector,
            dataplaneOwnershipStore: dataplaneStore,
            networkOwnershipStore: networkOwnershipStore
        )
    }

    func saveNetworkOwnership() throws {
        try networkOwnershipStore.save(
            FlannelHostOnlyNetworkOwnership(
                name: "kubernetes-pod",
                podCIDR: "10.244.22.0/24",
                plugin: "container-network-vmnet",
                variant: "reserved",
                ownershipID: "b7656446-13bc-482b-b02c-22eb6e066a59"
            )
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
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

    func referringObjectIDs(networkName: String) async throws -> [String] {
        inspectionCalls += 1
        if inspectionFails {
            throw FlannelVXLANError.runtime("injected attachment inspection failure")
        }
        return objectIDs
    }

    func setObjectIDs(_ values: [String]) {
        objectIDs = values
    }

    func failInspections(_ value: Bool) {
        inspectionFails = value
    }
}
