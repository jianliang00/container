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

@testable import ContainerCRIShimMacOS

struct VMNetRecoveryAdmissionTelemetryTests {
    @Test
    func eventContainsOnlyBoundedNonPodFields() throws {
        try withTelemetryContext { context in
            let attemptID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
            try context.journal.record(
                attemptID: attemptID,
                bootSessionID: "boot-a",
                gate: .beforeNetworkAttach,
                reason: .stateFenced
            )

            let data = try Data(contentsOf: context.paths.journalURL)
            let line = try #require(data.split(separator: 0x0A).first)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            )
            #expect(
                Set(object.keys)
                    == Set([
                        "schemaVersion", "attemptID", "observedAt", "bootSessionID", "gate", "reason",
                    ])
            )
            #expect(object["attemptID"] as? String == attemptID.uuidString)
            #expect(object["bootSessionID"] as? String == "boot-a")
            #expect(object["gate"] as? String == "beforeNetworkAttach")
            #expect(object["reason"] as? String == "stateFenced")
            let serialized = String(decoding: line, as: UTF8.self)
            #expect(!serialized.contains("pod"))
            #expect(!serialized.contains("namespace"))
            #expect(!serialized.contains("image"))
            #expect(!serialized.contains("sandboxID"))
        }
    }

    @Test
    func incrementalConsumptionPersistsAndDoesNotDoubleCount() throws {
        try withTelemetryContext { context in
            #expect(
                context.counter.consume(currentBootSessionID: "boot-a")
                    == VMNetRecoveryAdmissionRejectionCountResult(
                        total: 0,
                        known: true,
                        gapDetected: false
                    )
            )

            try context.record(count: 3, bootSessionID: "boot-a")
            #expect(context.counter.consume(currentBootSessionID: "boot-a").total == 3)
            #expect(try fileSize(context.paths.journalURL) == 0)
            #expect(context.counter.consume(currentBootSessionID: "boot-a").total == 3)

            try context.record(count: 2, bootSessionID: "boot-a")
            let restartedCounter = context.makeCounter()
            let result = restartedCounter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == 5)
            #expect(result.known)
            #expect(!result.gapDetected)
        }
    }

    @Test
    func firstEventBeforeConsumerInitializesCursorAndRemainsKnown() throws {
        try withTelemetryContext { context in
            try context.record(count: 1, bootSessionID: "boot-a")
            #expect(FileManager.default.fileExists(atPath: context.paths.cursorURL.path))

            let result = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == 1)
            #expect(result.known)
            #expect(!result.gapDetected)
        }
    }

    @Test
    func existingEmptyDirectoryBeforeLockAcquisitionInitializesWithoutGap() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = telemetryContext(root: root)
        try FileManager.default.createDirectory(
            at: context.paths.directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(context.paths.directoryURL.path, mode_t(0o700)) == 0 else {
            throw TelemetryTestError.posix("chmod pre-created telemetry directory")
        }

        let result = context.counter.consume(currentBootSessionID: "boot-a")
        #expect(result.total == 0)
        #expect(result.known)
        #expect(!result.gapDetected)
        #expect(FileManager.default.fileExists(atPath: context.paths.cursorURL.path))
    }

    @Test
    func writerInitializesAfterAnotherProcessCreatesDirectory() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = telemetryContext(root: root)
        try FileManager.default.createDirectory(
            at: context.paths.directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(context.paths.directoryURL.path, mode_t(0o700)) == 0 else {
            throw TelemetryTestError.posix("chmod pre-created telemetry directory")
        }

        try context.record(count: 1, bootSessionID: "boot-a")
        let result = context.counter.consume(currentBootSessionID: "boot-a")
        #expect(result.total == 1)
        #expect(result.known)
        #expect(!result.gapDetected)
    }

    @Test
    func preexistingEmptyJournalWithoutCursorCreatesStickyGap() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = telemetryContext(root: root)
        try FileManager.default.createDirectory(
            at: context.paths.directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(context.paths.directoryURL.path, mode_t(0o700)) == 0 else {
            throw TelemetryTestError.posix("chmod pre-created telemetry directory")
        }
        #expect(
            FileManager.default.createFile(
                atPath: context.paths.journalURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        )
        guard chmod(context.paths.journalURL.path, mode_t(0o600)) == 0 else {
            throw TelemetryTestError.posix("chmod pre-created journal")
        }

        let result = context.counter.consume(currentBootSessionID: "boot-a")
        #expect(result.total == nil)
        #expect(!result.known)
        #expect(result.gapDetected)
    }

    @Test
    func concurrentAppendProducesCompleteDistinctRecords() async throws {
        try await withTelemetryContext { context in
            let count = 128
            #expect(context.counter.consume(currentBootSessionID: "boot-a").known)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        try context.journal.record(
                            attemptID: UUID(),
                            bootSessionID: "boot-a",
                            gate: .beforeRequestValidation,
                            reason: .stateMissing
                        )
                    }
                }
                try await group.waitForAll()
            }

            let data = try Data(contentsOf: context.paths.journalURL)
            let lines = data.split(separator: 0x0A)
            #expect(lines.count == count)
            var attemptIDs: Set<String> = []
            for line in lines {
                let object = try #require(
                    JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                )
                attemptIDs.insert(try #require(object["attemptID"] as? String))
            }
            #expect(attemptIDs.count == count)

            let result = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == UInt64(count))
            #expect(result.known)
            #expect(!result.gapDetected)
        }
    }

    @Test
    func busyJournalLockMakesCounterUnknownWithoutWaitingOrMutatingFiles() throws {
        try withTelemetryContext { context in
            #expect(context.counter.consume(currentBootSessionID: "boot-a").known)
            try context.record(count: 1, bootSessionID: "boot-a")
            let journalBefore = try Data(contentsOf: context.paths.journalURL)
            let cursorBefore = try Data(contentsOf: context.paths.cursorURL)

            let lockDescriptor = open(
                context.paths.lockURL.path,
                O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard lockDescriptor >= 0 else {
                throw TelemetryTestError.posix("open lock fixture")
            }
            defer { close(lockDescriptor) }
            guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw TelemetryTestError.posix("acquire lock fixture")
            }
            defer { _ = flock(lockDescriptor, LOCK_UN) }

            let startedAt = Date()
            let result = context.counter.consume(currentBootSessionID: "boot-a")
            let elapsed = Date().timeIntervalSince(startedAt)

            #expect(result.total == nil)
            #expect(!result.known)
            #expect(!result.gapDetected)
            #expect(elapsed < 0.5)
            #expect(try Data(contentsOf: context.paths.journalURL) == journalBefore)
            #expect(try Data(contentsOf: context.paths.cursorURL) == cursorBefore)
        }
    }

    @Test
    func sameInodeTruncationAfterDurableCursorRecoversWithoutGap() throws {
        try withTelemetryContext { context in
            try context.record(count: 3, bootSessionID: "boot-a")
            let information = try statInformation(context.paths.journalURL)
            let committedOffset = UInt64(information.st_size)
            try writeCursor(
                VMNetRecoveryAdmissionRejectionCursorV1(
                    bootSessionID: "boot-a",
                    journalDeviceID: deviceID(information),
                    journalFileID: UInt64(information.st_ino),
                    journalOffset: committedOffset,
                    rejectedTotal: 3,
                    gapDetected: false
                ),
                to: context.paths.cursorURL
            )
            guard truncate(context.paths.journalURL.path, 0) == 0 else {
                throw TelemetryTestError.posix("truncate journal")
            }
            let afterTruncate = try statInformation(context.paths.journalURL)
            #expect(afterTruncate.st_ino == information.st_ino)

            try context.record(count: 1, bootSessionID: "boot-a")
            let result = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == 4)
            #expect(result.known)
            #expect(!result.gapDetected)
        }
    }

    @Test
    func crashAfterJournalRotationBeforeNewCursorCreatesStickyGap() throws {
        try withTelemetryContext { context in
            try context.record(count: 3, bootSessionID: "boot-a")
            let original = try statInformation(context.paths.journalURL)
            try writeCursor(
                VMNetRecoveryAdmissionRejectionCursorV1(
                    bootSessionID: "boot-a",
                    journalDeviceID: deviceID(original),
                    journalFileID: UInt64(original.st_ino),
                    journalOffset: UInt64(original.st_size),
                    rejectedTotal: 3,
                    gapDetected: false
                ),
                to: context.paths.cursorURL
            )

            let replacementURL = context.paths.directoryURL
                .appendingPathComponent("journal-rotation-crash-fixture")
            #expect(
                FileManager.default.createFile(
                    atPath: replacementURL.path,
                    contents: Data()
                )
            )
            guard chmod(replacementURL.path, mode_t(0o600)) == 0 else {
                throw TelemetryTestError.posix("chmod replacement journal")
            }
            let replacementHandle = try FileHandle(forWritingTo: replacementURL)
            try replacementHandle.synchronize()
            try replacementHandle.close()
            guard rename(replacementURL.path, context.paths.journalURL.path) == 0 else {
                throw TelemetryTestError.posix("replace journal")
            }
            let replacement = try statInformation(context.paths.journalURL)
            #expect(replacement.st_ino != original.st_ino)
            #expect(replacement.st_size == 0)

            let result = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == nil)
            #expect(!result.known)
            #expect(result.gapDetected)
        }
    }

    @Test
    func journalInodeReplacementCreatesStickyGap() throws {
        try withTelemetryContext { context in
            #expect(context.counter.consume(currentBootSessionID: "boot-a").known)
            try context.record(count: 1, bootSessionID: "boot-a")
            #expect(context.counter.consume(currentBootSessionID: "boot-a").total == 1)
            let original = try statInformation(context.paths.journalURL)

            try FileManager.default.removeItem(at: context.paths.journalURL)
            try context.record(count: 1, bootSessionID: "boot-a")
            let replacement = try statInformation(context.paths.journalURL)
            #expect(original.st_ino != replacement.st_ino)

            let first = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(first.total == nil)
            #expect(!first.known)
            #expect(first.gapDetected)

            try context.record(count: 1, bootSessionID: "boot-a")
            let second = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(second.total == nil)
            #expect(!second.known)
            #expect(second.gapDetected)
        }
    }

    @Test
    func missingCursorWithNonemptyJournalCreatesStickyGap() throws {
        try withTelemetryContext { context in
            try context.record(count: 1, bootSessionID: "boot-a")
            try FileManager.default.removeItem(at: context.paths.cursorURL)
            #expect(!FileManager.default.fileExists(atPath: context.paths.cursorURL.path))

            let first = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(first.total == nil)
            #expect(!first.known)
            #expect(first.gapDetected)

            try context.record(count: 1, bootSessionID: "boot-a")
            let second = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(second.total == nil)
            #expect(!second.known)
            #expect(second.gapDetected)
        }
    }

    @Test
    func missingCursorAfterCompactionCreatesStickyGap() throws {
        try withTelemetryContext { context in
            try context.record(count: 3, bootSessionID: "boot-a")
            #expect(context.counter.consume(currentBootSessionID: "boot-a").total == 3)
            #expect(try fileSize(context.paths.journalURL) == 0)
            try FileManager.default.removeItem(at: context.paths.cursorURL)

            let result = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == nil)
            #expect(!result.known)
            #expect(result.gapDetected)
        }
    }

    @Test
    func deletingProtectedTelemetryDirectoryStartsNewLifecycle() throws {
        try withTelemetryContext { context in
            try context.record(count: 2, bootSessionID: "boot-a")
            #expect(context.counter.consume(currentBootSessionID: "boot-a").total == 2)

            try FileManager.default.removeItem(at: context.paths.directoryURL)
            let result = context.makeCounter().consume(currentBootSessionID: "boot-a")
            #expect(result.total == 0)
            #expect(result.known)
            #expect(!result.gapDetected)
        }
    }

    @Test
    func capacityOverflowCreatesStickyGapBeforeLaterAppendsAreRejected() throws {
        try withTelemetryContext { context in
            #expect(context.counter.consume(currentBootSessionID: "boot-a").known)
            let event = VMNetRecoveryAdmissionRejectionEventV1(
                attemptID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                observedAt: fixtureDate,
                bootSessionID: "boot-a",
                gate: .beforeSandboxCreate,
                reason: .stateFenced
            )
            try appendRaw(
                Data(
                    repeating: 0x78,
                    count: VMNetRecoveryAdmissionRejectionJournal.maximumJournalSize
                ),
                to: context.paths.journalURL
            )

            try context.journal.append(event)
            #expect(
                try fileSize(context.paths.journalURL)
                    > Int64(VMNetRecoveryAdmissionRejectionJournal.maximumJournalSize)
            )
            #expect(throws: VMNetRecoveryAdmissionTelemetryError.journalCapacityExceeded) {
                try context.journal.append(event)
            }

            let first = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(first.total == nil)
            #expect(!first.known)
            #expect(first.gapDetected)
            #expect(try fileSize(context.paths.journalURL) == 0)

            try context.journal.append(event)
            let second = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(second.total == nil)
            #expect(!second.known)
            #expect(second.gapDetected)
        }
    }

    @Test
    func partialRecordCreatesStickyGap() throws {
        try withTelemetryContext { context in
            _ = context.counter.consume(currentBootSessionID: "boot-a")
            try appendRaw(Data(#"{"schemaVersion":1"#.utf8), to: context.paths.journalURL)

            let first = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(first.total == nil)
            #expect(first.gapDetected)
            #expect(try fileSize(context.paths.journalURL) == 0)

            try context.record(count: 1, bootSessionID: "boot-a")
            let second = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(second.total == nil)
            #expect(second.gapDetected)
        }
    }

    @Test
    func oversizedJournalCreatesStickyGapAndIsCompacted() throws {
        try withTelemetryContext { context in
            _ = context.counter.consume(currentBootSessionID: "boot-a")
            let oversized = Data(
                repeating: 0x78,
                count: VMNetRecoveryAdmissionRejectionJournal.maximumJournalSize + 1
            )
            try appendRaw(oversized, to: context.paths.journalURL)

            let result = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == nil)
            #expect(!result.known)
            #expect(result.gapDetected)
            #expect(try fileSize(context.paths.journalURL) == 0)
        }
    }

    @Test
    func badEventSchemaCreatesStickyGap() throws {
        try withTelemetryContext { context in
            _ = context.counter.consume(currentBootSessionID: "boot-a")
            let badSchema = Data(
                """
                {"attemptID":"00000000-0000-4000-8000-000000000001","bootSessionID":"boot-a","gate":"beforeSandboxCreate","observedAt":"2026-08-25T00:00:00Z","reason":"stateFenced","schemaVersion":2}

                """.utf8
            )
            try appendRaw(badSchema, to: context.paths.journalURL)

            let result = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == nil)
            #expect(result.gapDetected)
        }
    }

    @Test
    func counterOverflowCreatesStickyGap() throws {
        try withTelemetryContext { context in
            _ = context.counter.consume(currentBootSessionID: "boot-a")
            let information = try statInformation(context.paths.journalURL)
            try writeCursor(
                VMNetRecoveryAdmissionRejectionCursorV1(
                    bootSessionID: "boot-a",
                    journalDeviceID: deviceID(information),
                    journalFileID: UInt64(information.st_ino),
                    journalOffset: 0,
                    rejectedTotal: UInt64.max,
                    gapDetected: false
                ),
                to: context.paths.cursorURL
            )
            try context.record(count: 1, bootSessionID: "boot-a")

            let result = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == nil)
            #expect(!result.known)
            #expect(result.gapDetected)
        }
    }

    @Test
    func newBootResetsPriorStickyGapAndCountsOnlyCurrentBoot() throws {
        try withTelemetryContext { context in
            _ = context.counter.consume(currentBootSessionID: "boot-a")
            try appendRaw(Data("partial".utf8), to: context.paths.journalURL)
            #expect(context.counter.consume(currentBootSessionID: "boot-a").gapDetected)

            try context.record(count: 2, bootSessionID: "boot-b")
            let result = context.counter.consume(currentBootSessionID: "boot-b")
            #expect(result.total == 2)
            #expect(result.known)
            #expect(!result.gapDetected)
        }
    }

    @Test
    func mismatchedBootEventInsideEstablishedBootCreatesGap() throws {
        try withTelemetryContext { context in
            #expect(context.counter.consume(currentBootSessionID: "boot-a").known)
            try context.record(count: 1, bootSessionID: "boot-b")

            let result = context.counter.consume(currentBootSessionID: "boot-a")
            #expect(result.total == nil)
            #expect(result.gapDetected)
        }
    }

    @Test
    func newlyCreatedDirectoryDropsInheritedACLBeforeUse() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try addACL(
            "everyone allow read,readattr,readextattr,readsecurity,search,directory_inherit,only_inherit",
            to: root
        )
        let context = telemetryContext(root: root)

        try context.journal.record(
            attemptID: UUID(),
            bootSessionID: "boot-a",
            gate: .beforeRequestValidation,
            reason: .stateMissing
        )

        #expect(try !hasExtendedACL(at: context.paths.directoryURL))
        let attributes = try FileManager.default.attributesOfItem(atPath: context.paths.directoryURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
        #expect((attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value == getegid())
    }

    @Test
    func existingDirectoryWithExtendedACLIsRejected() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = telemetryContext(root: root)
        try FileManager.default.createDirectory(
            at: context.paths.directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try addACL("everyone allow read", to: context.paths.directoryURL)

        #expect(throws: VMNetRecoveryAdmissionTelemetryError.self) {
            try context.journal.record(
                attemptID: UUID(),
                bootSessionID: "boot-a",
                gate: .beforeRequestValidation,
                reason: .stateMissing
            )
        }
        #expect(try hasExtendedACL(at: context.paths.directoryURL))
        #expect(!FileManager.default.fileExists(atPath: context.paths.journalURL.path))
    }

    @Test
    func unsafeDirectoryModeAndJournalSymlinkAreRejected() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = telemetryContext(root: root)
        try FileManager.default.createDirectory(
            at: context.paths.directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        guard chmod(context.paths.directoryURL.path, mode_t(0o755)) == 0 else {
            throw TelemetryTestError.posix("chmod telemetry directory")
        }
        #expect(throws: VMNetRecoveryAdmissionTelemetryError.self) {
            try context.journal.record(
                attemptID: UUID(),
                bootSessionID: "boot-a",
                gate: .beforeRequestValidation,
                reason: .stateMissing
            )
        }

        guard chmod(context.paths.directoryURL.path, mode_t(0o700)) == 0 else {
            throw TelemetryTestError.posix("restore telemetry directory mode")
        }
        let target = root.appendingPathComponent("unrelated")
        #expect(FileManager.default.createFile(atPath: target.path, contents: Data()))
        guard chmod(target.path, mode_t(0o600)) == 0 else {
            throw TelemetryTestError.posix("chmod symlink target")
        }
        try FileManager.default.createSymbolicLink(at: context.paths.journalURL, withDestinationURL: target)
        #expect(throws: VMNetRecoveryAdmissionTelemetryError.self) {
            try context.journal.record(
                attemptID: UUID(),
                bootSessionID: "boot-a",
                gate: .beforeRequestValidation,
                reason: .stateMissing
            )
        }
        #expect(try fileSize(target) == 0)
    }

    @Test
    func invalidBootSessionAndCredentialContractFailClosed() throws {
        try withTelemetryContext { context in
            #expect(throws: VMNetRecoveryAdmissionTelemetryError.invalidEvent) {
                try context.journal.record(
                    attemptID: UUID(),
                    bootSessionID: "boot with spaces",
                    gate: .beforeRequestValidation,
                    reason: .stateMissing
                )
            }

            let wrongOwnerJournal = VMNetRecoveryAdmissionRejectionJournal(
                paths: context.paths,
                requiredOwnerID: geteuid() &+ 1,
                requiredGroupID: getegid(),
                now: { fixtureDate }
            )
            #expect(throws: VMNetRecoveryAdmissionTelemetryError.self) {
                try wrongOwnerJournal.record(
                    attemptID: UUID(),
                    bootSessionID: "boot-a",
                    gate: .beforeRequestValidation,
                    reason: .stateMissing
                )
            }

            let unknown = context.counter.consume(currentBootSessionID: "invalid boot")
            #expect(unknown.total == nil)
            #expect(!unknown.known)
            #expect(!unknown.gapDetected)
        }
    }
}

private let fixtureDate = Date(timeIntervalSince1970: 1_777_000_000)

private struct TelemetryTestContext: Sendable {
    let paths: VMNetRecoveryAdmissionTelemetryPaths
    let journal: VMNetRecoveryAdmissionRejectionJournal
    let counter: VMNetRecoveryAdmissionRejectionCounter

    func makeCounter() -> VMNetRecoveryAdmissionRejectionCounter {
        VMNetRecoveryAdmissionRejectionCounter(
            paths: paths,
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid()
        )
    }

    func record(count: Int, bootSessionID: String) throws {
        for _ in 0..<count {
            try journal.record(
                attemptID: UUID(),
                bootSessionID: bootSessionID,
                gate: .beforeSandboxCreate,
                reason: .stateFenced
            )
        }
    }
}

private func telemetryContext(root: URL) -> TelemetryTestContext {
    let paths = VMNetRecoveryAdmissionTelemetryPaths(
        directoryURL: root.appendingPathComponent("telemetry", isDirectory: true)
    )
    return TelemetryTestContext(
        paths: paths,
        journal: VMNetRecoveryAdmissionRejectionJournal(
            paths: paths,
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid(),
            now: { fixtureDate }
        ),
        counter: VMNetRecoveryAdmissionRejectionCounter(
            paths: paths,
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid()
        )
    )
}

private func withTelemetryContext<T>(_ body: (TelemetryTestContext) throws -> T) throws -> T {
    let root = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(telemetryContext(root: root))
}

private func withTelemetryContext<T>(_ body: (TelemetryTestContext) async throws -> T) async throws -> T {
    let root = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(telemetryContext(root: root))
}

private func makePrivateTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VMNetRecoveryAdmissionTelemetryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    guard chmod(root.path, mode_t(0o700)) == 0 else {
        throw TelemetryTestError.posix("chmod test root")
    }
    return root
}

private func appendRaw(_ data: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

private func writeCursor(
    _ cursor: VMNetRecoveryAdmissionRejectionCursorV1,
    to url: URL
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(cursor).write(to: url, options: .atomic)
    guard chmod(url.path, mode_t(0o600)) == 0 else {
        throw TelemetryTestError.posix("chmod cursor")
    }
}

private func statInformation(_ url: URL) throws -> stat {
    var information = stat()
    guard lstat(url.path, &information) == 0 else {
        throw TelemetryTestError.posix("stat \(url.lastPathComponent)")
    }
    return information
}

private func deviceID(_ information: stat) -> UInt64 {
    UInt64(bitPattern: Int64(information.st_dev))
}

private func fileSize(_ url: URL) throws -> Int64 {
    Int64(try statInformation(url).st_size)
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
        throw TelemetryTestError.command(String(decoding: data, as: UTF8.self))
    }
}

private func hasExtendedACL(at url: URL) throws -> Bool {
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw TelemetryTestError.posix("open ACL fixture")
    }
    defer { close(descriptor) }

    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        if errno == ENOENT {
            return false
        }
        throw TelemetryTestError.posix("inspect ACL fixture")
    }
    acl_free(UnsafeMutableRawPointer(acl))
    return true
}

private enum TelemetryTestError: Error {
    case command(String)
    case posix(String)
}
