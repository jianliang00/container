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

public struct MacOSGuestNetworkInterfaceConfiguration: Codable, Sendable, Equatable {
    public let networkID: String
    public let hostname: String
    public let macAddress: String
    public let ipv4Address: String
    public let ipv4PrefixLength: UInt8
    public let ipv4Gateway: String
    public let ipv6Address: String?
    public let ipv6PrefixLength: UInt8?
    public let ipv6Gateway: String?
    public let mtu: UInt32?

    public init(
        networkID: String,
        hostname: String,
        macAddress: String,
        ipv4Address: String,
        ipv4PrefixLength: UInt8,
        ipv4Gateway: String,
        ipv6Address: String? = nil,
        ipv6PrefixLength: UInt8? = nil,
        ipv6Gateway: String? = nil,
        mtu: UInt32? = nil
    ) {
        self.networkID = networkID
        self.hostname = hostname
        self.macAddress = macAddress
        self.ipv4Address = ipv4Address
        self.ipv4PrefixLength = ipv4PrefixLength
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Address = ipv6Address
        self.ipv6PrefixLength = ipv6PrefixLength
        self.ipv6Gateway = ipv6Gateway
        self.mtu = mtu
    }
}

public struct MacOSGuestDNSConfiguration: Codable, Sendable, Equatable {
    public let nameservers: [String]
    public let domain: String?
    public let searchDomains: [String]
    public let options: [String]

    public init(
        nameservers: [String],
        domain: String?,
        searchDomains: [String],
        options: [String]
    ) {
        self.nameservers = nameservers
        self.domain = domain
        self.searchDomains = searchDomains
        self.options = options
    }
}

public struct MacOSGuestNetworkConfigurationRequest: Codable, Sendable, Equatable {
    public let interfaces: [MacOSGuestNetworkInterfaceConfiguration]
    public let primaryInterfaceIndex: Int
    public let dns: MacOSGuestDNSConfiguration?

    public init(
        interfaces: [MacOSGuestNetworkInterfaceConfiguration],
        primaryInterfaceIndex: Int = 0,
        dns: MacOSGuestDNSConfiguration?
    ) {
        self.interfaces = interfaces
        self.primaryInterfaceIndex = primaryInterfaceIndex
        self.dns = dns
    }
}

public struct MacOSGuestAppliedNetworkInterface: Codable, Sendable, Equatable {
    public let networkID: String
    public let interfaceName: String
    public let macAddress: String
    public let ipv4Address: String
    public let ipv6Address: String?
    public let effectiveMTU: UInt32?

    public init(
        networkID: String,
        interfaceName: String,
        macAddress: String,
        ipv4Address: String,
        ipv6Address: String? = nil,
        effectiveMTU: UInt32? = nil
    ) {
        self.networkID = networkID
        self.interfaceName = interfaceName
        self.macAddress = macAddress
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.effectiveMTU = effectiveMTU
    }
}

public struct MacOSGuestEffectiveDNSConfiguration: Codable, Sendable, Equatable {
    public let serviceID: String
    public let interfaceName: String
    public let nameservers: [String]
    public let domain: String?
    public let searchDomains: [String]
    public let options: [String]

    public init(
        serviceID: String,
        interfaceName: String,
        nameservers: [String],
        domain: String?,
        searchDomains: [String],
        options: [String]
    ) {
        self.serviceID = serviceID
        self.interfaceName = interfaceName
        self.nameservers = nameservers
        self.domain = domain
        self.searchDomains = searchDomains
        self.options = options
    }
}

public struct MacOSGuestNetworkConfigurationResult: Codable, Sendable, Equatable {
    public let interfaces: [MacOSGuestAppliedNetworkInterface]
    /// Retained for compatibility with sidecars that predate effective DNS reporting.
    public let dnsApplied: Bool
    public let effectiveDNS: MacOSGuestEffectiveDNSConfiguration?
    public let warnings: [String]

    public init(
        interfaces: [MacOSGuestAppliedNetworkInterface],
        dnsApplied: Bool,
        effectiveDNS: MacOSGuestEffectiveDNSConfiguration? = nil,
        warnings: [String] = []
    ) {
        self.interfaces = interfaces
        self.dnsApplied = dnsApplied
        self.effectiveDNS = effectiveDNS
        self.warnings = warnings
    }
}
