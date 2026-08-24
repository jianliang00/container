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

import ArgumentParser
import ContainerK8sKubeProxyMacOS
import Foundation

@main
struct KubeProxyMacOS: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-kube-proxy-macos",
        abstract: "Program macOS PF rules for single-node Kubernetes ClusterIP Services."
    )

    @Option(name: [.customLong("config"), .short], help: "Path to the container kube-proxy macOS JSON config.")
    var configPath: String

    @Flag(
        name: .customLong("once"),
        help: "Run one relist/reconcile cycle and exit. Stop the launchd-managed daemon before applying manually."
    )
    var once: Bool = false

    @Flag(name: .customLong("dry-run"), help: "Print the generated PF anchor instead of applying it.")
    var dryRun: Bool = false

    @Flag(
        name: .customLong("withdraw"),
        help:
            "Remove managed PF references, flush both family anchors, and delete their files. Stop the launchd-managed daemon first."
    )
    var withdraw: Bool = false

    @Option(name: .customLong("snapshot"), help: "Path to a KubeProxySnapshot JSON file. Useful for dry-run validation.")
    var snapshotPath: String?

    func run() async throws {
        if withdraw {
            guard !once, !dryRun, snapshotPath == nil else {
                throw ValidationError("--withdraw cannot be combined with --once, --dry-run, or --snapshot")
            }
            let configURL = URL(fileURLWithPath: configPath).standardizedFileURL
            let pfConfig: KubeProxyPFConfig
            let statusPath: String
            if FileManager.default.fileExists(atPath: configURL.path) {
                let config = try KubeProxyMacOSConfig.load(from: configURL)
                pfConfig = config.pf
                statusPath = config.statusPath ?? KubeProxyMacOSConfig.defaultStatusPath
            } else {
                guard configURL.path == "/etc/kubernetes/kube-proxy.conf" else {
                    throw ValidationError("--withdraw config is missing at \(configURL.path)")
                }
                pfConfig = KubeProxyPFConfig()
                statusPath = KubeProxyMacOSConfig.defaultStatusPath
                try pfConfig.validate()
            }
            try KubeProxyPFRuleApplier(config: pfConfig).withdraw()
            do {
                try KubeProxyStatusFileStore(path: statusPath).remove()
            } catch {
                fputs(
                    "container-kube-proxy-macos: managed PF rules were withdrawn, but status cleanup failed: \(error)\n",
                    stderr
                )
            }
            return
        }
        let config = try KubeProxyMacOSConfig.load(from: URL(fileURLWithPath: configPath))
        let statusRecorder: KubeProxyStatusRecorder? =
            dryRun
            ? nil
            : config.statusPath.map {
                KubeProxyStatusRecorder(store: KubeProxyStatusFileStore(path: $0))
            }
        if let statusRecorder {
            do {
                try statusRecorder.recordStarting(config: config)
            } catch {
                Self.invalidateStaleStatus(statusRecorder, after: error)
            }
        }
        if let snapshotPath {
            let snapshot: KubeProxySnapshot
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
                snapshot = try JSONDecoder().decode(KubeProxySnapshot.self, from: data)
            } catch {
                Self.recordFailureBestEffort(
                    error,
                    generation: 0,
                    config: config,
                    recorder: statusRecorder
                )
                throw error
            }
            let reader = KubeProxyStaticSnapshotReader(snapshot)
            try await runWithReader(config: config, reader: reader, statusRecorder: statusRecorder)
        } else {
            let reader: KubeProxyKubernetesClient
            do {
                reader = try KubeProxyKubernetesClient(kubeconfigPath: config.kubeconfig)
            } catch {
                Self.recordFailureBestEffort(
                    error,
                    generation: 0,
                    config: config,
                    recorder: statusRecorder
                )
                throw error
            }
            try await runWithReader(config: config, reader: reader, statusRecorder: statusRecorder)
        }
    }

    private func runWithReader<Reader: KubeProxyKubernetesReading>(
        config: KubeProxyMacOSConfig,
        reader: Reader,
        statusRecorder: KubeProxyStatusRecorder?
    ) async throws {
        if dryRun {
            let applier = KubeProxyDryRunRuleApplier(
                anchorName: config.pf.anchorName,
                egressInterface: config.pf.configuredEgressInterface,
                ipv6EgressInterface: config.pf.configuredIPv6EgressInterface,
                ipv6EgressSourceAddress: config.pf.configuredIPv6EgressSourceAddress
            ) { anchor in
                print(anchor, terminator: "")
            }
            try await runController(
                config: config,
                reader: reader,
                applier: applier,
                statusRecorder: nil
            )
        } else {
            let applier = KubeProxyPFRuleApplier(config: config.pf)
            try await runController(
                config: config,
                reader: reader,
                applier: applier,
                statusRecorder: statusRecorder
            )
        }
    }

    private func runController<Reader: KubeProxyKubernetesReading, Applier: KubeProxyRuleApplying>(
        config: KubeProxyMacOSConfig,
        reader: Reader,
        applier: Applier,
        statusRecorder: KubeProxyStatusRecorder?
    ) async throws {
        let controller = KubeProxyController(config: config, reader: reader, applier: applier)
        if once {
            let result: KubeProxyRunResult
            do {
                result = try await controller.runOnce(generation: 1)
            } catch {
                Self.recordFailureBestEffort(error, generation: 1, config: config, recorder: statusRecorder)
                throw error
            }
            do {
                try statusRecorder?.record(result: result, config: config)
            } catch {
                Self.invalidateStaleStatus(statusRecorder, after: error)
            }
            if let pendingFamily = result.pendingFamily {
                fputs(
                    "container-kube-proxy-macos withdrew managed PF rules and is waiting for a directly connected local \(pendingFamily.rawValue) PodCIDR route\n",
                    stderr
                )
                throw KubeProxyMacOSError.applyFailed(
                    "local \(pendingFamily.rawValue) PodCIDR route is not directly connected; managed PF rules were withdrawn"
                )
            }
            fputs(
                "container-kube-proxy-macos reconciled \(result.ruleSet.rules.count) Service port rules with \(result.ruleSet.issues.count) issues\n",
                stderr
            )
        } else {
            try await controller.runForeverReportingResults(
                onResult: { result in
                    do {
                        try statusRecorder?.record(result: result, config: config)
                    } catch {
                        Self.invalidateStaleStatus(statusRecorder, after: error)
                    }
                },
                onFailure: { generation, error in
                    Self.recordFailureBestEffort(
                        error,
                        generation: generation,
                        config: config,
                        recorder: statusRecorder
                    )
                }
            )
        }
    }

    private static func invalidateStaleStatus(
        _ recorder: KubeProxyStatusRecorder?,
        after persistenceError: Error
    ) {
        fputs("container-kube-proxy-macos: \(persistenceError)\n", stderr)
        do {
            try recorder?.remove()
        } catch {
            fputs(
                "container-kube-proxy-macos: failed to invalidate stale status after a persistence error: \(error)\n",
                stderr
            )
        }
    }

    private static func recordFailureBestEffort(
        _ error: Error,
        generation: Int,
        config: KubeProxyMacOSConfig,
        recorder: KubeProxyStatusRecorder?
    ) {
        do {
            try recorder?.recordFailure(error: error, generation: generation, config: config)
        } catch {
            invalidateStaleStatus(recorder, after: error)
        }
    }
}
