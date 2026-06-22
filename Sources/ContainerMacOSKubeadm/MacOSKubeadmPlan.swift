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

public struct MacOSKubeadmPlan: Sendable, Equatable {
    public var steps: [MacOSKubeadmStep]

    public init(steps: [MacOSKubeadmStep]) {
        self.steps = steps
    }
}

public struct MacOSKubeadmStep: Sendable, Equatable {
    public var message: String
    public var action: MacOSKubeadmAction

    public init(message: String, action: MacOSKubeadmAction) {
        self.message = message
        self.action = action
    }
}

public enum MacOSKubeadmAction: Sendable, Equatable {
    case createDirectory(path: String, mode: Int)
    case copyFile(source: String, destination: String, mode: Int, sensitive: Bool)
    case writeFile(path: String, contents: String, mode: Int, sensitive: Bool)
    case removePath(path: String, recursive: Bool, bestEffort: Bool, sensitive: Bool)
    case runCommand(arguments: [String], bestEffort: Bool)
    case waitForPath(path: String, timeoutSeconds: Int)

    public var safeDescription: String {
        switch self {
        case .createDirectory(let path, let mode):
            return "mkdir -p \(path) mode \(String(mode, radix: 8))"
        case .copyFile(let source, let destination, let mode, let sensitive):
            return sensitive
                ? "copy sensitive file to \(destination) mode \(String(mode, radix: 8))"
                : "copy \(source) to \(destination) mode \(String(mode, radix: 8))"
        case .writeFile(let path, _, let mode, let sensitive):
            return sensitive
                ? "write sensitive file \(path) mode \(String(mode, radix: 8))"
                : "write file \(path) mode \(String(mode, radix: 8))"
        case .removePath(let path, let recursive, let bestEffort, let sensitive):
            var description = sensitive ? "remove sensitive path \(path)" : "remove \(path)"
            if recursive {
                description += " recursively"
            }
            if bestEffort {
                description += " (best effort)"
            }
            return description
        case .runCommand(let arguments, let bestEffort):
            let command = Self.shellEscaped(arguments)
            return bestEffort ? "\(command) (best effort)" : command
        case .waitForPath(let path, let timeoutSeconds):
            return "wait up to \(timeoutSeconds)s for \(path)"
        }
    }

    private static func shellEscaped(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\""))) == nil {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

public enum MacOSKubeadmPlanner {
    public static func joinPlan(options: MacOSKubeadmJoinOptions) throws -> MacOSKubeadmPlan {
        try validate(options)

        let caPath = "/etc/kubernetes/pki/ca.crt"
        var directories = [
            "/etc/kubernetes",
            "/etc/kubernetes/manifests",
            "/etc/kubernetes/pki",
            "/Library/LaunchDaemons",
            "/usr/local/share/container-macos-node/manifests",
            "/var/lib/kubelet",
            "/var/lib/container/cri-shim-macos",
            "/var/log/pods",
            "/var/log/containers",
        ]
        if options.networkMode.usesPodNetworking {
            directories.append(contentsOf: [
                "/etc/cni/net.d",
                "/opt/cni/bin",
                "/var/lib/container/cni/macvmnet",
            ])
        }

        var steps: [MacOSKubeadmStep] = directories.map { path in
            MacOSKubeadmStep(
                message: "ensure directory \(path)",
                action: .createDirectory(path: options.rooted(path), mode: 0o755)
            )
        }
        if options.containerServiceUserID != 0 {
            steps.append(contentsOf: kubeletPodsAccessSteps(options: options))
        }

        steps.append(
            MacOSKubeadmStep(
                message: "write Kubernetes CA certificate",
                action: .writeFile(
                    path: options.rooted(caPath),
                    contents: options.certificateAuthorityPEM ?? "",
                    mode: 0o644,
                    sensitive: false
                )
            )
        )

        steps.append(contentsOf: [
            MacOSKubeadmStep(
                message: "write bootstrap kubelet kubeconfig",
                action: .writeFile(
                    path: options.rooted("/etc/kubernetes/bootstrap-kubelet.kubeconfig"),
                    contents: MacOSKubeadmRenderer.kubeconfig(
                        clusterName: options.clusterName,
                        contextName: "bootstrap",
                        userName: "kubelet-bootstrap",
                        server: options.apiServer,
                        certificateAuthorityPath: caPath,
                        token: options.token
                    ),
                    mode: 0o600,
                    sensitive: true
                )
            ),
            MacOSKubeadmStep(
                message: "write kubelet configuration",
                action: .writeFile(
                    path: options.rooted("/etc/kubernetes/kubelet-config.yaml"),
                    contents: MacOSKubeadmRenderer.kubeletConfiguration(
                        clusterDNS: options.clusterDNS,
                        clusterDomain: options.clusterDomain
                    ),
                    mode: 0o644,
                    sensitive: false
                )
            ),
            MacOSKubeadmStep(
                message: "write CRI shim configuration",
                action: .writeFile(
                    path: options.rooted("/etc/kubernetes/container-cri-shim-macos-config.json"),
                    contents: MacOSKubeadmRenderer.criShimConfiguration(
                        sandboxImage: options.sandboxImage,
                        networkMode: options.networkMode,
                        runtimeClasses: options.runtimeClasses
                    ),
                    mode: 0o644,
                    sensitive: false
                )
            ),
        ])

        if options.networkMode.usesPodNetworking {
            steps.append(contentsOf: [
                MacOSKubeadmStep(
                    message: "write kube-proxy kubeconfig",
                    action: .writeFile(
                        path: options.rooted("/etc/kubernetes/kube-proxy.kubeconfig"),
                        contents: MacOSKubeadmRenderer.kubeconfig(
                            clusterName: options.clusterName,
                            contextName: "kube-proxy",
                            userName: "kube-proxy",
                            server: options.apiServer,
                            certificateAuthorityPath: caPath,
                            token: options.kubeProxyToken ?? ""
                        ),
                        mode: 0o600,
                        sensitive: true
                    )
                ),
                MacOSKubeadmStep(
                    message: "write CNI configuration",
                    action: .writeFile(
                        path: options.rooted("/etc/cni/net.d/10-macvmnet.conflist"),
                        contents: MacOSKubeadmRenderer.cniConfiguration(),
                        mode: 0o644,
                        sensitive: false
                    )
                ),
                MacOSKubeadmStep(
                    message: "write kube-proxy configuration",
                    action: .writeFile(
                        path: options.rooted("/etc/kubernetes/kube-proxy.conf"),
                        contents: MacOSKubeadmRenderer.kubeProxyConfiguration(nodeName: options.nodeName),
                        mode: 0o644,
                        sensitive: false
                    )
                ),
                MacOSKubeadmStep(
                    message: "write kube-proxy launchd plist",
                    action: .writeFile(
                        path: options.rooted("/Library/LaunchDaemons/com.apple.container.kube-proxy-macos.plist"),
                        contents: MacOSKubeadmRenderer.kubeProxyPlist(),
                        mode: 0o644,
                        sensitive: false
                    )
                ),
            ])
        }

        steps.append(
            contentsOf: options.effectiveRuntimeClasses.map { profile in
                MacOSKubeadmStep(
                    message: "write RuntimeClass manifest \(profile.name)",
                    action: .writeFile(
                        path: options.rooted("/usr/local/share/container-macos-node/manifests/\(profile.manifestFileName)"),
                        contents: MacOSKubeadmRenderer.runtimeClassManifest(profile: profile),
                        mode: 0o644,
                        sensitive: false
                    )
                )
            })
        steps.append(contentsOf: [
            MacOSKubeadmStep(
                message: "write CRI shim launchd plist",
                action: .writeFile(
                    path: options.rooted("/Library/LaunchDaemons/com.apple.container.cri-shim-macos.plist"),
                    contents: MacOSKubeadmRenderer.criShimPlist(
                        containerServiceUserID: options.containerServiceUserID
                    ),
                    mode: 0o644,
                    sensitive: false
                )
            ),
            MacOSKubeadmStep(
                message: "write kubelet launchd plist",
                action: .writeFile(
                    path: options.rooted("/Library/LaunchDaemons/com.apple.container.kubelet.plist"),
                    contents: MacOSKubeadmRenderer.kubeletPlist(
                        nodeName: options.nodeName,
                        sandboxImage: options.sandboxImage,
                        networkMode: options.networkMode
                    ),
                    mode: 0o644,
                    sensitive: false
                )
            ),
        ])

        if options.startServices {
            steps.append(
                contentsOf: serviceStartSteps(
                    networkMode: options.networkMode,
                    containerServiceUserID: options.containerServiceUserID
                ))
        }

        return MacOSKubeadmPlan(steps: steps)
    }

    public static func resetPlan(options: MacOSKubeadmResetOptions) throws -> MacOSKubeadmPlan {
        try validate(options)

        var steps = [
            MacOSKubeadmStep(
                message: "stop kubelet launchd job if present",
                action: .runCommand(arguments: ["/bin/launchctl", "bootout", "system/com.apple.container.kubelet"], bestEffort: true)
            ),
            MacOSKubeadmStep(
                message: "stop kube-proxy launchd job if present",
                action: .runCommand(arguments: ["/bin/launchctl", "bootout", "system/com.apple.container.kube-proxy-macos"], bestEffort: true)
            ),
            MacOSKubeadmStep(
                message: "stop CRI shim launchd job if present",
                action: .runCommand(arguments: ["/bin/launchctl", "bootout", "system/com.apple.container.cri-shim-macos"], bestEffort: true)
            ),
            MacOSKubeadmStep(
                message: "flush kube-proxy PF anchor if present",
                action: .runCommand(arguments: ["/sbin/pfctl", "-a", "com.apple.container.kube-proxy", "-F", "all"], bestEffort: true)
            ),
        ]

        let generatedPaths: [(path: String, recursive: Bool, sensitive: Bool)] = [
            ("/Library/LaunchDaemons/com.apple.container.kubelet.plist", false, false),
            ("/Library/LaunchDaemons/com.apple.container.kube-proxy-macos.plist", false, false),
            ("/Library/LaunchDaemons/com.apple.container.cri-shim-macos.plist", false, false),
            ("/etc/kubernetes/bootstrap-kubelet.kubeconfig", false, true),
            ("/etc/kubernetes/kubelet.kubeconfig", false, true),
            ("/etc/kubernetes/kube-proxy.kubeconfig", false, true),
            ("/etc/kubernetes/kubelet-config.yaml", false, false),
            ("/etc/kubernetes/container-cri-shim-macos-config.json", false, false),
            ("/etc/kubernetes/kube-proxy.conf", false, false),
            ("/etc/kubernetes/pki/ca.crt", false, false),
            ("/etc/cni/net.d/10-macvmnet.conflist", false, false),
            ("/usr/local/share/container-macos-node/manifests/runtimeclass-macos.yaml", false, false),
            ("/usr/local/share/container-macos-node/manifests/runtimeclass-macos-compat.yaml", false, false),
        ]

        for entry in generatedPaths {
            steps.append(
                MacOSKubeadmStep(
                    message: "remove \(entry.path)",
                    action: .removePath(
                        path: options.rooted(entry.path),
                        recursive: entry.recursive,
                        bestEffort: true,
                        sensitive: entry.sensitive
                    )
                )
            )
        }

        if options.purgeState {
            let statePaths = [
                "/var/lib/kubelet",
                "/var/lib/container/cri-shim-macos",
                "/var/lib/container/cni/macvmnet",
                "/var/log/pods",
                "/var/log/containers",
                "/var/log/kubelet.log",
                "/var/log/container-cri-shim-macos.log",
                "/var/log/container-kube-proxy-macos.log",
            ]
            for path in statePaths {
                steps.append(
                    MacOSKubeadmStep(
                        message: "purge \(path)",
                        action: .removePath(
                            path: options.rooted(path),
                            recursive: true,
                            bestEffort: true,
                            sensitive: false
                        )
                    )
                )
            }
        }

        return MacOSKubeadmPlan(steps: steps)
    }

    private static func validate(_ options: MacOSKubeadmJoinOptions) throws {
        guard ["https", "http"].contains(options.apiServer.scheme?.lowercased() ?? "") else {
            throw MacOSKubeadmError.invalidInput("--apiserver must use http or https")
        }
        guard options.nodeName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw MacOSKubeadmError.invalidInput("--node-name may only contain letters, numbers, '.', '_', and '-'")
        }
        guard !options.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacOSKubeadmError.invalidInput("--token is required")
        }
        guard !options.discoveryTokenCACertHashes.isEmpty else {
            throw MacOSKubeadmError.invalidInput("--discovery-token-ca-cert-hash is required")
        }
        guard !(options.certificateAuthorityPEM ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacOSKubeadmError.invalidInput("discovered Kubernetes CA certificate is required")
        }
        guard !options.networkMode.usesPodNetworking || !(options.kubeProxyToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacOSKubeadmError.invalidInput("discovered kube-proxy token is required")
        }
        guard options.containerServiceUserID >= 0 else {
            throw MacOSKubeadmError.invalidInput("--container-service-user must be a non-negative uid")
        }
        guard !options.clusterDNS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacOSKubeadmError.invalidInput("--cluster-dns is required")
        }
        guard options.installRoot.hasPrefix("/") else {
            throw MacOSKubeadmError.invalidInput("--install-root must be an absolute path")
        }
        if options.startServices && !options.rootPrefix.isEmpty && !options.dryRun {
            throw MacOSKubeadmError.invalidInput("--install-root cannot be combined with service start; pass --skip-start")
        }
        let runtimeClassNames = options.effectiveRuntimeClasses.map(\.name)
        if Set(runtimeClassNames).count != runtimeClassNames.count {
            throw MacOSKubeadmError.invalidInput("--runtime-class names must be unique")
        }
        let runtimeHandlers = options.effectiveRuntimeClasses.map(\.handler)
        if Set(runtimeHandlers).count != runtimeHandlers.count {
            throw MacOSKubeadmError.invalidInput("--runtime-class handlers must be unique")
        }
        for profile in options.effectiveRuntimeClasses {
            try validateRuntimeClassProfile(profile)
        }
    }

    private static func validateRuntimeClassProfile(_ profile: MacOSKubeadmRuntimeClassProfile) throws {
        let dnsLabelPattern = #"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"#
        guard profile.name.range(of: dnsLabelPattern, options: .regularExpression) != nil else {
            throw MacOSKubeadmError.invalidInput("--runtime-class name must be a DNS label")
        }
        guard profile.handler.range(of: dnsLabelPattern, options: .regularExpression) != nil else {
            throw MacOSKubeadmError.invalidInput("--runtime-class handler must be a DNS label")
        }
        guard !profile.sandboxImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacOSKubeadmError.invalidInput("--runtime-class sandbox image is required")
        }
    }

    private static func validate(_ options: MacOSKubeadmResetOptions) throws {
        guard options.installRoot.hasPrefix("/") else {
            throw MacOSKubeadmError.invalidInput("--install-root must be an absolute path")
        }
        if !options.dryRun && !options.force {
            throw MacOSKubeadmError.invalidInput("reset requires --force unless --dry-run is set")
        }
        if !options.rootPrefix.isEmpty && !options.dryRun {
            throw MacOSKubeadmError.invalidInput("--install-root cannot be used for a real reset; pass --dry-run")
        }
    }

    private static func serviceStartSteps(
        networkMode: MacOSKubeadmNetworkMode,
        containerServiceUserID: Int
    ) -> [MacOSKubeadmStep] {
        var steps = [
            MacOSKubeadmStep(
                message: "stop container core services if present",
                action: .runCommand(
                    arguments: containerSystemCommand(userID: containerServiceUserID, subcommand: "stop"),
                    bestEffort: true
                )
            ),
            MacOSKubeadmStep(
                message: "start container core services",
                action: .runCommand(
                    arguments: containerSystemCommand(userID: containerServiceUserID, subcommand: "start"),
                    bestEffort: false
                )
            ),
            MacOSKubeadmStep(
                message: "stop previous CRI shim launchd job if present",
                action: .runCommand(arguments: ["/bin/launchctl", "bootout", "system/com.apple.container.cri-shim-macos"], bestEffort: true)
            ),
            MacOSKubeadmStep(
                message: "start CRI shim launchd job",
                action: .runCommand(
                    arguments: [
                        "/bin/launchctl",
                        "bootstrap",
                        "system",
                        "/Library/LaunchDaemons/com.apple.container.cri-shim-macos.plist",
                    ],
                    bestEffort: false
                )
            ),
            MacOSKubeadmStep(
                message: "enable CRI shim launchd job",
                action: .runCommand(arguments: ["/bin/launchctl", "enable", "system/com.apple.container.cri-shim-macos"], bestEffort: false)
            ),
            MacOSKubeadmStep(
                message: "kickstart CRI shim launchd job",
                action: .runCommand(arguments: ["/bin/launchctl", "kickstart", "-k", "system/com.apple.container.cri-shim-macos"], bestEffort: false)
            ),
            MacOSKubeadmStep(
                message: "wait for CRI socket",
                action: .waitForPath(path: "/var/run/container-cri-macos.sock", timeoutSeconds: 30)
            ),
        ]
        if networkMode.usesPodNetworking {
            steps.append(contentsOf: [
                MacOSKubeadmStep(
                    message: "stop previous kube-proxy launchd job if present",
                    action: .runCommand(arguments: ["/bin/launchctl", "bootout", "system/com.apple.container.kube-proxy-macos"], bestEffort: true)
                ),
                MacOSKubeadmStep(
                    message: "start kube-proxy launchd job",
                    action: .runCommand(
                        arguments: [
                            "/bin/launchctl",
                            "bootstrap",
                            "system",
                            "/Library/LaunchDaemons/com.apple.container.kube-proxy-macos.plist",
                        ],
                        bestEffort: false
                    )
                ),
                MacOSKubeadmStep(
                    message: "enable kube-proxy launchd job",
                    action: .runCommand(arguments: ["/bin/launchctl", "enable", "system/com.apple.container.kube-proxy-macos"], bestEffort: false)
                ),
                MacOSKubeadmStep(
                    message: "kickstart kube-proxy launchd job",
                    action: .runCommand(arguments: ["/bin/launchctl", "kickstart", "-k", "system/com.apple.container.kube-proxy-macos"], bestEffort: false)
                ),
            ])
        }
        steps.append(contentsOf: [
            MacOSKubeadmStep(
                message: "stop previous kubelet launchd job if present",
                action: .runCommand(arguments: ["/bin/launchctl", "bootout", "system/com.apple.container.kubelet"], bestEffort: true)
            ),
            MacOSKubeadmStep(
                message: "start kubelet launchd job",
                action: .runCommand(
                    arguments: [
                        "/bin/launchctl",
                        "bootstrap",
                        "system",
                        "/Library/LaunchDaemons/com.apple.container.kubelet.plist",
                    ],
                    bestEffort: false
                )
            ),
            MacOSKubeadmStep(
                message: "enable kubelet launchd job",
                action: .runCommand(arguments: ["/bin/launchctl", "enable", "system/com.apple.container.kubelet"], bestEffort: false)
            ),
            MacOSKubeadmStep(
                message: "kickstart kubelet launchd job",
                action: .runCommand(arguments: ["/bin/launchctl", "kickstart", "-k", "system/com.apple.container.kubelet"], bestEffort: false)
            ),
        ])
        return steps
    }

    private static func kubeletPodsAccessSteps(options: MacOSKubeadmJoinOptions) -> [MacOSKubeadmStep] {
        let podsPath = options.rooted("/var/lib/kubelet/pods")
        let script = """
            set -eu
            user=$(/usr/bin/id -nu "$1")
            path=$2
            acl="$user allow read,readattr,readextattr,readsecurity,list,search,file_inherit,directory_inherit"
            /bin/mkdir -p "$path"
            /usr/bin/find "$path" -type d -exec /bin/chmod -a "$acl" {} + 2>/dev/null || true
            /usr/bin/find "$path" -type d -exec /bin/chmod +a "$acl" {} +
            """
        return [
            MacOSKubeadmStep(
                message: "ensure directory /var/lib/kubelet/pods",
                action: .createDirectory(path: podsPath, mode: 0o750)
            ),
            MacOSKubeadmStep(
                message: "grant container service user access to kubelet pod directories",
                action: .runCommand(
                    arguments: [
                        "/bin/sh",
                        "-c",
                        script,
                        "container-macos-kubeadm-acl",
                        "\(options.containerServiceUserID)",
                        podsPath,
                    ],
                    bestEffort: false
                )
            ),
        ]
    }

    private static func containerSystemCommand(userID: Int, subcommand: String) -> [String] {
        if userID == 0 {
            return ["/bin/launchctl", "asuser", "0", "/usr/local/bin/container", "system", subcommand]
        }
        return ["/usr/bin/sudo", "-u", "#\(userID)", "/usr/local/bin/container", "system", subcommand]
    }
}
