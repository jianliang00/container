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

/// Coordinates image removal with the gap between sandbox admission and metadata persistence.
public actor CRIShimImageGCProtection {
    private let configuredReferences: Set<String>
    private let metadataStore: CRIShimMetadataStore?
    private let runtimeManager: (any CRIShimRuntimeManaging)?
    private var preparing: [String: Int] = [:]
    private var removing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(config: CRIShimConfig = CRIShimConfig(), metadataStore: CRIShimMetadataStore? = nil, runtimeManager: (any CRIShimRuntimeManaging)? = nil) {
        configuredReferences = Set(([config.defaults?.sandboxImage] + config.runtimeHandlers.values.map(\.sandboxImage)).compactMap { $0 })
        self.metadataStore = metadataStore
        self.runtimeManager = runtimeManager
    }

    public func references() async throws -> Set<String> {
        let snapshots = try await runtimeManager?.listSandboxSnapshots() ?? []
        let runtimeReferences = try snapshots.flatMap { snapshot -> [String] in
            guard let configuration = snapshot.configuration else {
                throw CRIShimError.unavailable("cannot determine sandbox image references")
            }
            return [configuration.image.reference, configuration.image.digest]
        }
        let sandboxes = try metadataStore?.listSandboxes() ?? []
        return configuredReferences.union(preparing.keys).union(sandboxes.map(\.sandboxImage)).union(runtimeReferences)
    }

    public func withProtectedImage<T: Sendable>(
        _ reference: String, operation: @Sendable () async throws -> T
    ) async throws -> T {
        await waitForRemoval()
        try Task.checkCancellation()
        preparing[reference, default: 0] += 1
        defer {
            if preparing[reference] == 1 { preparing.removeValue(forKey: reference) } else { preparing[reference, default: 0] -= 1 }
        }
        return try await operation()
    }

    public func withRemoval<T: Sendable>(
        operation: @Sendable (Set<String>) async throws -> T
    ) async throws -> T {
        await waitForRemoval()
        try Task.checkCancellation()
        removing = true
        defer {
            removing = false
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        return try await operation(await references())
    }

    private func waitForRemoval() async {
        while removing {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
