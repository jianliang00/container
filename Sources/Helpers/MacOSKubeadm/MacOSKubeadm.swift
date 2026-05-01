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
import ContainerMacOSKubeadm
import Foundation

@main
struct MacOSKubeadm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-macos-kubeadm",
        abstract: "Bootstrap a macOS Kubernetes worker node for container.",
        subcommands: [
            Join.self
        ]
    )
}

extension MacOSKubeadm {
    struct Join: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "join",
            abstract: "Configure and start a macOS Kubernetes worker node."
        )

        @Option(help: "Kubernetes API server URL, for example https://10.0.0.10:6443.")
        var apiserver: String

        @Option(help: "Node name used by kubelet and kube-proxy.")
        var nodeName: String = "macos-node-1"

        @Option(help: "Kubelet TLS bootstrap token. This value is written to bootstrap-kubelet.kubeconfig and is never logged.")
        var bootstrapToken: String

        @Option(help: "Bearer token used by container-kube-proxy-macos. This value is written to kube-proxy.kubeconfig and is never logged.")
        var kubeProxyToken: String

        @Option(help: "Path to the cluster CA certificate.")
        var caCert: String

        @Option(help: "Optional sha256:<hex> or <hex> checksum for the CA certificate file.")
        var caCertSha256: String?

        @Option(help: "Kubernetes cluster name rendered into generated kubeconfigs.")
        var clusterName: String = "kubernetes"

        @Option(help: "Cluster DNS service IP rendered into kubelet-config.yaml.")
        var clusterDNS: String = "10.96.0.10"

        @Option(help: "Cluster DNS domain rendered into kubelet-config.yaml.")
        var clusterDomain: String = "cluster.local"

        @Option(help: "macOS sandbox image used by CRI shim and kubelet.")
        var sandboxImage: String = "localhost/macos-sandbox:latest"

        @Option(help: "Alternate filesystem root for tests and image assembly. Normal deployments use '/'.")
        var installRoot: String = "/"

        @Flag(help: "Write no files and start no services; print the planned actions.")
        var dryRun: Bool = false

        @Flag(help: "Only render files; do not start container, CRI shim, kube-proxy, or kubelet services.")
        var skipStart: Bool = false

        @Flag(help: "Enable debug logs, including command output and planned actions.")
        var debug: Bool = false

        func run() throws {
            guard let apiServer = URL(string: apiserver) else {
                throw ValidationError("--apiserver must be a valid URL")
            }

            let options = MacOSKubeadmJoinOptions(
                apiServer: apiServer,
                nodeName: nodeName,
                bootstrapToken: bootstrapToken,
                kubeProxyToken: kubeProxyToken,
                caCertificatePath: caCert,
                caCertificateSHA256: caCertSha256,
                clusterName: clusterName,
                clusterDNS: clusterDNS,
                clusterDomain: clusterDomain,
                sandboxImage: sandboxImage,
                installRoot: installRoot,
                startServices: !skipStart,
                dryRun: dryRun,
                debug: debug
            )

            let log = MacOSKubeadmLog(debugEnabled: debug)
            let runner = MacOSKubeadmJoinRunner()
            try runner.run(options: options, log: log)
        }
    }
}
