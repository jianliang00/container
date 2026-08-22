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

@testable import RuntimeMacOSSidecarShared

struct SidecarGuestNetworkingProtocolTests {
    @Test
    func interfaceConfigurationRoundTripPreservesDualStackAndMTU() throws {
        let interface = MacOSGuestNetworkInterfaceConfiguration(
            networkID: "default",
            hostname: "guest-1",
            macAddress: "02:42:ac:11:00:02",
            ipv4Address: "192.168.64.2",
            ipv4PrefixLength: 24,
            ipv4Gateway: "192.168.64.1",
            ipv6Address: "fd42:10:244:22::2",
            ipv6PrefixLength: 64,
            ipv6Gateway: "fd42:10:244:22::1",
            mtu: 1_450
        )

        let decoded = try JSONDecoder().decode(
            MacOSGuestNetworkInterfaceConfiguration.self,
            from: JSONEncoder().encode(interface)
        )

        #expect(decoded == interface)
        #expect(decoded.ipv6Address == "fd42:10:244:22::2")
        #expect(decoded.ipv6PrefixLength == 64)
        #expect(decoded.ipv6Gateway == "fd42:10:244:22::1")
        #expect(decoded.mtu == 1_450)
    }

    @Test
    func decodesLegacyInterfaceConfigurationWithoutMTU() throws {
        let data = Data(
            #"{"networkID":"default","hostname":"guest-1","macAddress":"02:42:ac:11:00:02","ipv4Address":"192.168.64.2","ipv4PrefixLength":24,"ipv4Gateway":"192.168.64.1"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(MacOSGuestNetworkInterfaceConfiguration.self, from: data)

        #expect(decoded.ipv6Address == nil)
        #expect(decoded.ipv6PrefixLength == nil)
        #expect(decoded.ipv6Gateway == nil)
        #expect(decoded.mtu == nil)
    }

    @Test
    func appliedInterfaceRoundTripPreservesEffectiveMTU() throws {
        let interface = MacOSGuestAppliedNetworkInterface(
            networkID: "default",
            interfaceName: "en0",
            macAddress: "02:42:ac:11:00:02",
            ipv4Address: "192.168.64.2/24",
            ipv6Address: "fd42:10:244:22::2/64",
            effectiveMTU: 1_450
        )

        let decoded = try JSONDecoder().decode(
            MacOSGuestAppliedNetworkInterface.self,
            from: JSONEncoder().encode(interface)
        )

        #expect(decoded == interface)
        #expect(decoded.ipv6Address == "fd42:10:244:22::2/64")
        #expect(decoded.effectiveMTU == 1_450)
    }

    @Test
    func decodesLegacyAppliedInterfaceWithoutEffectiveMTU() throws {
        let data = Data(
            #"{"networkID":"default","interfaceName":"en0","macAddress":"02:42:ac:11:00:02","ipv4Address":"192.168.64.2/24"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(MacOSGuestAppliedNetworkInterface.self, from: data)

        #expect(decoded.ipv6Address == nil)
        #expect(decoded.effectiveMTU == nil)
    }

    @Test
    func networkResultRoundTripPreservesEffectiveDNS() throws {
        let result = MacOSGuestNetworkConfigurationResult(
            interfaces: [],
            dnsApplied: true,
            effectiveDNS: .init(
                serviceID: "service-1",
                interfaceName: "en0",
                nameservers: ["10.96.0.10"],
                domain: nil,
                searchDomains: ["default.svc.cluster.local", "svc.cluster.local", "cluster.local"],
                options: ["ndots:5"]
            )
        )

        let decoded = try JSONDecoder().decode(
            MacOSGuestNetworkConfigurationResult.self,
            from: JSONEncoder().encode(result)
        )

        #expect(decoded == result)
    }

    @Test
    func decodesLegacyNetworkResultWithoutEffectiveDNS() throws {
        let data = Data(#"{"interfaces":[],"dnsApplied":true,"warnings":[]}"#.utf8)

        let decoded = try JSONDecoder().decode(MacOSGuestNetworkConfigurationResult.self, from: data)

        #expect(decoded.dnsApplied)
        #expect(decoded.effectiveDNS == nil)
    }
}
