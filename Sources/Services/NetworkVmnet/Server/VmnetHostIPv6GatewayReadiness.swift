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

import ContainerizationError
import ContainerizationExtras
import Darwin
import Foundation

enum VmnetHostIPv6GatewayReadiness: Equatable, Sendable {
    case pending
    case ready
}

enum VmnetHostIPv6GatewayReadinessError: Error, Equatable, Sendable {
    case bridgeNotReady(IPv4Address)
}

protocol VmnetHostIPv6GatewayReadinessChecking: Sendable {
    func readiness(
        ipv4Gateway: IPv4Address,
        ipv6Gateway: IPv6Address,
        prefixLength: UInt8
    ) throws -> VmnetHostIPv6GatewayReadiness
}

struct VmnetHostIPv6GatewayWaiter: Sendable {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let checker: any VmnetHostIPv6GatewayReadinessChecking
    private let maxAttempts: Int
    private let retryInterval: Duration
    private let sleep: Sleep

    init(
        checker: any VmnetHostIPv6GatewayReadinessChecking,
        maxAttempts: Int = 60,
        retryInterval: Duration = .milliseconds(200),
        sleep: @escaping Sleep = { duration in try await ContinuousClock().sleep(for: duration) }
    ) {
        self.checker = checker
        self.maxAttempts = maxAttempts
        self.retryInterval = retryInterval
        self.sleep = sleep
    }

    func wait(
        ipv4Gateway: IPv4Address,
        ipv6Gateway: IPv6Address,
        prefixLength: UInt8
    ) async throws {
        guard maxAttempts > 0 else {
            throw ContainerizationError(.invalidArgument, message: "host IPv6 gateway wait requires at least one attempt")
        }
        for attempt in 1...maxAttempts {
            do {
                switch try checker.readiness(
                    ipv4Gateway: ipv4Gateway,
                    ipv6Gateway: ipv6Gateway,
                    prefixLength: prefixLength
                ) {
                case .ready:
                    return
                case .pending:
                    break
                }
            } catch VmnetHostIPv6GatewayReadinessError.bridgeNotReady {
                // A reserved network bridge appears only after its first VM
                // interface starts. Flannel converges the gateway afterwards.
            }
            guard attempt < maxAttempts else {
                throw ContainerizationError(
                    .invalidState,
                    message: "vmnet host IPv6 gateway \(ipv6Gateway) did not become ready after VM attachment"
                )
            }
            try await sleep(retryInterval)
        }
    }
}

struct VmnetHostInterfaceAddress: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case link(type: UInt8)
        case ipv4(IPv4Address)
        case ipv6(IPv6Address, prefixLength: UInt8)
    }

    let interfaceName: String
    let value: Value
}

struct SystemVmnetHostIPv6GatewayReadinessChecker: VmnetHostIPv6GatewayReadinessChecking {
    typealias AddressSnapshotProvider = @Sendable () throws -> [VmnetHostInterfaceAddress]
    typealias InterfaceReadinessProvider = @Sendable (_ interfaceName: String, _ address: IPv6Address) throws -> VmnetHostIPv6GatewayReadiness

    private let addressSnapshotProvider: AddressSnapshotProvider
    private let interfaceReadinessProvider: InterfaceReadinessProvider

    init() {
        self.addressSnapshotProvider = Self.readHostInterfaceAddresses
        self.interfaceReadinessProvider = Self.readGatewayReadiness
    }

    init(
        addressSnapshotProvider: @escaping AddressSnapshotProvider,
        interfaceReadinessProvider: @escaping InterfaceReadinessProvider = Self.readGatewayReadiness
    ) {
        self.addressSnapshotProvider = addressSnapshotProvider
        self.interfaceReadinessProvider = interfaceReadinessProvider
    }

    func readiness(
        ipv4Gateway: IPv4Address,
        ipv6Gateway: IPv6Address,
        prefixLength: UInt8
    ) throws -> VmnetHostIPv6GatewayReadiness {
        let addresses = try addressSnapshotProvider()
        let interfaceName = try Self.resolveInterface(owning: ipv4Gateway, addresses: addresses)
        let matches = addresses.compactMap { entry -> (String, UInt8)? in
            guard case .ipv6(let address, let currentPrefixLength) = entry.value,
                address == ipv6Gateway
            else {
                return nil
            }
            return (entry.interfaceName, currentPrefixLength)
        }
        guard matches.allSatisfy({ $0.0 == interfaceName && $0.1 == prefixLength }) else {
            throw ContainerizationError(
                .invalidState,
                message: "vmnet host IPv6 gateway \(ipv6Gateway) exists with a conflicting interface or prefix"
            )
        }
        guard !matches.isEmpty else {
            return .pending
        }
        return try interfaceReadinessProvider(interfaceName, ipv6Gateway)
    }

    private static func resolveInterface(
        owning ipv4Gateway: IPv4Address,
        addresses: [VmnetHostInterfaceAddress]
    ) throws -> String {
        let gatewayInterfaces = Set(
            addresses.compactMap { entry -> String? in
                guard case .ipv4(let address) = entry.value, address == ipv4Gateway else {
                    return nil
                }
                return entry.interfaceName
            })
        guard !gatewayInterfaces.isEmpty else {
            throw VmnetHostIPv6GatewayReadinessError.bridgeNotReady(ipv4Gateway)
        }
        let bridgeInterfaces = Set(
            addresses.compactMap { entry -> String? in
                guard case .link(let type) = entry.value, type == UInt8(IFT_BRIDGE) else {
                    return nil
                }
                return entry.interfaceName
            })
        let matchingBridges = gatewayInterfaces.intersection(bridgeInterfaces)
        guard gatewayInterfaces == matchingBridges,
            matchingBridges.count == 1,
            let interfaceName = matchingBridges.first
        else {
            throw ContainerizationError(
                .invalidState,
                message: "vmnet IPv4 gateway \(ipv4Gateway) must belong to exactly one host bridge"
            )
        }
        return interfaceName
    }

    private static func readHostInterfaceAddresses() throws -> [VmnetHostInterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else {
            throw ContainerizationError(.internalError, message: "failed to inspect host interfaces: errno \(errno)")
        }
        defer { freeifaddrs(first) }

        var result: [VmnetHostInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let socketAddress = current.pointee.ifa_addr else {
                continue
            }
            let interfaceName = Self.interfaceName(current.pointee.ifa_name)
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_LINK:
                guard let interfaceData = current.pointee.ifa_data else {
                    continue
                }
                result.append(
                    VmnetHostInterfaceAddress(
                        interfaceName: interfaceName,
                        value: .link(type: interfaceData.assumingMemoryBound(to: if_data.self).pointee.ifi_type)
                    ))
            case AF_INET:
                let address = UnsafeRawPointer(socketAddress)
                    .assumingMemoryBound(to: sockaddr_in.self)
                    .pointee.sin_addr
                result.append(
                    VmnetHostInterfaceAddress(
                        interfaceName: interfaceName,
                        value: .ipv4(IPv4Address(UInt32(bigEndian: address.s_addr)))
                    ))
            case AF_INET6:
                guard let netmask = current.pointee.ifa_netmask else {
                    throw ContainerizationError(.invalidState, message: "host IPv6 address on \(interfaceName) has no netmask")
                }
                let socketAddressV6 = UnsafeRawPointer(socketAddress)
                    .assumingMemoryBound(to: sockaddr_in6.self).pointee
                let netmaskV6 = UnsafeRawPointer(netmask)
                    .assumingMemoryBound(to: sockaddr_in6.self).pointee
                let bytes = withUnsafeBytes(of: socketAddressV6.sin6_addr.__u6_addr.__u6_addr8) { Array($0) }
                result.append(
                    VmnetHostInterfaceAddress(
                        interfaceName: interfaceName,
                        value: .ipv6(
                            try IPv6Address(bytes),
                            prefixLength: try ipv6PrefixLength(netmaskV6.sin6_addr)
                        )
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
                        throw ContainerizationError(.invalidState, message: "host IPv6 address has a non-contiguous netmask")
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

    static func gatewayReadiness(
        fromIfconfigOutput output: String,
        address: IPv6Address
    ) throws -> VmnetHostIPv6GatewayReadiness {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "inet6" else {
                continue
            }
            let addressText = fields[1].split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
            guard let candidate = try? IPv6Address(addressText), candidate == address else {
                continue
            }
            let flags = Set(fields.dropFirst(2).map(String.init))
            if flags.contains("duplicated") {
                throw ContainerizationError(
                    .invalidState,
                    message: "vmnet host IPv6 gateway \(address) failed duplicate address detection"
                )
            }
            return flags.contains("tentative") ? .pending : .ready
        }
        return .pending
    }

    private static func readGatewayReadiness(
        interfaceName: String,
        address: IPv6Address
    ) throws -> VmnetHostIPv6GatewayReadiness {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [interfaceName]
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ContainerizationError(.internalError, message: "failed to inspect vmnet host IPv6 gateway: \(error)")
        }
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ContainerizationError(
                .internalError,
                message: "failed to inspect vmnet host IPv6 gateway on \(interfaceName): \(message)"
            )
        }
        return try gatewayReadiness(fromIfconfigOutput: String(decoding: output, as: UTF8.self), address: address)
    }
}
