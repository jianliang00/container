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

#if os(macOS)
import ContainerCRIShimMacOS
import ContainerResource
import Darwin
import Foundation
import Testing

@testable import container_vmnet_recovery_macos

@Suite(.serialized)
struct VMNetRecoveryStatusTests {
    private let coordinatorInstanceID = "8C049DCB-30EE-4B15-BE4B-A26144195B9D"
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func recordsRecoveryLifecycleWithStablePhaseTimesAndDeduplicatedCounters() throws {
        let context = try makeRecorderContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        _ = try context.stateStore.recordHealthyObservation(
            networkName: context.networkName,
            networkInstanceID: "instance-a",
            bootSessionID: "boot-a",
            now: baseDate.addingTimeInterval(-10)
        )
        let clock = VMNetRecoveryStatusClock(baseDate)
        let recorder = VMNetRecoveryStatusRecorder(
            store: context.statusStore,
            coordinatorInstanceID: coordinatorInstanceID,
            now: { clock.now() }
        )

        let healthy = try recorder.record(
            event: .result(.idle),
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(healthy.state == .ready)
        #expect(healthy.phase == .healthy)
        #expect(healthy.authorityPhase == .healthy)
        #expect(healthy.networkInstanceID == "instance-a")
        #expect(!healthy.sandboxAdmissionRejecting)
        #expect(healthy.sandboxRejectedTotal == nil)
        #expect(try healthy.freshness(at: baseDate.addingTimeInterval(14)) == .fresh)
        #expect(try healthy.freshness(at: baseDate.addingTimeInterval(15)) == .expired)

        clock.advance()
        let healthyHeartbeat = try recorder.record(
            event: .result(.idle),
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(healthyHeartbeat.phaseSince == healthy.phaseSince)

        clock.advance()
        let probeDegraded = try recorder.record(
            event: .result(.waitingForHealthyProbe(attempt: 1, reason: "helper status unavailable")),
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(probeDegraded.state == .degraded)
        #expect(probeDegraded.phase == .probeDegraded)
        #expect(probeDegraded.authorityPhase == .healthy)
        #expect(!probeDegraded.sandboxAdmissionRejecting)
        #expect(probeDegraded.consecutiveHealthyProbeFailures == 1)
        #expect(probeDegraded.phaseSince != healthy.phaseSince)
        #expect(probeDegraded.sandboxRejectedTotal == nil)

        clock.advance()
        let repeatedProbe = try recorder.record(
            event: .result(.waitingForHealthyProbe(attempt: 2, reason: "helper status unavailable")),
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(repeatedProbe.phaseSince == probeDegraded.phaseSince)
        #expect(repeatedProbe.consecutiveHealthyProbeFailures == 2)

        clock.advance()
        _ = try context.stateStore.recordFence(
            networkName: context.networkName,
            networkInstanceID: "instance-a",
            failureReason: "helper disconnected",
            bootSessionID: "boot-a",
            attemptWindow: 3_600,
            now: clock.now()
        )
        let fenced = try recorder.record(
            event: .fenced,
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(fenced.state == .degraded)
        #expect(fenced.phase == .fenced)
        #expect(fenced.authorityPhase == .fenced)
        #expect(fenced.fenceActive)
        #expect(fenced.sandboxAdmissionRejecting)
        #expect(fenced.counters.fencesObserved == 1)

        clock.advance()
        let repeatedFence = try recorder.record(
            event: .fenced,
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(repeatedFence.phaseSince == fenced.phaseSince)
        #expect(repeatedFence.counters.fencesObserved == 1)

        let restartedRecorder = VMNetRecoveryStatusRecorder(
            store: context.statusStore,
            coordinatorInstanceID: "00000000-0000-4000-8000-000000000002",
            now: { clock.now() }
        )
        _ = try restartedRecorder.record(
            event: .starting,
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        let fenceAfterRestart = try restartedRecorder.record(
            event: .fenced,
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(fenceAfterRestart.counters.fencesObserved == 1)

        clock.advance()
        _ = try context.stateStore.requestReboot(
            networkName: context.networkName,
            currentBootSessionID: "boot-a",
            maxAttempts: 2,
            minimumInterval: 0,
            maximumRequestAge: 900,
            now: clock.now()
        )
        let rebootRequested = try recorder.record(
            event: .rebootCommandRequested,
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(rebootRequested.phase == .rebootRequested)
        #expect(rebootRequested.authorityPhase == .rebootRequested)
        #expect(rebootRequested.rebootAttempts == 1)
        #expect(rebootRequested.rebootCommandResult == .requested)

        clock.advance()
        let rebootAccepted = try recorder.record(
            event: .rebootCommandAccepted,
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(rebootAccepted.rebootCommandResult == .accepted)
        #expect(rebootAccepted.counters.rebootCommandsAccepted == 1)

        clock.advance()
        let repeatedAcceptance = try recorder.record(
            event: .rebootCommandAccepted,
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(repeatedAcceptance.counters.rebootCommandsAccepted == 1)

        clock.advance()
        let budgetBlocked = try recorder.record(
            event: .result(.blocked("vmnet recovery reboot attempt budget is exhausted")),
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(budgetBlocked.state == .failed)
        #expect(budgetBlocked.phase == .blocked)
        #expect(budgetBlocked.loopProtectionBlocked)
        #expect(budgetBlocked.counters.loopProtectionBlocks == 1)

        clock.advance()
        let repeatedBudgetBlock = try recorder.record(
            event: .result(.blocked("vmnet recovery reboot attempt budget is exhausted")),
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(repeatedBudgetBlock.phaseSince == budgetBlocked.phaseSince)
        #expect(repeatedBudgetBlock.counters.loopProtectionBlocks == 1)

        clock.advance()
        _ = try context.stateStore.beginVerification(
            networkName: context.networkName,
            currentBootSessionID: "boot-b",
            now: clock.now()
        )
        let verifying = try recorder.record(
            event: .verificationStarted,
            config: context.config,
            currentBootSessionID: "boot-b"
        )
        #expect(verifying.phase == .verifying)
        #expect(verifying.authorityPhase == .verifying)
        #expect(verifying.currentBootSessionID == "boot-b")
        #expect(verifying.stateBootSessionID == "boot-a")
        #expect(verifying.counters.rebootsObserved == 1)

        clock.advance()
        let repeatedVerification = try recorder.record(
            event: .verificationStarted,
            config: context.config,
            currentBootSessionID: "boot-b"
        )
        #expect(repeatedVerification.counters.rebootsObserved == 1)

        clock.advance()
        _ = try context.stateStore.completeVerification(
            networkName: context.networkName,
            networkInstanceID: "instance-b",
            currentBootSessionID: "boot-b",
            now: clock.now()
        )
        let recovered = try recorder.record(
            event: .recovered,
            config: context.config,
            currentBootSessionID: "boot-b"
        )
        #expect(recovered.state == .ready)
        #expect(recovered.phase == .healthy)
        #expect(recovered.authorityPhase == .healthy)
        #expect(recovered.networkInstanceID == "instance-b")
        #expect(recovered.currentBootSessionID == "boot-b")
        #expect(recovered.stateBootSessionID == "boot-b")
        #expect(!recovered.fenceActive)
        #expect(!recovered.sandboxAdmissionRejecting)
        #expect(recovered.counters.recoveriesSucceeded == 1)
        #expect(recovered.sandboxRejectedTotal == nil)

        clock.advance()
        let repeatedRecovery = try recorder.record(
            event: .result(.recovered(networkInstanceID: "instance-b")),
            config: context.config,
            currentBootSessionID: "boot-b"
        )
        #expect(repeatedRecovery.counters.fencesObserved == 1)
        #expect(repeatedRecovery.counters.rebootCommandsAccepted == 1)
        #expect(repeatedRecovery.counters.rebootsObserved == 1)
        #expect(repeatedRecovery.counters.recoveriesSucceeded == 1)
        #expect(repeatedRecovery.counters.loopProtectionBlocks == 1)
    }

    @Test
    func aggregatesAdmissionRejectionsAcrossStatusRecorderRestartsAndResetsPerBoot() throws {
        let context = try makeRecorderContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        _ = try context.stateStore.recordHealthyObservation(
            networkName: context.networkName,
            networkInstanceID: "instance-a",
            bootSessionID: "boot-a",
            now: baseDate
        )
        let telemetryPaths = VMNetRecoveryAdmissionTelemetryPaths(
            directoryURL: context.root.appendingPathComponent("telemetry", isDirectory: true)
        )
        let journal = VMNetRecoveryAdmissionRejectionJournal(
            paths: telemetryPaths,
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid(),
            now: { self.baseDate }
        )
        let counter = VMNetRecoveryAdmissionRejectionCounter(
            paths: telemetryPaths,
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid()
        )
        try journal.record(
            attemptID: UUID(),
            bootSessionID: "boot-a",
            gate: .beforeSandboxCreate,
            reason: .stateFenced
        )
        try journal.record(
            attemptID: UUID(),
            bootSessionID: "boot-a",
            gate: .beforeNetworkAttach,
            reason: .stateFenced
        )

        let recorder = VMNetRecoveryStatusRecorder(
            store: context.statusStore,
            admissionRejectionCounter: counter,
            coordinatorInstanceID: coordinatorInstanceID,
            now: { self.baseDate }
        )
        let first = try recorder.record(
            event: .result(.idle),
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(first.sandboxRejectedTotal == 2)

        try journal.record(
            attemptID: UUID(),
            bootSessionID: "boot-a",
            gate: .beforeRequestValidation,
            reason: .requestPending
        )
        let restartedRecorder = VMNetRecoveryStatusRecorder(
            store: context.statusStore,
            admissionRejectionCounter: counter,
            coordinatorInstanceID: "00000000-0000-4000-8000-000000000003",
            now: { self.baseDate.addingTimeInterval(1) }
        )
        let afterRestart = try restartedRecorder.record(
            event: .result(.idle),
            config: context.config,
            currentBootSessionID: "boot-a"
        )
        #expect(afterRestart.sandboxRejectedTotal == 3)

        try journal.record(
            attemptID: UUID(),
            bootSessionID: "boot-b",
            gate: .beforeRequestValidation,
            reason: .bootMismatch
        )
        let nextBoot = try restartedRecorder.record(
            event: .verificationStarted,
            config: context.config,
            currentBootSessionID: "boot-b"
        )
        #expect(nextBoot.sandboxRejectedTotal == 1)
    }

    @Test
    func unknownAdmissionCounterDoesNotBlockStatusPersistence() throws {
        let context = try makeRecorderContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        _ = try context.stateStore.recordHealthyObservation(
            networkName: context.networkName,
            networkInstanceID: "instance-a",
            bootSessionID: "boot-a",
            now: baseDate
        )
        let telemetryPaths = VMNetRecoveryAdmissionTelemetryPaths(
            directoryURL: context.root.appendingPathComponent("telemetry", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: telemetryPaths.directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let recorder = VMNetRecoveryStatusRecorder(
            store: context.statusStore,
            admissionRejectionCounter: VMNetRecoveryAdmissionRejectionCounter(
                paths: telemetryPaths,
                requiredOwnerID: geteuid(),
                requiredGroupID: getegid()
            ),
            coordinatorInstanceID: coordinatorInstanceID,
            now: { self.baseDate }
        )

        let status = try recorder.record(
            event: .result(.idle),
            config: context.config,
            currentBootSessionID: "boot-a"
        )

        #expect(status.sandboxRejectedTotal == nil)
        #expect(try context.statusStore.load() == status)
    }

    @Test
    func statusValidationRejectsInvalidSchemaTimelineAndReadyAuthority() throws {
        var status = makeReadyStatus()
        status.schemaVersion += 1
        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try status.validated()
        }

        status = makeReadyStatus()
        status.expiresAt = status.updatedAt
        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try status.validated()
        }

        status = makeReadyStatus()
        status.stateBootSessionID = "boot-old"
        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try status.validated()
        }

        status = makeReadyStatus()
        status.errorCode = "invalid code"
        status.errorMessage = "invalid"
        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try status.validated()
        }
    }

    @Test
    func freshnessScalesWithPollIntervalAndCapsAtThreeDays() throws {
        let context = try makeRecorderContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        _ = try context.stateStore.recordHealthyObservation(
            networkName: context.networkName,
            networkInstanceID: "instance-a",
            bootSessionID: "boot-a",
            now: baseDate
        )
        let clock = VMNetRecoveryStatusClock(baseDate)
        let recorder = VMNetRecoveryStatusRecorder(
            store: context.statusStore,
            coordinatorInstanceID: coordinatorInstanceID,
            now: { clock.now() }
        )
        var config = context.config
        config.podNetwork?.vmnetRecovery?.pollIntervalSeconds = 10

        let fortySecondLease = try recorder.record(
            event: .result(.idle),
            config: config,
            currentBootSessionID: "boot-a"
        )
        #expect(try fortySecondLease.freshness(at: baseDate.addingTimeInterval(39)) == .fresh)
        #expect(try fortySecondLease.freshness(at: baseDate.addingTimeInterval(40)) == .expired)

        config.podNetwork?.vmnetRecovery?.pollIntervalSeconds = .max
        let cappedLease = try recorder.record(
            event: .result(.idle),
            config: config,
            currentBootSessionID: "boot-a"
        )
        #expect(try cappedLease.freshness(at: baseDate.addingTimeInterval(259_199)) == .fresh)
        #expect(try cappedLease.freshness(at: baseDate.addingTimeInterval(259_200)) == .expired)
    }

    @Test
    func fileStoreRoundTripsModeAndNoExtendedACL() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let store = VMNetRecoveryStatusFileStore(url: url)
        let status = makeReadyStatus()

        try store.save(status)

        #expect(try store.load() == status)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object.keys.contains("sandboxRejectedTotal"))
        #expect(object["sandboxRejectedTotal"] is NSNull)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
        #expect((attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value == getegid())
        #expect(try !hasExtendedACL(at: url))
    }

    @Test
    func fileStoreAcceptsReadOnlyInheritedDirectoryACLAndStripsItFromStatus() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("readable-parent")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try addACL(
            "everyone allow read,readattr,readextattr,readsecurity,file_inherit,only_inherit",
            to: directory
        )
        let url = directory.appendingPathComponent("status.json")
        let store = VMNetRecoveryStatusFileStore(url: url)
        let status = makeReadyStatus()

        try store.save(status)

        #expect(try store.load() == status)
        #expect(try hasExtendedACL(at: directory))
        #expect(try !hasExtendedACL(at: url))
    }

    @Test
    func fileStoreRejectsDirectoryACLThatGrantsMutation() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("writable-parent")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try addACL("everyone allow add_file", to: directory)
        let url = directory.appendingPathComponent("status.json")

        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try VMNetRecoveryStatusFileStore(url: url).save(makeReadyStatus())
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func fileStoreRejectsSymlinkFIFOAndWrongModeWithoutFollowingOrBlocking() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = makeReadyStatus()

        let targetURL = directory.appendingPathComponent("target.json")
        let targetData = Data("target must remain unchanged".utf8)
        try targetData.write(to: targetURL)
        try protectFixture(targetURL)
        let symlinkURL = directory.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: targetURL.path
        )
        let symlinkStore = VMNetRecoveryStatusFileStore(url: symlinkURL)
        expectUnsafeFileRejected(store: symlinkStore, replacement: status)
        #expect(try Data(contentsOf: targetURL) == targetData)

        let fifoURL = directory.appendingPathComponent("fifo.json")
        #expect(mkfifo(fifoURL.path, mode_t(0o600)) == 0)
        expectUnsafeFileRejected(
            store: VMNetRecoveryStatusFileStore(url: fifoURL),
            replacement: status
        )

        let wrongModeURL = directory.appendingPathComponent("wrong-mode.json")
        let wrongModeStore = VMNetRecoveryStatusFileStore(url: wrongModeURL)
        try wrongModeStore.save(status)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: wrongModeURL.path
        )
        expectUnsafeFileRejected(store: wrongModeStore, replacement: status)
    }

    @Test
    func fileStoreRejectsExtendedFileACL() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let store = VMNetRecoveryStatusFileStore(url: url)
        let status = makeReadyStatus()
        try store.save(status)
        try addACL("everyone allow read", to: url)

        expectUnsafeFileRejected(store: store, replacement: status)
    }

    @Test
    func fileStoreCanReplaceAndRemoveCorruptOrOversizedMetadataSafeFiles() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = makeReadyStatus()

        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let corruptStore = VMNetRecoveryStatusFileStore(url: corruptURL)
        try Data("not a recovery status".utf8).write(to: corruptURL)
        try protectFixture(corruptURL)
        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try corruptStore.load()
        }
        try corruptStore.save(status)
        #expect(try corruptStore.load() == status)
        try Data("still not a recovery status".utf8).write(to: corruptURL)
        try protectFixture(corruptURL)
        try corruptStore.remove()
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))

        let oversizedURL = directory.appendingPathComponent("oversized.json")
        let oversizedStore = VMNetRecoveryStatusFileStore(url: oversizedURL)
        try Data(count: 65 * 1_024).write(to: oversizedURL)
        try protectFixture(oversizedURL)
        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try oversizedStore.load()
        }
        try oversizedStore.save(status)
        #expect(try oversizedStore.load() == status)
        try Data(count: 65 * 1_024).write(to: oversizedURL)
        try protectFixture(oversizedURL)
        try oversizedStore.remove()
        #expect(!FileManager.default.fileExists(atPath: oversizedURL.path))
    }

    private func makeRecorderContext() throws -> VMNetRecoveryStatusTestContext {
        let root = try makePrivateTemporaryDirectory()
        let statePath = root.appendingPathComponent("state.json").path
        let requestPath = root.appendingPathComponent("requests/fence.json").path
        let statusStore = InMemoryVMNetRecoveryStatusStore()
        let networkName = "kubernetes-pod"
        let config = CRIShimConfig(
            podNetwork: PodNetworkConfig(
                enabled: true,
                dualStackEnabled: true,
                vmnetDisconnectRecovery: .rebootNode,
                networkName: networkName,
                runtimeStatePath: root.appendingPathComponent("runtime.json").path,
                readyStatePath: root.appendingPathComponent("ready.json").path,
                vmnetRecovery: VMNetRecoveryConfig(
                    nodeName: "node-a",
                    statePath: statePath,
                    requestPath: requestPath,
                    statusPath: root.appendingPathComponent("status.json").path,
                    requestWriterUID: Int(geteuid()),
                    maxRebootAttempts: 2,
                    minimumRebootIntervalSeconds: 0,
                    attemptWindowSeconds: 3_600,
                    maximumRequestAgeSeconds: 900,
                    verificationTimeoutSeconds: 300,
                    pollIntervalSeconds: 2,
                    healthyProbeFailureThreshold: 3
                )
            )
        )
        return VMNetRecoveryStatusTestContext(
            root: root,
            networkName: networkName,
            config: config,
            stateStore: VMNetRecoveryStateStore(path: statePath),
            statusStore: statusStore
        )
    }

    private func makeReadyStatus() -> VMNetRecoveryStatus {
        let timestamp = statusTimestamp(baseDate)
        return VMNetRecoveryStatus(
            nodeName: "node-a",
            networkName: "kubernetes-pod",
            coordinatorInstanceID: coordinatorInstanceID,
            updatedAt: timestamp,
            expiresAt: statusTimestamp(baseDate.addingTimeInterval(15)),
            phaseSince: timestamp,
            lastSuccessAt: timestamp,
            state: .ready,
            phase: .healthy,
            authorityPhase: .healthy,
            networkInstanceID: "instance-a",
            currentBootSessionID: "boot-a",
            stateBootSessionID: "boot-a",
            authorityUpdatedAt: timestamp,
            recoveryWindowStartedAt: timestamp,
            requestPending: false,
            sandboxAdmissionRejecting: false,
            sandboxRejectedTotal: nil,
            fenceActive: false,
            failureReason: nil,
            rebootAttempts: 0,
            maxRebootAttempts: 2,
            lastRebootRequestedAt: nil,
            rebootCommandResult: nil,
            consecutiveHealthyProbeFailures: 0,
            healthyProbeFailureThreshold: 3,
            loopProtectionBlocked: false,
            counters: .zero,
            errorCode: nil,
            errorMessage: nil
        )
    }

    private func statusTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makePrivateTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmnet-recovery-status-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func protectFixture(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func expectUnsafeFileRejected(
        store: VMNetRecoveryStatusFileStore,
        replacement: VMNetRecoveryStatus
    ) {
        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try store.load()
        }
        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try store.save(replacement)
        }
        #expect(throws: VMNetRecoveryStatusStoreError.self) {
            try store.remove()
        }
    }

    private func addACL(_ entry: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", entry, url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VMNetRecoveryStatusTestError.fixture(
                "failed to add ACL to \(url.path): \(String(decoding: data, as: UTF8.self))"
            )
        }
    }

    private func hasExtendedACL(at url: URL) throws -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw VMNetRecoveryStatusTestError.fixture(
                "failed to open ACL fixture at \(url.path): errno \(errno)"
            )
        }
        defer { close(descriptor) }

        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return false
            }
            throw VMNetRecoveryStatusTestError.fixture(
                "failed to inspect ACL fixture at \(url.path): errno \(errno)"
            )
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }
}

private struct VMNetRecoveryStatusTestContext {
    let root: URL
    let networkName: String
    let config: CRIShimConfig
    let stateStore: VMNetRecoveryStateStore
    let statusStore: InMemoryVMNetRecoveryStatusStore
}

private enum VMNetRecoveryStatusTestError: Error {
    case fixture(String)
}

private final class InMemoryVMNetRecoveryStatusStore: VMNetRecoveryStatusStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: VMNetRecoveryStatus?

    func load() throws -> VMNetRecoveryStatus? {
        lock.withLock { value }
    }

    func save(_ status: VMNetRecoveryStatus) throws {
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

private final class VMNetRecoveryStatusClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval = 1) {
        lock.withLock {
            value = value.addingTimeInterval(interval)
        }
    }
}
#endif
