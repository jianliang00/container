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
        #expect(object["underlayInterface"] == nil)
    }

    @Test func flannelConfigurationDefaultsContainerServiceUserIDToRoot() throws {
        let rendered = MacOSKubeadmRenderer.flannelVXLANConfiguration(nodeName: "macos-ci-1")

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        #expect(object["containerServiceUserID"] as? Int == 0)
    }

    @Test func kubeProxyConfigurationUsesAutomaticEgressResolution() throws {
        let rendered = MacOSKubeadmRenderer.kubeProxyConfiguration(nodeName: "macos-ci-1")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let pf = try #require(object["pf"] as? [String: Any])

        #expect(pf["egressInterface"] == nil)
    }
}
