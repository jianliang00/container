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

@testable import ContainerK8sKubeProxyMacOS

struct KubeProxyStatusTests {
    private let controllerInstanceID = "8C049DCB-30EE-4B15-BE4B-A26144195B9D"

    @Test
    func recordsAppliedPendingFailureAndRecoveryTransitions() throws {
        let store = InMemoryKubeProxyStatusStore()
        let clock = SequenceClock()
        let recorder = KubeProxyStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID,
            now: { clock.next() }
        )
        let config = KubeProxyMacOSConfig(
            kubeconfig: "/tmp/kubeconfig",
            nodeName: "node-a",
            dualStackEnabled: true,
            pf: KubeProxyPFConfig(
                runtimeStatePath: "/tmp/runtime.json",
                readyStatePath: "/tmp/ready.json"
            )
        )

        let starting = try recorder.recordStarting(config: config)
        #expect(starting.state == .starting)
        #expect(starting.updatedAt < starting.expiresAt)
        #expect(starting.attemptedGeneration == 0)
        #expect(starting.lastAppliedGeneration == nil)
        #expect(starting.ipv4.applied == nil)
        #expect(starting.ipv6.enabled)
        #expect(starting.pf.finalState == .unknown)

        let applied = try recorder.record(
            result: KubeProxyRunResult(ruleSet: makeDualStackRuleSet(generation: 1), applied: true),
            config: config
        )
        let firstSuccessAt = try #require(applied.lastSuccessAt)
        #expect(applied.state == .applied)
        #expect(applied.attemptedGeneration == 1)
        #expect(applied.lastAppliedGeneration == 1)
        #expect(applied.consecutiveSuccesses == 1)
        #expect(applied.ipv4.desiredRuleCount == 1)
        #expect(applied.ipv4.appliedRuleCount == 1)
        #expect(applied.ipv6.desiredRuleCount == 1)
        #expect(applied.ipv6.appliedRuleCount == 1)
        #expect(applied.pf.finalState == .applied)
        #expect(applied.pf.applyAttempted == true)
        #expect(applied.pf.applySucceeded == true)
        #expect(applied.pf.withdrawalAttempted == false)

        let pending = try recorder.record(
            result: KubeProxyRunResult(
                ruleSet: makeDualStackRuleSet(generation: 2),
                applied: false,
                pendingFamily: .ipv4
            ),
            config: config
        )
        #expect(pending.state == .waitingForPodIngressRoute)
        #expect(pending.lastSuccessAt == firstSuccessAt)
        #expect(pending.lastAppliedGeneration == 1)
        #expect(pending.consecutivePendingCycles == 1)
        #expect(pending.consecutiveSuccesses == 0)
        #expect(pending.ipv4.desiredRuleCount == 1)
        #expect(pending.ipv4.appliedRuleCount == 0)
        #expect(pending.ipv6.desiredRuleCount == 1)
        #expect(pending.ipv6.appliedRuleCount == 0)
        #expect(pending.pf.finalState == .withdrawn)
        #expect(pending.pf.applyAttempted == false)
        #expect(pending.pf.applySucceeded == nil)
        #expect(pending.pf.withdrawalAttempted == true)
        #expect(pending.pf.withdrawalSucceeded == true)
        #expect(pending.pf.rollbackAttempted == false)

        let repeatedPending = try recorder.record(
            result: KubeProxyRunResult(
                ruleSet: makeDualStackRuleSet(generation: 2),
                applied: false,
                pendingFamily: .ipv4
            ),
            config: config
        )
        #expect(repeatedPending.stateSince == pending.stateSince)
        #expect(repeatedPending.consecutivePendingCycles == 2)

        let otherFamilyPending = try recorder.record(
            result: KubeProxyRunResult(
                ruleSet: makeDualStackRuleSet(generation: 2),
                applied: false,
                pendingFamily: .ipv6
            ),
            config: config
        )
        #expect(otherFamilyPending.stateSince != repeatedPending.stateSince)
        #expect(otherFamilyPending.consecutivePendingCycles == 1)

        let failed = try recorder.recordFailure(
            error: KubeProxyMacOSError.applyFailed("PF reload failed"),
            generation: 2,
            config: config
        )
        #expect(failed.state == .failed)
        #expect(failed.lastSuccessAt == firstSuccessAt)
        #expect(failed.lastAppliedGeneration == 1)
        #expect(failed.consecutivePendingCycles == 0)
        #expect(failed.consecutiveFailures == 1)
        #expect(failed.ipv4.applied == nil)
        #expect(failed.pf.finalState == .unknown)
        #expect(failed.pf.applyAttempted == nil)
        #expect(failed.pf.rollbackAttempted == nil)

        let recovered = try recorder.record(
            result: KubeProxyRunResult(ruleSet: makeDualStackRuleSet(generation: 2), applied: true),
            config: config
        )
        #expect(recovered.state == .applied)
        #expect(recovered.lastAppliedGeneration == 2)
        #expect(recovered.consecutiveSuccesses == 1)
        #expect(recovered.consecutiveFailures == 0)
        #expect(recovered.lastSuccessAt != firstSuccessAt)
    }

    @Test
    func freshnessParsesRFC3339WithAndWithoutFractionalSeconds() throws {
        var status = try makeStatusInMemory()
        status.updatedAt = "2023-11-14T22:13:20Z"
        status.expiresAt = "2023-11-14T23:13:35+01:00"
        status.stateSince = "2023-11-14T22:13:19.500Z"
        status.lastSuccessAt = "2023-11-14T23:13:20.000+01:00"

        #expect(
            try status.freshness(at: Date(timeIntervalSince1970: 1_700_000_014)) == .fresh
        )
        #expect(
            try status.isFreshlyApplied(at: Date(timeIntervalSince1970: 1_700_000_014))
        )
    }

    @Test
    func expiredAppliedStatusIsNotFreshlyApplied() throws {
        var status = try makeStatusInMemory()
        status.updatedAt = "2023-11-14T22:13:20Z"
        status.expiresAt = "2023-11-14T22:13:35Z"
        status.stateSince = status.updatedAt
        status.lastSuccessAt = status.updatedAt
        let expiration = Date(timeIntervalSince1970: 1_700_000_015)

        #expect(
            try status.freshness(at: Date(timeIntervalSince1970: 1_699_999_999)) == .expired
        )
        #expect(try status.freshness(at: expiration) == .expired)
        #expect(try !status.isFreshlyApplied(at: expiration))
    }

    @Test
    func capsFreshnessLeaseWithoutIntegerOverflow() throws {
        let clock = SequenceClock()
        let recorder = KubeProxyStatusRecorder(
            store: InMemoryKubeProxyStatusStore(),
            controllerInstanceID: controllerInstanceID,
            now: { clock.next() }
        )
        var config = makeDualStackConfig()
        config.syncPeriodSeconds = Int.max

        let status = try recorder.recordStarting(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try status.freshness(at: start.addingTimeInterval(259_199)) == .fresh)
        #expect(try status.freshness(at: start.addingTimeInterval(259_200)) == .expired)
    }

    @Test
    func rejectsInvalidStatusBeforeReportingFreshness() throws {
        let validStatus = try makeStatusInMemory()
        let invalidTimelines: [(inout KubeProxyStatus) -> Void] = [
            { $0.schemaVersion = KubeProxyStatus.currentSchemaVersion + 1 },
            { $0.pf.finalState = .unknown },
            { $0.lastSuccessAt = nil },
            {
                $0.ipv4.desiredRuleCount = nil
                $0.ipv4.appliedRuleCount = nil
            },
            {
                $0.ipv6.enabled = false
                $0.ipv6.applied = false
                $0.ipv6.desiredRuleCount = 1
                $0.ipv6.appliedRuleCount = 1
            },
            { $0.updatedAt = "not-a-timestamp" },
            { $0.updatedAt += "\n" },
            { $0.updatedAt = "2023-02-31T00:00:00Z" },
            {
                $0.stateSince = "2023-11-14T22:13:21Z"
                $0.updatedAt = "2023-11-14T22:13:20Z"
                $0.expiresAt = "2023-11-14T22:13:35Z"
            },
            {
                $0.updatedAt = "2023-11-14T22:13:20Z"
                $0.expiresAt = $0.updatedAt
                $0.stateSince = $0.updatedAt
                $0.lastSuccessAt = $0.updatedAt
            },
            {
                $0.updatedAt = "2023-11-14T22:13:20Z"
                $0.expiresAt = "2023-11-17T22:13:21Z"
                $0.stateSince = $0.updatedAt
                $0.lastSuccessAt = $0.updatedAt
            },
            {
                $0.updatedAt = "2023-11-14T22:13:20Z"
                $0.expiresAt = "2023-11-14T22:13:35Z"
                $0.stateSince = $0.updatedAt
                $0.lastSuccessAt = "2023-11-14T22:13:21Z"
            },
        ]

        for mutate in invalidTimelines {
            var status = validStatus
            mutate(&status)
            #expect(throws: KubeProxyStatusStoreError.self) {
                try status.freshness(at: Date(timeIntervalSince1970: 1_700_000_000))
            }
        }
    }

    @Test
    func rejectsPendingStatusForDisabledFamily() throws {
        var status = try KubeProxyStatusRecorder(
            store: InMemoryKubeProxyStatusStore(),
            controllerInstanceID: controllerInstanceID
        ).record(
            result: KubeProxyRunResult(
                ruleSet: makeDualStackRuleSet(generation: 1),
                applied: false,
                pendingFamily: .ipv6
            ),
            config: makeDualStackConfig()
        )
        status.ipv6.enabled = false

        #expect(throws: KubeProxyStatusStoreError.self) {
            try status.freshness()
        }
    }

    @Test
    func rejectsFailureStatusWithIPv4Disabled() throws {
        var status = try KubeProxyStatusRecorder(
            store: InMemoryKubeProxyStatusStore(),
            controllerInstanceID: controllerInstanceID
        ).recordFailure(
            error: KubeProxyMacOSError.applyFailed("PF reload failed"),
            generation: 1,
            config: makeDualStackConfig()
        )
        status.ipv4.enabled = false

        #expect(throws: KubeProxyStatusStoreError.self) {
            try status.freshness()
        }
    }

    @Test
    func newControllerInstanceDoesNotInheritGenerationOrCounters() throws {
        let store = InMemoryKubeProxyStatusStore()
        let oldRecorder = KubeProxyStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID
        )
        let config = makeDualStackConfig()
        _ = try oldRecorder.record(
            result: KubeProxyRunResult(
                ruleSet: makeDualStackRuleSet(generation: 100),
                applied: true
            ),
            config: config
        )

        let restartedRecorder = KubeProxyStatusRecorder(
            store: store,
            controllerInstanceID: "FB941924-37A3-4523-988B-D2EBEB37852B"
        )
        let pending = try restartedRecorder.record(
            result: KubeProxyRunResult(
                ruleSet: makeDualStackRuleSet(generation: 1),
                applied: false,
                pendingFamily: .ipv4
            ),
            config: config
        )

        #expect(pending.attemptedGeneration == 1)
        #expect(pending.lastAppliedGeneration == nil)
        #expect(pending.lastSuccessAt == nil)
        #expect(pending.consecutivePendingCycles == 1)
    }

    @Test
    func differentNodeDoesNotInheritStateFromSamePath() throws {
        let store = InMemoryKubeProxyStatusStore()
        let recorder = KubeProxyStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID
        )
        _ = try recorder.record(
            result: KubeProxyRunResult(ruleSet: makeDualStackRuleSet(generation: 1), applied: true),
            config: makeDualStackConfig()
        )

        let pending = try recorder.record(
            result: KubeProxyRunResult(
                ruleSet: makeDualStackRuleSet(generation: 1),
                applied: false,
                pendingFamily: .ipv4
            ),
            config: makeDualStackConfig(nodeName: "node-b")
        )

        #expect(pending.nodeName == "node-b")
        #expect(pending.lastSuccessAt == nil)
        #expect(pending.lastAppliedGeneration == nil)
        #expect(pending.consecutivePendingCycles == 1)
    }

    @Test
    func truncatesMultibyteFailureMessageByEncodedSize() throws {
        let store = InMemoryKubeProxyStatusStore()
        let recorder = KubeProxyStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID
        )

        let status = try recorder.recordFailure(
            error: KubeProxyMacOSError.applyFailed(String(repeating: "🙂", count: 4_096)),
            generation: 1,
            config: makeDualStackConfig()
        )

        #expect(try #require(status.errorMessage).utf8.count <= 4_096)
        #expect(try store.load() == status)
    }

    @Test
    func fileStoreRoundTripsProtectedStatusAndRemovesIt() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let store = KubeProxyStatusFileStore(url: url)
        let recorder = KubeProxyStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID
        )
        let status = try recorder.record(
            result: KubeProxyRunResult(ruleSet: makeDualStackRuleSet(generation: 1), applied: true),
            config: makeDualStackConfig()
        )

        #expect(try store.load() == status)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test
    func fileStoreRejectsSymlinkAndWrongMode() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetURL = directory.appendingPathComponent("target.json")
        let symlinkURL = directory.appendingPathComponent("symlink-status.json")
        try Data("{}".utf8).write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: targetURL.path
        )
        let symlinkStore = KubeProxyStatusFileStore(url: symlinkURL)
        #expect(throws: KubeProxyStatusStoreError.self) {
            try symlinkStore.load()
        }

        let statusURL = directory.appendingPathComponent("status.json")
        let store = KubeProxyStatusFileStore(url: statusURL)
        let recorder = KubeProxyStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID
        )
        let status = try recorder.record(
            result: KubeProxyRunResult(ruleSet: makeDualStackRuleSet(generation: 1), applied: true),
            config: makeDualStackConfig()
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: statusURL.path)
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.load()
        }
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.save(status)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o4600], ofItemAtPath: statusURL.path)
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.load()
        }
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.save(status)
        }
    }

    @Test
    func fileStoreNeverRemovesForeignProtectedFile() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let foreignData = Data("not a kube-proxy status".utf8)
        try foreignData.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let store = KubeProxyStatusFileStore(url: url)
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.remove()
        }
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.save(try makeStatusInMemory())
        }
        #expect(try Data(contentsOf: url) == foreignData)
    }

    @Test
    func fileStoreRejectsUnsafeOrSymlinkedStatusDirectory() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = try makeStatusInMemory()

        let writableDirectory = directory.appendingPathComponent("writable")
        try FileManager.default.createDirectory(at: writableDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: writableDirectory.path
        )
        #expect(throws: KubeProxyStatusStoreError.self) {
            try KubeProxyStatusFileStore(
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
        #expect(throws: KubeProxyStatusStoreError.self) {
            try KubeProxyStatusFileStore(
                url: symlinkedDirectory.appendingPathComponent("status.json")
            ).save(status)
        }
    }

    @Test
    func fileStoreRejectsExtendedACLs() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let statusURL = directory.appendingPathComponent("status.json")
        let store = KubeProxyStatusFileStore(url: statusURL)
        let status = try makeStatusInMemory()
        try store.save(status)
        try addEveryoneReadACL(to: statusURL)
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.load()
        }
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.save(status)
        }

        let protectedDirectory = directory.appendingPathComponent("protected")
        try FileManager.default.createDirectory(
            at: protectedDirectory,
            withIntermediateDirectories: false
        )
        try addEveryoneReadACL(to: protectedDirectory)
        #expect(throws: KubeProxyStatusStoreError.self) {
            try KubeProxyStatusFileStore(
                url: protectedDirectory.appendingPathComponent("status.json")
            ).save(status)
        }
    }

    @Test
    func fileStoreRejectsOversizedStatus() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oversizedFileURL = directory.appendingPathComponent("oversized-load.json")
        try Data(count: 65 * 1_024).write(to: oversizedFileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: oversizedFileURL.path
        )
        #expect(throws: KubeProxyStatusStoreError.self) {
            try KubeProxyStatusFileStore(url: oversizedFileURL).load()
        }

        var oversizedStatus = try makeStatusInMemory()
        oversizedStatus.nodeName = String(repeating: "n", count: 65 * 1_024)
        #expect(throws: KubeProxyStatusStoreError.self) {
            try KubeProxyStatusFileStore(
                url: directory.appendingPathComponent("oversized-save.json")
            ).save(oversizedStatus)
        }
    }

    @Test
    func fileStoreRejectsFIFOWithoutBlocking() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        #expect(mkfifo(url.path, mode_t(0o600)) == 0)
        let store = KubeProxyStatusFileStore(url: url)

        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.load()
        }
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.remove()
        }
        #expect(throws: KubeProxyStatusStoreError.self) {
            try store.save(try makeStatusInMemory())
        }
    }

    @Test
    func statusPathIsOptionalForLegacyConfigAndMustBeSafeWhenSet() throws {
        let legacy = try JSONDecoder().decode(
            KubeProxyMacOSConfig.self,
            from: Data(#"{"kubeconfig":"/tmp/kubeconfig","nodeName":"node-a"}"#.utf8)
        )
        #expect(legacy.statusPath == nil)

        let explicit = KubeProxyMacOSConfig(
            kubeconfig: "/tmp/kubeconfig",
            nodeName: "node-a",
            statusPath: "/var/lib/container/kube-proxy-macos/status.json"
        )
        try explicit.validate()

        for path in ["relative/status.json", "/", "/tmp/../status.json", "/tmp/status\n.json"] {
            let invalid = KubeProxyMacOSConfig(
                kubeconfig: "/tmp/kubeconfig",
                nodeName: "node-a",
                statusPath: path
            )
            #expect(throws: KubeProxyMacOSError.self) {
                try invalid.validate()
            }
        }
    }

    @Test
    func runResultDecodesWithoutPendingFamily() throws {
        let result = try JSONDecoder().decode(
            KubeProxyRunResult.self,
            from: Data(
                #"{"ruleSet":{"generation":1,"rules":[],"issues":[]},"applied":true}"#.utf8
            )
        )

        #expect(result.applied)
        #expect(result.pendingFamily == nil)
    }

    private func makeDualStackRuleSet(generation: Int) -> KubeProxyRuleSet {
        KubeProxyRuleSet(
            generation: generation,
            rules: [
                KubeProxyServiceRule(
                    namespace: "default",
                    serviceName: "echo-v4",
                    protocolName: .tcp,
                    clusterIP: "10.96.0.42",
                    servicePort: 80,
                    backends: [KubeProxyBackend(ip: "10.250.34.2", port: 8080)]
                ),
                KubeProxyServiceRule(
                    namespace: "default",
                    serviceName: "echo-v6",
                    protocolName: .tcp,
                    family: .ipv6,
                    clusterIP: "fd42:10:96::42",
                    servicePort: 80,
                    backends: [
                        KubeProxyBackend(
                            family: .ipv6,
                            ip: "fd42:10:244:22::2",
                            port: 8080
                        )
                    ]
                ),
            ]
        )
    }

    private func makeDualStackConfig(nodeName: String = "node-a") -> KubeProxyMacOSConfig {
        KubeProxyMacOSConfig(
            kubeconfig: "/tmp/kubeconfig",
            nodeName: nodeName,
            dualStackEnabled: true,
            pf: KubeProxyPFConfig(
                runtimeStatePath: "/tmp/runtime.json",
                readyStatePath: "/tmp/ready.json"
            )
        )
    }

    private func makePrivateTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kube-proxy-status-tests-\(UUID().uuidString)")
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
            throw KubeProxyStatusStoreError.persistence(
                "failed to add an extended ACL to the test fixture at \(url.path)"
            )
        }
    }

    private func makeStatusInMemory() throws -> KubeProxyStatus {
        let store = InMemoryKubeProxyStatusStore()
        return try KubeProxyStatusRecorder(
            store: store,
            controllerInstanceID: controllerInstanceID
        ).record(
            result: KubeProxyRunResult(ruleSet: makeDualStackRuleSet(generation: 1), applied: true),
            config: makeDualStackConfig()
        )
    }

}

private final class InMemoryKubeProxyStatusStore: KubeProxyStatusStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KubeProxyStatus?

    func load() throws -> KubeProxyStatus? {
        lock.withLock { value }
    }

    func save(_ status: KubeProxyStatus) throws {
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

private final class SequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    func next() -> Date {
        lock.withLock {
            defer { offset += 1 }
            return Date(timeIntervalSince1970: 1_700_000_000 + offset)
        }
    }
}
