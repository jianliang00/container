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
import Foundation

public struct FlannelTunnelConfiguration: Sendable, Equatable {
    public var vni: Int
    public var port: Int
    public var mtu: Int
    public var bindIP: String
    public var localPodCIDR: String
    public var localVTEPMAC: String

    public init(
        vni: Int,
        port: Int,
        mtu: Int,
        bindIP: String,
        localPodCIDR: String,
        localVTEPMAC: String
    ) {
        self.vni = vni
        self.port = port
        self.mtu = mtu
        self.bindIP = bindIP
        self.localPodCIDR = localPodCIDR
        self.localVTEPMAC = localVTEPMAC
    }
}

public struct FlannelIPv6TunnelConfiguration: Sendable, Equatable {
    public var vni: Int
    public var port: Int
    public var mtu: Int
    public var bindIPv6: String
    public var localPodCIDR: String
    public var localVTEPMAC: String

    public init(
        vni: Int,
        port: Int,
        mtu: Int,
        bindIPv6: String,
        localPodCIDR: String,
        localVTEPMAC: String
    ) {
        self.vni = vni
        self.port = port
        self.mtu = mtu
        self.bindIPv6 = bindIPv6
        self.localPodCIDR = localPodCIDR
        self.localVTEPMAC = localVTEPMAC
    }
}

public struct FlannelTunnelStatistics: Sendable, Equatable {
    public var transmittedPackets: UInt64
    public var transmittedBytes: UInt64
    public var receivedPackets: UInt64
    public var receivedBytes: UInt64
    public var unknownPeerPackets: UInt64
    public var invalidPackets: UInt64
    public var oversizedPackets: UInt64
    public var sourceCIDRMismatches: UInt64
}

public protocol FlannelTunnelControlling: AnyObject, Sendable {
    var interfaceName: String { get }
    var isRunning: Bool { get }
    func setPeers(_ peers: [FlannelPeer]) throws
    func start() throws
    func stop()
    func destroy()
    func statistics() -> FlannelTunnelStatistics
}

public protocol FlannelIPv6TunnelControlling: AnyObject, Sendable {
    var interfaceName: String { get }
    var isRunning: Bool { get }
    func setPeers(_ peers: [FlannelIPv6Peer]) throws
    func start() throws
    func stop()
    func destroy()
    func statistics() -> FlannelTunnelStatistics
}

public final class FlannelVXLANTunnel: FlannelTunnelControlling, @unchecked Sendable {
    public let interfaceName: String

    private var tunnel: OpaquePointer?
    private var started = false

    public var isRunning: Bool {
        guard let tunnel else {
            return false
        }
        return container_vxlan_tunnel_is_running(tunnel)
    }

    public init(configuration: FlannelTunnelConfiguration) throws {
        var cConfiguration = try Self.makeConfiguration(configuration)
        var created: OpaquePointer?
        var interfaceBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = container_vxlan_tunnel_create(
            &cConfiguration,
            &created,
            &interfaceBuffer,
            interfaceBuffer.count,
            &errorBuffer,
            errorBuffer.count
        )
        guard status == 0, let created else {
            throw Self.runtimeError(status: status, buffer: errorBuffer, operation: "create tunnel")
        }
        self.tunnel = created
        let terminator = interfaceBuffer.firstIndex(of: 0) ?? interfaceBuffer.endIndex
        self.interfaceName = String(
            decoding: interfaceBuffer[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    deinit {
        if let tunnel {
            container_vxlan_tunnel_destroy(tunnel)
        }
    }

    public func setPeers(_ peers: [FlannelPeer]) throws {
        guard let tunnel else {
            throw FlannelVXLANError.runtime("tunnel is not available")
        }
        var values = try peers.map(Self.makePeer)
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            container_vxlan_tunnel_set_peers(
                tunnel,
                buffer.baseAddress,
                buffer.count,
                &errorBuffer,
                errorBuffer.count
            )
        }
        guard status == 0 else {
            throw Self.runtimeError(status: status, buffer: errorBuffer, operation: "update tunnel peers")
        }
    }

    public func start() throws {
        guard let tunnel else {
            throw FlannelVXLANError.runtime("tunnel is not available")
        }
        guard !started else {
            return
        }
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = container_vxlan_tunnel_start(tunnel, &errorBuffer, errorBuffer.count)
        guard status == 0 else {
            throw Self.runtimeError(status: status, buffer: errorBuffer, operation: "start tunnel")
        }
        started = true
    }

    public func stop() {
        guard let tunnel else {
            return
        }
        container_vxlan_tunnel_stop(tunnel)
        started = false
    }

    public func destroy() {
        guard let tunnel else {
            return
        }
        container_vxlan_tunnel_destroy(tunnel)
        self.tunnel = nil
        started = false
    }

    public func statistics() -> FlannelTunnelStatistics {
        guard let tunnel else {
            return FlannelTunnelStatistics(
                transmittedPackets: 0,
                transmittedBytes: 0,
                receivedPackets: 0,
                receivedBytes: 0,
                unknownPeerPackets: 0,
                invalidPackets: 0,
                oversizedPackets: 0,
                sourceCIDRMismatches: 0
            )
        }
        var value = container_vxlan_tunnel_stats_t()
        container_vxlan_tunnel_get_stats(tunnel, &value)
        return FlannelTunnelStatistics(
            transmittedPackets: value.transmitted_packets,
            transmittedBytes: value.transmitted_bytes,
            receivedPackets: value.received_packets,
            receivedBytes: value.received_bytes,
            unknownPeerPackets: value.unknown_peer_packets,
            invalidPackets: value.invalid_packets,
            oversizedPackets: value.oversized_packets,
            sourceCIDRMismatches: value.source_cidr_mismatches
        )
    }

    private static func makeConfiguration(
        _ configuration: FlannelTunnelConfiguration
    ) throws -> container_vxlan_tunnel_config_t {
        guard (1...0x00ff_ffff).contains(configuration.vni),
            (1...65_535).contains(configuration.port),
            (576...9_000).contains(configuration.mtu),
            let localCIDR = FlannelIPv4.parseCIDR(configuration.localPodCIDR),
            let localMAC = macBytes(configuration.localVTEPMAC)
        else {
            throw FlannelVXLANError.invalidConfiguration("invalid tunnel configuration")
        }

        var value = container_vxlan_tunnel_config_t()
        value.vni = UInt32(configuration.vni)
        value.port = UInt16(configuration.port)
        value.mtu = UInt16(configuration.mtu)
        value.bind_ip = try networkOrderIPv4(configuration.bindIP)
        value.local_network = localCIDR.network.bigEndian
        value.local_netmask = prefixMask(localCIDR.prefixLength).bigEndian
        withUnsafeMutableBytes(of: &value.local_vtep_mac) { destination in
            destination.copyBytes(from: localMAC)
        }
        return value
    }

    static func makePeer(_ peer: FlannelPeer) throws -> container_vxlan_peer_t {
        guard let podCIDR = FlannelIPv4.parseCIDR(peer.podCIDR),
            let vtepMAC = macBytes(peer.vtepMAC)
        else {
            throw FlannelVXLANError.invalidNode("invalid tunnel peer \(peer.nodeName)")
        }
        var value = container_vxlan_peer_t()
        value.pod_network = podCIDR.network.bigEndian
        value.pod_netmask = prefixMask(podCIDR.prefixLength).bigEndian
        value.public_ip = try networkOrderIPv4(peer.publicIP)
        value.allow_endpoint_source_mac = peer.operatingSystem?.lowercased() == "windows"
        withUnsafeMutableBytes(of: &value.vtep_mac) { destination in
            destination.copyBytes(from: vtepMAC)
        }
        return value
    }

    private static func networkOrderIPv4(_ value: String) throws -> UInt32 {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else {
            throw FlannelVXLANError.invalidConfiguration("invalid IPv4 address \(value)")
        }
        return address.s_addr
    }

    private static func prefixMask(_ prefixLength: Int) -> UInt32 {
        prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength)
    }

    private static func macBytes(_ value: String) -> [UInt8]? {
        guard let normalized = FlannelVTEPMAC.normalize(value) else {
            return nil
        }
        return normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    }

    private static func runtimeError(
        status: Int32,
        buffer: [CChar],
        operation: String
    ) -> FlannelVXLANError {
        let message = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map(String.init(cString:)) ?? ""
        }
        return .runtime("\(operation) failed with status \(status): \(message)")
    }
}

public final class FlannelIPv6VXLANTunnel: FlannelIPv6TunnelControlling, @unchecked Sendable {
    public let interfaceName: String

    private let vni: Int
    private var tunnel: OpaquePointer?
    private var started = false

    public var isRunning: Bool {
        guard let tunnel else {
            return false
        }
        return container_vxlan_tunnel_v6_is_running(tunnel)
    }

    public init(configuration: FlannelIPv6TunnelConfiguration) throws {
        var cConfiguration = try Self.makeConfiguration(configuration)
        var created: OpaquePointer?
        var interfaceBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = container_vxlan_tunnel_v6_create(
            &cConfiguration,
            &created,
            &interfaceBuffer,
            interfaceBuffer.count,
            &errorBuffer,
            errorBuffer.count
        )
        guard status == 0, let created else {
            throw Self.runtimeError(status: status, buffer: errorBuffer, operation: "create IPv6 tunnel")
        }
        self.vni = configuration.vni
        self.tunnel = created
        let terminator = interfaceBuffer.firstIndex(of: 0) ?? interfaceBuffer.endIndex
        self.interfaceName = String(
            decoding: interfaceBuffer[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    deinit {
        if let tunnel {
            container_vxlan_tunnel_v6_destroy(tunnel)
        }
    }

    public func setPeers(_ peers: [FlannelIPv6Peer]) throws {
        guard let tunnel else {
            throw FlannelVXLANError.runtime("IPv6 tunnel is not available")
        }
        guard peers.allSatisfy({ $0.vni == vni }) else {
            throw FlannelVXLANError.invalidNode("IPv6 tunnel peer VNI does not match local VNI \(vni)")
        }
        var values = try peers.map(Self.makePeer)
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            container_vxlan_tunnel_v6_set_peers(
                tunnel,
                buffer.baseAddress,
                buffer.count,
                &errorBuffer,
                errorBuffer.count
            )
        }
        guard status == 0 else {
            throw Self.runtimeError(status: status, buffer: errorBuffer, operation: "update IPv6 tunnel peers")
        }
    }

    public func start() throws {
        guard let tunnel else {
            throw FlannelVXLANError.runtime("IPv6 tunnel is not available")
        }
        guard !started else {
            return
        }
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = container_vxlan_tunnel_v6_start(tunnel, &errorBuffer, errorBuffer.count)
        guard status == 0 else {
            throw Self.runtimeError(status: status, buffer: errorBuffer, operation: "start IPv6 tunnel")
        }
        started = true
    }

    public func stop() {
        guard let tunnel else {
            return
        }
        container_vxlan_tunnel_v6_stop(tunnel)
        started = false
    }

    public func destroy() {
        guard let tunnel else {
            return
        }
        container_vxlan_tunnel_v6_destroy(tunnel)
        self.tunnel = nil
        started = false
    }

    public func statistics() -> FlannelTunnelStatistics {
        guard let tunnel else {
            return Self.zeroStatistics
        }
        var value = container_vxlan_tunnel_stats_t()
        container_vxlan_tunnel_v6_get_stats(tunnel, &value)
        return FlannelTunnelStatistics(
            transmittedPackets: value.transmitted_packets,
            transmittedBytes: value.transmitted_bytes,
            receivedPackets: value.received_packets,
            receivedBytes: value.received_bytes,
            unknownPeerPackets: value.unknown_peer_packets,
            invalidPackets: value.invalid_packets,
            oversizedPackets: value.oversized_packets,
            sourceCIDRMismatches: value.source_cidr_mismatches
        )
    }

    static func makeConfiguration(
        _ configuration: FlannelIPv6TunnelConfiguration
    ) throws -> container_vxlan_tunnel_config_v6_t {
        guard (1...0x00ff_ffff).contains(configuration.vni),
            (1...65_535).contains(configuration.port),
            (1_280...9_000).contains(configuration.mtu),
            let bindAddress = FlannelIPv6.parseAddress(configuration.bindIPv6),
            bindAddress.isUsableUnderlayAddress,
            let localCIDR = FlannelIPv6.parseCIDR(configuration.localPodCIDR),
            localCIDR.network.isUsableUnderlayAddress,
            let localMAC = macBytes(configuration.localVTEPMAC)
        else {
            throw FlannelVXLANError.invalidConfiguration("invalid IPv6 tunnel configuration")
        }

        var value = container_vxlan_tunnel_config_v6_t()
        value.abi_version = UInt32(CONTAINER_VXLAN_V6_ABI_VERSION)
        value.struct_size = UInt32(MemoryLayout<container_vxlan_tunnel_config_v6_t>.size)
        value.vni = UInt32(configuration.vni)
        value.port = UInt16(configuration.port)
        value.mtu = UInt16(configuration.mtu)
        try copyIPv6(configuration.bindIPv6, into: &value.bind_ip)
        try copyIPv6(localCIDR.baseAddress, into: &value.local_network)
        value.prefix_length = UInt8(localCIDR.prefixLength)
        withUnsafeMutableBytes(of: &value.local_vtep_mac) { destination in
            destination.copyBytes(from: localMAC)
        }
        return value
    }

    static func makePeer(_ peer: FlannelIPv6Peer) throws -> container_vxlan_peer_v6_t {
        guard let podCIDR = FlannelIPv6.parseCIDR(peer.podCIDR),
            podCIDR.network.isUsableUnderlayAddress,
            let publicIPv6 = FlannelIPv6.parseAddress(peer.publicIPv6),
            publicIPv6.isUsableUnderlayAddress,
            let vtepMAC = macBytes(peer.vtepMAC)
        else {
            throw FlannelVXLANError.invalidNode("invalid IPv6 tunnel peer \(peer.nodeName)")
        }

        var value = container_vxlan_peer_v6_t()
        value.abi_version = UInt32(CONTAINER_VXLAN_V6_ABI_VERSION)
        value.struct_size = UInt32(MemoryLayout<container_vxlan_peer_v6_t>.size)
        try copyIPv6(podCIDR.baseAddress, into: &value.pod_network)
        value.prefix_length = UInt8(podCIDR.prefixLength)
        try copyIPv6(publicIPv6.string, into: &value.public_ip)
        withUnsafeMutableBytes(of: &value.vtep_mac) { destination in
            destination.copyBytes(from: vtepMAC)
        }
        return value
    }

    private static var zeroStatistics: FlannelTunnelStatistics {
        FlannelTunnelStatistics(
            transmittedPackets: 0,
            transmittedBytes: 0,
            receivedPackets: 0,
            receivedBytes: 0,
            unknownPeerPackets: 0,
            invalidPackets: 0,
            oversizedPackets: 0,
            sourceCIDRMismatches: 0
        )
    }

    private static func copyIPv6<T>(_ input: String, into output: inout T) throws {
        var address = in6_addr()
        guard inet_pton(AF_INET6, input, &address) == 1 else {
            throw FlannelVXLANError.invalidConfiguration("invalid IPv6 address \(input)")
        }
        let addressBytes = withUnsafeBytes(of: &address) { Array($0) }
        guard MemoryLayout<T>.size == addressBytes.count else {
            throw FlannelVXLANError.invalidConfiguration("invalid IPv6 ABI address width")
        }
        withUnsafeMutableBytes(of: &output) { destination in
            destination.copyBytes(from: addressBytes)
        }
    }

    private static func macBytes(_ value: String) -> [UInt8]? {
        guard let normalized = FlannelVTEPMAC.normalize(value) else {
            return nil
        }
        return normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    }

    private static func runtimeError(
        status: Int32,
        buffer: [CChar],
        operation: String
    ) -> FlannelVXLANError {
        let message = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map(String.init(cString:)) ?? ""
        }
        return .runtime("\(operation) failed with status \(status): \(message)")
    }
}
