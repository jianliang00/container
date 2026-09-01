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

struct MacOSKubeadmRenderingTests {
    @Test func containerSystemBootstrapPlistRetriesOnlyAfterFailure() throws {
        let rendered = MacOSKubeadmRenderer.containerSystemBootstrapPlist(
            containerServiceUserID: 501
        )
        let object = try #require(
            PropertyListSerialization.propertyList(
                from: Data(rendered.utf8),
                format: nil
            ) as? [String: Any]
        )
        let keepAlive = try #require(object["KeepAlive"] as? [String: Any])

        #expect(object["Label"] as? String == MacOSKubeadmContainerSystem.bootstrapLaunchdLabel)
        #expect(
            object["ProgramArguments"] as? [String] == [
                "/usr/local/bin/container-macos-kubeadm",
                "start-container-system",
                "--container-service-user",
                "501",
            ])
        #expect(object["RunAtLoad"] as? Bool == true)
        #expect(keepAlive["SuccessfulExit"] as? Bool == false)
        #expect(object["ThrottleInterval"] as? Int == 10)
        #expect(object["StandardOutPath"] as? String == "/var/log/container-macos-node-bootstrap.log")
        #expect(object["StandardErrorPath"] as? String == "/var/log/container-macos-node-bootstrap.log")
    }

    @Test func containerSystemOperationPlistIsAOneShotBackgroundAgent() throws {
        let rendered = MacOSKubeadmRenderer.containerSystemOperationPlist(
            label: "com.apple.container-macos-kubeadm.operation.501",
            containerServiceUserID: 501,
            userName: "service",
            homeDirectory: "/Users/service",
            operation: .stop,
            operationID: "request-1",
            completionPath: "/var/run/container-macos-kubeadm/request-1.completion.json"
        )
        let object = try #require(
            PropertyListSerialization.propertyList(
                from: Data(rendered.utf8),
                format: nil
            ) as? [String: Any]
        )

        #expect(object["LimitLoadToSessionType"] as? String == "Background")
        #expect(object["RunAtLoad"] as? Bool == true)
        #expect(object["KeepAlive"] == nil)
        #expect(object["StandardOutPath"] == nil)
        #expect(object["StandardErrorPath"] == nil)
        #expect(
            object["EnvironmentVariables"] as? [String: String] == [
                "HOME": "/Users/service",
                "LOGNAME": "service",
                "USER": "service",
            ])
        #expect(
            object["ProgramArguments"] as? [String] == [
                "/usr/local/bin/container-macos-kubeadm",
                "execute-container-system",
                "--container-service-user",
                "501",
                "--operation",
                "stop",
                "--operation-id",
                "request-1",
                "--completion-path",
                "/var/run/container-macos-kubeadm/request-1.completion.json",
                "--expected-session-type",
                "Background",
            ])
    }

    @Test func longRunningLaunchdServicesRemainAlwaysAlive() throws {
        let rendered = MacOSKubeadmRenderer.criShimPlist(containerServiceUserID: 501)
        let object = try #require(
            PropertyListSerialization.propertyList(
                from: Data(rendered.utf8),
                format: nil
            ) as? [String: Any]
        )

        #expect(object["KeepAlive"] as? Bool == true)
        #expect(object["ThrottleInterval"] == nil)
    }

    @Test func vmnetRecoveryPlistUsesContainerServiceBootstrapContext() throws {
        let rendered = MacOSKubeadmRenderer.vmnetRecoveryPlist(containerServiceUserID: 501)
        let object = try #require(
            PropertyListSerialization.propertyList(
                from: Data(rendered.utf8),
                format: nil
            ) as? [String: Any]
        )

        #expect(object["Label"] as? String == "com.apple.container.vmnet-recovery-macos")
        #expect(
            object["ProgramArguments"] as? [String] == [
                "/bin/launchctl",
                "asuser",
                "501",
                "/usr/local/bin/container-vmnet-recovery-macos",
                "--config",
                "/etc/kubernetes/container-cri-shim-macos-config.json",
            ])
        #expect(object["KeepAlive"] as? Bool == true)
        #expect(object["ThrottleInterval"] as? Int == 10)
    }

    @Test func statusIncludesContainerSystemBootstrapArtifacts() {
        #expect(
            MacOSKubeadmStatusRunner.inspectedFiles.contains(
                MacOSKubeadmContainerSystem.bootstrapLaunchdPlistPath
            ))
        #expect(
            MacOSKubeadmStatusRunner.launchdLabels.contains(
                MacOSKubeadmContainerSystem.bootstrapLaunchdLabel
            ))
        #expect(
            MacOSKubeadmStatusRunner.inspectedFiles.contains(
                "/var/lib/container/vmnet-recovery/state.json"
            ))
        #expect(
            MacOSKubeadmStatusRunner.inspectedFiles.contains(
                "/var/lib/container/vmnet-recovery/status.json"
            ))
        #expect(
            MacOSKubeadmStatusRunner.inspectedFiles.contains(
                "/var/lib/container/flannel-vxlan/status.json"
            ))
        #expect(
            MacOSKubeadmStatusRunner.launchdLabels.contains(
                "com.apple.container.vmnet-recovery-macos"
            ))
        #expect(
            MacOSKubeadmStatusRunner.inspectedFiles.contains(
                "/usr/local/bin/container-macos-node-status"
            ))
        #expect(
            MacOSKubeadmStatusRunner.inspectedFiles.contains(
                "/etc/kubernetes/container-macos-node-status.json"
            ))
    }

    @Test func nodeStatusConfigurationBindsTrustedIdentityAndExpectedComponents() throws {
        let enabled = MacOSKubeadmRenderer.nodeStatusConfiguration(
            nodeName: "macos-ci-1",
            expectVMNetRecovery: true
        )
        let enabledObject = try #require(
            JSONSerialization.jsonObject(with: Data(enabled.utf8)) as? [String: Any]
        )
        let enabledComponents = try #require(enabledObject["expectedComponents"] as? [String: Any])

        #expect(enabledObject["schemaVersion"] as? Int == 1)
        #expect(enabledObject["nodeName"] as? String == "macos-ci-1")
        #expect(enabledObject["networkName"] as? String == "kubernetes-pod")
        #expect(enabledComponents["kubeProxy"] as? Bool == true)
        #expect(enabledComponents["flannel"] as? Bool == true)
        #expect(enabledComponents["vmnetRecovery"] as? Bool == true)

        let disabled = MacOSKubeadmRenderer.nodeStatusConfiguration(
            nodeName: "macos-ci-1",
            expectVMNetRecovery: false
        )
        let disabledObject = try #require(
            JSONSerialization.jsonObject(with: Data(disabled.utf8)) as? [String: Any]
        )
        let disabledComponents = try #require(disabledObject["expectedComponents"] as? [String: Any])
        #expect(disabledComponents["vmnetRecovery"] as? Bool == false)
    }

    @Test func flannelConfigurationPersistsContainerServiceUserID() throws {
        let rendered = MacOSKubeadmRenderer.flannelVXLANConfiguration(
            nodeName: "macos-ci-1",
            containerServiceUserID: 501
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        #expect(object["nodeName"] as? String == "macos-ci-1")
        #expect(object["containerServiceUserID"] as? Int == 501)
        #expect(object["dualStackEnabled"] as? Bool == false)
        #expect(
            object["statusPath"] as? String
                == "/var/lib/container/flannel-vxlan/status.json"
        )
        #expect(object["underlayInterface"] == nil)
    }

    @Test func packagedFlannelStatusPathMatchesRenderedConfiguration() throws {
        let rendered = MacOSKubeadmRenderer.flannelVXLANConfiguration(nodeName: "macos-ci-1")
        let renderedObject = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packagedURL = repositoryRoot.appendingPathComponent(
            "packaging/macos-node/config/flannel-vxlan-macos.conf"
        )
        let packagedObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: packagedURL)) as? [String: Any]
        )

        #expect(packagedObject["statusPath"] as? String == renderedObject["statusPath"] as? String)
    }

    @Test func flannelConfigurationRendersExplicitNetworkSourceAndUnderlay() throws {
        let rendered = MacOSKubeadmRenderer.flannelVXLANConfiguration(
            nodeName: "macos-ci-1",
            dualStackEnabled: true,
            configMapNamespace: "kube-flannel-macos",
            configMapName: "kube-flannel-cfg-macos-ds-mac-canary-a",
            underlayInterface: "en0"
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        #expect(object["configMapNamespace"] as? String == "kube-flannel-macos")
        #expect(object["configMapName"] as? String == "kube-flannel-cfg-macos-ds-mac-canary-a")
        #expect(object["underlayInterface"] as? String == "en0")
    }

    @Test func CRIConfigurationCanEnableGUIForOneRuntimeClass() throws {
        let rendered = MacOSKubeadmRenderer.criShimConfiguration(
            sandboxImage: "localhost/macos-sandbox:test",
            nodeName: "macos-ci-1",
            runtimeClasses: [
                MacOSKubeadmRuntimeClassProfile(
                    name: "macos-gui",
                    sandboxImage: "localhost/macos-sandbox:gui",
                    networkMode: .full,
                    guiEnabled: true
                )
            ]
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let defaults = try #require(object["defaults"] as? [String: Any])
        let handlers = try #require(object["runtimeHandlers"] as? [String: Any])
        let defaultHandler = try #require(handlers["macos"] as? [String: Any])
        let guiHandler = try #require(handlers["macos-gui"] as? [String: Any])

        #expect(defaults["guiEnabled"] as? Bool == false)
        #expect(defaultHandler["guiEnabled"] as? Bool == false)
        #expect(guiHandler["guiEnabled"] as? Bool == true)
    }

    @Test func CRIConfigurationRendersVMNetDisconnectRecovery() throws {
        let rendered = MacOSKubeadmRenderer.criShimConfiguration(
            sandboxImage: "localhost/macos-sandbox:test",
            nodeName: "macos-ci-1",
            vmnetDisconnectRecovery: .stopSandbox
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let podNetwork = try #require(object["podNetwork"] as? [String: Any])

        #expect(podNetwork["vmnetDisconnectRecovery"] as? String == "stop-sandbox")
    }

    @Test func CRIConfigurationRendersMachineStateContractInEveryNetworkMode() throws {
        for networkMode in [MacOSKubeadmNetworkMode.full, .compat] {
            let rendered = MacOSKubeadmRenderer.criShimConfiguration(
                sandboxImage: "localhost/macos-sandbox:test",
                nodeName: "macos-ci-1",
                networkMode: networkMode
            )
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
            )
            let machineState = try #require(object["machineState"] as? [String: Any])

            #expect(machineState["enabled"] as? Bool == true)
            #expect(
                machineState["storageRoot"] as? String
                    == "/var/lib/container/cri-shim-macos/machine-state/v1"
            )
            #expect(
                machineState["controlSocketRoot"] as? String
                    == "/var/run/container/machine-state/v1"
            )
            #expect(machineState["nbdSocketAllowedRoots"] as? [String] == ["/var/run/container/nbd"])
        }
    }

    @Test func CRIConfigurationRendersBoundedRebootRecovery() throws {
        let rendered = MacOSKubeadmRenderer.criShimConfiguration(
            sandboxImage: "localhost/macos-sandbox:test",
            nodeName: "macos-ci-1",
            vmnetDisconnectRecovery: .rebootNode,
            containerServiceUserID: 501
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let podNetwork = try #require(object["podNetwork"] as? [String: Any])
        let recovery = try #require(podNetwork["vmnetRecovery"] as? [String: Any])

        #expect(podNetwork["vmnetDisconnectRecovery"] as? String == "reboot-node")
        #expect(recovery["nodeName"] as? String == "macos-ci-1")
        #expect(recovery["statePath"] as? String == "/var/lib/container/vmnet-recovery/state.json")
        #expect(recovery["requestPath"] as? String == "/var/lib/container/vmnet-recovery/requests/fence.json")
        #expect(recovery["statusPath"] as? String == "/var/lib/container/vmnet-recovery/status.json")
        #expect(recovery["requestWriterUID"] as? Int == 501)
        #expect(recovery["maxRebootAttempts"] as? Int == 2)
        #expect(recovery["minimumRebootIntervalSeconds"] as? Int == 120)
        #expect(recovery["attemptWindowSeconds"] as? Int == 3600)
        #expect(recovery["maximumRequestAgeSeconds"] as? Int == 900)
        #expect(recovery["verificationTimeoutSeconds"] as? Int == 300)
        #expect(recovery["pollIntervalSeconds"] as? Int == 2)
        #expect(recovery["healthyProbeFailureThreshold"] as? Int == 3)
    }

    @Test func packagedCRIConfigurationMatchesRenderer() throws {
        let rendered = MacOSKubeadmRenderer.criShimConfiguration(
            sandboxImage: "localhost/macos-sandbox:latest",
            nodeName: "__NODE_NAME__"
        )
        let renderedObject = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let renderedPodNetwork = try #require(renderedObject["podNetwork"] as? [String: Any])
        let renderedRecovery = try #require(renderedPodNetwork["vmnetRecovery"] as? NSDictionary)
        let renderedMachineState = try #require(renderedObject["machineState"] as? NSDictionary)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packagedURL = repositoryRoot.appendingPathComponent(
            "packaging/macos-node/config/container-cri-shim-macos-config.json"
        )
        let packagedObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: packagedURL)) as? [String: Any]
        )
        let packagedPodNetwork = try #require(packagedObject["podNetwork"] as? [String: Any])
        let packagedRecovery = try #require(packagedPodNetwork["vmnetRecovery"] as? NSDictionary)
        let packagedMachineState = try #require(packagedObject["machineState"] as? NSDictionary)

        #expect(packagedRecovery == renderedRecovery)
        #expect(packagedMachineState == renderedMachineState)
    }

    @Test func kubeletPlistRendersDualNodeIPsAsOneArgument() throws {
        let rendered = MacOSKubeadmRenderer.kubeletPlist(
            nodeName: "macos-ci-1",
            sandboxImage: "localhost/macos-sandbox:test",
            nodeIPAddresses: [
                "203.0.113.208",
                "2001:db8:100:c:203:0:113:208",
            ]
        )
        let object = try #require(
            PropertyListSerialization.propertyList(
                from: Data(rendered.utf8),
                format: nil
            ) as? [String: Any]
        )
        let arguments = try #require(object["ProgramArguments"] as? [String])
        let nodeIPIndex = try #require(arguments.firstIndex(of: "--node-ip"))

        #expect(arguments.filter { $0 == "--node-ip" }.count == 1)
        #expect(arguments[nodeIPIndex + 1] == "203.0.113.208,2001:db8:100:c:203:0:113:208")
    }

    @Test func kubeletPlistOmitsNodeIPByDefault() throws {
        let rendered = MacOSKubeadmRenderer.kubeletPlist(
            nodeName: "macos-ci-1",
            sandboxImage: "localhost/macos-sandbox:test"
        )
        let object = try #require(
            PropertyListSerialization.propertyList(
                from: Data(rendered.utf8),
                format: nil
            ) as? [String: Any]
        )
        let arguments = try #require(object["ProgramArguments"] as? [String])

        #expect(!arguments.contains("--node-ip"))
    }

    @Test func fullModeConfigurationsDefaultDualStackOff() throws {
        let rendered = MacOSKubeadmRenderer.flannelVXLANConfiguration(nodeName: "macos-ci-1")

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        #expect(object["containerServiceUserID"] as? Int == 0)
        #expect(object["dualStackEnabled"] as? Bool == false)

        let criShim = MacOSKubeadmRenderer.criShimConfiguration(
            sandboxImage: "localhost/macos-sandbox:test",
            nodeName: "macos-ci-1"
        )
        let criShimObject = try #require(
            JSONSerialization.jsonObject(with: Data(criShim.utf8)) as? [String: Any]
        )
        let podNetwork = try #require(criShimObject["podNetwork"] as? [String: Any])
        #expect(podNetwork["dualStackEnabled"] as? Bool == false)
    }

    @Test func fullModeConfigurationsRenderMatchingDualStackGate() throws {
        let criShim = MacOSKubeadmRenderer.criShimConfiguration(
            sandboxImage: "localhost/macos-sandbox:test",
            nodeName: "macos-ci-1",
            dualStackEnabled: true
        )
        let criShimObject = try #require(
            JSONSerialization.jsonObject(with: Data(criShim.utf8)) as? [String: Any]
        )
        let podNetwork = try #require(criShimObject["podNetwork"] as? [String: Any])

        let flannel = MacOSKubeadmRenderer.flannelVXLANConfiguration(
            nodeName: "macos-ci-1",
            dualStackEnabled: true
        )
        let flannelObject = try #require(
            JSONSerialization.jsonObject(with: Data(flannel.utf8)) as? [String: Any]
        )

        #expect(podNetwork["dualStackEnabled"] as? Bool == true)
        #expect(flannelObject["dualStackEnabled"] as? Bool == true)
    }

    @Test func compatCRIConfigurationKeepsPodNetworkingDisabled() throws {
        let rendered = MacOSKubeadmRenderer.criShimConfiguration(
            sandboxImage: "localhost/macos-sandbox:test",
            nodeName: "macos-ci-1",
            networkMode: .compat
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )

        #expect(object["podNetwork"] == nil)
        #expect(!rendered.contains("dualStackEnabled"))
    }

    @Test func kubeProxyConfigurationUsesAutomaticEgressResolution() throws {
        let rendered = MacOSKubeadmRenderer.kubeProxyConfiguration(nodeName: "macos-ci-1")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let pf = try #require(object["pf"] as? [String: Any])

        #expect(pf["egressInterface"] == nil)
        #expect(pf["ipv6EgressInterface"] == nil)
        #expect(pf["ipv6EgressSourceAddress"] == nil)
        #expect(pf["masqueradeIPv6PodTraffic"] as? Bool == false)
        #expect(object["dualStackEnabled"] as? Bool == false)
        #expect(object["statusPath"] as? String == "/var/lib/container/kube-proxy-macos/status.json")
    }

    @Test func kubeProxyConfigurationCanEnableDualStack() throws {
        let rendered = MacOSKubeadmRenderer.kubeProxyConfiguration(
            nodeName: "macos-ci-1",
            dualStackEnabled: true
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let pf = try #require(object["pf"] as? [String: Any])

        #expect(object["dualStackEnabled"] as? Bool == true)
        #expect(pf["masqueradeIPv6PodTraffic"] as? Bool == true)
        #expect(pf["ipv6EgressInterface"] == nil)
        #expect(pf["ipv6EgressSourceAddress"] == nil)
    }

    @Test func kubeProxyConfigurationCanUseExplicitIPv6NATSource() throws {
        let rendered = MacOSKubeadmRenderer.kubeProxyConfiguration(
            nodeName: "macos-ci-1",
            dualStackEnabled: true,
            masqueradeIPv6PodTraffic: true,
            ipv6EgressInterface: "en7",
            ipv6EgressSourceAddress: "2001:db8:100:c::7"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let pf = try #require(object["pf"] as? [String: Any])

        #expect(pf["masqueradeIPv6PodTraffic"] as? Bool == true)
        #expect(pf["ipv6EgressInterface"] as? String == "en7")
        #expect(pf["ipv6EgressSourceAddress"] as? String == "2001:db8:100:c::7")
    }

    @Test func kubeProxyConfigurationCanUseRoutedIPv6Egress() throws {
        let rendered = MacOSKubeadmRenderer.kubeProxyConfiguration(
            nodeName: "macos-ci-1",
            dualStackEnabled: true,
            masqueradeIPv6PodTraffic: false
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let pf = try #require(object["pf"] as? [String: Any])

        #expect(pf["masqueradeIPv6PodTraffic"] as? Bool == false)
        #expect(pf["ipv6EgressInterface"] == nil)
        #expect(pf["ipv6EgressSourceAddress"] == nil)
    }
}
