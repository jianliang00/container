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
import Synchronization
import Testing

@testable import ContainerNetworkVmnetServer

struct VmnetDaemonLeaseTests {
    private let original = VmnetDaemonIdentity(pid: 123, startSeconds: 456, startMicroseconds: 789)

    @Test func existingDaemonBracketsOnlyOneReservation() throws {
        let inspector = LeaseTestInspector(original)
        let events = LeaseTestEvents()
        let (resource, lease) = try VmnetDaemonLease.reserve(inspector: inspector) {
            LeaseTestResource("published", events: events)
        }
        try lease.validate()
        #expect(lease.identity == original)
        #expect(events.values == ["create:published"])
        withExtendedLifetime(resource) {}
    }

    @Test func onDemandStartupReleasesUnpublishedReservationBeforeFinalCreate() throws {
        let inspector = LeaseTestInspector(nil)
        let events = LeaseTestEvents()
        var calls = 0
        let (resource, lease) = try VmnetDaemonLease.reserve(inspector: inspector) {
            calls += 1
            inspector.set(original)
            return LeaseTestResource(String(calls), events: events)
        }
        #expect(calls == 2)
        #expect(events.values == ["create:1", "release:1", "create:2"])
        try lease.validate()
        withExtendedLifetime(resource) {}
    }

    @Test func missingIdentityAfterStartupStopsWithoutRetry() {
        let inspector = LeaseTestInspector(nil)
        let events = LeaseTestEvents()
        #expect(throws: (any Error).self) {
            _ = try VmnetDaemonLease.reserve(inspector: inspector) {
                LeaseTestResource("unpublished", events: events)
            }
        }
        #expect(events.values == ["create:unpublished", "release:unpublished"])
    }

    @Test func daemonReplacementDuringCreateDoesNotPublishResource() {
        let inspector = LeaseTestInspector(original)
        let events = LeaseTestEvents()
        #expect(throws: (any Error).self) {
            _ = try VmnetDaemonLease.reserve(inspector: inspector) {
                inspector.set(VmnetDaemonIdentity(pid: 124, startSeconds: 457, startMicroseconds: 0))
                return LeaseTestResource("rejected", events: events)
            }
        }
        #expect(events.values == ["create:rejected", "release:rejected"])
    }

    @Test func disappearanceAndInspectionFailureAreSticky() throws {
        for inspectionFails in [false, true] {
            let inspector = LeaseTestInspector(original)
            let lease = VmnetDaemonLease(identity: original, inspector: inspector)
            try lease.validate()
            if inspectionFails { inspector.fail() } else { inspector.set(nil) }
            #expect(throws: (any Error).self) { try lease.validate() }
            inspector.set(original)
            #expect(throws: (any Error).self) { try lease.validate() }
        }
    }

    @Test func reusedPIDDoesNotReviveLease() {
        let inspector = LeaseTestInspector(VmnetDaemonIdentity(pid: original.pid, startSeconds: original.startSeconds, startMicroseconds: 790))
        let lease = VmnetDaemonLease(identity: original, inspector: inspector)
        #expect(throws: (any Error).self) { try lease.validate() }
    }

    @Test func inspectionFailureBeforeCreateDoesNotAllocate() {
        let inspector = LeaseTestInspector(original)
        inspector.fail()
        var creates = 0
        #expect(throws: (any Error).self) {
            _ = try VmnetDaemonLease.reserve(inspector: inspector) { creates += 1 }
        }
        #expect(creates == 0)
    }

    @Test func nativeCreateFailureIsPreservedWithoutRetry() {
        let inspector = LeaseTestInspector(original)
        var creates = 0
        #expect(throws: LeaseTestError.create) {
            _ = try VmnetDaemonLease.reserve(inspector: inspector) { () throws -> Int in
                creates += 1
                throw LeaseTestError.create
            }
        }
        #expect(creates == 1)
    }

    @Test func systemInspectorReadsRootProcessWithoutElevation() throws {
        let inspector = SystemVmnetDaemonInspector(executablePath: "/sbin/launchd")
        let identity = try #require(try inspector.current())
        #expect(identity.pid == 1)
        #expect(identity.startSeconds > 0)
        #expect(try inspector.isCurrent(identity))
        #expect(try !inspector.isCurrent(VmnetDaemonIdentity(pid: 1, startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds)))
        #expect(try !SystemVmnetDaemonInspector().isCurrent(identity))
    }
}

private enum LeaseTestError: Error, Equatable {
    case inspection
    case create
}

private final class LeaseTestInspector: VmnetDaemonInspecting {
    private struct State {
        var identity: VmnetDaemonIdentity?
        var failed = false
    }

    private let state: Mutex<State>

    init(_ identity: VmnetDaemonIdentity?) { state = Mutex(State(identity: identity)) }

    func set(_ identity: VmnetDaemonIdentity?) { state.withLock { $0 = State(identity: identity) } }
    func fail() { state.withLock { $0.failed = true } }

    func current() throws -> VmnetDaemonIdentity? {
        try state.withLock {
            if $0.failed { throw LeaseTestError.inspection }
            return $0.identity
        }
    }

    func isCurrent(_ identity: VmnetDaemonIdentity) throws -> Bool { try current() == identity }
}

private final class LeaseTestResource {
    private let name: String
    private let events: LeaseTestEvents

    init(_ name: String, events: LeaseTestEvents) {
        self.name = name
        self.events = events
        events.append("create:\(name)")
    }

    deinit { events.append("release:\(name)") }
}

private final class LeaseTestEvents: Sendable {
    private let storage = Mutex<[String]>([])
    var values: [String] { storage.withLock { $0 } }
    func append(_ value: String) { storage.withLock { $0.append(value) } }
}
