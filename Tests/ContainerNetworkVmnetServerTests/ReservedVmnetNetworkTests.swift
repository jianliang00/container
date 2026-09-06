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
import ContainerXPC
import ContainerizationExtras
import Logging
import Synchronization
import Testing
import XPC

@testable import ContainerNetworkVmnetServer

/// Exercises the real reservation state machine with no native network creation.
struct ReservedVmnetNetworkTests {
    @available(macOS 26, *)
    @Test func failedExportClearsStatusAndKeepsReferenceUntilStop() async throws {
        let fixture = ReservationFixture()
        let network = try fixture.makeNetwork()
        try await network.start()
        #expect(network.status != nil)
        fixture.failSerialization()
        #expect(throws: ReservationError.native) {
            try network.withAdditionalData { _ in Issue.record("failed export reached consumer") }
        }
        #expect(network.status == nil)
        #expect(throws: (any Error).self) {
            try network.withAdditionalData { _ in Issue.record("fenced export reached consumer") }
        }
        await #expect(throws: (any Error).self) { try await network.activate() }
        await #expect(throws: (any Error).self) { try await network.start() }
        #expect(fixture.exports == 1)
        #expect(fixture.releases == 0)
        try await network.stop()
        try await network.stop()
        #expect(fixture.releases == 1)
        await #expect(throws: (any Error).self) { try await network.start() }
    }

    @available(macOS 26, *)
    @Test func consumerErrorPreservesStatusAndAllowsLaterExport() async throws {
        let fixture = ReservationFixture()
        let network = try fixture.makeNetwork()
        try await network.start()
        let generation = try #require(network.status?.networkInstanceID)
        #expect(throws: ReservationError.consumer) {
            try network.withAdditionalData { _ in throw ReservationError.consumer }
        }
        #expect(network.status?.networkInstanceID == generation)
        try network.withAdditionalData { #expect($0 != nil) }
        try await network.activate()
        #expect(fixture.exports == 2)
        #expect(fixture.releases == 0)
        try await network.stop()
        #expect(fixture.releases == 1)
    }

    @available(macOS 26, *)
    @Test func daemonLossDuringSerializationRejectsSuccessfulNativeResult() async throws {
        let fixture = ReservationFixture()
        let network = try fixture.makeNetwork()
        try await network.start()
        fixture.loseDaemonDuringSerialization()
        #expect(throws: (any Error).self) {
            try network.withAdditionalData { _ in Issue.record("stale export reached consumer") }
        }
        #expect(network.status == nil)
        #expect(fixture.exports == 1)
        #expect(fixture.releases == 0)
        try await network.stop()
        #expect(fixture.releases == 1)
    }
}

private enum ReservationError: Error, Equatable { case native, consumer }

@available(macOS 26, *)
private final class ReservationFixture: VmnetDaemonInspecting {
    private struct State {
        var exports = 0
        var releases = 0
        var serializationFails = false
        var loseDaemon = false
        var daemonPresent = true
    }
    private let state = Mutex(State())
    private let identity = VmnetDaemonIdentity(pid: 123, startSeconds: 456, startMicroseconds: 789)

    var exports: Int { state.withLock { $0.exports } }
    var releases: Int { state.withLock { $0.releases } }
    func failSerialization() { state.withLock { $0.serializationFails = true } }
    func loseDaemonDuringSerialization() { state.withLock { $0.loseDaemon = true } }
    func current() throws -> VmnetDaemonIdentity? { state.withLock { $0.daemonPresent ? identity : nil } }
    func isCurrent(_ value: VmnetDaemonIdentity) throws -> Bool { try current() == value }

    func makeNetwork() throws -> ReservedVmnetNetwork {
        try ReservedVmnetNetwork(
            configuration: NetworkConfiguration(name: "reservation-test", mode: .nat, plugin: "container-network-vmnet"),
            log: Logger(label: "ReservedVmnetNetworkTests"),
            hostIPv6GatewayReadinessChecker: SystemVmnetHostIPv6GatewayReadinessChecker(),
            daemonInspector: self,
            createReservation: {
                try ReservedVmnetNetwork.NetworkInfo(
                    network: ReservedVmnetNetwork.ManagedVmnetCFReference(OpaquePointer(bitPattern: 1)!) { _ in
                        self.state.withLock { $0.releases += 1 }
                    },
                    ipv4Subnet: CIDRv4("192.168.64.0/24"), ipv4Gateway: IPv4Address("192.168.64.1"),
                    ipv6Subnet: CIDRv6("fd42:1::/64")
                )
            },
            serializeReservation: { _ in
                try self.state.withLock {
                    $0.exports += 1
                    if $0.serializationFails { throw ReservationError.native }
                    if $0.loseDaemon { $0.daemonPresent = false }
                }
                return XPCMessage(object: xpc_dictionary_create(nil, nil, 0))
            }
        )
    }
}
