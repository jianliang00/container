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

    @Test func statusIncludesContainerSystemBootstrapArtifacts() {
        #expect(
            MacOSKubeadmStatusRunner.inspectedFiles.contains(
                MacOSKubeadmContainerSystem.bootstrapLaunchdPlistPath
            ))
        #expect(
            MacOSKubeadmStatusRunner.launchdLabels.contains(
                MacOSKubeadmContainerSystem.bootstrapLaunchdLabel
            ))
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
        #expect(object["underlayInterface"] == nil)
    }

    @Test func fullModeConfigurationsDefaultDualStackOff() throws {
        let rendered = MacOSKubeadmRenderer.flannelVXLANConfiguration(nodeName: "macos-ci-1")

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        #expect(object["containerServiceUserID"] as? Int == 0)
        #expect(object["dualStackEnabled"] as? Bool == false)

        let criShim = MacOSKubeadmRenderer.criShimConfiguration(
            sandboxImage: "localhost/macos-sandbox:test"
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
