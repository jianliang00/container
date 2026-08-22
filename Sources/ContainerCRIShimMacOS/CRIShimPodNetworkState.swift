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

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct PodNetworkCIDRs: Codable, Equatable, Sendable {
    public var ipv4: String
    public var ipv6: String?

    public init(ipv4: String, ipv6: String? = nil) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

public struct PodNetworkRuntimeState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var networkName: String
    public var podCIDRs: PodNetworkCIDRs
    public var generation: UInt64
    public var updatedAt: Date

    public var podCIDR: String {
        get { podCIDRs.ipv4 }
        set { podCIDRs.ipv4 = newValue }
    }

    public init(
        networkName: String,
        podCIDRs: PodNetworkCIDRs,
        generation: UInt64,
        updatedAt: Date,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.networkName = networkName
        self.podCIDRs = podCIDRs
        self.generation = generation
        self.updatedAt = updatedAt
    }

    public init(networkName: String, podCIDR: String, generation: UInt64, updatedAt: Date) {
        self.init(
            networkName: networkName,
            podCIDRs: PodNetworkCIDRs(ipv4: podCIDR),
            generation: generation,
            updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case networkName
        case podCIDR
        case podCIDRs
        case generation
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
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
        podCIDRs = try Self.decodePodCIDRs(from: container)
        generation = try container.decode(UInt64.self, forKey: .generation)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(networkName, forKey: .networkName)
        try container.encode(podCIDRs.ipv4, forKey: .podCIDR)
        try container.encode(podCIDRs, forKey: .podCIDRs)
        try container.encode(generation, forKey: .generation)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func decodePodCIDRs(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> PodNetworkCIDRs {
        let legacyIPv4 = try container.decodeIfPresent(String.self, forKey: .podCIDR)
        if let podCIDRs = try container.decodeIfPresent(PodNetworkCIDRs.self, forKey: .podCIDRs) {
            if let legacyIPv4,
                (try? canonicalIPv4PodCIDR(legacyIPv4)) != (try? canonicalIPv4PodCIDR(podCIDRs.ipv4))
            {
                throw DecodingError.dataCorruptedError(
                    forKey: .podCIDRs,
                    in: container,
                    debugDescription: "pod network runtime state IPv4 aliases do not match"
                )
            }
            return podCIDRs
        }
        guard let legacyIPv4 else {
            throw DecodingError.keyNotFound(
                CodingKeys.podCIDR,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "pod network runtime state is missing PodCIDRs"
                )
            )
        }
        return PodNetworkCIDRs(ipv4: legacyIPv4)
    }
}

public struct PodNetworkReadyState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var networkName: String
    public var podCIDRs: PodNetworkCIDRs
    public var ipv4Ready: Bool
    public var ipv6Ready: Bool?
    public var runtimeGeneration: UInt64
    public var mtu: UInt32
    public var expiresAtUnixSeconds: Int64

    public var podCIDR: String {
        get { podCIDRs.ipv4 }
        set { podCIDRs.ipv4 = newValue }
    }

    public init(
        networkName: String,
        podCIDRs: PodNetworkCIDRs,
        runtimeGeneration: UInt64,
        mtu: UInt32,
        expiresAtUnixSeconds: Int64,
        ipv4Ready: Bool = true,
        ipv6Ready: Bool? = nil,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.networkName = networkName
        self.podCIDRs = podCIDRs
        self.ipv4Ready = ipv4Ready
        self.ipv6Ready = ipv6Ready
        self.runtimeGeneration = runtimeGeneration
        self.mtu = mtu
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
    }

    public init(
        networkName: String,
        podCIDR: String,
        runtimeGeneration: UInt64,
        mtu: UInt32,
        expiresAtUnixSeconds: Int64
    ) {
        self.init(
            networkName: networkName,
            podCIDRs: PodNetworkCIDRs(ipv4: podCIDR),
            runtimeGeneration: runtimeGeneration,
            mtu: mtu,
            expiresAtUnixSeconds: expiresAtUnixSeconds
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case networkName
        case podCIDR
        case podCIDRs
        case ipv4Ready
        case ipv6Ready
        case runtimeGeneration
        case mtu
        case expiresAtUnixSeconds
    }

    public init(from decoder: any Decoder) throws {
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
        podCIDRs = try Self.decodePodCIDRs(from: container)
        ipv4Ready = try container.decodeIfPresent(Bool.self, forKey: .ipv4Ready) ?? true
        ipv6Ready = try container.decodeIfPresent(Bool.self, forKey: .ipv6Ready)
        runtimeGeneration = try container.decode(UInt64.self, forKey: .runtimeGeneration)
        mtu = try container.decode(UInt32.self, forKey: .mtu)
        expiresAtUnixSeconds = try container.decode(Int64.self, forKey: .expiresAtUnixSeconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(networkName, forKey: .networkName)
        try container.encode(podCIDRs.ipv4, forKey: .podCIDR)
        try container.encode(podCIDRs, forKey: .podCIDRs)
        try container.encode(ipv4Ready, forKey: .ipv4Ready)
        try container.encodeIfPresent(ipv6Ready, forKey: .ipv6Ready)
        try container.encode(runtimeGeneration, forKey: .runtimeGeneration)
        try container.encode(mtu, forKey: .mtu)
        try container.encode(expiresAtUnixSeconds, forKey: .expiresAtUnixSeconds)
    }

    private static func decodePodCIDRs(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> PodNetworkCIDRs {
        let legacyIPv4 = try container.decodeIfPresent(String.self, forKey: .podCIDR)
        if let podCIDRs = try container.decodeIfPresent(PodNetworkCIDRs.self, forKey: .podCIDRs) {
            if let legacyIPv4,
                (try? canonicalIPv4PodCIDR(legacyIPv4)) != (try? canonicalIPv4PodCIDR(podCIDRs.ipv4))
            {
                throw DecodingError.dataCorruptedError(
                    forKey: .podCIDRs,
                    in: container,
                    debugDescription: "pod network ready state IPv4 aliases do not match"
                )
            }
            return podCIDRs
        }
        guard let legacyIPv4 else {
            throw DecodingError.keyNotFound(
                CodingKeys.podCIDR,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "pod network ready state is missing PodCIDRs"
                )
            )
        }
        return PodNetworkCIDRs(ipv4: legacyIPv4)
    }
}

struct PodNetworkReadyLease: Equatable, Sendable {
    var podCIDRs: PodNetworkCIDRs
    var mtu: UInt32

    var podCIDR: String { podCIDRs.ipv4 }
}

enum PodNetworkReadyLeaseValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case statePathsNotConfigured
    case runtimeStateMissing
    case readyStateMissing
    case runtimeStateMismatch
    case readyStateMismatch
    case ipv4NotReady
    case ipv6NotReady
    case readyStateExpired
    case mtuOutOfRange

    var description: String {
        switch self {
        case .statePathsNotConfigured:
            return "pod network state paths are not configured"
        case .runtimeStateMissing:
            return "pod network runtime state has not been published"
        case .readyStateMissing:
            return "pod network ready state has not been published"
        case .runtimeStateMismatch:
            return "pod network runtime state does not match the configured network"
        case .readyStateMismatch:
            return "pod network ready state does not match the runtime state"
        case .ipv4NotReady:
            return "pod network IPv4 family is not ready"
        case .ipv6NotReady:
            return "pod network IPv6 family is not ready"
        case .readyStateExpired:
            return "pod network ready state lease has expired"
        case .mtuOutOfRange:
            return "pod network ready state MTU must be between 576 and 9000"
        }
    }
}

public enum PodNetworkStateError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidIPv4PodCIDR
    case invalidIPv6PodCIDR
    case invalidPodCIDRList
    case runtimeStateReadFailed
    case runtimeStateWriteFailed
    case readyStateReadFailed
    case readyStateWriteFailed

    public var description: String {
        switch self {
        case .invalidIPv4PodCIDR:
            return "pod CIDR must be a valid IPv4 CIDR"
        case .invalidIPv6PodCIDR:
            return "pod CIDR must be a valid IPv6 CIDR"
        case .invalidPodCIDRList:
            return "pod CIDRs must contain exactly one valid IPv4 CIDR and one valid IPv6 CIDR"
        case .runtimeStateReadFailed:
            return "failed to read pod network runtime state"
        case .runtimeStateWriteFailed:
            return "failed to write pod network runtime state"
        case .readyStateReadFailed:
            return "failed to read pod network ready state"
        case .readyStateWriteFailed:
            return "failed to write pod network ready state"
        }
    }
}

public actor PodNetworkStateStore {
    public init() {}

    public func loadRuntimeState(path: String) throws -> PodNetworkRuntimeState? {
        do {
            return try load(PodNetworkRuntimeState.self, path: path)
        } catch {
            throw PodNetworkStateError.runtimeStateReadFailed
        }
    }

    @discardableResult
    public func updateRuntimeState(
        networkName: String,
        podCIDR: String,
        path: String,
        updatedAt: Date = Date()
    ) throws -> PodNetworkRuntimeState {
        try updateRuntimeState(
            networkName: networkName,
            podCIDRs: PodNetworkCIDRs(ipv4: podCIDR),
            path: path,
            updatedAt: updatedAt
        )
    }

    @discardableResult
    public func updateRuntimeState(
        networkName: String,
        podCIDRs: PodNetworkCIDRs,
        path: String,
        updatedAt: Date = Date()
    ) throws -> PodNetworkRuntimeState {
        let canonicalPodCIDRs = try canonicalPodNetworkCIDRs(podCIDRs)
        let previous = try loadRuntimeState(path: path)
        if let previous,
            previous.networkName == networkName,
            (try? canonicalPodNetworkCIDRs(previous.podCIDRs)) == canonicalPodCIDRs
        {
            return previous
        }

        let generation: UInt64
        if let previous {
            let increment = previous.generation.addingReportingOverflow(1)
            guard !increment.overflow else {
                throw PodNetworkStateError.runtimeStateWriteFailed
            }
            generation = increment.partialValue
        } else {
            generation = 1
        }

        let state = PodNetworkRuntimeState(
            networkName: networkName,
            podCIDRs: canonicalPodCIDRs,
            generation: generation,
            updatedAt: updatedAt
        )
        do {
            try write(state, path: path)
        } catch {
            throw PodNetworkStateError.runtimeStateWriteFailed
        }
        return state
    }

    public func loadReadyState(path: String) throws -> PodNetworkReadyState? {
        do {
            return try load(PodNetworkReadyState.self, path: path)
        } catch {
            throw PodNetworkStateError.readyStateReadFailed
        }
    }

    public func writeReadyState(_ state: PodNetworkReadyState, path: String) throws {
        do {
            try write(state, path: path)
        } catch {
            throw PodNetworkStateError.readyStateWriteFailed
        }
    }

    func resolveReadyLease(
        config: PodNetworkConfig,
        now: Date = Date()
    ) throws -> PodNetworkReadyLease {
        guard let runtimeStatePath = config.runtimeStatePath?.trimmed,
            !runtimeStatePath.isEmpty,
            let readyStatePath = config.readyStatePath?.trimmed,
            !readyStatePath.isEmpty
        else {
            throw PodNetworkReadyLeaseValidationError.statePathsNotConfigured
        }
        guard let runtimeState = try loadRuntimeState(path: runtimeStatePath) else {
            throw PodNetworkReadyLeaseValidationError.runtimeStateMissing
        }
        guard let readyState = try loadReadyState(path: readyStatePath) else {
            throw PodNetworkReadyLeaseValidationError.readyStateMissing
        }
        return try validatePodNetworkReadyLease(
            config: config,
            runtimeState: runtimeState,
            readyState: readyState,
            now: now
        )
    }

    private func load<T: Decodable>(_ type: T.Type, path: String) throws -> T? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

func validatePodNetworkReadyLease(
    config: PodNetworkConfig,
    runtimeState: PodNetworkRuntimeState,
    readyState: PodNetworkReadyState,
    now: Date = Date()
) throws -> PodNetworkReadyLease {
    let dualStackEnabled = config.dualStackEnabled
    guard config.enabled == true,
        let networkName = config.networkName?.trimmed,
        !networkName.isEmpty,
        runtimeState.generation > 0,
        runtimeState.networkName == networkName,
        let runtimePodCIDRs = try? canonicalPodNetworkCIDRs(runtimeState.podCIDRs),
        !dualStackEnabled || runtimePodCIDRs.ipv6 != nil
    else {
        throw PodNetworkReadyLeaseValidationError.runtimeStateMismatch
    }

    guard readyState.networkName == runtimeState.networkName,
        let readyPodCIDRs = try? canonicalPodNetworkCIDRs(readyState.podCIDRs),
        readyPodCIDRs.ipv4 == runtimePodCIDRs.ipv4,
        !dualStackEnabled || readyPodCIDRs.ipv6 == runtimePodCIDRs.ipv6,
        readyState.runtimeGeneration == runtimeState.generation
    else {
        throw PodNetworkReadyLeaseValidationError.readyStateMismatch
    }

    guard readyState.ipv4Ready else {
        throw PodNetworkReadyLeaseValidationError.ipv4NotReady
    }
    if dualStackEnabled, readyState.ipv6Ready != true {
        throw PodNetworkReadyLeaseValidationError.ipv6NotReady
    }

    let nowUnixSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
    guard readyState.expiresAtUnixSeconds > nowUnixSeconds else {
        throw PodNetworkReadyLeaseValidationError.readyStateExpired
    }
    guard (576...9_000).contains(readyState.mtu) else {
        throw PodNetworkReadyLeaseValidationError.mtuOutOfRange
    }

    let leasePodCIDRs =
        dualStackEnabled
        ? runtimePodCIDRs
        : PodNetworkCIDRs(ipv4: runtimePodCIDRs.ipv4)
    return PodNetworkReadyLease(podCIDRs: leasePodCIDRs, mtu: readyState.mtu)
}

func canonicalPodNetworkCIDRs(
    _ value: String,
    dualStackEnabled: Bool
) throws -> PodNetworkCIDRs {
    guard dualStackEnabled else {
        return PodNetworkCIDRs(ipv4: try canonicalIPv4PodCIDRList(value))
    }

    let candidates = value.split(separator: ",", omittingEmptySubsequences: false)
    guard !candidates.isEmpty else {
        throw PodNetworkStateError.invalidPodCIDRList
    }

    var ipv4PodCIDRs: [String] = []
    var ipv6PodCIDRs: [String] = []
    for rawCandidate in candidates {
        let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw PodNetworkStateError.invalidPodCIDRList
        }
        if let canonical = try? canonicalIPv4PodCIDR(candidate) {
            ipv4PodCIDRs.append(canonical)
            continue
        }
        if let canonical = try? canonicalIPv6PodCIDR(candidate) {
            ipv6PodCIDRs.append(canonical)
            continue
        }
        throw PodNetworkStateError.invalidPodCIDRList
    }

    guard ipv4PodCIDRs.count == 1, ipv6PodCIDRs.count == 1 else {
        throw PodNetworkStateError.invalidPodCIDRList
    }
    return PodNetworkCIDRs(ipv4: ipv4PodCIDRs[0], ipv6: ipv6PodCIDRs[0])
}

func canonicalPodNetworkCIDRs(
    _ value: PodNetworkCIDRs
) throws -> PodNetworkCIDRs {
    let ipv4 = try canonicalIPv4PodCIDR(value.ipv4)
    let ipv6 = try value.ipv6.map { try canonicalIPv6PodCIDR($0) }
    return PodNetworkCIDRs(ipv4: ipv4, ipv6: ipv6)
}

func canonicalIPv4PodCIDR(_ value: String) throws -> String {
    let components = value.trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2,
        let prefix = parseDecimal(components[1]),
        prefix <= 32
    else {
        throw PodNetworkStateError.invalidIPv4PodCIDR
    }

    let octetStrings = components[0].split(separator: ".", omittingEmptySubsequences: false)
    guard octetStrings.count == 4 else {
        throw PodNetworkStateError.invalidIPv4PodCIDR
    }

    var address: UInt32 = 0
    for octetString in octetStrings {
        guard let octet = parseDecimal(octetString), octet <= 255 else {
            throw PodNetworkStateError.invalidIPv4PodCIDR
        }
        address = (address << 8) | UInt32(octet)
    }

    let mask = prefix == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefix)
    let network = address & mask
    let octets = [
        (network >> 24) & 0xff,
        (network >> 16) & 0xff,
        (network >> 8) & 0xff,
        network & 0xff,
    ]
    return octets.map(String.init).joined(separator: ".") + "/\(prefix)"
}

func canonicalIPv4PodCIDRList(_ value: String) throws -> String {
    let candidates = value.split(separator: ",", omittingEmptySubsequences: false)
    guard !candidates.isEmpty else {
        throw PodNetworkStateError.invalidIPv4PodCIDR
    }

    var ipv4PodCIDRs: Set<String> = []
    for rawCandidate in candidates {
        let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw PodNetworkStateError.invalidIPv4PodCIDR
        }
        if let canonical = try? canonicalIPv4PodCIDR(candidate) {
            ipv4PodCIDRs.insert(canonical)
            continue
        }
        guard isValidIPv6CIDR(candidate) else {
            throw PodNetworkStateError.invalidIPv4PodCIDR
        }
    }

    guard ipv4PodCIDRs.count == 1, let podCIDR = ipv4PodCIDRs.first else {
        throw PodNetworkStateError.invalidIPv4PodCIDR
    }
    return podCIDR
}

private func isValidIPv6CIDR(_ value: String) -> Bool {
    (try? canonicalIPv6PodCIDR(value)) != nil
}

func canonicalIPv6PodCIDR(_ value: String) throws -> String {
    let components = value.trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2,
        let prefixLength = parseDecimal(components[1]),
        prefixLength <= 128
    else {
        throw PodNetworkStateError.invalidIPv6PodCIDR
    }

    var address = in6_addr()
    guard String(components[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
        throw PodNetworkStateError.invalidIPv6PodCIDR
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
        throw PodNetworkStateError.invalidIPv6PodCIDR
    }
    let renderedAddress = String(
        decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
        as: UTF8.self
    )
    return renderedAddress + "/\(prefixLength)"
}

private func parseDecimal(_ value: Substring) -> Int? {
    guard !value.isEmpty,
        value.utf8.allSatisfy({ (48...57).contains($0) })
    else {
        return nil
    }
    return Int(value)
}
