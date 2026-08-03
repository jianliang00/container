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
            return MacOSGuestNetworkInterfaceConfiguration(
                networkID: attachment.network,
                hostname: attachment.hostname,
                macAddress: macAddress,
                ipv4Address: attachment.ipv4Address.address.description,
                ipv4PrefixLength: attachment.ipv4Address.prefix.length,
                ipv4Gateway: attachment.ipv4Gateway.description,
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

    private static func normalizedDNSDomain(_ domain: String?) -> String? {
        guard let domain, !domain.isEmpty else {
            return nil
        }
        return domain
    }
}
