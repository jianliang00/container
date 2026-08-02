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
                    && contents.contains(#""runtimeStatePath": "/var/lib/container/cri-shim-macos/pod-network.json""#)
                    && contents.contains(#""readyStatePath": "/var/lib/container/flannel-vxlan/ready.json""#)
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.kubelet.plist"
                    && contents.contains("<string>macos-ci-1</string>")
                    && contents.contains("<string>localhost/macos-sandbox:test</string>")
                    && contents.contains("<string>/etc/kubernetes/kubelet.conf</string>")
                    && contents.contains(
                        "<string>kubernetes.io/os=darwin,node.kubernetes.io/macos=true,node.kubernetes.io/macos-network=full</string>"
                    )
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
                    && contents.contains("localStorageCapacityIsolation: true")
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
                    && contents.contains(#""name": "kubernetes-pod""#)
                    && contents.contains(#""network": "kubernetes-pod""#)
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/container-cri-shim-macos-config.json"
                    && contents.contains(#""network": "kubernetes-pod""#)
                    && !contents.contains(#""networkMTU""#)
                    && contents.contains(#""runtimeStatePath": "/var/lib/container/cri-shim-macos/pod-network.json""#)
                    && contents.contains(#""readyStatePath": "/var/lib/container/flannel-vxlan/ready.json""#)
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf"
                    && contents.contains(#""nodeKubeconfig": "/etc/kubernetes/kubelet.conf""#)
                    && contents.contains(#""nodeName": "macos-ci-1""#)
                    && contents.contains(#""networkName": "kubernetes-pod""#)
                    && contents.contains(#""networkVariant": "reserved""#)
                    && !contents.contains("underlayInterface")
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
        options.flannelToken = nil

        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let descriptions = plan.steps.map(\.message)
        let writePaths = plan.steps.compactMap { step -> String? in
            guard case .writeFile(let path, _, _, _) = step.action else {
                return nil
            }
            return path
        }

        #expect(!writePaths.contains("/tmp/macos-node/etc/kubernetes/kube-proxy.kubeconfig"))
        #expect(!writePaths.contains("/tmp/macos-node/etc/kubernetes/flannel-macos.kubeconfig"))
        #expect(!writePaths.contains("/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf"))
        #expect(!writePaths.contains("/tmp/macos-node/etc/kubernetes/kube-proxy.conf"))
        #expect(!writePaths.contains("/tmp/macos-node/etc/cni/net.d/10-macvmnet.conflist"))
        #expect(!writePaths.contains("/tmp/macos-node/Library/LaunchDaemons/com.apple.container.kube-proxy-macos.plist"))
        #expect(!writePaths.contains("/tmp/macos-node/Library/LaunchDaemons/com.apple.container.flannel-vxlan-macos.plist"))
        #expect(!descriptions.contains("start flannel VXLAN launchd job"))
        #expect(!descriptions.contains("start kube-proxy launchd job"))
        #expect(!descriptions.contains("kickstart kube-proxy launchd job"))
        #expect(descriptions.contains("stop previous flannel VXLAN launchd job if present"))
        #expect(descriptions.contains("withdraw previous flannel VXLAN data plane"))
        #expect(descriptions.contains("disable previous flannel VXLAN launchd job"))
        #expect(descriptions.contains("stop previous kube-proxy launchd job if present"))
        #expect(descriptions.contains("disable previous kube-proxy launchd job"))
        #expect(descriptions.contains("flush previous kube-proxy PF anchor"))
        #expect(descriptions.contains("purge owned pod network"))

        for path in [
            "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.flannel-vxlan-macos.plist",
            "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.kube-proxy-macos.plist",
            "/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf",
            "/tmp/macos-node/etc/kubernetes/kube-proxy.conf",
            "/tmp/macos-node/etc/cni/net.d/10-macvmnet.conflist",
        ] {
            #expect(
                plan.steps.contains { step in
                    guard case .removePath(let removedPath, false, true, _) = step.action else {
                        return false
                    }
                    return removedPath == path
                })
        }

        #expect(
            plan.steps.contains { step in
                guard case .removePath(let path, true, true, true) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/container/kubernetes-credentials"
            })

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
                    && !contents.contains(#""networkMTU""#)
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

    @Test func compatJoinPlanDoesNotMutateServicesWhenServicesAreNotStarted() throws {
        var options = try makeOptions(startServices: false)
        options.networkMode = .compat
        options.kubeProxyToken = nil
        options.flannelToken = nil

        let descriptions = try MacOSKubeadmPlanner.joinPlan(options: options).steps.map(\.message)

        #expect(!descriptions.contains("stop previous flannel VXLAN launchd job if present"))
        #expect(!descriptions.contains("withdraw previous flannel VXLAN data plane"))
        #expect(!descriptions.contains("disable previous flannel VXLAN launchd job"))
        #expect(!descriptions.contains("stop previous kube-proxy launchd job if present"))
        #expect(!descriptions.contains("disable previous kube-proxy launchd job"))
        #expect(!descriptions.contains("flush previous kube-proxy PF anchor"))
        #expect(!descriptions.contains("purge owned pod network"))
        #expect(!descriptions.contains("start container core services"))
        #expect(!descriptions.contains("start CRI shim launchd job"))
    }

    @Test func compatJoinWithdrawsAndPurgesFlannelBeforeRemovingCredentialsAndConfiguration() throws {
        var options = try makeOptions(startServices: true)
        options.networkMode = .compat
        options.kubeProxyToken = nil
        options.flannelToken = nil

        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let descriptions = plan.steps.map(\.message)
        let preflightIndex = try #require(descriptions.firstIndex(of: "preflight owned pod network purge"))
        let stopKubeletIndex = try #require(descriptions.firstIndex(of: "stop previous kubelet launchd job if present"))
        let stopProxyIndex = try #require(descriptions.firstIndex(of: "stop previous kube-proxy launchd job if present"))
        let withdrawIndex = try #require(descriptions.firstIndex(of: "withdraw previous flannel VXLAN data plane"))
        let stopIndex = try #require(descriptions.firstIndex(of: "stop previous flannel VXLAN launchd job if present"))
        let stopCRIIndex = try #require(descriptions.firstIndex(of: "stop previous CRI shim launchd job if present"))
        let purgeIndex = try #require(descriptions.firstIndex(of: "purge owned pod network"))
        let configRemovalIndex = try #require(
            descriptions.firstIndex(of: "remove full-mode artifact /etc/kubernetes/flannel-vxlan-macos.conf")
        )
        let credentialRemovalIndex = try #require(descriptions.firstIndex(of: "remove full-mode Kubernetes credentials"))

        #expect(preflightIndex < stopKubeletIndex)
        #expect(stopKubeletIndex < stopProxyIndex)
        #expect(stopProxyIndex < withdrawIndex)
        #expect(withdrawIndex < stopIndex)
        #expect(stopIndex < stopCRIIndex)
        #expect(stopCRIIndex < purgeIndex)
        #expect(purgeIndex < configRemovalIndex)
        #expect(purgeIndex < credentialRemovalIndex)
        #expect(
            plan.steps.contains { step in
                guard step.message == "preflight owned pod network purge",
                    case .runCommand(let arguments, let bestEffort) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-flannel-vxlan-macos",
                    "--config",
                    "/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf",
                    "--check-purge",
                ] && !bestEffort
            }
        )
        #expect(
            plan.steps.contains { step in
                guard step.message == "withdraw previous flannel VXLAN data plane",
                    case .runCommand(let arguments, let bestEffort) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-flannel-vxlan-macos",
                    "--config",
                    "/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf",
                    "--withdraw",
                ] && !bestEffort
            }
        )
        #expect(
            plan.steps.contains { step in
                guard step.message == "purge owned pod network",
                    case .runCommand(let arguments, let bestEffort) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-flannel-vxlan-macos",
                    "--config",
                    "/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf",
                    "--purge-network",
                ] && !bestEffort
            }
        )
    }

    @Test func joinPlanRendersAdditionalRuntimeClasses() throws {
        var options = try makeOptions(startServices: false)
        options.networkMode = .compat
        options.kubeProxyToken = nil
        options.flannelToken = nil
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
        let configObject = try #require(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let runtimeHandlers = try #require(configObject["runtimeHandlers"] as? [String: Any])
        let macosCompat = try #require(runtimeHandlers["macos-compat"] as? [String: Any])
        let macos15_2 = try #require(runtimeHandlers["macos-15-2"] as? [String: Any])
        let macos15_4 = try #require(runtimeHandlers["macos-15-4"] as? [String: Any])
        #expect(macosCompat["networkBackend"] as? String == "virtualizationNAT")
        #expect(macos15_2["sandboxImage"] as? String == "ghcr.io/jianliang00/macos-base:15.2")
        #expect(macos15_2["networkBackend"] as? String == "virtualizationNAT")
        #expect(macos15_4["sandboxImage"] as? String == "ghcr.io/jianliang00/macos-base:15.4")
        #expect(macos15_4["networkBackend"] as? String == "virtualizationNAT")

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

        #expect(kubeconfigSteps.count == 3)
        for step in kubeconfigSteps {
            guard case .writeFile(let path, let contents, 0o600, true) = step.action else {
                Issue.record("kubeconfig step should be mode 0600 and sensitive")
                continue
            }
            if path.hasSuffix("bootstrap-kubelet.kubeconfig") {
                #expect(contents.contains("token: abcdef.0123456789abcdef"))
            } else {
                #expect(contents.contains("tokenFile: /var/lib/container/kubernetes-credentials/"))
                #expect(!contents.contains("proxy-token"))
                #expect(!contents.contains("flannel-token"))
            }
            #expect(!step.action.safeDescription.contains("abcdef.0123456789abcdef"))
            #expect(!step.action.safeDescription.contains("proxy-token"))
            #expect(!step.action.safeDescription.contains("flannel-token"))
        }

        #expect(
            plan.steps.contains { step in
                guard case .createDirectory(let path, 0o700) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/container/kubernetes-credentials"
            })

        let tokenSteps = plan.steps.filter { step in
            guard case .writeFile(let path, _, _, _) = step.action else {
                return false
            }
            return path.hasSuffix(".token")
        }
        #expect(tokenSteps.count == 2)
        for step in tokenSteps {
            guard case .writeFile(let path, let contents, 0o600, true) = step.action else {
                Issue.record("ServiceAccount token should be mode 0600 and sensitive")
                continue
            }
            #expect(path.hasPrefix("/tmp/macos-node/var/lib/container/kubernetes-credentials/"))
            #expect(contents == "proxy-token" || contents == "flannel-token")
            #expect(!step.action.safeDescription.contains(contents))
        }
    }

    @Test func serviceStartPlanStartsCRIBeforeKubelet() throws {
        let options = try makeOptions(startServices: true)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let descriptions = plan.steps.map(\.message)

        let criIndex = try #require(descriptions.firstIndex(of: "start CRI shim launchd job"))
        let waitIndex = try #require(descriptions.firstIndex(of: "wait for CRI socket"))
        let flannelEnableIndex = try #require(descriptions.firstIndex(of: "enable flannel VXLAN launchd job"))
        let flannelIndex = try #require(descriptions.firstIndex(of: "start flannel VXLAN launchd job"))
        let kubeletIndex = try #require(descriptions.firstIndex(of: "start kubelet launchd job"))
        let kubeProxyEnableIndex = try #require(descriptions.firstIndex(of: "enable kube-proxy launchd job"))
        let kubeProxyIndex = try #require(descriptions.firstIndex(of: "start kube-proxy launchd job"))

        #expect(criIndex < waitIndex)
        #expect(waitIndex < flannelEnableIndex)
        #expect(flannelEnableIndex < flannelIndex)
        #expect(flannelIndex < kubeletIndex)
        #expect(kubeletIndex < kubeProxyEnableIndex)
        #expect(kubeProxyEnableIndex < kubeProxyIndex)
        #expect(kubeletIndex < kubeProxyIndex)
        #expect(!descriptions.contains("disable previous flannel VXLAN launchd job"))
        #expect(!descriptions.contains("disable previous kube-proxy launchd job"))
    }

    @Test func serviceRestartUsesStrictIdempotentLaunchdStops() throws {
        let options = try makeOptions(startServices: true)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let expectedStops = [
            ("stop previous kubelet launchd job if present", "system/com.apple.container.kubelet"),
            ("stop previous kube-proxy launchd job if present", "system/com.apple.container.kube-proxy-macos"),
            ("stop previous flannel VXLAN launchd job if present", "system/com.apple.container.flannel-vxlan-macos"),
            ("stop previous CRI shim launchd job if present", "system/com.apple.container.cri-shim-macos"),
        ]

        for (message, label) in expectedStops {
            let step = try #require(plan.steps.first { $0.message == message })
            guard case .runCommand(let arguments, let bestEffort) = step.action else {
                Issue.record("expected \(message) to run a command")
                continue
            }
            #expect(!bestEffort)
            #expect(arguments.first == "/bin/sh")
            #expect(arguments.dropFirst().first == "-c")
            #expect(arguments.count == 5)
            #expect(arguments[2].contains("/bin/launchctl print"))
            #expect(arguments[2].contains("/bin/launchctl bootout"))
            #expect(arguments[4] == label)
        }
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
                guard step.message == "write flannel VXLAN configuration",
                    case .writeFile(_, let contents, 0o644, false) = step.action,
                    let data = contents.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return false
                }
                return object["containerServiceUserID"] as? Int == 501
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "write flannel VXLAN launchd plist",
                    case .writeFile(_, let contents, 0o644, false) = step.action
                else {
                    return false
                }
                return contents.contains("<string>/bin/launchctl</string>")
                    && contents.contains("<string>asuser</string>")
                    && contents.contains("<string>501</string>")
                    && contents.contains("<string>/usr/local/bin/container-flannel-vxlan-macos</string>")
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "stop root container core services if present",
                    case .runCommand(let arguments, true) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/bin/launchctl",
                    "asuser",
                    "0",
                    "/usr/local/bin/container",
                    "system",
                    "stop",
                ]
            })

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

    @Test func joinPlanRejectsHTTPAPIServer() throws {
        var options = try makeOptions(startServices: false)
        options.apiServer = try #require(URL(string: "http://127.0.0.1:6443"))

        #expect(throws: MacOSKubeadmError.invalidInput("--apiserver must use HTTPS")) {
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

        let preflightIndex = try #require(descriptions.firstIndex(of: "preflight owned pod network purge"))
        let stopKubeletIndex = try #require(descriptions.firstIndex(of: "stop kubelet launchd job if present"))
        let stopProxyIndex = try #require(descriptions.firstIndex(of: "stop kube-proxy launchd job if present"))
        let withdrawFlannelIndex = try #require(descriptions.firstIndex(of: "withdraw flannel VXLAN data plane"))
        let stopFlannelIndex = try #require(descriptions.firstIndex(of: "stop flannel VXLAN launchd job if present"))
        let stopCRIIndex = try #require(descriptions.firstIndex(of: "stop CRI shim launchd job if present"))
        let purgeIndex = try #require(descriptions.firstIndex(of: "purge owned pod network"))
        let removeFlannelConfigIndex = try #require(descriptions.firstIndex(of: "remove /etc/kubernetes/flannel-vxlan-macos.conf"))
        let firstRemoveIndex = try #require(descriptions.firstIndex { $0.hasPrefix("remove ") })

        #expect(preflightIndex < stopKubeletIndex)
        #expect(stopKubeletIndex < firstRemoveIndex)
        #expect(stopKubeletIndex < stopProxyIndex)
        #expect(stopProxyIndex < withdrawFlannelIndex)
        #expect(withdrawFlannelIndex < stopFlannelIndex)
        #expect(stopFlannelIndex < stopCRIIndex)
        #expect(stopCRIIndex < purgeIndex)
        #expect(purgeIndex < removeFlannelConfigIndex)
        #expect(
            plan.steps.contains { step in
                guard step.message == "preflight owned pod network purge",
                    case .runCommand(let arguments, let bestEffort) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-flannel-vxlan-macos",
                    "--config",
                    "/etc/kubernetes/flannel-vxlan-macos.conf",
                    "--check-purge",
                ] && !bestEffort
            }
        )
        #expect(
            plan.steps.contains { step in
                guard step.message == "withdraw flannel VXLAN data plane",
                    case .runCommand(let arguments, let bestEffort) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-flannel-vxlan-macos",
                    "--config",
                    "/etc/kubernetes/flannel-vxlan-macos.conf",
                    "--withdraw",
                ] && !bestEffort
            }
        )
        #expect(
            plan.steps.contains { step in
                guard step.message == "purge owned pod network",
                    case .runCommand(let arguments, let bestEffort) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-flannel-vxlan-macos",
                    "--config",
                    "/etc/kubernetes/flannel-vxlan-macos.conf",
                    "--purge-network",
                ] && !bestEffort
            }
        )
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
            return path.hasSuffix(".kubeconfig") || path.hasSuffix("/kubelet.conf")
        }

        #expect(kubeconfigSteps.count == 5)
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

        #expect(
            plan.steps.contains { step in
                guard case .removePath(let path, true, true, true) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/container/kubernetes-credentials"
            })
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
            flannelToken: "flannel-token",
            clusterDNS: "10.96.0.53",
            sandboxImage: "localhost/macos-sandbox:test",
            installRoot: "/tmp/macos-node",
            startServices: startServices,
            dryRun: true
        )
    }
}
