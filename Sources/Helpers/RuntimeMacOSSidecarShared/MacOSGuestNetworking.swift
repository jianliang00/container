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
import Foundation

public struct MacOSGuestNetworkConfiguration: Codable, Sendable {
    public let interfaceMACAddress: String?
    public let ipv4Address: String?
    public let ipv4PrefixLength: UInt8?
    public let ipv4Gateway: String?
    public let nameservers: [String]
    public let searchDomains: [String]
    public let domain: String?

    public init(
        interfaceMACAddress: String? = nil,
        ipv4Address: String? = nil,
        ipv4PrefixLength: UInt8? = nil,
        ipv4Gateway: String? = nil,
        nameservers: [String] = [],
        searchDomains: [String] = [],
        domain: String? = nil
    ) {
        self.interfaceMACAddress = interfaceMACAddress
        self.ipv4Address = ipv4Address
        self.ipv4PrefixLength = ipv4PrefixLength
        self.ipv4Gateway = ipv4Gateway
        self.nameservers = nameservers
        self.searchDomains = searchDomains
        self.domain = domain
    }

    public var isEmpty: Bool {
        interfaceMACAddress == nil
            && ipv4Address == nil
            && ipv4PrefixLength == nil
            && ipv4Gateway == nil
            && nameservers.isEmpty
            && searchDomains.isEmpty
            && domain == nil
    }
}

public struct MacOSSidecarBootstrapResult: Codable, Sendable {
    public let attachments: [Attachment]

    public init(attachments: [Attachment] = []) {
        self.attachments = attachments
    }
}
