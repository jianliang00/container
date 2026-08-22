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
import ContainerizationExtras
import Darwin
import Foundation

public enum FlannelHostIPv6GatewayOwnershipPhase: String, Codable, Sendable, Equatable {
    case adding
    case owned
}

public struct FlannelHostIPv6GatewayOwnership: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var networkName: String
    public var networkOwnershipID: String
    public var ipv4PodCIDR: String
    public var ipv6PodCIDR: String
    public var interfaceName: String
    public var ipv4Gateway: String
    public var ipv6Gateway: String
    public var prefixLength: Int
    public var phase: FlannelHostIPv6GatewayOwnershipPhase

    public init(
        networkName: String,
        networkOwnershipID: String,
        ipv4PodCIDR: String,
        ipv6PodCIDR: String,
        interfaceName: String,
        ipv4Gateway: String,
        ipv6Gateway: String,
        prefixLength: Int = 64,
        phase: FlannelHostIPv6GatewayOwnershipPhase = .owned,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.networkName = networkName
        self.networkOwnershipID = networkOwnershipID
        self.ipv4PodCIDR = ipv4PodCIDR
        self.ipv6PodCIDR = ipv6PodCIDR
        self.interfaceName = interfaceName
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Gateway = ipv6Gateway
        self.prefixLength = prefixLength
        self.phase = phase
    }

    fileprivate func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FlannelVXLANError.persistence("unsupported host IPv6 gateway ownership schema version \(schemaVersion)")
        }
        guard !networkName.isEmpty, !networkName.contains("/"), !networkName.contains(where: \.isWhitespace) else {
            throw FlannelVXLANError.persistence("host IPv6 gateway ownership contains an invalid network name")
        }
        guard UUID(uuidString: networkOwnershipID)?.uuidString.lowercased() == networkOwnershipID.lowercased() else {
            throw FlannelVXLANError.persistence("host IPv6 gateway ownership contains an invalid network ownership ID")
        }
        guard !interfaceName.isEmpty,
            interfaceName.utf8.count < Int(IFNAMSIZ),
            !interfaceName.contains("/"),
            !interfaceName.contains(where: \.isWhitespace)
        else {
            throw FlannelVXLANError.persistence("host IPv6 gateway ownership contains an invalid interface name")
        }
        guard let ipv4CIDR = FlannelIPv4.parseCIDR(ipv4PodCIDR),
            ipv4CIDR.string == ipv4PodCIDR,
            ipv4CIDR.network < UInt32.max,
            let parsedIPv4Gateway = FlannelIPv4.parseAddress(ipv4Gateway),
            parsedIPv4Gateway == ipv4CIDR.network + 1
        else {
            throw FlannelVXLANError.persistence("host IPv6 gateway ownership contains an invalid IPv4 network or gateway")
        }
        guard let ipv6CIDR = FlannelIPv6.parseCIDR(ipv6PodCIDR),
            ipv6CIDR.prefixLength == 64,
            ipv6CIDR.string == ipv6PodCIDR,
            ipv6CIDR.network.isUsableUnderlayAddress,
            let parsedIPv6Gateway = FlannelIPv6.parseAddress(ipv6Gateway),
            let expectedIPv6Gateway = try? IPv6Address(ipv6CIDR.network.string),
            parsedIPv6Gateway.string == IPv6Address(expectedIPv6Gateway.value + 1).description,
            prefixLength == 64
        else {
            throw FlannelVXLANError.persistence("host IPv6 gateway ownership contains an invalid IPv6 network or gateway")
        }
        return Self(
            networkName: networkName,
            networkOwnershipID: networkOwnershipID.lowercased(),
            ipv4PodCIDR: ipv4CIDR.string,
            ipv6PodCIDR: ipv6CIDR.string,
            interfaceName: interfaceName,
            ipv4Gateway: IPv4Address(parsedIPv4Gateway).description,
            ipv6Gateway: parsedIPv6Gateway.string,
            prefixLength: prefixLength,
            phase: phase
        )
    }
}

public protocol FlannelHostIPv6GatewayOwnershipStoring: Sendable {
    func load() throws -> FlannelHostIPv6GatewayOwnership?
    func save(_ ownership: FlannelHostIPv6GatewayOwnership) throws
    func remove() throws
}

public struct FlannelHostIPv6GatewayOwnershipStore: FlannelHostIPv6GatewayOwnershipStoring, Sendable {
    public let url: URL

    public init(path: String) {
        self.url = URL(fileURLWithPath: path)
    }

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> FlannelHostIPv6GatewayOwnership? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let value = try JSONDecoder().decode(
                FlannelHostIPv6GatewayOwnership.self,
                from: Data(contentsOf: url)
            )
            return try value.validated()
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence("failed to read host IPv6 gateway ownership at \(url.path): \(error)")
        }
    }

    public func save(_ ownership: FlannelHostIPv6GatewayOwnership) throws {
        let ownership = try ownership.validated()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(ownership).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence("failed to write host IPv6 gateway ownership at \(url.path): \(error)")
        }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FlannelVXLANError.persistence("failed to remove host IPv6 gateway ownership at \(url.path): \(error)")
        }
    }
}

public enum FlannelHostIPv6GatewayReconcileResult: Sendable, Equatable {
    case bridgePending
    case dadPending(FlannelHostIPv6GatewayOwnership)
    case ready(FlannelHostIPv6GatewayOwnership)
}

public protocol FlannelHostIPv6GatewayManaging: Sendable {
    func reconcile(
        networkOwnership: FlannelHostOnlyNetworkOwnership,
        knownOwnership: FlannelHostIPv6GatewayOwnership?
    ) throws -> FlannelHostIPv6GatewayReconcileResult

    func remove(ownership: FlannelHostIPv6GatewayOwnership) throws
}

struct FlannelHostInterfaceAddress: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case link(type: UInt8)
        case ipv4(IPv4Address)
        case ipv6(IPv6Address, prefixLength: UInt8)
    }

    var interfaceName: String
    var value: Value
}

public struct SystemFlannelHostIPv6GatewayManager: FlannelHostIPv6GatewayManaging {
    enum AddressState: Equatable {
        case absent
        case present
    }

    typealias AddressSnapshotProvider = @Sendable () throws -> [FlannelHostInterfaceAddress]
    typealias AddressMutator = @Sendable (_ interfaceName: String, _ address: IPv6Address, _ prefixLength: UInt8) -> Int32
    typealias FlagsProvider = @Sendable (_ interfaceName: String, _ address: IPv6Address) -> (status: Int32, flags: UInt32)

    private let addressSnapshotProvider: AddressSnapshotProvider
    private let addAddress: AddressMutator
    private let removeAddress: AddressMutator
    private let flagsProvider: FlagsProvider
    private let ownershipStore: any FlannelHostIPv6GatewayOwnershipStoring

    public init(ownershipStore: any FlannelHostIPv6GatewayOwnershipStoring) {
        self.ownershipStore = ownershipStore
        self.addressSnapshotProvider = Self.readHostInterfaceAddresses
        self.addAddress = { interfaceName, address, prefixLength in
            Int32(
                interfaceName.withCString { name in
                    address.bytes.withUnsafeBufferPointer { bytes in
                        container_flannel_ipv6_gateway_add(name, bytes.baseAddress, prefixLength)
                    }
                })
        }
        self.removeAddress = { interfaceName, address, _ in
            Int32(
                interfaceName.withCString { name in
                    address.bytes.withUnsafeBufferPointer { bytes in
                        container_flannel_ipv6_gateway_remove(name, bytes.baseAddress)
                    }
                })
        }
        self.flagsProvider = { interfaceName, address in
            var flags: UInt32 = 0
            let status = Int32(
                interfaceName.withCString { name in
                    address.bytes.withUnsafeBufferPointer { bytes in
                        container_flannel_ipv6_gateway_flags(name, bytes.baseAddress, &flags)
                    }
                })
            return (status, flags)
        }
    }

    init(
        ownershipStore: any FlannelHostIPv6GatewayOwnershipStoring,
        addressSnapshotProvider: @escaping AddressSnapshotProvider,
        addAddress: @escaping AddressMutator,
        removeAddress: @escaping AddressMutator,
        flagsProvider: @escaping FlagsProvider
    ) {
        self.ownershipStore = ownershipStore
        self.addressSnapshotProvider = addressSnapshotProvider
        self.addAddress = addAddress
        self.removeAddress = removeAddress
        self.flagsProvider = flagsProvider
    }

    public func reconcile(
        networkOwnership: FlannelHostOnlyNetworkOwnership,
        knownOwnership: FlannelHostIPv6GatewayOwnership?
    ) throws -> FlannelHostIPv6GatewayReconcileResult {
        guard try ownershipStore.load() == knownOwnership else {
            throw FlannelVXLANError.persistence("host IPv6 gateway ownership changed during reconciliation")
        }
        let intent = try Self.intent(networkOwnership: networkOwnership)
        if let knownOwnership {
            try Self.validate(knownOwnership: knownOwnership, matches: intent)
        }

        let initial = try addressSnapshotProvider()
        guard let interfaceName = try Self.resolveBridge(owning: intent.ipv4Gateway, addresses: initial) else {
            return .bridgePending
        }
        let currentOwnership = intent.ownership(interfaceName: interfaceName, phase: .owned)
        let state = try Self.addressState(
            interfaceName: interfaceName,
            address: intent.ipv6Gateway,
            prefixLength: intent.prefixLength,
            addresses: initial
        )
        switch state {
        case .present:
            guard let knownOwnership,
                Self.sameResource(knownOwnership, currentOwnership)
            else {
                throw FlannelVXLANError.runtime(
                    "refusing to adopt unowned host IPv6 gateway \(intent.ipv6Gateway) on \(interfaceName)"
                )
            }
            if knownOwnership.phase == .adding {
                try ownershipStore.save(currentOwnership)
            }
        case .absent:
            let addingOwnership = intent.ownership(interfaceName: interfaceName, phase: .adding)
            try ownershipStore.save(addingOwnership)
            let status = addAddress(interfaceName, intent.ipv6Gateway, intent.prefixLength)
            guard status == 0 else {
                let readback = try addressSnapshotProvider()
                if try Self.addressState(
                    interfaceName: interfaceName,
                    address: intent.ipv6Gateway,
                    prefixLength: intent.prefixLength,
                    addresses: readback
                ) == .present {
                    try ownershipStore.save(currentOwnership)
                    return try readiness(ownership: currentOwnership)
                }
                throw Self.ioctlError(operation: "add", status: status, ownership: currentOwnership)
            }
            do {
                let readback = try addressSnapshotProvider()
                guard
                    try Self.addressState(
                        interfaceName: interfaceName,
                        address: intent.ipv6Gateway,
                        prefixLength: intent.prefixLength,
                        addresses: readback
                    ) == .present
                else {
                    throw FlannelVXLANError.runtime("host IPv6 gateway is absent after a successful add")
                }
            } catch {
                let verificationError = error
                let rollbackStatus = removeAddress(interfaceName, intent.ipv6Gateway, intent.prefixLength)
                do {
                    let rollbackReadback = try addressSnapshotProvider()
                    guard
                        try Self.addressState(
                            interfaceName: interfaceName,
                            address: intent.ipv6Gateway,
                            prefixLength: intent.prefixLength,
                            addresses: rollbackReadback
                        ) == .absent
                    else {
                        throw FlannelVXLANError.runtime(
                            "host IPv6 gateway remained after rollback with errno \(rollbackStatus)"
                        )
                    }
                } catch {
                    throw FlannelVXLANError.runtime(
                        "host IPv6 gateway verification failed: \(verificationError); "
                            + "rollback could not be verified after errno \(rollbackStatus): \(error); "
                            + "write-ahead ownership was retained"
                    )
                }
                if let knownOwnership {
                    try ownershipStore.save(knownOwnership)
                } else {
                    try ownershipStore.remove()
                }
                throw verificationError
            }
            try ownershipStore.save(currentOwnership)
        }
        return try readiness(ownership: currentOwnership)
    }

    public func remove(ownership: FlannelHostIPv6GatewayOwnership) throws {
        let ownership = try ownership.validated()
        let ipv4Gateway = try IPv4Address(ownership.ipv4Gateway)
        let ipv6Gateway = try IPv6Address(ownership.ipv6Gateway)
        let addresses = try addressSnapshotProvider()
        let state = try Self.addressState(
            interfaceName: ownership.interfaceName,
            address: ipv6Gateway,
            prefixLength: UInt8(ownership.prefixLength),
            addresses: addresses
        )
        guard state == .present else {
            return
        }
        guard try Self.resolveBridge(owning: ipv4Gateway, addresses: addresses) == ownership.interfaceName else {
            throw FlannelVXLANError.runtime("refusing to remove host IPv6 gateway because its vmnet bridge ownership changed")
        }
        let status = removeAddress(ownership.interfaceName, ipv6Gateway, UInt8(ownership.prefixLength))
        if status != 0 {
            let readback = try addressSnapshotProvider()
            guard
                try Self.addressState(
                    interfaceName: ownership.interfaceName,
                    address: ipv6Gateway,
                    prefixLength: UInt8(ownership.prefixLength),
                    addresses: readback
                ) == .absent
            else {
                throw Self.ioctlError(operation: "remove", status: status, ownership: ownership)
            }
            return
        }
        let readback = try addressSnapshotProvider()
        guard
            try Self.addressState(
                interfaceName: ownership.interfaceName,
                address: ipv6Gateway,
                prefixLength: UInt8(ownership.prefixLength),
                addresses: readback
            ) == .absent
        else {
            throw FlannelVXLANError.runtime("host IPv6 gateway remained after removal")
        }
    }

    private func readiness(
        ownership: FlannelHostIPv6GatewayOwnership
    ) throws -> FlannelHostIPv6GatewayReconcileResult {
        let address = try IPv6Address(ownership.ipv6Gateway)
        let result = flagsProvider(ownership.interfaceName, address)
        guard result.status == 0 else {
            throw Self.ioctlError(operation: "inspect flags for", status: result.status, ownership: ownership)
        }
        if container_flannel_ipv6_gateway_is_duplicated(result.flags) {
            let removeStatus = removeAddress(ownership.interfaceName, address, UInt8(ownership.prefixLength))
            guard removeStatus == 0 else {
                throw FlannelVXLANError.runtime(
                    "host IPv6 gateway failed duplicate address detection and rollback failed with errno \(removeStatus)"
                )
            }
            throw FlannelVXLANError.runtime("host IPv6 gateway \(address) failed duplicate address detection")
        }
        if container_flannel_ipv6_gateway_is_tentative(result.flags) {
            return .dadPending(ownership)
        }
        return .ready(ownership)
    }

    private struct Intent {
        var networkName: String
        var networkOwnershipID: String
        var ipv4PodCIDR: String
        var ipv6PodCIDR: String
        var ipv4Gateway: IPv4Address
        var ipv6Gateway: IPv6Address
        var prefixLength: UInt8

        func ownership(
            interfaceName: String,
            phase: FlannelHostIPv6GatewayOwnershipPhase
        ) -> FlannelHostIPv6GatewayOwnership {
            FlannelHostIPv6GatewayOwnership(
                networkName: networkName,
                networkOwnershipID: networkOwnershipID,
                ipv4PodCIDR: ipv4PodCIDR,
                ipv6PodCIDR: ipv6PodCIDR,
                interfaceName: interfaceName,
                ipv4Gateway: ipv4Gateway.description,
                ipv6Gateway: ipv6Gateway.description,
                prefixLength: Int(prefixLength),
                phase: phase
            )
        }
    }

    private static func intent(networkOwnership: FlannelHostOnlyNetworkOwnership) throws -> Intent {
        guard let ipv6PodCIDR = networkOwnership.ipv6PodCIDR,
            let ipv4CIDR = FlannelIPv4.parseCIDR(networkOwnership.podCIDR),
            ipv4CIDR.string == networkOwnership.podCIDR,
            ipv4CIDR.network < UInt32.max,
            let ipv6CIDR = FlannelIPv6.parseCIDR(ipv6PodCIDR),
            ipv6CIDR.string == ipv6PodCIDR,
            ipv6CIDR.prefixLength == 64,
            ipv6CIDR.network.isUsableUnderlayAddress
        else {
            throw FlannelVXLANError.runtime("host IPv6 gateway requires an owned canonical host-only dual-stack /64 network")
        }
        let networkAddress = try IPv6Address(ipv6CIDR.network.string)
        return Intent(
            networkName: networkOwnership.name,
            networkOwnershipID: networkOwnership.ownershipID.lowercased(),
            ipv4PodCIDR: ipv4CIDR.string,
            ipv6PodCIDR: ipv6CIDR.string,
            ipv4Gateway: IPv4Address(ipv4CIDR.network + 1),
            ipv6Gateway: IPv6Address(networkAddress.value + 1),
            prefixLength: 64
        )
    }

    private static func validate(
        knownOwnership: FlannelHostIPv6GatewayOwnership,
        matches intent: Intent
    ) throws {
        let knownOwnership = try knownOwnership.validated()
        guard knownOwnership.networkName == intent.networkName,
            knownOwnership.networkOwnershipID == intent.networkOwnershipID,
            knownOwnership.ipv4PodCIDR == intent.ipv4PodCIDR,
            knownOwnership.ipv6PodCIDR == intent.ipv6PodCIDR,
            knownOwnership.ipv4Gateway == intent.ipv4Gateway.description,
            knownOwnership.ipv6Gateway == intent.ipv6Gateway.description,
            knownOwnership.prefixLength == Int(intent.prefixLength)
        else {
            throw FlannelVXLANError.runtime("host IPv6 gateway ownership does not match the current Pod network")
        }
    }

    private static func sameResource(
        _ lhs: FlannelHostIPv6GatewayOwnership,
        _ rhs: FlannelHostIPv6GatewayOwnership
    ) -> Bool {
        lhs.networkName == rhs.networkName
            && lhs.networkOwnershipID == rhs.networkOwnershipID
            && lhs.ipv4PodCIDR == rhs.ipv4PodCIDR
            && lhs.ipv6PodCIDR == rhs.ipv6PodCIDR
            && lhs.interfaceName == rhs.interfaceName
            && lhs.ipv4Gateway == rhs.ipv4Gateway
            && lhs.ipv6Gateway == rhs.ipv6Gateway
            && lhs.prefixLength == rhs.prefixLength
    }

    private static func resolveBridge(
        owning ipv4Gateway: IPv4Address,
        addresses: [FlannelHostInterfaceAddress]
    ) throws -> String? {
        let gatewayInterfaces = Set(
            addresses.compactMap { entry -> String? in
                guard case .ipv4(let address) = entry.value, address == ipv4Gateway else { return nil }
                return entry.interfaceName
            })
        guard !gatewayInterfaces.isEmpty else {
            return nil
        }
        let bridgeInterfaces = Set(
            addresses.compactMap { entry -> String? in
                guard case .link(let type) = entry.value, type == UInt8(IFT_BRIDGE) else { return nil }
                return entry.interfaceName
            })
        let matchingBridges = gatewayInterfaces.intersection(bridgeInterfaces)
        guard gatewayInterfaces == matchingBridges,
            matchingBridges.count == 1,
            let interfaceName = matchingBridges.first
        else {
            throw FlannelVXLANError.runtime(
                "IPv4 gateway \(ipv4Gateway) must belong to exactly one vmnet bridge"
            )
        }
        return interfaceName
    }

    private static func addressState(
        interfaceName: String,
        address: IPv6Address,
        prefixLength: UInt8,
        addresses: [FlannelHostInterfaceAddress]
    ) throws -> AddressState {
        let matches = addresses.compactMap { entry -> (String, UInt8)? in
            guard case .ipv6(let currentAddress, let currentPrefixLength) = entry.value,
                currentAddress == address
            else { return nil }
            return (entry.interfaceName, currentPrefixLength)
        }
        guard matches.allSatisfy({ $0.0 == interfaceName && $0.1 == prefixLength }) else {
            throw FlannelVXLANError.runtime(
                "host IPv6 gateway \(address) exists with a conflicting interface or prefix"
            )
        }
        return matches.isEmpty ? .absent : .present
    }

    private static func ioctlError(
        operation: String,
        status: Int32,
        ownership: FlannelHostIPv6GatewayOwnership
    ) -> FlannelVXLANError {
        let detail: String
        if let errorPointer = strerror(status) {
            let bytes = UnsafeRawPointer(errorPointer).assumingMemoryBound(to: UInt8.self)
            detail = String(
                decoding: UnsafeBufferPointer(start: bytes, count: strlen(errorPointer)),
                as: UTF8.self
            )
        } else {
            detail = "unknown error"
        }
        return .runtime(
            "failed to \(operation) host IPv6 gateway \(ownership.ipv6Gateway) on \(ownership.interfaceName): errno \(status) (\(detail))"
        )
    }

    private static func readHostInterfaceAddresses() throws -> [FlannelHostInterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else {
            throw FlannelVXLANError.runtime("failed to inspect host interfaces: errno \(errno)")
        }
        defer { freeifaddrs(first) }

        var result: [FlannelHostInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let socketAddress = current.pointee.ifa_addr else { continue }
            let interfaceName = Self.interfaceName(current.pointee.ifa_name)
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_LINK:
                guard let interfaceData = current.pointee.ifa_data else { continue }
                result.append(
                    FlannelHostInterfaceAddress(
                        interfaceName: interfaceName,
                        value: .link(type: interfaceData.assumingMemoryBound(to: if_data.self).pointee.ifi_type)
                    ))
            case AF_INET:
                let address = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                result.append(
                    FlannelHostInterfaceAddress(
                        interfaceName: interfaceName,
                        value: .ipv4(IPv4Address(UInt32(bigEndian: address.s_addr)))
                    ))
            case AF_INET6:
                guard let netmask = current.pointee.ifa_netmask else {
                    throw FlannelVXLANError.runtime("host IPv6 address on \(interfaceName) has no netmask")
                }
                let address = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let mask = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let bytes = withUnsafeBytes(of: address.__u6_addr.__u6_addr8) { Array($0) }
                result.append(
                    FlannelHostInterfaceAddress(
                        interfaceName: interfaceName,
                        value: .ipv6(try IPv6Address(bytes), prefixLength: try ipv6PrefixLength(mask))
                    ))
            default:
                continue
            }
        }
        return result
    }

    private static func ipv6PrefixLength(_ netmask: in6_addr) throws -> UInt8 {
        let bytes = withUnsafeBytes(of: netmask.__u6_addr.__u6_addr8) { Array($0) }
        var length = 0
        var foundZero = false
        for byte in bytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                if byte & (1 << bit) != 0 {
                    guard !foundZero else {
                        throw FlannelVXLANError.runtime("host IPv6 address has a non-contiguous netmask")
                    }
                    length += 1
                } else {
                    foundZero = true
                }
            }
        }
        return UInt8(length)
    }

    private static func interfaceName(_ pointer: UnsafeMutablePointer<CChar>) -> String {
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(IFNAMSIZ))
        let length = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes.prefix(length), as: UTF8.self)
    }
}
