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

struct FlannelWireProtocolTests {
    @Test
    func encodesLinuxAndWindowsCompatibleVXLANEthernetFrame() {
        let innerPacket = outboundIPv4Fixture
        let expectedDatagram: [UInt8] =
            [
                0x08, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
                0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
                0x02, 0x00, 0x00, 0x00, 0x00, 0x16,
                0x08, 0x00,
            ] + innerPacket

        let result = encode(innerPacket)

        #expect(result.status == CONTAINER_VXLAN_WIRE_SUCCESS)
        #expect(result.datagram == expectedDatagram)
        #expect(result.encoded.datagram_length == expectedDatagram.count)
        #expect(result.encoded.inner_packet_length == innerPacket.count)
        #expect(result.encoded.destination_ip == networkIPv4("10.31.252.2"))
        #expect(result.encoded.destination_port == 4_789)
    }

    @Test
    func decodesLinuxAndWindowsCompatibleVXLANEthernetFrame() {
        let expectedInnerPacket = inboundIPv4Fixture
        let datagram: [UInt8] =
            [
                0x08, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
                0x02, 0x00, 0x00, 0x00, 0x00, 0x16,
                0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
                0x08, 0x00,
            ] + expectedInnerPacket

        let result = decode(datagram, outerSourceIP: "10.31.252.2")

        #expect(result.status == CONTAINER_VXLAN_WIRE_SUCCESS)
        #expect(result.innerPacket == expectedInnerPacket)
        #expect(result.decoded.inner_packet_length == expectedInnerPacket.count)
        #expect(!result.decoded.source_cidr_mismatch)
    }

    @Test
    func usesIPv4LengthAndDestinationForOutboundPeerSelection() {
        let ignoredTrailingBytes: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
        let result = encode(outboundIPv4Fixture + ignoredTrailingBytes)

        #expect(result.status == CONTAINER_VXLAN_WIRE_SUCCESS)
        #expect(result.encoded.inner_packet_length == outboundIPv4Fixture.count)
        #expect(result.datagram.suffix(outboundIPv4Fixture.count) == outboundIPv4Fixture[...])

        var unknownDestination = outboundIPv4Fixture
        unknownDestination.replaceSubrange(16..<20, with: [10, 244, 99, 9])
        #expect(encode(unknownDestination).status == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER)
    }

    @Test
    func rejectsInvalidVXLANAndEthernetHeaders() {
        var reservedBitSet = inboundDatagramFixture
        reservedBitSet[1] = 0x01
        #expect(decode(reservedBitSet).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)

        var wrongVNI = inboundDatagramFixture
        wrongVNI[6] = 0x01
        #expect(decode(wrongVNI).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)

        var wrongDestinationMAC = inboundDatagramFixture
        wrongDestinationMAC[8] = 0x04
        #expect(decode(wrongDestinationMAC).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)

        var wrongEtherType = inboundDatagramFixture
        wrongEtherType[20] = 0x86
        wrongEtherType[21] = 0xdd
        #expect(decode(wrongEtherType).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)
    }

    @Test
    func rejectsUnknownOuterPeerAndMismatchedVTEPMAC() {
        #expect(
            decode(inboundDatagramFixture, outerSourceIP: "10.31.252.99").status
                == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER
        )

        var mismatchedSourceMAC = inboundDatagramFixture
        mismatchedSourceMAC[19] = 0x03
        #expect(decode(mismatchedSourceMAC).status == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER)
    }

    @Test
    func validatesInboundIPv4LengthAndLocalDestination() {
        var truncated = inboundDatagramFixture
        truncated[24] = 0x00
        truncated[25] = 0x15
        #expect(decode(truncated).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)

        var wrongDestination = inboundDatagramFixture
        wrongDestination.replaceSubrange(38..<42, with: [10, 244, 23, 9])
        #expect(decode(wrongDestination).status == CONTAINER_VXLAN_WIRE_INVALID_PACKET)
    }

    @Test
    func classifiesOversizedPacketsAndSmallOutputs() {
        let oversizedPacket = ipv4Packet(
            totalLength: 577,
            source: [10, 244, 2, 7],
            destination: [10, 244, 22, 9]
        )
        var config = makeConfiguration()
        config.mtu = 576

        #expect(encode(oversizedPacket, config: config).status == CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET)

        let oversizedDatagram = inboundEthernetPrefix + oversizedPacket
        #expect(
            decode(oversizedDatagram, config: config).status
                == CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET
        )

        #expect(
            encode(outboundIPv4Fixture, outputCapacity: 41).status
                == CONTAINER_VXLAN_WIRE_OUTPUT_TOO_SMALL
        )
        #expect(
            decode(inboundDatagramFixture, outputCapacity: 19).status
                == CONTAINER_VXLAN_WIRE_OUTPUT_TOO_SMALL
        )
    }

    @Test
    func rejectsSpoofedInnerSourceOutsideAuthenticatedPeerAddresses() {
        var innerPacket = inboundIPv4Fixture
        innerPacket.replaceSubrange(12..<16, with: [10, 244, 9, 7])
        let result = decode(inboundEthernetPrefix + innerPacket)

        #expect(result.status == CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH)
        #expect(result.innerPacket.isEmpty)
        #expect(result.decoded.source_cidr_mismatch)
    }

    @Test
    func acceptsAuthenticatedPeerPublicIPAsInnerSource() {
        var innerPacket = inboundIPv4Fixture
        innerPacket.replaceSubrange(12..<16, with: [10, 31, 252, 2])
        let result = decode(inboundEthernetPrefix + innerPacket)

        #expect(result.status == CONTAINER_VXLAN_WIRE_SUCCESS)
        #expect(result.innerPacket == innerPacket)
        #expect(!result.decoded.source_cidr_mismatch)
    }
}

private let outboundIPv4Fixture: [UInt8] = [
    0x45, 0x00, 0x00, 0x14, 0x12, 0x34, 0x40, 0x00,
    0x40, 0x01, 0x00, 0x00, 0x0a, 0xf4, 0x16, 0x07,
    0x0a, 0xf4, 0x02, 0x09,
]

private let inboundIPv4Fixture: [UInt8] = [
    0x45, 0x00, 0x00, 0x14, 0x12, 0x34, 0x40, 0x00,
    0x40, 0x01, 0x00, 0x00, 0x0a, 0xf4, 0x02, 0x07,
    0x0a, 0xf4, 0x16, 0x09,
]

private let inboundEthernetPrefix: [UInt8] = [
    0x08, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x16,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x00,
]

private let inboundDatagramFixture = inboundEthernetPrefix + inboundIPv4Fixture

private func makeConfiguration() -> container_vxlan_tunnel_config_t {
    var config = container_vxlan_tunnel_config_t()
    config.vni = 4_096
    config.port = 4_789
    config.mtu = 1_450
    config.bind_ip = networkIPv4("10.31.252.24")
    config.local_network = networkIPv4("10.244.22.0")
    config.local_netmask = networkIPv4("255.255.255.0")
    setMAC([0x02, 0x00, 0x00, 0x00, 0x00, 0x16], on: &config.local_vtep_mac)
    return config
}

private func makePeer() -> container_vxlan_peer_t {
    var peer = container_vxlan_peer_t()
    peer.pod_network = networkIPv4("10.244.2.0")
    peer.pod_netmask = networkIPv4("255.255.255.0")
    peer.public_ip = networkIPv4("10.31.252.2")
    setMAC([0x02, 0x00, 0x00, 0x00, 0x00, 0x02], on: &peer.vtep_mac)
    return peer
}

private func encode(
    _ innerPacket: [UInt8],
    config: container_vxlan_tunnel_config_t = makeConfiguration(),
    peers: [container_vxlan_peer_t] = [makePeer()],
    outputCapacity: Int? = nil
) -> (
    status: container_vxlan_wire_status_t,
    datagram: [UInt8],
    encoded: container_vxlan_encoded_packet_t
) {
    var config = config
    var datagram = [UInt8](
        repeating: 0,
        count: outputCapacity
            ?? (Int(CONTAINER_VXLAN_HEADER_LENGTH) + Int(CONTAINER_VXLAN_ETHERNET_HEADER_LENGTH)
                + innerPacket.count)
    )
    var encoded = container_vxlan_encoded_packet_t()
    let status = innerPacket.withUnsafeBufferPointer { innerBuffer in
        peers.withUnsafeBufferPointer { peerBuffer in
            datagram.withUnsafeMutableBufferPointer { datagramBuffer in
                container_vxlan_encode_ipv4(
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

private func decode(
    _ datagram: [UInt8],
    outerSourceIP: String = "10.31.252.2",
    config: container_vxlan_tunnel_config_t = makeConfiguration(),
    peers: [container_vxlan_peer_t] = [makePeer()],
    outputCapacity: Int? = nil
) -> (
    status: container_vxlan_wire_status_t,
    innerPacket: [UInt8],
    decoded: container_vxlan_decoded_packet_t
) {
    var config = config
    var innerPacket = [UInt8](repeating: 0, count: outputCapacity ?? max(datagram.count, 1))
    var decoded = container_vxlan_decoded_packet_t()
    let status = peers.withUnsafeBufferPointer { peerBuffer in
        datagram.withUnsafeBufferPointer { datagramBuffer in
            innerPacket.withUnsafeMutableBufferPointer { innerBuffer in
                container_vxlan_decode_ipv4(
                    &config,
                    peerBuffer.baseAddress,
                    peerBuffer.count,
                    networkIPv4(outerSourceIP),
                    datagramBuffer.baseAddress,
                    datagramBuffer.count,
                    innerBuffer.baseAddress,
                    innerBuffer.count,
                    &decoded
                )
            }
        }
    }
    return (status, Array(innerPacket.prefix(decoded.inner_packet_length)), decoded)
}

private func ipv4Packet(totalLength: Int, source: [UInt8], destination: [UInt8]) -> [UInt8] {
    precondition((20...Int(UInt16.max)).contains(totalLength))
    precondition(source.count == 4 && destination.count == 4)
    var packet = [UInt8](repeating: 0, count: totalLength)
    packet[0] = 0x45
    packet[2] = UInt8((totalLength >> 8) & 0xff)
    packet[3] = UInt8(totalLength & 0xff)
    packet[8] = 64
    packet[9] = 1
    packet.replaceSubrange(12..<16, with: source)
    packet.replaceSubrange(16..<20, with: destination)
    return packet
}

private func networkIPv4(_ value: String) -> UInt32 {
    var address = in_addr()
    let result = value.withCString { inet_pton(AF_INET, $0, &address) }
    precondition(result == 1)
    return address.s_addr
}

private func setMAC<T>(_ bytes: [UInt8], on value: inout T) {
    precondition(bytes.count == 6)
    withUnsafeMutableBytes(of: &value) { destination in
        destination.copyBytes(from: bytes)
    }
}
