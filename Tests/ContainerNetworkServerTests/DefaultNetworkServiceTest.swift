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

    private func makeService() async throws -> DefaultNetworkService {
        try await DefaultNetworkService(
            network: TestNetwork(
                status: NetworkStatus(
                    ipv4Subnet: try CIDRv4("192.168.64.0/24"),
                    ipv4Gateway: try IPv4Address("192.168.64.1"),
                    ipv6Subnet: nil
                )
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
