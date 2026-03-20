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

#if os(macOS)
import Testing

@testable import container_macos_guest_agent

struct GuestNetworkManagerTests {
    @Test
    func parsesNetworkServiceNameForBSDDevice() {
        let output = """
            An asterisk (*) denotes that a network service is disabled.
            (1) Wi-Fi
            (Hardware Port: Wi-Fi, Device: en0)
            (2) USB 10/100/1000 LAN
            (Hardware Port: USB 10/100/1000 LAN, Device: en7)
            """

        let serviceName = GuestNetworkManager.parseNetworkServiceName(output, interfaceName: "en7")
        #expect(serviceName == "USB 10/100/1000 LAN")
    }

    @Test
    func mergedSearchDomainsPrependsDomainAndDedupes() {
        let values = GuestNetworkManager.mergedSearchDomains(
            domain: "cluster.local",
            searchDomains: ["svc.cluster.local", "cluster.local"]
        )

        #expect(values == ["cluster.local", "svc.cluster.local"])
    }

    @Test
    func netmaskTextFormatsPrefixLength() throws {
        #expect(try GuestNetworkManager.netmaskText(prefixLength: 24) == "255.255.255.0")
        #expect(try GuestNetworkManager.netmaskText(prefixLength: 16) == "255.255.0.0")
    }
}
#endif
