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

public struct CRIShimRuntimeInventory: Codable, Equatable, Sendable {
    public var sandboxes: [CRIShimRuntimeSandboxInventory]
    public var containers: [CRIShimRuntimeContainerInventory]

    public init(
        sandboxes: [CRIShimRuntimeSandboxInventory] = [],
        containers: [CRIShimRuntimeContainerInventory] = []
    ) {
        self.sandboxes = sandboxes
        self.containers = containers
    }
}

public enum CRIShimRuntimeObjectState: String, Codable, Sendable, Equatable {
    case live
    case released
}

public struct CRIShimRuntimeSandboxInventory: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var state: CRIShimRuntimeObjectState
    public var fingerprint: String

    public init(id: String, state: CRIShimRuntimeObjectState, fingerprint: String) {
        self.id = id
        self.state = state
        self.fingerprint = fingerprint
    }
}

public struct CRIShimRuntimeContainerInventory: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var state: CRIShimRuntimeObjectState
    public var fingerprint: String

    public init(id: String, state: CRIShimRuntimeObjectState, fingerprint: String) {
        self.id = id
        self.state = state
        self.fingerprint = fingerprint
    }
}

public struct CRIShimReconcilePlan: Codable, Equatable, Sendable {
    public var sandboxSteps: [CRIShimReconcileStep]
    public var containerSteps: [CRIShimReconcileStep]

    public init(
        sandboxSteps: [CRIShimReconcileStep] = [],
        containerSteps: [CRIShimReconcileStep] = []
    ) {
        self.sandboxSteps = sandboxSteps
        self.containerSteps = containerSteps
    }

    public var isEmpty: Bool {
        sandboxSteps.isEmpty && containerSteps.isEmpty
    }
}

public struct CRIShimReconcileStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case sandbox
        case container
    }

    public enum Action: String, Codable, Sendable, Equatable {
        case create
        case update
        case delete
        case release
    }

    public var kind: Kind
    public var action: Action
    public var id: String
    public var reason: String
    public var storeFingerprint: String?
    public var runtimeFingerprint: String?

    public init(
        kind: Kind,
        action: Action,
        id: String,
        reason: String,
        storeFingerprint: String? = nil,
        runtimeFingerprint: String? = nil
    ) {
        self.kind = kind
        self.action = action
        self.id = id
        self.reason = reason
        self.storeFingerprint = storeFingerprint
        self.runtimeFingerprint = runtimeFingerprint
    }
}

public struct CRIShimReconciler {
    public init() {}

    public func makePlan(
        store: CRIShimMetadataSnapshot,
        inventory: CRIShimRuntimeInventory
    ) -> CRIShimReconcilePlan {
        let sandboxSteps = reconcile(
            kind: .sandbox,
            stored: store.sandboxes.map { ($0.id, $0.reconcileFingerprint) },
            runtime: inventory.sandboxes.map { ($0.id, $0.state, $0.fingerprint) }
        )
        let containerSteps = reconcile(
            kind: .container,
            stored: store.containers.map { ($0.id, $0.reconcileFingerprint) },
            runtime: inventory.containers.map { ($0.id, $0.state, $0.fingerprint) }
        )
        return CRIShimReconcilePlan(sandboxSteps: sandboxSteps, containerSteps: containerSteps)
    }

    private func reconcile(
        kind: CRIShimReconcileStep.Kind,
        stored: [(String, String)],
        runtime: [(String, CRIShimRuntimeObjectState, String)]
    ) -> [CRIShimReconcileStep] {
        let storedByID = Dictionary(stored, uniquingKeysWith: { _, new in new })
        let runtimeByID = Dictionary(runtime.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { _, new in new })
        let ids = Set(storedByID.keys).union(runtimeByID.keys).sorted()
        var steps: [CRIShimReconcileStep] = []

        for id in ids {
            let storeFingerprint = storedByID[id]
            let runtimeEntry = runtimeByID[id]
            switch (storeFingerprint, runtimeEntry) {
            case (nil, nil):
                continue
            case (nil, let runtimeEntry?):
                steps.append(
                    CRIShimReconcileStep(
                        kind: kind,
                        action: runtimeEntry.0 == .released ? .release : .create,
                        id: id,
                        reason: runtimeEntry.0 == .released ? "runtime reported released \(kind.rawValue)" : "runtime entry missing from store",
                        runtimeFingerprint: runtimeEntry.1
                    )
                )
            case (let storeFingerprint?, nil):
                steps.append(
                    CRIShimReconcileStep(
                        kind: kind,
                        action: .delete,
                        id: id,
                        reason: "stored \(kind.rawValue) missing from runtime inventory",
                        storeFingerprint: storeFingerprint
                    )
                )
            case (let storeFingerprint?, let runtimeEntry?):
                if runtimeEntry.0 == .released {
                    steps.append(
                        CRIShimReconcileStep(
                            kind: kind,
                            action: .release,
                            id: id,
                            reason: "runtime reported released \(kind.rawValue)",
                            storeFingerprint: storeFingerprint,
                            runtimeFingerprint: runtimeEntry.1
                        )
                    )
                } else if storeFingerprint != runtimeEntry.1 {
                    steps.append(
                        CRIShimReconcileStep(
                            kind: kind,
                            action: .update,
                            id: id,
                            reason: "stored \(kind.rawValue) metadata differs from runtime inventory",
                            storeFingerprint: storeFingerprint,
                            runtimeFingerprint: runtimeEntry.1
                        )
                    )
                }
            }
        }

        return steps
    }
}
