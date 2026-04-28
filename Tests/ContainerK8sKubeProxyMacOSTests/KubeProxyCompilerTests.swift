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
    func skipsRemoteAndNotReadyEndpoints() throws {
        let snapshot = makeSnapshot(
            endpoints: [
                KubeProxyEndpoint(addresses: ["192.168.65.10"], conditions: .init(ready: true), nodeName: "node-a"),
                KubeProxyEndpoint(addresses: ["192.168.65.20"], conditions: .init(ready: true), nodeName: "node-b"),
                KubeProxyEndpoint(addresses: ["192.168.65.30"], conditions: .init(ready: false), nodeName: "node-a"),
            ]
        )

        let ruleSet = KubeProxyCompiler.compile(snapshot: snapshot, nodeName: "node-a")
        let rule = try #require(ruleSet.rules.first)
        #expect(rule.backends == [KubeProxyBackend(ip: "192.168.65.10", port: 8080)])
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
        let anchor = KubeProxyPFRenderer.renderAnchor(ruleSet: ruleSet)

        #expect(anchor.contains("# generation: 7"))
        #expect(anchor.contains("table <ckp_default_echo_http_tcp_80> persist { 192.168.65.10, 192.168.65.11 }"))
        #expect(anchor.contains("rdr pass inet proto tcp from any to 10.96.0.42 port 80 -> <ckp_default_echo_http_tcp_80> port 8080 round-robin"))
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
            )
        )
        let ruleSet = KubeProxyCompiler.compile(snapshot: makeSnapshot(), nodeName: "node-a")

        try applier.apply(ruleSet)

        let config = try String(contentsOf: configURL, encoding: .utf8)
        let anchorURL = anchorsURL.appendingPathComponent("com.apple.container.kube-proxy.test")
        let anchor = try String(contentsOf: anchorURL, encoding: .utf8)
        #expect(config.contains("rdr-anchor \"com.apple.container.kube-proxy.test\""))
        #expect(config.contains("load anchor \"com.apple.container.kube-proxy.test\" from \"\(anchorURL.path)\""))
        #expect(anchor.contains("rdr pass inet proto tcp from any to 10.96.0.42 port 80 -> <ckp_default_echo_http_tcp_80> port 8080 round-robin"))
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
            try applier.apply(ruleSet)
            Issue.record("expected applier.apply to fail")
        } catch {
            #expect(String(describing: error).contains("pfctl validation failed"))
        }

        #expect(try String(contentsOf: configURL, encoding: .utf8) == "original pf config\n")
        #expect(try String(contentsOf: anchorURL, encoding: .utf8) == "original anchor\n")
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

    private func makeSnapshot(
        endpoints: [KubeProxyEndpoint] = [
            KubeProxyEndpoint(addresses: ["192.168.65.10"], conditions: .init(ready: true), nodeName: "node-a"),
            KubeProxyEndpoint(addresses: ["192.168.65.11"], conditions: .init(ready: true), nodeName: "node-a"),
        ]
    ) -> KubeProxySnapshot {
        KubeProxySnapshot(
            services: [makeService()],
            endpointSlices: [makeEndpointSlice(endpoints: endpoints)]
        )
    }

    private func makeService() -> KubeProxyService {
        KubeProxyService(
            metadata: KubeProxyObjectMeta(namespace: "default", name: "echo", uid: "svc-echo"),
            spec: KubeProxyServiceSpec(
                type: "ClusterIP",
                clusterIP: "10.96.0.42",
                clusterIPs: ["10.96.0.42"],
                ipFamilies: ["IPv4"],
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-kube-proxy-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFakePFCTL(in directory: URL, exitCode: Int32) throws -> URL {
        let url = directory.appendingPathComponent("pfctl")
        let script = """
            #!/bin/sh
            exit \(exitCode)
            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
