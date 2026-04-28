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
import Security

public protocol KubeProxyKubernetesReading: Sendable {
    func snapshot() async throws -> KubeProxySnapshot
}

public final class KubeProxyKubernetesClient: KubeProxyKubernetesReading, @unchecked Sendable {
    private let config: KubeProxyKubeconfigClientConfig
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(config: KubeProxyKubeconfigClientConfig) {
        self.config = config
        let delegate = KubeProxyURLSessionDelegate(config: config)
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    public convenience init(kubeconfigPath: String) throws {
        try self.init(config: KubeProxyKubeconfig.load(from: URL(fileURLWithPath: kubeconfigPath)))
    }

    public func snapshot() async throws -> KubeProxySnapshot {
        async let services: KubeProxyServiceList = get("/api/v1/services")
        async let endpointSlices: KubeProxyEndpointSliceList = get("/apis/discovery.k8s.io/v1/endpointslices")
        return try await KubeProxySnapshot(services: services.items, endpointSlices: endpointSlices.items)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = try url(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let token = config.bearerToken, !token.isEmpty {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KubeProxyMacOSError.invalidKubeconfig("Kubernetes API response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw KubeProxyMacOSError.invalidKubeconfig("Kubernetes API GET \(path) returned \(httpResponse.statusCode): \(body)")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func url(path: String) throws -> URL {
        guard var components = URLComponents(url: config.server, resolvingAgainstBaseURL: false) else {
            throw KubeProxyMacOSError.invalidKubeconfig("invalid Kubernetes API server URL")
        }
        components.path = path
        components.query = nil
        guard let url = components.url else {
            throw KubeProxyMacOSError.invalidKubeconfig("failed to construct Kubernetes API URL for \(path)")
        }
        return url
    }
}

private final class KubeProxyURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let insecureSkipTLSVerify: Bool
    private let certificateAuthority: SecCertificate?
    private let serverHost: String?

    init(config: KubeProxyKubeconfigClientConfig) {
        self.insecureSkipTLSVerify = config.insecureSkipTLSVerify
        self.serverHost = config.server.host
        if let data = config.certificateAuthorityData {
            self.certificateAuthority = SecCertificateCreateWithData(nil, data as CFData)
        } else {
            self.certificateAuthority = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if insecureSkipTLSVerify {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        guard let certificateAuthority else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if let serverHost {
            let policy = SecPolicyCreateSSL(true, serverHost as CFString)
            SecTrustSetPolicies(serverTrust, policy)
        }
        SecTrustSetAnchorCertificates(serverTrust, [certificateAuthority] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, true)

        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
