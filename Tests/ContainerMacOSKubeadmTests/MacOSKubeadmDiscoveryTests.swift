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
    @Test func clusterInfoDiscoveryUsesAnonymousRequest() throws {
        MockKubernetesAPIURLProtocol.reset()
        let client = MacOSKubeadmDiscoveryClient(sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockKubernetesAPIURLProtocol.self]
            return configuration
        })

        let discovered = try client.discover(
            apiServer: #require(URL(string: "https://cluster.example:6443")),
            token: "abcdef.0123456789abcdef",
            expectedCACertHashes: [testCACertHash],
            log: MacOSKubeadmLog()
        )

        #expect(discovered.clusterDNS == "10.96.0.53")
        #expect(discovered.clusterDomain == "cluster.local")
        #expect(discovered.kubeProxyToken == "proxy-token")

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
    }
}

private struct RecordedKubernetesRequest: Sendable {
    var path: String
    var method: String
    var authorization: String?
}

private final class MockKubernetesAPIURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [RecordedKubernetesRequest] = []

    static func reset() {
        lock.withLock {
            requests = []
        }
    }

    static func recordedRequests() -> [RecordedKubernetesRequest] {
        lock.withLock {
            requests
        }
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
        Self.lock.withLock {
            Self.requests.append(
                RecordedKubernetesRequest(
                    path: path,
                    method: request.httpMethod ?? "GET",
                    authorization: request.value(forHTTPHeaderField: "Authorization")
                ))
        }

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

    private static func statusCode(for path: String) -> Int {
        switch path {
        case "/api/v1/namespaces/kube-public/configmaps/cluster-info",
            "/api/v1/namespaces/kube-system/configmaps/kubelet-config",
            "/api/v1/namespaces/kube-system/serviceaccounts/kube-proxy-macos/token":
            return 200
        default:
            return 404
        }
    }

    private static func responseData(for path: String) -> Data {
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
                        server: https://cluster.example:6443
                      name: cluster
                    contexts: []
                    current-context: ""
                    preferences: {}
                    users: []
                    """
                ]
            ])
        case "/api/v1/namespaces/kube-system/configmaps/kubelet-config":
            return jsonData([
                "data": [
                    "kubelet": """
                    clusterDNS:
                    - 10.96.0.53
                    clusterDomain: cluster.local
                    """
                ]
            ])
        case "/api/v1/namespaces/kube-system/serviceaccounts/kube-proxy-macos/token":
            return jsonData([
                "status": [
                    "token": "proxy-token"
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

private let testCACertHash = "25d73167746724376c17137b25cbe31bd9bfc043b7988bbc4ba0871e79eb3a32"
private let testCACertDERBase64 = """
    MIIDNTCCAh2gAwIBAgIUZ/4Clhc95XFBgVqlnx/eJGA89XgwDQYJKoZIhvcNAQELBQAwKjEoMCYGA1UEAwwfY29udGFpbmVyLW1hY29zLWt1YmVhZG0tdGVzdC1jYTAeFw0yNjA2MTYxMzUzMDRaFw0yNjA2MTcxMzUzMDRaMCoxKDAmBgNVBAMMH2NvbnRhaW5lci1tYWNvcy1rdWJlYWRtLXRlc3QtY2EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCp0i+lkZ8Efjr5/bT/4TtvkG9IqCwTzRe5F7QmT+ORLr/FnMaBGQKKf4FDPXK8CxjwkI4T5ylA66sTEKCB8oZ/9TsVzJjWaiVlJs9jXA5jOtvrSIUMfpqqCqSDcDhtYv8j12fFXRbEN/xBLxkl5xZiP0VulwoUfbxW6ziw6MRit7lQv/rhTtVuerjLWmjGKAra4VmBQtOr6obpcHdRsyCetw1e4WwVmza6LqfN1u2ng09vQcOiQFicKX5iXffJ7Pqj+0QnSKkspGnOjnd6HwkY8qFzHYERlz8OM15WbcQGqWBJ94dOM9Bt0HjogqrFe4NXxsWW+cw5OdyzlRvFgb4XAgMBAAGjUzBRMB0GA1UdDgQWBBRcdGTdWP5ySNU7+3TegPrr9Cw0azAfBgNVHSMEGDAWgBRcdGTdWP5ySNU7+3TegPrr9Cw0azAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQB0u3XkSAe1HkbwS2Qr52smHJhxQxugY8OZ+1ECn62Uq5Tvn01jzP929oYRgi406xstRg7nHcP+Z9265jH7H2UA7by/nkQFElAeqi71hqwkEr519LeEANwkzJw0pf2o2D1uPgGIV13E9qxLDl7A1Xjmq3Lel8+XWYbhF06jmogbLEtehTwPMbIAz679mZf7aKQGiuxvMs5oZthSPzfsXP3asoWKFSB9Oosw6KmNAS0n4ulOBWcQrc20+E4iJAkmQu3fp7dbYsecrRaDCCqU8n9kzKF5bjH3saCuUc29bLtBHOs2kcEOVeLUw3xNVxPa5t6wGjVMQTTeINyZ9Puyo0V9
    """
