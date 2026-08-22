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

import ContainerizationExtras
import Darwin
import Foundation
import Testing

@testable import ContainerNetworkVmnetServer

struct VmnetHostIPv6GatewayReadinessTests {
    @available(macOS 26, *)
    @Test func managedVmnetCFReferenceReleasesExactlyOnce() {
        let releaseCounter = ReleaseCounter()
        let pointer = OpaquePointer(bitPattern: 1)!

        do {
            let reference = ReservedVmnetNetwork.ManagedVmnetCFReference(pointer) { _ in
                releaseCounter.increment()
            }
            #expect(reference.value == pointer)
        }

        #expect(releaseCounter.value == 1)
    }

    @Test func exactGatewayOnUniqueBridgeBecomesReady() throws {
        let fixture = try GatewayFixture(includeGateway: true)
        let checker = fixture.checker(readiness: .ready)

        let result = try checker.readiness(
            ipv4Gateway: fixture.ipv4Gateway,
            ipv6Gateway: fixture.ipv6Gateway,
            prefixLength: 64
        )

        #expect(result == .ready)
        #expect(fixture.readinessInspections == ["bridge100|fd42:10:244:22::1"])
    }

    @Test func missingBridgeOrGatewayRemainsPending() throws {
        let noBridge = try GatewayFixture(includeIPv4Gateway: false)
        #expect(throws: VmnetHostIPv6GatewayReadinessError.self) {
            try noBridge.checker().readiness(
                ipv4Gateway: noBridge.ipv4Gateway,
                ipv6Gateway: noBridge.ipv6Gateway,
                prefixLength: 64
            )
        }

        let noGateway = try GatewayFixture()
        let result = try noGateway.checker().readiness(
            ipv4Gateway: noGateway.ipv4Gateway,
            ipv6Gateway: noGateway.ipv6Gateway,
            prefixLength: 64
        )
        #expect(result == .pending)
        #expect(noGateway.readinessInspections.isEmpty)
    }

    @Test func tentativeGatewayRemainsPending() throws {
        let fixture = try GatewayFixture(includeGateway: true)
        let result = try fixture.checker(readiness: .pending).readiness(
            ipv4Gateway: fixture.ipv4Gateway,
            ipv6Gateway: fixture.ipv6Gateway,
            prefixLength: 64
        )
        #expect(result == .pending)
    }

    @Test func ambiguousPhysicalOrConflictingPlacementFailsClosed() throws {
        for fixture in [
            try GatewayFixture(additionalIPv4GatewayInterface: "bridge101"),
            try GatewayFixture(ipv4GatewayInterfaceType: UInt8(IFT_ETHER)),
            try GatewayFixture(includeGateway: true, gatewayInterface: "bridge101"),
            try GatewayFixture(includeGateway: true, gatewayPrefixLength: 128),
        ] {
            #expect(throws: (any Error).self) {
                try fixture.checker().readiness(
                    ipv4Gateway: fixture.ipv4Gateway,
                    ipv6Gateway: fixture.ipv6Gateway,
                    prefixLength: 64
                )
            }
            #expect(fixture.readinessInspections.isEmpty)
        }
    }

    @Test func ifconfigReadinessRejectsDuplicatedAndRecognizesTentative() throws {
        let gateway = try IPv6Address("fd42:10:244:22::1")
        #expect(
            try SystemVmnetHostIPv6GatewayReadinessChecker.gatewayReadiness(
                fromIfconfigOutput: "\tinet6 fd42:10:244:22::1 prefixlen 64 tentative\n",
                address: gateway
            ) == .pending
        )
        #expect(
            try SystemVmnetHostIPv6GatewayReadinessChecker.gatewayReadiness(
                fromIfconfigOutput: "\tinet6 fd42:10:244:22::1 prefixlen 64\n",
                address: gateway
            ) == .ready
        )
        #expect(throws: (any Error).self) {
            try SystemVmnetHostIPv6GatewayReadinessChecker.gatewayReadiness(
                fromIfconfigOutput: "\tinet6 fd42:10:244:22::1 prefixlen 64 duplicated\n",
                address: gateway
            )
        }
    }

    @Test func waiterHandlesFirstPodBridgeAndGatewayConvergence() async throws {
        let checker = SequencedReadinessChecker([
            .bridgePending,
            .readiness(.pending),
            .readiness(.ready),
        ])
        let sleepCounter = SleepCounter()
        let waiter = VmnetHostIPv6GatewayWaiter(
            checker: checker,
            maxAttempts: 3,
            retryInterval: .zero,
            sleep: { _ in sleepCounter.increment() }
        )

        try await waiter.wait(
            ipv4Gateway: IPv4Address("10.250.34.1"),
            ipv6Gateway: IPv6Address("fd42:10:244:22::1"),
            prefixLength: 64
        )

        #expect(checker.attempts == 3)
        #expect(sleepCounter.value == 2)
    }

    @Test func waiterFailsClosedAtItsServerSideDeadline() async throws {
        let checker = SequencedReadinessChecker([.readiness(.pending)])
        let waiter = VmnetHostIPv6GatewayWaiter(
            checker: checker,
            maxAttempts: 3,
            retryInterval: .zero,
            sleep: { _ in }
        )

        await #expect(throws: (any Error).self) {
            try await waiter.wait(
                ipv4Gateway: IPv4Address("10.250.34.1"),
                ipv6Gateway: IPv6Address("fd42:10:244:22::1"),
                prefixLength: 64
            )
        }
        #expect(checker.attempts == 3)
    }
}

private final class GatewayFixture: @unchecked Sendable {
    let ipv4Gateway: IPv4Address
    let ipv6Gateway: IPv6Address
    let addresses: [VmnetHostInterfaceAddress]

    private let lock = NSLock()
    private var inspections: [String] = []

    init(
        includeIPv4Gateway: Bool = true,
        ipv4GatewayInterfaceType: UInt8 = UInt8(IFT_BRIDGE),
        additionalIPv4GatewayInterface: String? = nil,
        includeGateway: Bool = false,
        gatewayInterface: String = "bridge100",
        gatewayPrefixLength: UInt8 = 64
    ) throws {
        ipv4Gateway = try IPv4Address("10.250.34.1")
        ipv6Gateway = try IPv6Address("fd42:10:244:22::1")
        var addresses: [VmnetHostInterfaceAddress] = [
            .init(interfaceName: "bridge100", value: .link(type: ipv4GatewayInterfaceType))
        ]
        if includeIPv4Gateway {
            addresses.append(.init(interfaceName: "bridge100", value: .ipv4(ipv4Gateway)))
        }
        if let additionalIPv4GatewayInterface {
            addresses.append(.init(interfaceName: additionalIPv4GatewayInterface, value: .link(type: UInt8(IFT_BRIDGE))))
            addresses.append(.init(interfaceName: additionalIPv4GatewayInterface, value: .ipv4(ipv4Gateway)))
        }
        if includeGateway {
            if gatewayInterface != "bridge100" {
                addresses.append(.init(interfaceName: gatewayInterface, value: .link(type: UInt8(IFT_BRIDGE))))
            }
            addresses.append(
                .init(
                    interfaceName: gatewayInterface,
                    value: .ipv6(ipv6Gateway, prefixLength: gatewayPrefixLength)
                ))
        }
        self.addresses = addresses
    }

    var readinessInspections: [String] {
        lock.withLock { inspections }
    }

    func checker(
        readiness: VmnetHostIPv6GatewayReadiness = .ready
    ) -> SystemVmnetHostIPv6GatewayReadinessChecker {
        SystemVmnetHostIPv6GatewayReadinessChecker(
            addressSnapshotProvider: { [addresses] in addresses },
            interfaceReadinessProvider: { [self] interfaceName, address in
                lock.withLock { inspections.append("\(interfaceName)|\(address)") }
                return readiness
            }
        )
    }
}

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class SleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class SequencedReadinessChecker: VmnetHostIPv6GatewayReadinessChecking, @unchecked Sendable {
    enum Result {
        case bridgePending
        case readiness(VmnetHostIPv6GatewayReadiness)
    }

    private let lock = NSLock()
    private let values: [Result]
    private var attemptCount = 0

    init(_ values: [Result]) {
        self.values = values
    }

    var attempts: Int { lock.withLock { attemptCount } }

    func readiness(
        ipv4Gateway: IPv4Address,
        ipv6Gateway _: IPv6Address,
        prefixLength _: UInt8
    ) throws -> VmnetHostIPv6GatewayReadiness {
        try lock.withLock {
            let index = min(attemptCount, values.count - 1)
            attemptCount += 1
            switch values[index] {
            case .bridgePending:
                throw VmnetHostIPv6GatewayReadinessError.bridgeNotReady(ipv4Gateway)
            case .readiness(let value):
                return value
            }
        }
    }
}
