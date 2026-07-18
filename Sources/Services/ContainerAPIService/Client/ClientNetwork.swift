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
import ContainerXPC
import ContainerizationError
import ContainerizationOS
import Foundation

public struct ClientNetwork {
    static let serviceIdentifier = NetworkClient.defaultServiceIdentifier

    public static let defaultNetworkName = "default"
    public static let noNetworkName = "none"
}

extension ClientNetwork {
    private static func newClient() -> XPCClient {
        XPCClient(service: serviceIdentifier)
    }

    private static func xpcSend(
        client: XPCClient,
        message: XPCMessage,
        timeout: Duration? = .seconds(15)
    ) async throws -> XPCMessage {
        try await client.send(message, responseTimeout: timeout)
    }

    public static func create(configuration: NetworkConfiguration) async throws -> NetworkResource {
        try await NetworkClient().create(configuration: configuration)
    }

    public static func list() async throws -> [NetworkResource] {
        try await NetworkClient().list()
    }

    /// Get the network for the provided id.
    public static func get(id: String) async throws -> NetworkResource {
        try await NetworkClient().get(id: id)
    }

    /// Delete the network with the given id.
    public static func delete(id: String) async throws {
        try await NetworkClient().delete(id: id)
    }

    public static func prepareSandboxNetwork(sandboxID: String) async throws -> SandboxNetworkState {
        let client = Self.newClient()
        let request = XPCMessage(route: .networkPrepareSandbox)
        request.set(key: .id, value: sandboxID)

        let response = try await xpcSend(client: client, message: request)
        return try response.sandboxNetworkState()
    }

    public static func inspectSandboxNetwork(sandboxID: String) async throws -> SandboxNetworkState {
        let client = Self.newClient()
        let request = XPCMessage(route: .networkInspectSandbox)
        request.set(key: .id, value: sandboxID)

        let response = try await xpcSend(client: client, message: request)
        return try response.sandboxNetworkState()
    }

    public static func releaseSandboxNetwork(sandboxID: String) async throws {
        let client = Self.newClient()
        let request = XPCMessage(route: .networkReleaseSandbox)
        request.set(key: .id, value: sandboxID)

        _ = try await xpcSend(client: client, message: request)
    }

    @discardableResult
    public static func applySandboxPolicy(_ policy: SandboxNetworkPolicy) async throws -> SandboxNetworkPolicyState {
        let client = Self.newClient()
        let request = XPCMessage(route: .networkApplySandboxPolicy)
        request.set(key: .id, value: policy.sandboxID)
        request.set(key: .networkPolicy, value: try JSONEncoder().encode(policy))

        let response = try await xpcSend(client: client, message: request)
        let responseData = response.dataNoCopy(key: .networkPolicyState)
        guard let responseData else {
            throw ContainerizationError(.invalidArgument, message: "network policy state not received")
        }
        return try JSONDecoder().decode(SandboxNetworkPolicyState.self, from: responseData)
    }

    public static func removeSandboxPolicy(sandboxID: String) async throws {
        let client = Self.newClient()
        let request = XPCMessage(route: .networkRemoveSandboxPolicy)
        request.set(key: .id, value: sandboxID)
        _ = try await xpcSend(client: client, message: request)
    }

    public static func inspectSandboxPolicy(sandboxID: String) async throws -> SandboxNetworkPolicyState? {
        let client = Self.newClient()
        let request = XPCMessage(route: .networkInspectSandboxPolicy)
        request.set(key: .id, value: sandboxID)

        let response = try await xpcSend(client: client, message: request)
        guard let responseData = response.dataNoCopy(key: .networkPolicyState) else {
            return nil
        }
        return try JSONDecoder().decode(SandboxNetworkPolicyState.self, from: responseData)
    }

    /// Retrieve the builtin network.
    public static var builtin: NetworkResource? {
        get async throws {
            try await NetworkClient().builtin
        }
    }
}

extension XPCMessage {
    fileprivate func sandboxNetworkState() throws -> SandboxNetworkState {
        guard let data = dataNoCopy(key: .networkState) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "sandbox network state not received"
            )
        }
        return try JSONDecoder().decode(SandboxNetworkState.self, from: data)
    }
}
