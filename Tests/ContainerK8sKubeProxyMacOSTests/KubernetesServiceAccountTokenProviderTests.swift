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

struct KubernetesServiceAccountTokenProviderTests {
    @Test
    func parsesRelativeTokenFileFromKubeconfig() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tokenURL = directory.appendingPathComponent("service-account.token")
        try "persisted-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)
        let kubeconfig = """
            apiVersion: v1
            clusters:
            - cluster:
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
                tokenFile: service-account.token
            """

        let config = try KubeProxyKubeconfig.parse(kubeconfig, baseURL: directory)

        #expect(config.bearerToken == "persisted-token")
        #expect(config.bearerTokenFile == tokenURL)
    }

    @Test
    func unexpiredTokenDoesNotRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let token = try serviceAccountToken(expiration: now.addingTimeInterval(3_600))
        let requests = TokenRequestRecorder()
        let provider = KubernetesServiceAccountTokenProvider(initialToken: token) { _, _, _ in
            await requests.record()
            throw TokenRefreshTestError.unavailable
        }

        let authorized = try await provider.authorizationToken(now: now)

        #expect(authorized == token)
        #expect(await requests.count() == 0)
    }

    @Test
    func refreshesNearExpiryAndPersistsTokenWithPrivatePermissions() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldToken = try serviceAccountToken(expiration: now.addingTimeInterval(120))
        let newExpiration = now.addingTimeInterval(7_200)
        let newToken = try serviceAccountToken(expiration: newExpiration)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tokenURL = directory.appendingPathComponent("service-account.token")
        try oldToken.write(to: tokenURL, atomically: true, encoding: .utf8)
        let requests = TokenRequestRecorder()
        let provider = KubernetesServiceAccountTokenProvider(initialToken: oldToken, tokenFile: tokenURL) {
            currentToken,
            identity,
            expirationSeconds in
            await requests.record(
                token: currentToken,
                identity: identity,
                expirationSeconds: expirationSeconds
            )
            return KubernetesServiceAccountTokenProvider.RefreshedToken(
                token: newToken,
                expiration: newExpiration
            )
        }

        let authorized = try await provider.authorizationToken(now: now)
        let request = try #require(await requests.last())
        let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)

        #expect(authorized == newToken)
        #expect(request.token == oldToken)
        #expect(request.identity.namespace == "kube-system")
        #expect(request.identity.name == "kube-proxy-macos")
        #expect(request.expirationSeconds == 86_400)
        #expect(try String(contentsOf: tokenURL, encoding: .utf8) == newToken)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func keepsStillValidTokenWhenRefreshTemporarilyFails() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let token = try serviceAccountToken(expiration: now.addingTimeInterval(120))
        let provider = KubernetesServiceAccountTokenProvider(initialToken: token) { _, _, _ in
            throw TokenRefreshTestError.unavailable
        }

        #expect(try await provider.authorizationToken(now: now) == token)
    }

    @Test
    func rejectsExpiredTokenWhenRefreshFails() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let token = try serviceAccountToken(expiration: now.addingTimeInterval(-1))
        let provider = KubernetesServiceAccountTokenProvider(initialToken: token) { _, _, _ in
            throw TokenRefreshTestError.unavailable
        }

        await #expect(throws: TokenRefreshTestError.self) {
            try await provider.authorizationToken(now: now)
        }
    }
}

private actor TokenRequestRecorder {
    struct Request: Sendable {
        var token: String
        var identity: KubernetesServiceAccountTokenProvider.ServiceAccountIdentity
        var expirationSeconds: Int64
    }

    private var requests: [Request] = []

    func record(
        token: String = "",
        identity: KubernetesServiceAccountTokenProvider.ServiceAccountIdentity = .init(namespace: "", name: ""),
        expirationSeconds: Int64 = 0
    ) {
        requests.append(Request(token: token, identity: identity, expirationSeconds: expirationSeconds))
    }

    func count() -> Int {
        requests.count
    }

    func last() -> Request? {
        requests.last
    }
}

private enum TokenRefreshTestError: Error {
    case unavailable
}

private func serviceAccountToken(
    namespace: String = "kube-system",
    name: String = "kube-proxy-macos",
    expiration: Date
) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: [
        "sub": "system:serviceaccount:\(namespace):\(name)",
        "exp": Int64(expiration.timeIntervalSince1970),
    ])
    return "e30.\(base64URLEncoded(payload)).signature"
}

private func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("KubernetesServiceAccountTokenProviderTests-\(UUID().uuidString)", isDirectory: true)
}
