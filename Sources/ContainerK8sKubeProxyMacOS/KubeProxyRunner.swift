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

public struct KubeProxyRunResult: Codable, Sendable, Equatable {
    public var ruleSet: KubeProxyRuleSet
    public var applied: Bool

    public init(ruleSet: KubeProxyRuleSet, applied: Bool) {
        self.ruleSet = ruleSet
        self.applied = applied
    }
}

public struct KubeProxyController<Reader: KubeProxyKubernetesReading, Applier: KubeProxyRuleApplying>: Sendable {
    public let config: KubeProxyMacOSConfig
    public let reader: Reader
    public let applier: Applier

    public init(config: KubeProxyMacOSConfig, reader: Reader, applier: Applier) {
        self.config = config
        self.reader = reader
        self.applier = applier
    }

    @discardableResult
    public func runOnce(generation: Int = 0) async throws -> KubeProxyRunResult {
        let snapshot = try await reader.snapshot()
        let ruleSet = KubeProxyCompiler.compile(
            snapshot: snapshot,
            nodeName: config.nodeName,
            generation: generation
        )
        try applier.apply(ruleSet)
        return KubeProxyRunResult(ruleSet: ruleSet, applied: true)
    }

    public func runForever() async throws -> Never {
        var generation = 1
        while true {
            try Task.checkCancellation()
            _ = try await runOnce(generation: generation)
            generation += 1
            try await Task.sleep(for: .seconds(config.syncPeriodSeconds))
        }
    }
}

public struct KubeProxyStaticSnapshotReader: KubeProxyKubernetesReading {
    public let value: KubeProxySnapshot

    public init(_ value: KubeProxySnapshot) {
        self.value = value
    }

    public func snapshot() async throws -> KubeProxySnapshot {
        value
    }
}
