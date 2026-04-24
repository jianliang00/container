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

import Foundation

public protocol K8sNetworkPolicyControllerStateStore: Sendable {
    func load() throws -> K8sNetworkPolicyControllerState
    func save(_ state: K8sNetworkPolicyControllerState) throws
}

public struct FileK8sNetworkPolicyControllerStateStore: K8sNetworkPolicyControllerStateStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> K8sNetworkPolicyControllerState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return K8sNetworkPolicyControllerState()
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return K8sNetworkPolicyControllerState()
        }

        return try JSONDecoder().decode(K8sNetworkPolicyControllerState.self, from: data)
    }

    public func save(_ state: K8sNetworkPolicyControllerState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }
}

public final class InMemoryK8sNetworkPolicyControllerStateStore: K8sNetworkPolicyControllerStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var currentState: K8sNetworkPolicyControllerState
    private var savedStateSnapshots: [K8sNetworkPolicyControllerState]

    public var savedStates: [K8sNetworkPolicyControllerState] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return savedStateSnapshots
    }

    public init(state: K8sNetworkPolicyControllerState = K8sNetworkPolicyControllerState()) {
        self.currentState = state
        self.savedStateSnapshots = []
    }

    public func load() throws -> K8sNetworkPolicyControllerState {
        lock.lock()
        defer {
            lock.unlock()
        }
        return currentState
    }

    public func save(_ state: K8sNetworkPolicyControllerState) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        currentState = state
        savedStateSnapshots.append(state)
    }
}

public struct K8sNetworkPolicyControllerRunResult: Codable, Sendable, Equatable {
    public let reconcileResult: K8sNetworkPolicyReconcileResult
    public let appliedState: K8sNetworkPolicyControllerState

    public init(
        reconcileResult: K8sNetworkPolicyReconcileResult,
        appliedState: K8sNetworkPolicyControllerState
    ) {
        self.reconcileResult = reconcileResult
        self.appliedState = appliedState
    }
}

public struct K8sNetworkPolicyControllerRunner<Adapter: K8sNetworkPolicyAdapter>: Sendable {
    public let config: K8sNetworkPolicyControllerConfig
    public let adapter: Adapter
    public let stateStore: any K8sNetworkPolicyControllerStateStore

    public init(
        config: K8sNetworkPolicyControllerConfig,
        adapter: Adapter,
        stateStore: any K8sNetworkPolicyControllerStateStore
    ) {
        self.config = config
        self.adapter = adapter
        self.stateStore = stateStore
    }

    @discardableResult
    public func runOnce(snapshot: K8sNetworkPolicyControllerSnapshot) async throws -> K8sNetworkPolicyControllerRunResult {
        let currentState = try stateStore.load()
        let reconcileResult = try K8sNetworkPolicyController.reconcile(
            config: config,
            snapshot: snapshot,
            currentState: currentState
        )
        let appliedState = try await adapter.execute(
            reconcileResult.plan,
            currentState: currentState
        )
        try stateStore.save(appliedState)

        return K8sNetworkPolicyControllerRunResult(
            reconcileResult: reconcileResult,
            appliedState: appliedState
        )
    }
}
