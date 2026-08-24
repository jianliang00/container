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

struct FlannelForwardingTests {
    @Test
    func enablingUsesWriteAheadOwnershipAndReadbackBeforePublishingOwned() throws {
        let fixture = ForwardingFixture(ipv4: false)
        defer { fixture.removeFiles() }
        let observation = ForwardingWriteObservation()
        fixture.host.onWrite = { family in
            observation.record(
                family: family,
                ownership: try? fixture.store.load()
            )
        }

        try fixture.manager.ensureEnabled(.ipv4)

        #expect(fixture.host.value(.ipv4))
        #expect(fixture.host.writeValues == [.ipv4: [true]])
        #expect(observation.phase(for: .ipv4) == .enabling)
        let ownership = try #require(try fixture.store.load())
        #expect(ownership.ipv4?.originalEnabled == false)
        #expect(ownership.ipv4?.phase == .owned)
        #expect(try fixture.manager.ownedFamilies() == [.ipv4])
    }

    @Test
    func preenabledFamilyIsRecordedAndReleasedWithoutMutation() throws {
        let fixture = ForwardingFixture(ipv6: true)
        defer { fixture.removeFiles() }

        try fixture.manager.ensureEnabled(.ipv6)
        let restored = try fixture.manager.restore(.ipv6)

        #expect(restored)
        #expect(fixture.host.writeValues.isEmpty)
        #expect(fixture.host.value(.ipv6))
        #expect(try fixture.store.load() == nil)
    }

    @Test
    func restoringIPv6PreservesIPv4ForwardingOwnership() throws {
        let fixture = ForwardingFixture(ipv4: false, ipv6: false)
        defer { fixture.removeFiles() }
        try fixture.manager.ensureEnabled(.ipv4)
        try fixture.manager.ensureEnabled(.ipv6)

        #expect(try fixture.manager.restore(.ipv6))

        #expect(fixture.host.value(.ipv4))
        #expect(!fixture.host.value(.ipv6))
        #expect(try fixture.manager.ownedFamilies() == [.ipv4])
        let ownership = try #require(try fixture.store.load())
        #expect(ownership.ipv4?.phase == .owned)
        #expect(ownership.ipv6 == nil)
    }

    @Test
    func concurrentManagersSerializeTheWholeOwnershipTransaction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-forwarding-lock-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlannelForwardingOwnershipStore(
            url: root.appendingPathComponent("ownership.json"),
            requiredOwnerID: geteuid()
        )
        let host = ForwardingTestHost(ipv4: false, ipv6: false)
        let gate = ForwardingReadGate()
        host.onRead = { family in
            gate.blockFirstIPv4Read(family)
        }
        let lockPath = root.appendingPathComponent("forwarding.lock").path
        let ipv4Manager = SystemFlannelForwardingManager(
            ownershipStore: store,
            advisoryLockPath: lockPath,
            bootSessionProvider: { "boot-a" },
            commandRunner: { [host] executable, arguments in
                try host.run(executable: executable, arguments: arguments)
            }
        )
        let ipv6Manager = SystemFlannelForwardingManager(
            ownershipStore: store,
            advisoryLockPath: lockPath,
            bootSessionProvider: { "boot-a" },
            commandRunner: { [host] executable, arguments in
                try host.run(executable: executable, arguments: arguments)
            }
        )

        let ipv4Task = Task.detached {
            try ipv4Manager.ensureEnabled(.ipv4)
        }
        #expect(gate.waitUntilBlocked())
        let ipv6Task = Task.detached {
            try ipv6Manager.ensureEnabled(.ipv6)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.readCount(.ipv6) == 0)

        gate.open()
        try await ipv4Task.value
        try await ipv6Task.value

        #expect(try ipv4Manager.ownedFamilies() == [.ipv4, .ipv6])
        #expect(host.value(.ipv4))
        #expect(host.value(.ipv6))
    }

    @Test
    func newBootRebasesRestorationToTheCurrentBootBaseline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-forwarding-boot-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlannelForwardingOwnershipStore(
            url: root.appendingPathComponent("ownership.json"),
            requiredOwnerID: geteuid()
        )
        let host = ForwardingTestHost(ipv4: false, ipv6: false)
        let lockPath = root.appendingPathComponent("forwarding.lock").path
        let firstBootManager = SystemFlannelForwardingManager(
            ownershipStore: store,
            advisoryLockPath: lockPath,
            bootSessionProvider: { "boot-a" },
            commandRunner: { [host] executable, arguments in
                try host.run(executable: executable, arguments: arguments)
            }
        )
        try firstBootManager.ensureEnabled(.ipv4)
        try firstBootManager.ensureEnabled(.ipv6)

        host.setValue(.ipv4, enabled: true)
        host.setValue(.ipv6, enabled: false)
        host.clearWrites()
        let secondBootManager = SystemFlannelForwardingManager(
            ownershipStore: store,
            advisoryLockPath: lockPath,
            bootSessionProvider: { "boot-b" },
            commandRunner: { [host] executable, arguments in
                try host.run(executable: executable, arguments: arguments)
            }
        )

        #expect(try secondBootManager.restoreAll() == [.ipv4, .ipv6])

        #expect(host.value(.ipv4))
        #expect(!host.value(.ipv6))
        #expect(host.writeValues.isEmpty)
        #expect(try store.load() == nil)
    }

    @Test
    func enablingRecoveryRetriesOrPromotesFromWriteAheadState() throws {
        for currentEnabled in [false, true] {
            let fixture = ForwardingFixture(ipv4: currentEnabled)
            defer { fixture.removeFiles() }
            try fixture.store.save(
                FlannelForwardingOwnership(
                    bootSessionID: "boot-a",
                    ipv4: FlannelForwardingFamilyOwnership(
                        originalEnabled: false,
                        phase: .enabling
                    )
                )
            )

            try fixture.manager.ensureEnabled(.ipv4)

            #expect(fixture.host.value(.ipv4))
            #expect(fixture.host.writeValues[.ipv4, default: []] == (currentEnabled ? [] : [true]))
            #expect(try fixture.store.load()?.ipv4?.phase == .owned)
            #expect(try fixture.store.load()?.ipv4?.originalEnabled == false)
        }
    }

    @Test
    func activeReconciliationCancelsInterruptedRestorationWithoutLosingOriginalValue() throws {
        let fixture = ForwardingFixture(ipv4: false)
        defer { fixture.removeFiles() }
        try fixture.store.save(
            FlannelForwardingOwnership(
                bootSessionID: "boot-a",
                ipv4: FlannelForwardingFamilyOwnership(
                    originalEnabled: false,
                    phase: .restoring
                )
            )
        )

        try fixture.manager.ensureEnabled(.ipv4)

        #expect(fixture.host.value(.ipv4))
        #expect(fixture.host.writeValues[.ipv4] == [true])
        #expect(try fixture.store.load()?.ipv4?.phase == .owned)
        #expect(try fixture.store.load()?.ipv4?.originalEnabled == false)
    }

    @Test
    func successfulCommandWithoutEffectiveWriteFailsAndRetainsWriteAheadOwnership() throws {
        let fixture = ForwardingFixture(ipv4: false)
        defer { fixture.removeFiles() }
        fixture.host.ignoreWrites(.ipv4)

        #expect(throws: FlannelVXLANError.self) {
            try fixture.manager.ensureEnabled(.ipv4)
        }

        #expect(!fixture.host.value(.ipv4))
        #expect(try fixture.store.load()?.ipv4?.phase == .enabling)
    }

    @Test
    func commandFailureAfterEffectiveWriteUsesReadbackAndCompletes() throws {
        let fixture = ForwardingFixture(ipv6: false)
        defer { fixture.removeFiles() }
        fixture.host.failNextWrite(.ipv6, afterMutation: true)

        try fixture.manager.ensureEnabled(.ipv6)

        #expect(fixture.host.value(.ipv6))
        #expect(try fixture.store.load()?.ipv6?.phase == .owned)
    }

    @Test
    func failedRestorationRetainsRestoringOwnershipForRetry() throws {
        let fixture = ForwardingFixture(ipv4: false)
        defer { fixture.removeFiles() }
        try fixture.manager.ensureEnabled(.ipv4)
        fixture.host.ignoreWrites(.ipv4)

        #expect(throws: FlannelVXLANError.self) {
            try fixture.manager.restore(.ipv4)
        }

        #expect(fixture.host.value(.ipv4))
        let ownership = try #require(try fixture.store.load())
        #expect(ownership.ipv4?.originalEnabled == false)
        #expect(ownership.ipv4?.phase == .restoring)
    }

    @Test
    func failedOwnedStateCommitRecoversFromWriteAheadState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-forwarding-save-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistedStore = FlannelForwardingOwnershipStore(
            url: root.appendingPathComponent("ownership.json"),
            requiredOwnerID: geteuid()
        )
        let failingStore = FailingForwardingOwnershipStore(store: persistedStore)
        failingStore.failSave(call: 2)
        let host = ForwardingTestHost(ipv4: false, ipv6: false)
        let manager = SystemFlannelForwardingManager(
            ownershipStore: failingStore,
            advisoryLockPath: root.appendingPathComponent("forwarding.lock").path,
            bootSessionProvider: { "boot-a" },
            commandRunner: { [host] executable, arguments in
                try host.run(executable: executable, arguments: arguments)
            }
        )

        #expect(throws: FlannelVXLANError.self) {
            try manager.ensureEnabled(.ipv4)
        }

        #expect(host.value(.ipv4))
        #expect(try persistedStore.load()?.ipv4?.phase == .enabling)

        try manager.ensureEnabled(.ipv4)
        #expect(try persistedStore.load()?.ipv4?.phase == .owned)
    }

    @Test
    func failedOwnershipRemovalRecoversAfterSysctlRestoration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-forwarding-remove-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistedStore = FlannelForwardingOwnershipStore(
            url: root.appendingPathComponent("ownership.json"),
            requiredOwnerID: geteuid()
        )
        let failingStore = FailingForwardingOwnershipStore(store: persistedStore)
        let host = ForwardingTestHost(ipv4: false, ipv6: false)
        let manager = SystemFlannelForwardingManager(
            ownershipStore: failingStore,
            advisoryLockPath: root.appendingPathComponent("forwarding.lock").path,
            bootSessionProvider: { "boot-a" },
            commandRunner: { [host] executable, arguments in
                try host.run(executable: executable, arguments: arguments)
            }
        )
        try manager.ensureEnabled(.ipv4)
        failingStore.failNextRemove()

        #expect(throws: FlannelVXLANError.self) {
            try manager.restore(.ipv4)
        }

        #expect(!host.value(.ipv4))
        #expect(try persistedStore.load()?.ipv4?.phase == .restoring)
        #expect(try manager.restore(.ipv4))
        #expect(try persistedStore.load() == nil)
    }

    @Test
    func restoreAllMakesIndependentProgressAndRetainsOnlyFailedFamily() throws {
        let fixture = ForwardingFixture(ipv4: false, ipv6: false)
        defer { fixture.removeFiles() }
        try fixture.manager.ensureEnabled(.ipv4)
        try fixture.manager.ensureEnabled(.ipv6)
        fixture.host.ignoreWrites(.ipv6)

        #expect(throws: FlannelVXLANError.self) {
            try fixture.manager.restoreAll()
        }

        #expect(!fixture.host.value(.ipv4))
        #expect(fixture.host.value(.ipv6))
        let ownership = try #require(try fixture.store.load())
        #expect(ownership.ipv4 == nil)
        #expect(ownership.ipv6?.phase == .restoring)

        fixture.host.allowWrites(.ipv6)
        #expect(try fixture.manager.restoreAll() == [.ipv6])
        #expect(try fixture.store.load() == nil)
    }

    @Test
    func ownershipStoreRejectsUnknownOrEmptySchemaWithoutSysctlMutation() throws {
        let fixture = ForwardingFixture(ipv4: false)
        defer { fixture.removeFiles() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data(
            #"{"bootSessionID":"boot-a","schemaVersion":99,"ipv4":{"originalEnabled":false,"phase":"owned"}}"#.utf8
        )
        .write(to: fixture.store.url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.store.url.path
        )

        #expect(throws: FlannelVXLANError.self) {
            try fixture.manager.ensureEnabled(.ipv4)
        }
        #expect(fixture.host.writeValues.isEmpty)

        try Data(#"{"schemaVersion":1}"#.utf8).write(to: fixture.store.url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.store.url.path
        )
        #expect(throws: FlannelVXLANError.self) {
            try fixture.store.load()
        }
    }

    @Test
    func ownershipStoreRejectsInsecureOrSymlinkedState() throws {
        let fixture = ForwardingFixture()
        defer { fixture.removeFiles() }
        let ownership = FlannelForwardingOwnership(
            bootSessionID: "boot-a",
            ipv4: FlannelForwardingFamilyOwnership(
                originalEnabled: false,
                phase: .enabling
            )
        )
        try fixture.store.save(ownership)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.store.url.path
        )

        #expect(throws: FlannelVXLANError.self) {
            try fixture.store.load()
        }

        try FileManager.default.removeItem(at: fixture.store.url)
        let target = fixture.root.appendingPathComponent("ownership-target.json")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.store.url,
            withDestinationURL: target
        )
        #expect(throws: FlannelVXLANError.self) {
            try fixture.store.load()
        }
    }

    @Test
    func ownershipStorePersistsCanonicalStateWithPrivatePermissions() throws {
        let fixture = ForwardingFixture()
        defer { fixture.removeFiles() }
        let ownership = FlannelForwardingOwnership(
            bootSessionID: "boot-a",
            ipv4: FlannelForwardingFamilyOwnership(
                originalEnabled: false,
                phase: .enabling
            ),
            ipv6: FlannelForwardingFamilyOwnership(
                originalEnabled: true,
                phase: .owned
            )
        )

        try fixture.store.save(ownership)

        #expect(try fixture.store.load() == ownership)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func unexpectedSysctlValueFailsBeforeWritingOwnershipOrMutatingHost() throws {
        let fixture = ForwardingFixture()
        defer { fixture.removeFiles() }
        fixture.host.overrideRead(.ipv4, value: "2")

        #expect(throws: FlannelVXLANError.self) {
            try fixture.manager.ensureEnabled(.ipv4)
        }

        #expect(try fixture.store.load() == nil)
        #expect(fixture.host.writeValues.isEmpty)
    }
}

private struct ForwardingFixture: Sendable {
    let root: URL
    let store: FlannelForwardingOwnershipStore
    let host: ForwardingTestHost
    let manager: SystemFlannelForwardingManager

    init(ipv4: Bool = false, ipv6: Bool = false) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-forwarding-tests-\(UUID().uuidString)", isDirectory: true)
        store = FlannelForwardingOwnershipStore(
            url: root.appendingPathComponent("ownership.json"),
            requiredOwnerID: geteuid()
        )
        host = ForwardingTestHost(ipv4: ipv4, ipv6: ipv6)
        manager = SystemFlannelForwardingManager(
            ownershipStore: store,
            bootSessionProvider: { "boot-a" },
            commandRunner: { [host] executable, arguments in
                try host.run(executable: executable, arguments: arguments)
            }
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ForwardingWriteObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [FlannelForwardingFamily: FlannelForwardingOwnershipPhase] = [:]

    func record(family: FlannelForwardingFamily, ownership: FlannelForwardingOwnership?) {
        lock.withLock {
            switch family {
            case .ipv4:
                phases[family] = ownership?.ipv4?.phase
            case .ipv6:
                phases[family] = ownership?.ipv6?.phase
            }
        }
    }

    func phase(for family: FlannelForwardingFamily) -> FlannelForwardingOwnershipPhase? {
        lock.withLock { phases[family] }
    }
}

private final class ForwardingReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private var didBlock = false

    func blockFirstIPv4Read(_ family: FlannelForwardingFamily) {
        guard family == .ipv4 else {
            return
        }
        let shouldBlock = lock.withLock { () -> Bool in
            guard !didBlock else {
                return false
            }
            didBlock = true
            return true
        }
        guard shouldBlock else {
            return
        }
        entered.signal()
        released.wait()
    }

    func waitUntilBlocked() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func open() {
        released.signal()
    }
}

private final class FailingForwardingOwnershipStore: FlannelForwardingOwnershipStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let store: FlannelForwardingOwnershipStore
    private var saveCalls = 0
    private var failingSaveCalls: Set<Int> = []
    private var removeShouldFail = false

    init(store: FlannelForwardingOwnershipStore) {
        self.store = store
    }

    func failSave(call: Int) {
        lock.withLock { _ = failingSaveCalls.insert(call) }
    }

    func failNextRemove() {
        lock.withLock { removeShouldFail = true }
    }

    func load() throws -> FlannelForwardingOwnership? {
        try store.load()
    }

    func save(_ ownership: FlannelForwardingOwnership) throws {
        let shouldFail = lock.withLock { () -> Bool in
            saveCalls += 1
            return failingSaveCalls.remove(saveCalls) != nil
        }
        if shouldFail {
            throw FlannelVXLANError.persistence("injected forwarding ownership save failure")
        }
        try store.save(ownership)
    }

    func remove() throws {
        let shouldFail = lock.withLock { () -> Bool in
            defer { removeShouldFail = false }
            return removeShouldFail
        }
        if shouldFail {
            throw FlannelVXLANError.persistence("injected forwarding ownership remove failure")
        }
        try store.remove()
    }
}

private final class ForwardingTestHost: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FlannelForwardingFamily: Bool]
    private var writes: [FlannelForwardingFamily: [Bool]] = [:]
    private var ignoredWrites: Set<FlannelForwardingFamily> = []
    private var reads: [FlannelForwardingFamily: Int] = [:]
    private var readOverrides: [FlannelForwardingFamily: String] = [:]
    private var writeFailures: [FlannelForwardingFamily: Bool] = [:]
    var onRead: (@Sendable (FlannelForwardingFamily) -> Void)?
    var onWrite: (@Sendable (FlannelForwardingFamily) -> Void)?

    init(ipv4: Bool, ipv6: Bool) {
        values = [.ipv4: ipv4, .ipv6: ipv6]
    }

    var writeValues: [FlannelForwardingFamily: [Bool]] {
        lock.withLock { writes }
    }

    func value(_ family: FlannelForwardingFamily) -> Bool {
        lock.withLock { values[family] ?? false }
    }

    func readCount(_ family: FlannelForwardingFamily) -> Int {
        lock.withLock { reads[family, default: 0] }
    }

    func setValue(_ family: FlannelForwardingFamily, enabled: Bool) {
        lock.withLock { values[family] = enabled }
    }

    func clearWrites() {
        lock.withLock { writes.removeAll() }
    }

    func ignoreWrites(_ family: FlannelForwardingFamily) {
        lock.withLock { _ = ignoredWrites.insert(family) }
    }

    func allowWrites(_ family: FlannelForwardingFamily) {
        lock.withLock { _ = ignoredWrites.remove(family) }
    }

    func failNextWrite(_ family: FlannelForwardingFamily, afterMutation: Bool) {
        lock.withLock { writeFailures[family] = afterMutation }
    }

    func overrideRead(_ family: FlannelForwardingFamily, value: String) {
        lock.withLock { readOverrides[family] = value }
    }

    func run(executable: String, arguments: [String]) throws -> String {
        guard executable == "/usr/sbin/sysctl", arguments.count == 2 else {
            throw FlannelVXLANError.runtime("unexpected test command")
        }
        if arguments[0] == "-n", let family = Self.family(sysctlName: arguments[1]) {
            let value = lock.withLock { () -> String in
                reads[family, default: 0] += 1
                return readOverrides[family] ?? ((values[family] ?? false) ? "1\n" : "0\n")
            }
            onRead?(family)
            return value
        }
        guard arguments[0] == "-w",
            let separator = arguments[1].lastIndex(of: "="),
            let family = Self.family(sysctlName: String(arguments[1][..<separator])),
            let enabled = Self.enabled(String(arguments[1][arguments[1].index(after: separator)...]))
        else {
            throw FlannelVXLANError.runtime("unexpected test sysctl arguments")
        }

        onWrite?(family)
        let failureAfterMutation = lock.withLock { () -> Bool? in
            writes[family, default: []].append(enabled)
            let failure = writeFailures.removeValue(forKey: family)
            if !ignoredWrites.contains(family), failure != false {
                values[family] = enabled
            }
            return failure
        }
        if failureAfterMutation != nil {
            throw FlannelVXLANError.runtime("injected sysctl write failure")
        }
        return ""
    }

    private static func family(sysctlName: String) -> FlannelForwardingFamily? {
        switch sysctlName {
        case "net.inet.ip.forwarding":
            .ipv4
        case "net.inet6.ip6.forwarding":
            .ipv6
        default:
            nil
        }
    }

    private static func enabled(_ value: String) -> Bool? {
        switch value {
        case "0":
            false
        case "1":
            true
        default:
            nil
        }
    }
}
