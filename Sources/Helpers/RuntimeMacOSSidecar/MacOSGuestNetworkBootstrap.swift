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
        allocations: [MacOSGuestNetworkAllocation]
    ) throws -> MacOSGuestNetworkConfigurationRequest? {
        guard containerConfig.macosGuest?.networkBackend == .vmnetShared else {
            return nil
        }
        guard !allocations.isEmpty else {
            return nil
        }

        let interfaces = try allocations.map { allocation in
            guard let macAddress = allocation.attachment.macAddress?.description else {
                throw ContainerizationError(
                    .invalidState,
                    message: "guest network bootstrap requires a MAC address for network \(allocation.network)"
                )
            }
            return MacOSGuestNetworkInterfaceConfiguration(
                networkID: allocation.network,
                hostname: allocation.hostname,
                macAddress: macAddress,
                ipv4Address: allocation.attachment.ipv4Address.address.description,
                ipv4PrefixLength: allocation.attachment.ipv4Address.prefix.length,
                ipv4Gateway: allocation.attachment.ipv4Gateway.description
            )
        }

        return MacOSGuestNetworkConfigurationRequest(
            interfaces: interfaces,
            primaryInterfaceIndex: 0,
            dns: makeDNSConfiguration(containerConfig: containerConfig, allocations: allocations)
        )
    }

    private static func makeDNSConfiguration(
        containerConfig: ContainerConfiguration,
        allocations: [MacOSGuestNetworkAllocation]
    ) -> MacOSGuestDNSConfiguration? {
        guard let dns = containerConfig.dns else {
            return nil
        }

        let nameservers: [String]
        if dns.nameservers.isEmpty {
            nameservers = orderedUniqueValues(allocations.map { $0.attachment.ipv4Gateway.description })
        } else {
            nameservers = dns.nameservers
        }

        return MacOSGuestDNSConfiguration(
            nameservers: nameservers,
            domain: dns.domain,
            searchDomains: dns.searchDomains,
            options: dns.options
        )
    }

    private static func orderedUniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
