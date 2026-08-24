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
    public var pendingFamily: KubeProxyAddressFamily?

    public init(
        ruleSet: KubeProxyRuleSet,
        applied: Bool,
        pendingFamily: KubeProxyAddressFamily? = nil
    ) {
        self.ruleSet = ruleSet
        self.applied = applied
        self.pendingFamily = pendingFamily
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
        let podNetwork: KubeProxyPodNetworkResolution
        do {
            podNetwork = try KubeProxyPodNetworkStateResolver.resolve(config: config)
        } catch {
            do {
                try applier.withdraw()
            } catch let withdrawError {
                throw KubeProxyMacOSError.applyFailed(
                    "pod network readiness failed (\(error)); fail-closed PF withdrawal also failed (\(withdrawError))"
                )
            }
            throw error
        }
        if config.dualStackEnabled, !podNetwork.ipv6Ready {
            try applier.withdrawIPv6()
        }
        let snapshot = try await reader.snapshot()
        let compiledRuleSet = KubeProxyCompiler.compile(
            snapshot: snapshot,
            nodeName: config.nodeName,
            generation: generation
        )
        var enabledFamilies: Set<KubeProxyAddressFamily> = [.ipv4]
        if config.dualStackEnabled, podNetwork.ipv6Ready {
            enabledFamilies.insert(.ipv6)
        }
        let ruleSet = compiledRuleSet.selecting(families: enabledFamilies)
        do {
            try applier.apply(
                ruleSet,
                podNetwork: KubeProxyFamilyRuleApplication(
                    ipv4PodCIDR: podNetwork.ipv4PodCIDR,
                    ipv6PodCIDR: podNetwork.ipv6PodCIDR,
                    ipv4Ready: podNetwork.ipv4Ready,
                    ipv6Ready: podNetwork.ipv6Ready,
                    dualStackEnabled: config.dualStackEnabled,
                    masqueradeIPv4PodTraffic: podNetwork.masqueradeIPv4PodTraffic,
                    masqueradeIPv6PodTraffic: podNetwork.masqueradeIPv6PodTraffic
                )
            )
        } catch KubeProxyPodIngressRouteTransitionError.unavailableAfterWithdrawal(let family) {
            return KubeProxyRunResult(
                ruleSet: ruleSet,
                applied: false,
                pendingFamily: family
            )
        }
        guard !config.dualStackEnabled || podNetwork.ipv6Ready else {
            throw KubeProxyMacOSError.applyFailed("pod network IPv6 family is not ready")
        }
        return KubeProxyRunResult(ruleSet: ruleSet, applied: true)
    }

    public func runForever(
        onError: @escaping @Sendable (Error) -> Void = { error in
            fputs("container-kube-proxy-macos: \(error)\n", stderr)
        }
    ) async throws -> Never {
        try await runForeverReportingResults(
            onResult: { _ in },
            onFailure: { _, _ in },
            onError: onError
        )
    }

    public func runForeverReportingResults(
        onResult: @escaping @Sendable (KubeProxyRunResult) -> Void,
        onFailure: @escaping @Sendable (_ generation: Int, _ error: Error) -> Void,
        onError: @escaping @Sendable (Error) -> Void = { error in
            fputs("container-kube-proxy-macos: \(error)\n", stderr)
        }
    ) async throws -> Never {
        var generation = 1
        var reportedPendingFamily: KubeProxyAddressFamily?
        while true {
            try Task.checkCancellation()
            do {
                let result = try await runOnce(generation: generation)
                onResult(result)
                if result.applied {
                    reportedPendingFamily = nil
                    generation += 1
                } else if let pendingFamily = result.pendingFamily,
                    reportedPendingFamily != pendingFamily
                {
                    reportedPendingFamily = pendingFamily
                    onError(KubeProxyPodIngressRouteTransitionError.unavailableAfterWithdrawal(pendingFamily))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reportedPendingFamily = nil
                onFailure(generation, error)
                onError(error)
            }
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
