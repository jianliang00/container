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

public enum VMNetRecoveryAdmissionGate: String, Codable, CaseIterable, Sendable {
    case beforeRequestValidation
    case beforeSandboxCreate
    case beforeNetworkAttach
}

public enum VMNetRecoveryAdmissionRejectReason: String, Codable, CaseIterable, Sendable {
    case configurationUnavailable
    case requestPending
    case requestStateUnavailable
    case stateMissing
    case networkMismatch
    case stateFenced
    case bootMismatch
    case stateUnavailable
}

public protocol VMNetRecoveryAdmissionRejectionRecording: Sendable {
    func record(
        attemptID: UUID,
        bootSessionID: String,
        gate: VMNetRecoveryAdmissionGate,
        reason: VMNetRecoveryAdmissionRejectReason
    ) throws
}

public struct VMNetRecoveryAdmissionRejectionEventV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var attemptID: UUID
    public var observedAt: Date
    public var bootSessionID: String
    public var gate: VMNetRecoveryAdmissionGate
    public var reason: VMNetRecoveryAdmissionRejectReason

    public init(
        attemptID: UUID,
        observedAt: Date,
        bootSessionID: String,
        gate: VMNetRecoveryAdmissionGate,
        reason: VMNetRecoveryAdmissionRejectReason,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.attemptID = attemptID
        self.observedAt = observedAt
        self.bootSessionID = bootSessionID
        self.gate = gate
        self.reason = reason
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw VMNetRecoveryAdmissionTelemetryError.invalidEvent
        }
        try validateVMNetRecoveryAdmissionBootSessionID(bootSessionID)
        guard observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw VMNetRecoveryAdmissionTelemetryError.invalidEvent
        }
        return self
    }
}

public struct VMNetRecoveryAdmissionTelemetryPaths: Equatable, Sendable {
    public static let production = Self(
        directoryURL: URL(fileURLWithPath: "/var/lib/container/vmnet-recovery/telemetry", isDirectory: true),
        journalURL: URL(fileURLWithPath: "/var/lib/container/vmnet-recovery/telemetry/sandbox-rejections.ndjson"),
        lockURL: URL(fileURLWithPath: "/var/lib/container/vmnet-recovery/telemetry/sandbox-rejections.lock"),
        cursorURL: URL(fileURLWithPath: "/var/lib/container/vmnet-recovery/telemetry/sandbox-rejections.cursor.json")
    )

    public var directoryURL: URL
    public var journalURL: URL
    public var lockURL: URL
    public var cursorURL: URL

    public init(
        directoryURL: URL,
        journalURL: URL,
        lockURL: URL,
        cursorURL: URL
    ) {
        self.directoryURL = directoryURL
        self.journalURL = journalURL
        self.lockURL = lockURL
        self.cursorURL = cursorURL
    }

    public init(directoryURL: URL) {
        self.init(
            directoryURL: directoryURL,
            journalURL: directoryURL.appendingPathComponent("sandbox-rejections.ndjson"),
            lockURL: directoryURL.appendingPathComponent("sandbox-rejections.lock"),
            cursorURL: directoryURL.appendingPathComponent("sandbox-rejections.cursor.json")
        )
    }

    fileprivate func validated() throws -> Self {
        let directory = directoryURL.standardizedFileURL
        guard directory.isFileURL,
            directory.path.hasPrefix("/"),
            !directory.lastPathComponent.isEmpty
        else {
            throw VMNetRecoveryAdmissionTelemetryError.unsafePath
        }

        let files = [journalURL, lockURL, cursorURL].map(\.standardizedFileURL)
        guard
            files.allSatisfy({ file in
                file.isFileURL
                    && !file.lastPathComponent.isEmpty
                    && file.deletingLastPathComponent().standardizedFileURL == directory
            }), Set(files.map(\.lastPathComponent)).count == files.count
        else {
            throw VMNetRecoveryAdmissionTelemetryError.unsafePath
        }
        return Self(
            directoryURL: directory,
            journalURL: files[0],
            lockURL: files[1],
            cursorURL: files[2]
        )
    }
}

public enum VMNetRecoveryAdmissionTelemetryError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsafePath
    case unsafeMetadata(String)
    case invalidEvent
    case invalidCursor
    case journalCapacityExceeded
    case io(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .unsafePath:
            "vmnet recovery admission telemetry path is unsafe"
        case .unsafeMetadata(let object):
            "vmnet recovery admission telemetry has unsafe metadata for \(object)"
        case .invalidEvent:
            "vmnet recovery admission telemetry event is invalid"
        case .invalidCursor:
            "vmnet recovery admission telemetry cursor is invalid"
        case .journalCapacityExceeded:
            "vmnet recovery admission telemetry journal capacity is exceeded"
        case .io(let operation, let code):
            "vmnet recovery admission telemetry \(operation) failed: errno \(code)"
        }
    }
}

public struct VMNetRecoveryAdmissionRejectionJournal: VMNetRecoveryAdmissionRejectionRecording, Sendable {
    static let maximumEventSize = 1024
    static let maximumJournalSize = 1024 * 1024

    private let files: VMNetRecoveryAdmissionTelemetryFiles
    private let now: @Sendable () -> Date

    public init(
        paths: VMNetRecoveryAdmissionTelemetryPaths = .production,
        requiredOwnerID: uid_t = 0,
        requiredGroupID: gid_t = 0,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = VMNetRecoveryAdmissionTelemetryFiles(
            paths: paths,
            requiredOwnerID: requiredOwnerID,
            requiredGroupID: requiredGroupID
        )
        self.now = now
    }

    public func record(
        attemptID: UUID,
        bootSessionID: String,
        gate: VMNetRecoveryAdmissionGate,
        reason: VMNetRecoveryAdmissionRejectReason
    ) throws {
        try append(
            VMNetRecoveryAdmissionRejectionEventV1(
                attemptID: attemptID,
                observedAt: now(),
                bootSessionID: bootSessionID,
                gate: gate,
                reason: reason
            )
        )
    }

    public func append(_ event: VMNetRecoveryAdmissionRejectionEventV1) throws {
        let event = try event.validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data: Data
        do {
            data = try encoder.encode(event)
        } catch {
            throw VMNetRecoveryAdmissionTelemetryError.invalidEvent
        }
        guard !data.contains(0x0A), data.count <= Self.maximumEventSize else {
            throw VMNetRecoveryAdmissionTelemetryError.invalidEvent
        }
        data.append(0x0A)

        try files.withExclusiveLock { directoryDescriptor in
            let journal = try files.openJournal(
                in: directoryDescriptor,
                flags: O_WRONLY | O_APPEND,
                createIfMissing: true
            )
            defer { close(journal.descriptor) }
            let information = try files.validateFile(
                journal.descriptor,
                object: "journal",
                requireEmpty: false
            )
            if journal.created,
                case .missing = try files.loadCursor(in: directoryDescriptor)
            {
                let identity = VMNetRecoveryAdmissionJournalIdentity(information)
                try files.saveCursor(
                    VMNetRecoveryAdmissionRejectionCursorV1(
                        bootSessionID: event.bootSessionID,
                        journalDeviceID: identity.deviceID,
                        journalFileID: identity.fileID,
                        journalOffset: 0,
                        rejectedTotal: 0,
                        gapDetected: false
                    ),
                    in: directoryDescriptor
                )
            }
            // Permit one complete record to cross the soft limit. The
            // consumer treats that bounded oversize as a durable gap signal;
            // later writers fail until it is consumed and compacted.
            guard information.st_size >= 0,
                information.st_size <= off_t(Self.maximumJournalSize)
            else {
                throw VMNetRecoveryAdmissionTelemetryError.journalCapacityExceeded
            }
            try files.writeAll(data, to: journal.descriptor, object: "journal")
            guard fsync(journal.descriptor) == 0 else {
                throw files.ioError("sync journal")
            }
            try files.syncDirectory(directoryDescriptor)
        }
    }
}

public struct VMNetRecoveryAdmissionRejectionCountResult: Equatable, Sendable {
    public var total: UInt64?
    public var known: Bool
    public var gapDetected: Bool

    public init(total: UInt64?, known: Bool, gapDetected: Bool) {
        self.total = total
        self.known = known
        self.gapDetected = gapDetected
    }
}

public struct VMNetRecoveryAdmissionRejectionCounter: Sendable {
    private let files: VMNetRecoveryAdmissionTelemetryFiles

    public init(
        paths: VMNetRecoveryAdmissionTelemetryPaths = .production,
        requiredOwnerID: uid_t = 0,
        requiredGroupID: gid_t = 0
    ) {
        self.files = VMNetRecoveryAdmissionTelemetryFiles(
            paths: paths,
            requiredOwnerID: requiredOwnerID,
            requiredGroupID: requiredGroupID
        )
    }

    public func consume(currentBootSessionID: String) -> VMNetRecoveryAdmissionRejectionCountResult {
        do {
            return try consumeThrowing(currentBootSessionID: currentBootSessionID)
        } catch {
            return VMNetRecoveryAdmissionRejectionCountResult(
                total: nil,
                known: false,
                gapDetected: false
            )
        }
    }

    func consumeThrowing(currentBootSessionID: String) throws -> VMNetRecoveryAdmissionRejectionCountResult {
        try validateVMNetRecoveryAdmissionBootSessionID(currentBootSessionID)

        return try files.withExclusiveLock(waitForLock: false) { directoryDescriptor in
            let journal = try files.openJournal(
                in: directoryDescriptor,
                flags: O_RDWR,
                createIfMissing: true
            )
            defer { close(journal.descriptor) }
            let journalInformation = try files.validateFile(
                journal.descriptor,
                object: "journal",
                requireEmpty: false
            )
            let identity = VMNetRecoveryAdmissionJournalIdentity(journalInformation)
            let loadedCursor = try files.loadCursor(in: directoryDescriptor)

            var cursor: VMNetRecoveryAdmissionRejectionCursorV1
            var scanOffset: UInt64
            var allowHistoricalBootEvents: Bool
            switch loadedCursor {
            case .missing:
                cursor = VMNetRecoveryAdmissionRejectionCursorV1(
                    bootSessionID: currentBootSessionID,
                    journalDeviceID: identity.deviceID,
                    journalFileID: identity.fileID,
                    journalOffset: 0,
                    rejectedTotal: 0,
                    // Journal creation happens after taking the stable lock.
                    // An existing journal with no cursor is an interrupted or
                    // damaged lifecycle even if it currently has no bytes.
                    gapDetected: !journal.created || journalInformation.st_size != 0
                )
                scanOffset = 0
                allowHistoricalBootEvents = true
            case .invalid:
                cursor = VMNetRecoveryAdmissionRejectionCursorV1(
                    bootSessionID: currentBootSessionID,
                    journalDeviceID: identity.deviceID,
                    journalFileID: identity.fileID,
                    journalOffset: 0,
                    rejectedTotal: 0,
                    gapDetected: true
                )
                scanOffset = 0
                allowHistoricalBootEvents = true
            case .valid(let existing) where existing.bootSessionID != currentBootSessionID:
                cursor = VMNetRecoveryAdmissionRejectionCursorV1(
                    bootSessionID: currentBootSessionID,
                    journalDeviceID: identity.deviceID,
                    journalFileID: identity.fileID,
                    journalOffset: 0,
                    rejectedTotal: 0,
                    gapDetected: false
                )
                scanOffset = 0
                allowHistoricalBootEvents = true
            case .valid(let existing):
                cursor = existing
                allowHistoricalBootEvents = false
                if existing.journalDeviceID != identity.deviceID
                    || existing.journalFileID != identity.fileID
                {
                    cursor.journalDeviceID = identity.deviceID
                    cursor.journalFileID = identity.fileID
                    cursor.journalOffset = 0
                    cursor.gapDetected = true
                    scanOffset = 0
                } else if UInt64(journalInformation.st_size) < existing.journalOffset {
                    // Recover a durable cursor left by an older implementation
                    // or an external same-inode truncation. New compaction uses
                    // inode replacement so an interrupted rotation is detected
                    // by the identity check above.
                    cursor.journalOffset = 0
                    scanOffset = 0
                } else {
                    scanOffset = existing.journalOffset
                }
            }

            let journalSize = UInt64(journalInformation.st_size)
            let journalIsOversized =
                journalSize > UInt64(VMNetRecoveryAdmissionRejectionJournal.maximumJournalSize)
            if journalIsOversized {
                cursor.gapDetected = true
            } else if scanOffset <= journalSize {
                let data = try files.read(
                    from: journal.descriptor,
                    offset: scanOffset,
                    count: Int(journalSize - scanOffset),
                    object: "journal"
                )
                consume(
                    data,
                    currentBootSessionID: currentBootSessionID,
                    allowHistoricalBootEvents: allowHistoricalBootEvents,
                    cursor: &cursor
                )
            } else {
                cursor.gapDetected = true
            }

            cursor.journalDeviceID = identity.deviceID
            cursor.journalFileID = identity.fileID
            cursor.journalOffset =
                journalSize <= VMNetRecoveryAdmissionRejectionCursorV1.maximumJournalOffset
                ? journalSize : 0
            try files.saveCursor(cursor, in: directoryDescriptor)

            if journalSize > 0 {
                let rotatedInformation = try files.replaceJournalWithEmpty(
                    in: directoryDescriptor
                )
                let rotatedIdentity = VMNetRecoveryAdmissionJournalIdentity(rotatedInformation)
                cursor.journalDeviceID = rotatedIdentity.deviceID
                cursor.journalFileID = rotatedIdentity.fileID
                cursor.journalOffset = 0
                try files.saveCursor(cursor, in: directoryDescriptor)
            }

            return VMNetRecoveryAdmissionRejectionCountResult(
                total: cursor.gapDetected ? nil : cursor.rejectedTotal,
                known: !cursor.gapDetected,
                gapDetected: cursor.gapDetected
            )
        }
    }

    private func consume(
        _ data: Data,
        currentBootSessionID: String,
        allowHistoricalBootEvents: Bool,
        cursor: inout VMNetRecoveryAdmissionRejectionCursorV1
    ) {
        guard !data.isEmpty else {
            return
        }
        guard data.last == 0x0A else {
            cursor.gapDetected = true
            return
        }

        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            guard let newline = data[lineStart...].firstIndex(of: 0x0A) else {
                cursor.gapDetected = true
                return
            }
            let line = Data(data[lineStart..<newline])
            lineStart = data.index(after: newline)
            guard !line.isEmpty,
                line.count <= VMNetRecoveryAdmissionRejectionJournal.maximumEventSize,
                let event = decodeEvent(line)
            else {
                cursor.gapDetected = true
                continue
            }
            if event.bootSessionID != currentBootSessionID {
                if !allowHistoricalBootEvents {
                    cursor.gapDetected = true
                }
                continue
            }
            let (next, overflow) = cursor.rejectedTotal.addingReportingOverflow(1)
            if overflow {
                cursor.gapDetected = true
            } else {
                cursor.rejectedTotal = next
            }
        }
    }

    private func decodeEvent(_ data: Data) -> VMNetRecoveryAdmissionRejectionEventV1? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let event = try? decoder.decode(VMNetRecoveryAdmissionRejectionEventV1.self, from: data),
            let validated = try? event.validated()
        else {
            return nil
        }
        return validated
    }

}

struct VMNetRecoveryAdmissionRejectionCursorV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEncodedSize = 16 * 1024
    static let maximumJournalOffset =
        UInt64(VMNetRecoveryAdmissionRejectionJournal.maximumJournalSize)
        + UInt64(VMNetRecoveryAdmissionRejectionJournal.maximumEventSize) + 1

    var schemaVersion: Int
    var bootSessionID: String
    var journalDeviceID: UInt64
    var journalFileID: UInt64
    var journalOffset: UInt64
    var rejectedTotal: UInt64
    var gapDetected: Bool

    init(
        bootSessionID: String,
        journalDeviceID: UInt64,
        journalFileID: UInt64,
        journalOffset: UInt64,
        rejectedTotal: UInt64,
        gapDetected: Bool,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.bootSessionID = bootSessionID
        self.journalDeviceID = journalDeviceID
        self.journalFileID = journalFileID
        self.journalOffset = journalOffset
        self.rejectedTotal = rejectedTotal
        self.gapDetected = gapDetected
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion,
            journalFileID != 0,
            journalOffset <= Self.maximumJournalOffset
        else {
            throw VMNetRecoveryAdmissionTelemetryError.invalidCursor
        }
        try validateVMNetRecoveryAdmissionBootSessionID(bootSessionID)
        return self
    }
}

private enum LoadedVMNetRecoveryAdmissionCursor {
    case missing
    case invalid
    case valid(VMNetRecoveryAdmissionRejectionCursorV1)
}

private struct VMNetRecoveryAdmissionJournalIdentity {
    var deviceID: UInt64
    var fileID: UInt64

    init(_ information: stat) {
        self.deviceID = UInt64(bitPattern: Int64(information.st_dev))
        self.fileID = UInt64(information.st_ino)
    }
}

private struct VMNetRecoveryAdmissionTelemetryFiles: Sendable {
    private static let processLock = NSLock()

    let paths: VMNetRecoveryAdmissionTelemetryPaths
    let requiredOwnerID: uid_t
    let requiredGroupID: gid_t

    func withExclusiveLock<T>(
        waitForLock: Bool = true,
        _ body: (Int32) throws -> T
    ) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let paths = try paths.validated()
        guard geteuid() == requiredOwnerID, getegid() == requiredGroupID else {
            throw VMNetRecoveryAdmissionTelemetryError.unsafeMetadata("effective process credentials")
        }

        let createdDirectory: Bool
        if mkdir(paths.directoryURL.path, mode_t(0o700)) == 0 {
            createdDirectory = true
        } else if errno == EEXIST {
            createdDirectory = false
        } else {
            throw ioError("create directory")
        }
        let directoryDescriptor = open(
            paths.directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw ioError("open directory")
        }
        defer { close(directoryDescriptor) }
        if createdDirectory {
            guard fchown(directoryDescriptor, requiredOwnerID, requiredGroupID) == 0 else {
                throw ioError("set directory ownership")
            }
            guard fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
                throw ioError("set directory mode")
            }
            // The recovery parent can carry inheritable ACLs for the container
            // service identity. Telemetry is root-only, so a newly created
            // child must drop every inherited extended ACL before use.
            try clearExtendedACL(directoryDescriptor, object: "directory")
        }
        try validateDirectory(directoryDescriptor)

        let lockDescriptor = openat(
            directoryDescriptor,
            paths.lockURL.lastPathComponent,
            O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard lockDescriptor >= 0 else {
            throw ioError("open lock")
        }
        defer { close(lockDescriptor) }
        _ = try validateFile(lockDescriptor, object: "lock", requireEmpty: true)

        let lockOperation = LOCK_EX | (waitForLock ? 0 : LOCK_NB)
        guard flock(lockDescriptor, lockOperation) == 0 else {
            throw ioError("acquire lock")
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        return try body(directoryDescriptor)
    }

    func openJournal(
        in directoryDescriptor: Int32,
        flags: Int32,
        createIfMissing: Bool
    ) throws -> (descriptor: Int32, created: Bool) {
        let resolvedFlags = flags | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        if createIfMissing {
            let descriptor = openat(
                directoryDescriptor,
                paths.journalURL.lastPathComponent,
                resolvedFlags | O_CREAT | O_EXCL,
                mode_t(0o600)
            )
            if descriptor >= 0 {
                var keepFile = false
                defer {
                    if !keepFile {
                        close(descriptor)
                        _ = unlinkat(directoryDescriptor, paths.journalURL.lastPathComponent, 0)
                    }
                }
                guard fchown(descriptor, requiredOwnerID, requiredGroupID) == 0 else {
                    throw ioError("set journal ownership")
                }
                guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw ioError("set journal mode")
                }
                try clearExtendedACL(descriptor, object: "journal")
                _ = try validateFile(descriptor, object: "journal", requireEmpty: true)
                keepFile = true
                return (descriptor, true)
            }
            guard errno == EEXIST else {
                throw ioError("create journal")
            }
        }
        let descriptor = openat(
            directoryDescriptor,
            paths.journalURL.lastPathComponent,
            resolvedFlags,
        )
        guard descriptor >= 0 else {
            throw ioError("open journal")
        }
        return (descriptor, false)
    }

    func replaceJournalWithEmpty(in directoryDescriptor: Int32) throws -> stat {
        let temporaryName = ".sandbox-rejections.journal.\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ioError("create replacement journal")
        }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        guard fchown(descriptor, requiredOwnerID, requiredGroupID) == 0 else {
            throw ioError("set replacement journal ownership")
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ioError("set replacement journal mode")
        }
        try clearExtendedACL(descriptor, object: "replacement journal")
        let information = try validateFile(
            descriptor,
            object: "replacement journal",
            requireEmpty: true
        )
        guard fsync(descriptor) == 0 else {
            throw ioError("sync replacement journal")
        }
        guard
            renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                paths.journalURL.lastPathComponent
            ) == 0
        else {
            throw ioError("rotate journal")
        }
        renamed = true
        try syncDirectory(directoryDescriptor)
        return information
    }

    func validateExistingCursor(in directoryDescriptor: Int32) throws {
        let descriptor = openat(
            directoryDescriptor,
            paths.cursorURL.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw ioError("inspect existing cursor")
        }
        defer { close(descriptor) }
        _ = try validateFile(descriptor, object: "cursor", requireEmpty: false)
    }

    func loadCursor(in directoryDescriptor: Int32) throws -> LoadedVMNetRecoveryAdmissionCursor {
        let descriptor = openat(
            directoryDescriptor,
            paths.cursorURL.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return .missing
            }
            throw ioError("open cursor")
        }
        defer { close(descriptor) }

        let information = try validateFile(
            descriptor,
            object: "cursor",
            requireEmpty: false
        )
        guard information.st_size > 0,
            information.st_size <= off_t(VMNetRecoveryAdmissionRejectionCursorV1.maximumEncodedSize)
        else {
            return .invalid
        }
        let data = try read(
            from: descriptor,
            offset: 0,
            count: Int(information.st_size),
            object: "cursor"
        )
        guard let cursor = try? JSONDecoder().decode(VMNetRecoveryAdmissionRejectionCursorV1.self, from: data),
            let validated = try? cursor.validated()
        else {
            return .invalid
        }
        return .valid(validated)
    }

    func saveCursor(
        _ cursor: VMNetRecoveryAdmissionRejectionCursorV1,
        in directoryDescriptor: Int32
    ) throws {
        let cursor = try cursor.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(cursor)
        } catch {
            throw VMNetRecoveryAdmissionTelemetryError.invalidCursor
        }
        guard data.count <= VMNetRecoveryAdmissionRejectionCursorV1.maximumEncodedSize else {
            throw VMNetRecoveryAdmissionTelemetryError.invalidCursor
        }

        try validateExistingCursor(in: directoryDescriptor)
        let temporaryName = ".sandbox-rejections.cursor.\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ioError("create temporary cursor")
        }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        guard fchown(descriptor, requiredOwnerID, requiredGroupID) == 0 else {
            throw ioError("set temporary cursor ownership")
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ioError("set temporary cursor mode")
        }
        try clearExtendedACL(descriptor, object: "temporary cursor")
        _ = try validateFile(
            descriptor,
            object: "temporary cursor",
            requireEmpty: true
        )
        try writeAll(data, to: descriptor, object: "temporary cursor")
        guard fsync(descriptor) == 0 else {
            throw ioError("sync temporary cursor")
        }
        guard
            renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                paths.cursorURL.lastPathComponent
            ) == 0
        else {
            throw ioError("commit cursor")
        }
        renamed = true
        try syncDirectory(directoryDescriptor)
    }

    func validateFile(
        _ descriptor: Int32,
        object: String,
        requireEmpty: Bool
    ) throws -> stat {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw ioError("inspect \(object)")
        }
        guard information.st_mode & S_IFMT == S_IFREG,
            information.st_uid == requiredOwnerID,
            information.st_gid == requiredGroupID,
            information.st_mode & mode_t(0o7777) == mode_t(0o600),
            information.st_nlink == 1,
            !requireEmpty || information.st_size == 0
        else {
            throw VMNetRecoveryAdmissionTelemetryError.unsafeMetadata(object)
        }
        try validateNoExtendedACL(descriptor, object: object)
        return information
    }

    func read(
        from descriptor: Int32,
        offset: UInt64,
        count: Int,
        object: String
    ) throws -> Data {
        guard count >= 0, offset <= UInt64(off_t.max) else {
            throw VMNetRecoveryAdmissionTelemetryError.unsafeMetadata(object)
        }
        guard lseek(descriptor, off_t(offset), SEEK_SET) == off_t(offset) else {
            throw ioError("seek \(object)")
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard !buffer.isEmpty else {
                return
            }
            guard let baseAddress = buffer.baseAddress else {
                throw VMNetRecoveryAdmissionTelemetryError.unsafeMetadata(object)
            }
            var readOffset = 0
            while readOffset < buffer.count {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: readOffset),
                    buffer.count - readOffset
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ioError("read \(object)")
                }
                guard result > 0 else {
                    throw VMNetRecoveryAdmissionTelemetryError.unsafeMetadata(object)
                }
                readOffset += result
            }
        }
        return data
    }

    func writeAll(_ data: Data, to descriptor: Int32, object: String) throws {
        try data.withUnsafeBytes { bytes in
            guard !bytes.isEmpty else {
                return
            }
            guard let baseAddress = bytes.baseAddress else {
                throw VMNetRecoveryAdmissionTelemetryError.unsafeMetadata(object)
            }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ioError("write \(object)")
                }
                guard result > 0 else {
                    throw VMNetRecoveryAdmissionTelemetryError.unsafeMetadata(object)
                }
                offset += result
            }
        }
    }

    func clearExtendedACL(_ descriptor: Int32, object: String) throws {
        guard let emptyACL = acl_init(0) else {
            throw ioError("allocate empty ACL for \(object)")
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) == 0 else {
            throw ioError("clear ACL for \(object)")
        }
    }

    func syncDirectory(_ directoryDescriptor: Int32) throws {
        guard fsync(directoryDescriptor) == 0 else {
            throw ioError("sync directory")
        }
    }

    func ioError(_ operation: String) -> VMNetRecoveryAdmissionTelemetryError {
        .io(operation: operation, code: errno)
    }

    private func validateDirectory(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw ioError("inspect directory")
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
            information.st_uid == requiredOwnerID,
            information.st_gid == requiredGroupID,
            information.st_mode & mode_t(0o7777) == mode_t(0o700)
        else {
            throw VMNetRecoveryAdmissionTelemetryError.unsafeMetadata("directory")
        }
        try validateNoExtendedACL(descriptor, object: "directory")
    }

    private func validateNoExtendedACL(_ descriptor: Int32, object: String) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw ioError("inspect ACL for \(object)")
            }
            return
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw VMNetRecoveryAdmissionTelemetryError.unsafeMetadata(object)
    }
}

private func validateVMNetRecoveryAdmissionBootSessionID(_ value: String) throws {
    guard !value.isEmpty,
        value.utf8.count <= 128,
        value.utf8.allSatisfy({ byte in
            (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2E
                || byte == 0x5F
                || byte == 0x2D
        })
    else {
        throw VMNetRecoveryAdmissionTelemetryError.invalidEvent
    }
}
