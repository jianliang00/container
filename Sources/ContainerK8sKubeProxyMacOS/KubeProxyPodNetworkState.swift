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

struct KubeProxyPodNetworkRuntimeState: Decodable, Equatable {
    var networkName: String
    var podCIDR: String
    var generation: UInt64
}

struct KubeProxyPodNetworkReadyState: Decodable, Equatable {
    var networkName: String
    var podCIDR: String
    var runtimeGeneration: UInt64
    var expiresAtUnixSeconds: Int64
}

struct KubeProxyPodNetworkResolution: Equatable {
    var podCIDR: String
    var masqueradePodTraffic: Bool
}

enum KubeProxyPodNetworkStateResolver {
    static func resolve(
        config: KubeProxyPFConfig,
        fileManager: FileManager = .default,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> KubeProxyPodNetworkResolution {
        guard let runtimeStatePath = normalizedPath(config.runtimeStatePath) else {
            guard normalizedPath(config.readyStatePath) == nil else {
                throw KubeProxyMacOSError.applyFailed("pod network runtime state path is not configured")
            }
            guard let podCIDR = KubeProxyIPv4CIDR.canonicalize(config.resolvedVmnetCIDR) else {
                throw KubeProxyMacOSError.applyFailed("configured pod CIDR is not a valid IPv4 CIDR")
            }
            return KubeProxyPodNetworkResolution(podCIDR: podCIDR, masqueradePodTraffic: true)
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
        let nowUnixSeconds = Int64(Date().timeIntervalSince1970.rounded(.down))
        guard readyState.expiresAtUnixSeconds > nowUnixSeconds else {
            throw KubeProxyMacOSError.applyFailed("pod network ready state lease has expired")
        }

        return KubeProxyPodNetworkResolution(podCIDR: runtimePodCIDR, masqueradePodTraffic: true)
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
