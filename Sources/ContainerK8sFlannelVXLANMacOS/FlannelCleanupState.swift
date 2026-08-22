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

public struct FlannelOwnershipState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var interfaceName: String
    public var localPodCIDR: String
    public var routePodCIDRs: [String]
    public var ipv6InterfaceName: String?
    public var localIPv6PodCIDR: String?
    public var ipv6RoutePodCIDRs: [String]?

    public init(
        interfaceName: String,
        localPodCIDR: String,
        routePodCIDRs: [String],
        ipv6InterfaceName: String? = nil,
        localIPv6PodCIDR: String? = nil,
        ipv6RoutePodCIDRs: [String]? = nil,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.interfaceName = interfaceName
        self.localPodCIDR = localPodCIDR
        self.routePodCIDRs = routePodCIDRs
        self.ipv6InterfaceName = ipv6InterfaceName
        self.localIPv6PodCIDR = localIPv6PodCIDR
        self.ipv6RoutePodCIDRs = ipv6RoutePodCIDRs
    }

    fileprivate func validated() throws -> Self {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw FlannelVXLANError.persistence("unsupported cleanup state schema version \(schemaVersion)")
        }
        guard interfaceName.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil else {
            throw FlannelVXLANError.persistence("cleanup state contains an invalid tunnel interface")
        }
        guard let localCIDR = FlannelIPv4.parseCIDR(localPodCIDR) else {
            throw FlannelVXLANError.persistence("cleanup state contains an invalid local PodCIDR")
        }

        var routes: Set<String> = []
        for route in routePodCIDRs {
            guard let cidr = FlannelIPv4.parseCIDR(route), !cidr.overlaps(localCIDR) else {
                throw FlannelVXLANError.persistence("cleanup state contains an invalid remote PodCIDR")
            }
            routes.insert(cidr.string)
        }
        let ipv6State = try validatedIPv6State()
        guard schemaVersion != 1 || ipv6State == nil else {
            throw FlannelVXLANError.persistence(
                "cleanup state schema version 1 cannot contain IPv6 ownership"
            )
        }
        return Self(
            interfaceName: interfaceName,
            localPodCIDR: localCIDR.string,
            routePodCIDRs: routes.sorted(),
            ipv6InterfaceName: ipv6State?.interfaceName,
            localIPv6PodCIDR: ipv6State?.localPodCIDR,
            ipv6RoutePodCIDRs: ipv6State?.routes,
            schemaVersion: ipv6State == nil ? 1 : Self.currentSchemaVersion
        )
    }

    private func validatedIPv6State() throws -> (interfaceName: String, localPodCIDR: String, routes: [String])? {
        switch (ipv6InterfaceName, localIPv6PodCIDR, ipv6RoutePodCIDRs) {
        case (nil, nil, nil):
            return nil
        case (.some(let interfaceName), .some(let localPodCIDR), .some(let routePodCIDRs)):
            guard interfaceName.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil else {
                throw FlannelVXLANError.persistence("cleanup state contains an invalid IPv6 tunnel interface")
            }
            guard let localCIDR = FlannelIPv6.parseCIDR(localPodCIDR), localCIDR.prefixLength > 0 else {
                throw FlannelVXLANError.persistence("cleanup state contains an invalid local IPv6 PodCIDR")
            }
            var routes: Set<String> = []
            for route in routePodCIDRs {
                guard let cidr = FlannelIPv6.parseCIDR(route),
                    cidr.prefixLength > 0,
                    !cidr.overlaps(localCIDR)
                else {
                    throw FlannelVXLANError.persistence("cleanup state contains an invalid remote IPv6 PodCIDR")
                }
                routes.insert(cidr.string)
            }
            return (interfaceName, localCIDR.string, routes.sorted())
        default:
            throw FlannelVXLANError.persistence("cleanup state contains incomplete IPv6 ownership")
        }
    }
}

public protocol FlannelOwnershipStateStoring: Sendable {
    func load() throws -> FlannelOwnershipState?
    func save(_ state: FlannelOwnershipState) throws
    func remove() throws
}

public struct FlannelOwnershipStateStore: FlannelOwnershipStateStoring, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(path: String) {
        self.init(url: URL(fileURLWithPath: path))
    }

    public func load() throws -> FlannelOwnershipState? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let state = try JSONDecoder().decode(FlannelOwnershipState.self, from: Data(contentsOf: url))
            return try state.validated()
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence("failed to read cleanup state at \(url.path): \(error)")
        }
    }

    public func save(_ state: FlannelOwnershipState) throws {
        let state = try state.validated()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence("failed to write cleanup state at \(url.path): \(error)")
        }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FlannelVXLANError.persistence("failed to remove cleanup state at \(url.path): \(error)")
        }
    }
}

public struct FlannelHostOnlyNetworkOwnership: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var name: String
    public var podCIDR: String
    public var ipv6PodCIDR: String?
    public var plugin: String
    public var variant: String
    public var ownershipID: String

    public init(
        name: String,
        podCIDR: String,
        ipv6PodCIDR: String? = nil,
        plugin: String,
        variant: String,
        ownershipID: String,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.podCIDR = podCIDR
        self.ipv6PodCIDR = ipv6PodCIDR
        self.plugin = plugin
        self.variant = variant
        self.ownershipID = ownershipID
    }

    fileprivate func validated() throws -> Self {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw FlannelVXLANError.persistence("unsupported network ownership schema version \(schemaVersion)")
        }
        guard !name.isEmpty, !name.contains("/"), !name.contains(where: \.isWhitespace) else {
            throw FlannelVXLANError.persistence("network ownership contains an invalid name")
        }
        guard let podCIDR = FlannelIPv4.parseCIDR(podCIDR) else {
            throw FlannelVXLANError.persistence("network ownership contains an invalid PodCIDR")
        }
        let ipv6PodCIDR: String?
        if let value = self.ipv6PodCIDR {
            guard let cidr = FlannelIPv6.parseCIDR(value), cidr.prefixLength > 0 else {
                throw FlannelVXLANError.persistence("network ownership contains an invalid IPv6 PodCIDR")
            }
            ipv6PodCIDR = cidr.string
        } else {
            ipv6PodCIDR = nil
        }
        guard schemaVersion != 1 || ipv6PodCIDR == nil else {
            throw FlannelVXLANError.persistence(
                "network ownership schema version 1 cannot contain an IPv6 PodCIDR"
            )
        }
        guard !plugin.isEmpty, !variant.isEmpty else {
            throw FlannelVXLANError.persistence("network ownership contains an invalid plugin or variant")
        }
        guard UUID(uuidString: ownershipID)?.uuidString.lowercased() == ownershipID.lowercased() else {
            throw FlannelVXLANError.persistence("network ownership contains an invalid ownership ID")
        }
        return Self(
            name: name,
            podCIDR: podCIDR.string,
            ipv6PodCIDR: ipv6PodCIDR,
            plugin: plugin,
            variant: variant,
            ownershipID: ownershipID.lowercased(),
            schemaVersion: ipv6PodCIDR == nil ? 1 : Self.currentSchemaVersion
        )
    }
}

public protocol FlannelHostOnlyNetworkOwnershipStoring: Sendable {
    func load() throws -> FlannelHostOnlyNetworkOwnership?
    func save(_ state: FlannelHostOnlyNetworkOwnership) throws
    func remove() throws
}

public struct FlannelHostOnlyNetworkOwnershipStore: FlannelHostOnlyNetworkOwnershipStoring, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(path: String) {
        self.init(url: URL(fileURLWithPath: path))
    }

    public func load() throws -> FlannelHostOnlyNetworkOwnership? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let state = try JSONDecoder().decode(FlannelHostOnlyNetworkOwnership.self, from: Data(contentsOf: url))
            return try state.validated()
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence("failed to read network ownership at \(url.path): \(error)")
        }
    }

    public func save(_ state: FlannelHostOnlyNetworkOwnership) throws {
        let state = try state.validated()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence("failed to write network ownership at \(url.path): \(error)")
        }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FlannelVXLANError.persistence("failed to remove network ownership at \(url.path): \(error)")
        }
    }
}
