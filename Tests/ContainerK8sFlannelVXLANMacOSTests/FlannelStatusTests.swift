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

import Darwin
import Foundation
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelStatusTests {
    private let controllerInstanceID = "8C049DCB-30EE-4B15-BE4B-A26144195B9D"

    @Test
    func recordsReadyDegradedFailureAndRecoveryTransitions() throws {
        let store = InMemoryFlannelStatusStore()
        let clock = FlannelStatusSequenceClock()
        let recorder = FlannelStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID,
            now: { clock.next() }
        )
        let config = makeConfig()

        let starting = try recorder.recordStarting(
            nodeName: config.nodeName,
            networkName: config.networkName,
            ipv6Enabled: config.dualStackEnabled,
            syncPeriodSeconds: config.syncPeriodSeconds
        )
        #expect(starting.state == .starting)
        #expect(starting.attemptedGeneration == 0)
        #expect(starting.ipv4.ready == nil)
        #expect(starting.ipv6.ready == nil)

        let ready = try recorder.record(result: makeResult(), generation: 1, config: config)
        let firstSuccessAt = try #require(ready.lastSuccessAt)
        #expect(ready.state == .ready)
        #expect(ready.lastSuccessfulGeneration == 1)
        #expect(ready.runtimeGeneration == 42)
        #expect(ready.ipv4.peerCount == 1)
        #expect(ready.ipv4.routeCount == 1)
        #expect(ready.ipv4.tunnelUp == true)
        #expect(ready.ipv4.tunnelEpoch == 3)
        #expect(ready.ipv4.wireCounters?.sourceCIDRMismatches == 8)
        #expect(ready.ipv6.wireCounters?.transmittedPackets == 9)

        var degradedResult = makeResult()
        degradedResult.ipv6Ready = false
        degradedResult.ipv6TunnelUp = true
        degradedResult.issues = [
            FlannelCompileIssue(
                id: "peer-v6-pending",
                severity: .pending,
                message: "one IPv6 peer is not published"
            )
        ]
        let degraded = try recorder.record(result: degradedResult, generation: 2, config: config)
        #expect(degraded.state == .degraded)
        #expect(degraded.lastSuccessAt != firstSuccessAt)
        #expect(degraded.lastSuccessfulGeneration == 2)
        #expect(degraded.errorCode == "compileIssues")
        #expect(degraded.ipv6.ready == false)
        #expect(degraded.ipv6.tunnelUp == true)

        let failed = try recorder.recordFailure(
            error: FlannelVXLANError.runtime("route reconcile failed"),
            generation: 3,
            config: config
        )
        #expect(failed.state == .failed)
        #expect(failed.lastSuccessAt == degraded.lastSuccessAt)
        #expect(failed.lastSuccessfulGeneration == 2)
        #expect(failed.runtimeGeneration == nil)
        #expect(failed.mtu == nil)
        #expect(failed.ipv4.ready == nil)
        #expect(failed.ipv4.tunnelUp == nil)
        #expect(failed.ipv6.wireCounters == nil)
        #expect(failed.errorCode == "runtime")

        let recovered = try recorder.record(result: makeResult(), generation: 3, config: config)
        #expect(recovered.state == .ready)
        #expect(recovered.lastSuccessfulGeneration == 3)
        #expect(recovered.lastSuccessAt != degraded.lastSuccessAt)
    }

    @Test
    func statusLeaseUsesFourSyncPeriodsWithFifteenSecondMinimum() throws {
        let clock = FlannelStatusSequenceClock()
        let recorder = FlannelStatusRecorder(
            store: InMemoryFlannelStatusStore(),
            controllerInstanceID: controllerInstanceID,
            now: { clock.next() }
        )
        var config = makeConfig()
        config.syncPeriodSeconds = 2
        let shortLease = try recorder.recordStarting(
            nodeName: config.nodeName,
            networkName: config.networkName,
            ipv6Enabled: config.dualStackEnabled,
            syncPeriodSeconds: config.syncPeriodSeconds
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try shortLease.freshness(at: start.addingTimeInterval(14)) == .fresh)
        #expect(try shortLease.freshness(at: start.addingTimeInterval(15)) == .expired)

        config.syncPeriodSeconds = Int.max
        let cappedLease = try recorder.recordStarting(
            nodeName: config.nodeName,
            networkName: config.networkName,
            ipv6Enabled: config.dualStackEnabled,
            syncPeriodSeconds: config.syncPeriodSeconds
        )
        let next = start.addingTimeInterval(1)
        #expect(try cappedLease.freshness(at: next.addingTimeInterval(259_199)) == .fresh)
        #expect(try cappedLease.freshness(at: next.addingTimeInterval(259_200)) == .expired)
    }

    @Test
    func validatesStateSpecificOperationalData() throws {
        let valid = try makeReadyStatusInMemory()
        var invalidReady = valid
        invalidReady.ipv4.routeCount = nil
        #expect(throws: FlannelStatusStoreError.self) {
            try invalidReady.freshness()
        }

        invalidReady = valid
        invalidReady.ipv4.tunnelUp = false
        #expect(throws: FlannelStatusStoreError.self) {
            try invalidReady.freshness()
        }

        invalidReady = valid
        invalidReady.ipv6.tunnelEpoch = 0
        #expect(throws: FlannelStatusStoreError.self) {
            try invalidReady.freshness()
        }

        var invalidGeneration = valid
        invalidGeneration.lastSuccessfulGeneration = 2
        #expect(throws: FlannelStatusStoreError.self) {
            try invalidGeneration.freshness()
        }

        var invalidTimestamp = valid
        invalidTimestamp.updatedAt = "2026-02-31T00:00:00Z"
        #expect(throws: FlannelStatusStoreError.self) {
            try invalidTimestamp.freshness()
        }

        var degraded = valid
        degraded.state = .degraded
        degraded.errorCode = "familyNotReady"
        degraded.errorMessage = "IPv6 is not ready"
        degraded.ipv6.ready = false
        degraded.ipv6.tunnelUp = true
        #expect(try degraded.freshness() == .expired)

        var failed = valid
        failed.state = .failed
        failed.errorCode = "runtime"
        failed.errorMessage = "failed"
        failed.runtimeGeneration = nil
        failed.mtu = nil
        failed.ipv4 = .unknown(enabled: true)
        failed.ipv6 = .unknown(enabled: true)
        #expect(try failed.freshness() == .expired)
    }

    @Test
    func encodesAllWireCountersWithStableKeyOrdering() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let store = FlannelStatusFileStore(url: url)
        let status = try makeReadyStatusInMemory()

        try store.save(status)
        let first = try Data(contentsOf: url)
        try store.save(status)
        let second = try Data(contentsOf: url)
        #expect(first == second)

        let json = try #require(String(data: first, encoding: .utf8))
        for key in [
            "transmittedPackets",
            "transmittedBytes",
            "receivedPackets",
            "receivedBytes",
            "unknownPeerPackets",
            "invalidPackets",
            "oversizedPackets",
            "sourceCIDRMismatches",
        ] {
            #expect(json.contains("\"\(key)\""))
        }
        #expect(json.first == "{")
        #expect(json.contains("\"attemptedGeneration\":1,\"controllerInstanceID\""))
    }

    @Test
    func fileStoreRoundTripsProtectedStatusAndRemovesIt() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let store = FlannelStatusFileStore(url: url)
        let status = try makeReadyStatusInMemory()

        try store.save(status)
        #expect(try store.load() == status)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
        #expect((attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value == getegid())

        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test
    func fileStoreRejectsUnexpectedOwnershipSymlinkAndWrongMode() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = try makeReadyStatusInMemory()

        let wrongOwnershipStore = FlannelStatusFileStore(
            url: directory.appendingPathComponent("owner.json"),
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid() &+ 1
        )
        try FlannelStatusFileStore(url: wrongOwnershipStore.url).save(status)
        #expect(throws: FlannelStatusStoreError.self) {
            try wrongOwnershipStore.save(status)
        }
        #expect(throws: FlannelStatusStoreError.self) {
            try wrongOwnershipStore.remove()
        }

        let targetURL = directory.appendingPathComponent("target.json")
        let symlinkURL = directory.appendingPathComponent("symlink.json")
        try Data("{}".utf8).write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: targetURL.path
        )
        #expect(throws: FlannelStatusStoreError.self) {
            try FlannelStatusFileStore(url: symlinkURL).load()
        }
        #expect(throws: FlannelStatusStoreError.self) {
            try FlannelStatusFileStore(url: symlinkURL).remove()
        }

        let url = directory.appendingPathComponent("mode.json")
        let store = FlannelStatusFileStore(url: url)
        try store.save(status)
        for mode in [0o644, 0o4600] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            #expect(throws: FlannelStatusStoreError.self) {
                try store.load()
            }
            #expect(throws: FlannelStatusStoreError.self) {
                try store.save(status)
            }
            #expect(throws: FlannelStatusStoreError.self) {
                try store.remove()
            }
        }
    }

    @Test
    func fileStoreRejectsUnsafeOrSymlinkedStatusDirectory() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = try makeReadyStatusInMemory()

        let writableDirectory = directory.appendingPathComponent("writable")
        try FileManager.default.createDirectory(at: writableDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writableDirectory.path)
        #expect(throws: FlannelStatusStoreError.self) {
            try FlannelStatusFileStore(
                url: writableDirectory.appendingPathComponent("status.json")
            ).save(status)
        }

        let actualDirectory = directory.appendingPathComponent("actual")
        let symlinkedDirectory = directory.appendingPathComponent("symlinked")
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkedDirectory.path,
            withDestinationPath: actualDirectory.path
        )
        #expect(throws: FlannelStatusStoreError.self) {
            try FlannelStatusFileStore(
                url: symlinkedDirectory.appendingPathComponent("status.json")
            ).save(status)
        }
    }

    @Test
    func fileStoreRejectsExtendedACLs() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = try makeReadyStatusInMemory()

        let statusURL = directory.appendingPathComponent("status.json")
        let store = FlannelStatusFileStore(url: statusURL)
        try store.save(status)
        try addEveryoneReadACL(to: statusURL)
        #expect(throws: FlannelStatusStoreError.self) {
            try store.load()
        }
        #expect(throws: FlannelStatusStoreError.self) {
            try store.save(status)
        }
        #expect(throws: FlannelStatusStoreError.self) {
            try store.remove()
        }

        let protectedDirectory = directory.appendingPathComponent("protected")
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        try addEveryoneReadACL(to: protectedDirectory)
        #expect(throws: FlannelStatusStoreError.self) {
            try FlannelStatusFileStore(
                url: protectedDirectory.appendingPathComponent("status.json")
            ).save(status)
        }
    }

    @Test
    func fileStoreRemovesCorruptedProtectedStatusButRejectsUnsafeFiles() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oversizedURL = directory.appendingPathComponent("oversized.json")
        try Data(count: 65 * 1_024).write(to: oversizedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversizedURL.path)
        let oversizedStore = FlannelStatusFileStore(url: oversizedURL)
        #expect(throws: FlannelStatusStoreError.self) {
            try oversizedStore.load()
        }
        try oversizedStore.remove()
        #expect(!FileManager.default.fileExists(atPath: oversizedURL.path))

        let foreignURL = directory.appendingPathComponent("foreign.json")
        let foreignData = Data("not a flannel status".utf8)
        try foreignData.write(to: foreignURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foreignURL.path)
        let foreignStore = FlannelStatusFileStore(url: foreignURL)
        #expect(throws: FlannelStatusStoreError.self) {
            try foreignStore.save(try makeReadyStatusInMemory())
        }
        #expect(try Data(contentsOf: foreignURL) == foreignData)
        try foreignStore.remove()
        #expect(!FileManager.default.fileExists(atPath: foreignURL.path))

        let fifoURL = directory.appendingPathComponent("fifo.json")
        #expect(mkfifo(fifoURL.path, mode_t(0o600)) == 0)
        let fifoStore = FlannelStatusFileStore(url: fifoURL)
        #expect(throws: FlannelStatusStoreError.self) {
            try fifoStore.load()
        }
        #expect(throws: FlannelStatusStoreError.self) {
            try fifoStore.remove()
        }
        #expect(throws: FlannelStatusStoreError.self) {
            try fifoStore.save(try makeReadyStatusInMemory())
        }
    }

    @Test
    func truncatesMultibyteFailureMessageByEncodedSize() throws {
        let store = InMemoryFlannelStatusStore()
        let status = try FlannelStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID
        ).recordFailure(
            nodeName: "node-a",
            networkName: "kubernetes-pod",
            generation: 1,
            ipv6Enabled: true,
            syncPeriodSeconds: 5,
            errorCode: "runtime",
            errorMessage: String(repeating: "🙂", count: 4_096)
        )

        #expect(try #require(status.errorMessage).utf8.count <= 4_096)
        #expect(try store.load() == status)
    }

    @Test
    func stoppedTunnelResultIsReportedAsDegraded() throws {
        let store = InMemoryFlannelStatusStore()
        let recorder = FlannelStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let config = makeConfig()
        var result = makeResult()
        result.tunnelUp = false

        let status = try recorder.record(result: result, generation: 1, config: config)

        #expect(status.state == .degraded)
        #expect(status.errorCode == "tunnelNotRunning")
        #expect(status.ipv4.ready == false)
        #expect(status.ipv4.tunnelUp == false)
        #expect(try store.load() == status)

        result = makeResult()
        result.ipv6TunnelUp = false
        result.issues = [
            FlannelCompileIssue(
                id: "local/ipv6-tunnel-stopped",
                severity: .error,
                message: "IPv6 tunnel stopped before readiness publication; IPv4 dataplane was retained"
            )
        ]
        let ipv6Status = try recorder.record(result: result, generation: 2, config: config)
        #expect(ipv6Status.state == .degraded)
        #expect(ipv6Status.errorCode == "tunnelNotRunning")
        #expect(ipv6Status.ipv6.ready == false)
        #expect(ipv6Status.ipv6.tunnelUp == false)

        var ipv4OnlyConfig = config
        ipv4OnlyConfig.dualStackEnabled = false
        result.issues = []
        let ipv4OnlyStatus = try recorder.record(
            result: result,
            generation: 3,
            config: ipv4OnlyConfig
        )
        #expect(ipv4OnlyStatus.state == .ready)
        #expect(ipv4OnlyStatus.ipv6 == .disabled)
    }

    private func makeReadyStatusInMemory() throws -> FlannelStatus {
        try FlannelStatusRecorder(
            store: InMemoryFlannelStatusStore(),
            controllerInstanceID: controllerInstanceID,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        ).record(result: makeResult(), generation: 1, config: makeConfig())
    }

    private func makeConfig() -> FlannelVXLANMacOSConfig {
        FlannelVXLANMacOSConfig(
            kubeconfig: "/tmp/kubeconfig",
            nodeName: "node-a",
            dualStackEnabled: true,
            runtimeStatePath: "/tmp/runtime.json",
            readyStatePath: "/tmp/ready.json",
            ownershipStatePath: "/tmp/ownership.json"
        )
    }

    private func makeResult() -> FlannelVXLANReconcileResult {
        FlannelVXLANReconcileResult(
            runtimeGeneration: 42,
            localNetwork: FlannelLocalNodeNetwork(
                nodeName: "node-a",
                podCIDR: "10.250.22.0/24",
                subnetBase: "10.250.22.0"
            ),
            underlay: FlannelUnderlayInterface(
                name: "en7",
                ipv4Address: "192.0.2.24",
                ipv6Address: "2001:db8:200:109d::24",
                mtu: 1_500
            ),
            interfaceName: "utun4",
            mtu: 1_450,
            peers: [
                FlannelPeer(
                    nodeName: "linux-a",
                    podCIDR: "10.250.2.0/24",
                    subnetBase: "10.250.2.0",
                    publicIP: "198.18.55.8",
                    vni: 4_096,
                    vtepMAC: "0a:58:0a:f4:02:00"
                )
            ],
            routeCount: 1,
            tunnelUp: true,
            tunnelEpoch: 3,
            localIPv6Network: FlannelLocalNodeIPv6Network(
                nodeName: "node-a",
                podCIDR: "fd42:10:244:22::/64",
                subnetBase: "fd42:10:244:22::"
            ),
            ipv6InterfaceName: "utun5",
            ipv6Peers: [
                FlannelIPv6Peer(
                    nodeName: "linux-a",
                    podCIDR: "fd42:10:244:2::/64",
                    subnetBase: "fd42:10:244:2::",
                    publicIPv6: "2001:db8:200:109d::8",
                    vni: 4_096,
                    vtepMAC: "0a:58:00:00:00:02"
                )
            ],
            ipv6RouteCount: 1,
            ipv6TunnelUp: true,
            ipv6TunnelEpoch: 4,
            ipv4Ready: true,
            ipv6Ready: true,
            issues: [],
            statistics: makeStatistics(offset: 0),
            ipv6Statistics: makeStatistics(offset: 8)
        )
    }

    private func makeStatistics(offset: UInt64) -> FlannelTunnelStatistics {
        FlannelTunnelStatistics(
            transmittedPackets: offset + 1,
            transmittedBytes: offset + 2,
            receivedPackets: offset + 3,
            receivedBytes: offset + 4,
            unknownPeerPackets: offset + 5,
            invalidPackets: offset + 6,
            oversizedPackets: offset + 7,
            sourceCIDRMismatches: offset + 8
        )
    }

    private func makePrivateTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-status-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func addEveryoneReadACL(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FlannelStatusStoreError.persistence(
                "failed to add an extended ACL to the test fixture at \(url.path)"
            )
        }
    }
}

private final class InMemoryFlannelStatusStore: FlannelStatusStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: FlannelStatus?

    func load() throws -> FlannelStatus? {
        lock.withLock { value }
    }

    func save(_ status: FlannelStatus) throws {
        lock.withLock {
            value = status
        }
    }

    func remove() throws {
        lock.withLock {
            value = nil
        }
    }
}

private final class FlannelStatusSequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    func next() -> Date {
        lock.withLock {
            defer { offset += 1 }
            return Date(timeIntervalSince1970: 1_700_000_000 + offset)
        }
    }
}
