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
                ipv4Gateway: attachment.ipv4Gateway.description
            )
        }

        return MacOSGuestNetworkConfigurationRequest(
            interfaces: interfaces,
            primaryInterfaceIndex: 0,
            dns: makeDNSConfiguration(lease: lease)
        )
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
            options: []
        )
    }
}
