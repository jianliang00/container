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

import CContainerK8sFlannelVXLANMacOS
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

#if DEBUG
@_silgen_name("container_vxlan_debug_v6_idle_stop")
private func debugIPv6IdleStop() -> Int32

@_silgen_name("container_vxlan_debug_v6_inbound_start_failure")
private func debugIPv6InboundStartFailure() -> Int32
#endif

struct FlannelIPv6TunnelTests {
    @Test
    func rendersVersionedIPv6TunnelConfiguration() throws {
        var value = try FlannelIPv6VXLANTunnel.makeConfiguration(
            FlannelIPv6TunnelConfiguration(
                vni: 4096,
                port: 4789,
                mtu: 1450,
                bindIPv6: "FD31::9",
                localPodCIDR: "fd42:10:244:25::99/64",
                localVTEPMAC: "02-AA-BB-CC-DD-EE"
            )
        )

        #expect(value.abi_version == UInt32(CONTAINER_VXLAN_V6_ABI_VERSION))
        #expect(value.struct_size == UInt32(MemoryLayout<container_vxlan_tunnel_config_v6_t>.size))
        #expect(value.vni == 4096)
        #expect(value.port == 4789)
        #expect(value.mtu == 1450)
        #expect(value.prefix_length == 64)
        #expect(
            bytes(of: &value.bind_ip)
                == [0xfd, 0x31, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9]
        )
        #expect(
            bytes(of: &value.local_network)
                == [0xfd, 0x42, 0, 0x10, 0x02, 0x44, 0, 0x25, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        #expect(bytes(of: &value.local_vtep_mac) == [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee])
    }

    @Test
    func rejectsInvalidIPv6TunnelConfigurations() {
        let valid = FlannelIPv6TunnelConfiguration(
            vni: 4096,
            port: 4789,
            mtu: 1_450,
            bindIPv6: "fd31::9",
            localPodCIDR: "fd42:10:244:25::/64",
            localVTEPMAC: "02:aa:bb:cc:dd:ee"
        )
        let invalid = [
            replacing(valid, mtu: 1_279),
            replacing(valid, bindIPv6: "fe80::9"),
            replacing(valid, bindIPv6: "::ffff:192.0.2.9"),
            replacing(valid, localPodCIDR: "fe80::/64"),
            replacing(valid, localPodCIDR: "fd00::/129"),
            replacing(valid, localVTEPMAC: "01:aa:bb:cc:dd:ee"),
        ]

        for configuration in invalid {
            #expect(
                throws: FlannelVXLANError.invalidConfiguration(
                    "invalid IPv6 tunnel configuration"
                )
            ) {
                try FlannelIPv6VXLANTunnel.makeConfiguration(configuration)
            }
        }
    }

    @Test
    func rendersVersionedIPv6Peer() throws {
        var value = try FlannelIPv6VXLANTunnel.makePeer(
            FlannelIPv6Peer(
                nodeName: "linux-a",
                operatingSystem: "linux",
                podCIDR: "fd42:10:244:2::99/64",
                subnetBase: "fd42:10:244:2::",
                publicIPv6: "FD31::20",
                vni: 4096,
                vtepMAC: "02:11:22:33:44:66"
            )
        )

        #expect(value.abi_version == UInt32(CONTAINER_VXLAN_V6_ABI_VERSION))
        #expect(value.struct_size == UInt32(MemoryLayout<container_vxlan_peer_v6_t>.size))
        #expect(value.prefix_length == 64)
        #expect(
            bytes(of: &value.pod_network)
                == [0xfd, 0x42, 0, 0x10, 0x02, 0x44, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        #expect(
            bytes(of: &value.public_ip)
                == [0xfd, 0x31, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20]
        )
        #expect(bytes(of: &value.vtep_mac) == [0x02, 0x11, 0x22, 0x33, 0x44, 0x66])
    }

    @Test
    func rejectsInvalidIPv6Peers() {
        let valid = FlannelIPv6Peer(
            nodeName: "linux-a",
            podCIDR: "fd42:10:244:2::/64",
            subnetBase: "fd42:10:244:2::",
            publicIPv6: "fd31::20",
            vni: 4096,
            vtepMAC: "02:11:22:33:44:66"
        )
        let invalid = [
            replacing(valid, podCIDR: "fe80::/64"),
            replacing(valid, podCIDR: "fd00::/129"),
            replacing(valid, publicIPv6: "::1"),
            replacing(valid, publicIPv6: "ff02::1"),
            replacing(valid, vtepMAC: "01:11:22:33:44:66"),
        ]

        for peer in invalid {
            #expect(
                throws: FlannelVXLANError.invalidNode("invalid IPv6 tunnel peer linux-a")
            ) {
                try FlannelIPv6VXLANTunnel.makePeer(peer)
            }
        }
    }

    #if DEBUG
    @Test
    func stopsIdleIPv6TunnelWithoutClosingUtunFromAnotherThread() {
        #expect(debugIPv6IdleStop() == 0)
    }

    @Test
    func cleansUpOutboundThreadWhenInboundThreadCreationFails() {
        #expect(debugIPv6InboundStartFailure() == 0)
    }
    #endif
}

private func bytes<T>(of value: inout T) -> [UInt8] {
    withUnsafeBytes(of: &value) { Array($0) }
}

private func replacing(
    _ value: FlannelIPv6TunnelConfiguration,
    mtu: Int? = nil,
    bindIPv6: String? = nil,
    localPodCIDR: String? = nil,
    localVTEPMAC: String? = nil
) -> FlannelIPv6TunnelConfiguration {
    FlannelIPv6TunnelConfiguration(
        vni: value.vni,
        port: value.port,
        mtu: mtu ?? value.mtu,
        bindIPv6: bindIPv6 ?? value.bindIPv6,
        localPodCIDR: localPodCIDR ?? value.localPodCIDR,
        localVTEPMAC: localVTEPMAC ?? value.localVTEPMAC
    )
}

private func replacing(
    _ value: FlannelIPv6Peer,
    podCIDR: String? = nil,
    publicIPv6: String? = nil,
    vtepMAC: String? = nil
) -> FlannelIPv6Peer {
    FlannelIPv6Peer(
        nodeName: value.nodeName,
        operatingSystem: value.operatingSystem,
        podCIDR: podCIDR ?? value.podCIDR,
        subnetBase: value.subnetBase,
        publicIPv6: publicIPv6 ?? value.publicIPv6,
        vni: value.vni,
        vtepMAC: vtepMAC ?? value.vtepMAC
    )
}
