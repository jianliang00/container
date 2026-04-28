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

    @Flag(name: .customLong("once"), help: "Run one relist/reconcile cycle and exit.")
    var once: Bool = false

    @Flag(name: .customLong("dry-run"), help: "Print the generated PF anchor instead of applying it.")
    var dryRun: Bool = false

    @Option(name: .customLong("snapshot"), help: "Path to a KubeProxySnapshot JSON file. Useful for dry-run validation.")
    var snapshotPath: String?

    func run() async throws {
        let config = try KubeProxyMacOSConfig.load(from: URL(fileURLWithPath: configPath))
        if let snapshotPath {
            let data = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
            let snapshot = try JSONDecoder().decode(KubeProxySnapshot.self, from: data)
            let reader = KubeProxyStaticSnapshotReader(snapshot)
            try await runWithReader(config: config, reader: reader)
        } else {
            let reader = try KubeProxyKubernetesClient(kubeconfigPath: config.kubeconfig)
            try await runWithReader(config: config, reader: reader)
        }
    }

    private func runWithReader<Reader: KubeProxyKubernetesReading>(
        config: KubeProxyMacOSConfig,
        reader: Reader
    ) async throws {
        if dryRun {
            let applier = KubeProxyDryRunRuleApplier(anchorName: config.pf.anchorName) { anchor in
                print(anchor, terminator: "")
            }
            try await runController(config: config, reader: reader, applier: applier)
        } else {
            let applier = KubeProxyPFRuleApplier(config: config.pf)
            try await runController(config: config, reader: reader, applier: applier)
        }
    }

    private func runController<Reader: KubeProxyKubernetesReading, Applier: KubeProxyRuleApplying>(
        config: KubeProxyMacOSConfig,
        reader: Reader,
        applier: Applier
    ) async throws {
        let controller = KubeProxyController(config: config, reader: reader, applier: applier)
        if once {
            let result = try await controller.runOnce(generation: 1)
            fputs(
                "container-kube-proxy-macos reconciled \(result.ruleSet.rules.count) Service port rules with \(result.ruleSet.issues.count) issues\n",
                stderr
            )
        } else {
            try await controller.runForever()
        }
    }
}
