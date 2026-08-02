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
        let anchor = try KubeProxyPFRenderer.renderAnchor(ruleSet: ruleSet, localPodCIDR: "10.250.25.0/24")

        #expect(anchor.contains("# generation: 7"))
        #expect(anchor.contains("# local PodCIDR: 10.250.25.0/24"))
        #expect(anchor.contains("table <ckp_default_echo_http_tcp_80> persist { 192.168.65.10, 192.168.65.11 }"))
        #expect(!anchor.contains("nat on"))
        #expect(anchor.contains("rdr pass inet proto tcp from any to 10.96.0.42 port 80 -> <ckp_default_echo_http_tcp_80> port 8080 round-robin"))
    }

    @Test
    func rendersPodEgressNATOnlyOnConfiguredInterface() throws {
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")
        let anchor = try KubeProxyPFRenderer.renderAnchor(
            ruleSet: ruleSet,
            localPodCIDR: "192.168.64.0/24",
            masqueradePodTraffic: true,
            egressInterface: "en7"
        )

        #expect(anchor.contains("nat on en7 inet from 192.168.64.0/24 to any -> (en7)"))
        #expect(!anchor.contains("nat on utun"))
        #expect(anchor.contains("rdr pass inet proto tcp from any to 10.96.0.42 port 80"))
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
        #expect(tableName.hasPrefix("ckp_default_kubernet_"))
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
        try """
        set skip on lo0
        nat-anchor "com.apple.container.kube-proxy.test"

        """.write(to: configURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: "com.apple.container.kube-proxy.test",
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            )
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")

        let config = try String(contentsOf: configURL, encoding: .utf8)
        let anchorURL = anchorsURL.appendingPathComponent("com.apple.container.kube-proxy.test")
        let anchor = try String(contentsOf: anchorURL, encoding: .utf8)
        #expect(!config.contains("nat-anchor \"com.apple.container.kube-proxy.test\""))
        #expect(config.contains("rdr-anchor \"com.apple.container.kube-proxy.test\""))
        #expect(config.contains("load anchor \"com.apple.container.kube-proxy.test\" from \"\(anchorURL.path)\""))
        #expect(anchor.contains("# local PodCIDR: 10.250.25.0/24"))
        #expect(!anchor.contains("nat on"))
        #expect(anchor.contains("rdr pass inet proto tcp from any to 10.96.0.42 port 80 -> <ckp_default_echo_http_tcp_80> port 8080 round-robin"))
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
            egressInterfaceResolver: StaticEgressInterfaceResolver(interface: "en7")
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
    func applierReloadsGlobalPFConfigOnlyWhenAnchorReferencesChange() throws {
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
            )
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")
        try applier.apply(ruleSet, localPodCIDR: "10.250.25.0/24")

        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        let anchorURL = anchorsURL.appendingPathComponent(anchorName)
        #expect(arguments.filter { $0 == "-f \(configURL.path)" }.count == 1)
        #expect(arguments.filter { $0 == "-a \(anchorName) -f \(anchorURL.path)" }.count == 1)
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
          rdr-anchor "\(anchorName)"
          load anchor "\(anchorName)" from "\(anchorURL.path)"

        """.write(to: configURL, atomically: true, encoding: .utf8)

        let applier = KubeProxyPFRuleApplier(
            config: KubeProxyPFConfig(
                anchorName: anchorName,
                configPath: configURL.path,
                anchorsPath: anchorsURL.path,
                pfctlPath: pfctl.path
            )
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
            )
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
    func decodesLegacyPFConfigWithDefaultNetworkSettings() throws {
        let data = Data(
            #"{"anchorName":"test","configPath":"/tmp/pf.conf","anchorsPath":"/tmp/anchors","pfctlPath":"/tmp/pfctl"}"#.utf8
        )
        let config = try JSONDecoder().decode(KubeProxyPFConfig.self, from: data)

        #expect(config.configuredEgressInterface == nil)
        #expect(config.resolvedVmnetCIDR == "192.168.64.0/24")
    }

    @Test
    func rejectsInvalidVmnetCIDR() {
        let config = KubeProxyPFConfig(vmnetCIDR: "999.168.64.0/24")

        #expect(throws: KubeProxyMacOSError.invalidConfiguration("pf.vmnetCIDR is not a valid IPv4 CIDR")) {
            try config.validate()
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
            )
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
            )
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

    private func makeService(
        serviceType: String = "ClusterIP",
        internalTrafficPolicy: KubeProxyInternalTrafficPolicy? = nil
    ) -> KubeProxyService {
        KubeProxyService(
            metadata: KubeProxyObjectMeta(namespace: "default", name: "echo", uid: "svc-echo"),
            spec: KubeProxyServiceSpec(
                type: serviceType,
                clusterIP: "10.96.0.42",
                clusterIPs: ["10.96.0.42"],
                ipFamilies: ["IPv4"],
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
        endpoints: [KubeProxyEndpoint]
    ) -> KubeProxyEndpointSlice {
        KubeProxyEndpointSlice(
            metadata: KubeProxyObjectMeta(
                namespace: "default",
                name: name,
                labels: ["kubernetes.io/service-name": "echo"]
            ),
            endpoints: endpoints,
            ports: [
                KubeProxyEndpointPort(name: "http", protocolName: .tcp, port: port)
            ]
        )
    }

    private func makeControllerConfig(runtimeStatePath: String, readyStatePath: String) -> KubeProxyMacOSConfig {
        KubeProxyMacOSConfig(
            kubeconfig: "/tmp/kubeconfig",
            nodeName: "node-a",
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
}

private struct StaticEgressInterfaceResolver: KubeProxyEgressInterfaceResolving {
    var interface: String

    func resolveDefaultIPv4EgressInterface() throws -> String {
        interface
    }
}

private final class RecordingRuleApplier: KubeProxyRuleApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var podCIDRs: [String] = []
    private var masqueradePodTrafficValues: [Bool] = []

    var appliedPodCIDRs: [String] {
        lock.withLock { podCIDRs }
    }

    var appliedMasqueradePodTraffic: [Bool] {
        lock.withLock { masqueradePodTrafficValues }
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
}
