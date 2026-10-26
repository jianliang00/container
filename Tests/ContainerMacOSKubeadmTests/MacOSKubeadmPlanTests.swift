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
import Testing

@testable import ContainerMacOSKubeadm

struct MacOSKubeadmPlanTests {
    @Test func joinPlanRendersExpectedNodeConfiguration() throws {
        let options = try makeOptions(startServices: false)
        #expect(!options.enableDualStack)
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
                    && contents.contains(#""dualStackEnabled": false"#)
                    && contents.contains(#""statusPath": "/var/lib/container/kube-proxy-macos/status.json""#)
                    && contents.contains(#""runtimeStatePath": "/var/lib/container/cri-shim-macos/pod-network.json""#)
                    && contents.contains(#""readyStatePath": "/var/lib/container/flannel-vxlan/ready.json""#)
            })

        #expect(
            plan.steps.contains { step in
                guard case .createDirectory(let path, 0o755) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/container/kube-proxy-macos"
            })

        for path in [
            "/tmp/macos-node/var/lib/container/cri-shim-macos/machine-state/v1",
            "/tmp/macos-node/var/run/container/machine-state/v1",
            "/tmp/macos-node/var/run/container/nbd",
            "/tmp/macos-node/var/lib/container/cri-shim-macos/machine-state-leases/v1",
        ] {
            #expect(
                plan.steps.contains { step in
                    guard case .createDirectory(let createdPath, 0o700) = step.action else {
                        return false
                    }
                    return createdPath == path
                }
            )
        }

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o600, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/container-macos-node-status.json"
                    && contents.contains(#""nodeName": "macos-ci-1""#)
                    && contents.contains(#""networkName": "kubernetes-pod""#)
                    && contents.contains(#""vmnetRecovery": false"#)
            })
        #expect(
            plan.steps.contains { step in
                guard case .runCommand(let arguments, false) = step.action else {
                    return false
                }
                return arguments == [
                    "/bin/chmod",
                    "-N",
                    "/tmp/macos-node/etc/kubernetes/container-macos-node-status.json",
                ]
            })
        let writeNodeStatusIndex = try #require(
            plan.steps.firstIndex { $0.message == "write macOS node status collector configuration" }
        )
        let protectNodeStatusIndex = try #require(
            plan.steps.firstIndex {
                $0.message == "remove inherited ACL from macOS node status collector configuration"
            }
        )
        #expect(writeNodeStatusIndex < protectNodeStatusIndex)

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
                return path == "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.macos-node-bootstrap.plist"
                    && contents.contains("<string>start-container-system</string>")
                    && contents.contains("<string>0</string>")
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
                    && contents.contains("maxPods: 2")
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
                    && contents.contains(#""dualStackEnabled": false"#)
                    && contents.contains(#""vmnetDisconnectRecovery": "disabled""#)
                    && contents.contains(#""nodeName": "macos-ci-1""#)
                    && contents.contains(#""statusPath": "/var/lib/container/vmnet-recovery/status.json""#)
                    && contents.contains(#""runtimeStatePath": "/var/lib/container/cri-shim-macos/pod-network.json""#)
                    && contents.contains(#""readyStatePath": "/var/lib/container/flannel-vxlan/ready.json""#)
                    && contents.contains(#""storageRoot": "/var/lib/container/cri-shim-macos/machine-state/v1""#)
                    && contents.contains(#""controlSocketRoot": "/var/run/container/machine-state/v1""#)
                    && contents.contains(#""leaseRoot": "/var/lib/container/cri-shim-macos/machine-state-leases/v1""#)
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf"
                    && contents.contains(#""nodeKubeconfig": "/etc/kubernetes/kubelet.conf""#)
                    && contents.contains(#""nodeName": "macos-ci-1""#)
                    && contents.contains(#""dualStackEnabled": false"#)
                    && contents.contains(#""statusPath": "/var/lib/container/flannel-vxlan/status.json""#)
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

    @Test func dualStackJoinPlanEnablesAllPodNetworkConsumersTogether() throws {
        var options = try makeOptions(startServices: false)
        options.enableDualStack = true

        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let renderedConfigurations = Dictionary(
            uniqueKeysWithValues: plan.steps.compactMap { step -> (String, String)? in
                guard case .writeFile(let path, let contents, _, _) = step.action else {
                    return nil
                }
                return (path, contents)
            }
        )
        let criShim = try #require(
            renderedConfigurations["/tmp/macos-node/etc/kubernetes/container-cri-shim-macos-config.json"]
        )
        let flannel = try #require(
            renderedConfigurations["/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf"]
        )
        let kubeProxy = try #require(
            renderedConfigurations["/tmp/macos-node/etc/kubernetes/kube-proxy.conf"]
        )

        #expect(criShim.contains(#""dualStackEnabled": true"#))
        #expect(flannel.contains(#""dualStackEnabled": true"#))
        #expect(kubeProxy.contains(#""dualStackEnabled": true"#))
        #expect(kubeProxy.contains(#""masqueradeIPv6PodTraffic": true"#))
    }

    @Test func stopSandboxRecoveryRequiresFullNetworkMode() throws {
        var options = try makeOptions(startServices: false)
        options.networkMode = .compat
        options.vmnetDisconnectRecovery = .stopSandbox

        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--vmnet-disconnect-recovery requires --network-mode full"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: options)
        }
    }

    @Test func rebootNodeRecoveryStagesAndStartsCoordinatorOnlyWhenEnabled() throws {
        var enabled = try makeOptions(startServices: true)
        enabled.vmnetDisconnectRecovery = .rebootNode
        enabled.containerServiceUserID = 501

        let enabledPlan = try MacOSKubeadmPlanner.joinPlan(options: enabled)
        #expect(
            !enabledPlan.steps.contains { step in
                step.message == "assign private machine-state directories to the container service user"
            }
        )
        let recoveryPlist = try #require(
            enabledPlan.steps.compactMap { step -> String? in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action,
                    path == "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.vmnet-recovery-macos.plist"
                else {
                    return nil
                }
                return contents
            }.first
        )
        #expect(recoveryPlist.contains("<string>asuser</string>"))
        #expect(recoveryPlist.contains("<string>501</string>"))
        #expect(
            enabledPlan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o600, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/container-macos-node-status.json"
                    && contents.contains(#""vmnetRecovery": true"#)
            }
        )
        #expect(
            enabledPlan.steps.contains { step in
                guard step.message == "ensure private vmnet recovery directory",
                    case .createDirectory(
                        "/tmp/macos-node/var/lib/container/vmnet-recovery",
                        0o700
                    ) = step.action
                else {
                    return false
                }
                return true
            }
        )
        #expect(
            enabledPlan.steps.contains { step in
                guard step.message == "ensure private vmnet recovery request directory",
                    case .createDirectory(
                        "/tmp/macos-node/var/lib/container/vmnet-recovery/requests",
                        0o700
                    ) = step.action
                else {
                    return false
                }
                return true
            }
        )
        #expect(
            enabledPlan.steps.contains { step in
                guard step.message == "grant container service user access to vmnet recovery state",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments.contains("501")
                    && arguments.contains("/tmp/macos-node/var/lib/container")
                    && arguments.contains("/tmp/macos-node/var/lib/container/vmnet-recovery")
                    && arguments.contains("/tmp/macos-node/var/lib/container/vmnet-recovery/requests")
                    && arguments[2].contains("container_traverse_acl")
                    && arguments[2].contains("file_inherit")
                    && arguments[2].contains("only_inherit")
                    && arguments[2].contains("state.json.lock")
                    && arguments[2].contains("add_file")
                    && !arguments[2].contains("delete_child")
            }
        )
        #expect(enabledPlan.steps.contains { $0.message == "start vmnet recovery launchd job" })
        #expect(enabledPlan.steps.contains { $0.message == "kickstart vmnet recovery launchd job" })
        #expect(
            enabledPlan.steps.contains { step in
                guard step.message == "remove stale vmnet recovery status",
                    case .removePath(let path, false, true, false) = step.action
                else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/container/vmnet-recovery/status.json"
            })
        let enabledDescriptions = enabledPlan.steps.map(\.message)
        let stopRecoveryIndex = try #require(
            enabledDescriptions.firstIndex(of: "stop previous vmnet recovery launchd job if present")
        )
        let removeStatusIndex = try #require(
            enabledDescriptions.firstIndex(of: "remove stale vmnet recovery status")
        )
        #expect(stopRecoveryIndex < removeStatusIndex)

        let disabled = try makeOptions(startServices: true)
        let disabledPlan = try MacOSKubeadmPlanner.joinPlan(options: disabled)
        #expect(
            !disabledPlan.steps.contains { step in
                guard case .writeFile(let path, _, _, _) = step.action else {
                    return false
                }
                return path.hasSuffix("com.apple.container.vmnet-recovery-macos.plist")
            }
        )
        #expect(!disabledPlan.steps.contains { $0.message == "start vmnet recovery launchd job" })
        #expect(disabledPlan.steps.contains { $0.message == "remove previous vmnet recovery launchd plist" })
        #expect(disabledPlan.steps.contains { $0.message == "remove stale vmnet recovery status" })
        #expect(
            disabledPlan.steps.contains { step in
                guard step.message == "remove stale vmnet recovery status",
                    case .removePath(let path, false, true, false) = step.action
                else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/container/vmnet-recovery/status.json"
            }
        )
    }

    @Test func dualStackJoinPlanRendersExplicitNodeContract() throws {
        var options = try makeOptions(startServices: false)
        options.enableDualStack = true
        options.nodeIPAddresses = [
            "203.0.113.208",
            "2001:db8:100:c:203:0:113:208",
        ]
        options.flannelConfigMapNamespace = "kube-flannel"
        options.flannelConfigMapName = "kube-flannel-cfg-macos-ds-mac-canary-a"
        options.flannelUnderlayInterface = "en0"
        options.runtimeClasses = [
            MacOSKubeadmRuntimeClassProfile(
                name: "macos-gui",
                sandboxImage: "localhost/macos-sandbox:test",
                networkMode: .full,
                guiEnabled: true
            )
        ]

        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let renderedConfigurations = Dictionary(
            uniqueKeysWithValues: plan.steps.compactMap { step -> (String, String)? in
                guard case .writeFile(let path, let contents, _, _) = step.action else {
                    return nil
                }
                return (path, contents)
            }
        )

        let flannel = try #require(
            renderedConfigurations["/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf"]
        )
        let flannelObject = try #require(
            JSONSerialization.jsonObject(with: Data(flannel.utf8)) as? [String: Any]
        )
        #expect(flannelObject["configMapNamespace"] as? String == "kube-flannel")
        #expect(flannelObject["configMapName"] as? String == "kube-flannel-cfg-macos-ds-mac-canary-a")
        #expect(flannelObject["underlayInterface"] as? String == "en0")

        let criShim = try #require(
            renderedConfigurations["/tmp/macos-node/etc/kubernetes/container-cri-shim-macos-config.json"]
        )
        let criShimObject = try #require(
            JSONSerialization.jsonObject(with: Data(criShim.utf8)) as? [String: Any]
        )
        let handlers = try #require(criShimObject["runtimeHandlers"] as? [String: Any])
        let guiHandler = try #require(handlers["macos-gui"] as? [String: Any])
        #expect(guiHandler["guiEnabled"] as? Bool == true)

        let kubeletPlist = try #require(
            renderedConfigurations["/tmp/macos-node/Library/LaunchDaemons/com.apple.container.kubelet.plist"]
        )
        let kubeletObject = try #require(
            PropertyListSerialization.propertyList(
                from: Data(kubeletPlist.utf8),
                format: nil
            ) as? [String: Any]
        )
        let kubeletArguments = try #require(kubeletObject["ProgramArguments"] as? [String])
        let nodeIPIndex = try #require(kubeletArguments.firstIndex(of: "--node-ip"))
        #expect(kubeletArguments.filter { $0 == "--node-ip" }.count == 1)
        #expect(kubeletArguments[nodeIPIndex + 1] == "203.0.113.208,2001:db8:100:c:203:0:113:208")
    }

    @Test func dualStackExplicitNodeIPsRequireBothFamiliesInOrder() throws {
        var missingIPv6 = try makeOptions(startServices: false)
        missingIPv6.enableDualStack = true
        missingIPv6.nodeIPAddresses = ["203.0.113.208"]
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "dual-stack --node-ip requires one IPv4 address followed by one IPv6 address"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: missingIPv6)
        }

        var reversed = try makeOptions(startServices: false)
        reversed.enableDualStack = true
        reversed.nodeIPAddresses = [
            "2001:db8:100:c:203:0:113:208",
            "203.0.113.208",
        ]
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "dual-stack --node-ip values must be ordered IPv4,IPv6"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: reversed)
        }
    }

    @Test func nodeIPValidationRejectsInvalidOrIncompatibleAddresses() throws {
        var invalid = try makeOptions(startServices: false)
        invalid.nodeIPAddresses = ["not-an-ip"]
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--node-ip must be a valid usable unicast IP address"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: invalid)
        }

        var duplicate = try makeOptions(startServices: false)
        duplicate.enableDualStack = true
        duplicate.nodeIPAddresses = ["203.0.113.208", "203.0.113.208"]
        #expect(throws: MacOSKubeadmError.invalidInput("--node-ip values must be unique")) {
            try MacOSKubeadmPlanner.joinPlan(options: duplicate)
        }

        var multipleWithoutDualStack = try makeOptions(startServices: false)
        multipleWithoutDualStack.nodeIPAddresses = [
            "203.0.113.208",
            "2001:db8:100:c:203:0:113:208",
        ]
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "multiple --node-ip values require --enable-dual-stack"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: multipleWithoutDualStack)
        }

        var fullModeIPv6Only = try makeOptions(startServices: false)
        fullModeIPv6Only.nodeIPAddresses = ["2001:db8:100:c:203:0:113:208"]
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "full-mode IPv4 Pod networking requires an IPv4 --node-ip"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: fullModeIPv6Only)
        }
    }

    @Test func flannelJoinOptionsRequireValidFullModeValues() throws {
        var invalidNamespace = try makeOptions(startServices: false)
        invalidNamespace.flannelConfigMapNamespace = "Kube_Flannel"
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--flannel-config-map-namespace must be a valid DNS label"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: invalidNamespace)
        }

        var invalidName = try makeOptions(startServices: false)
        invalidName.flannelConfigMapName = "kube-flannel..macos"
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--flannel-config-map-name must be a valid DNS subdomain"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: invalidName)
        }

        var invalidInterface = try makeOptions(startServices: false)
        invalidInterface.flannelUnderlayInterface = "en0;route"
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--flannel-underlay-interface must be a valid interface name"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: invalidInterface)
        }

        var compat = try makeOptions(startServices: false)
        compat.networkMode = .compat
        compat.kubeProxyToken = nil
        compat.flannelToken = nil
        compat.flannelConfigMapName = "kube-flannel-cfg-macos"
        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "Flannel options require --network-mode full"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: compat)
        }
    }

    @Test func dualStackJoinPlanRendersExplicitIPv6NATSource() throws {
        var options = try makeOptions(startServices: false)
        options.enableDualStack = true
        options.masqueradeIPv6PodTraffic = true
        options.ipv6EgressInterface = "en7"
        options.ipv6EgressSourceAddress = "2001:db8:100:c::7"

        let pf = try renderedKubeProxyPF(options: options)

        #expect(pf["masqueradeIPv6PodTraffic"] as? Bool == true)
        #expect(pf["ipv6EgressInterface"] as? String == "en7")
        #expect(pf["ipv6EgressSourceAddress"] as? String == "2001:db8:100:c::7")
    }

    @Test func dualStackJoinPlanCanDisableIPv6Masquerade() throws {
        var options = try makeOptions(startServices: false)
        options.enableDualStack = true
        options.masqueradeIPv6PodTraffic = false

        let pf = try renderedKubeProxyPF(options: options)

        #expect(pf["masqueradeIPv6PodTraffic"] as? Bool == false)
        #expect(pf["ipv6EgressInterface"] == nil)
        #expect(pf["ipv6EgressSourceAddress"] == nil)
    }

    @Test func dualStackJoinPlanLeavesUnspecifiedIPv6NATSourceForRuntimeValidation() throws {
        var options = try makeOptions(startServices: false)
        options.enableDualStack = true
        options.ipv6EgressInterface = "en7"

        let pf = try renderedKubeProxyPF(options: options)

        #expect(pf["masqueradeIPv6PodTraffic"] as? Bool == true)
        #expect(pf["ipv6EgressInterface"] as? String == "en7")
        #expect(pf["ipv6EgressSourceAddress"] == nil)
    }

    @Test func IPv6EgressOptionsRequireDualStack() throws {
        for scenario in 0..<3 {
            var options = try makeOptions(startServices: false)
            switch scenario {
            case 0:
                options.masqueradeIPv6PodTraffic = false
            case 1:
                options.ipv6EgressInterface = "en7"
            default:
                options.ipv6EgressSourceAddress = "2001:db8:100:c::7"
            }

            #expect(throws: MacOSKubeadmError.invalidInput("IPv6 egress options require --enable-dual-stack")) {
                try MacOSKubeadmPlanner.joinPlan(options: options)
            }
        }
    }

    @Test func compatJoinPlanRejectsIPv6EgressOptions() throws {
        var options = try makeOptions(startServices: false)
        options.networkMode = .compat
        options.enableDualStack = true
        options.ipv6EgressInterface = "en7"
        options.kubeProxyToken = nil
        options.flannelToken = nil

        #expect(throws: MacOSKubeadmError.invalidInput("IPv6 egress options require --network-mode full")) {
            try MacOSKubeadmPlanner.joinPlan(options: options)
        }
    }

    @Test func routedIPv6EgressRejectsNATSourceOptions() throws {
        var options = try makeOptions(startServices: false)
        options.enableDualStack = true
        options.masqueradeIPv6PodTraffic = false
        options.ipv6EgressSourceAddress = "2001:db8:100:c::7"

        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--disable-ipv6-masquerade cannot be combined with --ipv6-egress-interface or --ipv6-egress-source-address"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: options)
        }
    }

    @Test func IPv6EgressInterfaceMustHaveValidFormat() throws {
        var options = try makeOptions(startServices: false)
        options.enableDualStack = true
        options.ipv6EgressInterface = "en7; pass all"

        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--ipv6-egress-interface must be a valid interface name"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: options)
        }
    }

    @Test func IPv6EgressSourceMustHaveValidFormat() throws {
        var options = try makeOptions(startServices: false)
        options.enableDualStack = true
        options.ipv6EgressSourceAddress = "192.0.2.7"

        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--ipv6-egress-source-address must be a valid IPv6 address"
            )
        ) {
            try MacOSKubeadmPlanner.joinPlan(options: options)
        }
    }

    @Test func IPv6EgressSourceMustBeUsableUnicastAddress() throws {
        for sourceAddress in ["::", "::1", "fe80::7", "ff02::1", "::ffff:192.0.2.7"] {
            var options = try makeOptions(startServices: false)
            options.enableDualStack = true
            options.ipv6EgressSourceAddress = sourceAddress

            #expect(
                throws: MacOSKubeadmError.invalidInput(
                    "--ipv6-egress-source-address must be a usable unicast IPv6 address"
                )
            ) {
                try MacOSKubeadmPlanner.joinPlan(options: options)
            }
        }
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
        #expect(!writePaths.contains("/tmp/macos-node/etc/kubernetes/container-macos-node-status.json"))
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
        #expect(descriptions.contains("withdraw previous kube-proxy PF configuration"))
        #expect(descriptions.contains("flush previous kube-proxy PF anchor"))
        #expect(descriptions.contains("flush previous kube-proxy IPv6 PF anchor"))
        #expect(descriptions.contains("purge owned pod network"))

        #expect(
            plan.steps.contains { step in
                guard step.message == "withdraw previous kube-proxy PF configuration",
                    case .runCommand(let arguments, let bestEffort) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-kube-proxy-macos",
                    "--config",
                    "/tmp/macos-node/etc/kubernetes/kube-proxy.conf",
                    "--withdraw",
                ] && !bestEffort
            }
        )

        for path in [
            "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.flannel-vxlan-macos.plist",
            "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.kube-proxy-macos.plist",
            "/tmp/macos-node/etc/kubernetes/flannel-vxlan-macos.conf",
            "/tmp/macos-node/etc/kubernetes/kube-proxy.conf",
            "/tmp/macos-node/etc/kubernetes/container-macos-node-status.json",
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

    @Test func compatJoinPlanRejectsDualStack() throws {
        var options = try makeOptions(startServices: false)
        options.networkMode = .compat
        options.enableDualStack = true
        options.kubeProxyToken = nil
        options.flannelToken = nil

        #expect(throws: MacOSKubeadmError.invalidInput("--enable-dual-stack requires --network-mode full")) {
            try MacOSKubeadmPlanner.joinPlan(options: options)
        }
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
        #expect(!descriptions.contains("withdraw previous kube-proxy PF configuration"))
        #expect(!descriptions.contains("flush previous kube-proxy PF anchor"))
        #expect(!descriptions.contains("flush previous kube-proxy IPv6 PF anchor"))
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
        let removeStatusIndex = try #require(descriptions.firstIndex(of: "remove stale flannel VXLAN status"))
        let purgeIndex = try #require(descriptions.firstIndex(of: "purge owned pod network"))
        let configRemovalIndex = try #require(
            descriptions.firstIndex(of: "remove full-mode artifact /etc/kubernetes/flannel-vxlan-macos.conf")
        )
        let credentialRemovalIndex = try #require(descriptions.firstIndex(of: "remove full-mode Kubernetes credentials"))

        #expect(preflightIndex < stopKubeletIndex)
        #expect(stopKubeletIndex < stopProxyIndex)
        #expect(stopProxyIndex < withdrawIndex)
        #expect(withdrawIndex < stopIndex)
        #expect(stopIndex < removeStatusIndex)
        #expect(stopIndex < stopCRIIndex)
        #expect(removeStatusIndex < stopCRIIndex)
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
        let macos15Point2 = try #require(runtimeHandlers["macos-15-2"] as? [String: Any])
        let macos15Point4 = try #require(runtimeHandlers["macos-15-4"] as? [String: Any])
        #expect(macosCompat["networkBackend"] as? String == "virtualizationNAT")
        #expect(macos15Point2["sandboxImage"] as? String == "ghcr.io/jianliang00/macos-base:15.2")
        #expect(macos15Point2["networkBackend"] as? String == "virtualizationNAT")
        #expect(macos15Point4["sandboxImage"] as? String == "ghcr.io/jianliang00/macos-base:15.4")
        #expect(macos15Point4["networkBackend"] as? String == "virtualizationNAT")

        let runtimeClass15Point2 = try #require(
            writes.first {
                $0.path == "/tmp/macos-node/usr/local/share/container-macos-node/manifests/runtimeclass-macos-15-2.yaml"
            }?.contents
        )
        #expect(runtimeClass15Point2.contains("name: macos-15-2"))
        #expect(runtimeClass15Point2.contains("handler: macos-15-2"))
        #expect(runtimeClass15Point2.contains("node.kubernetes.io/macos-network: \"compat\""))

        let runtimeClass15Point4 = try #require(
            writes.first {
                $0.path == "/tmp/macos-node/usr/local/share/container-macos-node/manifests/runtimeclass-macos-15-4.yaml"
            }?.contents
        )
        #expect(runtimeClass15Point4.contains("name: macos-15-4"))
        #expect(runtimeClass15Point4.contains("handler: macos-15-4"))
        #expect(runtimeClass15Point4.contains("node.kubernetes.io/macos-network: \"compat\""))
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

        let containerSystemIndex = try #require(descriptions.firstIndex(of: "start container core services"))
        let bootstrapEnableIndex = try #require(
            descriptions.firstIndex(of: "enable container system bootstrap launchd job")
        )
        let bootstrapStartIndex = try #require(
            descriptions.firstIndex(of: "start container system bootstrap launchd job")
        )
        let criIndex = try #require(descriptions.firstIndex(of: "start CRI shim launchd job"))
        let waitIndex = try #require(descriptions.firstIndex(of: "wait for CRI socket"))
        let flannelEnableIndex = try #require(descriptions.firstIndex(of: "enable flannel VXLAN launchd job"))
        let flannelIndex = try #require(descriptions.firstIndex(of: "start flannel VXLAN launchd job"))
        let kubeletIndex = try #require(descriptions.firstIndex(of: "start kubelet launchd job"))
        let kubeProxyEnableIndex = try #require(descriptions.firstIndex(of: "enable kube-proxy launchd job"))
        let kubeProxyIndex = try #require(descriptions.firstIndex(of: "start kube-proxy launchd job"))

        #expect(containerSystemIndex < bootstrapEnableIndex)
        #expect(bootstrapEnableIndex < bootstrapStartIndex)
        #expect(bootstrapStartIndex < criIndex)
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
            (
                "stop previous container system bootstrap launchd job if present",
                "system/com.apple.container.macos-node-bootstrap"
            ),
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
            #expect(arguments.count == 9)
            #expect(arguments[2].contains("job_present"))
            #expect(arguments[2].contains("bootout"))
            #expect(arguments[4] == label)
            #expect(arguments[5] == "/bin/launchctl")
            #expect(arguments[6] == "/bin/sleep")
            #expect(arguments[7] == "50")
            #expect(arguments[8] == "0.1")
        }

        let bootstrapStopIndex = try #require(
            plan.steps.firstIndex { $0.message == "stop previous container system bootstrap launchd job if present" }
        )
        let containerStopIndex = try #require(
            plan.steps.firstIndex { $0.message == "stop container core services if present" }
        )
        let containerStartIndex = try #require(
            plan.steps.firstIndex { $0.message == "start container core services" }
        )
        #expect(bootstrapStopIndex < containerStopIndex)
        #expect(containerStopIndex < containerStartIndex)
    }

    @Test func launchdStopAcceptsAnInitiallyMissingJob() throws {
        let result = try runLaunchdStopScenario("absent")

        #expect(result.status == 0)
        #expect(!result.calls.contains("bootout"))
        #expect(!result.calls.contains("sleep"))
    }

    @Test func launchdStopWaitsForAnAsynchronousBootout() throws {
        let result = try runLaunchdStopScenario("async-failure")

        #expect(result.status == 0)
        #expect(result.calls.filter { $0 == "bootout" }.count == 1)
        #expect(result.calls.filter { $0 == "sleep" }.count == 2)
    }

    @Test(arguments: ["persistent-failure", "persistent-success"])
    func launchdStopFailsWhenTheJobNeverDisappears(_ scenario: String) throws {
        let result = try runLaunchdStopScenario(scenario)

        #expect(result.status == 1)
        #expect(result.calls.filter { $0 == "bootout" }.count == 1)
        #expect(result.calls.filter { $0 == "sleep" }.count == 3)
    }

    @Test func launchdStopFailsClosedOnAnUnexpectedQueryError() throws {
        let result = try runLaunchdStopScenario("query-error")

        #expect(result.status == 77)
        #expect(!result.calls.contains("bootout"))
        #expect(!result.calls.contains("sleep"))
    }

    @Test func serviceStartPlanUsesRootUserBootstrapForContainerRuntime() throws {
        let options = try makeOptions(startServices: true)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)

        #expect(!plan.steps.contains { $0.message == "ensure container service user launchd domain" })

        #expect(
            plan.steps.contains { step in
                guard step.message == "stop container core services if present",
                    case .runCommand(_, false) = step.action
                else {
                    return false
                }
                return true
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "start container core services",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-macos-kubeadm",
                    "start-container-system",
                    "--container-service-user",
                    "0",
                ]
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "enable container system bootstrap launchd job",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/bin/launchctl",
                    "enable",
                    "system/com.apple.container.macos-node-bootstrap",
                ]
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "start container system bootstrap launchd job",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/bin/launchctl",
                    "bootstrap",
                    "system",
                    "/Library/LaunchDaemons/com.apple.container.macos-node-bootstrap.plist",
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
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-macos-kubeadm",
                    "stop-container-system",
                    "--container-service-user",
                    "0",
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
                    "/usr/local/bin/container-macos-kubeadm",
                    "start-container-system",
                    "--container-service-user",
                    "501",
                ]
            })

        let stopContainerIndex = try #require(
            plan.steps.firstIndex { $0.message == "stop container core services if present" }
        )
        let startContainerIndex = try #require(
            plan.steps.firstIndex { $0.message == "start container core services" }
        )
        #expect(stopContainerIndex < startContainerIndex)
        #expect(!plan.steps.contains { $0.message == "ensure container service user launchd domain" })

        #expect(
            plan.steps.contains { step in
                guard step.message == "stop container core services if present",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-macos-kubeadm",
                    "stop-container-system",
                    "--container-service-user",
                    "501",
                ]
            })

        #expect(
            !plan.steps.contains { step in
                guard case .runCommand(let arguments, _) = step.action else {
                    return false
                }
                return arguments.starts(with: ["/bin/launchctl", "asuser", "501"])
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "write container system bootstrap launchd plist",
                    case .writeFile(let path, let contents, 0o644, false) = step.action
                else {
                    return false
                }
                return path == "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.macos-node-bootstrap.plist"
                    && contents.contains("<string>--container-service-user</string>")
                    && contents.contains("<string>501</string>")
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

    @Test func skipStartDoesNotDispatchNonRootContainerSystemOperations() throws {
        var options = try makeOptions(startServices: false)
        options.containerServiceUserID = 501

        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)

        #expect(!plan.steps.contains { $0.message == "stop container core services if present" })
        #expect(!plan.steps.contains { $0.message == "start container core services" })
        #expect(
            !plan.steps.contains { step in
                guard case .runCommand(let arguments, _) = step.action else {
                    return false
                }
                return arguments.starts(with: [
                    "/usr/local/bin/container-macos-kubeadm",
                    "start-container-system",
                ])
                    || arguments.starts(with: [
                        "/usr/local/bin/container-macos-kubeadm",
                        "stop-container-system",
                    ])
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

    @Test func joinPlanRejectsReservedContainerServiceUID() throws {
        var options = try makeOptions(startServices: false)
        options.containerServiceUserID = Int(UInt32.max)

        #expect(throws: MacOSKubeadmError.invalidInput("--container-service-user must be a valid uid")) {
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
        let stopBootstrapIndex = try #require(
            descriptions.firstIndex(of: "stop container system bootstrap launchd job if present")
        )
        let cleanupOperationsIndex = try #require(
            descriptions.firstIndex(of: "clean container system operation agents")
        )
        let removeBootstrapIndex = try #require(
            descriptions.firstIndex(of: "remove container system bootstrap launchd plist")
        )
        let stopRecoveryIndex = try #require(
            descriptions.firstIndex(of: "stop vmnet recovery launchd job if present")
        )
        let removeRecoveryStatusIndex = try #require(
            descriptions.firstIndex(of: "remove stale vmnet recovery status")
        )
        let stopKubeletIndex = try #require(descriptions.firstIndex(of: "stop kubelet launchd job if present"))
        let stopProxyIndex = try #require(descriptions.firstIndex(of: "stop kube-proxy launchd job if present"))
        let withdrawProxyIndex = try #require(
            descriptions.firstIndex(of: "withdraw kube-proxy PF configuration")
        )
        let withdrawFlannelIndex = try #require(descriptions.firstIndex(of: "withdraw flannel VXLAN data plane"))
        let stopFlannelIndex = try #require(descriptions.firstIndex(of: "stop flannel VXLAN launchd job if present"))
        let stopCRIIndex = try #require(descriptions.firstIndex(of: "stop CRI shim launchd job if present"))
        let purgeIndex = try #require(descriptions.firstIndex(of: "purge owned pod network"))
        let removeFlannelConfigIndex = try #require(descriptions.firstIndex(of: "remove /etc/kubernetes/flannel-vxlan-macos.conf"))
        let removeNodeStatusConfigIndex = try #require(
            descriptions.firstIndex(of: "remove /etc/kubernetes/container-macos-node-status.json")
        )
        let removeProxyStatusIndex = try #require(
            descriptions.firstIndex(of: "remove /var/lib/container/kube-proxy-macos/status.json")
        )
        let removeFlannelStatusIndex = try #require(
            descriptions.firstIndex(of: "remove /var/lib/container/flannel-vxlan/status.json")
        )
        let firstGeneratedRemoveIndex = try #require(
            descriptions.firstIndex(of: "remove /Library/LaunchDaemons/com.apple.container.kubelet.plist")
        )

        #expect(preflightIndex < stopBootstrapIndex)
        #expect(stopBootstrapIndex < cleanupOperationsIndex)
        #expect(cleanupOperationsIndex < removeBootstrapIndex)
        #expect(removeBootstrapIndex < stopRecoveryIndex)
        #expect(stopRecoveryIndex < removeRecoveryStatusIndex)
        #expect(removeRecoveryStatusIndex < stopKubeletIndex)
        #expect(stopKubeletIndex < firstGeneratedRemoveIndex)
        #expect(stopKubeletIndex < stopProxyIndex)
        #expect(stopProxyIndex < withdrawProxyIndex)
        #expect(withdrawProxyIndex < removeProxyStatusIndex)
        #expect(stopProxyIndex < withdrawFlannelIndex)
        #expect(withdrawFlannelIndex < removeFlannelStatusIndex)
        #expect(withdrawFlannelIndex < stopFlannelIndex)
        #expect(stopFlannelIndex < removeFlannelStatusIndex)
        #expect(stopFlannelIndex < stopCRIIndex)
        #expect(stopCRIIndex < purgeIndex)
        #expect(purgeIndex < removeFlannelStatusIndex)
        #expect(purgeIndex < removeFlannelConfigIndex)
        #expect(purgeIndex < removeNodeStatusConfigIndex)
        #expect(
            plan.steps.contains { step in
                step.message == "clean container system operation agents"
                    && step.action == .cleanupContainerSystemOperations
            }
        )
        #expect(
            plan.steps.contains { step in
                guard step.message == "remove container system bootstrap launchd plist",
                    case .removePath(let path, false, false, false) = step.action
                else {
                    return false
                }
                return path == "/Library/LaunchDaemons/com.apple.container.macos-node-bootstrap.plist"
            }
        )
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
        #expect(
            plan.steps.contains { step in
                guard step.message == "withdraw kube-proxy PF configuration",
                    case .runCommand(let arguments, let bestEffort) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/usr/local/bin/container-kube-proxy-macos",
                    "--config",
                    "/etc/kubernetes/kube-proxy.conf",
                    "--withdraw",
                ] && !bestEffort
            }
        )
        for (message, anchorName) in [
            ("flush kube-proxy PF anchor if present", "com.apple.container.kube-proxy"),
            ("flush kube-proxy IPv6 PF anchor if present", "com.apple.container.kube-proxy.ipv6"),
        ] {
            #expect(
                plan.steps.contains { step in
                    guard step.message == message,
                        case .runCommand(let arguments, let bestEffort) = step.action
                    else {
                        return false
                    }
                    return arguments == ["/sbin/pfctl", "-a", anchorName, "-F", "all"] && bestEffort
                }
            )
        }
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
        #expect(
            plan.steps.contains { step in
                guard case .removePath(let path, true, true, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/var/log/container-macos-node-bootstrap.log"
            })
        #expect(
            plan.steps.contains { step in
                guard case .removePath(let path, true, true, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/container/kube-proxy-macos"
            })
        #expect(
            plan.steps.contains { step in
                guard case .removePath(let path, true, true, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/private/var/run/container/cri-shim-macos"
            }
        )
    }

    @Test func resetRemovesAllGeneratedRuntimeClassManifests() throws {
        let plan = try MacOSKubeadmPlanner.resetPlan(
            options: MacOSKubeadmResetOptions(
                installRoot: "/tmp/macos-node",
                dryRun: true
            )
        )

        #expect(
            plan.steps.contains { step in
                guard step.message == "remove generated RuntimeClass manifests",
                    case .removeRuntimeClassManifests(let directory, let bestEffort) = step.action
                else {
                    return false
                }
                return directory == "/tmp/macos-node/usr/local/share/container-macos-node/manifests"
                    && bestEffort
            }
        )
        #expect(
            !plan.steps.contains { step in
                guard case .removePath(let path, _, _, _) = step.action else {
                    return false
                }
                return path.contains("/manifests/runtimeclass-")
            }
        )
    }

    @Test func runtimeClassManifestCleanerOnlyRemovesGeneratedFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("container-macos-kubeadm-runtimeclass-cleaner-\(UUID().uuidString)")
        let manifests = root.appendingPathComponent("manifests")
        let externalTarget = root.appendingPathComponent("external-target.yaml")
        try fileManager.createDirectory(at: manifests, withIntermediateDirectories: true)
        try "external".write(to: externalTarget, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        for fileName in [
            "runtimeclass-macos.yaml",
            "runtimeclass-macos-gui.yaml",
            "runtimeclass-macos-15-2.yaml",
        ] {
            try "generated".write(
                to: manifests.appendingPathComponent(fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        for fileName in [
            "macos-node-bootstrap-rbac.yaml",
            "runtimeclass-.yaml",
            "runtimeclass-macos.yml",
            "runtimeclass-macos.extra.yaml",
        ] {
            try "preserved".write(
                to: manifests.appendingPathComponent(fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        try fileManager.createDirectory(
            at: manifests.appendingPathComponent("runtimeclass-directory.yaml"),
            withIntermediateDirectories: false
        )
        try fileManager.createSymbolicLink(
            at: manifests.appendingPathComponent("runtimeclass-link.yaml"),
            withDestinationURL: externalTarget
        )
        try fileManager.createSymbolicLink(
            at: manifests.appendingPathComponent("runtimeclass-dangling.yaml"),
            withDestinationURL: root.appendingPathComponent("missing-target.yaml")
        )

        try MacOSKubeadmRuntimeClassManifestCleaner.remove(
            in: manifests.path,
            bestEffort: false,
            log: MacOSKubeadmLog()
        )

        let remaining = try Set(fileManager.contentsOfDirectory(atPath: manifests.path))
        #expect(
            remaining == [
                "macos-node-bootstrap-rbac.yaml",
                "runtimeclass-.yaml",
                "runtimeclass-directory.yaml",
                "runtimeclass-macos.extra.yaml",
                "runtimeclass-macos.yml",
            ]
        )
        #expect(try String(contentsOf: externalTarget, encoding: .utf8) == "external")

        try MacOSKubeadmRuntimeClassManifestCleaner.remove(
            in: root.appendingPathComponent("missing").path,
            bestEffort: false,
            log: MacOSKubeadmLog()
        )

        #expect(MacOSKubeadmRuntimeClassManifestCleaner.isGeneratedManifest("runtimeclass-macos-gui.yaml"))
        #expect(!MacOSKubeadmRuntimeClassManifestCleaner.isGeneratedManifest("runtimeclass-MACOS.yaml"))
        #expect(!MacOSKubeadmRuntimeClassManifestCleaner.isGeneratedManifest("runtimeclass-.yaml"))
    }

    @Test func runtimeClassManifestCleanerDoesNotFollowDirectorySymlinks() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("container-macos-kubeadm-runtimeclass-symlink-\(UUID().uuidString)")
        let externalDirectory = root.appendingPathComponent("external")
        let externalManifest = externalDirectory.appendingPathComponent("runtimeclass-external.yaml")
        let manifestsLink = root.appendingPathComponent("manifests")
        try fileManager.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try "external".write(to: externalManifest, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: manifestsLink, withDestinationURL: externalDirectory)
        defer { try? fileManager.removeItem(at: root) }

        #expect(throws: (any Error).self) {
            try MacOSKubeadmRuntimeClassManifestCleaner.remove(
                in: manifestsLink.path,
                bestEffort: false,
                log: MacOSKubeadmLog()
            )
        }
        try MacOSKubeadmRuntimeClassManifestCleaner.remove(
            in: manifestsLink.path,
            bestEffort: true,
            log: MacOSKubeadmLog()
        )

        #expect(try String(contentsOf: externalManifest, encoding: .utf8) == "external")
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

    private struct LaunchdStopResult {
        let status: Int32
        let calls: [String]
    }

    private func runLaunchdStopScenario(_ scenario: String) throws -> LaunchdStopResult {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-macos-kubeadm-launchd-stop-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let modePath = directory.appendingPathComponent("mode")
        let callsPath = directory.appendingPathComponent("calls")
        let launchctlPath = directory.appendingPathComponent("launchctl")
        let sleepPath = directory.appendingPathComponent("sleep")
        try scenario.write(to: modePath, atomically: true, encoding: .utf8)
        try "".write(to: callsPath, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        set -eu
        state_dir=${FAKE_LAUNCHD_STATE:?}
        mode=$(/bin/cat "$state_dir/mode")
        command=$1
        echo "$command" >> "$state_dir/calls"
        case "$command" in
            print)
                case "$mode" in
                    absent) exit 113 ;;
                    query-error) exit 77 ;;
                    async-failure)
                        if [ ! -e "$state_dir/bootout-seen" ]; then
                            exit 0
                        fi
                        count=0
                        if [ -e "$state_dir/post-bootout-print-count" ]; then
                            count=$(/bin/cat "$state_dir/post-bootout-print-count")
                        fi
                        count=$((count + 1))
                        echo "$count" > "$state_dir/post-bootout-print-count"
                        if [ "$count" -ge 3 ]; then
                            exit 113
                        fi
                        exit 0
                        ;;
                    persistent-failure|persistent-success) exit 0 ;;
                    *) exit 78 ;;
                esac
                ;;
            bootout)
                : > "$state_dir/bootout-seen"
                case "$mode" in
                    async-failure|persistent-failure) exit 1 ;;
                    persistent-success) exit 0 ;;
                    *) exit 79 ;;
                esac
                ;;
            *) exit 80 ;;
        esac
        """.write(to: launchctlPath, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        set -eu
        echo sleep >> "${FAKE_LAUNCHD_STATE:?}/calls"
        """.write(to: sleepPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctlPath.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sleepPath.path)

        let options = try makeOptions(startServices: true)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let step = try #require(plan.steps.first { $0.message == "stop previous kubelet launchd job if present" })
        guard case .runCommand(var arguments, false) = step.action else {
            Issue.record("expected a strict launchd stop command")
            return LaunchdStopResult(status: -1, calls: [])
        }
        arguments[5] = launchctlPath.path
        arguments[6] = sleepPath.path
        arguments[7] = "3"
        arguments[8] = "0"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_LAUNCHD_STATE"] = directory.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let calls = try String(contentsOf: callsPath, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        return LaunchdStopResult(status: process.terminationStatus, calls: calls)
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

    private func renderedKubeProxyPF(options: MacOSKubeadmJoinOptions) throws -> [String: Any] {
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let kubeProxy = try #require(
            plan.steps.compactMap { step -> String? in
                guard case .writeFile(let path, let contents, _, _) = step.action,
                    path == "/tmp/macos-node/etc/kubernetes/kube-proxy.conf"
                else {
                    return nil
                }
                return contents
            }.first
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(kubeProxy.utf8)) as? [String: Any]
        )
        return try #require(object["pf"] as? [String: Any])
    }
}
