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

import ContainerResource
import ContainerizationError
import Foundation
import RuntimeMacOSSidecarShared

enum MacOSGuestNetworkBootstrap {
    static func makeRequest(
        containerConfig: ContainerConfiguration,
        lease: MacOSGuestNetworkLease?
    ) throws -> MacOSGuestNetworkConfigurationRequest? {
        guard containerConfig.macosGuest?.networkBackend == .vmnetShared else {
            return nil
        }
        guard let lease, !lease.interfaces.isEmpty else {
            return nil
        }

        let interfaces = try lease.interfaces.map { leasedInterface in
            let attachment = leasedInterface.attachment
            guard let macAddress = attachment.macAddress?.description else {
                throw ContainerizationError(
                    .invalidState,
                    message: "guest network bootstrap requires a MAC address for network \(attachment.network)"
                )
            }
            let ipv6Address: String?
            let ipv6PrefixLength: UInt8?
            let ipv6Gateway: String?
            switch (attachment.ipv6Address, attachment.ipv6Gateway) {
            case (_, nil):
                // vmnet may report an automatically generated IPv6 prefix even
                // when this network has no explicit IPv6 configuration. Keep
                // that legacy status out of the guest configuration unless a
                // matching gateway proves that IPv6 was intentionally enabled.
                ipv6Address = nil
                ipv6PrefixLength = nil
                ipv6Gateway = nil
            case (.some(let address), .some(let gateway)):
                ipv6Address = address.address.description
                ipv6PrefixLength = address.prefix.length
                ipv6Gateway = gateway.description
            case (nil, .some):
                throw ContainerizationError(
                    .invalidState,
                    message: "guest network bootstrap requires complete IPv6 address and gateway intent for network \(attachment.network)"
                )
            }
            return MacOSGuestNetworkInterfaceConfiguration(
                networkID: attachment.network,
                hostname: attachment.hostname,
                macAddress: macAddress,
                ipv4Address: attachment.ipv4Address.address.description,
                ipv4PrefixLength: attachment.ipv4Address.prefix.length,
                ipv4Gateway: attachment.ipv4Gateway.description,
                ipv6Address: ipv6Address,
                ipv6PrefixLength: ipv6PrefixLength,
                ipv6Gateway: ipv6Gateway,
                mtu: attachment.mtu
            )
        }

        return MacOSGuestNetworkConfigurationRequest(
            interfaces: interfaces,
            primaryInterfaceIndex: 0,
            dns: makeDNSConfiguration(lease: lease)
        )
    }

    static func validateResult(
        _ result: MacOSGuestNetworkConfigurationResult,
        for request: MacOSGuestNetworkConfigurationRequest
    ) throws {
        guard result.interfaces.count == request.interfaces.count else {
            throw ContainerizationError(
                .invalidState,
                message:
                    "guest network configuration result contains \(result.interfaces.count) interfaces; expected \(request.interfaces.count)"
            )
        }

        var unmatched = result.interfaces
        for expected in request.interfaces {
            guard
                let index = unmatched.firstIndex(where: {
                    $0.networkID == expected.networkID
                        && $0.macAddress.caseInsensitiveCompare(expected.macAddress) == .orderedSame
                })
            else {
                throw ContainerizationError(
                    .invalidState,
                    message:
                        "guest network configuration result is missing network \(expected.networkID) interface \(expected.macAddress)"
                )
            }

            let applied = unmatched.remove(at: index)
            let expectedIPv4 = "\(expected.ipv4Address)/\(expected.ipv4PrefixLength)"
            guard applied.ipv4Address == expectedIPv4 else {
                throw ContainerizationError(
                    .invalidState,
                    message:
                        "guest network IPv4 mismatch for \(expected.networkID): requested \(expectedIPv4), effective \(applied.ipv4Address)"
                )
            }
            let expectedIPv6 = try requestedIPv6CIDR(expected)
            guard applied.ipv6Address == expectedIPv6 else {
                throw ContainerizationError(
                    .invalidState,
                    message:
                        "guest network IPv6 mismatch for \(expected.networkID): requested \(expectedIPv6 ?? "none"), effective \(applied.ipv6Address ?? "none")"
                )
            }
            if let requestedMTU = expected.mtu, applied.effectiveMTU != requestedMTU {
                let effectiveMTU = applied.effectiveMTU.map { String($0) } ?? "unreported"
                throw ContainerizationError(
                    .invalidState,
                    message:
                        "guest network MTU mismatch for \(expected.networkID): requested \(requestedMTU), effective \(effectiveMTU)"
                )
            }
        }

        guard let requestedDNS = request.dns else {
            return
        }
        guard !request.interfaces.isEmpty else {
            throw ContainerizationError(
                .invalidState,
                message: "guest DNS configuration requires a primary network interface"
            )
        }
        guard result.dnsApplied, let effectiveDNS = result.effectiveDNS else {
            throw ContainerizationError(
                .invalidState,
                message: "guest did not report an effective DNS resolver"
            )
        }
        guard !effectiveDNS.serviceID.isEmpty else {
            throw ContainerizationError(
                .invalidState,
                message: "guest effective DNS resolver is missing its SystemConfiguration service identifier"
            )
        }

        let primaryIndex = min(max(request.primaryInterfaceIndex, 0), request.interfaces.count - 1)
        let primary = request.interfaces[primaryIndex]
        guard
            let appliedPrimary = result.interfaces.first(where: {
                $0.networkID == primary.networkID
                    && $0.macAddress.caseInsensitiveCompare(primary.macAddress) == .orderedSame
            }),
            effectiveDNS.interfaceName == appliedPrimary.interfaceName
        else {
            throw ContainerizationError(
                .invalidState,
                message: "guest effective DNS resolver is not attached to the primary interface"
            )
        }

        guard effectiveDNS.nameservers == requestedDNS.nameservers else {
            throw ContainerizationError(
                .invalidState,
                message:
                    "guest DNS nameserver mismatch: requested \(requestedDNS.nameservers), effective \(effectiveDNS.nameservers)"
            )
        }
        let requestedDomain = normalizedDNSDomain(requestedDNS.domain)
        guard effectiveDNS.domain == requestedDomain else {
            throw ContainerizationError(
                .invalidState,
                message:
                    "guest DNS domain mismatch: requested \(requestedDomain ?? "none"), effective \(effectiveDNS.domain ?? "none")"
            )
        }
        guard effectiveDNS.searchDomains == requestedDNS.searchDomains else {
            throw ContainerizationError(
                .invalidState,
                message:
                    "guest DNS search domain mismatch: requested \(requestedDNS.searchDomains), effective \(effectiveDNS.searchDomains)"
            )
        }
        guard effectiveDNS.options == requestedDNS.options else {
            throw ContainerizationError(
                .invalidState,
                message:
                    "guest DNS option mismatch: requested \(requestedDNS.options), effective \(effectiveDNS.options)"
            )
        }
    }

    private static func makeDNSConfiguration(
        lease: MacOSGuestNetworkLease
    ) -> MacOSGuestDNSConfiguration? {
        guard let dns = lease.attachments.first?.dns else {
            return nil
        }

        return MacOSGuestDNSConfiguration(
            nameservers: dns.nameservers,
            domain: dns.domain,
            searchDomains: dns.searchDomains,
            options: dns.options
        )
    }

    private static func requestedIPv6CIDR(
        _ interface: MacOSGuestNetworkInterfaceConfiguration
    ) throws -> String? {
        switch (interface.ipv6Address, interface.ipv6PrefixLength, interface.ipv6Gateway) {
        case (nil, nil, nil):
            return nil
        case (.some(let address), .some(let prefixLength), .some(_)):
            return "\(address)/\(prefixLength)"
        default:
            throw ContainerizationError(
                .invalidState,
                message: "guest network request contains incomplete IPv6 intent for network \(interface.networkID)"
            )
        }
    }

    private static func normalizedDNSDomain(_ domain: String?) -> String? {
        guard let domain, !domain.isEmpty else {
            return nil
        }
        return domain
    }
}
