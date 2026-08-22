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
import Testing

@testable import ContainerNetworkServer
@testable import ContainerXPC

struct DefaultNetworkServiceTest {
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
                ipv6Gateway: try IPv6Address("fd42:10:244:22::1")
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

private actor TestNetwork: Network {
    nonisolated let id = "test-network"
    nonisolated let variant: String? = nil
    let status: NetworkStatus?

    init(status: NetworkStatus) {
        self.status = status
    }

    nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        try handler(nil)
    }

    func start() async throws {}
}
