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

import Darwin
import Foundation

public struct KubeProxyIPv6Egress: Sendable, Equatable {
    public var interfaceName: String
    public var sourceAddress: String

    public init(interfaceName: String, sourceAddress: String) {
        self.interfaceName = interfaceName
        self.sourceAddress = sourceAddress
    }
}

public protocol KubeProxyIPv6EgressResolving: Sendable {
    func resolveIPv6Egress(
        configuredInterface: String?,
        configuredSourceAddress: String?
    ) throws -> KubeProxyIPv6Egress
}

public struct KubeProxyDefaultIPv6EgressResolver: KubeProxyIPv6EgressResolving {
    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> String
    typealias InterfaceAddressResolver = @Sendable (_ interfaceName: String) throws -> [String]
    typealias AddressReadinessResolver = @Sendable (_ interfaceName: String, _ address: String) throws -> Bool

    private let commandRunner: CommandRunner
    private let interfaceAddressResolver: InterfaceAddressResolver
    private let addressReadinessResolver: AddressReadinessResolver

    public init() {
        self.commandRunner = Self.runProcess
        self.interfaceAddressResolver = Self.interfaceAddresses
        self.addressReadinessResolver = Self.addressIsReady
    }

    init(
        commandRunner: @escaping CommandRunner,
        interfaceAddressResolver: @escaping InterfaceAddressResolver,
        addressReadinessResolver: @escaping AddressReadinessResolver = { _, _ in true }
    ) {
        self.commandRunner = commandRunner
        self.interfaceAddressResolver = interfaceAddressResolver
        self.addressReadinessResolver = addressReadinessResolver
    }

    public func resolveIPv6Egress(
        configuredInterface: String?,
        configuredSourceAddress: String?
    ) throws -> KubeProxyIPv6Egress {
        let interfaceName: String
        if let configuredInterface = normalized(configuredInterface) {
            guard Self.isValidInterfaceName(configuredInterface) else {
                throw KubeProxyMacOSError.applyFailed(
                    "configured IPv6 egress interface is not valid"
                )
            }
            interfaceName = configuredInterface
        } else {
            let output = try commandRunner("/sbin/route", ["-n", "get", "-inet6", "default"])
            interfaceName = try Self.parseDefaultRouteInterface(output)
        }

        let usableAddresses = try Set(
            interfaceAddressResolver(interfaceName).compactMap(Self.usableIPv6Address)
                .filter { try addressReadinessResolver(interfaceName, $0) }
        ).sorted()
        let sourceAddress: String
        if let configuredSourceAddress = normalized(configuredSourceAddress) {
            guard let canonical = Self.usableIPv6Address(configuredSourceAddress) else {
                throw KubeProxyMacOSError.applyFailed(
                    "configured IPv6 egress source address is not usable"
                )
            }
            guard usableAddresses.contains(canonical) else {
                throw KubeProxyMacOSError.applyFailed(
                    "configured IPv6 egress source address is not assigned to \(interfaceName)"
                )
            }
            sourceAddress = canonical
        } else {
            guard usableAddresses.count == 1, let onlyAddress = usableAddresses.first else {
                throw KubeProxyMacOSError.applyFailed(
                    "IPv6 egress interface \(interfaceName) must have exactly one usable non-link-local IPv6 address or an explicit source address"
                )
            }
            sourceAddress = onlyAddress
        }
        return KubeProxyIPv6Egress(
            interfaceName: interfaceName,
            sourceAddress: sourceAddress
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func parseDefaultRouteInterface(_ output: String) throws -> String {
        let interfaces = output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "interface:" else {
                return nil
            }
            return String(fields[1])
        }
        guard interfaces.count == 1, let interfaceName = interfaces.first,
            isValidInterfaceName(interfaceName)
        else {
            throw KubeProxyMacOSError.applyFailed(
                "default IPv6 route did not identify exactly one valid egress interface"
            )
        }
        return interfaceName
    }

    private static func isValidInterfaceName(_ value: String) -> Bool {
        value.utf8.count < Int(IFNAMSIZ)
            && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func usableIPv6Address(_ value: String) -> String? {
        guard !value.contains("%") else {
            return nil
        }
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard
            !bytes.allSatisfy({ $0 == 0 }),
            bytes != Array(repeating: 0, count: 15) + [1],
            !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80),
            bytes[0] != 0xff,
            !(bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff)
        else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func interfaceAddresses(_ interfaceName: String) throws -> [String] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0 else {
            throw KubeProxyMacOSError.applyFailed(
                "failed to inspect IPv6 egress addresses: \(kubeProxyString(decodingCString: strerror(errno)))"
            )
        }
        defer { freeifaddrs(firstAddress) }

        var foundInterface = false
        var interfaceIsUsable = false
        var addresses: [String] = []
        var current = firstAddress
        while let record = current {
            defer { current = record.pointee.ifa_next }
            guard kubeProxyString(decodingCString: record.pointee.ifa_name) == interfaceName else {
                continue
            }
            foundInterface = true
            let flags = Int32(record.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_RUNNING != 0 {
                interfaceIsUsable = true
            }
            guard
                let socketAddress = record.pointee.ifa_addr,
                Int32(socketAddress.pointee.sa_family) == AF_INET6
            else {
                continue
            }
            var address = UnsafeRawPointer(socketAddress)
                .assumingMemoryBound(to: sockaddr_in6.self)
                .pointee.sin6_addr
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
                continue
            }
            addresses.append(
                String(
                    decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                ))
        }
        guard foundInterface, interfaceIsUsable else {
            throw KubeProxyMacOSError.applyFailed(
                "IPv6 egress interface \(interfaceName) is missing or not up and running"
            )
        }
        return addresses
    }

    private static func addressIsReady(interfaceName: String, address: String) throws -> Bool {
        var socketAddress = sockaddr_in6()
        socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        socketAddress.sin6_family = UInt8(AF_INET6)
        guard address.withCString({ inet_pton(AF_INET6, $0, &socketAddress.sin6_addr) }) == 1 else {
            return false
        }

        var request = in6_ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { nameBytes in
            nameBytes.initializeMemory(as: UInt8.self, repeating: 0)
            nameBytes.copyBytes(from: interfaceName.utf8)
        }
        request.ifr_ifru.ifru_addr = socketAddress

        let descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw KubeProxyMacOSError.applyFailed(
                "failed to inspect IPv6 egress address state: \(kubeProxyString(decodingCString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }

        let inputOutput = UInt(0xc000_0000)
        let parameterLength = UInt(MemoryLayout<in6_ifreq>.size & 0x1fff) << 16
        let command = inputOutput | parameterLength | UInt(Character("i").asciiValue!) << 8 | 73
        let result = withUnsafeMutablePointer(to: &request) { requestPointer in
            ioctl(descriptor, command, UnsafeMutableRawPointer(requestPointer))
        }
        guard result == 0 else {
            throw KubeProxyMacOSError.applyFailed(
                "failed to inspect IPv6 egress address state for \(address) on \(interfaceName): \(kubeProxyString(decodingCString: strerror(errno)))"
            )
        }

        let unusableFlags =
            IN6_IFF_TENTATIVE
            | IN6_IFF_OPTIMISTIC
            | IN6_IFF_DUPLICATED
            | IN6_IFF_DETACHED
            | IN6_IFF_DEPRECATED
        return request.ifr_ifru.ifru_flags6 & unusableFlags == 0
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw KubeProxyMacOSError.applyFailed(
                "failed to inspect the default IPv6 route: \(error)"
            )
        }
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw KubeProxyMacOSError.applyFailed(
                "failed to inspect the default IPv6 route with status \(process.terminationStatus): \(message)"
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
