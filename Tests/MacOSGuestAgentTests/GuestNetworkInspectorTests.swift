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

struct GuestNetworkInspectorTests {
    @Test
    func parseDefaultRouteExtractsInterfaceAndGateway() throws {
        let output = """
            route to: default
            destination: default
            mask: default
            gateway: 192.168.64.1
            interface: en0
            flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
            recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
            0         0         0         0          0       0             1500    0
            """

        let route = try GuestNetworkInspector.parseDefaultRoute(output)

        #expect(route == .init(interfaceName: "en0", gateway: "192.168.64.1"))
    }

    @Test
    func parseInterfaceDetailsExtractsIPv4PrefixAndMAC() throws {
        let output = """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            	options=400<CHANNEL_IO>
            	ether 02:42:ac:11:00:02
            	inet 192.168.64.2 netmask 0xffffff00 broadcast 192.168.64.255
            	inet6 fe80::1%en0 prefixlen 64 scopeid 0x4
            	nd6 options=201<PERFORMNUD,DAD>
            	status: active
            """

        let details = try GuestNetworkInspector.parseInterfaceDetails(output)

        #expect(details == .init(
            ipv4Address: "192.168.64.2",
            prefixLength: 24,
            macAddress: "02:42:ac:11:00:02"
        ))
    }

    @Test
    func prefixLengthAcceptsDottedQuadNetmasks() throws {
        let prefix = try GuestNetworkInspector.prefixLength(fromNetmask: "255.255.255.0")
        #expect(prefix == 24)
    }
}
#endif
