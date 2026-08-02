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

import ContainerK8sKubeProxyMacOS
import Foundation
import Security

public protocol FlannelKubernetesReading: Sendable {
    func nodes() async throws -> [FlannelNode]
    func configMap(namespace: String, name: String) async throws -> FlannelConfigMap
}

public protocol FlannelKubernetesWriting: Sendable {
    func patchOwnNodeAnnotations(_ patch: FlannelNodeAnnotationPatch) async throws -> FlannelNode
}

public final class FlannelKubernetesClient: FlannelKubernetesReading, FlannelKubernetesWriting, @unchecked Sendable {
    private let config: KubeProxyKubeconfigClientConfig
    private let session: URLSession
    private let tokenProvider: KubernetesServiceAccountTokenProvider
    private let nodeWriter: FlannelKubernetesNodeWriter

    public convenience init(
        readConfig: KubeProxyKubeconfigClientConfig,
        nodeKubeconfigPath: String,
        nodeName: String
    ) throws {
        try self.init(
            readConfig: readConfig,
            nodeKubeconfigPath: nodeKubeconfigPath,
            nodeName: nodeName,
            nodeTransport: FlannelCurlNodeAnnotationTransport()
        )
    }

    init(
        readConfig: KubeProxyKubeconfigClientConfig,
        nodeKubeconfigPath: String,
        nodeName: String,
        nodeTransport: any FlannelNodeAnnotationTransport
    ) throws {
        guard !nodeName.isEmpty, !nodeName.contains("/") else {
            throw FlannelVXLANError.invalidConfiguration("nodeName is not a valid Kubernetes resource name")
        }
        guard readConfig.server.scheme?.lowercased() == "https", readConfig.server.host != nil else {
            throw FlannelVXLANError.invalidConfiguration("read kubeconfig Kubernetes API server must use HTTPS")
        }
        self.config = readConfig

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 30
        let session = URLSession(
            configuration: sessionConfig,
            delegate: FlannelURLSessionDelegate(config: readConfig),
            delegateQueue: nil
        )
        self.session = session
        self.tokenProvider = KubernetesServiceAccountTokenProvider(config: readConfig, session: session)
        self.nodeWriter = try FlannelKubernetesNodeWriter(
            kubeconfigPath: nodeKubeconfigPath,
            nodeName: nodeName,
            transport: nodeTransport
        )
    }

    public convenience init(readKubeconfigPath: String, nodeKubeconfigPath: String, nodeName: String) throws {
        let config = try KubeProxyKubeconfig.load(from: URL(fileURLWithPath: readKubeconfigPath))
        try self.init(readConfig: config, nodeKubeconfigPath: nodeKubeconfigPath, nodeName: nodeName)
    }

    public func nodes() async throws -> [FlannelNode] {
        let list: FlannelNodeList = try await get(path: "/api/v1/nodes")
        return list.items
    }

    public func configMap(namespace: String, name: String) async throws -> FlannelConfigMap {
        try validatePathSegment(namespace, name: "namespace")
        try validatePathSegment(name, name: "ConfigMap name")
        return try await get(path: "/api/v1/namespaces/\(namespace)/configmaps/\(name)")
    }

    public func patchOwnNodeAnnotations(_ patch: FlannelNodeAnnotationPatch) async throws -> FlannelNode {
        try await nodeWriter.patchOwnNodeAnnotations(patch)
    }

    public static func leaseAnnotationPatch(
        annotationPrefix: String,
        publicIP: String,
        vni: Int,
        vtepMAC: String
    ) throws -> FlannelNodeAnnotationPatch {
        let keys = try FlannelAnnotationKeys(prefix: annotationPrefix)
        guard FlannelIPv4.parseAddress(publicIP) != nil else {
            throw FlannelVXLANError.invalidConfiguration("publicIP must be a valid IPv4 address")
        }
        guard (1...16_777_215).contains(vni) else {
            throw FlannelVXLANError.invalidConfiguration("VNI must be a non-zero 24-bit value")
        }
        guard let normalizedMAC = FlannelVTEPMAC.normalize(vtepMAC) else {
            throw FlannelVXLANError.invalidConfiguration("vtepMAC must be a valid unicast MAC address")
        }

        let backendData = try JSONEncoder().encode(FlannelBackendLeaseData(vni: vni, vtepMAC: normalizedMAC))
        guard let backendDataString = String(data: backendData, encoding: .utf8) else {
            throw FlannelVXLANError.invalidConfiguration("failed to encode VXLAN backend data")
        }
        return FlannelNodeAnnotationPatch(values: [
            keys.kubeSubnetManager: "true",
            keys.backendType: "vxlan",
            keys.publicIP: publicIP,
            keys.backendData: backendDataString,
        ])
    }

    public static func annotationMergePatchData(_ patch: FlannelNodeAnnotationPatch) throws -> Data {
        try patch.validate()
        var annotations: [String: Any] = patch.values
        for key in patch.removals {
            annotations[key] = NSNull()
        }
        return try JSONSerialization.data(
            withJSONObject: ["metadata": ["annotations": annotations]],
            options: [.sortedKeys]
        )
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        try await perform(request(path: path, method: "GET"))
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FlannelVXLANError.kubernetesAPI("response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body =
                String(data: data.prefix(4096), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FlannelVXLANError.kubernetesAPI(
                "\(request.httpMethod ?? "request") \(request.url?.path ?? "<unknown>") returned \(httpResponse.statusCode): \(body)"
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FlannelVXLANError.kubernetesAPI(
                "failed to decode \(request.httpMethod ?? "request") \(request.url?.path ?? "<unknown>") response: \(error)"
            )
        }
    }

    private func request(path: String, method: String) async throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains("..") else {
            throw FlannelVXLANError.invalidConfiguration("invalid Kubernetes API path")
        }
        guard var components = URLComponents(url: config.server, resolvingAgainstBaseURL: false) else {
            throw FlannelVXLANError.invalidConfiguration("invalid Kubernetes API server URL")
        }
        components.path = path
        components.query = nil
        guard let url = components.url else {
            throw FlannelVXLANError.invalidConfiguration("failed to construct Kubernetes API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let token = try await tokenProvider.authorizationToken(), !token.isEmpty {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validatePathSegment(_ value: String, name: String) throws {
        guard !value.isEmpty, !value.contains("/"), value != ".", value != ".." else {
            throw FlannelVXLANError.invalidConfiguration("\(name) is not a valid Kubernetes resource name")
        }
    }
}

private final class FlannelURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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
            SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, serverHost as CFString))
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
