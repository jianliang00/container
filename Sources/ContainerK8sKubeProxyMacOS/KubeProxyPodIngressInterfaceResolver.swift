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

public protocol KubeProxyPodIngressInterfaceResolving: Sendable {
    func resolvePodIngressInterface(
        family: KubeProxyAddressFamily,
        podCIDR: String
    ) throws -> String
}

public struct KubeProxyDefaultPodIngressInterfaceResolver: KubeProxyPodIngressInterfaceResolving {
    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> String
    typealias InterfaceTypeResolver = @Sendable (_ interfaceName: String) throws -> UInt8

    private let commandRunner: CommandRunner
    private let interfaceTypeResolver: InterfaceTypeResolver

    public init() {
        self.commandRunner = Self.runProcess
        self.interfaceTypeResolver = Self.interfaceType
    }

    init(
        commandRunner: @escaping CommandRunner,
        interfaceTypeResolver: @escaping InterfaceTypeResolver
    ) {
        self.commandRunner = commandRunner
        self.interfaceTypeResolver = interfaceTypeResolver
    }

    public func resolvePodIngressInterface(
        family: KubeProxyAddressFamily,
        podCIDR: String
    ) throws -> String {
        let canonicalPodCIDR = try canonicalPodCIDR(family: family, value: podCIDR)
        let probeAddress = try Self.probeAddress(family: family, canonicalPodCIDR: canonicalPodCIDR)
        let familyArgument = family == .ipv4 ? "-inet" : "-inet6"
        let probeOutput = try commandRunner("/sbin/route", ["-n", "get", familyArgument, probeAddress])
        let probeRoute = try Self.parseRoute(probeOutput)
        let networkOutput = try commandRunner("/sbin/route", ["-n", "get", familyArgument, canonicalPodCIDR])
        let networkRoute = try Self.parseRoute(networkOutput)

        guard
            probeRoute.interfaceName == networkRoute.interfaceName,
            !probeRoute.flags.contains("GATEWAY"),
            !networkRoute.flags.contains("GATEWAY")
        else {
            throw KubeProxyMacOSError.applyFailed(
                "local \(family.rawValue) PodCIDR route is not directly connected"
            )
        }
        guard
            let mask = networkRoute.mask,
            let routePrefixLength = Self.maskPrefixLength(mask, family: family),
            Self.canonicalize(
                family: family,
                value: "\(Self.addressWithoutScope(networkRoute.destination))/\(routePrefixLength)"
            ) == canonicalPodCIDR
        else {
            throw KubeProxyMacOSError.applyFailed(
                "route to local \(family.rawValue) PodCIDR does not cover the canonical PodCIDR exactly"
            )
        }
        guard try interfaceTypeResolver(probeRoute.interfaceName) == UInt8(IFT_BRIDGE) else {
            throw KubeProxyMacOSError.applyFailed(
                "local \(family.rawValue) PodCIDR route interface \(probeRoute.interfaceName) is not a bridge"
            )
        }
        return probeRoute.interfaceName
    }

    private func canonicalPodCIDR(
        family: KubeProxyAddressFamily,
        value: String
    ) throws -> String {
        guard let canonical = Self.canonicalize(family: family, value: value), canonical == value else {
            throw KubeProxyMacOSError.applyFailed(
                "local \(family.rawValue) PodCIDR is not canonical"
            )
        }
        return canonical
    }

    private static func canonicalize(
        family: KubeProxyAddressFamily,
        value: String
    ) -> String? {
        switch family {
        case .ipv4:
            KubeProxyIPv4CIDR.canonicalize(value)
        case .ipv6:
            KubeProxyIPv6CIDR.canonicalize(value)
        }
    }

    private static func probeAddress(
        family: KubeProxyAddressFamily,
        canonicalPodCIDR: String
    ) throws -> String {
        let components = canonicalPodCIDR.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, let prefixLength = Int(components[1]) else {
            throw KubeProxyMacOSError.applyFailed("local PodCIDR could not be parsed")
        }

        switch family {
        case .ipv4:
            guard prefixLength <= 30 else {
                throw KubeProxyMacOSError.applyFailed(
                    "local IPv4 PodCIDR must contain a non-gateway probe address"
                )
            }
            var address = in_addr()
            guard String(components[0]).withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
                throw KubeProxyMacOSError.applyFailed("local IPv4 PodCIDR address could not be parsed")
            }
            withUnsafeMutableBytes(of: &address) { bytes in
                bytes[bytes.count - 1] &+= 2
            }
            return try addressString(address)

        case .ipv6:
            guard prefixLength <= 126 else {
                throw KubeProxyMacOSError.applyFailed(
                    "local IPv6 PodCIDR must contain a non-gateway probe address"
                )
            }
            var address = in6_addr()
            guard String(components[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                throw KubeProxyMacOSError.applyFailed("local IPv6 PodCIDR address could not be parsed")
            }
            withUnsafeMutableBytes(of: &address) { bytes in
                bytes[bytes.count - 1] &+= 2
            }
            return try addressString(address)
        }
    }

    private static func addressString(_ value: in_addr) throws -> String {
        var address = value
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            throw KubeProxyMacOSError.applyFailed("PodCIDR probe address could not be formatted")
        }
        return decodedAddressBuffer(buffer)
    }

    private static func addressString(_ value: in6_addr) throws -> String {
        var address = value
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
            throw KubeProxyMacOSError.applyFailed("PodCIDR probe address could not be formatted")
        }
        return decodedAddressBuffer(buffer)
    }

    private static func decodedAddressBuffer(_ buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private struct Route {
        var destination: String
        var mask: String?
        var interfaceName: String
        var flags: Set<String>
    }

    private static func parseRoute(_ output: String) throws -> Route {
        var fields: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            fields[key, default: []].append(value)
        }
        guard
            fields["destination"]?.count == 1,
            fields["interface"]?.count == 1,
            fields["flags"]?.count == 1,
            let destination = fields["destination"]?.first,
            let interfaceName = fields["interface"]?.first,
            let flagsValue = fields["flags"]?.first,
            interfaceName.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        else {
            throw KubeProxyMacOSError.applyFailed(
                "local PodCIDR route did not identify one complete route and valid interface"
            )
        }
        let flags = Set(
            flagsValue
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .split(separator: ",")
                .map(String.init)
        )
        guard flags.contains("UP") else {
            throw KubeProxyMacOSError.applyFailed("local PodCIDR route is not up")
        }
        return Route(
            destination: destination,
            mask: fields["mask"]?.count == 1 ? fields["mask"]?.first : nil,
            interfaceName: interfaceName,
            flags: flags
        )
    }

    private static func maskPrefixLength(
        _ value: String,
        family: KubeProxyAddressFamily
    ) -> Int? {
        switch family {
        case .ipv4:
            if value.hasPrefix("0x"), let mask = UInt32(value.dropFirst(2), radix: 16) {
                return contiguousPrefixLength([
                    UInt8((mask >> 24) & 0xff),
                    UInt8((mask >> 16) & 0xff),
                    UInt8((mask >> 8) & 0xff),
                    UInt8(mask & 0xff),
                ])
            }
            var address = in_addr()
            guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
                return nil
            }
            return withUnsafeBytes(of: &address) { contiguousPrefixLength(Array($0)) }

        case .ipv6:
            var address = in6_addr()
            guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                return nil
            }
            return withUnsafeBytes(of: &address) { contiguousPrefixLength(Array($0)) }
        }
    }

    private static func contiguousPrefixLength(_ bytes: [UInt8]) -> Int? {
        var prefixLength = 0
        var foundZero = false
        for byte in bytes {
            for bit in 0..<8 {
                let isSet = byte & (0x80 >> UInt8(bit)) != 0
                if isSet {
                    guard !foundZero else {
                        return nil
                    }
                    prefixLength += 1
                } else {
                    foundZero = true
                }
            }
        }
        return prefixLength
    }

    private static func addressWithoutScope(_ value: String) -> String {
        String(value.split(separator: "%", maxSplits: 1)[0])
    }

    private static func interfaceType(_ interfaceName: String) throws -> UInt8 {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0 else {
            throw KubeProxyMacOSError.applyFailed(
                "failed to inspect Pod ingress interface type: \(kubeProxyString(decodingCString: strerror(errno)))"
            )
        }
        defer { freeifaddrs(firstAddress) }

        var types: [UInt8] = []
        var current = firstAddress
        while let address = current {
            defer { current = address.pointee.ifa_next }
            guard
                kubeProxyString(decodingCString: address.pointee.ifa_name) == interfaceName,
                let socketAddress = address.pointee.ifa_addr,
                Int32(socketAddress.pointee.sa_family) == AF_LINK
            else {
                continue
            }
            let linkAddress = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_dl.self)
            types.append(linkAddress.pointee.sdl_type)
        }
        guard types.count == 1, let type = types.first else {
            throw KubeProxyMacOSError.applyFailed(
                "Pod ingress interface \(interfaceName) did not identify exactly one link type"
            )
        }
        return type
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
            throw KubeProxyMacOSError.applyFailed("failed to inspect the local PodCIDR route: \(error)")
        }
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw KubeProxyMacOSError.applyFailed(
                "failed to inspect the local PodCIDR route with status \(process.terminationStatus): \(message)"
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
