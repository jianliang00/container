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

import ContainerizationExtras

public struct MacOSGuestNetworkRequest: Sendable, Equatable {
    public static let defaultNetworkID = "default"

    public let network: String
    public let hostname: String
    public let macAddress: MACAddress?

    public init(network: String, hostname: String, macAddress: MACAddress?) {
        self.network = network
        self.hostname = hostname
        self.macAddress = macAddress
    }
}

extension ContainerConfiguration {
    public func macOSGuestNetworkRequests(
        defaultNetworkID: String = MacOSGuestNetworkRequest.defaultNetworkID
    ) -> [MacOSGuestNetworkRequest] {
        if !networks.isEmpty {
            return networks.map {
                MacOSGuestNetworkRequest(
                    network: $0.network,
                    hostname: $0.options.hostname,
                    macAddress: $0.options.macAddress
                )
            }
        }

        return [
            MacOSGuestNetworkRequest(
                network: defaultNetworkID,
                hostname: id,
                macAddress: nil
            )
        ]
    }

    public func macOSGuestReportedNetworkAttachments(_ attachments: [Attachment]) -> [Attachment] {
        guard let dns = macOSGuestReportedDNS(attachments: attachments) else {
            return attachments
        }
        return attachments.map { $0.withDNS(dns) }
    }

    public func macOSGuestReportedDNS(attachments: [Attachment]) -> Attachment.DNSConfiguration? {
        guard let dns else {
            return nil
        }

        let nameservers: [String]
        if dns.nameservers.isEmpty {
            nameservers = orderedUniqueMacOSGuestValues(attachments.map { $0.ipv4Gateway.description })
        } else {
            nameservers = dns.nameservers
        }

        return Attachment.DNSConfiguration(
            nameservers: nameservers,
            domain: dns.domain,
            searchDomains: dns.searchDomains,
            options: dns.options
        )
    }

    private func orderedUniqueMacOSGuestValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
