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
    func interfaceConfigurationRoundTripPreservesMTU() throws {
        let interface = MacOSGuestNetworkInterfaceConfiguration(
            networkID: "default",
            hostname: "guest-1",
            macAddress: "02:42:ac:11:00:02",
            ipv4Address: "192.168.64.2",
            ipv4PrefixLength: 24,
            ipv4Gateway: "192.168.64.1",
            mtu: 1_450
        )

        let decoded = try JSONDecoder().decode(
            MacOSGuestNetworkInterfaceConfiguration.self,
            from: JSONEncoder().encode(interface)
        )

        #expect(decoded == interface)
        #expect(decoded.mtu == 1_450)
    }

    @Test
    func decodesLegacyInterfaceConfigurationWithoutMTU() throws {
        let data = Data(
            #"{"networkID":"default","hostname":"guest-1","macAddress":"02:42:ac:11:00:02","ipv4Address":"192.168.64.2","ipv4PrefixLength":24,"ipv4Gateway":"192.168.64.1"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(MacOSGuestNetworkInterfaceConfiguration.self, from: data)

        #expect(decoded.mtu == nil)
    }
}
