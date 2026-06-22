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

import ContainerMacOSKubeadm
import Foundation
import Testing

struct MacOSKubeadmPlanTests {
    @Test func joinPlanRendersExpectedNodeConfiguration() throws {
        let options = try makeOptions(startServices: false)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/pki/ca.crt"
                    && contents.contains("BEGIN CERTIFICATE")
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/kube-proxy.conf"
                    && contents.contains(#""nodeName": "macos-ci-1""#)
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.kubelet.plist"
                    && contents.contains("<string>macos-ci-1</string>")
                    && contents.contains("<string>localhost/macos-sandbox:test</string>")
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/kubelet-config.yaml"
                    && contents.contains("clusterDNS:")
                    && contents.contains(#""10.96.0.53""#)
                    && contents.contains("enforceNodeAllocatable: []")
                    && contents.contains(#"memory.available: "0%""#)
                    && !contents.contains("podLogsDir:")
                    && !contents.contains("failCgroupV1:")
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/cni/net.d/10-macvmnet.conflist"
                    && contents.contains(#""name": "default""#)
                    && contents.contains(#""network": "default""#)
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/usr/local/share/container-macos-node/manifests/runtimeclass-macos.yaml"
                    && contents.contains("name: macos")
                    && contents.contains("node.kubernetes.io/macos-network: \"full\"")
            })
    }

    @Test func compatJoinPlanOmitsPodNetworkingArtifacts() throws {
        var options = try makeOptions(startServices: true)
        options.networkMode = .compat
        options.kubeProxyToken = nil

        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let descriptions = plan.steps.map(\.message)
        let writePaths = plan.steps.compactMap { step -> String? in
            guard case .writeFile(let path, _, _, _) = step.action else {
                return nil
            }
            return path
        }

        #expect(!writePaths.contains("/tmp/macos-node/etc/kubernetes/kube-proxy.kubeconfig"))
        #expect(!writePaths.contains("/tmp/macos-node/etc/kubernetes/kube-proxy.conf"))
        #expect(!writePaths.contains("/tmp/macos-node/etc/cni/net.d/10-macvmnet.conflist"))
        #expect(!writePaths.contains("/tmp/macos-node/Library/LaunchDaemons/com.apple.container.kube-proxy-macos.plist"))
        #expect(!descriptions.contains("start kube-proxy launchd job"))
        #expect(!descriptions.contains("kickstart kube-proxy launchd job"))

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/container-cri-shim-macos-config.json"
                    && contents.contains(#""networkBackend": "virtualizationNAT""#)
                    && contents.contains(#""macos-compat""#)
                    && contents.contains(#""kubeProxy": {"#)
                    && contents.contains(#""enabled": false"#)
                    && !contents.contains(#""cni":"#)
                    && !contents.contains(#""plugin": "macvmnet""#)
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/usr/local/share/container-macos-node/manifests/runtimeclass-macos-compat.yaml"
                    && contents.contains("name: macos-compat")
                    && contents.contains("handler: macos-compat")
                    && contents.contains("node.kubernetes.io/macos-network: \"compat\"")
                    && contents.contains("key: node.kubernetes.io/macos-network")
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.kubelet.plist"
                    && contents.contains("node.kubernetes.io/macos-network=compat")
                    && contents.contains("node.kubernetes.io/macos-network=compat:NoSchedule")
            })
    }

    @Test func joinPlanRendersAdditionalRuntimeClasses() throws {
        var options = try makeOptions(startServices: false)
        options.networkMode = .compat
        options.kubeProxyToken = nil
        options.runtimeClasses = [
            MacOSKubeadmRuntimeClassProfile(
                name: "macos-15-2",
                sandboxImage: "ghcr.io/jianliang00/macos-base:15.2",
                networkMode: .compat
            ),
            MacOSKubeadmRuntimeClassProfile(
                name: "macos-15-4",
                sandboxImage: "ghcr.io/jianliang00/macos-base:15.4",
                networkMode: .compat
            ),
        ]

        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let writes = plan.steps.compactMap { step -> (path: String, contents: String)? in
            guard case .writeFile(let path, let contents, _, _) = step.action else {
                return nil
            }
            return (path, contents)
        }

        let config = try #require(
            writes.first { $0.path == "/tmp/macos-node/etc/kubernetes/container-cri-shim-macos-config.json" }?.contents
        )
        #expect(config.contains(#""macos-compat": {"#))
        #expect(config.contains(#""macos-15-2": {"#))
        #expect(config.contains(#""sandboxImage": "ghcr.io/jianliang00/macos-base:15.2""#))
        #expect(config.contains(#""macos-15-4": {"#))
        #expect(config.contains(#""sandboxImage": "ghcr.io/jianliang00/macos-base:15.4""#))
        #expect(config.contains(#""networkBackend": "virtualizationNAT""#))

        let runtimeClass15_2 = try #require(
            writes.first {
                $0.path == "/tmp/macos-node/usr/local/share/container-macos-node/manifests/runtimeclass-macos-15-2.yaml"
            }?.contents
        )
        #expect(runtimeClass15_2.contains("name: macos-15-2"))
        #expect(runtimeClass15_2.contains("handler: macos-15-2"))
        #expect(runtimeClass15_2.contains("node.kubernetes.io/macos-network: \"compat\""))

        let runtimeClass15_4 = try #require(
            writes.first {
                $0.path == "/tmp/macos-node/usr/local/share/container-macos-node/manifests/runtimeclass-macos-15-4.yaml"
            }?.contents
        )
        #expect(runtimeClass15_4.contains("name: macos-15-4"))
        #expect(runtimeClass15_4.contains("handler: macos-15-4"))
        #expect(runtimeClass15_4.contains("node.kubernetes.io/macos-network: \"compat\""))
    }

    @Test func joinPlanRejectsDuplicateRuntimeClassNames() throws {
        var options = try makeOptions(startServices: false)
        options.runtimeClasses = [
            MacOSKubeadmRuntimeClassProfile(
                name: "macos",
                sandboxImage: "ghcr.io/jianliang00/macos-base:26.3",
                networkMode: .full
            )
        ]

        #expect(throws: MacOSKubeadmError.invalidInput("--runtime-class names must be unique")) {
            try MacOSKubeadmPlanner.joinPlan(options: options)
        }
    }

    @Test func kubeconfigsAreMarkedSensitive() throws {
        let options = try makeOptions(startServices: false)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let kubeconfigSteps = plan.steps.filter { step in
            guard case .writeFile(let path, _, _, _) = step.action else {
                return false
            }
            return path.hasSuffix(".kubeconfig")
        }

        #expect(kubeconfigSteps.count == 2)
        for step in kubeconfigSteps {
            guard case .writeFile(_, let contents, 0o600, true) = step.action else {
                Issue.record("kubeconfig step should be mode 0600 and sensitive")
                continue
            }
            #expect(contents.contains("token:"))
            #expect(!step.action.safeDescription.contains("abcdef.0123456789abcdef"))
            #expect(!step.action.safeDescription.contains("proxy-token"))
        }
    }

    @Test func serviceStartPlanStartsCRIBeforeKubelet() throws {
        let options = try makeOptions(startServices: true)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let descriptions = plan.steps.map(\.message)

        let criIndex = try #require(descriptions.firstIndex(of: "start CRI shim launchd job"))
        let waitIndex = try #require(descriptions.firstIndex(of: "wait for CRI socket"))
        let kubeletIndex = try #require(descriptions.firstIndex(of: "start kubelet launchd job"))

        #expect(criIndex < waitIndex)
        #expect(waitIndex < kubeletIndex)
    }

    @Test func serviceStartPlanUsesRootUserBootstrapForContainerRuntime() throws {
        let options = try makeOptions(startServices: true)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)

        #expect(
            plan.steps.contains { step in
                guard step.message == "start container core services",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/bin/launchctl",
                    "asuser",
                    "0",
                    "/usr/local/bin/container",
                    "system",
                    "start",
                ]
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "start CRI shim launchd job",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/bin/launchctl",
                    "bootstrap",
                    "system",
                    "/Library/LaunchDaemons/com.apple.container.cri-shim-macos.plist",
                ]
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "kickstart CRI shim launchd job",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/bin/launchctl",
                    "kickstart",
                    "-k",
                    "system/com.apple.container.cri-shim-macos",
                ]
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "write CRI shim launchd plist",
                    case .writeFile(_, let contents, 0o644, false) = step.action
                else {
                    return false
                }
                return contents.contains("<string>/bin/launchctl</string>")
                    && contents.contains("<string>asuser</string>")
                    && contents.contains("<string>0</string>")
                    && contents.contains("<string>/usr/local/bin/container-cri-shim-macos</string>")
            })
    }

    @Test func serviceStartPlanCanUseNonRootContainerServiceUser() throws {
        var options = try makeOptions(startServices: true)
        options.containerServiceUserID = 501

        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)

        #expect(
            plan.steps.contains { step in
                guard step.message == "start container core services",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/bin/sudo",
                    "-u",
                    "#501",
                    "/usr/local/bin/container",
                    "system",
                    "start",
                ]
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "write CRI shim launchd plist",
                    case .writeFile(_, let contents, 0o644, false) = step.action
                else {
                    return false
                }
                return contents.contains("<string>asuser</string>")
                    && contents.contains("<string>501</string>")
                    && contents.contains("<string>/usr/local/bin/container-cri-shim-macos</string>")
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "ensure directory /var/lib/kubelet/pods",
                    case .createDirectory(let path, 0o750) = step.action
                else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/kubelet/pods"
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "grant container service user access to kubelet pod directories",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments.count == 6
                    && arguments[0] == "/bin/sh"
                    && arguments[1] == "-c"
                    && arguments[2].contains("/usr/bin/id -nu")
                    && arguments[2].contains("/bin/chmod +a")
                    && arguments[3] == "container-macos-kubeadm-acl"
                    && arguments[4] == "501"
                    && arguments[5] == "/tmp/macos-node/var/lib/kubelet/pods"
            })
    }

    @Test func joinPlanRequiresDiscoveryHash() throws {
        var options = try makeOptions(startServices: false)
        options.discoveryTokenCACertHashes = []

        #expect(throws: MacOSKubeadmError.invalidInput("--discovery-token-ca-cert-hash is required")) {
            try MacOSKubeadmPlanner.joinPlan(options: options)
        }
    }

    @Test func resetRequiresForceUnlessDryRun() throws {
        #expect(throws: MacOSKubeadmError.invalidInput("reset requires --force unless --dry-run is set")) {
            try MacOSKubeadmPlanner.resetPlan(
                options: MacOSKubeadmResetOptions(
                    installRoot: "/",
                    dryRun: false
                )
            )
        }

        let dryRunPlan = try MacOSKubeadmPlanner.resetPlan(
            options: MacOSKubeadmResetOptions(
                installRoot: "/tmp/macos-node",
                dryRun: true
            )
        )
        #expect(!dryRunPlan.steps.isEmpty)
    }

    @Test func resetStopsServicesBeforeRemovingConfiguration() throws {
        let plan = try MacOSKubeadmPlanner.resetPlan(
            options: MacOSKubeadmResetOptions(
                installRoot: "/",
                force: true
            )
        )
        let descriptions = plan.steps.map(\.message)

        let stopKubeletIndex = try #require(descriptions.firstIndex(of: "stop kubelet launchd job if present"))
        let firstRemoveIndex = try #require(descriptions.firstIndex { $0.hasPrefix("remove ") })

        #expect(stopKubeletIndex < firstRemoveIndex)
    }

    @Test func resetPurgeStateRemovesRuntimeStateRecursively() throws {
        let plan = try MacOSKubeadmPlanner.resetPlan(
            options: MacOSKubeadmResetOptions(
                installRoot: "/tmp/macos-node",
                purgeState: true,
                dryRun: true
            )
        )

        #expect(
            plan.steps.contains { step in
                guard case .removePath(let path, let recursive, let bestEffort, let sensitive) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/kubelet"
                    && recursive
                    && bestEffort
                    && !sensitive
            })
    }

    @Test func resetKubeconfigRemovalIsMarkedSensitive() throws {
        let plan = try MacOSKubeadmPlanner.resetPlan(
            options: MacOSKubeadmResetOptions(
                installRoot: "/tmp/macos-node",
                dryRun: true
            )
        )
        let kubeconfigSteps = plan.steps.filter { step in
            guard case .removePath(let path, _, _, _) = step.action else {
                return false
            }
            return path.hasSuffix(".kubeconfig")
        }

        #expect(kubeconfigSteps.count == 3)
        for step in kubeconfigSteps {
            guard case .removePath(_, let recursive, let bestEffort, let sensitive) = step.action,
                !recursive && bestEffort && sensitive
            else {
                Issue.record("kubeconfig removal should be best-effort and sensitive")
                continue
            }
            #expect(step.action.safeDescription.contains("sensitive"))
            #expect(!step.action.safeDescription.contains("token:"))
        }
    }

    private func makeOptions(startServices: Bool) throws -> MacOSKubeadmJoinOptions {
        try MacOSKubeadmJoinOptions(
            apiServer: #require(URL(string: "https://127.0.0.1:6443")),
            nodeName: "macos-ci-1",
            token: "abcdef.0123456789abcdef",
            discoveryTokenCACertHashes: [String(repeating: "a", count: 64)],
            certificateAuthorityPEM: """
                -----BEGIN CERTIFICATE-----
                dGVzdC1jYQ==
                -----END CERTIFICATE-----

                """,
            kubeProxyToken: "proxy-token",
            clusterDNS: "10.96.0.53",
            sandboxImage: "localhost/macos-sandbox:test",
            installRoot: "/tmp/macos-node",
            startServices: startServices,
            dryRun: true
        )
    }
}
