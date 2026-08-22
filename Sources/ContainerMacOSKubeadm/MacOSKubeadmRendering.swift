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

public enum MacOSKubeadmRenderer {
    private enum LaunchdKeepAlive {
        case always
        case unsuccessfulExit
    }

    public static func kubeconfig(
        clusterName: String,
        contextName: String,
        userName: String,
        server: URL,
        certificateAuthorityPath: String,
        token: String
    ) -> String {
        kubeconfig(
            clusterName: clusterName,
            contextName: contextName,
            userName: userName,
            server: server,
            certificateAuthorityPath: certificateAuthorityPath,
            credentialKey: "token",
            credentialValue: token
        )
    }

    public static func kubeconfig(
        clusterName: String,
        contextName: String,
        userName: String,
        server: URL,
        certificateAuthorityPath: String,
        tokenFile: String
    ) -> String {
        kubeconfig(
            clusterName: clusterName,
            contextName: contextName,
            userName: userName,
            server: server,
            certificateAuthorityPath: certificateAuthorityPath,
            credentialKey: "tokenFile",
            credentialValue: tokenFile
        )
    }

    private static func kubeconfig(
        clusterName: String,
        contextName: String,
        userName: String,
        server: URL,
        certificateAuthorityPath: String,
        credentialKey: String,
        credentialValue: String
    ) -> String {
        """
        apiVersion: v1
        kind: Config
        clusters:
        - name: \(clusterName)
          cluster:
            server: \(server.absoluteString)
            certificate-authority: \(certificateAuthorityPath)
        users:
        - name: \(userName)
          user:
            \(credentialKey): \(credentialValue)
        contexts:
        - name: \(contextName)
          context:
            cluster: \(clusterName)
            user: \(userName)
        current-context: \(contextName)

        """
    }

    public static func kubeletConfiguration(clusterDNS: String, clusterDomain: String) -> String {
        """
        apiVersion: kubelet.config.k8s.io/v1beta1
        kind: KubeletConfiguration
        address: "0.0.0.0"
        port: 10250
        readOnlyPort: 0
        staticPodPath: "/etc/kubernetes/manifests"
        containerRuntimeEndpoint: "unix:///var/run/container-cri-macos.sock"
        imageServiceEndpoint: "unix:///var/run/container-cri-macos.sock"
        syncFrequency: "5s"
        fileCheckFrequency: "5s"
        runtimeRequestTimeout: "2m"
        failSwapOn: false
        cgroupsPerQOS: false
        enforceNodeAllocatable: []
        evictionHard:
          memory.available: "0%"
        evictionPressureTransitionPeriod: "10s"
        eventRecordQPS: 5
        enableServer: true
        localStorageCapacityIsolation: true
        makeIPTablesUtilChains: false
        maxPods: 2
        clusterDNS:
          - "\(clusterDNS)"
        clusterDomain: "\(clusterDomain)"
        authentication:
          anonymous:
            enabled: false
          webhook:
            enabled: true
          x509:
            clientCAFile: "/etc/kubernetes/pki/ca.crt"
        authorization:
          mode: Webhook

        """
    }

    public static func criShimConfiguration(
        sandboxImage: String,
        networkMode: MacOSKubeadmNetworkMode = .full,
        dualStackEnabled: Bool = false,
        runtimeClasses: [MacOSKubeadmRuntimeClassProfile] = []
    ) -> String {
        let sandboxImageJSON = jsonString(sandboxImage)
        let profiles =
            [
                MacOSKubeadmRuntimeClassProfile(
                    name: networkMode.runtimeClassName,
                    handler: networkMode.runtimeHandler,
                    sandboxImage: sandboxImage,
                    networkMode: networkMode
                )
            ] + runtimeClasses
        let runtimeHandlers = profiles.map(runtimeHandlerJSON).joined(separator: ",\n")

        switch networkMode {
        case .full:
            return """
                {
                    "runtimeEndpoint": "/var/run/container-cri-macos.sock",
                    "stateDirectory": "/var/lib/container/cri-shim-macos",
                    "streaming": {
                        "address": "127.0.0.1",
                        "port": 0
                    },
                    "cni": {
                        "binDir": "/opt/cni/bin",
                        "confDir": "/etc/cni/net.d",
                        "plugin": "macvmnet"
                    },
                    "defaults": {
                        "sandboxImage": \(sandboxImageJSON),
                        "workloadPlatform": {
                            "os": "darwin",
                            "architecture": "arm64"
                        },
                        "network": "kubernetes-pod",
                        "networkBackend": "vmnetShared",
                        "guiEnabled": false
                    },
                    "runtimeHandlers": {
                \(runtimeHandlers)
                    },
                    "networkPolicy": {
                        "enabled": false
                    },
                    "kubeProxy": {
                        "enabled": true,
                        "configPath": "/etc/kubernetes/kube-proxy.conf"
                    },
                    "podNetwork": {
                        "enabled": true,
                        "dualStackEnabled": \(dualStackEnabled),
                        "networkName": "kubernetes-pod",
                        "runtimeStatePath": "/var/lib/container/cri-shim-macos/pod-network.json",
                        "readyStatePath": "/var/lib/container/flannel-vxlan/ready.json"
                    }
                }

                """
        case .compat:
            return """
                {
                    "runtimeEndpoint": "/var/run/container-cri-macos.sock",
                    "stateDirectory": "/var/lib/container/cri-shim-macos",
                    "streaming": {
                        "address": "127.0.0.1",
                        "port": 0
                    },
                    "defaults": {
                        "sandboxImage": \(sandboxImageJSON),
                        "workloadPlatform": {
                            "os": "darwin",
                            "architecture": "arm64"
                        },
                        "network": "default",
                        "networkBackend": "virtualizationNAT",
                        "guiEnabled": false
                    },
                    "runtimeHandlers": {
                \(runtimeHandlers)
                    },
                    "networkPolicy": {
                        "enabled": false
                    },
                    "kubeProxy": {
                        "enabled": false
                    }
                }

                """
        }
    }

    private static func runtimeHandlerJSON(_ profile: MacOSKubeadmRuntimeClassProfile) -> String {
        """
                        \(jsonString(profile.handler)): {
                            "sandboxImage": \(jsonString(profile.sandboxImage)),
                            "network": \(jsonString(profile.networkMode.networkName)),
                            "networkBackend": \(jsonString(profile.networkMode.networkBackend)),
                            "guiEnabled": \(profile.guiEnabled)
                        }
        """
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data(#""""#.utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static func cniConfiguration() -> String {
        """
        {
            "cniVersion": "1.1.0",
            "name": "kubernetes-pod",
            "plugins": [
                {
                    "type": "macvmnet",
                    "network": "kubernetes-pod",
                    "runtime": "container-runtime-macos",
                    "stateDir": "/var/lib/container/cni/macvmnet"
                }
            ]
        }

        """
    }

    public static func flannelVXLANConfiguration(
        nodeName: String,
        containerServiceUserID: Int = 0,
        dualStackEnabled: Bool = false,
        configMapNamespace: String = "kube-flannel",
        configMapName: String = "kube-flannel-cfg",
        underlayInterface: String? = nil
    ) -> String {
        let underlayConfiguration =
            underlayInterface.map {
                """

                    "underlayInterface": \(jsonString($0)),
                """
            } ?? ""

        return """
            {
                "kubeconfig": "/etc/kubernetes/flannel-macos.kubeconfig",
                "nodeKubeconfig": "/etc/kubernetes/kubelet.conf",
                "nodeName": \(jsonString(nodeName)),
                "containerServiceUserID": \(containerServiceUserID),
                "dualStackEnabled": \(dualStackEnabled),
                "configMapNamespace": \(jsonString(configMapNamespace)),
                "configMapName": \(jsonString(configMapName)),
                "networkConfigKey": "net-conf.json",
                "annotationPrefix": "flannel.alpha.coreos.com",
                "vtepMACPath": "/var/lib/container/flannel-vxlan/vtep-mac",
                "runtimeStatePath": "/var/lib/container/cri-shim-macos/pod-network.json",
                "readyStatePath": "/var/lib/container/flannel-vxlan/ready.json",
                "networkName": "kubernetes-pod",
                "networkPlugin": "container-network-vmnet",
                "networkVariant": "reserved",\(underlayConfiguration)
                "syncPeriodSeconds": 5
            }

            """
    }

    public static func kubeProxyConfiguration(
        nodeName: String,
        dualStackEnabled: Bool = false,
        masqueradeIPv6PodTraffic: Bool? = nil,
        ipv6EgressInterface: String? = nil,
        ipv6EgressSourceAddress: String? = nil
    ) -> String {
        let shouldMasqueradeIPv6PodTraffic = dualStackEnabled && (masqueradeIPv6PodTraffic ?? true)
        var ipv6EgressLines = [
            "            \"masqueradeIPv6PodTraffic\": \(shouldMasqueradeIPv6PodTraffic),"
        ]
        if let ipv6EgressInterface {
            ipv6EgressLines.append(
                "            \"ipv6EgressInterface\": \(jsonString(ipv6EgressInterface)),"
            )
        }
        if let ipv6EgressSourceAddress {
            ipv6EgressLines.append(
                "            \"ipv6EgressSourceAddress\": \(jsonString(ipv6EgressSourceAddress)),"
            )
        }
        let ipv6EgressConfiguration = ipv6EgressLines.joined(separator: "\n")

        return """
            {
                "kubeconfig": "/etc/kubernetes/kube-proxy.kubeconfig",
                "nodeName": "\(nodeName)",
                "syncPeriodSeconds": 5,
                "dualStackEnabled": \(dualStackEnabled),
                "pf": {
                    "anchorName": "com.apple.container.kube-proxy",
                    "configPath": "/etc/pf.conf",
                    "anchorsPath": "/etc/pf.anchors",
                    "pfctlPath": "/sbin/pfctl",
            \(ipv6EgressConfiguration)
                    "vmnetCIDR": "192.168.64.0/24",
                    "runtimeStatePath": "/var/lib/container/cri-shim-macos/pod-network.json",
                    "readyStatePath": "/var/lib/container/flannel-vxlan/ready.json"
                }
            }

            """
    }

    public static func runtimeClassManifest(networkMode: MacOSKubeadmNetworkMode = .full) -> String {
        runtimeClassManifest(
            profile: MacOSKubeadmRuntimeClassProfile(
                name: networkMode.runtimeClassName,
                handler: networkMode.runtimeHandler,
                sandboxImage: "",
                networkMode: networkMode
            ))
    }

    public static func runtimeClassManifest(profile: MacOSKubeadmRuntimeClassProfile) -> String {
        var lines = [
            "apiVersion: node.k8s.io/v1",
            "kind: RuntimeClass",
            "metadata:",
            "  name: \(profile.name)",
            "handler: \(profile.handler)",
            "scheduling:",
            "  nodeSelector:",
            "    kubernetes.io/os: darwin",
            "    node.kubernetes.io/macos: \"true\"",
            "    node.kubernetes.io/macos-network: \"\(profile.networkMode.nodeNetworkLabelValue)\"",
            "  tolerations:",
            "    - key: node.kubernetes.io/macos",
            "      operator: Equal",
            "      value: \"true\"",
            "      effect: NoSchedule",
        ]
        if profile.networkMode == .compat {
            lines.append(contentsOf: [
                "    - key: node.kubernetes.io/macos-network",
                "      operator: Equal",
                "      value: \"compat\"",
                "      effect: NoSchedule",
            ])
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func criShimPlist(containerServiceUserID: Int = 0) -> String {
        launchdPlist(
            label: "com.apple.container.cri-shim-macos",
            programArguments: [
                "/bin/launchctl",
                "asuser",
                "\(containerServiceUserID)",
                "/usr/local/bin/container-cri-shim-macos",
                "--config",
                "/etc/kubernetes/container-cri-shim-macos-config.json",
            ],
            logPath: "/var/log/container-cri-shim-macos.log"
        )
    }

    public static func containerSystemBootstrapPlist(containerServiceUserID: Int) -> String {
        launchdPlist(
            label: MacOSKubeadmContainerSystem.bootstrapLaunchdLabel,
            programArguments: [
                "/usr/local/bin/container-macos-kubeadm",
                "start-container-system",
                "--container-service-user",
                "\(containerServiceUserID)",
            ],
            logPath: "/var/log/container-macos-node-bootstrap.log",
            keepAlive: .unsuccessfulExit,
            throttleInterval: 10
        )
    }

    public static func kubeProxyPlist() -> String {
        launchdPlist(
            label: "com.apple.container.kube-proxy-macos",
            programArguments: [
                "/usr/local/bin/container-kube-proxy-macos",
                "--config",
                "/etc/kubernetes/kube-proxy.conf",
            ],
            logPath: "/var/log/container-kube-proxy-macos.log"
        )
    }

    public static func flannelVXLANPlist(containerServiceUserID: Int = 0) -> String {
        launchdPlist(
            label: "com.apple.container.flannel-vxlan-macos",
            programArguments: [
                "/bin/launchctl",
                "asuser",
                "\(containerServiceUserID)",
                "/usr/local/bin/container-flannel-vxlan-macos",
                "--config",
                "/etc/kubernetes/flannel-vxlan-macos.conf",
            ],
            logPath: "/var/log/container-flannel-vxlan-macos.log"
        )
    }

    public static func kubeletPlist(
        nodeName: String,
        sandboxImage: String,
        networkMode: MacOSKubeadmNetworkMode = .full,
        nodeIPAddresses: [String] = []
    ) -> String {
        let nodeLabels = [
            "kubernetes.io/os=darwin",
            "node.kubernetes.io/macos=true",
            "node.kubernetes.io/macos-network=\(networkMode.nodeNetworkLabelValue)",
        ].joined(separator: ",")
        let nodeTaints: String
        switch networkMode {
        case .full:
            nodeTaints = "node.kubernetes.io/macos=true:NoSchedule"
        case .compat:
            nodeTaints = [
                "node.kubernetes.io/macos=true:NoSchedule",
                "node.kubernetes.io/macos-network=compat:NoSchedule",
            ].joined(separator: ",")
        }

        var programArguments = [
            "/usr/local/bin/kubelet",
            "--config",
            "/etc/kubernetes/kubelet-config.yaml",
            "--kubeconfig",
            "/etc/kubernetes/kubelet.conf",
            "--bootstrap-kubeconfig",
            "/etc/kubernetes/bootstrap-kubelet.kubeconfig",
            "--hostname-override",
            nodeName,
        ]
        if !nodeIPAddresses.isEmpty {
            programArguments.append(contentsOf: [
                "--node-ip",
                nodeIPAddresses.joined(separator: ","),
            ])
        }
        programArguments.append(contentsOf: [
            "--node-labels",
            nodeLabels,
            "--register-with-taints",
            nodeTaints,
            "--root-dir",
            "/var/lib/kubelet",
            "--pod-infra-container-image",
            sandboxImage,
        ])

        return launchdPlist(
            label: "com.apple.container.kubelet",
            programArguments: programArguments,
            logPath: "/var/log/kubelet.log"
        )
    }

    private static func launchdPlist(
        label: String,
        programArguments: [String],
        logPath: String,
        keepAlive: LaunchdKeepAlive = .always,
        throttleInterval: Int? = nil
    ) -> String {
        let arguments = programArguments.map { argument in
            "        <string>\(xmlEscape(argument))</string>"
        }.joined(separator: "\n")

        let keepAliveValue: String
        switch keepAlive {
        case .always:
            keepAliveValue = "    <true/>"
        case .unsuccessfulExit:
            keepAliveValue = """
                    <dict>
                        <key>SuccessfulExit</key>
                        <false/>
                    </dict>
                """
        }

        let throttleIntervalValue: String
        if let throttleInterval {
            throttleIntervalValue = """
                    <key>ThrottleInterval</key>
                    <integer>\(throttleInterval)</integer>
                """
        } else {
            throttleIntervalValue = ""
        }

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(xmlEscape(label))</string>
                <key>ProgramArguments</key>
                <array>
            \(arguments)
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
            \(keepAliveValue)
            \(throttleIntervalValue)
                <key>StandardOutPath</key>
                <string>\(xmlEscape(logPath))</string>
                <key>StandardErrorPath</key>
                <string>\(xmlEscape(logPath))</string>
            </dict>
            </plist>

            """
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
