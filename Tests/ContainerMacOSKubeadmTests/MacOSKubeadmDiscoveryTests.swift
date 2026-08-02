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

@Suite(.serialized)
struct MacOSKubeadmDiscoveryTests {
    @Test func nodeAbsentUsesFreshFlannelTokenAfterAnonymousPinnedDiscovery() throws {
        MockKubernetesAPIURLProtocol.reset()
        let client = MacOSKubeadmDiscoveryClient(sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockKubernetesAPIURLProtocol.self]
            return configuration
        })

        let discovered = try client.discover(
            apiServer: #require(URL(string: "https://cluster.example:6443")),
            nodeName: "macos-ci-1",
            networkMode: .full,
            token: "abcdef.0123456789abcdef",
            expectedCACertHashes: [testCACertHash],
            log: MacOSKubeadmLog()
        )

        #expect(discovered.clusterDNS == "10.96.0.53")
        #expect(discovered.clusterDomain == "cluster.local")
        #expect(discovered.kubeProxyToken == "proxy-token")
        #expect(discovered.flannelToken == "flannel-token")

        let requests = MockKubernetesAPIURLProtocol.recordedRequests()
        let clusterInfoRequest = try #require(
            requests.first { $0.path == "/api/v1/namespaces/kube-public/configmaps/cluster-info" })
        #expect(clusterInfoRequest.method == "GET")
        #expect(clusterInfoRequest.authorization == nil)

        let kubeletConfigRequest = try #require(
            requests.first { $0.path == "/api/v1/namespaces/kube-system/configmaps/kubelet-config" })
        #expect(kubeletConfigRequest.method == "GET")
        #expect(kubeletConfigRequest.authorization == "Bearer abcdef.0123456789abcdef")

        let kubeProxyTokenRequest = try #require(
            requests.first { $0.path == "/api/v1/namespaces/kube-system/serviceaccounts/kube-proxy-macos/token" })
        #expect(kubeProxyTokenRequest.method == "POST")
        #expect(kubeProxyTokenRequest.authorization == "Bearer abcdef.0123456789abcdef")
        let tokenRequest = try #require(
            JSONSerialization.jsonObject(with: kubeProxyTokenRequest.body ?? Data()) as? [String: Any]
        )
        let tokenRequestSpec = try #require(tokenRequest["spec"] as? [String: Any])
        #expect(tokenRequestSpec["audiences"] == nil)
        #expect(tokenRequestSpec["expirationSeconds"] as? Int == 86_400)

        let flannelTokenRequest = try #require(
            requests.first { $0.path == "/api/v1/namespaces/kube-system/serviceaccounts/flannel-macos/token" })
        #expect(flannelTokenRequest.method == "POST")
        #expect(flannelTokenRequest.authorization == "Bearer abcdef.0123456789abcdef")

        let nodeRequest = try #require(requests.first { $0.path == "/api/v1/nodes/macos-ci-1" })
        #expect(nodeRequest.method == "GET")
        #expect(nodeRequest.authorization == "Bearer flannel-token")
    }

    @Test func rejectsHTTPEntryEndpointBeforeAnyRequest() throws {
        MockKubernetesAPIURLProtocol.reset()
        let client = MacOSKubeadmDiscoveryClient(sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockKubernetesAPIURLProtocol.self]
            return configuration
        })

        #expect(
            throws: MacOSKubeadmError.invalidInput("Kubernetes API server endpoint must use HTTPS")
        ) {
            try client.discover(
                apiServer: #require(URL(string: "http://cluster.example:6443")),
                nodeName: "macos-ci-1",
                networkMode: .full,
                token: "abcdef.0123456789abcdef",
                expectedCACertHashes: [testCACertHash],
                log: MacOSKubeadmLog()
            )
        }
        #expect(MockKubernetesAPIURLProtocol.recordedRequests().isEmpty)
    }

    @Test func rejectsInvalidNodeNameBeforeAnyRequest() throws {
        MockKubernetesAPIURLProtocol.reset()
        let client = makeDiscoveryClient()

        #expect(
            throws: MacOSKubeadmError.invalidInput(
                "--node-name may only contain letters, numbers, '.', '_', and '-'"
            )
        ) {
            try client.discover(
                apiServer: #require(URL(string: "https://cluster.example:6443")),
                nodeName: "nodes/other",
                networkMode: .full,
                token: "abcdef.0123456789abcdef",
                expectedCACertHashes: [testCACertHash],
                log: MacOSKubeadmLog()
            )
        }
        #expect(MockKubernetesAPIURLProtocol.recordedRequests().isEmpty)
    }

    @Test func rejectsHTTPDiscoveredServerBeforeAnyAuthorizedRequest() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setClusterServer("http://cluster.example:6443")
        let client = MacOSKubeadmDiscoveryClient(sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockKubernetesAPIURLProtocol.self]
            return configuration
        })

        #expect(
            throws: MacOSKubeadmError.preflightFailed(
                "cluster-info kubeconfig cluster.server must use HTTPS"
            )
        ) {
            try client.discover(
                apiServer: #require(URL(string: "https://cluster.example:6443")),
                nodeName: "macos-ci-1",
                networkMode: .full,
                token: "abcdef.0123456789abcdef",
                expectedCACertHashes: [testCACertHash],
                log: MacOSKubeadmLog()
            )
        }

        let requests = MockKubernetesAPIURLProtocol.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].path == "/api/v1/namespaces/kube-public/configmaps/cluster-info")
        #expect(requests[0].authorization == nil)
    }

    @Test func fullNetworkDiscoveryRequiresClusterProvidedDNSSettings() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setKubeletConfig(
            """
            clusterDNS:
            - fd42:10:96::53
            clusterDomain: cluster.local
            """
        )
        let client = MacOSKubeadmDiscoveryClient(sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockKubernetesAPIURLProtocol.self]
            return configuration
        })

        #expect(
            throws: MacOSKubeadmError.preflightFailed(
                "kube-system/kubelet-config does not contain a usable IPv4 clusterDNS and clusterDomain"
            )
        ) {
            try client.discover(
                apiServer: #require(URL(string: "https://cluster.example:6443")),
                nodeName: "macos-ci-1",
                networkMode: .full,
                token: "abcdef.0123456789abcdef",
                expectedCACertHashes: [testCACertHash],
                log: MacOSKubeadmLog()
            )
        }
    }

    @Test func fullNetworkDiscoverySelectsIPv4DNSFromDualStackList() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setKubeletConfig(
            """
            clusterDNS:
            - fd42:10:96::53
            - 10.96.0.53
            clusterDomain: cluster.local
            """
        )
        let client = MacOSKubeadmDiscoveryClient(sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockKubernetesAPIURLProtocol.self]
            return configuration
        })

        let discovered = try client.discover(
            apiServer: #require(URL(string: "https://cluster.example:6443")),
            nodeName: "macos-ci-1",
            networkMode: .full,
            token: "abcdef.0123456789abcdef",
            expectedCACertHashes: [testCACertHash],
            log: MacOSKubeadmLog()
        )

        #expect(discovered.clusterDNS == "10.96.0.53")
    }

    @Test func compatDiscoveryRetainsDefaultWhenClusterDNSIsUnavailable() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setKubeletConfig(nil)
        let client = MacOSKubeadmDiscoveryClient(sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockKubernetesAPIURLProtocol.self]
            return configuration
        })

        let discovered = try client.discover(
            apiServer: #require(URL(string: "https://cluster.example:6443")),
            nodeName: "macos-ci-1",
            networkMode: .compat,
            token: "abcdef.0123456789abcdef",
            expectedCACertHashes: [testCACertHash],
            log: MacOSKubeadmLog()
        )

        #expect(discovered.clusterDNS == "10.96.0.10")
        #expect(discovered.clusterDomain == "cluster.local")
        #expect(discovered.kubeProxyToken.isEmpty)
        #expect(discovered.flannelToken.isEmpty)
    }

    @Test func existingFullNodeWithMatchingMetadataIsAccepted() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setNode(
            networkMode: "full",
            taints: [macOSTaint]
        )

        let discovered = try discover(networkMode: .full)

        #expect(discovered.kubeProxyToken == "proxy-token")
        #expect(discovered.flannelToken == "flannel-token")
    }

    @Test func existingCompatNodeWithMatchingMetadataIsAccepted() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setNode(
            networkMode: "compat",
            taints: [macOSTaint, compatNetworkTaint]
        )

        let discovered = try discover(networkMode: .compat)

        #expect(discovered.kubeProxyToken.isEmpty)
        #expect(discovered.flannelToken.isEmpty)
        let requests = MockKubernetesAPIURLProtocol.recordedRequests()
        #expect(
            requests.first { $0.path == "/api/v1/nodes/macos-ci-1" }?.authorization
                == "Bearer flannel-token"
        )
        #expect(
            !requests.contains {
                $0.path == "/api/v1/namespaces/kube-system/serviceaccounts/kube-proxy-macos/token"
            }
        )
    }

    @Test func fullToCompatModeSwitchIsRejectedBeforePodNetworkTokenRequest() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setNode(
            networkMode: "full",
            taints: [macOSTaint]
        )

        try expectModeConflict(desiredMode: .compat)

        #expect(
            !MockKubernetesAPIURLProtocol.recordedRequests().contains {
                $0.path == "/api/v1/namespaces/kube-system/serviceaccounts/kube-proxy-macos/token"
            }
        )
    }

    @Test func compatToFullModeSwitchIsRejectedBeforePodNetworkTokenRequest() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setNode(
            networkMode: "compat",
            taints: [macOSTaint, compatNetworkTaint]
        )

        try expectModeConflict(desiredMode: .full)

        #expect(
            !MockKubernetesAPIURLProtocol.recordedRequests().contains {
                $0.path == "/api/v1/namespaces/kube-system/serviceaccounts/kube-proxy-macos/token"
            }
        )
    }

    @Test func staleCompatTaintOnFullNodeIsRejected() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setNode(
            networkMode: "full",
            taints: [macOSTaint, compatNetworkTaint]
        )

        try expectModeConflict(desiredMode: .full)
    }

    @Test func missingNetworkModeLabelIsRejected() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setNode(
            networkMode: nil,
            taints: [macOSTaint]
        )

        try expectModeConflict(desiredMode: .full)
    }

    @Test func missingMacOSTaintIsRejected() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setNode(
            networkMode: "full",
            taints: []
        )

        try expectModeConflict(desiredMode: .full)
    }

    @Test func unrelatedTaintDoesNotAffectMatchingMode() throws {
        MockKubernetesAPIURLProtocol.reset()
        MockKubernetesAPIURLProtocol.setNode(
            networkMode: "full",
            taints: [
                macOSTaint,
                [
                    "key": "node.kubernetes.io/unschedulable",
                    "effect": "NoSchedule",
                ],
            ]
        )

        let discovered = try discover(networkMode: .full)

        #expect(discovered.kubeProxyToken == "proxy-token")
        #expect(discovered.flannelToken == "flannel-token")
    }

    @Test func dryRunDoesNotContactKubernetesAPI() throws {
        MockKubernetesAPIURLProtocol.reset()
        let runner = MacOSKubeadmJoinRunner(discoveryClient: makeDiscoveryClient())
        let options = MacOSKubeadmJoinOptions(
            apiServer: try #require(URL(string: "https://cluster.example:6443")),
            nodeName: "macos-ci-1",
            token: "abcdef.0123456789abcdef",
            discoveryTokenCACertHashes: [testCACertHash],
            networkMode: .compat,
            installRoot: "/tmp/container-macos-kubeadm-dry-run",
            startServices: false,
            dryRun: true
        )

        try runner.run(options: options, log: MacOSKubeadmLog())

        #expect(MockKubernetesAPIURLProtocol.recordedRequests().isEmpty)
    }

    private func discover(networkMode: MacOSKubeadmNetworkMode) throws -> MacOSKubeadmDiscoveredCluster {
        try makeDiscoveryClient().discover(
            apiServer: #require(URL(string: "https://cluster.example:6443")),
            nodeName: "macos-ci-1",
            networkMode: networkMode,
            token: "abcdef.0123456789abcdef",
            expectedCACertHashes: [testCACertHash],
            log: MacOSKubeadmLog()
        )
    }

    private func expectModeConflict(desiredMode: MacOSKubeadmNetworkMode) throws {
        do {
            _ = try discover(networkMode: desiredMode)
            Issue.record("expected existing Node metadata to reject the requested network mode")
        } catch MacOSKubeadmError.preflightFailed(let message) {
            #expect(message.contains("does not match --network-mode \(desiredMode.rawValue)"))
            #expect(message.contains("cordon and drain the Node"))
            #expect(message.contains("delete it or explicitly converge"))
        }
    }

    private func makeDiscoveryClient() -> MacOSKubeadmDiscoveryClient {
        MacOSKubeadmDiscoveryClient(sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockKubernetesAPIURLProtocol.self]
            return configuration
        })
    }
}

private struct RecordedKubernetesRequest: Sendable {
    var path: String
    var method: String
    var authorization: String?
    var body: Data?
}

private final class KubernetesRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RecordedKubernetesRequest] = []
    private var kubeletConfig: String? = KubernetesRequestRecorder.defaultKubeletConfig
    private var clusterServer = "https://cluster.example:6443"
    private var node: MockKubernetesNode?

    private static let defaultKubeletConfig = """
        clusterDNS:
        - 10.96.0.53
        clusterDomain: cluster.local
        """

    func reset() {
        lock.withLock {
            requests = []
            kubeletConfig = Self.defaultKubeletConfig
            clusterServer = "https://cluster.example:6443"
            node = nil
        }
    }

    func setKubeletConfig(_ value: String?) {
        lock.withLock {
            kubeletConfig = value
        }
    }

    func setClusterServer(_ value: String) {
        lock.withLock {
            clusterServer = value
        }
    }

    func setNode(networkMode: String?, taints: [[String: String]]) {
        lock.withLock {
            node = MockKubernetesNode(
                labels: networkMode.map { ["node.kubernetes.io/macos-network": $0] } ?? [:],
                taints: taints
            )
        }
    }

    func currentKubeletConfig() -> String? {
        lock.withLock { kubeletConfig }
    }

    func currentClusterServer() -> String {
        lock.withLock { clusterServer }
    }

    func currentNode() -> MockKubernetesNode? {
        lock.withLock { node }
    }

    func append(_ request: RecordedKubernetesRequest) {
        lock.withLock {
            requests.append(request)
        }
    }

    func recordedRequests() -> [RecordedKubernetesRequest] {
        lock.withLock {
            requests
        }
    }
}

private final class MockKubernetesAPIURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recorder = KubernetesRequestRecorder()

    static func reset() {
        recorder.reset()
    }

    static func recordedRequests() -> [RecordedKubernetesRequest] {
        recorder.recordedRequests()
    }

    static func setKubeletConfig(_ value: String?) {
        recorder.setKubeletConfig(value)
    }

    static func setClusterServer(_ value: String) {
        recorder.setClusterServer(value)
    }

    static func setNode(networkMode: String?, taints: [[String: String]]) {
        recorder.setNode(networkMode: networkMode, taints: taints)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://cluster.example")!
        let path = url.path
        Self.recorder.append(
            RecordedKubernetesRequest(
                path: path,
                method: request.httpMethod ?? "GET",
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: Self.bodyData(for: request)
            ))

        let statusCode = Self.statusCode(for: path)
        let data = Self.responseData(for: path)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var body = Data()
        while true {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count >= 0 else {
                return nil
            }
            guard count > 0 else {
                return body
            }
            body.append(buffer, count: count)
        }
    }

    private static func statusCode(for path: String) -> Int {
        if path.hasPrefix("/api/v1/nodes/") {
            return recorder.currentNode() == nil ? 404 : 200
        }
        switch path {
        case "/api/v1/namespaces/kube-public/configmaps/cluster-info",
            "/api/v1/namespaces/kube-system/configmaps/kubelet-config",
            "/api/v1/namespaces/kube-system/serviceaccounts/kube-proxy-macos/token",
            "/api/v1/namespaces/kube-system/serviceaccounts/flannel-macos/token":
            return 200
        default:
            return 404
        }
    }

    private static func responseData(for path: String) -> Data {
        if path.hasPrefix("/api/v1/nodes/") {
            guard let node = recorder.currentNode() else {
                return jsonData([
                    "kind": "Status",
                    "status": "Failure",
                    "reason": "NotFound",
                    "code": 404,
                ])
            }
            return jsonData([
                "metadata": ["labels": node.labels],
                "spec": ["taints": node.taints],
            ])
        }
        switch path {
        case "/api/v1/namespaces/kube-public/configmaps/cluster-info":
            return jsonData([
                "data": [
                    "kubeconfig": """
                    apiVersion: v1
                    kind: Config
                    clusters:
                    - cluster:
                        certificate-authority-data: \(testCACertDERBase64)
                        server: \(recorder.currentClusterServer())
                      name: cluster
                    contexts: []
                    current-context: ""
                    preferences: {}
                    users: []
                    """
                ]
            ])
        case "/api/v1/namespaces/kube-system/configmaps/kubelet-config":
            guard let kubeletConfig = recorder.currentKubeletConfig() else {
                return jsonData(["data": [:]])
            }
            return jsonData(["data": ["kubelet": kubeletConfig]])
        case "/api/v1/namespaces/kube-system/serviceaccounts/kube-proxy-macos/token":
            return jsonData([
                "status": [
                    "token": "proxy-token"
                ]
            ])
        case "/api/v1/namespaces/kube-system/serviceaccounts/flannel-macos/token":
            return jsonData([
                "status": [
                    "token": "flannel-token"
                ]
            ])
        default:
            return jsonData([
                "status": "Failure",
                "message": "unexpected mock path \(path)",
            ])
        }
    }

    private static func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private struct MockKubernetesNode: Sendable {
    var labels: [String: String]
    var taints: [[String: String]]
}

private let macOSTaint = [
    "key": "node.kubernetes.io/macos",
    "value": "true",
    "effect": "NoSchedule",
]

private let compatNetworkTaint = [
    "key": "node.kubernetes.io/macos-network",
    "value": "compat",
    "effect": "NoSchedule",
]

private let testCACertHash = "25d73167746724376c17137b25cbe31bd9bfc043b7988bbc4ba0871e79eb3a32"
private let testCACertDERBase64 = """
    MIIDNTCCAh2gAwIBAgIUZ/4Clhc95XFBgVqlnx/eJGA89XgwDQYJKoZIhvcNAQELBQAwKjEoMCYGA1UEAwwfY29udGFpbmVyLW1hY29zLWt1YmVhZG0tdGVzdC1jYTAeFw0yNjA2MTYxMzUzMDRaFw0yNjA2MTcxMzUzMDRaMCoxKDAmBgNVBAMMH2NvbnRhaW5lci1tYWNvcy1rdWJlYWRtLXRlc3QtY2EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCp0i+lkZ8Efjr5/bT/4TtvkG9IqCwTzRe5F7QmT+ORLr/FnMaBGQKKf4FDPXK8CxjwkI4T5ylA66sTEKCB8oZ/9TsVzJjWaiVlJs9jXA5jOtvrSIUMfpqqCqSDcDhtYv8j12fFXRbEN/xBLxkl5xZiP0VulwoUfbxW6ziw6MRit7lQv/rhTtVuerjLWmjGKAra4VmBQtOr6obpcHdRsyCetw1e4WwVmza6LqfN1u2ng09vQcOiQFicKX5iXffJ7Pqj+0QnSKkspGnOjnd6HwkY8qFzHYERlz8OM15WbcQGqWBJ94dOM9Bt0HjogqrFe4NXxsWW+cw5OdyzlRvFgb4XAgMBAAGjUzBRMB0GA1UdDgQWBBRcdGTdWP5ySNU7+3TegPrr9Cw0azAfBgNVHSMEGDAWgBRcdGTdWP5ySNU7+3TegPrr9Cw0azAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQB0u3XkSAe1HkbwS2Qr52smHJhxQxugY8OZ+1ECn62Uq5Tvn01jzP929oYRgi406xstRg7nHcP+Z9265jH7H2UA7by/nkQFElAeqi71hqwkEr519LeEANwkzJw0pf2o2D1uPgGIV13E9qxLDl7A1Xjmq3Lel8+XWYbhF06jmogbLEtehTwPMbIAz679mZf7aKQGiuxvMs5oZthSPzfsXP3asoWKFSB9Oosw6KmNAS0n4ulOBWcQrc20+E4iJAkmQu3fp7dbYsecrRaDCCqU8n9kzKF5bjH3saCuUc29bLtBHOs2kcEOVeLUw3xNVxPa5t6wGjVMQTTeINyZ9Puyo0V9
    """
