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

struct FlannelStateManifestTests {
    @Test func legacyManagedStatePathsDecodeWithoutStatusPath() throws {
        let data = Data(
            """
            {
                "dataplaneOwnership": "/var/lib/container/flannel-vxlan/ownership.json",
                "networkOwnership": "/var/lib/container/flannel-vxlan/network-ownership.json",
                "hostIPv6GatewayOwnership": "/var/lib/container/flannel-vxlan/host-ipv6-gateway-ownership.json",
                "forwardingOwnership": "/var/lib/container/flannel-vxlan/forwarding-ownership.json",
                "ready": "/var/lib/container/flannel-vxlan/ready.json"
            }
            """.utf8
        )

        let paths = try JSONDecoder().decode(FlannelManagedStatePaths.self, from: data)

        #expect(paths.statusPath == nil)
        #expect(paths.all.count == 5)
    }

    @Test func configuredStatusPathParticipatesInManagedState() {
        let config = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a",
            statusPath: FlannelVXLANMacOSConfig.defaultStatusPath
        )

        #expect(config.managedStatePaths.statusPath == FlannelVXLANMacOSConfig.defaultStatusPath)
        #expect(config.managedStatePaths.all.contains(FlannelVXLANMacOSConfig.defaultStatusPath))
    }

    @Test func legacyManifestCanAtomicallyAddStatusPathWhileNetworkOwnershipRemains() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let lock = try fixture.lock()
        defer { lock.release() }

        let legacyManifest = try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )
        try fixture.createState(at: fixture.config.networkOwnershipStatePath)
        var upgradedConfig = fixture.config
        upgradedConfig.statusPath = FlannelVXLANMacOSConfig.defaultStatusPath
        var incompatibleUpgrade = upgradedConfig
        incompatibleUpgrade.nodeName = "mac-b"

        #expect(throws: FlannelVXLANError.self) {
            try fixture.coordinator.validateClaim(
                configPath: fixture.configPath,
                config: incompatibleUpgrade,
                whileHolding: lock
            )
        }
        #expect(throws: FlannelVXLANError.self) {
            try fixture.coordinator.claim(
                configPath: fixture.configPath,
                config: incompatibleUpgrade,
                whileHolding: lock
            )
        }
        #expect(try fixture.store.load() == legacyManifest)

        try fixture.coordinator.validateClaim(
            configPath: fixture.configPath,
            config: upgradedConfig,
            whileHolding: lock
        )
        #expect(try fixture.store.load() == legacyManifest)

        let upgradedManifest = try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: upgradedConfig,
            whileHolding: lock
        )
        #expect(upgradedManifest.statePaths.statusPath == FlannelVXLANMacOSConfig.defaultStatusPath)
        #expect(try fixture.store.load() == upgradedManifest)
        #expect(FileManager.default.fileExists(atPath: fixture.config.networkOwnershipStatePath))

        #expect(throws: FlannelVXLANError.self) {
            try fixture.coordinator.validateClaim(
                configPath: fixture.configPath,
                config: fixture.config,
                whileHolding: lock
            )
        }
        #expect(throws: FlannelVXLANError.self) {
            try fixture.coordinator.claim(
                configPath: fixture.configPath,
                config: fixture.config,
                whileHolding: lock
            )
        }
        #expect(try fixture.store.load() == upgradedManifest)
        #expect(FileManager.default.fileExists(atPath: fixture.config.networkOwnershipStatePath))
    }

    @Test func customStateIsDiscoveredAfterConfigurationDisappears() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let lock = try fixture.lock()
        defer { lock.release() }

        let manifest = try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )
        try fixture.createState(at: fixture.config.forwardingOwnershipStatePath)

        #expect(manifest.statePaths.forwardingOwnership == fixture.config.forwardingOwnershipStatePath)
        #expect(
            try fixture.coordinator.discoverMissingConfiguration(
                requestedConfigPath: fixture.configPath,
                whileHolding: lock
            )
                == .managedStateRemains(
                    expectedConfigPath: FlannelVXLANMacOSConfig.canonicalFilePath(fixture.configPath),
                    paths: [fixture.config.forwardingOwnershipStatePath]
                )
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func missingConfigurationDoesNotDeleteAnUnownedManifest() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let lock = try fixture.lock()
        defer { lock.release() }

        try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )

        #expect(
            try fixture.coordinator.discoverMissingConfiguration(
                requestedConfigPath: fixture.configPath,
                whileHolding: lock
            )
                == .noManagedState(
                    expectedConfigPath: FlannelVXLANMacOSConfig.canonicalFilePath(fixture.configPath)
                )
        )
        #expect(try fixture.store.load() != nil)
    }

    @Test func missingConfigurationPathMismatchIsRejected() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let lock = try fixture.lock()
        defer { lock.release() }

        try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )

        #expect(throws: FlannelVXLANError.self) {
            try fixture.coordinator.discoverMissingConfiguration(
                requestedConfigPath: fixture.root.appendingPathComponent("other-config.json").path,
                whileHolding: lock
            )
        }
    }

    @Test func claimMismatchRequiresAllOldAndNewStateToBeAbsent() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let lock = try fixture.lock()
        defer { lock.release() }

        try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )
        try fixture.createState(at: fixture.config.ownershipStatePath)
        var replacement = fixture.config
        replacement.nodeName = "mac-b"

        #expect(throws: FlannelVXLANError.self) {
            try fixture.coordinator.claim(
                configPath: fixture.configPath,
                config: replacement,
                whileHolding: lock
            )
        }

        try FileManager.default.removeItem(atPath: fixture.config.ownershipStatePath)
        let replaced = try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: replacement,
            whileHolding: lock
        )
        #expect(replaced.identity.nodeName == "mac-b")
        #expect(try fixture.store.load()?.identity.nodeName == "mac-b")
    }

    @Test func readOnlyClaimValidationDoesNotCreateOrReplaceManifest() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let lock = try fixture.lock()
        defer { lock.release() }

        try fixture.coordinator.validateClaim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )
        #expect(try fixture.store.load() == nil)

        try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )
        try fixture.createState(at: fixture.config.ownershipStatePath)
        var replacement = fixture.config
        replacement.nodeName = "mac-b"

        #expect(throws: FlannelVXLANError.self) {
            try fixture.coordinator.validateClaim(
                configPath: fixture.configPath,
                config: replacement,
                whileHolding: lock
            )
        }
        #expect(try fixture.store.load()?.identity.nodeName == "mac-a")
    }

    @Test func exactClaimRequiresAPersistedMatchingManifest() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let lock = try fixture.lock()
        defer { lock.release() }

        #expect(throws: FlannelVXLANError.self) {
            try fixture.coordinator.requireExactClaim(
                configPath: fixture.configPath,
                config: fixture.config,
                whileHolding: lock
            )
        }

        let claimed = try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )
        #expect(
            try fixture.coordinator.requireExactClaim(
                configPath: fixture.configPath,
                config: fixture.config,
                whileHolding: lock
            ) == claimed
        )

        var replacement = fixture.config
        replacement.nodeName = "mac-b"
        #expect(throws: FlannelVXLANError.self) {
            try fixture.coordinator.requireExactClaim(
                configPath: fixture.configPath,
                config: replacement,
                whileHolding: lock
            )
        }
    }

    @Test func manifestIsRemovedOnlyAfterEveryManagedStateFileIsGone() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let lock = try fixture.lock()
        defer { lock.release() }

        try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )
        try fixture.createState(at: fixture.config.networkOwnershipStatePath)

        #expect(try !fixture.coordinator.removeIfUnowned(whileHolding: lock))
        #expect(try fixture.store.load() != nil)

        try FileManager.default.removeItem(atPath: fixture.config.networkOwnershipStatePath)
        #expect(try fixture.coordinator.removeIfUnowned(whileHolding: lock))
        #expect(try fixture.store.load() == nil)
    }

    @Test func danglingManagedStateSymlinkFailsClosed() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let lock = try fixture.lock()
        defer { lock.release() }

        try fixture.coordinator.claim(
            configPath: fixture.configPath,
            config: fixture.config,
            whileHolding: lock
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: fixture.config.ownershipStatePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.config.ownershipStatePath,
            withDestinationPath: fixture.root.appendingPathComponent("missing-target").path
        )

        guard
            case .managedStateRemains(_, let paths) = try fixture.coordinator.discoverMissingConfiguration(
                requestedConfigPath: fixture.configPath,
                whileHolding: lock
            )
        else {
            Issue.record("expected a dangling symlink to count as remaining managed state")
            return
        }
        #expect(paths == [fixture.config.ownershipStatePath])
    }

    @Test func storeRejectsInsecureOrSymlinkedManifests() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let manifest = try FlannelStateManifest(configPath: fixture.configPath, config: fixture.config)

        try fixture.store.save(manifest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.store.url.path
        )
        #expect(throws: FlannelVXLANError.self) {
            try fixture.store.load()
        }

        try FileManager.default.removeItem(at: fixture.store.url)
        let target = fixture.root.appendingPathComponent("manifest-target.json")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.store.url,
            withDestinationURL: target
        )
        #expect(throws: FlannelVXLANError.self) {
            try fixture.store.load()
        }
    }

    @Test func storeRejectsUnsupportedSchema() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let manifest = FlannelStateManifest(
            schemaVersion: 2,
            configPath: fixture.configPath,
            identity: FlannelStateManifestIdentity(
                nodeName: "mac-a",
                networkName: "kubernetes-pod",
                networkPlugin: "container-network-vmnet",
                networkVariant: "reserved",
                annotationPrefix: "flannel.alpha.coreos.com"
            ),
            statePaths: fixture.config.managedStatePaths
        )

        #expect(throws: FlannelVXLANError.self) {
            try fixture.store.save(manifest)
        }
    }
}

private final class ManifestFixture {
    let root: URL
    let configPath: String
    let config: FlannelVXLANMacOSConfig
    let store: FlannelStateManifestStore
    let coordinator: FlannelStateManifestCoordinator
    let lifetimeLockPath: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-state-manifest-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configPath = root.appendingPathComponent("flannel.conf").path
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        config = FlannelVXLANMacOSConfig(
            kubeconfig: root.appendingPathComponent("flannel.kubeconfig").path,
            nodeKubeconfig: root.appendingPathComponent("kubelet.kubeconfig").path,
            nodeName: "mac-a",
            vtepMACPath: stateRoot.appendingPathComponent("vtep-mac").path,
            runtimeStatePath: root.appendingPathComponent("runtime.json").path,
            readyStatePath: stateRoot.appendingPathComponent("ready.json").path,
            ownershipStatePath: stateRoot.appendingPathComponent("ownership.json").path
        )
        store = FlannelStateManifestStore(
            url: root.appendingPathComponent("manifest/state-manifest.json"),
            requiredOwnerID: geteuid()
        )
        coordinator = FlannelStateManifestCoordinator(store: store)
        lifetimeLockPath = root.appendingPathComponent("lifetime.lock").path
    }

    func lock() throws -> FlannelDaemonLifetimeLock {
        guard let lock = try FlannelDaemonLifetimeLock.tryAcquire(path: lifetimeLockPath) else {
            throw FlannelVXLANError.runtime("test lifetime lock is unexpectedly held")
        }
        return lock
    }

    func createState(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("state".utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
