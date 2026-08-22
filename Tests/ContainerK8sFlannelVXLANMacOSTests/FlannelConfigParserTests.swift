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

import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelConfigParserTests {
    @Test
    func parsesWindowsCompatibleVXLANConfiguration() throws {
        let config = try FlannelConfigParser.parse(
            #"{"Network":"10.250.0.0/16","EnableIPv4":true,"Backend":{"Type":"vxlan","VNI":4096,"Port":4789,"MTU":1500}}"#
        )

        #expect(config.network == "10.250.0.0/16")
        #expect(config.enableIPv4)
        #expect(!config.enableIPv6)
        #expect(config.backend.vni == 4096)
        #expect(config.backend.port == 4789)
        #expect(config.backend.mtu == 1500)
        #expect(config.backend.isWindowsCompatible)
        #expect(try config.backend.innerMTU(underlayMTU: 9000) == 1450)
    }

    @Test
    func parsesConfigurationFromConfigMapKey() throws {
        let configMap = FlannelConfigMap(
            metadata: FlannelObjectMeta(namespace: "networking", name: "flannel"),
            data: [
                "cluster-network.json":
                    #"{"Network":"10.250.7.19/16","IPv6Network":"FD42:10:244:0:1234::/56","EnableIPv6":true,"Backend":{"VNI":4096,"Port":4789}}"#
            ]
        )

        let config = try FlannelConfigParser.parse(configMap: configMap, key: "cluster-network.json")

        #expect(config.network == "10.250.0.0/16")
        #expect(config.ipv6Network == "fd42:10:244::/56")
        #expect(config.enableIPv6)
        #expect(config.backend.type == "vxlan")
        #expect(config.backend.directRouting == false)
        #expect(config.backend.gbp == false)
        #expect(config.backend.learning == false)
    }

    @Test
    func acceptsOptionalIPv6NetworkWhenIPv6IsDisabled() throws {
        let config = try FlannelConfigParser.parse(
            #"{"Network":"10.250.0.0/16","IPv6Network":"fd42:10:244:12ff::1/56","Backend":{"VNI":4096,"Port":4789}}"#
        )

        #expect(!config.enableIPv6)
        #expect(config.ipv6Network == "fd42:10:244:1200::/56")
    }

    @Test
    func requiresValidIPv6NetworkWhenIPv6IsEnabled() {
        #expect(
            throws: FlannelVXLANError.invalidNetworkConfig(
                "IPv6Network is required when EnableIPv6 is true"
            )
        ) {
            try FlannelConfigParser.parse(
                #"{"Network":"10.250.0.0/16","EnableIPv6":true,"Backend":{"VNI":4096,"Port":4789}}"#
            )
        }

        #expect(throws: FlannelVXLANError.invalidNetworkConfig("IPv6Network must be a valid IPv6 CIDR")) {
            try FlannelConfigParser.parse(
                #"{"Network":"10.250.0.0/16","IPv6Network":"fd00::/129","EnableIPv6":true,"Backend":{"VNI":4096,"Port":4789}}"#
            )
        }
    }

    @Test
    func rejectsPlatformDependentVXLANDefaults() {
        #expect(throws: FlannelVXLANError.invalidNetworkConfig("Backend.VNI must be explicit for cross-platform VXLAN")) {
            try FlannelConfigParser.parse(
                #"{"Network":"10.250.0.0/16","Backend":{"Type":"vxlan","Port":4789}}"#
            )
        }

        #expect(throws: FlannelVXLANError.invalidNetworkConfig("Backend.Port must be explicit for cross-platform VXLAN")) {
            try FlannelConfigParser.parse(
                #"{"Network":"10.250.0.0/16","Backend":{"Type":"vxlan","VNI":4096}}"#
            )
        }
    }

    @Test
    func validatesWindowsRestrictionsSeparatelyFromGenericParsing() throws {
        let config = try FlannelConfigParser.parse(
            #"{"Network":"10.250.0.0/16","Backend":{"Type":"vxlan","VNI":4097,"Port":4789}}"#
        )

        #expect(!config.backend.isWindowsCompatible)
        #expect(throws: FlannelVXLANError.invalidNetworkConfig("Windows Flannel requires VNI 4096")) {
            try config.backend.validateWindowsCompatibility()
        }
    }

    @Test
    func rejectsMissingConfigMapData() {
        let configMap = FlannelConfigMap(
            metadata: FlannelObjectMeta(namespace: "kube-flannel", name: "kube-flannel-cfg")
        )

        #expect(
            throws: FlannelVXLANError.invalidNetworkConfig(
                "ConfigMap kube-flannel/kube-flannel-cfg does not contain net-conf.json"
            )
        ) {
            try FlannelConfigParser.parse(configMap: configMap)
        }
    }
}
