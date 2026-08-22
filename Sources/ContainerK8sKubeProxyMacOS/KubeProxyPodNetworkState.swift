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

struct KubeProxyPodNetworkRuntimeState: Decodable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var networkName: String
    var podCIDRs: KubeProxyPodNetworkCIDRs
    var generation: UInt64

    var podCIDR: String { podCIDRs.ipv4 }

    private enum CodingKeys: String, CodingKey {
        case networkName
        case podCIDR
        case podCIDRs
        case generation
        case schemaVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported pod network runtime state schema version \(schemaVersion)"
            )
        }
        networkName = try container.decode(String.self, forKey: .networkName)
        podCIDRs = try decodePodNetworkCIDRs(from: container)
        generation = try container.decode(UInt64.self, forKey: .generation)
    }
}

struct KubeProxyPodNetworkReadyState: Decodable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var networkName: String
    var podCIDRs: KubeProxyPodNetworkCIDRs
    var ipv4Ready: Bool
    var ipv6Ready: Bool?
    var runtimeGeneration: UInt64
    var expiresAtUnixSeconds: Int64

    var podCIDR: String { podCIDRs.ipv4 }

    private enum CodingKeys: String, CodingKey {
        case networkName
        case podCIDR
        case podCIDRs
        case ipv4Ready
        case ipv6Ready
        case runtimeGeneration
        case expiresAtUnixSeconds
        case schemaVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported pod network ready state schema version \(schemaVersion)"
            )
        }
        networkName = try container.decode(String.self, forKey: .networkName)
        podCIDRs = try decodePodNetworkCIDRs(from: container)
        ipv4Ready = try container.decodeIfPresent(Bool.self, forKey: .ipv4Ready) ?? true
        ipv6Ready = try container.decodeIfPresent(Bool.self, forKey: .ipv6Ready)
        runtimeGeneration = try container.decode(UInt64.self, forKey: .runtimeGeneration)
        expiresAtUnixSeconds = try container.decode(Int64.self, forKey: .expiresAtUnixSeconds)
    }
}

struct KubeProxyPodNetworkCIDRs: Decodable, Equatable {
    var ipv4: String
    var ipv6: String?
}

struct KubeProxyPodNetworkResolution: Equatable {
    var ipv4PodCIDR: String
    var ipv6PodCIDR: String?
    var ipv4Ready: Bool
    var ipv6Ready: Bool
    var masqueradeIPv4PodTraffic: Bool
    var masqueradeIPv6PodTraffic: Bool

    var podCIDR: String { ipv4PodCIDR }
    var masqueradePodTraffic: Bool { masqueradeIPv4PodTraffic }
}

enum KubeProxyPodNetworkStateResolver {
    static func resolve(
        config: KubeProxyMacOSConfig,
        fileManager: FileManager = .default,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> KubeProxyPodNetworkResolution {
        try resolve(
            pfConfig: config.pf,
            dualStackEnabled: config.dualStackEnabled,
            masqueradeIPv6PodTraffic: config.pf.resolvedMasqueradeIPv6PodTraffic,
            fileManager: fileManager,
            decoder: decoder
        )
    }

    static func resolve(
        config: KubeProxyPFConfig,
        fileManager: FileManager = .default,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> KubeProxyPodNetworkResolution {
        try resolve(
            pfConfig: config,
            dualStackEnabled: false,
            masqueradeIPv6PodTraffic: false,
            fileManager: fileManager,
            decoder: decoder
        )
    }

    private static func resolve(
        pfConfig config: KubeProxyPFConfig,
        dualStackEnabled: Bool,
        masqueradeIPv6PodTraffic: Bool,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) throws -> KubeProxyPodNetworkResolution {
        guard let runtimeStatePath = normalizedPath(config.runtimeStatePath) else {
            guard normalizedPath(config.readyStatePath) == nil else {
                throw KubeProxyMacOSError.applyFailed("pod network runtime state path is not configured")
            }
            guard !dualStackEnabled else {
                throw KubeProxyMacOSError.applyFailed(
                    "dual-stack pod networking requires runtime and ready state paths"
                )
            }
            guard let podCIDR = KubeProxyIPv4CIDR.canonicalize(config.resolvedVmnetCIDR) else {
                throw KubeProxyMacOSError.applyFailed("configured pod CIDR is not a valid IPv4 CIDR")
            }
            return KubeProxyPodNetworkResolution(
                ipv4PodCIDR: podCIDR,
                ipv6PodCIDR: nil,
                ipv4Ready: true,
                ipv6Ready: false,
                masqueradeIPv4PodTraffic: true,
                masqueradeIPv6PodTraffic: false
            )
        }

        guard let readyStatePath = normalizedPath(config.readyStatePath) else {
            throw KubeProxyMacOSError.applyFailed("pod network ready state path is not configured")
        }

        let runtimeState: KubeProxyPodNetworkRuntimeState = try loadState(
            at: runtimeStatePath,
            description: "runtime",
            fileManager: fileManager,
            decoder: decoder
        )
        guard runtimeState.generation > 0 else {
            throw KubeProxyMacOSError.applyFailed("pod network runtime state generation must be greater than zero")
        }
        let networkName = runtimeState.networkName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !networkName.isEmpty else {
            throw KubeProxyMacOSError.applyFailed("pod network runtime state network name is empty")
        }
        guard let runtimePodCIDR = KubeProxyIPv4CIDR.canonicalize(runtimeState.podCIDR) else {
            throw KubeProxyMacOSError.applyFailed("pod network runtime state contains an invalid IPv4 PodCIDR")
        }

        let readyState: KubeProxyPodNetworkReadyState = try loadState(
            at: readyStatePath,
            description: "ready",
            fileManager: fileManager,
            decoder: decoder
        )
        guard readyState.networkName.trimmingCharacters(in: .whitespacesAndNewlines) == networkName,
            let readyPodCIDR = KubeProxyIPv4CIDR.canonicalize(readyState.podCIDR),
            readyPodCIDR == runtimePodCIDR,
            readyState.runtimeGeneration == runtimeState.generation
        else {
            throw KubeProxyMacOSError.applyFailed("pod network ready state does not match runtime state")
        }
        guard readyState.ipv4Ready else {
            throw KubeProxyMacOSError.applyFailed("pod network IPv4 family is not ready")
        }
        let nowUnixSeconds = Int64(Date().timeIntervalSince1970.rounded(.down))
        guard readyState.expiresAtUnixSeconds > nowUnixSeconds else {
            throw KubeProxyMacOSError.applyFailed("pod network ready state lease has expired")
        }

        let runtimeIPv6PodCIDR =
            dualStackEnabled
            ? runtimeState.podCIDRs.ipv6.flatMap(KubeProxyIPv6CIDR.canonicalize)
            : nil
        let readyIPv6PodCIDR =
            dualStackEnabled
            ? readyState.podCIDRs.ipv6.flatMap(KubeProxyIPv6CIDR.canonicalize)
            : nil
        let ipv6Ready =
            dualStackEnabled
            && readyState.ipv6Ready == true
            && runtimeIPv6PodCIDR != nil
            && readyIPv6PodCIDR == runtimeIPv6PodCIDR

        return KubeProxyPodNetworkResolution(
            ipv4PodCIDR: runtimePodCIDR,
            ipv6PodCIDR: runtimeIPv6PodCIDR,
            ipv4Ready: true,
            ipv6Ready: ipv6Ready,
            masqueradeIPv4PodTraffic: true,
            masqueradeIPv6PodTraffic: dualStackEnabled && masqueradeIPv6PodTraffic
        )
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func loadState<T: Decodable>(
        at path: String,
        description: String,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) throws -> T {
        guard fileManager.fileExists(atPath: path) else {
            throw KubeProxyMacOSError.applyFailed("pod network \(description) state is missing at \(path)")
        }
        do {
            return try decoder.decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw KubeProxyMacOSError.applyFailed("pod network \(description) state is invalid at \(path)")
        }
    }
}

private func decodePodNetworkCIDRs<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>
) throws -> KubeProxyPodNetworkCIDRs {
    guard let podCIDRsKey = Key(stringValue: "podCIDRs"),
        let podCIDRKey = Key(stringValue: "podCIDR")
    else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "pod network state coding keys are invalid"
            )
        )
    }
    let legacyIPv4 = try container.decodeIfPresent(String.self, forKey: podCIDRKey)
    if let podCIDRs = try container.decodeIfPresent(KubeProxyPodNetworkCIDRs.self, forKey: podCIDRsKey) {
        if let legacyIPv4,
            KubeProxyIPv4CIDR.canonicalize(legacyIPv4)
                != KubeProxyIPv4CIDR.canonicalize(podCIDRs.ipv4)
        {
            throw DecodingError.dataCorruptedError(
                forKey: podCIDRsKey,
                in: container,
                debugDescription: "pod network state IPv4 aliases do not match"
            )
        }
        return podCIDRs
    }
    guard let legacyIPv4 else {
        throw DecodingError.keyNotFound(
            podCIDRKey,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "pod network state is missing PodCIDRs"
            )
        )
    }
    return KubeProxyPodNetworkCIDRs(ipv4: legacyIPv4, ipv6: nil)
}

enum KubeProxyIPv4CIDR {
    static func canonicalize(_ value: String) -> String? {
        let components = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
            let prefixLength = decimal(components[1]),
            (0...32).contains(prefixLength)
        else {
            return nil
        }

        let octetStrings = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octetStrings.count == 4 else {
            return nil
        }

        var address: UInt32 = 0
        for octetString in octetStrings {
            guard let octet = decimal(octetString), (0...255).contains(octet) else {
                return nil
            }
            address = (address << 8) | UInt32(octet)
        }

        let mask = prefixLength == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefixLength)
        let network = address & mask
        return [
            (network >> 24) & 0xff,
            (network >> 16) & 0xff,
            (network >> 8) & 0xff,
            network & 0xff,
        ].map(String.init).joined(separator: ".") + "/\(prefixLength)"
    }

    private static func decimal(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return Int(value)
    }
}

enum KubeProxyIPv6CIDR {
    static func canonicalize(_ value: String) -> String? {
        let components = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
            let prefixLength = decimal(components[1]),
            (0...128).contains(prefixLength)
        else {
            return nil
        }

        var address = in6_addr()
        guard String(components[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }

        var bytes = withUnsafeBytes(of: &address) { Array($0) }
        let fullBytes = prefixLength / 8
        let remainingBits = prefixLength % 8
        if remainingBits != 0 {
            bytes[fullBytes] &= UInt8.max << UInt8(8 - remainingBits)
        }
        let firstHostByte = fullBytes + (remainingBits == 0 ? 0 : 1)
        if firstHostByte < bytes.count {
            for index in firstHostByte..<bytes.count {
                bytes[index] = 0
            }
        }

        var networkAddress = in6_addr()
        withUnsafeMutableBytes(of: &networkAddress) { destination in
            destination.copyBytes(from: bytes)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &networkAddress, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text + "/\(prefixLength)"
    }

    private static func decimal(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return Int(value)
    }
}
