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
import Logging
import Synchronization
import Testing

@testable import ContainerNetworkServer
@testable import ContainerXPC

struct DefaultNetworkServiceTest {
    @Test func invalidatedNetworkRejectsStatusAllocationAndCachedActivation() async throws {
        let network = try TestNetwork(status: NetworkStatus(ipv4Subnet: CIDRv4("192.168.64.0/24"), ipv4Gateway: IPv4Address("192.168.64.1"), ipv6Subnet: nil))
        let service = try await DefaultNetworkService(network: network, log: Logger(label: "DefaultNetworkServiceTest"))
        let session = XPCServerSession()
        _ = try await service.allocate(hostname: "original", macAddress: nil, session: session)
        try await service.activate(session: session)
        await network.invalidate()
        await #expect(throws: (any Error).self) { try await service.status() }
        await #expect(throws: (any Error).self) { try await service.activate(session: session) }
        await #expect(throws: (any Error).self) {
            try await service.allocate(hostname: "new", macAddress: nil, session: XPCServerSession())
        }
        #expect(await network.activationCount == 1)
        await session.fireDisconnect()
    }

    @Test func invalidationWhileActivationIsPendingCannotCommitCachedSuccess() async throws {
        let gate = ActivationGate()
        let network = try ControlledActivationNetwork(gate: gate)
        let service = try await DefaultNetworkService(network: network, log: Logger(label: "DefaultNetworkServiceTest"))
        let session = XPCServerSession()
        _ = try await service.allocate(hostname: "pending", macAddress: nil, session: session)
        let activation = Task { try await service.activate(session: session) }
        await waitForActivationCount(network, 1)
        await network.invalidate()
        await gate.open()
        await #expect(throws: (any Error).self) { try await activation.value }
        await #expect(throws: (any Error).self) { try await service.activate(session: session) }
        await session.fireDisconnect()
    }

    @Test func failedReferenceExportReleasesOnlyUnownedAddress() async throws {
        let network = try TestNetwork(status: NetworkStatus(ipv4Subnet: CIDRv4("192.168.64.0/24"), ipv4Gateway: IPv4Address("192.168.64.1"), ipv6Subnet: nil))
        let service = try await DefaultNetworkService(network: network, log: Logger(label: "DefaultNetworkServiceTest"))
        let preferred = try IPv4Address("192.168.64.42")
        network.setExportFailure(true)
        await #expect(throws: (any Error).self) {
            try await service.allocate(hostname: "rejected", macAddress: nil, preferredIPv4Address: preferred, session: XPCServerSession())
        }
        network.setExportFailure(false)
        #expect(try await service.lookup(hostname: "rejected") == nil)
        let session = XPCServerSession()
        let original = try await service.allocate(hostname: "owner", macAddress: nil, preferredIPv4Address: preferred, session: session).attachment
        network.setExportFailure(true)
        await #expect(throws: (any Error).self) {
            try await service.allocate(hostname: "owner", macAddress: nil, session: XPCServerSession())
        }
        network.setExportFailure(false)
        #expect(try await service.lookup(hostname: "owner") == original)
        await session.fireDisconnect()
        #expect(try await service.lookup(hostname: "owner") == nil)
    }

    @Test func testAllocationIsIdempotentWithinSession() async throws {
        let service = try await makeService()
        let session = XPCServerSession()
        let originalMAC = try MACAddress("f2:00:00:00:00:01")
        let replacementMAC = try MACAddress("f2:00:00:00:00:02")

        let first = try await service.allocate(
            hostname: "test-host",
            macAddress: originalMAC,
            session: session
        ).attachment
        let second = try await service.allocate(
            hostname: "test-host",
            macAddress: replacementMAC,
            session: session
        ).attachment

        #expect(second == first)
        #expect(second.macAddress == originalMAC)

        await session.fireDisconnect()
        #expect(try await service.lookup(hostname: "test-host") == nil)
    }

    @Test func preferredIPv4ReservationIsExactAndExclusive() async throws {
        let service = try await makeService()
        let preferred = try IPv4Address("192.168.64.42")
        let ownerSession = XPCServerSession()
        let attachment = try await service.allocate(
            hostname: "restored-host",
            macAddress: try MACAddress("f2:00:00:00:00:01"),
            preferredIPv4Address: preferred,
            session: ownerSession
        ).attachment

        #expect(attachment.ipv4Address.address == preferred)
        await #expect(throws: (any Error).self) {
            try await service.allocate(
                hostname: "stale-host",
                macAddress: try MACAddress("f2:00:00:00:00:02"),
                preferredIPv4Address: preferred,
                session: XPCServerSession()
            )
        }
    }

    @Test func testAllocationRemainsUntilLastOwningSessionDisconnects() async throws {
        let service = try await makeService()
        let oldSession = XPCServerSession()
        let newSession = XPCServerSession()
        let originalMAC = try MACAddress("f2:00:00:00:00:01")
        let replacementMAC = try MACAddress("f2:00:00:00:00:02")

        let original = try await service.allocate(
            hostname: "test-host",
            macAddress: originalMAC,
            session: oldSession
        ).attachment
        let replacement = try await service.allocate(
            hostname: "test-host",
            macAddress: replacementMAC,
            session: newSession
        ).attachment

        #expect(replacement == original)
        #expect(replacement.macAddress == originalMAC)

        await oldSession.fireDisconnect()
        #expect(try await service.lookup(hostname: "test-host") == original)

        await newSession.fireDisconnect()
        #expect(try await service.lookup(hostname: "test-host") == nil)
    }

    @Test func explicitIPv6NetworkProjectsStableAddressAndGateway() async throws {
        let service = try await makeService(
            status: NetworkStatus(
                ipv4Subnet: try CIDRv4("192.168.64.0/24"),
                ipv4Gateway: try IPv4Address("192.168.64.1"),
                ipv6Subnet: try CIDRv6("fd42:10:244:22::/64"),
                ipv6Gateway: try IPv6Address("fd42:10:244:22::1"),
                networkInstanceID: "instance-a"
            )
        )
        let session = XPCServerSession()
        let macAddress = try MACAddress("f2:00:00:00:00:01")

        let allocated = try await service.allocate(
            hostname: "dual-stack-host",
            macAddress: macAddress,
            session: session
        ).attachment
        let lookedUp = try #require(try await service.lookup(hostname: "dual-stack-host"))
        let expectedIPv6Address = try CIDRv6("fd42:10:244:22:f000:ff:fe00:1/64")
        let expectedIPv6Gateway = try IPv6Address("fd42:10:244:22::1")

        #expect(allocated == lookedUp)
        #expect(allocated.networkInstanceID == "instance-a")
        #expect(allocated.ipv6Address == expectedIPv6Address)
        #expect(allocated.ipv6Gateway == expectedIPv6Gateway)
    }

    @Test func automaticIPv6PrefixDoesNotCreateGuestIPv6Intent() async throws {
        let service = try await makeService(
            status: NetworkStatus(
                ipv4Subnet: try CIDRv4("192.168.64.0/24"),
                ipv4Gateway: try IPv4Address("192.168.64.1"),
                ipv6Subnet: try CIDRv6("fd42:25e3:5eb4:24a4::/64")
            )
        )

        let attachment = try await service.allocate(
            hostname: "legacy-host",
            macAddress: try MACAddress("f2:00:00:00:00:01"),
            session: XPCServerSession()
        ).attachment

        #expect(attachment.ipv6Address != nil)
        #expect(attachment.ipv6Gateway == nil)
    }

    @Test func activationRequiresAllocationOnSameSession() async throws {
        let service = try await makeService()

        await #expect(throws: (any Error).self) {
            try await service.activate(session: XPCServerSession())
        }
    }

    @Test func activationIsSharedWhileAttachedAndRevalidatedAfterLastDisconnect() async throws {
        let network = try TestNetwork(
            status: NetworkStatus(
                ipv4Subnet: CIDRv4("192.168.64.0/24"),
                ipv4Gateway: IPv4Address("192.168.64.1"),
                ipv6Subnet: CIDRv6("fd42:10:244:22::/64"),
                ipv6Gateway: IPv6Address("fd42:10:244:22::1")
            ))
        let service = try await DefaultNetworkService(
            network: network,
            log: Logger(label: "DefaultNetworkServiceTest")
        )
        let firstSession = XPCServerSession()
        let secondSession = XPCServerSession()
        for (index, session) in [firstSession, secondSession].enumerated() {
            _ = try await service.allocate(
                hostname: "dual-stack-\(index)",
                macAddress: try MACAddress("f2:00:00:00:00:0\(index + 1)"),
                session: session
            )
            try await service.activate(session: session)
        }
        #expect(await network.activationCount == 1)

        await firstSession.fireDisconnect()
        #expect(await network.activationCount == 1)
        await secondSession.fireDisconnect()

        let nextSession = XPCServerSession()
        _ = try await service.allocate(
            hostname: "dual-stack-next",
            macAddress: try MACAddress("f2:00:00:00:00:03"),
            session: nextSession
        )
        try await service.activate(session: nextSession)

        #expect(await network.activationCount == 2)
    }

    @Test func concurrentActivationsShareOneNetworkTransition() async throws {
        let gate = ActivationGate()
        let network = try ControlledActivationNetwork(gate: gate)
        let service = try await DefaultNetworkService(
            network: network,
            log: Logger(label: "DefaultNetworkServiceTest")
        )
        let firstSession = XPCServerSession()
        let secondSession = XPCServerSession()
        _ = try await service.allocate(
            hostname: "concurrent-a",
            macAddress: try MACAddress("f2:00:00:00:00:01"),
            session: firstSession
        )
        _ = try await service.allocate(
            hostname: "concurrent-b",
            macAddress: try MACAddress("f2:00:00:00:00:02"),
            session: secondSession
        )

        let first = Task { try await service.activate(session: firstSession) }
        await waitForActivationCount(network, 1)
        let second = await service.beginActivation(session: secondSession)
        #expect(await network.activationCount == 1)

        await gate.open()
        try await first.value
        try await second.value
        #expect(await network.activationCount == 1)
    }

    @Test func disconnectedConcurrentWaiterDoesNotRestartSharedActivation() async throws {
        let gate = ActivationGate()
        let network = try ControlledActivationNetwork(gate: gate)
        let service = try await DefaultNetworkService(
            network: network,
            log: Logger(label: "DefaultNetworkServiceTest")
        )
        let disconnectedSession = XPCServerSession()
        let survivingSession = XPCServerSession()
        _ = try await service.allocate(
            hostname: "disconnecting-concurrent",
            macAddress: try MACAddress("f2:00:00:00:00:01"),
            session: disconnectedSession
        )
        _ = try await service.allocate(
            hostname: "surviving-concurrent",
            macAddress: try MACAddress("f2:00:00:00:00:02"),
            session: survivingSession
        )

        let disconnected = Task(priority: .high) {
            try await service.activate(session: disconnectedSession)
        }
        await waitForActivationCount(network, 1)
        let surviving = await service.beginActivation(session: survivingSession)

        await disconnectedSession.fireDisconnect()
        await gate.open()
        await #expect(throws: (any Error).self) {
            try await disconnected.value
        }
        try await surviving.value

        #expect(await network.activationCount == 1)
    }

    @Test func failedActivationCanBeRetried() async throws {
        let network = try ControlledActivationNetwork(failuresRemaining: 1)
        let service = try await DefaultNetworkService(
            network: network,
            log: Logger(label: "DefaultNetworkServiceTest")
        )
        let session = XPCServerSession()
        _ = try await service.allocate(
            hostname: "retry",
            macAddress: try MACAddress("f2:00:00:00:00:01"),
            session: session
        )

        await #expect(throws: ControlledActivationError.self) {
            try await service.activate(session: session)
        }
        try await service.activate(session: session)

        #expect(await network.activationCount == 2)
    }

    @Test func disconnectDuringActivationDoesNotLeaveCachedReadyState() async throws {
        let gate = ActivationGate()
        let network = try ControlledActivationNetwork(gate: gate)
        let service = try await DefaultNetworkService(
            network: network,
            log: Logger(label: "DefaultNetworkServiceTest")
        )
        let disconnectedSession = XPCServerSession()
        _ = try await service.allocate(
            hostname: "disconnecting",
            macAddress: try MACAddress("f2:00:00:00:00:01"),
            session: disconnectedSession
        )
        let activation = Task { try await service.activate(session: disconnectedSession) }
        await waitForActivationCount(network, 1)

        await disconnectedSession.fireDisconnect()
        await gate.open()
        await #expect(throws: (any Error).self) {
            try await activation.value
        }

        let replacementSession = XPCServerSession()
        _ = try await service.allocate(
            hostname: "replacement",
            macAddress: try MACAddress("f2:00:00:00:00:02"),
            session: replacementSession
        )
        try await service.activate(session: replacementSession)
        #expect(await network.activationCount == 2)
    }

    @Test func explicitIPv6NetworkRejectsDuplicateMACAddressesWithoutLeakingAllocation() async throws {
        let service = try await makeService(
            status: NetworkStatus(
                ipv4Subnet: try CIDRv4("192.168.64.0/24"),
                ipv4Gateway: try IPv4Address("192.168.64.1"),
                ipv6Subnet: try CIDRv6("fd42:10:244:22::/64"),
                ipv6Gateway: try IPv6Address("fd42:10:244:22::1")
            )
        )
        let duplicate = try MACAddress("f2:00:00:00:00:01")
        _ = try await service.allocate(
            hostname: "first-host",
            macAddress: duplicate,
            session: XPCServerSession()
        )

        await #expect(throws: (any Error).self) {
            try await service.allocate(
                hostname: "conflicting-host",
                macAddress: duplicate,
                session: XPCServerSession()
            )
        }
        #expect(try await service.lookup(hostname: "conflicting-host") == nil)
    }

    @Test func explicitIPv6NetworkRejectsPrefixThatCannotUseEUI64Allocation() async throws {
        let service = try await makeService(
            status: NetworkStatus(
                ipv4Subnet: try CIDRv4("192.168.64.0/24"),
                ipv4Gateway: try IPv4Address("192.168.64.1"),
                ipv6Subnet: try CIDRv6("fd42:10:244:22::/80"),
                ipv6Gateway: try IPv6Address("fd42:10:244:22::1")
            )
        )

        await #expect(throws: (any Error).self) {
            try await service.allocate(
                hostname: "invalid-prefix-host",
                macAddress: try MACAddress("f2:00:00:00:00:01"),
                session: XPCServerSession()
            )
        }
        #expect(try await service.lookup(hostname: "invalid-prefix-host") == nil)
    }

    @Test func explicitIPv6NetworkRejectsGatewayOutsideSubnet() async throws {
        let service = try await makeService(
            status: NetworkStatus(
                ipv4Subnet: try CIDRv4("192.168.64.0/24"),
                ipv4Gateway: try IPv4Address("192.168.64.1"),
                ipv6Subnet: try CIDRv6("fd42:10:244:22::/64"),
                ipv6Gateway: try IPv6Address("fd42:10:244:23::1")
            )
        )

        await #expect(throws: (any Error).self) {
            try await service.allocate(
                hostname: "invalid-gateway-host",
                macAddress: try MACAddress("f2:00:00:00:00:01"),
                session: XPCServerSession()
            )
        }
        #expect(try await service.lookup(hostname: "invalid-gateway-host") == nil)
    }

    private func makeService(
        status: NetworkStatus? = nil
    ) async throws -> DefaultNetworkService {
        let status =
            try status
            ?? NetworkStatus(
                ipv4Subnet: CIDRv4("192.168.64.0/24"),
                ipv4Gateway: IPv4Address("192.168.64.1"),
                ipv6Subnet: nil
            )
        return try await DefaultNetworkService(
            network: TestNetwork(
                status: status
            ),
            log: Logger(label: "DefaultNetworkServiceTest")
        )
    }
}

extension DefaultNetworkService {
    fileprivate func beginActivation(session: XPCServerSession) async -> Task<Void, Error> {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            continuation.yield()
            continuation.finish()
            try await activate(session: session)
        }
        // Both tasks run on the service actor. This returns only after the
        // activation call has reached its first suspension, registering its waiter.
        for await _ in started {}
        return task
    }
}

private func waitForActivationCount(
    _ network: ControlledActivationNetwork,
    _ expected: Int
) async {
    for _ in 0..<1_000 {
        if await network.activationCount >= expected { return }
        await Task.yield()
    }
    Issue.record("network activation did not start")
}

private actor TestNetwork: Network {
    nonisolated let id = "test-network"
    nonisolated let variant: String? = nil
    private(set) var status: NetworkStatus?
    private nonisolated let exportFailure = Mutex(false)
    private(set) var activationCount = 0

    init(status: NetworkStatus) {
        self.status = status
    }

    nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        if exportFailure.withLock({ $0 }) { throw ControlledActivationError.injectedFailure }
        try handler(nil)
    }

    nonisolated func setExportFailure(_ fail: Bool) { exportFailure.withLock { $0 = fail } }
    func invalidate() { status = nil }

    func start() async throws {}

    func activate() async throws {
        activationCount += 1
    }
}

private enum ControlledActivationError: Error {
    case injectedFailure
}

private actor ActivationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor ControlledActivationNetwork: Network {
    nonisolated let id = "controlled-network"
    nonisolated let variant: String? = nil
    private(set) var status: NetworkStatus?
    private(set) var activationCount = 0
    private var failuresRemaining: Int
    private let gate: ActivationGate?

    init(
        gate: ActivationGate? = nil,
        failuresRemaining: Int = 0
    ) throws {
        self.gate = gate
        self.failuresRemaining = failuresRemaining
        self.status = try NetworkStatus(
            ipv4Subnet: CIDRv4("192.168.64.0/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Subnet: CIDRv6("fd42:10:244:22::/64"),
            ipv6Gateway: IPv6Address("fd42:10:244:22::1")
        )
    }

    nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        try handler(nil)
    }

    func start() async throws {}

    func invalidate() { status = nil }

    func activate() async throws {
        activationCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ControlledActivationError.injectedFailure
        }
        if let gate {
            await gate.wait()
        }
    }
}
