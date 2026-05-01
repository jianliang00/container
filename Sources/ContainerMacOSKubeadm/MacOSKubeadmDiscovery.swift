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

import CryptoKit
import Foundation
import Security

public struct MacOSKubeadmDiscoveredCluster: Sendable, Equatable {
    public var apiServer: URL
    public var certificateAuthorityPEM: String
    public var clusterDNS: String
    public var clusterDomain: String
    public var kubeProxyToken: String

    public init(
        apiServer: URL,
        certificateAuthorityPEM: String,
        clusterDNS: String,
        clusterDomain: String,
        kubeProxyToken: String
    ) {
        self.apiServer = apiServer
        self.certificateAuthorityPEM = certificateAuthorityPEM
        self.clusterDNS = clusterDNS
        self.clusterDomain = clusterDomain
        self.kubeProxyToken = kubeProxyToken
    }
}

public struct MacOSKubeadmDiscoveryClient: Sendable {
    public static let dryRunCertificateAuthorityPEM = """
        -----BEGIN CERTIFICATE-----
        ZHJ5LXJ1bi1jYQ==
        -----END CERTIFICATE-----

        """

    public init() {}

    public func discover(
        apiServer: URL,
        token: String,
        expectedCACertHashes: [String],
        log: MacOSKubeadmLog
    ) throws -> MacOSKubeadmDiscoveredCluster {
        let normalizedHashes = try expectedCACertHashes.map(Self.normalizeDiscoveryHash)

        let insecureSession = URLSession(
            configuration: Self.sessionConfiguration(),
            delegate: MacOSKubeadmInsecureURLSessionDelegate(),
            delegateQueue: nil
        )
        let clusterInfo: MacOSKubeadmClusterInfoConfigMap = try get(
            "/api/v1/namespaces/kube-public/configmaps/cluster-info",
            apiServer: apiServer,
            token: token,
            session: insecureSession
        )
        guard let kubeconfig = clusterInfo.data?["kubeconfig"] else {
            throw MacOSKubeadmError.preflightFailed("kube-public/cluster-info does not contain data.kubeconfig")
        }

        let parsedClusterInfo = try Self.parseClusterInfoKubeconfig(kubeconfig)
        let certificateAuthorityDER = parsedClusterInfo.certificateAuthorityDER
        let actualHash = try Self.subjectPublicKeyInfoSHA256(derCertificate: certificateAuthorityDER)
        guard normalizedHashes.contains(actualHash) else {
            throw MacOSKubeadmError.preflightFailed(
                "discovery-token-ca-cert-hash mismatch: expected one of \(normalizedHashes.joined(separator: ", ")), got sha256:\(actualHash)"
            )
        }
        log.info("validated discovery-token-ca-cert-hash")

        let trustedSession = URLSession(
            configuration: Self.sessionConfiguration(),
            delegate: MacOSKubeadmPinnedCAURLSessionDelegate(
                certificateAuthorityDER: certificateAuthorityDER,
                serverHost: parsedClusterInfo.apiServer.host ?? apiServer.host
            ),
            delegateQueue: nil
        )

        let kubeletSettings = discoverKubeletSettings(
            apiServer: parsedClusterInfo.apiServer,
            token: token,
            session: trustedSession,
            log: log
        )
        let kubeProxyToken = try requestKubeProxyToken(
            apiServer: parsedClusterInfo.apiServer,
            token: token,
            session: trustedSession
        )
        log.info("received kube-proxy ServiceAccount token")

        return MacOSKubeadmDiscoveredCluster(
            apiServer: parsedClusterInfo.apiServer,
            certificateAuthorityPEM: Self.pemString(fromDER: certificateAuthorityDER),
            clusterDNS: kubeletSettings.clusterDNS,
            clusterDomain: kubeletSettings.clusterDomain,
            kubeProxyToken: kubeProxyToken
        )
    }

    private func discoverKubeletSettings(
        apiServer: URL,
        token: String,
        session: URLSession,
        log: MacOSKubeadmLog
    ) -> MacOSKubeadmKubeletSettings {
        do {
            let configMap: MacOSKubeadmClusterInfoConfigMap = try get(
                "/api/v1/namespaces/kube-system/configmaps/kubelet-config",
                apiServer: apiServer,
                token: token,
                session: session
            )
            guard let kubeletConfig = configMap.data?["kubelet"] else {
                log.warning("kube-system/kubelet-config does not contain data.kubelet; using default cluster DNS settings")
                return .default
            }
            return Self.parseKubeletSettings(kubeletConfig) ?? .default
        } catch {
            log.warning("failed to discover kubelet cluster DNS settings; using defaults: \(error)")
            return .default
        }
    }

    private func requestKubeProxyToken(apiServer: URL, token: String, session: URLSession) throws -> String {
        let body = """
            {
              "apiVersion": "authentication.k8s.io/v1",
              "kind": "TokenRequest",
              "spec": {
                "audiences": ["https://kubernetes.default.svc"],
                "expirationSeconds": 31536000
              }
            }
            """
        let response: MacOSKubeadmTokenRequestResponse = try post(
            "/api/v1/namespaces/kube-system/serviceaccounts/kube-proxy-macos/token",
            apiServer: apiServer,
            token: token,
            body: Data(body.utf8),
            session: session
        )
        guard let token = response.status.token, !token.isEmpty else {
            throw MacOSKubeadmError.preflightFailed("kube-proxy TokenRequest returned no token")
        }
        return token
    }

    private func get<T: Decodable>(_ path: String, apiServer: URL, token: String, session: URLSession) throws -> T {
        let url = try Self.url(apiServer: apiServer, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try Self.execute(request, session: session)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, apiServer: URL, token: String, body: Data, session: URLSession) throws -> T {
        let url = try Self.url(apiServer: apiServer, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try Self.execute(request, session: session)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func execute(_ request: URLRequest, session: URLSession) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var result: Result<(Data, URLResponse), Error>?
        }
        let box = Box()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else {
                box.result = .success((data ?? Data(), response ?? URLResponse()))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard let result = box.result else {
            throw MacOSKubeadmError.preflightFailed("Kubernetes API request did not complete")
        }
        let (data, response) = try result.get()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MacOSKubeadmError.preflightFailed("Kubernetes API response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MacOSKubeadmError.preflightFailed(
                "Kubernetes API \(request.httpMethod ?? "GET") \(request.url?.path ?? "") returned \(httpResponse.statusCode): \(body)"
            )
        }
        return data
    }

    private static func url(apiServer: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: apiServer, resolvingAgainstBaseURL: false) else {
            throw MacOSKubeadmError.invalidInput("invalid Kubernetes API server URL")
        }
        components.path = path
        components.query = nil
        guard let url = components.url else {
            throw MacOSKubeadmError.invalidInput("failed to construct Kubernetes API URL for \(path)")
        }
        return url
    }

    private static func parseClusterInfoKubeconfig(_ content: String) throws -> MacOSKubeadmParsedClusterInfo {
        guard let serverValue = firstKubeconfigValue(named: "server", in: content),
            let server = URL(string: serverValue)
        else {
            throw MacOSKubeadmError.preflightFailed("cluster-info kubeconfig does not contain a valid cluster.server")
        }
        guard let caDataValue = firstKubeconfigValue(named: "certificate-authority-data", in: content),
            let caData = Data(base64Encoded: caDataValue)
        else {
            throw MacOSKubeadmError.preflightFailed("cluster-info kubeconfig does not contain valid certificate-authority-data")
        }
        let caDER = pemToDER(caData) ?? caData
        return MacOSKubeadmParsedClusterInfo(apiServer: server, certificateAuthorityDER: caDER)
    }

    private static func parseKubeletSettings(_ content: String) -> MacOSKubeadmKubeletSettings? {
        var clusterDNS: String?
        var clusterDomain: String?
        var expectingClusterDNSValue = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = stripInlineComment(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                continue
            }
            if expectingClusterDNSValue, trimmed.hasPrefix("- ") {
                clusterDNS = unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                expectingClusterDNSValue = false
                continue
            }
            if trimmed == "clusterDNS:" {
                expectingClusterDNSValue = true
                continue
            }
            if let value = value(after: "clusterDomain:", in: trimmed) {
                clusterDomain = value
            }
        }

        guard clusterDNS != nil || clusterDomain != nil else {
            return nil
        }
        return MacOSKubeadmKubeletSettings(
            clusterDNS: clusterDNS ?? MacOSKubeadmKubeletSettings.default.clusterDNS,
            clusterDomain: clusterDomain ?? MacOSKubeadmKubeletSettings.default.clusterDomain
        )
    }

    private static func firstKubeconfigValue(named field: String, in content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = stripInlineComment(line).trimmingCharacters(in: .whitespaces)
            if let value = value(after: "\(field):", in: trimmed) {
                return value
            }
        }
        return nil
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else {
            return nil
        }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return unquote(value)
    }

    private static func stripInlineComment(_ line: String) -> String {
        guard let index = line.firstIndex(of: "#") else {
            return line
        }
        return String(line[..<index])
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2,
            let first = value.first,
            let last = value.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func normalizeDiscoveryHash(_ hash: String) throws -> String {
        let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = trimmed.hasPrefix("sha256:") ? String(trimmed.dropFirst("sha256:".count)) : trimmed
        guard value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw MacOSKubeadmError.invalidInput("--discovery-token-ca-cert-hash must be sha256:<64 hex chars>")
        }
        return value
    }

    private static func subjectPublicKeyInfoSHA256(derCertificate: Data) throws -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-macos-kubeadm-ca-\(UUID().uuidString).crt")
        try derCertificate.write(to: tempURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let publicKeyPEM = try runProcess([
            "/usr/bin/openssl",
            "x509",
            "-in",
            tempURL.path,
            "-inform",
            "DER",
            "-pubkey",
            "-noout",
        ])
        let publicKeyDER = try runProcess(
            [
                "/usr/bin/openssl",
                "pkey",
                "-pubin",
                "-outform",
                "DER",
            ], input: publicKeyPEM)

        return SHA256.hash(data: publicKeyDER).map { String(format: "%02x", $0) }.joined()
    }

    private static func runProcess(_ arguments: [String], input: Data? = nil) throws -> Data {
        guard let executable = arguments.first else {
            throw MacOSKubeadmError.invalidInput("empty command")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        let inputPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            inputPipe = nil
        }

        try process.run()
        if let input {
            inputPipe?.fileHandleForWriting.write(input)
            try? inputPipe?.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr =
            String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw MacOSKubeadmError.commandFailed(
                command: MacOSKubeadmAction.runCommand(arguments: arguments, bestEffort: false).safeDescription,
                status: process.terminationStatus,
                output: stderr
            )
        }
        return stdout
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    private static func pemString(fromDER data: Data) -> String {
        let encoded = data.base64EncodedString()
        let lines = stride(from: 0, to: encoded.count, by: 64).map { offset -> String in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(64, encoded.distance(from: start, to: encoded.endIndex)))
            return String(encoded[start..<end])
        }
        return """
            -----BEGIN CERTIFICATE-----
            \(lines.joined(separator: "\n"))
            -----END CERTIFICATE-----

            """
    }

    private static func pemToDER(_ data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8),
            string.contains("-----BEGIN CERTIFICATE-----")
        else {
            return nil
        }
        let lines = string.components(separatedBy: .newlines).filter { line in
            !line.hasPrefix("-----BEGIN") && !line.hasPrefix("-----END") && !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return Data(base64Encoded: lines.joined())
    }
}

private struct MacOSKubeadmParsedClusterInfo: Sendable, Equatable {
    var apiServer: URL
    var certificateAuthorityDER: Data
}

private struct MacOSKubeadmKubeletSettings: Sendable, Equatable {
    static let `default` = MacOSKubeadmKubeletSettings(clusterDNS: "10.96.0.10", clusterDomain: "cluster.local")

    var clusterDNS: String
    var clusterDomain: String
}

private struct MacOSKubeadmClusterInfoConfigMap: Decodable {
    var data: [String: String]?
}

private struct MacOSKubeadmTokenRequestResponse: Decodable {
    var status: Status

    struct Status: Decodable {
        var token: String?
    }
}

private final class MacOSKubeadmInsecureURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

private final class MacOSKubeadmPinnedCAURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let certificateAuthority: SecCertificate?
    private let serverHost: String?

    init(certificateAuthorityDER: Data, serverHost: String?) {
        self.certificateAuthority = SecCertificateCreateWithData(nil, certificateAuthorityDER as CFData)
        self.serverHost = serverHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust,
            let certificateAuthority
        else {
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
