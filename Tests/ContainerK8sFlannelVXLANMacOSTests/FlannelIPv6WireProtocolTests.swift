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
import Darwin
import Testing

struct FlannelIPv6WireProtocolTests {
    @Test
    func encodesIPv6VXLANEthernetGoldenFrame() {
        let innerPacket = outboundIPv6Fixture
        let expectedDatagram: [UInt8] =
            [
                0x08, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
                0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
                0x02, 0x00, 0x00, 0x00, 0x00, 0x16,
                0x86, 0xdd,
            ] + innerPacket

        let result = encodeIPv6(innerPacket)

        #expect(result.status == CONTAINER_VXLAN_WIRE_SUCCESS)
        #expect(result.datagram == expectedDatagram)
        #expect(result.encoded.datagram_length == expectedDatagram.count)
        #expect(result.encoded.inner_packet_length == innerPacket.count)
        #expect(encodedDestination(result.encoded) == ipv6Bytes("2001:db8:200:109d::2"))
        #expect(result.encoded.destination_port == 4_789)
    }

    @Test
    func decodesIPv6VXLANEthernetGoldenFrame() {
        let result = decodeIPv6(inboundIPv6DatagramFixture)

        #expect(result.status == CONTAINER_VXLAN_WIRE_SUCCESS)
        #expect(result.innerPacket == inboundIPv6Fixture)
        #expect(result.decoded.inner_packet_length == inboundIPv6Fixture.count)
        #expect(!result.decoded.source_cidr_mismatch)
    }

    @Test
    func usesPayloadLengthAndForwardsExtensionHeadersTransparently() {
        let extensionHeader: [UInt8] = [59, 0, 0, 0, 0, 0, 0, 0]
        let packet = ipv6Packet(
            payload: extensionHeader,
            nextHeader: 0,
            source: "fd42:10:244:22::7",
            destination: "fd42:10:244:2::9"
        )
        let trailingBytes: [UInt8] = [0xde, 0xad, 0xbe, 0xef]

        let result = encodeIPv6(packet + trailingBytes)

        #expect(result.status == CONTAINER_VXLAN_WIRE_SUCCESS)
        #expect(result.encoded.inner_packet_length == packet.count)
        #expect(result.datagram.suffix(packet.count) == packet[...])
    }

    @Test
    func matchesNonByteAlignedPrefixesAndPrefersLongestPeerPrefix() {
        let broadPeer = makeIPv6Peer(
            podNetwork: "fd42:10:244:2::",
            prefixLength: 64,
            publicIP: "2001:db8:200:109d::2",
            mac: [0x02, 0, 0, 0, 0, 0x02]
        )
        let specificPeer = makeIPv6Peer(
            podNetwork: "fd42:10:244:2:8000::",
            prefixLength: 73,
            publicIP: "2001:db8:200:109d::73",
            mac: [0x02, 0, 0, 0, 0, 0x73]
        )
        let packet = ipv6Packet(
            source: "fd42:10:244:22::7",
            destination: "fd42:10:244:2:807f::9"
        )

        let result = encodeIPv6(packet, peers: [broadPeer, specificPeer])

        #expect(result.status == CONTAINER_VXLAN_WIRE_SUCCESS)
        #expect(encodedDestination(result.encoded) == ipv6Bytes("2001:db8:200:109d::73"))

        let outsideSpecificPrefix = ipv6Packet(
            source: "fd42:10:244:22::7",
            destination: "fd42:10:244:2:80ff::9"
        )
        let broadResult = encodeIPv6(outsideSpecificPrefix, peers: [broadPeer, specificPeer])
        #expect(encodedDestination(broadResult.encoded) == ipv6Bytes("2001:db8:200:109d::2"))
    }

    @Test
    func rejectsInvalidVXLANEthernetAndIPv6Lengths() {
        var reservedBitSet = inboundIPv6DatagramFixture
        reservedBitSet[1] = 0x01
        #expect(decodeIPv6(reservedBitSet).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)

        var wrongVNI = inboundIPv6DatagramFixture
        wrongVNI[6] = 0x01
        #expect(decodeIPv6(wrongVNI).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)

        var wrongDestinationMAC = inboundIPv6DatagramFixture
        wrongDestinationMAC[8] = 0x04
        #expect(decodeIPv6(wrongDestinationMAC).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)

        var wrongEtherType = inboundIPv6DatagramFixture
        wrongEtherType[20] = 0x08
        wrongEtherType[21] = 0x00
        #expect(decodeIPv6(wrongEtherType).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)

        var truncatedPayload = inboundIPv6DatagramFixture
        truncatedPayload[26] = 0x00
        truncatedPayload[27] = 0x09
        #expect(decodeIPv6(truncatedPayload).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)
    }

    @Test
    func authenticatesOuterIPv6AndVTEPMACAsOnePeerIdentity() {
        #expect(
            decodeIPv6(inboundIPv6DatagramFixture, outerSourceIP: "2001:db8:200:109d::99").status
                == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER
        )

        var mismatchedSourceMAC = inboundIPv6DatagramFixture
        mismatchedSourceMAC[19] = 0x03
        #expect(decodeIPv6(mismatchedSourceMAC).status == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER)
    }

    @Test
    func rejectsSpoofedInnerIPv6SourceAndDestination() {
        let spoofedOutboundSource = ipv6Packet(
            source: "fd42:10:244:99::7",
            destination: "fd42:10:244:2::9"
        )
        #expect(
            encodeIPv6(spoofedOutboundSource).status
                == CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH
        )

        let spoofedInboundSource = ipv6Packet(
            source: "fd42:10:244:99::7",
            destination: "fd42:10:244:22::9"
        )
        let sourceResult = decodeIPv6(inboundIPv6EthernetPrefix + spoofedInboundSource)
        #expect(sourceResult.status == CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH)
        #expect(sourceResult.innerPacket.isEmpty)
        #expect(sourceResult.decoded.source_cidr_mismatch)

        let spoofedInboundDestination = ipv6Packet(
            source: "fd42:10:244:2::7",
            destination: "fd42:10:244:99::9"
        )
        #expect(
            decodeIPv6(inboundIPv6EthernetPrefix + spoofedInboundDestination).status
                == CONTAINER_VXLAN_WIRE_INVALID_PACKET
        )
    }

    @Test
    func acceptsAllowlistedPeerPublicIPv6AsInnerSource() {
        let packet = ipv6Packet(
            source: "2001:db8:200:109d::2",
            destination: "fd42:10:244:22::9"
        )
        let result = decodeIPv6(inboundIPv6EthernetPrefix + packet)

        #expect(result.status == CONTAINER_VXLAN_WIRE_SUCCESS)
        #expect(result.innerPacket == packet)
        #expect(!result.decoded.source_cidr_mismatch)
    }

    @Test
    func rejectsDifferentPublicIPv6AsInnerSource() {
        let packet = ipv6Packet(
            source: "2001:db8:200:109d::3",
            destination: "fd42:10:244:22::9"
        )
        let result = decodeIPv6(inboundIPv6EthernetPrefix + packet)

        #expect(result.status == CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH)
        #expect(result.innerPacket.isEmpty)
        #expect(result.decoded.source_cidr_mismatch)
    }

    @Test
    func rejectsPeerPublicIPv6WithoutMatchingOuterSource() {
        let packet = ipv6Packet(
            source: "2001:db8:200:109d::2",
            destination: "fd42:10:244:22::9"
        )
        let result = decodeIPv6(
            inboundIPv6EthernetPrefix + packet,
            outerSourceIP: "2001:db8:200:109d::99"
        )

        #expect(result.status == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER)
        #expect(result.innerPacket.isEmpty)
    }

    @Test
    func rejectsPeerPublicIPv6WithoutMatchingVTEPMAC() {
        let packet = ipv6Packet(
            source: "2001:db8:200:109d::2",
            destination: "fd42:10:244:22::9"
        )
        var datagram = inboundIPv6EthernetPrefix + packet
        datagram[19] = 0x03
        let result = decodeIPv6(datagram)

        #expect(result.status == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER)
        #expect(result.innerPacket.isEmpty)
    }

    @Test
    func classifiesIPv6MTUAndOutputCapacityErrors() {
        let oversizedPacket = ipv6Packet(
            payload: [UInt8](repeating: 0, count: 1_241),
            source: "fd42:10:244:22::7",
            destination: "fd42:10:244:2::9"
        )
        var config = makeIPv6Configuration()
        config.mtu = 1_280

        #expect(
            encodeIPv6(oversizedPacket, config: config).status
                == CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET
        )
        #expect(
            decodeIPv6(inboundIPv6EthernetPrefix + oversizedPacket, config: config).status
                == CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET
        )
        #expect(
            encodeIPv6(outboundIPv6Fixture, outputCapacity: 61).status
                == CONTAINER_VXLAN_WIRE_OUTPUT_TOO_SMALL
        )
        #expect(
            decodeIPv6(inboundIPv6DatagramFixture, outputCapacity: 39).status
                == CONTAINER_VXLAN_WIRE_OUTPUT_TOO_SMALL
        )
    }

    @Test
    func validatesV6ABIVersionStructSizePrefixAndCanonicalNetwork() {
        var wrongVersion = makeIPv6Configuration()
        wrongVersion.abi_version += 1
        #expect(encodeIPv6(outboundIPv6Fixture, config: wrongVersion).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

        var shortConfig = makeIPv6Configuration()
        shortConfig.struct_size -= 1
        #expect(encodeIPv6(outboundIPv6Fixture, config: shortConfig).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

        var oversizedConfig = makeIPv6Configuration()
        oversizedConfig.struct_size += 1
        #expect(encodeIPv6(outboundIPv6Fixture, config: oversizedConfig).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

        var invalidPeerPrefix = makeIPv6Peer()
        invalidPeerPrefix.prefix_length = 129
        #expect(encodeIPv6(outboundIPv6Fixture, peers: [invalidPeerPrefix]).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

        var zeroPeerPrefix = makeIPv6Peer()
        zeroPeerPrefix.prefix_length = 0
        #expect(encodeIPv6(outboundIPv6Fixture, peers: [zeroPeerPrefix]).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

        var zeroConfigPrefix = makeIPv6Configuration()
        zeroConfigPrefix.prefix_length = 0
        #expect(encodeIPv6(outboundIPv6Fixture, config: zeroConfigPrefix).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

        var zeroLocalNetwork = makeIPv6Configuration()
        setIPv6("::", on: &zeroLocalNetwork.local_network)
        #expect(encodeIPv6(outboundIPv6Fixture, config: zeroLocalNetwork).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

        var zeroPodNetwork = makeIPv6Peer()
        setIPv6("::", on: &zeroPodNetwork.pod_network)
        #expect(encodeIPv6(outboundIPv6Fixture, peers: [zeroPodNetwork]).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

        var nonCanonicalPeer = makeIPv6Peer()
        setIPv6("fd42:10:244:2::1", on: &nonCanonicalPeer.pod_network)
        #expect(encodeIPv6(outboundIPv6Fixture, peers: [nonCanonicalPeer]).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

        for invalidUnderlay in ["::1", "fe80::24", "::ffff:192.0.2.24"] {
            var invalidBind = makeIPv6Configuration()
            setIPv6(invalidUnderlay, on: &invalidBind.bind_ip)
            #expect(encodeIPv6(outboundIPv6Fixture, config: invalidBind).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)

            var invalidPublicIP = makeIPv6Peer()
            setIPv6(invalidUnderlay, on: &invalidPublicIP.public_ip)
            #expect(encodeIPv6(outboundIPv6Fixture, peers: [invalidPublicIP]).status == CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT)
        }
    }
}

private let outboundIPv6Fixture = ipv6Packet(
    payload: [0x80, 0x00, 0x00, 0x00, 0x12, 0x34, 0x00, 0x01],
    source: "fd42:10:244:22::7",
    destination: "fd42:10:244:2::9"
)

private let inboundIPv6Fixture = ipv6Packet(
    payload: [0x81, 0x00, 0x00, 0x00, 0x12, 0x34, 0x00, 0x01],
    source: "fd42:10:244:2::7",
    destination: "fd42:10:244:22::9"
)

private let inboundIPv6EthernetPrefix: [UInt8] = [
    0x08, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x16,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
    0x86, 0xdd,
]

private let inboundIPv6DatagramFixture = inboundIPv6EthernetPrefix + inboundIPv6Fixture

private func makeIPv6Configuration(
    localNetwork: String = "fd42:10:244:22::",
    prefixLength: UInt8 = 64
) -> container_vxlan_tunnel_config_v6_t {
    var config = container_vxlan_tunnel_config_v6_t()
    config.abi_version = UInt32(CONTAINER_VXLAN_V6_ABI_VERSION)
    config.struct_size = UInt32(MemoryLayout<container_vxlan_tunnel_config_v6_t>.size)
    config.vni = 4_096
    config.port = 4_789
    config.mtu = 1_450
    config.prefix_length = prefixLength
    setIPv6("2001:db8:200:109d::24", on: &config.bind_ip)
    setIPv6(localNetwork, on: &config.local_network)
    setFixedBytes([0x02, 0, 0, 0, 0, 0x16], on: &config.local_vtep_mac)
    return config
}

private func makeIPv6Peer(
    podNetwork: String = "fd42:10:244:2::",
    prefixLength: UInt8 = 64,
    publicIP: String = "2001:db8:200:109d::2",
    mac: [UInt8] = [0x02, 0, 0, 0, 0, 0x02]
) -> container_vxlan_peer_v6_t {
    var peer = container_vxlan_peer_v6_t()
    peer.abi_version = UInt32(CONTAINER_VXLAN_V6_ABI_VERSION)
    peer.struct_size = UInt32(MemoryLayout<container_vxlan_peer_v6_t>.size)
    peer.prefix_length = prefixLength
    setIPv6(podNetwork, on: &peer.pod_network)
    setIPv6(publicIP, on: &peer.public_ip)
    setFixedBytes(mac, on: &peer.vtep_mac)
    return peer
}

private func encodeIPv6(
    _ innerPacket: [UInt8],
    config: container_vxlan_tunnel_config_v6_t = makeIPv6Configuration(),
    peers: [container_vxlan_peer_v6_t] = [makeIPv6Peer()],
    outputCapacity: Int? = nil
) -> (
    status: container_vxlan_wire_status_t,
    datagram: [UInt8],
    encoded: container_vxlan_encoded_packet_v6_t
) {
    var config = config
    var datagram = [UInt8](
        repeating: 0,
        count: outputCapacity
            ?? (Int(CONTAINER_VXLAN_HEADER_LENGTH) + Int(CONTAINER_VXLAN_ETHERNET_HEADER_LENGTH)
                + innerPacket.count)
    )
    var encoded = container_vxlan_encoded_packet_v6_t()
    let status = innerPacket.withUnsafeBufferPointer { innerBuffer in
        peers.withUnsafeBufferPointer { peerBuffer in
            datagram.withUnsafeMutableBufferPointer { datagramBuffer in
                container_vxlan_encode_ipv6(
                    &config,
                    peerBuffer.baseAddress,
                    peerBuffer.count,
                    innerBuffer.baseAddress,
                    innerBuffer.count,
                    datagramBuffer.baseAddress,
                    datagramBuffer.count,
                    &encoded
                )
            }
        }
    }
    return (status, Array(datagram.prefix(encoded.datagram_length)), encoded)
}

private func decodeIPv6(
    _ datagram: [UInt8],
    outerSourceIP: String = "2001:db8:200:109d::2",
    config: container_vxlan_tunnel_config_v6_t = makeIPv6Configuration(),
    peers: [container_vxlan_peer_v6_t] = [makeIPv6Peer()],
    outputCapacity: Int? = nil
) -> (
    status: container_vxlan_wire_status_t,
    innerPacket: [UInt8],
    decoded: container_vxlan_decoded_packet_t
) {
    var config = config
    var outerSource = ipv6Bytes(outerSourceIP)
    var innerPacket = [UInt8](repeating: 0, count: outputCapacity ?? max(datagram.count, 1))
    var decoded = container_vxlan_decoded_packet_t()
    let status = peers.withUnsafeBufferPointer { peerBuffer in
        outerSource.withUnsafeMutableBufferPointer { outerBuffer in
            datagram.withUnsafeBufferPointer { datagramBuffer in
                innerPacket.withUnsafeMutableBufferPointer { innerBuffer in
                    container_vxlan_decode_ipv6(
                        &config,
                        peerBuffer.baseAddress,
                        peerBuffer.count,
                        outerBuffer.baseAddress,
                        datagramBuffer.baseAddress,
                        datagramBuffer.count,
                        innerBuffer.baseAddress,
                        innerBuffer.count,
                        &decoded
                    )
                }
            }
        }
    }
    return (status, Array(innerPacket.prefix(decoded.inner_packet_length)), decoded)
}

private func ipv6Packet(
    payload: [UInt8] = [],
    nextHeader: UInt8 = 58,
    source: String,
    destination: String
) -> [UInt8] {
    precondition(payload.count <= Int(UInt16.max))
    var packet = [UInt8](repeating: 0, count: 40 + payload.count)
    packet[0] = 0x60
    packet[4] = UInt8((payload.count >> 8) & 0xff)
    packet[5] = UInt8(payload.count & 0xff)
    packet[6] = nextHeader
    packet[7] = 64
    packet.replaceSubrange(8..<24, with: ipv6Bytes(source))
    packet.replaceSubrange(24..<40, with: ipv6Bytes(destination))
    packet.replaceSubrange(40..., with: payload)
    return packet
}

private func ipv6Bytes(_ value: String) -> [UInt8] {
    var address = in6_addr()
    let result = value.withCString { inet_pton(AF_INET6, $0, &address) }
    precondition(result == 1)
    return withUnsafeBytes(of: &address) { Array($0) }
}

private func setIPv6<T>(_ value: String, on field: inout T) {
    setFixedBytes(ipv6Bytes(value), on: &field)
}

private func setFixedBytes<T>(_ bytes: [UInt8], on field: inout T) {
    precondition(MemoryLayout<T>.size == bytes.count)
    withUnsafeMutableBytes(of: &field) { destination in
        destination.copyBytes(from: bytes)
    }
}

private func encodedDestination(_ encoded: container_vxlan_encoded_packet_v6_t) -> [UInt8] {
    var encoded = encoded
    return withUnsafeBytes(of: &encoded.destination_ip) { Array($0) }
}
