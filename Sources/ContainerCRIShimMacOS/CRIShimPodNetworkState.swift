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

public struct PodNetworkRuntimeState: Codable, Equatable, Sendable {
    public var networkName: String
    public var podCIDR: String
    public var generation: UInt64
    public var updatedAt: Date

    public init(networkName: String, podCIDR: String, generation: UInt64, updatedAt: Date) {
        self.networkName = networkName
        self.podCIDR = podCIDR
        self.generation = generation
        self.updatedAt = updatedAt
    }
}

public struct PodNetworkReadyState: Codable, Equatable, Sendable {
    public var networkName: String
    public var podCIDR: String
    public var runtimeGeneration: UInt64
    public var mtu: UInt32
    public var expiresAtUnixSeconds: Int64

    public init(
        networkName: String,
        podCIDR: String,
        runtimeGeneration: UInt64,
        mtu: UInt32,
        expiresAtUnixSeconds: Int64
    ) {
        self.networkName = networkName
        self.podCIDR = podCIDR
        self.runtimeGeneration = runtimeGeneration
        self.mtu = mtu
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
    }
}

struct PodNetworkReadyLease: Equatable, Sendable {
    var podCIDR: String
    var mtu: UInt32
}

enum PodNetworkReadyLeaseValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case statePathsNotConfigured
    case runtimeStateMissing
    case readyStateMissing
    case runtimeStateMismatch
    case readyStateMismatch
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
        case .readyStateExpired:
            return "pod network ready state lease has expired"
        case .mtuOutOfRange:
            return "pod network ready state MTU must be between 576 and 9000"
        }
    }
}

public enum PodNetworkStateError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidIPv4PodCIDR
    case runtimeStateReadFailed
    case runtimeStateWriteFailed
    case readyStateReadFailed
    case readyStateWriteFailed

    public var description: String {
        switch self {
        case .invalidIPv4PodCIDR:
            return "pod CIDR must be a valid IPv4 CIDR"
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
        let canonicalPodCIDR = try canonicalIPv4PodCIDR(podCIDR)
        let previous = try loadRuntimeState(path: path)
        if let previous,
            previous.networkName == networkName,
            previous.podCIDR == canonicalPodCIDR
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
            podCIDR: canonicalPodCIDR,
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
    guard config.enabled == true,
        let networkName = config.networkName?.trimmed,
        !networkName.isEmpty,
        runtimeState.generation > 0,
        runtimeState.networkName == networkName,
        let runtimePodCIDR = try? canonicalIPv4PodCIDR(runtimeState.podCIDR)
    else {
        throw PodNetworkReadyLeaseValidationError.runtimeStateMismatch
    }

    guard readyState.networkName == runtimeState.networkName,
        let readyPodCIDR = try? canonicalIPv4PodCIDR(readyState.podCIDR),
        readyPodCIDR == runtimePodCIDR,
        readyState.runtimeGeneration == runtimeState.generation
    else {
        throw PodNetworkReadyLeaseValidationError.readyStateMismatch
    }

    let nowUnixSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
    guard readyState.expiresAtUnixSeconds > nowUnixSeconds else {
        throw PodNetworkReadyLeaseValidationError.readyStateExpired
    }
    guard (576...9_000).contains(readyState.mtu) else {
        throw PodNetworkReadyLeaseValidationError.mtuOutOfRange
    }

    return PodNetworkReadyLease(podCIDR: runtimePodCIDR, mtu: readyState.mtu)
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
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2,
        let prefixLength = parseDecimal(components[1]),
        prefixLength <= 128
    else {
        return false
    }
    var address = in6_addr()
    return String(components[0]).withCString { inet_pton(AF_INET6, $0, &address) } == 1
}

private func parseDecimal(_ value: Substring) -> Int? {
    guard !value.isEmpty,
        value.utf8.allSatisfy({ (48...57).contains($0) })
    else {
        return nil
    }
    return Int(value)
}
