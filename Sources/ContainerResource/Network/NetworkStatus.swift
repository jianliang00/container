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

/// The runtime status of a network — the addresses assigned once the network
/// plugin is active. Only present after the network has started.
public struct NetworkStatus: Codable, Sendable {
    /// The IPv4 subnet assigned to the network.
    public let ipv4Subnet: CIDRv4

    /// The IPv4 gateway address.
    public let ipv4Gateway: IPv4Address

    /// The IPv6 subnet assigned to the network, if IPv6 is enabled.
    public let ipv6Subnet: CIDRv6?

    /// The IPv6 gateway address when IPv6 was explicitly configured.
    ///
    /// vmnet can report an automatically generated IPv6 prefix even when the
    /// network was created without IPv6 intent. Keeping the gateway optional
    /// prevents that prefix from being treated as a configured data plane.
    public let ipv6Gateway: IPv6Address?

    public init(
        ipv4Subnet: CIDRv4,
        ipv4Gateway: IPv4Address,
        ipv6Subnet: CIDRv6?,
        ipv6Gateway: IPv6Address? = nil
    ) {
        self.ipv4Subnet = ipv4Subnet
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Subnet = ipv6Subnet
        self.ipv6Gateway = ipv6Gateway
    }
}
