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

import ContainerAPIClient
import Foundation

extension ContainerKit {
    public func listNetworks() async throws -> [NetworkState] {
        try await ClientNetwork.list()
    }

    public func getNetwork(id: String) async throws -> NetworkState {
        try await ClientNetwork.get(id: id)
    }

    public func createNetwork(configuration: NetworkConfiguration) async throws -> NetworkState {
        try await ClientNetwork.create(configuration: configuration)
    }

    public func deleteNetwork(id: String) async throws {
        try await ClientNetwork.delete(id: id)
    }

    public func applySandboxPolicy(_ policy: SandboxNetworkPolicy) async throws -> SandboxNetworkPolicyState {
        try await ClientNetwork.applySandboxPolicy(policy)
    }

    public func removeSandboxPolicy(sandboxID: String) async throws {
        try await ClientNetwork.removeSandboxPolicy(sandboxID: sandboxID)
    }

    public func inspectSandboxPolicy(sandboxID: String) async throws -> SandboxNetworkPolicyState? {
        try await ClientNetwork.inspectSandboxPolicy(sandboxID: sandboxID)
    }
}
