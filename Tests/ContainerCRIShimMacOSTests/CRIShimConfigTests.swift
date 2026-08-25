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

@testable import ContainerCRIShimMacOS

struct CRIShimConfigTests {
    @Test
    func decodesDocumentedConfigShape() throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))

        #expect(config.runtimeEndpoint == "/var/run/container-cri-macos.sock")
        #expect(config.stateDirectory == nil)
        #expect(config.normalizedStateDirectory == CRIShimConfigDefaults.stateDirectoryURL.path)
        #expect(config.streaming?.address == "127.0.0.1")
        #expect(config.streaming?.port == 0)
        #expect(config.cni?.binDir == "/opt/cni/bin")
        #expect(config.cni?.confDir == "/etc/cni/net.d")
        #expect(config.cni?.plugin == "macvmnet")
        #expect(config.defaults?.sandboxImage == "localhost/macos-sandbox:latest")
        #expect(config.defaults?.workloadPlatform?.os == "darwin")
        #expect(config.defaults?.workloadPlatform?.architecture == "arm64")
        #expect(config.defaults?.networkBackend == "vmnetShared")
        #expect(config.defaults?.networkMTU == 1_450)
        #expect(config.defaults?.resources?.cpus == 4)
        #expect(config.defaults?.resources?.memoryInBytes == RuntimeResources.defaultMacOSMemoryInBytes)
        #expect(config.runtimeHandlers["macos"]?.network == "default")
        #expect(config.runtimeHandlers["macos"]?.networkBackend == "vmnetShared")
        #expect(config.runtimeHandlers["macos"]?.networkMTU == nil)
        #expect(config.runtimeHandlers["macos"]?.resources?.memoryInBytes == 17_179_869_184)
        #expect(config.networkPolicy?.enabled == true)
        #expect(config.kubeProxy?.enabled == true)
        #expect(config.podNetwork?.enabled == true)
        #expect(config.podNetwork?.dualStackEnabled == false)
        #expect(config.podNetwork?.vmnetDisconnectRecovery == .disabled)
        #expect(config.podNetwork?.networkName == "kubernetes-pods")
        #expect(config.podNetwork?.runtimeStatePath == "/var/lib/container/pod-network/runtime.json")
        #expect(config.podNetwork?.readyStatePath == "/var/lib/container/pod-network/ready.json")
    }

    @Test
    func podNetworkDualStackGateDefaultsOffAndDecodesExplicitTrue() throws {
        let defaultConfig = try JSONDecoder().decode(
            PodNetworkConfig.self,
            from: Data(#"{"enabled":true}"#.utf8)
        )
        #expect(!defaultConfig.dualStackEnabled)

        let enabledConfig = try JSONDecoder().decode(
            PodNetworkConfig.self,
            from: Data(#"{"enabled":true,"dualStackEnabled":true}"#.utf8)
        )
        #expect(enabledConfig.dualStackEnabled)
    }

    @Test
    func podNetworkVMNetDisconnectRecoveryDefaultsOffAndDecodesStopSandbox() throws {
        let defaultConfig = try JSONDecoder().decode(
            PodNetworkConfig.self,
            from: Data(#"{"enabled":true}"#.utf8)
        )
        #expect(defaultConfig.vmnetDisconnectRecovery == .disabled)

        let enabledConfig = try JSONDecoder().decode(
            PodNetworkConfig.self,
            from: Data(#"{"enabled":true,"vmnetDisconnectRecovery":"stop-sandbox"}"#.utf8)
        )
        #expect(enabledConfig.vmnetDisconnectRecovery == .stopSandbox)
    }

    @Test
    func podNetworkRebootRecoveryDecodesDefaultsAndResolvesStatePath() throws {
        let podNetwork = try JSONDecoder().decode(
            PodNetworkConfig.self,
            from: Data(
                #"{"enabled":true,"vmnetDisconnectRecovery":"reboot-node","networkName":"kubernetes-pod","vmnetRecovery":{}}"#.utf8
            )
        )
        let config = CRIShimConfig(
            stateDirectory: "/var/lib/example-state",
            podNetwork: podNetwork
        )
        let recovery = config.resolvedVMNetRecoveryConfig

        #expect(podNetwork.vmnetDisconnectRecovery == .rebootNode)
        #expect(recovery.nodeName == nil)
        #expect(recovery.statePath == "/var/lib/container/vmnet-recovery/state.json")
        #expect(recovery.requestPath == "/var/lib/container/vmnet-recovery/requests/fence.json")
        #expect(recovery.statusPath == nil)
        #expect(recovery.requestWriterUID == 0)
        #expect(recovery.maxRebootAttempts == 2)
        #expect(recovery.minimumRebootIntervalSeconds == 120)
        #expect(recovery.attemptWindowSeconds == 3600)
        #expect(recovery.maximumRequestAgeSeconds == 900)
        #expect(recovery.verificationTimeoutSeconds == 300)
        #expect(recovery.pollIntervalSeconds == 2)
        #expect(recovery.healthyProbeFailureThreshold == 3)
    }

    @Test
    func rebootRecoveryValidationRejectsUnsafeBounds() throws {
        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.podNetwork?.vmnetDisconnectRecovery = .rebootNode
        config.podNetwork?.vmnetRecovery = VMNetRecoveryConfig(
            nodeName: "invalid node",
            statePath: "relative-state.json",
            requestPath: "relative-request.json",
            statusPath: "/tmp/recovery-status.json",
            requestWriterUID: -1,
            maxRebootAttempts: 0,
            minimumRebootIntervalSeconds: -1,
            attemptWindowSeconds: 0,
            maximumRequestAgeSeconds: 0,
            verificationTimeoutSeconds: 0,
            pollIntervalSeconds: 0,
            healthyProbeFailureThreshold: 0
        )

        let issues = config.validationIssues
        #expect(issues.contains("podNetwork.vmnetRecovery.statePath must be an absolute path"))
        #expect(issues.contains("podNetwork.vmnetRecovery.requestPath must be an absolute path"))
        #expect(
            issues.contains(
                "podNetwork.vmnetRecovery.statusPath must be /var/lib/container/vmnet-recovery/status.json"
            )
        )
        #expect(
            issues.contains(
                "podNetwork.vmnetRecovery.nodeName may only contain letters, numbers, '.', '_', and '-', and must start with a letter or number"
            )
        )
        #expect(issues.contains("podNetwork.vmnetRecovery.requestWriterUID must be a valid uid"))
        #expect(issues.contains("podNetwork.vmnetRecovery.maxRebootAttempts must be greater than zero"))
        #expect(issues.contains("podNetwork.vmnetRecovery.minimumRebootIntervalSeconds must not be negative"))
        #expect(issues.contains("podNetwork.vmnetRecovery.attemptWindowSeconds must be greater than zero"))
        #expect(issues.contains("podNetwork.vmnetRecovery.maximumRequestAgeSeconds must be greater than zero"))
        #expect(issues.contains("podNetwork.vmnetRecovery.verificationTimeoutSeconds must be greater than zero"))
        #expect(issues.contains("podNetwork.vmnetRecovery.pollIntervalSeconds must be greater than zero"))
        #expect(issues.contains("podNetwork.vmnetRecovery.healthyProbeFailureThreshold must be greater than zero"))
    }

    @Test
    func rebootRecoveryStatusRequiresNodeIdentity() throws {
        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.podNetwork?.vmnetDisconnectRecovery = .rebootNode
        config.podNetwork?.vmnetRecovery = VMNetRecoveryConfig(
            statusPath: CRIShimConfigDefaults.vmnetRecoveryStatusURL.path
        )

        #expect(
            config.validationIssues.contains(
                "podNetwork.vmnetRecovery.nodeName is required when statusPath is configured"
            )
        )

        config.podNetwork?.vmnetRecovery?.nodeName = "macos-node-1"
        #expect(config.validationIssues.isEmpty)
    }

    @Test
    func configuredRecoveryStatusIsValidatedWhileRecoveryIsDisabled() throws {
        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.podNetwork?.vmnetRecovery = VMNetRecoveryConfig(
            nodeName: "invalid node",
            statusPath: "/tmp/recovery-status.json"
        )

        #expect(
            config.validationIssues.contains(
                "podNetwork.vmnetRecovery.statusPath must be /var/lib/container/vmnet-recovery/status.json"
            )
        )
        #expect(
            config.validationIssues.contains(
                "podNetwork.vmnetRecovery.nodeName may only contain letters, numbers, '.', '_', and '-', and must start with a letter or number"
            )
        )
    }

    @Test
    func recoveryStatusPathCannotOverlapAuthorityFiles() throws {
        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.podNetwork?.vmnetDisconnectRecovery = .rebootNode
        config.podNetwork?.vmnetRecovery = VMNetRecoveryConfig(
            nodeName: "macos-node-1",
            statePath: CRIShimConfigDefaults.vmnetRecoveryStatusURL.path,
            requestPath: CRIShimConfigDefaults.vmnetRecoveryStatusURL.path,
            statusPath: CRIShimConfigDefaults.vmnetRecoveryStatusURL.path
        )

        let issues = config.validationIssues
        #expect(issues.contains("podNetwork.vmnetRecovery statusPath and statePath must be different"))
        #expect(issues.contains("podNetwork.vmnetRecovery statusPath and requestPath must be different"))
    }

    @Test
    func recoveryStatusPathRejectsSurroundingWhitespace() throws {
        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.podNetwork?.vmnetRecovery = VMNetRecoveryConfig(
            nodeName: "macos-node-1",
            statusPath: " \(CRIShimConfigDefaults.vmnetRecoveryStatusURL.path) "
        )

        #expect(
            config.validationIssues.contains(
                "podNetwork.vmnetRecovery.statusPath must be /var/lib/container/vmnet-recovery/status.json"
            )
        )
    }

    @Test
    func rebootRecoveryRequiresEnabledPodNetworking() throws {
        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.podNetwork?.enabled = false
        config.podNetwork?.vmnetDisconnectRecovery = .rebootNode

        #expect(
            config.validationIssues.contains(
                "podNetwork.vmnetDisconnectRecovery reboot-node requires podNetwork.enabled true"
            )
        )
    }

    @Test
    func disabledRecoveryIgnoresUnusedRecoveryTuning() throws {
        var config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        config.podNetwork?.vmnetRecovery = VMNetRecoveryConfig(
            statePath: "relative-state.json",
            maxRebootAttempts: 0,
            minimumRebootIntervalSeconds: -1,
            attemptWindowSeconds: 0,
            maximumRequestAgeSeconds: 0,
            verificationTimeoutSeconds: 0,
            pollIntervalSeconds: 0,
            healthyProbeFailureThreshold: 0
        )

        #expect(config.validationIssues.isEmpty)
    }

    @Test
    func validDocumentedConfigHasNoValidationIssues() throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        #expect(config.validationIssues.isEmpty)
        try config.validate()
    }

    @Test
    func validationReportsMissingRequiredSectionsAndInvalidValues() throws {
        let config = CRIShimConfig(
            runtimeEndpoint: "relative.sock",
            stateDirectory: "relative-state",
            streaming: StreamingConfig(address: " ", port: 70_000),
            cni: CNIConfig(binDir: nil, confDir: "relative", plugin: "nested/plugin"),
            defaults: RuntimeProfile(
                sandboxImage: "",
                workloadPlatform: WorkloadPlatform(os: "linux", architecture: ""),
                network: nil,
                networkBackend: "invalid",
                networkMTU: 575,
                guiEnabled: nil,
                resources: RuntimeResources(cpus: 0, memoryInBytes: 0)
            ),
            runtimeHandlers: [
                " ": RuntimeProfile(network: "", networkBackend: "", networkMTU: 9_001, resources: RuntimeResources(cpus: -1))
            ],
            networkPolicy: NetworkPolicyConfig(enabled: true, kubeconfig: "kubelet.conf", nodeName: "", resyncSeconds: 0),
            kubeProxy: KubeProxyConfig(enabled: true, configPath: "kube-proxy.conf"),
            podNetwork: PodNetworkConfig(
                enabled: true,
                networkName: " ",
                runtimeStatePath: "runtime.json",
                readyStatePath: "ready.json"
            )
        )

        let issues = config.validationIssues
        #expect(issues.contains("runtimeEndpoint must be an absolute path"))
        #expect(issues.contains("stateDirectory must be an absolute path"))
        #expect(issues.contains("streaming.address is required"))
        #expect(issues.contains("streaming.port must be between 0 and 65535"))
        #expect(issues.contains("cni.binDir is required"))
        #expect(issues.contains("cni.confDir must be an absolute path"))
        #expect(issues.contains("cni.plugin must be a plugin name, not a path"))
        #expect(issues.contains("defaults.sandboxImage is required"))
        #expect(issues.contains("defaults.workloadPlatform.os must be darwin"))
        #expect(issues.contains("defaults.workloadPlatform.architecture is required"))
        #expect(issues.contains("defaults.network is required"))
        #expect(issues.contains("defaults.networkBackend must be virtualizationNAT or vmnetShared"))
        #expect(issues.contains("defaults.networkMTU must be between 576 and 9000"))
        #expect(issues.contains("defaults.guiEnabled is required"))
        #expect(issues.contains("defaults.resources.cpus must be greater than zero"))
        #expect(issues.contains("defaults.resources.memoryInBytes must be greater than zero"))
        #expect(issues.contains("runtimeHandlers contains an empty handler name"))
        #expect(issues.contains("runtimeHandlers. .network cannot be empty"))
        #expect(issues.contains("runtimeHandlers. .networkMTU must be between 576 and 9000"))
        #expect(issues.contains("runtimeHandlers. .resources.cpus must be greater than zero"))
        #expect(issues.contains("networkPolicy.kubeconfig must be an absolute path"))
        #expect(issues.contains("networkPolicy.nodeName is required"))
        #expect(issues.contains("networkPolicy.resyncSeconds must be greater than zero"))
        #expect(issues.contains("kubeProxy.configPath must be an absolute path"))
        #expect(issues.contains("podNetwork.networkName is required"))
        #expect(issues.contains("podNetwork.runtimeStatePath must be an absolute path"))
        #expect(issues.contains("podNetwork.readyStatePath must be an absolute path"))
    }

    @Test
    func resolvesDefaultRuntimeHandlerForEmptyRequest() throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))

        let resolved = try config.resolveRuntimeHandler("")

        #expect(resolved.name == nil)
        #expect(resolved.sandboxImage == "localhost/macos-sandbox:latest")
        #expect(resolved.workloadPlatform == WorkloadPlatform(os: "darwin", architecture: "arm64"))
        #expect(resolved.network == "default")
        #expect(resolved.networkBackend == "vmnetShared")
        #expect(resolved.networkMTU == 1_450)
        #expect(resolved.guiEnabled == false)
        #expect(resolved.resources == RuntimeResources(cpus: 4, memoryInBytes: RuntimeResources.defaultMacOSMemoryInBytes))
    }

    @Test
    func resolvesNamedRuntimeHandlerOverDefaults() throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigWithOverrideJSON.utf8))

        let resolved = try config.resolveRuntimeHandler("macos-gui")

        #expect(resolved.name == "macos-gui")
        #expect(resolved.sandboxImage == "localhost/macos-gui-sandbox:latest")
        #expect(resolved.workloadPlatform == WorkloadPlatform(os: "darwin", architecture: "arm64"))
        #expect(resolved.network == "gui")
        #expect(resolved.networkBackend == "vmnetShared")
        #expect(resolved.networkMTU == 1_400)
        #expect(resolved.guiEnabled == true)
        #expect(resolved.resources == RuntimeResources(cpus: 8, memoryInBytes: RuntimeResources.defaultMacOSMemoryInBytes))
    }

    @Test
    func rejectsUnknownRuntimeHandler() throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))

        #expect(throws: RuntimeHandlerResolutionError.unknownRuntimeHandler("linux")) {
            try config.resolveRuntimeHandler("linux")
        }
    }

    @Test
    func decodesLegacyRuntimeProfileWithoutNetworkMTU() throws {
        let profile = try JSONDecoder().decode(
            RuntimeProfile.self,
            from: Data(#"{"network":"default","networkBackend":"vmnetShared"}"#.utf8)
        )

        #expect(profile.networkMTU == nil)
    }

    @Test
    func loadsFirstExistingConfigFromSearchPath() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let missingURL = rootURL.appendingPathComponent("missing.json")
        let configURL = rootURL.appendingPathComponent("config.json")
        try Data(validConfigJSON.utf8).write(to: configURL)

        let result = try CRIShimConfig.loadFromSearchPath([missingURL, configURL])
        #expect(result.sourceURL == configURL)
        #expect(result.config.runtimeEndpoint == "/var/run/container-cri-macos.sock")
    }

    @Test
    func reportsSearchedPathsWhenConfigSearchMisses() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let missingURL = rootURL.appendingPathComponent("missing.json")
        #expect(throws: CRIShimConfigLoadError(searchedPaths: [missingURL.path])) {
            _ = try CRIShimConfig.loadFromSearchPath([missingURL])
        }
    }

    @Test
    func rejectsKubernetesIntegrationWithoutVmnetShared() {
        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            cni: CNIConfig(binDir: "/opt/cni/bin", confDir: "/etc/cni/net.d", plugin: "macvmnet"),
            defaults: RuntimeProfile(
                sandboxImage: "localhost/macos-sandbox:latest",
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "virtualizationNAT",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos": RuntimeProfile(networkBackend: "virtualizationNAT")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: true, kubeconfig: "/etc/kubernetes/kubelet.conf", nodeName: "node-a", resyncSeconds: 30),
            kubeProxy: KubeProxyConfig(enabled: true, configPath: "/etc/kubernetes/kube-proxy.conf")
        )

        #expect(
            config.validationIssues.contains(
                "defaults.networkBackend must be vmnetShared when networkPolicy or kubeProxy is enabled"
            ))
        #expect(
            config.validationIssues.contains(
                "runtimeHandlers.macos.networkBackend must be vmnetShared when networkPolicy or kubeProxy is enabled"
            ))
    }

    @Test
    func natOnlyConfigDoesNotRequireCNI() throws {
        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            defaults: RuntimeProfile(
                sandboxImage: "localhost/macos-sandbox:latest",
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "virtualizationNAT",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos-compat": RuntimeProfile(networkBackend: "virtualizationNAT")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: false),
            kubeProxy: KubeProxyConfig(enabled: false)
        )

        #expect(config.requiresCNI == false)
        #expect(!config.validationIssues.contains("cni is required"))
        try config.validate()
    }

    @Test
    func vmnetSharedConfigRequiresCNI() {
        let config = CRIShimConfig(
            runtimeEndpoint: "/var/run/container-cri-macos.sock",
            streaming: StreamingConfig(address: "127.0.0.1", port: 0),
            defaults: RuntimeProfile(
                sandboxImage: "localhost/macos-sandbox:latest",
                workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
                network: "default",
                networkBackend: "vmnetShared",
                guiEnabled: false
            ),
            runtimeHandlers: [
                "macos": RuntimeProfile(networkBackend: "vmnetShared")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: false),
            kubeProxy: KubeProxyConfig(enabled: false)
        )

        #expect(config.requiresCNI)
        #expect(config.validationIssues.contains("cni is required"))
    }
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CRIShimConfigTests-\(UUID().uuidString)", isDirectory: true)
}

private let validConfigJSON = """
    {
      "runtimeEndpoint": "/var/run/container-cri-macos.sock",
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
        "sandboxImage": "localhost/macos-sandbox:latest",
        "workloadPlatform": {
          "os": "darwin",
          "architecture": "arm64"
        },
        "network": "default",
        "networkBackend": "vmnetShared",
        "networkMTU": 1450,
        "guiEnabled": false,
        "resources": {
          "cpus": 4,
          "memoryInBytes": 8589934592
        }
      },
      "runtimeHandlers": {
        "macos": {
          "sandboxImage": "localhost/macos-sandbox:latest",
          "network": "default",
          "networkBackend": "vmnetShared",
          "guiEnabled": false,
          "resources": {
            "memoryInBytes": 17179869184
          }
        }
      },
      "networkPolicy": {
        "enabled": true,
        "kubeconfig": "/etc/kubernetes/kubelet.conf",
        "nodeName": "macos-node-1",
        "resyncSeconds": 30
      },
      "kubeProxy": {
        "enabled": true,
        "configPath": "/etc/kubernetes/kube-proxy.conf"
      },
      "podNetwork": {
        "enabled": true,
        "networkName": "kubernetes-pods",
        "runtimeStatePath": "/var/lib/container/pod-network/runtime.json",
        "readyStatePath": "/var/lib/container/pod-network/ready.json"
      }
    }
    """

private let validConfigWithOverrideJSON = """
    {
      "runtimeEndpoint": "unix:///var/run/container-cri-macos.sock",
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
        "sandboxImage": "localhost/macos-sandbox:latest",
        "workloadPlatform": {
          "os": "darwin",
          "architecture": "arm64"
        },
        "network": "default",
        "networkBackend": "vmnetShared",
        "networkMTU": 1450,
        "guiEnabled": false,
        "resources": {
          "cpus": 4,
          "memoryInBytes": 8589934592
        }
      },
      "runtimeHandlers": {
        "macos-gui": {
          "sandboxImage": "localhost/macos-gui-sandbox:latest",
          "network": "gui",
          "networkBackend": "vmnetShared",
          "networkMTU": 1400,
          "guiEnabled": true,
          "resources": {
            "cpus": 8
          }
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
