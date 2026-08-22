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
import Foundation
import Testing

@testable import ContainerResource

struct MacOSGuestNetworkLeaseTests {
    @Test
    func leaseStoreRoundTripsProjectedAttachmentState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let attachment = ContainerResource.Attachment(
            network: "default",
            hostname: "guest-1",
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: try CIDRv6("fd42:10:244:22::2/64"),
            ipv6Gateway: try IPv6Address("fd42:10:244:22::1"),
            macAddress: try MACAddress("02:42:ac:11:00:02"),
            dns: .init(
                nameservers: ["9.9.9.9"],
                domain: "cluster.local",
                searchDomains: ["svc.cluster.local"],
                options: ["ndots:5"]
            )
        )
        let lease = MacOSGuestNetworkLease(
            interfaces: [
                .init(
                    backend: .vmnetShared,
                    attachment: attachment
                )
            ]
        )

        try MacOSGuestNetworkLeaseStore.save(lease, in: root)
        let maybeLoaded = try MacOSGuestNetworkLeaseStore.load(from: root)
        let loaded = try #require(maybeLoaded)

        #expect(loaded == lease)
        #expect(loaded.attachments == [attachment])

        try MacOSGuestNetworkLeaseStore.remove(from: root)
        #expect(try MacOSGuestNetworkLeaseStore.load(from: root) == nil)
    }

    @Test
    func legacyAttachmentWithoutIPv6GatewayRemainsIPv4OnlyIntent() throws {
        let data = Data(
            #"{"network":"default","hostname":"guest-1","ipv4Address":"192.168.64.2/24","ipv4Gateway":"192.168.64.1","ipv6Address":"fd42:25e3:5eb4:24a4::2/64"}"#.utf8
        )

        let attachment = try JSONDecoder().decode(ContainerResource.Attachment.self, from: data)
        let expectedIPv6Address = try CIDRv6("fd42:25e3:5eb4:24a4::2/64")

        #expect(attachment.ipv6Address == expectedIPv6Address)
        #expect(attachment.ipv6Gateway == nil)
    }
}
