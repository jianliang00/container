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

@testable import ContainerK8sKubeProxyMacOS

struct KubeProxyCompilerTests {
    @Test
    func compilesSingleNodeClusterIPServiceIntoPFRule() throws {
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a", generation: 3)

        #expect(ruleSet.generation == 3)
        #expect(ruleSet.issues.isEmpty)
        #expect(ruleSet.rules.count == 1)

        let rule = try #require(ruleSet.rules.first)
        #expect(rule.namespace == "default")
        #expect(rule.serviceName == "echo")
        #expect(rule.protocolName == .tcp)
        #expect(rule.clusterIP == "10.96.0.42")
        #expect(rule.servicePort == 80)
        #expect(
            rule.backends == [
                KubeProxyBackend(ip: "192.168.65.10", port: 8080),
                KubeProxyBackend(ip: "192.168.65.11", port: 8080),
            ])
    }

    @Test
    func compilesClusterIPForNodePortAndLoadBalancerServices() {
        for serviceType in ["NodePort", "LoadBalancer"] {
            let ruleSet = KubeProxyCompiler.compile(
                snapshot: makeSnapshot(serviceType: serviceType),
                nodeName: "node-a"
            )

            #expect(ruleSet.rules.count == 1, "missing ClusterIP rule for \(serviceType) Service")
            #expect(ruleSet.rules.first?.clusterIP == "10.96.0.42")
        }
    }

    @Test
    func skipsExternalNameServices() {
        let ruleSet = KubeProxyCompiler.compile(
            snapshot: makeSnapshot(serviceType: "ExternalName"),
            nodeName: "node-a"
        )

        #expect(ruleSet.rules.isEmpty)
    }

    @Test
    func defaultClusterTrafficPolicyIncludesReadyRemoteEndpoints() throws {
        let snapshot = makeSnapshot(
            endpoints: [
                KubeProxyEndpoint(addresses: ["192.168.65.10"], conditions: .init(ready: true), nodeName: "node-a"),
                KubeProxyEndpoint(addresses: ["192.168.65.20"], conditions: .init(ready: true), nodeName: "node-b"),
                KubeProxyEndpoint(addresses: ["192.168.65.30"], conditions: .init(ready: false), nodeName: "node-a"),
            ]
        )

        let ruleSet = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a")
        let rule = try #require(ruleSet.rules.first)
        #expect(
            rule.backends == [
                KubeProxyBackend(ip: "192.168.65.10", port: 8080),
                KubeProxyBackend(ip: "192.168.65.20", port: 8080),
            ])
    }

    @Test
    func explicitClusterTrafficPolicyIncludesReadyRemoteEndpoints() throws {
        let snapshot = makeSnapshot(
            internalTrafficPolicy: .cluster,
            endpoints: [
                KubeProxyEndpoint(addresses: ["192.168.65.10"], conditions: .init(ready: true), nodeName: "node-a"),
                KubeProxyEndpoint(addresses: ["192.168.65.20"], conditions: .init(ready: true), nodeName: "node-b"),
            ]
        )

        let ruleSet = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a")
        let rule = try #require(ruleSet.rules.first)
        #expect(
            rule.backends == [
                KubeProxyBackend(ip: "192.168.65.10", port: 8080),
                KubeProxyBackend(ip: "192.168.65.20", port: 8080),
            ])
    }

    @Test
    func localTrafficPolicyIncludesOnlyReadyEndpointsOnThisNode() throws {
        let snapshot = makeSnapshot(
            internalTrafficPolicy: .local,
            endpoints: [
                KubeProxyEndpoint(addresses: ["192.168.65.10"], conditions: .init(ready: true), nodeName: "node-a"),
                KubeProxyEndpoint(addresses: ["192.168.65.20"], conditions: .init(ready: true), nodeName: "node-b"),
                KubeProxyEndpoint(addresses: ["192.168.65.30"], conditions: .init(ready: true)),
                KubeProxyEndpoint(addresses: ["192.168.65.40"], conditions: .init(ready: false), nodeName: "node-a"),
            ]
        )

        let ruleSet = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a")
        let rule = try #require(ruleSet.rules.first)
        #expect(rule.backends == [KubeProxyBackend(ip: "192.168.65.10", port: 8080)])
    }

    @Test
    func compilesIPv6OnlyServiceWithIPv6EndpointSlice() throws {
        let snapshot = KubeProxySnapshot(
            services: [makeService(clusterIPs: ["fd42:10:96::42"], ipFamilies: ["IPv6"])],
            endpointSlices: [
                makeEndpointSlice(
                    addressType: "IPv6",
                    endpoints: [
                        KubeProxyEndpoint(addresses: ["fd42:10:244:22::10"], conditions: .init(ready: true), nodeName: "node-a"),
                        KubeProxyEndpoint(addresses: ["fd42:10:244:22::11"], conditions: .init(ready: true), nodeName: "node-a"),
                    ]
                )
            ]
        )

        let ruleSet = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a")

        #expect(ruleSet.issues.isEmpty)
        #expect(ruleSet.rules.count == 1)
        let rule = try #require(ruleSet.rules.first)
        #expect(rule.family == .ipv6)
        #expect(rule.clusterIP == "fd42:10:96::42")
        #expect(
            rule.backends == [
                KubeProxyBackend(family: .ipv6, ip: "fd42:10:244:22::10", port: 8080),
                KubeProxyBackend(family: .ipv6, ip: "fd42:10:244:22::11", port: 8080),
            ])
    }

    @Test
    func compilesEachDualStackClusterIPAgainstSameFamilySlice() throws {
        let snapshot = KubeProxySnapshot(
            services: [
                makeService(
                    clusterIPs: ["10.96.0.42", "fd42:10:96::42"],
                    ipFamilies: ["IPv4", "IPv6"]
                )
            ],
            endpointSlices: [
                makeEndpointSlice(
                    name: "echo-v4",
                    endpoints: [
                        KubeProxyEndpoint(addresses: ["192.168.65.10"], conditions: .init(ready: true), nodeName: "node-a")
                    ]
                ),
                makeEndpointSlice(
                    name: "echo-v6",
                    addressType: "IPv6",
                    endpoints: [
                        KubeProxyEndpoint(addresses: ["fd42:10:244:22::10"], conditions: .init(ready: true), nodeName: "node-a")
                    ]
                ),
            ]
        )

        let ruleSet = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a")
        let rulesByFamily = Dictionary(uniqueKeysWithValues: ruleSet.rules.map { ($0.family, $0) })

        #expect(ruleSet.rules.count == 2)
        #expect(rulesByFamily[.ipv4]?.clusterIP == "10.96.0.42")
        #expect(rulesByFamily[.ipv4]?.backends == [KubeProxyBackend(ip: "192.168.65.10", port: 8080)])
        #expect(rulesByFamily[.ipv6]?.clusterIP == "fd42:10:96::42")
        #expect(
            rulesByFamily[.ipv6]?.backends == [
                KubeProxyBackend(family: .ipv6, ip: "fd42:10:244:22::10", port: 8080)
            ])
    }

    @Test
    func neverMixesEndpointSliceOrBackendAddressFamilies() throws {
        let snapshot = KubeProxySnapshot(
            services: [
                makeService(
                    clusterIPs: ["10.96.0.42", "fd42:10:96::42"],
                    ipFamilies: ["IPv4", "IPv6"]
                )
            ],
            endpointSlices: [
                makeEndpointSlice(
                    name: "echo-v4",
                    endpoints: [
                        KubeProxyEndpoint(
                            addresses: ["192.168.65.10", "fd42:10:244:22::bad"],
                            conditions: .init(ready: true),
                            nodeName: "node-a"
                        )
                    ]
                ),
                makeEndpointSlice(
                    name: "echo-v6",
                    addressType: "IPv6",
                    endpoints: [
                        KubeProxyEndpoint(
                            addresses: ["fd42:10:244:22::10", "192.168.65.99"],
                            conditions: .init(ready: true),
                            nodeName: "node-a"
                        )
                    ]
                ),
            ]
        )

        let rules = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a").rules
        let ipv4Rule = try #require(rules.first { $0.family == .ipv4 })
        let ipv6Rule = try #require(rules.first { $0.family == .ipv6 })

        #expect(ipv4Rule.backends == [KubeProxyBackend(ip: "192.168.65.10", port: 8080)])
        #expect(
            ipv6Rule.backends == [
                KubeProxyBackend(family: .ipv6, ip: "fd42:10:244:22::10", port: 8080)
            ])
    }

    @Test
    func localTrafficPolicyFiltersIPv6EndpointsByNode() throws {
        let snapshot = KubeProxySnapshot(
            services: [
                makeService(
                    internalTrafficPolicy: .local,
                    clusterIPs: ["fd42:10:96::42"],
                    ipFamilies: ["IPv6"]
                )
            ],
            endpointSlices: [
                makeEndpointSlice(
                    addressType: "IPv6",
                    endpoints: [
                        KubeProxyEndpoint(addresses: ["fd42:10:244:22::10"], conditions: .init(ready: true), nodeName: "node-a"),
                        KubeProxyEndpoint(addresses: ["fd42:10:244:23::10"], conditions: .init(ready: true), nodeName: "node-b"),
                        KubeProxyEndpoint(addresses: ["fd42:10:244:24::10"], conditions: .init(ready: true)),
                    ]
                )
            ]
        )

        let rules = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a").rules
        #expect(rules.count == 1)
        let rule = try #require(rules.first)

        #expect(rule.family == .ipv6)
        #expect(
            rule.backends == [
                KubeProxyBackend(family: .ipv6, ip: "fd42:10:244:22::10", port: 8080)
            ])
    }

    @Test
    func excludesUnreadyNonServingAndTerminatingEndpoints() throws {
        let snapshot = makeSnapshot(
            endpoints: [
                KubeProxyEndpoint(
                    addresses: ["192.168.65.10"],
                    conditions: .init(ready: true, serving: true, terminating: false),
                    nodeName: "node-a"
                ),
                KubeProxyEndpoint(
                    addresses: ["192.168.65.20"],
                    conditions: .init(ready: false, serving: true, terminating: false),
                    nodeName: "node-a"
                ),
                KubeProxyEndpoint(
                    addresses: ["192.168.65.30"],
                    conditions: .init(ready: true, serving: false, terminating: false),
                    nodeName: "node-a"
                ),
                KubeProxyEndpoint(
                    addresses: ["192.168.65.40"],
                    conditions: .init(ready: true, serving: true, terminating: true),
                    nodeName: "node-a"
                ),
                KubeProxyEndpoint(addresses: ["192.168.65.50"], nodeName: "node-a"),
            ]
        )

        let ruleSet = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a")
        let rule = try #require(ruleSet.rules.first)
        #expect(
            rule.backends == [
                KubeProxyBackend(ip: "192.168.65.10", port: 8080),
                KubeProxyBackend(ip: "192.168.65.50", port: 8080),
            ])
    }

    @Test
    func decodesInternalTrafficPolicyAndEndpointConditions() throws {
        let serviceData = Data(
            #"{"items":[{"metadata":{"namespace":"default","name":"echo"},"spec":{"internalTrafficPolicy":"Local","ports":[]}}]}"#.utf8
        )
        let endpointSliceData = Data(
            #"{"items":[{"metadata":{"namespace":"default","name":"echo-abc"},"addressType":"IPv4","endpoints":[{"addresses":["192.168.65.10"],"conditions":{"ready":true,"serving":false,"terminating":false},"nodeName":"node-a"}],"ports":[]}]}"#
                .utf8
        )

        let serviceList = try JSONDecoder().decode(KubeProxyServiceList.self, from: serviceData)
        let endpointSliceList = try JSONDecoder().decode(KubeProxyEndpointSliceList.self, from: endpointSliceData)

        #expect(serviceList.items.first?.spec?.internalTrafficPolicy == .local)
        #expect(endpointSliceList.items.first?.endpoints.first?.conditions == .init(ready: true, serving: false, terminating: false))
    }

    @Test
    func decodesNullOrMissingEndpointSliceEndpointsAsEmpty() throws {
        let endpointSliceData = Data(
            #"{"items":[{"metadata":{"namespace":"default","name":"null-endpoints"},"addressType":"IPv4","endpoints":null,"ports":[]},{"metadata":{"namespace":"default","name":"missing-endpoints"},"addressType":"IPv6","ports":[]}]}"#
                .utf8
        )

        let endpointSliceList = try JSONDecoder().decode(KubeProxyEndpointSliceList.self, from: endpointSliceData)

        #expect(endpointSliceList.items.count == 2)
        #expect(endpointSliceList.items.map(\.endpoints) == [[], []])
    }

    @Test
    func decodesNullOrMissingEndpointSlicePortsAsEmpty() throws {
        let endpointSliceData = Data(
            #"{"items":[{"metadata":{"namespace":"default","name":"null-ports"},"addressType":"IPv4","endpoints":[],"ports":null},{"metadata":{"namespace":"default","name":"missing-ports"},"addressType":"IPv6","endpoints":[]}]}"#
                .utf8
        )

        let endpointSliceList = try JSONDecoder().decode(
            KubeProxyEndpointSliceList.self,
            from: endpointSliceData
        )

        #expect(endpointSliceList.items.count == 2)
        #expect(endpointSliceList.items.map(\.ports) == [[], []])
    }

    @Test
    func reportsAndSkipsHeterogeneousBackendPorts() throws {
        let snapshot = KubeProxySnapshot(
            services: [makeService()],
            endpointSlices: [
                makeEndpointSlice(
                    name: "echo-a", port: 8080,
                    endpoints: [
                        KubeProxyEndpoint(addresses: ["192.168.65.10"], conditions: .init(ready: true), nodeName: "node-a")
                    ]),
                makeEndpointSlice(
                    name: "echo-b", port: 9090,
                    endpoints: [
                        KubeProxyEndpoint(addresses: ["192.168.65.11"], conditions: .init(ready: true), nodeName: "node-a")
                    ]),
            ]
        )

        let ruleSet = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a")
        #expect(ruleSet.rules.isEmpty)
        #expect(ruleSet.issues.contains { $0.id.contains("heterogeneous-backend-ports") })
    }

    @Test
    func rendersDeterministicPFAnchor() throws {
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a", generation: 7)
        let anchor = try KubeProxyPFRenderer.renderAnchor(
            ruleSet: ruleSet,
            localPodCIDR: "10.250.25.0/24",
            podIngressInterface: "bridge100"
        )

        #expect(anchor.contains("# generation: 7"))
        #expect(anchor.contains("# local PodCIDR: 10.250.25.0/24"))
        #expect(anchor.contains("# Pod ingress interface: bridge100"))
        #expect(anchor.contains("table <ckp_v4_default_echo_http_tcp_80> persist { 192.168.65.10, 192.168.65.11 }"))
        #expect(!anchor.contains("table <ckh_"))
        #expect(!anchor.contains("nat on"))
        #expect(
            anchor.contains(
                "no rdr on bridge100 inet proto tcp from <ckp_v4_default_echo_http_tcp_80> port 8080 to 10.250.25.0/24"
            ))
        #expect(
            anchor.contains(
                "rdr pass on bridge100 inet proto tcp from 10.250.25.0/24 to 10.96.0.42 port 80 -> <ckp_v4_default_echo_http_tcp_80> port 8080 round-robin"
            ))
        #expect(!anchor.contains(" from any "))
    }

    @Test
    func rendersPodEgressNATOnlyOnConfiguredInterface() throws {
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")
        let anchor = try KubeProxyPFRenderer.renderAnchor(
            ruleSet: ruleSet,
            localPodCIDR: "192.168.64.0/24",
            podIngressInterface: "bridge100",
            masqueradePodTraffic: true,
            egressInterface: "en7"
        )

        #expect(anchor.contains("nat on en7 inet from 192.168.64.0/24 to any -> (en7)"))
        #expect(!anchor.contains("nat on utun"))
        #expect(
            anchor.contains(
                "rdr pass on bridge100 inet proto tcp from 192.168.64.0/24 to 10.96.0.42 port 80"
            ))
    }

    @Test
    func rendersScopedIPv6HairpinNAT() throws {
        let snapshot = KubeProxySnapshot(
            services: [makeService(clusterIPs: ["fd42:10:96::42"], ipFamilies: ["IPv6"])],
            endpointSlices: [
                makeEndpointSlice(
                    addressType: "IPv6",
                    endpoints: [
                        KubeProxyEndpoint(addresses: ["fd42:10:244:22::10"], conditions: .init(ready: true), nodeName: "node-a")
                    ]
                )
            ]
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a")
        let anchor = try KubeProxyPFRenderer.renderAnchor(
            ruleSet: ruleSet,
            localPodCIDR: "fd42:10:244:22::/64",
            podIngressInterface: "bridge100"
        )

        #expect(anchor.contains("table <ckp_v6_default_echo_http_tcp_80> persist { fd42:10:244:22::10 }"))
        #expect(anchor.contains("table <ckh_v6_default_echo_http_tcp_80> persist { fd42:10:244:22::10 }"))
        #expect(
            anchor.contains(
                "nat on bridge100 inet6 proto tcp from fd42:10:244:22::/64 to <ckh_v6_default_echo_http_tcp_80> port 8080 tagged ckp_hairpin -> fd42:10:244:22::1"
            ))
        #expect(!anchor.contains("-> (bridge100)"))
        #expect(
            anchor.contains(
                "no rdr on bridge100 inet6 proto tcp from <ckp_v6_default_echo_http_tcp_80> port 8080 to fd42:10:244:22::/64"
            ))
        #expect(
            anchor.contains(
                "rdr pass on bridge100 inet6 proto tcp from fd42:10:244:22::/64 to fd42:10:96::42 port 80 tag ckp_hairpin -> <ckp_v6_default_echo_http_tcp_80> port 8080"
            ))
    }

    @Test
    func rendersIPv6EgressNATWithExplicitSourceAddress() throws {
        let rule = KubeProxyServiceRule(
            namespace: "default",
            serviceName: "echo",
            portName: "http",
            protocolName: .tcp,
            family: .ipv6,
            clusterIP: "fd42:10:96::42",
            servicePort: 80,
            backends: [
                KubeProxyBackend(
                    family: .ipv6,
                    ip: "fd42:10:244:1::10",
                    port: 8080
                )
            ]
        )

        let anchor = try KubeProxyPFRenderer.renderAnchor(
            ruleSet: KubeProxyRuleSet(rules: [rule]),
            localPodCIDR: "fd42:10:244:22::/64",
            podIngressInterface: "bridge100",
            masqueradePodTraffic: true,
            egressInterface: "en0",
            egressSourceAddress: "2001:db8:100:c:203:0:113:208"
        )

        #expect(
            anchor.contains(
                "nat on en0 inet6 from fd42:10:244:22::/64 to any -> 2001:db8:100:c:203:0:113:208"
            ))
        #expect(!anchor.contains("nat on en0 inet6 from fd42:10:244:22::/64 to any -> (en0)"))
    }

    @Test
    func rejectsIPv6EgressNATWithoutCanonicalSourceAddress() {
        let ruleSet = KubeProxyRuleSet(
            rules: [
                KubeProxyServiceRule(
                    namespace: "default",
                    serviceName: "echo",
                    portName: "http",
                    protocolName: .tcp,
                    family: .ipv6,
                    clusterIP: "fd42:10:96::42",
                    servicePort: 80,
                    backends: [
                        KubeProxyBackend(family: .ipv6, ip: "fd42:10:244:1::10", port: 8080)
                    ]
                )
            ]
        )

        #expect(throws: KubeProxyMacOSError.self) {
            try KubeProxyPFRenderer.renderAnchor(
                ruleSet: ruleSet,
                localPodCIDR: "fd42:10:244:22::/64",
                podIngressInterface: "bridge100",
                masqueradePodTraffic: true,
                egressInterface: "en0"
            )
        }
    }

    @Test
    func hairpinNATTargetsOnlyTaggedLocalBackends() throws {
        let rule = KubeProxyServiceRule(
            namespace: "default",
            serviceName: "echo",
            portName: "http",
            protocolName: .tcp,
            clusterIP: "10.96.0.42",
            servicePort: 80,
            backends: [
                KubeProxyBackend(ip: "10.250.1.43", port: 8080),
                KubeProxyBackend(ip: "10.250.34.6", port: 8080),
                KubeProxyBackend(ip: "10.250.34.7", port: 8080),
            ]
        )

        let anchor = try KubeProxyPFRenderer.renderAnchor(
            ruleSet: KubeProxyRuleSet(rules: [rule]),
            localPodCIDR: "10.250.34.0/24",
            podIngressInterface: "bridge100"
        )

        #expect(
            anchor.contains(
                "table <ckp_v4_default_echo_http_tcp_80> persist { 10.250.1.43, 10.250.34.6, 10.250.34.7 }"
            ))
        #expect(
            anchor.contains(
                "table <ckh_v4_default_echo_http_tcp_80> persist { 10.250.34.6, 10.250.34.7 }"
            ))
        #expect(
            anchor.contains(
                "nat on bridge100 inet proto tcp from 10.250.34.0/24 to <ckh_v4_default_echo_http_tcp_80> port 8080 tagged ckp_hairpin -> 10.250.34.1"
            ))
        #expect(!anchor.contains("-> (bridge100)"))
        #expect(
            anchor.contains(
                "no rdr on bridge100 inet proto tcp from <ckp_v4_default_echo_http_tcp_80> port 8080 to 10.250.34.0/24\nrdr pass on bridge100 inet proto tcp from 10.250.34.0/24 to 10.96.0.42 port 80 tag ckp_hairpin -> <ckp_v4_default_echo_http_tcp_80> port 8080 round-robin"
            ))
        #expect(!anchor.contains("nat on bridge100 inet proto tcp from any"))
        #expect(!anchor.contains("to <ckp_v4_default_echo_http_tcp_80> port 8080 tagged"))
    }

    @Test
    func omitsNoOpRedirectPortMapping() throws {
        let rule = KubeProxyServiceRule(
            namespace: "default",
            serviceName: "echo",
            portName: "http",
            protocolName: .tcp,
            clusterIP: "10.96.0.42",
            servicePort: 18080,
            backends: [KubeProxyBackend(ip: "10.250.25.10", port: 18080)]
        )

        let anchor = try KubeProxyPFRenderer.renderAnchor(
            ruleSet: KubeProxyRuleSet(rules: [rule]),
            localPodCIDR: "10.250.25.0/24",
            podIngressInterface: "bridge100"
        )
        let tableName = KubeProxyPFRenderer.tableName(for: rule)

        #expect(
            anchor.contains(
                "to 10.96.0.42 port 18080 tag ckp_hairpin -> <\(tableName)>"
            ))
        #expect(!anchor.contains("-> <\(tableName)> port 18080"))
        #expect(!anchor.contains("no rdr"))
    }

    @Test
    func rejectsPFAnchorWithInvalidPodIngressInterfaceOrMixedFamilies() {
        let ipv4RuleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        #expect(throws: KubeProxyMacOSError.self) {
            try KubeProxyPFRenderer.renderAnchor(
                ruleSet: ipv4RuleSet,
                localPodCIDR: "10.250.25.0/24",
                podIngressInterface: ""
            )
        }
        #expect(throws: KubeProxyMacOSError.self) {
            try KubeProxyPFRenderer.renderAnchor(
                ruleSet: ipv4RuleSet,
                localPodCIDR: "fd42:10:244:19::/64",
                podIngressInterface: "bridge100"
            )
        }
    }

    @Test
    func familyMakesPFTableNamesDistinct() {
        let ipv4Rule = KubeProxyServiceRule(
            namespace: "default",
            serviceName: "echo",
            portName: "http",
            protocolName: .tcp,
            family: .ipv4,
            clusterIP: "10.96.0.42",
            servicePort: 80,
            backends: [KubeProxyBackend(ip: "192.168.65.10", port: 8080)]
        )
        let ipv6Rule = KubeProxyServiceRule(
            namespace: "default",
            serviceName: "echo",
            portName: "http",
            protocolName: .tcp,
            family: .ipv6,
            clusterIP: "fd42:10:96::42",
            servicePort: 80,
            backends: [KubeProxyBackend(family: .ipv6, ip: "fd42:10:244:22::10", port: 8080)]
        )

        let ipv4TableName = KubeProxyPFRenderer.tableName(for: ipv4Rule)
        let ipv6TableName = KubeProxyPFRenderer.tableName(for: ipv6Rule)

        #expect(ipv4TableName.contains("_v4_"))
        #expect(ipv6TableName.contains("_v6_"))
        #expect(ipv4TableName != ipv6TableName)
    }

    @Test
    func decodesLegacyRuleStateAsIPv4() throws {
        let data = Data(
            #"{"generation":7,"rules":[{"namespace":"default","serviceName":"echo","protocolName":"TCP","clusterIP":"10.96.0.42","servicePort":80,"backends":[{"ip":"192.168.65.10","port":8080}]}],"issues":[]}"#
                .utf8
        )

        let ruleSet = try JSONDecoder().decode(KubeProxyRuleSet.self, from: data)
        let rule = try #require(ruleSet.rules.first)
        let backend = try #require(rule.backends.first)

        #expect(rule.family == .ipv4)
        #expect(backend.family == .ipv4)
    }

    @Test
    func limitsPFTableNamesToPlatformMaximum() throws {
        let rule = KubeProxyServiceRule(
            namespace: "default",
            serviceName: "kubernetes",
            portName: "https",
            protocolName: .tcp,
            clusterIP: "10.96.0.1",
            servicePort: 443,
            backends: [KubeProxyBackend(ip: "198.18.55.130", port: 6443)]
        )
        let tableName = KubeProxyPFRenderer.tableName(for: rule)

        #expect(tableName.utf8.count == 31)
        #expect(tableName.hasPrefix("ckp_v4_default_kuber"))
        #expect(tableName == KubeProxyPFRenderer.tableName(for: rule))
    }

    @Test
    func applierInstallsPFConfigAndAnchorAfterValidation() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: "com.apple.container.kube-proxy.test",
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")

        let config = try String(contentsOf: configURL, encoding: .utf8)
        let anchorURL = anchorsURL.appendingPathComponent("com.apple.container.kube-proxy.test")
        let anchor = try String(contentsOf: anchorURL, encoding: .utf8)
        #expect(config.contains("nat-anchor \"com.apple.container.kube-proxy.test\""))
        #expect(config.contains("rdr-anchor \"com.apple.container.kube-proxy.test\""))
        #expect(config.contains("load anchor \"com.apple.container.kube-proxy.test\" from \"\(anchorURL.path)\""))
        #expect(anchor.contains("# local PodCIDR: 10.250.25.0/24"))
        #expect(!anchor.contains("nat on"))
        #expect(
            anchor.contains(
                "rdr pass on bridge100 inet proto tcp from 10.250.25.0/24 to 10.96.0.42 port 80 -> <ckp_v4_default_echo_http_tcp_80> port 8080 round-robin"
            ))
    }

    @Test
    func applierDrainsLargePFCTLOutputOnSuccess() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pfctl = try makeChattyPFCTL(in: directory, exitCode: 0)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: "com.apple.container.kube-proxy.test",
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")

        #expect(FileManager.default.fileExists(atPath: anchorsURL.path))
    }

    @Test
    func applierInstallsPodEgressNATAnchorAndRule() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: "com.apple.container.kube-proxy.test",
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        try applier.apply(
            ruleSet,
            localPodCIDR: "192.168.64.0/24",
            masqueradePodTraffic: true
        )

        let config = try String(contentsOf: configURL, encoding: .utf8)
        let anchor = try String(
            contentsOf: anchorsURL.appendingPathComponent("com.apple.container.kube-proxy.test"),
            encoding: .utf8
        )
        #expect(config.contains("nat-anchor \"com.apple.container.kube-proxy.test\""))
        #expect(config.contains("rdr-anchor \"com.apple.container.kube-proxy.test\""))
        #expect(anchor.contains("nat on en7 inet from 192.168.64.0/24 to any -> (en7)"))
    }

    @Test
    func localBackendChurnReloadsOnlyTheChildAnchor() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(
            in: directory,
            exitCode: 0,
            argumentsLogURL: argumentsLogURL
        )
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)

        let anchorName = "com.apple.container.kube-proxy.test"
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")
        let localRuleSet = KubeProxyCompiler.compile(
            snapshot: makeSnapshot(
                endpoints: [
                    KubeProxyEndpoint(
                        addresses: ["10.250.25.10"],
                        conditions: .init(ready: true),
                        nodeName: "node-a"
                    )
                ]
            ),
            nodeName: "node-a"
        )

        try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")
        try applier.apply(localRuleSet, localPodCIDR: "10.250.25.0/24")

        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        let anchorURL = anchorsURL.appendingPathComponent(anchorName)
        #expect(arguments.filter { $0 == "-f \(configURL.path)" }.count == 1)
        #expect(arguments.filter { $0 == "-a \(anchorName) -f \(anchorURL.path)" }.count == 1)
        #expect(
            try String(contentsOf: anchorURL, encoding: .utf8)
                .contains("tagged ckp_hairpin -> 10.250.25.1")
        )
    }

    @Test
    func applierRecognizesIndentedAnchorReferencesWithoutDuplicatingThem() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(
            in: directory,
            exitCode: 0,
            argumentsLogURL: argumentsLogURL
        )
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let anchorURL = anchorsURL.appendingPathComponent(anchorName)
        try """
          nat-anchor "\(anchorName)"
          rdr-anchor "\(anchorName)"
          load anchor "\(anchorName)" from "\(anchorURL.path)"

        """.write(to: configURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")

        let directives = try String(contentsOf: configURL, encoding: .utf8)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        #expect(directives.filter { $0 == "rdr-anchor \"\(anchorName)\"" }.count == 1)
        #expect(directives.filter { $0 == "load anchor \"\(anchorName)\" from \"\(anchorURL.path)\"" }.count == 1)
        #expect(arguments.filter { $0 == "-f \(configURL.path)" }.isEmpty)
        #expect(arguments.filter { $0 == "-a \(anchorName) -f \(anchorURL.path)" }.count == 1)
    }

    @Test
    func applierUpgradesUniqueLegacyReferencesWithManagedLoadPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let anchorURL = anchorsURL.appendingPathComponent(anchorName)
        try """
        rdr-anchor "\(anchorName)"
        load anchor "\(anchorName)" from "\(anchorURL.path)"

        """.write(to: configURL, atomically: true, encoding: .utf8)
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        try applier.apply(
            KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a"),
            localPodCIDR: "10.250.25.0/24"
        )

        let config = try String(contentsOf: configURL, encoding: .utf8)
        #expect(config.components(separatedBy: "nat-anchor \"\(anchorName)\"").count == 2)
        #expect(config.components(separatedBy: "rdr-anchor \"\(anchorName)\"").count == 2)
        #expect(config.components(separatedBy: "load anchor \"\(anchorName)\"").count == 2)
    }

    @Test
    func applierRejectsForeignOrDuplicateManagedAnchorReferences() throws {
        for conflictingReferences in [
            { (anchorName: String, _: URL) in
                """
                nat-anchor "\(anchorName)"
                rdr-anchor "\(anchorName)"
                load anchor "\(anchorName)" from "/tmp/foreign-kube-proxy-anchor"
                """
            },
            { (anchorName: String, anchorURL: URL) in
                """
                nat-anchor "\(anchorName)"
                rdr-anchor "\(anchorName)"
                rdr-anchor "\(anchorName)"
                load anchor "\(anchorName)" from "\(anchorURL.path)"
                """
            },
        ] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pfctl = try makeFakePFCTL(in: directory, exitCode: 0)
            let configURL = directory.appendingPathComponent("pf.conf")
            let anchorsURL = directory.appendingPathComponent("anchors")
            let anchorName = "com.apple.container.kube-proxy.test"
            let anchorURL = anchorsURL.appendingPathComponent(anchorName)
            let originalConfig = conflictingReferences(anchorName, anchorURL) + "\n"
            try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
            let applier = KubeProxyPFRuleApplier(
                config: KubeProxyPFConfig(
                    anchorName: anchorName,
                    configPath: configURL.path,
                    anchorsPath: anchorsURL.path,
                    pfctlPath: pfctl.path
                ),
                podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
                advisoryLockPath: directory.appendingPathComponent("pf.lock").path
            )

            do {
                try applier.apply(
                    KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a"),
                    localPodCIDR: "10.250.25.0/24"
                )
                Issue.record("conflicting PF anchor references must fail closed")
            } catch {
                #expect(String(describing: error).contains("conflicting or incomplete references"))
            }
            #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
            #expect(!FileManager.default.fileExists(atPath: anchorURL.path))
        }
    }

    @Test
    func withdrawRejectsForeignManagedAnchorLoadPathWithoutMutation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let anchorURL = anchorsURL.appendingPathComponent(anchorName)
        try FileManager.default.createDirectory(at: anchorsURL, withIntermediateDirectories: true)
        let originalConfig = """
            nat-anchor "\(anchorName)"
            rdr-anchor "\(anchorName)"
            load anchor "\(anchorName)" from "/tmp/foreign-kube-proxy-anchor"

            """
        let originalAnchor = "# local file must not be removed\n"
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try originalAnchor.write(to: anchorURL, atomically: true, encoding: .utf8)
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        #expect(throws: KubeProxyMacOSError.self) {
            try applier.withdraw()
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
        #expect(try String(contentsOf: anchorURL, encoding: .utf8) == originalAnchor)
    }

    @Test
    func applierBestEffortReloadsOriginalRootRulesAfterRuntimeFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makePFCTLFailingFirstRootReload(
            in: directory,
            argumentsLogURL: argumentsLogURL
        )
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let anchorURL = anchorsURL.appendingPathComponent(anchorName)
        try FileManager.default.createDirectory(at: anchorsURL, withIntermediateDirectories: true)
        let originalConfig = "set skip on lo0\n"
        let originalAnchor = "# original anchor\n"
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try originalAnchor.write(to: anchorURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        #expect(throws: (any Error).self) {
            try applier.apply(
                KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a"),
                localPodCIDR: "10.250.25.0/24"
            )
        }

        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
        #expect(try String(contentsOf: anchorURL, encoding: .utf8) == originalAnchor)
        #expect(arguments.filter { $0 == "-f \(configURL.path)" }.count == 2)
    }

    @Test
    func legacyApplierFlushesNewLiveAnchorWhenChildReloadFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makePFCTLFailingFirstAnchorReload(
            in: directory,
            argumentsLogURL: argumentsLogURL
        )
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let anchorURL = anchorsURL.appendingPathComponent(anchorName)
        try """
        nat-anchor "\(anchorName)"
        rdr-anchor "\(anchorName)"
        load anchor "\(anchorName)" from "\(anchorURL.path)"

        """.write(to: configURL, atomically: true, encoding: .utf8)
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        #expect(throws: KubeProxyMacOSError.self) {
            try applier.apply(
                KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a"),
                localPodCIDR: "10.250.25.0/24"
            )
        }

        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(arguments.contains("-a \(anchorName) -F all"))
        #expect(!FileManager.default.fileExists(atPath: anchorURL.path))
    }

    @Test
    func legacyApplierWithdrawsStaleRulesWhenPodIngressBridgeDisappearsAndRecovers() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let anchorURL = anchorsURL.appendingPathComponent(anchorName)
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)
        let config = KubeProxyPFConfig(
            anchorName: anchorName,
            configPath: configURL.path,
            anchorsPath: anchorsURL.path,
            pfctlPath: pfctl.path
        )
        let readyApplier = KubeProxyPFRuleApplier(
            config: config,
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        try readyApplier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")
        try Data().write(to: argumentsLogURL)

        let unavailableApplier = KubeProxyPFRuleApplier(
            config: config,
            podIngressInterfaceResolver: UnavailablePodIngressInterfaceResolver(failingFamily: .ipv4),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        do {
            try unavailableApplier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")
            Issue.record("missing Pod ingress bridge must fail after withdrawing stale rules")
        } catch {
            #expect(String(describing: error).contains("Pod ingress bridge is not ready"))
        }

        let withdrawnConfig = try String(contentsOf: configURL, encoding: .utf8)
        let withdrawalArguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(!withdrawnConfig.contains("anchor \"\(anchorName)\""))
        #expect(!FileManager.default.fileExists(atPath: anchorURL.path))
        #expect(withdrawalArguments.contains("-a \(anchorName) -F all"))
        #expect(!withdrawalArguments.contains("-a \(anchorName).ipv6 -F all"))

        try readyApplier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")

        #expect(FileManager.default.fileExists(atPath: anchorURL.path))
        #expect(
            try String(contentsOf: anchorURL, encoding: .utf8)
                .contains("rdr pass on bridge100 inet")
        )
        #expect(
            try String(contentsOf: configURL, encoding: .utf8)
                .contains("rdr-anchor \"\(anchorName)\"")
        )
    }

    @Test
    func dualStackApplierUsesFamilySpecificHairpinNAT() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(
                ipv4Interface: "bridge100",
                ipv6Interface: "bridge101"
            ),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeDualStackSnapshot(), nodeName: "node-a")

        try applier.apply(
            ruleSet,
            podNetwork: KubeProxyFamilyRuleApplication(
                ipv4PodCIDR: "10.250.25.0/24",
                ipv6PodCIDR: "fd42:10:244:19::/64",
                ipv6Ready: true,
                dualStackEnabled: true
            )
        )

        let ipv4AnchorURL = anchorsURL.appendingPathComponent(anchorName)
        let ipv6AnchorURL = anchorsURL.appendingPathComponent("\(anchorName).ipv6")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let ipv4Anchor = try String(contentsOf: ipv4AnchorURL, encoding: .utf8)
        let ipv6Anchor = try String(contentsOf: ipv6AnchorURL, encoding: .utf8)
        #expect(config.contains("nat-anchor \"\(anchorName)\""))
        #expect(config.contains("rdr-anchor \"\(anchorName)\""))
        #expect(config.contains("rdr-anchor \"\(anchorName).ipv6\""))
        #expect(config.contains("nat-anchor \"\(anchorName).ipv6\""))
        #expect(ipv4Anchor.contains("nat on en7 inet from 10.250.25.0/24"))
        #expect(ipv4Anchor.contains("nat on bridge100 inet proto tcp from 10.250.25.0/24"))
        #expect(ipv4Anchor.contains("tagged ckp_hairpin -> 10.250.25.1"))
        #expect(ipv4Anchor.contains("rdr pass on bridge100 inet proto tcp from 10.250.25.0/24"))
        #expect(!ipv4Anchor.contains("rdr pass on bridge100 inet6"))
        #expect(ipv6Anchor.contains("# local PodCIDR: fd42:10:244:19::/64"))
        #expect(
            ipv6Anchor.contains(
                "nat on en7 inet6 from fd42:10:244:19::/64 to any -> 2001:db8:100:c:203:0:113:208"
            ))
        #expect(ipv6Anchor.contains("nat on bridge101 inet6 proto tcp from fd42:10:244:19::/64"))
        #expect(ipv6Anchor.contains("tagged ckp_hairpin -> fd42:10:244:19::1"))
        #expect(ipv6Anchor.contains("rdr pass on bridge101 inet6 proto tcp from fd42:10:244:19::/64"))
    }

    @Test(arguments: [KubeProxyAddressFamily.ipv4, .ipv6])
    func dualStackApplierWithdrawsBothFamiliesWhenPodIngressBridgeDisappears(
        failingFamily: KubeProxyAddressFamily
    ) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let ipv4AnchorURL = anchorsURL.appendingPathComponent(anchorName)
        let ipv6AnchorURL = anchorsURL.appendingPathComponent("\(anchorName).ipv6")
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)
        let config = KubeProxyPFConfig(
            anchorName: anchorName,
            configPath: configURL.path,
            anchorsPath: anchorsURL.path,
            pfctlPath: pfctl.path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeDualStackSnapshot(), nodeName: "node-a")
        let podNetwork = KubeProxyFamilyRuleApplication(
            ipv4PodCIDR: "10.250.25.0/24",
            ipv6PodCIDR: "fd42:10:244:19::/64",
            ipv6Ready: true,
            dualStackEnabled: true
        )
        let readyApplier = KubeProxyPFRuleApplier(
            config: config,
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        try readyApplier.apply(ruleSet, podNetwork: podNetwork)
        try Data().write(to: argumentsLogURL)

        let unavailableApplier = KubeProxyPFRuleApplier(
            config: config,
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: UnavailablePodIngressRouteResolver(failingFamily: failingFamily),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        #expect(
            throws: KubeProxyPodIngressRouteTransitionError.unavailableAfterWithdrawal(failingFamily)
        ) {
            try unavailableApplier.apply(ruleSet, podNetwork: podNetwork)
        }

        let withdrawnConfig = try String(contentsOf: configURL, encoding: .utf8)
        let withdrawalArguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(!withdrawnConfig.contains("anchor \"\(anchorName)\""))
        #expect(!withdrawnConfig.contains("anchor \"\(anchorName).ipv6\""))
        #expect(!FileManager.default.fileExists(atPath: ipv4AnchorURL.path))
        #expect(!FileManager.default.fileExists(atPath: ipv6AnchorURL.path))
        #expect(withdrawalArguments.contains("-a \(anchorName) -F all"))
        #expect(withdrawalArguments.contains("-a \(anchorName).ipv6 -F all"))
    }

    @Test
    func podIngressResolutionFailureReportsWithdrawalFailureAndRestoresPersistentState() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let ipv4AnchorURL = anchorsURL.appendingPathComponent(anchorName)
        let ipv6AnchorURL = anchorsURL.appendingPathComponent("\(anchorName).ipv6")
        let initialPFCTL = try makeFakePFCTL(in: directory, exitCode: 0)
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeDualStackSnapshot(), nodeName: "node-a")
        let podNetwork = KubeProxyFamilyRuleApplication(
            ipv4PodCIDR: "10.250.25.0/24",
            ipv6PodCIDR: "fd42:10:244:19::/64",
            ipv6Ready: true,
            dualStackEnabled: true
        )
        let readyApplier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: initialPFCTL.path
            ),
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        try readyApplier.apply(ruleSet, podNetwork: podNetwork)
        let originalConfig = try Data(contentsOf: configURL)
        let originalIPv4Anchor = try Data(contentsOf: ipv4AnchorURL)
        let originalIPv6Anchor = try Data(contentsOf: ipv6AnchorURL)

        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let failingPFCTL = try makePFCTLFailingFirstRootReload(
            in: directory,
            argumentsLogURL: argumentsLogURL
        )
        let unavailableApplier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: failingPFCTL.path
            ),
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: UnavailablePodIngressRouteResolver(failingFamily: .ipv6),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        do {
            try unavailableApplier.apply(ruleSet, podNetwork: podNetwork)
            Issue.record("Pod ingress and fail-closed withdrawal failures must both be reported")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("Pod ingress interface resolution failed"))
            #expect(message.contains("local IPv6 PodCIDR route is not directly connected"))
            #expect(message.contains("fail-closed PF withdrawal also failed"))
            #expect(message.contains("pfctl reload failed"))
        }
        #expect(try Data(contentsOf: configURL) == originalConfig)
        #expect(try Data(contentsOf: ipv4AnchorURL) == originalIPv4Anchor)
        #expect(try Data(contentsOf: ipv6AnchorURL) == originalIPv6Anchor)
        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        #expect(arguments.filter { $0 == "-f \(configURL.path)" }.count == 2)
    }

    @Test
    func staleIPv6FamilyIsFlushedWithoutFlushingIPv4() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeDualStackSnapshot(), nodeName: "node-a")
        let ready = KubeProxyFamilyRuleApplication(
            ipv4PodCIDR: "10.250.25.0/24",
            ipv6PodCIDR: "fd42:10:244:19::/64",
            ipv6Ready: true,
            dualStackEnabled: true
        )

        try applier.apply(ruleSet, podNetwork: ready)
        try Data().write(to: argumentsLogURL)
        var stale = ready
        stale.ipv6Ready = false
        try applier.apply(ruleSet.selecting(families: [.ipv4]), podNetwork: stale)

        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let ipv4Anchor = try String(contentsOf: anchorsURL.appendingPathComponent(anchorName), encoding: .utf8)
        let ipv6Anchor = try String(
            contentsOf: anchorsURL.appendingPathComponent("\(anchorName).ipv6"),
            encoding: .utf8
        )
        #expect(arguments.contains("-a \(anchorName).ipv6 -F all"))
        #expect(!arguments.contains("-a \(anchorName) -F all"))
        #expect(config.contains("rdr-anchor \"\(anchorName)\""))
        #expect(!config.contains("rdr-anchor \"\(anchorName).ipv6\""))
        #expect(ipv4Anchor.contains("rdr pass on bridge100 inet proto tcp from 10.250.25.0/24"))
        #expect(ipv6Anchor.contains("IPv6 family disabled or not ready"))
    }

    @Test
    func dualStackApplierRestoresBothAnchorsAfterRootReloadFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makePFCTLFailingFirstRootReload(in: directory, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let ipv4AnchorURL = anchorsURL.appendingPathComponent(anchorName)
        let ipv6AnchorURL = anchorsURL.appendingPathComponent("\(anchorName).ipv6")
        try FileManager.default.createDirectory(at: anchorsURL, withIntermediateDirectories: true)
        let originalConfig = "set skip on lo0\n"
        let originalIPv4Anchor = "# original IPv4 anchor\n"
        let originalIPv6Anchor = "# original IPv6 anchor\n"
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try originalIPv4Anchor.write(to: ipv4AnchorURL, atomically: true, encoding: .utf8)
        try originalIPv6Anchor.write(to: ipv6AnchorURL, atomically: true, encoding: .utf8)
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        #expect(throws: (any Error).self) {
            try applier.apply(
                KubeProxyCompiler.compile(snapshot: makeDualStackSnapshot(), nodeName: "node-a"),
                podNetwork: KubeProxyFamilyRuleApplication(
                    ipv4PodCIDR: "10.250.25.0/24",
                    ipv6PodCIDR: "fd42:10:244:19::/64",
                    ipv6Ready: true,
                    dualStackEnabled: true
                )
            )
        }

        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
        #expect(try String(contentsOf: ipv4AnchorURL, encoding: .utf8) == originalIPv4Anchor)
        #expect(try String(contentsOf: ipv6AnchorURL, encoding: .utf8) == originalIPv6Anchor)
        #expect(arguments.components(separatedBy: .newlines).filter { $0 == "-f \(configURL.path)" }.count == 2)
    }

    @Test
    func dualStackApplierReportsPrimaryAndRollbackFailures() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let ipv4AnchorURL = anchorsURL.appendingPathComponent(anchorName)
        let ipv6AnchorURL = anchorsURL.appendingPathComponent("\(anchorName).ipv6")
        try FileManager.default.createDirectory(at: anchorsURL, withIntermediateDirectories: true)
        let originalConfig = """
            nat-anchor "\(anchorName)"
            rdr-anchor "\(anchorName)"
            load anchor "\(anchorName)" from "\(ipv4AnchorURL.path)"
            nat-anchor "\(anchorName).ipv6"
            rdr-anchor "\(anchorName).ipv6"
            load anchor "\(anchorName).ipv6" from "\(ipv6AnchorURL.path)"

            """
        let originalIPv4Anchor = "# original IPv4 anchor\n"
        let originalIPv6Anchor = "# original IPv6 anchor\n"
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try originalIPv4Anchor.write(to: ipv4AnchorURL, atomically: true, encoding: .utf8)
        try originalIPv6Anchor.write(to: ipv6AnchorURL, atomically: true, encoding: .utf8)
        let pfctl = try makePFCTLFailingIPv6ReloadAndIPv4Rollback(
            in: directory,
            anchorName: anchorName,
            argumentsLogURL: argumentsLogURL
        )
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        do {
            try applier.apply(
                KubeProxyCompiler.compile(snapshot: makeDualStackSnapshot(), nodeName: "node-a"),
                podNetwork: KubeProxyFamilyRuleApplication(
                    ipv4PodCIDR: "10.250.25.0/24",
                    ipv6PodCIDR: "fd42:10:244:19::/64",
                    ipv6Ready: true,
                    dualStackEnabled: true
                )
            )
            Issue.record("IPv6 child reload failure must be reported")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("pfctl IPv6 anchor reload failed"))
            #expect(message.contains("pfctl IPv4 anchor rollback failed"))
            #expect(message.contains("rollback was incomplete"))
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
        #expect(try String(contentsOf: ipv4AnchorURL, encoding: .utf8) == originalIPv4Anchor)
        #expect(try String(contentsOf: ipv6AnchorURL, encoding: .utf8) == originalIPv6Anchor)
    }

    @Test
    func withdrawRemovesPersistentReferencesFlushesFamiliesAndDeletesAnchors() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        try applier.apply(
            KubeProxyCompiler.compile(snapshot: makeDualStackSnapshot(), nodeName: "node-a"),
            podNetwork: KubeProxyFamilyRuleApplication(
                ipv4PodCIDR: "10.250.25.0/24",
                ipv6PodCIDR: "fd42:10:244:19::/64",
                ipv6Ready: true,
                dualStackEnabled: true
            )
        )
        try Data().write(to: argumentsLogURL)

        try applier.withdraw()

        let config = try String(contentsOf: configURL, encoding: .utf8)
        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(!config.contains("anchor \"\(anchorName)\""))
        #expect(!config.contains("anchor \"\(anchorName).ipv6\""))
        #expect(arguments.contains("-a \(anchorName) -F all"))
        #expect(arguments.contains("-a \(anchorName).ipv6 -F all"))
        #expect(!FileManager.default.fileExists(atPath: anchorsURL.appendingPathComponent(anchorName).path))
        #expect(!FileManager.default.fileExists(atPath: anchorsURL.appendingPathComponent("\(anchorName).ipv6").path))
    }

    @Test
    func withdrawIPv6PreservesIPv4PersistentState() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        try "set skip on lo0\n".write(to: configURL, atomically: true, encoding: .utf8)
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7"),
            ipv6EgressResolver: StaticIPv6EgressResolver(),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        try applier.apply(
            KubeProxyCompiler.compile(snapshot: makeDualStackSnapshot(), nodeName: "node-a"),
            podNetwork: KubeProxyFamilyRuleApplication(
                ipv4PodCIDR: "10.250.25.0/24",
                ipv6PodCIDR: "fd42:10:244:19::/64",
                ipv6Ready: true,
                dualStackEnabled: true
            )
        )
        try Data().write(to: argumentsLogURL)

        try applier.withdrawIPv6()

        let config = try String(contentsOf: configURL, encoding: .utf8)
        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(config.contains("rdr-anchor \"\(anchorName)\""))
        #expect(config.contains("load anchor \"\(anchorName)\""))
        #expect(!config.contains("anchor \"\(anchorName).ipv6\""))
        #expect(arguments.contains("-a \(anchorName).ipv6 -F all"))
        #expect(!arguments.contains("-a \(anchorName) -F all"))
        #expect(FileManager.default.fileExists(atPath: anchorsURL.appendingPathComponent(anchorName).path))
        #expect(!FileManager.default.fileExists(atPath: anchorsURL.appendingPathComponent("\(anchorName).ipv6").path))

        try Data().write(to: argumentsLogURL)
        try applier.withdrawIPv6()

        let secondWithdrawalArguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(secondWithdrawalArguments.contains("-a \(anchorName).ipv6 -F all"))
    }

    @Test
    func withdrawIPv6FlushesOrphanedLiveStateWhenDiskStateIsAbsent() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let originalConfig = "set skip on lo0\n"
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: "com.apple.container.kube-proxy.test",
                configPath: configURL.path,
                anchorsPath: directory.appendingPathComponent("anchors").path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        try applier.withdrawIPv6()
        try applier.withdrawIPv6()

        #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(
            arguments.components(separatedBy: .newlines)
                .filter { $0 == "-a com.apple.container.kube-proxy.test.ipv6 -F all" }
                .count == 2
        )
    }

    @Test
    func withdrawRestoresPersistentConfigurationWhenReloadFails() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makePFCTLFailingFirstRootReload(in: directory, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorName = "com.apple.container.kube-proxy.test"
        let ipv4AnchorURL = anchorsURL.appendingPathComponent(anchorName)
        let ipv6AnchorURL = anchorsURL.appendingPathComponent("\(anchorName).ipv6")
        try FileManager.default.createDirectory(at: anchorsURL, withIntermediateDirectories: true)
        let originalConfig = """
            nat-anchor "\(anchorName)"
            rdr-anchor "\(anchorName)"
            rdr-anchor "\(anchorName).ipv6"
            load anchor "\(anchorName)" from "\(ipv4AnchorURL.path)"
            load anchor "\(anchorName).ipv6" from "\(ipv6AnchorURL.path)"

            """
        let originalIPv4Anchor = "# original IPv4 anchor\n"
        let originalIPv6Anchor = "# original IPv6 anchor\n"
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try originalIPv4Anchor.write(to: ipv4AnchorURL, atomically: true, encoding: .utf8)
        try originalIPv6Anchor.write(to: ipv6AnchorURL, atomically: true, encoding: .utf8)
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        #expect(throws: (any Error).self) {
            try applier.withdraw()
        }

        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
        #expect(try String(contentsOf: ipv4AnchorURL, encoding: .utf8) == originalIPv4Anchor)
        #expect(try String(contentsOf: ipv6AnchorURL, encoding: .utf8) == originalIPv6Anchor)
        #expect(arguments.components(separatedBy: .newlines).filter { $0 == "-f \(configURL.path)" }.count == 2)
    }

    @Test
    func withdrawIsIdempotentWhenManagedPFStateIsAlreadyAbsent() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let argumentsLogURL = directory.appendingPathComponent("pfctl-arguments.log")
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0, argumentsLogURL: argumentsLogURL)
        let configURL = directory.appendingPathComponent("pf.conf")
        let originalConfig = "set skip on lo0\n"
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        let anchorName = "com.apple.container.kube-proxy.test"
        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: directory.appendingPathComponent("anchors").path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )

        try applier.withdraw()

        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
        #expect(arguments.contains("-a \(anchorName) -F all"))
        #expect(arguments.contains("-a \(anchorName).ipv6 -F all"))
    }

    @Test
    func usesSharedSystemPFAdvisoryLockPath() {
        #expect(KubeProxyPFCoordination.advisoryLockPath == "/var/run/com.apple.container.pf.lock")
    }

    @Test
    func decodesLegacyPFConfigWithDefaultNetworkSettings() throws {
        let data = Data(
            #"{"anchorName":"test","configPath":"/tmp/pf.conf","anchorsPath":"/tmp/anchors","pfctlPath":"/tmp/pfctl"}"#.utf8
        )
        let config = try JSONDecoder().decode(KubeProxyPFConfig.self, from: data)

        #expect(config.configuredEgressInterface == nil)
        #expect(config.configuredIPv6EgressInterface == nil)
        #expect(config.configuredIPv6EgressSourceAddress == nil)
        #expect(config.resolvedMasqueradeIPv6PodTraffic)
        #expect(config.resolvedVmnetCIDR == "192.168.64.0/24")
    }

    @Test
    func decodesLegacyControllerConfigWithDualStackDisabled() throws {
        let data = Data(
            #"{"kubeconfig":"/tmp/kubeconfig","nodeName":"node-a","pf":{"anchorName":"test","configPath":"/tmp/pf.conf","anchorsPath":"/tmp/anchors","pfctlPath":"/tmp/pfctl"}}"#
                .utf8
        )

        let config = try JSONDecoder().decode(KubeProxyMacOSConfig.self, from: data)

        #expect(config.syncPeriodSeconds == 5)
        #expect(config.dualStackEnabled == false)
        #expect(config.pf.resolvedMasqueradeIPv6PodTraffic)
    }

    @Test
    func rejectsIPv6EgressConfigurationWhenMasqueradeIsDisabled() throws {
        for json in [
            #"{"anchorName":"test","configPath":"/tmp/pf.conf","anchorsPath":"/tmp/anchors","pfctlPath":"/tmp/pfctl","masqueradeIPv6PodTraffic":false,"ipv6EgressInterface":"en7"}"#,
            #"{"anchorName":"test","configPath":"/tmp/pf.conf","anchorsPath":"/tmp/anchors","pfctlPath":"/tmp/pfctl","masqueradeIPv6PodTraffic":false,"ipv6EgressSourceAddress":"2001:db8:100:c::7"}"#,
        ] {
            let config = try JSONDecoder().decode(KubeProxyPFConfig.self, from: Data(json.utf8))

            #expect(!config.resolvedMasqueradeIPv6PodTraffic)
            #expect(
                throws: KubeProxyMacOSError.invalidConfiguration(
                    "pf.masqueradeIPv6PodTraffic=false cannot be combined with pf.ipv6EgressInterface or pf.ipv6EgressSourceAddress"
                )
            ) {
                try config.validate()
            }
        }
    }

    @Test
    func dualStackControllerConfigRequiresPodNetworkStatePaths() {
        let config = KubeProxyMacOSConfig(
            kubeconfig: "/tmp/kubeconfig",
            nodeName: "node-a",
            dualStackEnabled: true
        )

        #expect(
            throws: KubeProxyMacOSError.invalidConfiguration(
                "dualStackEnabled requires pf.runtimeStatePath and pf.readyStatePath"
            )
        ) {
            try config.validate()
        }
    }

    @Test
    func rejectsInvalidVmnetCIDR() {
        let config = KubeProxyPFConfig(vmnetCIDR: "999.168.64.0/24")

        #expect(throws: KubeProxyMacOSError.invalidConfiguration("pf.vmnetCIDR is not a valid IPv4 CIDR")) {
            try config.validate()
        }
    }

    @Test
    func rejectsUnsafePFAnchorNameBeforeRenderingRootConfig() {
        for anchorName in ["", "unsafe anchor", "unsafe\"anchor", "unsafe/anchor", "unsafe\nanchor"] {
            let config = KubeProxyPFConfig(anchorName: anchorName)

            #expect(
                throws: KubeProxyMacOSError.invalidConfiguration(
                    "pf.anchorName is not a valid PF anchor name"
                )
            ) {
                try config.validate()
            }
        }
    }

    @Test
    func requiresRuntimeAndReadyStatePathsTogether() {
        let config = KubeProxyPFConfig(runtimeStatePath: "/var/lib/container/pod-network.json")

        #expect(
            throws: KubeProxyMacOSError.invalidConfiguration("pf.readyStatePath must be an absolute path")
        ) {
            try config.validate()
        }
    }

    @Test
    func controllerUsesCanonicalRuntimePodCIDRInsteadOfStaticCIDR() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writePodNetworkStates(
            in: directory,
            runtimePodCIDR: "10.250.25.42/24",
            readyPodCIDR: "10.250.25.0/24"
        )
        let applier = RecordingRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(runtimeStatePath: paths.runtime.path, readyStatePath: paths.ready.path),
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: applier
        )

        _ = try await controller.runOnce(generation: 1)

        #expect(applier.appliedPodCIDRs == ["10.250.25.0/24"])
        #expect(applier.appliedMasqueradePodTraffic == [true])
    }

    @Test
    func dualStackControllerConsumesV2FamilyReadiness() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writeDualStackPodNetworkStates(in: directory)
        let applier = RecordingFamilyRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(
                runtimeStatePath: paths.runtime.path,
                readyStatePath: paths.ready.path,
                dualStackEnabled: true
            ),
            reader: KubeProxyStaticSnapshotReader(makeDualStackSnapshot()),
            applier: applier
        )

        let result = try await controller.runOnce(generation: 2)

        let application = try #require(applier.applications.first)
        #expect(application.ipv4PodCIDR == "10.250.25.0/24")
        #expect(application.ipv6PodCIDR == "fd42:10:244:19::/64")
        #expect(application.ipv4Ready)
        #expect(application.ipv6Ready)
        #expect(application.dualStackEnabled)
        #expect(application.masqueradeIPv6PodTraffic)
        #expect(Set(result.ruleSet.rules.map(\.family)) == [.ipv4, .ipv6])
    }

    @Test
    func dualStackControllerCanDisableIPv6EgressMasquerade() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writeDualStackPodNetworkStates(in: directory)
        let applier = RecordingFamilyRuleApplier()
        var config = makeControllerConfig(
            runtimeStatePath: paths.runtime.path,
            readyStatePath: paths.ready.path,
            dualStackEnabled: true
        )
        config.pf.masqueradeIPv6PodTraffic = false
        let controller = KubeProxyController(
            config: config,
            reader: KubeProxyStaticSnapshotReader(makeDualStackSnapshot()),
            applier: applier
        )

        _ = try await controller.runOnce(generation: 2)

        #expect(try #require(applier.applications.first).masqueradeIPv6PodTraffic == false)
    }

    @Test
    func dualStackControllerRefreshesIPv4AndMarksIPv6StaleBeforeFailing() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writeDualStackPodNetworkStates(in: directory, ipv6Ready: false)
        let applier = RecordingFamilyRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(
                runtimeStatePath: paths.runtime.path,
                readyStatePath: paths.ready.path,
                dualStackEnabled: true
            ),
            reader: KubeProxyStaticSnapshotReader(makeDualStackSnapshot()),
            applier: applier
        )

        do {
            _ = try await controller.runOnce(generation: 3)
            Issue.record("expected unready IPv6 family to fail")
        } catch {
            #expect(String(describing: error).contains("IPv6 family is not ready"))
        }

        let application = try #require(applier.applications.first)
        let appliedRuleSet = try #require(applier.ruleSets.first)
        #expect(application.ipv4Ready)
        #expect(!application.ipv6Ready)
        #expect(Set(appliedRuleSet.rules.map(\.family)) == [.ipv4])
        #expect(applier.ipv6WithdrawalCount == 1)
    }

    @Test
    func dualStackControllerWithdrawsStaleIPv6BeforeReadingKubernetesSnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writeDualStackPodNetworkStates(in: directory, ipv6Ready: false)
        let applier = RecordingFamilyRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(
                runtimeStatePath: paths.runtime.path,
                readyStatePath: paths.ready.path,
                dualStackEnabled: true
            ),
            reader: FailingSnapshotReader(),
            applier: applier
        )

        do {
            _ = try await controller.runOnce(generation: 4)
            Issue.record("expected Kubernetes snapshot read to fail")
        } catch {
            #expect(String(describing: error).contains("snapshot unavailable"))
        }
        #expect(applier.ipv6WithdrawalCount == 1)
        #expect(applier.applications.isEmpty)
    }

    @Test
    func gateOffControllerDoesNotRequireIPv6WithdrawalBeforeReadingKubernetesSnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writeDualStackPodNetworkStates(in: directory)
        let applier = RecordingFamilyRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(
                runtimeStatePath: paths.runtime.path,
                readyStatePath: paths.ready.path,
                dualStackEnabled: false
            ),
            reader: FailingSnapshotReader(),
            applier: applier
        )

        do {
            _ = try await controller.runOnce(generation: 4)
            Issue.record("expected Kubernetes snapshot read to fail")
        } catch {
            #expect(String(describing: error).contains("snapshot unavailable"))
        }
        #expect(applier.ipv6WithdrawalCount == 0)
        #expect(applier.applications.isEmpty)
    }

    @Test
    func gateOffControllerSupportsLegacyOnlyRuleApplier() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writeDualStackPodNetworkStates(in: directory)
        let applier = LegacyOnlyRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(
                runtimeStatePath: paths.runtime.path,
                readyStatePath: paths.ready.path,
                dualStackEnabled: false
            ),
            reader: KubeProxyStaticSnapshotReader(makeDualStackSnapshot()),
            applier: applier
        )

        let result = try await controller.runOnce(generation: 4)

        #expect(applier.appliedPodCIDRs == ["10.250.25.0/24"])
        #expect(Set(result.ruleSet.rules.map(\.family)) == [.ipv4])
    }

    @Test
    func runForeverRetriesSameGenerationWhenPodIngressRouteBecomesReady() async throws {
        let applier = InitiallyUnavailablePodIngressRouteRuleApplier()
        let results = RecordedKubeProxyRunResults()
        let failures = RecordedKubeProxyErrors()
        let errors = RecordedKubeProxyErrors()
        let controller = KubeProxyController(
            config: KubeProxyMacOSConfig(
                kubeconfig: "/tmp/kubeconfig",
                nodeName: "node-a",
                syncPeriodSeconds: 1,
                pf: KubeProxyPFConfig(vmnetCIDR: "192.168.64.0/24")
            ),
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: applier
        )
        let runTask = Task {
            do {
                try await controller.runForeverReportingResults(
                    onResult: { result in
                        results.append(result)
                    },
                    onFailure: { _, error in
                        failures.append(error)
                    },
                    onError: { error in
                        errors.append(error)
                    }
                )
            } catch is CancellationError {
            } catch {
                Issue.record("runForever must stop only through cancellation: \(error)")
            }
        }

        for _ in 0..<40 {
            if results.values.contains(where: \.applied) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        runTask.cancel()
        await runTask.value

        #expect(applier.applyAttemptCount == 3)
        #expect(applier.successfulApplyCount == 1)
        #expect(applier.attemptedGenerations == [1, 1, 1])
        #expect(results.values.map(\.ruleSet.generation) == [1, 1, 1])
        #expect(results.values.map(\.applied) == [false, false, true])
        #expect(results.values.map(\.pendingFamily) == [.ipv4, .ipv4, nil])
        #expect(failures.messages.isEmpty)
        #expect(errors.messages.count == 1)
        #expect(errors.messages[0].contains("managed PF rules were withdrawn"))
    }

    @Test
    func controllerReturnsPendingOnlyAfterFailClosedWithdrawal() async throws {
        let controller = KubeProxyController(
            config: KubeProxyMacOSConfig(
                kubeconfig: "/tmp/kubeconfig",
                nodeName: "node-a",
                pf: KubeProxyPFConfig(vmnetCIDR: "192.168.64.0/24")
            ),
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: ConfiguredTransitionRuleApplier(
                error: .unavailableAfterWithdrawal(.ipv4)
            )
        )

        let result = try await controller.runOnce(generation: 7)

        #expect(result.ruleSet.generation == 7)
        #expect(!result.applied)
        #expect(result.pendingFamily == .ipv4)
    }

    @Test
    func controllerKeepsNonWithdrawnApplyErrorsHard() async throws {
        let config = KubeProxyMacOSConfig(
            kubeconfig: "/tmp/kubeconfig",
            nodeName: "node-a",
            pf: KubeProxyPFConfig(vmnetCIDR: "192.168.64.0/24")
        )
        let rawRouteError = KubeProxyPodIngressRouteTransitionError.unavailable(.ipv4)
        let rawRouteController = KubeProxyController(
            config: config,
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: ConfiguredTransitionRuleApplier(error: rawRouteError)
        )
        do {
            _ = try await rawRouteController.runOnce(generation: 7)
            Issue.record("expected raw route unavailability to remain a hard error")
        } catch let error as KubeProxyPodIngressRouteTransitionError {
            #expect(error == rawRouteError)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        let applyError = KubeProxyMacOSError.applyFailed("PF apply failed")
        let applyController = KubeProxyController(
            config: config,
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: ConfiguredErrorRuleApplier(error: applyError)
        )
        do {
            _ = try await applyController.runOnce(generation: 7)
            Issue.record("expected PF apply failure to remain a hard error")
        } catch let error as KubeProxyMacOSError {
            #expect(error == applyError)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func dualStackControllerRejectsUnreadyIPv4BeforeApplyingRules() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writeDualStackPodNetworkStates(in: directory, ipv4Ready: false)
        let applier = RecordingFamilyRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(
                runtimeStatePath: paths.runtime.path,
                readyStatePath: paths.ready.path,
                dualStackEnabled: true
            ),
            reader: KubeProxyStaticSnapshotReader(makeDualStackSnapshot()),
            applier: applier
        )

        do {
            _ = try await controller.runOnce(generation: 4)
            Issue.record("expected unready IPv4 family to fail")
        } catch {
            #expect(String(describing: error).contains("IPv4 family is not ready"))
        }
        #expect(applier.applications.isEmpty)
        #expect(applier.withdrawalCount == 1)
    }

    @Test
    func dualStackControllerWithdrawsWhenReadyStateIsMissingExpiredOrMismatched() async throws {
        enum Failure: Equatable {
            case missing
            case expired
            case generationMismatch
        }

        for failure in [Failure.missing, .expired, .generationMismatch] {
            let directory = try makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let paths = try writeDualStackPodNetworkStates(
                in: directory,
                readyGeneration: failure == .generationMismatch ? 2 : 1,
                readyExpiresAtUnixSeconds: failure == .expired
                    ? Int64(Date().timeIntervalSince1970.rounded(.down)) - 1
                    : Int64(Date().timeIntervalSince1970.rounded(.down)) + 300
            )
            if failure == .missing {
                try FileManager.default.removeItem(at: paths.ready)
            }
            let applier = RecordingFamilyRuleApplier()
            let controller = KubeProxyController(
                config: makeControllerConfig(
                    runtimeStatePath: paths.runtime.path,
                    readyStatePath: paths.ready.path,
                    dualStackEnabled: true
                ),
                reader: KubeProxyStaticSnapshotReader(makeDualStackSnapshot()),
                applier: applier
            )

            do {
                _ = try await controller.runOnce(generation: 5)
                Issue.record("expected invalid family readiness to fail")
            } catch {
                #expect(
                    String(describing: error).contains("ready state is missing")
                        || String(describing: error).contains("lease has expired")
                        || String(describing: error).contains("does not match runtime state")
                )
            }
            #expect(applier.withdrawalCount == 1)
            #expect(applier.applications.isEmpty)
        }
    }

    @Test
    func controllerKeepsSourceNATForLegacyVmnetCIDRFallback() async throws {
        let applier = RecordingRuleApplier()
        let controller = KubeProxyController(
            config: KubeProxyMacOSConfig(
                kubeconfig: "/tmp/kubeconfig",
                nodeName: "node-a",
                pf: KubeProxyPFConfig(vmnetCIDR: "192.168.64.42/24")
            ),
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: applier
        )

        _ = try await controller.runOnce(generation: 1)

        #expect(applier.appliedPodCIDRs == ["192.168.64.0/24"])
        #expect(applier.appliedMasqueradePodTraffic == [true])
    }

    @Test
    func controllerRefusesMissingRuntimeStateBeforeApplyingRules() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let applier = RecordingRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(
                runtimeStatePath: directory.appendingPathComponent("missing-runtime.json").path,
                readyStatePath: directory.appendingPathComponent("missing-ready.json").path
            ),
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: applier
        )

        do {
            _ = try await controller.runOnce(generation: 1)
            Issue.record("expected missing runtime state to fail")
        } catch {
            #expect(String(describing: error).contains("runtime state is missing"))
        }
        #expect(applier.appliedPodCIDRs.isEmpty)
        #expect(applier.withdrawalCount == 1)
    }

    @Test
    func controllerRefusesMissingReadyStateBeforeApplyingRules() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writePodNetworkStates(
            in: directory,
            runtimePodCIDR: "10.250.25.0/24",
            readyPodCIDR: "10.250.25.0/24"
        )
        try FileManager.default.removeItem(at: paths.ready)
        let applier = RecordingRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(runtimeStatePath: paths.runtime.path, readyStatePath: paths.ready.path),
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: applier
        )

        do {
            _ = try await controller.runOnce(generation: 1)
            Issue.record("expected missing ready state to fail")
        } catch {
            #expect(String(describing: error).contains("ready state is missing"))
        }
        #expect(applier.appliedPodCIDRs.isEmpty)
        #expect(applier.withdrawalCount == 1)
    }

    @Test
    func controllerRefusesInvalidOrMismatchedReadyStateBeforeApplyingRules() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = try writePodNetworkStates(
            in: directory,
            runtimePodCIDR: "10.250.25.0/24",
            readyPodCIDR: "10.250.26.0/24"
        )
        let applier = RecordingRuleApplier()
        let controller = KubeProxyController(
            config: makeControllerConfig(runtimeStatePath: paths.runtime.path, readyStatePath: paths.ready.path),
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: applier
        )

        do {
            _ = try await controller.runOnce(generation: 1)
            Issue.record("expected mismatched ready state to fail")
        } catch {
            #expect(String(describing: error).contains("ready state does not match runtime state"))
        }
        #expect(applier.appliedPodCIDRs.isEmpty)

        try "not-json".write(to: paths.ready, atomically: true, encoding: .utf8)
        do {
            _ = try await controller.runOnce(generation: 2)
            Issue.record("expected invalid ready state to fail")
        } catch {
            #expect(String(describing: error).contains("ready state is invalid"))
        }
        #expect(applier.appliedPodCIDRs.isEmpty)
        #expect(applier.withdrawalCount == 2)
    }

    @Test
    func controllerRefusesExpiredOrWrongGenerationReadyLease() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let applier = RecordingRuleApplier()
        var paths = try writePodNetworkStates(
            in: directory,
            runtimePodCIDR: "10.250.25.0/24",
            readyPodCIDR: "10.250.25.0/24",
            readyExpiresAtUnixSeconds: Int64(Date().timeIntervalSince1970.rounded(.down)) - 1
        )
        let controller = KubeProxyController(
            config: makeControllerConfig(runtimeStatePath: paths.runtime.path, readyStatePath: paths.ready.path),
            reader: KubeProxyStaticSnapshotReader(makeSnapshot()),
            applier: applier
        )

        do {
            _ = try await controller.runOnce(generation: 1)
            Issue.record("expected expired ready lease to fail")
        } catch {
            #expect(String(describing: error).contains("ready state lease has expired"))
        }
        #expect(applier.appliedPodCIDRs.isEmpty)
        #expect(applier.withdrawalCount == 1)

        paths = try writePodNetworkStates(
            in: directory,
            runtimePodCIDR: "10.250.25.0/24",
            readyPodCIDR: "10.250.25.0/24",
            readyGeneration: 2
        )
        do {
            _ = try await controller.runOnce(generation: 2)
            Issue.record("expected wrong-generation ready lease to fail")
        } catch {
            #expect(String(describing: error).contains("ready state does not match runtime state"))
        }
        #expect(applier.appliedPodCIDRs.isEmpty)
        #expect(applier.withdrawalCount == 2)
    }

    @Test
    func applierRestoresPFConfigAndAnchorWhenValidationFails() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 2)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        let anchorURL = anchorsURL.appendingPathComponent("com.apple.container.kube-proxy.test")
        try FileManager.default.createDirectory(at: anchorsURL, withIntermediateDirectories: true)
        try "original pf config\n".write(to: configURL, atomically: true, encoding: .utf8)
        try "original anchor\n".write(to: anchorURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: "com.apple.container.kube-proxy.test",
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        do {
            try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")
            Issue.record("expected applier.apply to fail")
        } catch {
            #expect(String(describing: error).contains("pfctl validation failed"))
        }

        #expect(try String(contentsOf: configURL, encoding: .utf8) == "original pf config\n")
        #expect(try String(contentsOf: anchorURL, encoding: .utf8) == "original anchor\n")
    }

    @Test
    func applierDrainsLargePFCTLOutputAndReportsFailureDetail() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pfctl = try makeChattyPFCTL(in: directory, exitCode: 2)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        try "original pf config\n".write(to: configURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: "com.apple.container.kube-proxy.test",
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        do {
            try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")
            Issue.record("expected applier.apply to fail")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("pfctl validation failed with status 2"))
            #expect(message.contains("stdout-tail-marker"))
            #expect(message.contains("stderr-tail-marker"))
        }
    }

    @Test
    func applierRequiresPFEnabledBeforeWritingFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pfctl = try makeFakePFCTL(in: directory, exitCode: 0, pfEnabled: false)
        let configURL = directory.appendingPathComponent("pf.conf")
        let anchorsURL = directory.appendingPathComponent("anchors")
        try "original pf config\n".write(to: configURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: "com.apple.container.kube-proxy.test",
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            ),
            podIngressInterfaceResolver: StaticPodIngressInterfaceResolver(),
            advisoryLockPath: directory.appendingPathComponent("pf.lock").path
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        do {
            try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")
            Issue.record("expected applier.apply to fail")
        } catch {
            #expect(String(describing: error).contains("PF is not enabled"))
        }

        #expect(try String(contentsOf: configURL, encoding: .utf8) == "original pf config\n")
        #expect(!FileManager.default.fileExists(atPath: anchorsURL.path))
    }

    @Test
    func parsesTokenKubeconfig() throws {
        let kubeconfig = """
            apiVersion: v1
            clusters:
            - cluster:
                certificate-authority-data: \(Data("ca".utf8).base64EncodedString())
                server: https://127.0.0.1:6443
              name: local
            contexts:
            - context:
                cluster: local
                user: proxy
              name: local
            current-context: local
            users:
            - name: proxy
              user:
                token: test-token
            """

        let config = try KubeProxyKubeconfig.parse(kubeconfig, baseURL: URL(fileURLWithPath: "/tmp"))
        #expect(config.server.absoluteString == "https://127.0.0.1:6443")
        #expect(config.bearerToken == "test-token")
        #expect(config.certificateAuthorityData == Data("ca".utf8))
    }

    @Test
    func honorsCurrentContextAfterContextList() throws {
        let kubeconfig = """
            apiVersion: v1
            clusters:
            - cluster:
                server: https://first.example.invalid
              name: first
            - cluster:
                server: https://second.example.invalid
              name: second
            contexts:
            - context:
                cluster: first
                user: first-user
              name: first
            - context:
                cluster: second
                user: second-user
              name: second
            current-context: second
            users:
            - name: second-user
              user:
                token: second-token
            """

        let config = try KubeProxyKubeconfig.parse(kubeconfig, baseURL: URL(fileURLWithPath: "/tmp"))
        #expect(config.server.absoluteString == "https://second.example.invalid")
        #expect(config.bearerToken == "second-token")
    }

    @Test
    func decodesEmbeddedPEMCertificateAuthorityData() throws {
        let der = Data([0x30, 0x03, 0x02, 0x01, 0x01])
        let pem = """
            -----BEGIN CERTIFICATE-----
            \(der.base64EncodedString())
            -----END CERTIFICATE-----
            """
        let kubeconfig = """
            apiVersion: v1
            clusters:
            - cluster:
                certificate-authority-data: \(Data(pem.utf8).base64EncodedString())
                server: https://127.0.0.1:6443
              name: local
            contexts:
            - context:
                cluster: local
                user: proxy
              name: local
            current-context: local
            users:
            - name: proxy
              user:
                token: test-token
            """

        let config = try KubeProxyKubeconfig.parse(kubeconfig, baseURL: URL(fileURLWithPath: "/tmp"))
        #expect(config.certificateAuthorityData == der)
    }

    @Test
    func refusesToSendKubernetesCredentialsOverPlaintextHTTP() throws {
        let server = try #require(URL(string: "http://127.0.0.1:8080"))
        let config = KubeProxyKubeconfigClientConfig(
            server: server,
            bearerToken: "sensitive-token"
        )

        #expect(
            throws: KubeProxyMacOSError.invalidKubeconfig("Kubernetes API server must use HTTPS")
        ) {
            _ = try KubeProxyKubernetesClient(config: config)
        }
    }

    @Test
    func loadsClientCertificateAndKeyFromCurrentKubeconfigUser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kubeconfig-client-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certificate = Data("client-certificate".utf8)
        let key = Data("client-key".utf8)
        try certificate.write(to: directory.appendingPathComponent("kubelet-client.crt"))
        try key.write(to: directory.appendingPathComponent("kubelet-client.key"))
        let kubeconfig = """
            apiVersion: v1
            clusters:
            - cluster:
                server: https://127.0.0.1:6443
              name: local
            contexts:
            - context:
                cluster: local
                user: kubelet
              name: local
            current-context: local
            users:
            - name: kubelet
              user:
                client-certificate: kubelet-client.crt
                client-key-data: \(key.base64EncodedString())
            """

        let config = try KubeProxyKubeconfig.parse(kubeconfig, baseURL: directory)

        #expect(config.clientCertificateData == certificate)
        #expect(config.clientKeyData == key)
    }

    private func makeSnapshot(
        serviceType: String = "ClusterIP",
        internalTrafficPolicy: KubeProxyInternalTrafficPolicy? = nil,
        endpoints: [KubeProxyEndpoint] = [
            KubeProxyEndpoint(addresses: ["192.168.65.10"], conditions: .init(ready: true), nodeName: "node-a"),
            KubeProxyEndpoint(addresses: ["192.168.65.11"], conditions: .init(ready: true), nodeName: "node-a"),
        ]
    ) -> KubeProxySnapshot {
        KubeProxySnapshot(
            services: [makeService(serviceType: serviceType, internalTrafficPolicy: internalTrafficPolicy)],
            endpointSlices: [makeEndpointSlice(endpoints: endpoints)]
        )
    }

    private func makeDualStackSnapshot() -> KubeProxySnapshot {
        KubeProxySnapshot(
            services: [
                makeService(
                    clusterIPs: ["10.96.0.42", "fd42:10:96::42"],
                    ipFamilies: ["IPv4", "IPv6"]
                )
            ],
            endpointSlices: [
                makeEndpointSlice(
                    endpoints: [
                        KubeProxyEndpoint(
                            addresses: ["10.250.25.10"],
                            conditions: .init(ready: true),
                            nodeName: "node-a"
                        )
                    ]
                ),
                makeEndpointSlice(
                    name: "echo-v6",
                    addressType: "IPv6",
                    endpoints: [
                        KubeProxyEndpoint(
                            addresses: ["fd42:10:244:19::10"],
                            conditions: .init(ready: true),
                            nodeName: "node-a"
                        )
                    ]
                ),
            ]
        )
    }

    private func makeService(
        serviceType: String = "ClusterIP",
        internalTrafficPolicy: KubeProxyInternalTrafficPolicy? = nil,
        clusterIPs: [String] = ["10.96.0.42"],
        ipFamilies: [String] = ["IPv4"]
    ) -> KubeProxyService {
        KubeProxyService(
            metadata: KubeProxyObjectMeta(namespace: "default", name: "echo", uid: "svc-echo"),
            spec: KubeProxyServiceSpec(
                type: serviceType,
                clusterIP: clusterIPs.first,
                clusterIPs: clusterIPs,
                ipFamilies: ipFamilies,
                internalTrafficPolicy: internalTrafficPolicy,
                ports: [
                    KubeProxyServicePort(
                        name: "http",
                        protocolName: .tcp,
                        port: 80,
                        targetPort: .string("http")
                    )
                ]
            )
        )
    }

    private func makeEndpointSlice(
        name: String = "echo-abc",
        port: Int = 8080,
        addressType: String = "IPv4",
        endpoints: [KubeProxyEndpoint]
    ) -> KubeProxyEndpointSlice {
        KubeProxyEndpointSlice(
            metadata: KubeProxyObjectMeta(
                namespace: "default",
                name: name,
                labels: ["kubernetes.io/service-name": "echo"]
            ),
            addressType: addressType,
            endpoints: endpoints,
            ports: [
                KubeProxyEndpointPort(name: "http", protocolName: .tcp, port: port)
            ]
        )
    }

    private func makeControllerConfig(
        runtimeStatePath: String,
        readyStatePath: String,
        dualStackEnabled: Bool = false
    ) -> KubeProxyMacOSConfig {
        KubeProxyMacOSConfig(
            kubeconfig: "/tmp/kubeconfig",
            nodeName: "node-a",
            dualStackEnabled: dualStackEnabled,
            pf: KubeProxyPFConfig(
                vmnetCIDR: "192.168.64.0/24",
                runtimeStatePath: runtimeStatePath,
                readyStatePath: readyStatePath
            )
        )
    }

    private func writePodNetworkStates(
        in directory: URL,
        runtimePodCIDR: String,
        readyPodCIDR: String,
        readyGeneration: UInt64 = 1,
        readyExpiresAtUnixSeconds: Int64 = Int64(Date().timeIntervalSince1970.rounded(.down)) + 300
    ) throws -> (runtime: URL, ready: URL) {
        let runtimeURL = directory.appendingPathComponent("runtime.json")
        let readyURL = directory.appendingPathComponent("ready.json")
        let runtimeData = try JSONSerialization.data(withJSONObject: [
            "networkName": "kubernetes-pod",
            "podCIDR": runtimePodCIDR,
            "generation": 1,
            "updatedAt": "2026-08-02T00:00:00Z",
        ])
        let readyData = try JSONSerialization.data(withJSONObject: [
            "networkName": "kubernetes-pod",
            "podCIDR": readyPodCIDR,
            "runtimeGeneration": readyGeneration,
            "expiresAtUnixSeconds": readyExpiresAtUnixSeconds,
        ])
        try runtimeData.write(to: runtimeURL, options: .atomic)
        try readyData.write(to: readyURL, options: .atomic)
        return (runtimeURL, readyURL)
    }

    private func writeDualStackPodNetworkStates(
        in directory: URL,
        ipv4Ready: Bool = true,
        ipv6Ready: Bool = true,
        readyGeneration: UInt64 = 1,
        readyExpiresAtUnixSeconds: Int64 = Int64(Date().timeIntervalSince1970.rounded(.down)) + 300
    ) throws -> (runtime: URL, ready: URL) {
        let runtimeURL = directory.appendingPathComponent("runtime-v2.json")
        let readyURL = directory.appendingPathComponent("ready-v2.json")
        let podCIDRs: [String: Any] = [
            "ipv4": "10.250.25.42/24",
            "ipv6": "fd42:10:244:19::42/64",
        ]
        let runtimeData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "networkName": "kubernetes-pod",
            "podCIDR": "10.250.25.0/24",
            "podCIDRs": podCIDRs,
            "generation": 1,
            "updatedAt": "2026-08-02T00:00:00Z",
        ])
        let readyData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "networkName": "kubernetes-pod",
            "podCIDR": "10.250.25.0/24",
            "podCIDRs": [
                "ipv4": "10.250.25.0/24",
                "ipv6": "fd42:10:244:19::/64",
            ],
            "ipv4Ready": ipv4Ready,
            "ipv6Ready": ipv6Ready,
            "runtimeGeneration": readyGeneration,
            "mtu": 1450,
            "expiresAtUnixSeconds": readyExpiresAtUnixSeconds,
        ])
        try runtimeData.write(to: runtimeURL, options: .atomic)
        try readyData.write(to: readyURL, options: .atomic)
        return (runtimeURL, readyURL)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-kube-proxy-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFakePFCTL(
        in directory: URL,
        exitCode: Int32,
        pfEnabled: Bool = true,
        argumentsLogURL: URL? = nil
    ) throws -> URL {
        let url = directory.appendingPathComponent("pfctl")
        let pfStatus = pfEnabled ? "Enabled" : "Disabled"
        let logArguments = argumentsLogURL.map { "echo \"$*\" >> \"\($0.path)\"" } ?? ":"
        let script = """
            #!/bin/sh
            \(logArguments)
            if [ "$1" = "-s" ] && [ "$2" = "info" ]; then
              echo "Status: \(pfStatus)"
              exit 0
            fi
            exit \(exitCode)
            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeChattyPFCTL(in directory: URL, exitCode: Int32) throws -> URL {
        let url = directory.appendingPathComponent("pfctl-chatty")
        let script = """
            #!/bin/sh
            emit_large_output() {
              /usr/bin/awk 'BEGIN { for (i = 0; i < 4096; i++) print "stdout-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }'
              echo "stdout-tail-marker"
              /usr/bin/awk 'BEGIN { for (i = 0; i < 4096; i++) print "stderr-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }' >&2
              echo "stderr-tail-marker" >&2
            }
            emit_large_output
            if [ "$1" = "-s" ] && [ "$2" = "info" ]; then
              echo "Status: Enabled"
              exit 0
            fi
            exit \(exitCode)
            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makePFCTLFailingFirstRootReload(in directory: URL, argumentsLogURL: URL) throws -> URL {
        let url = directory.appendingPathComponent("pfctl-fail-first-root-reload")
        let failedMarkerURL = directory.appendingPathComponent("failed-root-reload")
        let script = """
            #!/bin/sh
            echo "$*" >> "\(argumentsLogURL.path)"
            if [ "$1" = "-s" ] && [ "$2" = "info" ]; then
              echo "Status: Enabled"
              exit 0
            fi
            if [ "$1" = "-n" ]; then
              exit 0
            fi
            if [ "$1" = "-f" ] && [ ! -f "\(failedMarkerURL.path)" ]; then
              /usr/bin/touch "\(failedMarkerURL.path)"
              exit 2
            fi
            exit 0
            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makePFCTLFailingFirstAnchorReload(in directory: URL, argumentsLogURL: URL) throws -> URL {
        let url = directory.appendingPathComponent("pfctl-fail-first-anchor-reload")
        let failureMarkerURL = directory.appendingPathComponent("failed-anchor-reload")
        let script = """
            #!/bin/sh
            echo "$*" >> "\(argumentsLogURL.path)"
            if [ "$1" = "-s" ] && [ "$2" = "info" ]; then
              echo "Status: Enabled"
              exit 0
            fi
            if [ "$1" = "-n" ]; then
              exit 0
            fi
            if [ "$1" = "-a" ] && [ "$3" = "-f" ] && [ ! -f "\(failureMarkerURL.path)" ]; then
              /usr/bin/touch "\(failureMarkerURL.path)"
              echo "child reload failed" >&2
              exit 2
            fi
            exit 0
            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makePFCTLFailingIPv6ReloadAndIPv4Rollback(
        in directory: URL,
        anchorName: String,
        argumentsLogURL: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("pfctl-fail-ipv6-reload-and-ipv4-rollback")
        let ipv4LoadedMarkerURL = directory.appendingPathComponent("ipv4-anchor-loaded")
        let ipv6FailedMarkerURL = directory.appendingPathComponent("ipv6-anchor-failed")
        let script = """
            #!/bin/sh
            echo "$*" >> "\(argumentsLogURL.path)"
            if [ "$1" = "-s" ] && [ "$2" = "info" ]; then
              echo "Status: Enabled"
              exit 0
            fi
            if [ "$1" = "-n" ]; then
              exit 0
            fi
            if [ "$1" = "-a" ] && [ "$2" = "\(anchorName)" ] && [ "$3" = "-f" ]; then
              if [ -f "\(ipv4LoadedMarkerURL.path)" ]; then
                echo "IPv4 rollback failed" >&2
                exit 23
              fi
              /usr/bin/touch "\(ipv4LoadedMarkerURL.path)"
              exit 0
            fi
            if [ "$1" = "-a" ] && [ "$2" = "\(anchorName).ipv6" ] && [ "$3" = "-f" ]; then
              if [ ! -f "\(ipv6FailedMarkerURL.path)" ]; then
                /usr/bin/touch "\(ipv6FailedMarkerURL.path)"
                echo "IPv6 reload failed" >&2
                exit 22
              fi
              exit 0
            fi
            exit 0
            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private struct StaticEgressInterfaceResolver: KubeProxyEgressInterfaceResolving {
    var interface: String

    func resolveDefaultIPv4EgressInterface() throws -> String {
        interface
    }
}

private struct StaticIPv6EgressResolver: KubeProxyIPv6EgressResolving {
    var interfaceName = "en7"
    var sourceAddress = "2001:db8:100:c:203:0:113:208"

    func resolveIPv6Egress(
        configuredInterface: String?,
        configuredSourceAddress: String?
    ) throws -> KubeProxyIPv6Egress {
        KubeProxyIPv6Egress(
            interfaceName: configuredInterface ?? interfaceName,
            sourceAddress: configuredSourceAddress ?? sourceAddress
        )
    }
}

private struct StaticPodIngressInterfaceResolver: KubeProxyPodIngressInterfaceResolving {
    var ipv4Interface = "bridge100"
    var ipv6Interface = "bridge100"

    func resolvePodIngressInterface(
        family: KubeProxyAddressFamily,
        podCIDR: String
    ) throws -> String {
        switch family {
        case .ipv4:
            ipv4Interface
        case .ipv6:
            ipv6Interface
        }
    }
}

private struct UnavailablePodIngressInterfaceResolver: KubeProxyPodIngressInterfaceResolving {
    var failingFamily: KubeProxyAddressFamily

    func resolvePodIngressInterface(
        family: KubeProxyAddressFamily,
        podCIDR: String
    ) throws -> String {
        guard family != failingFamily else {
            throw KubeProxyMacOSError.applyFailed("Pod ingress bridge is not ready")
        }
        return "bridge100"
    }
}

private struct UnavailablePodIngressRouteResolver: KubeProxyPodIngressInterfaceResolving {
    var failingFamily: KubeProxyAddressFamily

    func resolvePodIngressInterface(
        family: KubeProxyAddressFamily,
        podCIDR: String
    ) throws -> String {
        guard family != failingFamily else {
            throw KubeProxyPodIngressRouteTransitionError.unavailable(family)
        }
        return "bridge100"
    }
}

private struct FailingSnapshotReader: KubeProxyKubernetesReading {
    func snapshot() async throws -> KubeProxySnapshot {
        throw KubeProxyMacOSError.applyFailed("snapshot unavailable")
    }
}

private final class LegacyOnlyRuleApplier: KubeProxyRuleApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var podCIDRs: [String] = []

    var appliedPodCIDRs: [String] {
        lock.withLock { podCIDRs }
    }

    func apply(
        _ ruleSet: KubeProxyRuleSet,
        localPodCIDR: String,
        masqueradePodTraffic: Bool
    ) throws {
        lock.withLock {
            podCIDRs.append(localPodCIDR)
        }
    }
}

private struct ConfiguredErrorRuleApplier: KubeProxyRuleApplying {
    var error: KubeProxyMacOSError

    func apply(
        _ ruleSet: KubeProxyRuleSet,
        localPodCIDR: String,
        masqueradePodTraffic: Bool
    ) throws {
        throw error
    }
}

private struct ConfiguredTransitionRuleApplier: KubeProxyRuleApplying {
    var error: KubeProxyPodIngressRouteTransitionError

    func apply(
        _ ruleSet: KubeProxyRuleSet,
        localPodCIDR: String,
        masqueradePodTraffic: Bool
    ) throws {
        throw error
    }
}

private final class InitiallyUnavailablePodIngressRouteRuleApplier: KubeProxyRuleApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var successes = 0
    private var generations: [Int] = []

    var applyAttemptCount: Int {
        lock.withLock { attempts }
    }

    var successfulApplyCount: Int {
        lock.withLock { successes }
    }

    var attemptedGenerations: [Int] {
        lock.withLock { generations }
    }

    func apply(
        _ ruleSet: KubeProxyRuleSet,
        localPodCIDR: String,
        masqueradePodTraffic: Bool
    ) throws {
        let bridgeIsReady = lock.withLock { () -> Bool in
            attempts += 1
            generations.append(ruleSet.generation)
            guard attempts > 2 else {
                return false
            }
            successes += 1
            return true
        }
        guard bridgeIsReady else {
            throw KubeProxyPodIngressRouteTransitionError.unavailableAfterWithdrawal(.ipv4)
        }
    }
}

private final class RecordedKubeProxyRunResults: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [KubeProxyRunResult] = []

    var values: [KubeProxyRunResult] {
        lock.withLock { recordedValues }
    }

    func append(_ result: KubeProxyRunResult) {
        lock.withLock {
            recordedValues.append(result)
        }
    }
}

private final class RecordedKubeProxyErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var messages: [String] {
        lock.withLock { values }
    }

    func append(_ error: any Error) {
        lock.withLock {
            values.append(String(describing: error))
        }
    }
}

private final class RecordingRuleApplier: KubeProxyRuleApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var podCIDRs: [String] = []
    private var masqueradePodTrafficValues: [Bool] = []
    private var recordedWithdrawalCount = 0
    private var recordedIPv6WithdrawalCount = 0

    var appliedPodCIDRs: [String] {
        lock.withLock { podCIDRs }
    }

    var appliedMasqueradePodTraffic: [Bool] {
        lock.withLock { masqueradePodTrafficValues }
    }

    var withdrawalCount: Int {
        lock.withLock { recordedWithdrawalCount }
    }

    var ipv6WithdrawalCount: Int {
        lock.withLock { recordedIPv6WithdrawalCount }
    }

    func apply(
        _ ruleSet: KubeProxyRuleSet,
        localPodCIDR: String,
        masqueradePodTraffic: Bool
    ) throws {
        lock.withLock {
            podCIDRs.append(localPodCIDR)
            masqueradePodTrafficValues.append(masqueradePodTraffic)
        }
    }

    func withdraw() throws {
        lock.withLock {
            recordedWithdrawalCount += 1
        }
    }

    func withdrawIPv6() throws {
        lock.withLock {
            recordedIPv6WithdrawalCount += 1
        }
    }
}

private final class RecordingFamilyRuleApplier: KubeProxyRuleApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRuleSets: [KubeProxyRuleSet] = []
    private var recordedApplications: [KubeProxyFamilyRuleApplication] = []
    private var recordedWithdrawalCount = 0
    private var recordedIPv6WithdrawalCount = 0

    var ruleSets: [KubeProxyRuleSet] {
        lock.withLock { recordedRuleSets }
    }

    var applications: [KubeProxyFamilyRuleApplication] {
        lock.withLock { recordedApplications }
    }

    var withdrawalCount: Int {
        lock.withLock { recordedWithdrawalCount }
    }

    var ipv6WithdrawalCount: Int {
        lock.withLock { recordedIPv6WithdrawalCount }
    }

    func apply(
        _ ruleSet: KubeProxyRuleSet,
        localPodCIDR: String,
        masqueradePodTraffic: Bool
    ) throws {
        throw KubeProxyMacOSError.unsupported("legacy apply was not expected")
    }

    func apply(
        _ ruleSet: KubeProxyRuleSet,
        podNetwork: KubeProxyFamilyRuleApplication
    ) throws {
        lock.withLock {
            recordedRuleSets.append(ruleSet)
            recordedApplications.append(podNetwork)
        }
    }

    func withdraw() throws {
        lock.withLock {
            recordedWithdrawalCount += 1
        }
    }

    func withdrawIPv6() throws {
        lock.withLock {
            recordedIPv6WithdrawalCount += 1
        }
    }
}
