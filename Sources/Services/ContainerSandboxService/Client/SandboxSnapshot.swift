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

/// A snapshot of a sandbox and its resources.
public struct SandboxSnapshot: Codable, Sendable {
    /// Static sandbox configuration, if available.
    public var configuration: SandboxConfiguration?
    /// The runtime status of the sandbox.
    public var status: RuntimeStatus
    /// Network attachments for the sandbox.
    public var networks: [Attachment]
    /// Containers placed in the sandbox.
    public var containers: [ContainerSnapshot]
    /// Workloads running inside the sandbox.
    public var workloads: [WorkloadSnapshot]
    /// Applied sandbox network policy state, if available.
    public var networkPolicy: SandboxNetworkPolicyState?

    enum CodingKeys: String, CodingKey {
        case configuration
        case status
        case networks
        case containers
        case workloads
        case networkPolicy
    }

    public init(
        configuration: SandboxConfiguration? = nil,
        status: RuntimeStatus,
        networks: [Attachment],
        containers: [ContainerSnapshot],
        workloads: [WorkloadSnapshot] = [],
        networkPolicy: SandboxNetworkPolicyState? = nil
    ) {
        self.configuration = configuration
        self.status = status
        self.networks = networks
        self.containers = containers
        self.workloads = workloads
        self.networkPolicy = networkPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(RuntimeStatus.self, forKey: .status)
        networks = try container.decode([Attachment].self, forKey: .networks)
        containers = try container.decode([ContainerSnapshot].self, forKey: .containers)
        workloads = try container.decodeIfPresent([WorkloadSnapshot].self, forKey: .workloads) ?? []
        networkPolicy = try container.decodeIfPresent(SandboxNetworkPolicyState.self, forKey: .networkPolicy)
        configuration =
            try container.decodeIfPresent(SandboxConfiguration.self, forKey: .configuration)
            ?? containers.first.map { SandboxConfiguration(containerConfiguration: $0.configuration) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encode(status, forKey: .status)
        try container.encode(networks, forKey: .networks)
        try container.encode(containers, forKey: .containers)
        try container.encode(workloads, forKey: .workloads)
        try container.encodeIfPresent(networkPolicy, forKey: .networkPolicy)
    }
}
