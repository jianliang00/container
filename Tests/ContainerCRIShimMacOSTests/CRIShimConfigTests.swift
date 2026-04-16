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
        #expect(config.streaming?.address == "127.0.0.1")
        #expect(config.streaming?.port == 0)
        #expect(config.cni?.binDir == "/opt/cni/bin")
        #expect(config.cni?.confDir == "/etc/cni/net.d")
        #expect(config.cni?.plugin == "macvmnet")
        #expect(config.defaults?.sandboxImage == "localhost/macos-sandbox:latest")
        #expect(config.defaults?.workloadPlatform?.os == "darwin")
        #expect(config.defaults?.workloadPlatform?.architecture == "arm64")
        #expect(config.runtimeHandlers["macos"]?.network == "default")
        #expect(config.networkPolicy?.enabled == true)
        #expect(config.kubeProxy?.enabled == true)
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
            streaming: StreamingConfig(address: " ", port: 70_000),
            cni: CNIConfig(binDir: nil, confDir: "relative", plugin: "nested/plugin"),
            defaults: RuntimeProfile(
                sandboxImage: "",
                workloadPlatform: WorkloadPlatform(os: "linux", architecture: ""),
                network: nil,
                guiEnabled: nil
            ),
            runtimeHandlers: [
                " ": RuntimeProfile(network: "")
            ],
            networkPolicy: NetworkPolicyConfig(enabled: true, kubeconfig: "kubelet.conf", nodeName: "", resyncSeconds: 0),
            kubeProxy: KubeProxyConfig(enabled: true, configPath: "kube-proxy.conf")
        )

        let issues = config.validationIssues
        #expect(issues.contains("runtimeEndpoint must be an absolute path"))
        #expect(issues.contains("streaming.address is required"))
        #expect(issues.contains("streaming.port must be between 0 and 65535"))
        #expect(issues.contains("cni.binDir is required"))
        #expect(issues.contains("cni.confDir must be an absolute path"))
        #expect(issues.contains("cni.plugin must be a plugin name, not a path"))
        #expect(issues.contains("defaults.sandboxImage is required"))
        #expect(issues.contains("defaults.workloadPlatform.os must be darwin"))
        #expect(issues.contains("defaults.workloadPlatform.architecture is required"))
        #expect(issues.contains("defaults.network is required"))
        #expect(issues.contains("defaults.guiEnabled is required"))
        #expect(issues.contains("runtimeHandlers contains an empty handler name"))
        #expect(issues.contains("runtimeHandlers. .network cannot be empty"))
        #expect(issues.contains("networkPolicy.kubeconfig must be an absolute path"))
        #expect(issues.contains("networkPolicy.nodeName is required"))
        #expect(issues.contains("networkPolicy.resyncSeconds must be greater than zero"))
        #expect(issues.contains("kubeProxy.configPath must be an absolute path"))
    }

    @Test
    func resolvesDefaultRuntimeHandlerForEmptyRequest() throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))

        let resolved = try config.resolveRuntimeHandler("")

        #expect(resolved.name == nil)
        #expect(resolved.sandboxImage == "localhost/macos-sandbox:latest")
        #expect(resolved.workloadPlatform == WorkloadPlatform(os: "darwin", architecture: "arm64"))
        #expect(resolved.network == "default")
        #expect(resolved.guiEnabled == false)
    }

    @Test
    func resolvesNamedRuntimeHandlerOverDefaults() throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigWithOverrideJSON.utf8))

        let resolved = try config.resolveRuntimeHandler("macos-gui")

        #expect(resolved.name == "macos-gui")
        #expect(resolved.sandboxImage == "localhost/macos-gui-sandbox:latest")
        #expect(resolved.workloadPlatform == WorkloadPlatform(os: "darwin", architecture: "arm64"))
        #expect(resolved.network == "gui")
        #expect(resolved.guiEnabled == true)
    }

    @Test
    func rejectsUnknownRuntimeHandler() throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))

        #expect(throws: RuntimeHandlerResolutionError.unknownRuntimeHandler("linux")) {
            try config.resolveRuntimeHandler("linux")
        }
    }
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
        "guiEnabled": false
      },
      "runtimeHandlers": {
        "macos": {
          "sandboxImage": "localhost/macos-sandbox:latest",
          "network": "default",
          "guiEnabled": false
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
        "guiEnabled": false
      },
      "runtimeHandlers": {
        "macos-gui": {
          "sandboxImage": "localhost/macos-gui-sandbox:latest",
          "network": "gui",
          "guiEnabled": true
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
