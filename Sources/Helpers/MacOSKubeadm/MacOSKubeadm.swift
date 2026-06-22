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
            Join.self,
            Reset.self,
            Status.self,
        ]
    )
}

extension MacOSKubeadm {
    struct Join: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "join",
            abstract: "Configure and start a macOS Kubernetes worker node."
        )

        @Argument(help: "Kubernetes API server endpoint, for example 10.0.0.10:6443.")
        var apiServerEndpoint: String

        @Option(help: "Node name used by kubelet and kube-proxy.")
        var nodeName: String = "macos-node-1"

        @Option(help: "Kubelet TLS bootstrap token from kubeadm token create.")
        var token: String

        @Option(help: "Kubernetes discovery CA public key hash, for example sha256:<hex>.")
        var discoveryTokenCACertHash: [String] = []

        @Option(help: "macOS sandbox image used by CRI shim and kubelet.")
        var sandboxImage: String = "localhost/macos-sandbox:latest"

        @Option(help: "Additional RuntimeClass in name=sandbox-image format. May be repeated; each entry uses the selected --network-mode.")
        var runtimeClass: [String] = []

        @Option(help: "Node network mode: full or compat.")
        var networkMode: String = MacOSKubeadmNetworkMode.full.rawValue

        @Option(help: "UID whose bootstrap domain runs container core services. Defaults to SUDO_UID for compat joins, otherwise 0.")
        var containerServiceUser: Int?

        @Option(help: "Alternate filesystem root for tests and image assembly. Normal deployments use '/'.")
        var installRoot: String = "/"

        @Flag(help: "Write no files and start no services; print the planned actions.")
        var dryRun: Bool = false

        @Flag(help: "Only render files; do not start container, CRI shim, kube-proxy, or kubelet services.")
        var skipStart: Bool = false

        @Flag(help: "Enable debug logs, including command output and planned actions.")
        var debug: Bool = false

        func run() throws {
            let apiServer = try parseAPIServerEndpoint(apiServerEndpoint)
            let resolvedNetworkMode = try parseNetworkMode(networkMode)
            let resolvedContainerServiceUser = try resolveContainerServiceUser(networkMode: resolvedNetworkMode)
            let resolvedRuntimeClasses = try runtimeClass.map {
                try parseRuntimeClass($0, networkMode: resolvedNetworkMode)
            }

            let options = MacOSKubeadmJoinOptions(
                apiServer: apiServer,
                nodeName: nodeName,
                token: token,
                discoveryTokenCACertHashes: discoveryTokenCACertHash,
                sandboxImage: sandboxImage,
                runtimeClasses: resolvedRuntimeClasses,
                networkMode: resolvedNetworkMode,
                containerServiceUserID: resolvedContainerServiceUser,
                installRoot: installRoot,
                startServices: !skipStart,
                dryRun: dryRun,
                debug: debug
            )

            let log = MacOSKubeadmLog(debugEnabled: debug)
            let runner = MacOSKubeadmJoinRunner()
            try runner.run(options: options, log: log)
        }

        private func parseAPIServerEndpoint(_ value: String) throws -> URL {
            let candidate = value.contains("://") ? value : "https://\(value)"
            guard let url = URL(string: candidate),
                let scheme = url.scheme?.lowercased(),
                ["https", "http"].contains(scheme),
                url.host != nil
            else {
                throw ValidationError("api-server-endpoint must be a valid host:port or URL")
            }
            return url
        }

        private func parseNetworkMode(_ value: String) throws -> MacOSKubeadmNetworkMode {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let mode = MacOSKubeadmNetworkMode(rawValue: normalized) else {
                let allowed = MacOSKubeadmNetworkMode.allCases.map(\.rawValue).joined(separator: ", ")
                throw ValidationError("--network-mode must be one of: \(allowed)")
            }
            return mode
        }

        private func parseRuntimeClass(
            _ value: String,
            networkMode: MacOSKubeadmNetworkMode
        ) throws -> MacOSKubeadmRuntimeClassProfile {
            let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ValidationError("--runtime-class must use name=sandbox-image")
            }
            let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let image = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw ValidationError("--runtime-class name is required")
            }
            guard !image.isEmpty else {
                throw ValidationError("--runtime-class sandbox image is required")
            }
            return MacOSKubeadmRuntimeClassProfile(
                name: name,
                sandboxImage: image,
                networkMode: networkMode
            )
        }

        private func resolveContainerServiceUser(networkMode: MacOSKubeadmNetworkMode) throws -> Int {
            if let containerServiceUser {
                guard containerServiceUser >= 0 else {
                    throw ValidationError("--container-service-user must be a non-negative uid")
                }
                return containerServiceUser
            }
            guard networkMode == .compat else {
                return 0
            }
            guard let sudoUID = ProcessInfo.processInfo.environment["SUDO_UID"],
                let uid = Int(sudoUID),
                uid > 0
            else {
                return 0
            }
            return uid
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset",
            abstract: "Stop Kubernetes node services and remove generated node configuration."
        )

        @Option(help: "Alternate filesystem root for tests and image assembly. Real resets only support '/'.")
        var installRoot: String = "/"

        @Flag(help: "Also remove kubelet, CRI/CNI state, and node logs.")
        var purgeState: Bool = false

        @Flag(help: "Required for a real reset. Not required with --dry-run.")
        var force: Bool = false

        @Flag(help: "Remove no files and stop no services; print the planned actions.")
        var dryRun: Bool = false

        @Flag(help: "Enable debug logs, including command output and planned actions.")
        var debug: Bool = false

        func run() throws {
            let options = MacOSKubeadmResetOptions(
                installRoot: installRoot,
                purgeState: purgeState,
                force: force,
                dryRun: dryRun,
                debug: debug
            )

            let log = MacOSKubeadmLog(debugEnabled: debug)
            let runner = MacOSKubeadmResetRunner()
            try runner.run(options: options, log: log)
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Check macOS Kubernetes node files, socket, and launchd services."
        )

        @Option(help: "Alternate filesystem root for tests and image assembly. Launchd checks are skipped outside '/'.")
        var installRoot: String = "/"

        @Flag(help: "Enable debug logs, including launchctl errors.")
        var debug: Bool = false

        func run() throws {
            let options = MacOSKubeadmStatusOptions(
                installRoot: installRoot,
                debug: debug
            )

            let log = MacOSKubeadmLog(debugEnabled: debug)
            let runner = MacOSKubeadmStatusRunner()
            try runner.run(options: options, log: log)
        }
    }
}
