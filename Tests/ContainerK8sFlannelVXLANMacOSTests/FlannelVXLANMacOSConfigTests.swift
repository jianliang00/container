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

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelVXLANMacOSConfigTests {
    @Test func legacyConfigurationDefaultsContainerServiceUserIDToRoot() throws {
        let data = Data(
            #"{"kubeconfig":"/etc/kubernetes/flannel.kubeconfig","nodeName":"mac-a","syncPeriodSeconds":10}"#.utf8
        )

        let config = try JSONDecoder().decode(FlannelVXLANMacOSConfig.self, from: data)

        #expect(config.containerServiceUserID == 0)
        #expect(!config.dualStackEnabled)
        #expect(config.vtepMACIPv6Path == "/var/lib/container/flannel-vxlan/vtep-mac-v6")
        try config.validate()
    }

    @Test func explicitContainerServiceUserIDRoundTrips() throws {
        let original = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a",
            containerServiceUserID: 501,
            vtepMACPath: "/private/var/lib/container/flannel-vxlan/custom-vtep-mac",
            dualStackEnabled: true
        )

        let decoded = try JSONDecoder().decode(
            FlannelVXLANMacOSConfig.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded.containerServiceUserID == 501)
        #expect(decoded.dualStackEnabled)
        #expect(decoded.vtepMACIPv6Path == "/private/var/lib/container/flannel-vxlan/vtep-mac-v6")
        #expect(decoded == original)
        try decoded.validate()
    }

    @Test func negativeContainerServiceUserIDIsRejected() throws {
        let config = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a",
            containerServiceUserID: -1
        )

        #expect(
            throws: FlannelVXLANError.invalidConfiguration(
                "containerServiceUserID must be non-negative"
            )
        ) {
            try config.validate()
        }
    }
}
