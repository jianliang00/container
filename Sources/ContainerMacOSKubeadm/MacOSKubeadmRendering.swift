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
    public static func kubeconfig(
        clusterName: String,
        contextName: String,
        userName: String,
        server: URL,
        certificateAuthorityPath: String,
        token: String
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
            token: \(token)
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
        address: "127.0.0.1"
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
        localStorageCapacityIsolation: false
        makeIPTablesUtilChains: false
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
        networkMode: MacOSKubeadmNetworkMode = .full
    ) -> String {
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
                        "sandboxImage": "\(sandboxImage)",
                        "workloadPlatform": {
                            "os": "darwin",
                            "architecture": "arm64"
                        },
                        "network": "default",
                        "networkBackend": "vmnetShared",
                        "guiEnabled": false
                    },
                    "runtimeHandlers": {
                        "macos": {
                            "sandboxImage": "\(sandboxImage)",
                            "network": "default",
                            "networkBackend": "vmnetShared",
                            "guiEnabled": false
                        }
                    },
                    "networkPolicy": {
                        "enabled": false
                    },
                    "kubeProxy": {
                        "enabled": true,
                        "configPath": "/etc/kubernetes/kube-proxy.conf"
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
                        "sandboxImage": "\(sandboxImage)",
                        "workloadPlatform": {
                            "os": "darwin",
                            "architecture": "arm64"
                        },
                        "network": "default",
                        "networkBackend": "virtualizationNAT",
                        "guiEnabled": false
                    },
                    "runtimeHandlers": {
                        "macos-compat": {
                            "sandboxImage": "\(sandboxImage)",
                            "network": "default",
                            "networkBackend": "virtualizationNAT",
                            "guiEnabled": false
                        }
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

    public static func cniConfiguration() -> String {
        """
        {
            "cniVersion": "1.1.0",
            "name": "default",
            "plugins": [
                {
                    "type": "macvmnet",
                    "network": "default",
                    "runtime": "container-runtime-macos",
                    "stateDir": "/var/lib/container/cni/macvmnet"
                }
            ]
        }

        """
    }

    public static func kubeProxyConfiguration(nodeName: String) -> String {
        """
        {
            "kubeconfig": "/etc/kubernetes/kube-proxy.kubeconfig",
            "nodeName": "\(nodeName)",
            "syncPeriodSeconds": 5,
            "pf": {
                "anchorName": "com.apple.container.kube-proxy",
                "configPath": "/etc/pf.conf",
                "anchorsPath": "/etc/pf.anchors",
                "pfctlPath": "/sbin/pfctl"
            }
        }

        """
    }

    public static func runtimeClassManifest(networkMode: MacOSKubeadmNetworkMode = .full) -> String {
        var lines = [
            "apiVersion: node.k8s.io/v1",
            "kind: RuntimeClass",
            "metadata:",
            "  name: \(networkMode.runtimeClassName)",
            "handler: \(networkMode.runtimeHandler)",
            "scheduling:",
            "  nodeSelector:",
            "    kubernetes.io/os: darwin",
            "    node.kubernetes.io/macos: \"true\"",
            "    node.kubernetes.io/macos-network: \"\(networkMode.nodeNetworkLabelValue)\"",
            "  tolerations:",
            "    - key: node.kubernetes.io/macos",
            "      operator: Equal",
            "      value: \"true\"",
            "      effect: NoSchedule",
        ]
        if networkMode == .compat {
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

    public static func kubeletPlist(
        nodeName: String,
        sandboxImage: String,
        networkMode: MacOSKubeadmNetworkMode = .full
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

        return launchdPlist(
            label: "com.apple.container.kubelet",
            programArguments: [
                "/usr/local/bin/kubelet",
                "--config",
                "/etc/kubernetes/kubelet-config.yaml",
                "--kubeconfig",
                "/etc/kubernetes/kubelet.kubeconfig",
                "--bootstrap-kubeconfig",
                "/etc/kubernetes/bootstrap-kubelet.kubeconfig",
                "--hostname-override",
                nodeName,
                "--node-labels",
                nodeLabels,
                "--register-with-taints",
                nodeTaints,
                "--root-dir",
                "/var/lib/kubelet",
                "--pod-infra-container-image",
                sandboxImage,
            ],
            logPath: "/var/log/kubelet.log"
        )
    }

    private static func launchdPlist(label: String, programArguments: [String], logPath: String) -> String {
        let arguments = programArguments.map { argument in
            "        <string>\(xmlEscape(argument))</string>"
        }.joined(separator: "\n")

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
                <true/>
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
