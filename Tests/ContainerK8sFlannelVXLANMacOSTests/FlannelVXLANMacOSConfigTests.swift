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
        #expect(config.statusPath == nil)
        #expect(config.vtepMACIPv6Path == "/var/lib/container/flannel-vxlan/vtep-mac-v6")
        #expect(
            config.hostIPv6GatewayOwnershipStatePath
                == "/var/lib/container/flannel-vxlan/host-ipv6-gateway-ownership.json"
        )
        #expect(
            config.forwardingOwnershipStatePath
                == "/var/lib/container/flannel-vxlan/forwarding-ownership.json"
        )
        #expect(config.withdrawalStatePaths.contains(config.forwardingOwnershipStatePath))
        #expect(!config.withdrawalStatePaths.contains(FlannelVXLANMacOSConfig.defaultStatusPath))
        #expect(
            FlannelVXLANMacOSConfig.defaultPersistentStatePaths.contains(
                "/var/lib/container/flannel-vxlan/forwarding-ownership.json"
            )
        )
        #expect(
            FlannelVXLANMacOSConfig.defaultPersistentStatePaths.contains(
                FlannelVXLANMacOSConfig.defaultStatusPath
            )
        )
        try config.validate()
    }

    @Test func explicitContainerServiceUserIDRoundTrips() throws {
        let original = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a",
            containerServiceUserID: 501,
            vtepMACPath: "/private/var/lib/container/flannel-vxlan/custom-vtep-mac",
            dualStackEnabled: true,
            statusPath: FlannelVXLANMacOSConfig.defaultStatusPath
        )

        let decoded = try JSONDecoder().decode(
            FlannelVXLANMacOSConfig.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded.containerServiceUserID == 501)
        #expect(decoded.dualStackEnabled)
        #expect(decoded.statusPath == FlannelVXLANMacOSConfig.defaultStatusPath)
        #expect(!decoded.withdrawalStatePaths.contains(FlannelVXLANMacOSConfig.defaultStatusPath))
        #expect(decoded.managedStatePaths.statusPath == FlannelVXLANMacOSConfig.defaultStatusPath)
        #expect(decoded.managedStatePaths.all.contains(FlannelVXLANMacOSConfig.defaultStatusPath))
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

    @Test func dualStackRejectsSyncPeriodLongerThanFirstPodActivationBudget() {
        let config = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a",
            dualStackEnabled: true,
            syncPeriodSeconds: 6
        )

        #expect(throws: FlannelVXLANError.self) {
            try config.validate()
        }
    }

    @Test func rejectsPersistentStatePathCollisions() throws {
        let sharedCredentialPath = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/kubelet.conf",
            nodeKubeconfig: "/etc/kubernetes/kubelet.conf",
            nodeName: "mac-a"
        )
        try sharedCredentialPath.validate()

        var ownershipCollision = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a"
        )
        ownershipCollision.ownershipStatePath = "/var/lib/container/flannel-vxlan/forwarding-ownership.json"
        #expect(throws: FlannelVXLANError.self) {
            try ownershipCollision.validate()
        }

        var readyCollision = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a"
        )
        readyCollision.readyStatePath = readyCollision.networkOwnershipStatePath
        #expect(throws: FlannelVXLANError.self) {
            try readyCollision.validate()
        }

        var vtepCollision = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a"
        )
        vtepCollision.vtepMACPath = "/var/lib/container/flannel-vxlan/vtep-mac-v6"
        #expect(throws: FlannelVXLANError.self) {
            try vtepCollision.validate()
        }

        var kubeconfigCollision = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a"
        )
        kubeconfigCollision.ownershipStatePath = kubeconfigCollision.kubeconfig
        #expect(throws: FlannelVXLANError.self) {
            try kubeconfigCollision.validate()
        }

        var manifestCollision = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a"
        )
        manifestCollision.ownershipStatePath = FlannelVXLANMacOSConfig.defaultStateManifestPath
        #expect(throws: FlannelVXLANError.self) {
            try manifestCollision.validate()
        }

        var ancestorCollision = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a"
        )
        ancestorCollision.readyStatePath = ancestorCollision.ownershipStatePath + "/ready.json"
        #expect(throws: FlannelVXLANError.self) {
            try ancestorCollision.validate()
        }

        let configPathCollision = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a"
        )
        #expect(throws: FlannelVXLANError.self) {
            try configPathCollision.validateConfigurationFilePath(
                configPathCollision.forwardingOwnershipStatePath
            )
        }

        #expect(throws: FlannelVXLANError.self) {
            try configPathCollision.validateControlSocketPath(
                configPathCollision.forwardingOwnershipStatePath,
                configurationFilePath: "/etc/container/flannel-vxlan.json"
            )
        }
        #expect(throws: FlannelVXLANError.self) {
            try configPathCollision.validateControlSocketPath(
                "/etc/container/flannel-vxlan.json",
                configurationFilePath: "/etc/container/flannel-vxlan.json"
            )
        }
        #expect(throws: FlannelVXLANError.self) {
            try configPathCollision.validateControlSocketPath(
                "relative.sock",
                configurationFilePath: "/etc/container/flannel-vxlan.json"
            )
        }

        for lockPath in [
            FlannelVXLANMacOSConfig.defaultDaemonLifetimeLockPath,
            FlannelVXLANMacOSConfig.defaultForwardingAdvisoryLockPath,
        ] {
            var lockCollision = configPathCollision
            lockCollision.ownershipStatePath = lockPath
            #expect(throws: FlannelVXLANError.self) {
                try lockCollision.validate()
            }
        }

        var statusCollision = configPathCollision
        statusCollision.statusPath = FlannelVXLANMacOSConfig.defaultStatusPath
        statusCollision.ownershipStatePath = FlannelVXLANMacOSConfig.defaultStatusPath
        #expect(throws: FlannelVXLANError.self) {
            try statusCollision.validate()
        }
    }

    @Test func statusPathMustUseTheFixedLocation() {
        var config = FlannelVXLANMacOSConfig(
            kubeconfig: "/etc/kubernetes/flannel.kubeconfig",
            nodeName: "mac-a"
        )
        config.statusPath = "/var/lib/container/flannel-vxlan/other-status.json"

        #expect(
            throws: FlannelVXLANError.invalidConfiguration(
                "statusPath must be \(FlannelVXLANMacOSConfig.defaultStatusPath)"
            )
        ) {
            try config.validate()
        }
    }
}
