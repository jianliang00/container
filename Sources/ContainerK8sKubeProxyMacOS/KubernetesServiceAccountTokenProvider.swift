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

public enum KubernetesServiceAccountTokenError: Error, Sendable, CustomStringConvertible {
    case invalidRefreshResponse(String)
    case refreshRequestFailed(String)
    case persistenceFailed(String)

    public var description: String {
        switch self {
        case .invalidRefreshResponse(let message):
            "invalid ServiceAccount TokenRequest response: \(message)"
        case .refreshRequestFailed(let message):
            "ServiceAccount TokenRequest failed: \(message)"
        case .persistenceFailed(let message):
            "failed to persist refreshed ServiceAccount token: \(message)"
        }
    }
}

public actor KubernetesServiceAccountTokenProvider {
    public static let defaultRequestedExpirationSeconds: Int64 = 86_400
    public static let defaultRefreshBeforeExpirationSeconds: TimeInterval = 300

    private var credential: Credential
    private let tokenFile: URL?
    private let requestedExpirationSeconds: Int64
    private let refreshBeforeExpirationSeconds: TimeInterval
    private let requester: TokenRequester
    private var refreshTask: Task<Credential, Error>?

    public init(
        config: KubeProxyKubeconfigClientConfig,
        session: URLSession,
        requestedExpirationSeconds: Int64 = defaultRequestedExpirationSeconds,
        refreshBeforeExpirationSeconds: TimeInterval = defaultRefreshBeforeExpirationSeconds
    ) {
        self.init(
            initialToken: config.bearerToken,
            tokenFile: config.bearerTokenFile,
            requestedExpirationSeconds: requestedExpirationSeconds,
            refreshBeforeExpirationSeconds: refreshBeforeExpirationSeconds
        ) { token, identity, expirationSeconds in
            try await KubernetesServiceAccountTokenRequester.request(
                server: config.server,
                session: session,
                currentToken: token,
                identity: identity,
                expirationSeconds: expirationSeconds
            )
        }
    }

    init(
        initialToken: String?,
        tokenFile: URL? = nil,
        requestedExpirationSeconds: Int64 = defaultRequestedExpirationSeconds,
        refreshBeforeExpirationSeconds: TimeInterval = defaultRefreshBeforeExpirationSeconds,
        requester: @escaping TokenRequester
    ) {
        self.credential = Credential(token: initialToken)
        self.tokenFile = tokenFile
        self.requestedExpirationSeconds = requestedExpirationSeconds
        self.refreshBeforeExpirationSeconds = refreshBeforeExpirationSeconds
        self.requester = requester
    }

    public func authorizationToken(now: Date = Date()) async throws -> String? {
        guard let token = credential.token else {
            return nil
        }
        guard let identity = credential.identity,
            let expiration = credential.expiration,
            expiration.timeIntervalSince(now) <= refreshBeforeExpirationSeconds
        else {
            return token
        }

        let task: Task<Credential, Error>
        if let refreshTask {
            task = refreshTask
        } else {
            let requester = requester
            let requestedExpirationSeconds = requestedExpirationSeconds
            task = Task {
                let refreshed = try await requester(token, identity, requestedExpirationSeconds)
                return try Self.validatedCredential(
                    refreshed,
                    expectedIdentity: identity,
                    now: max(now, Date())
                )
            }
            refreshTask = task
        }

        do {
            let nextCredential = try await task.value
            try persist(nextCredential.token)
            credential = nextCredential
            refreshTask = nil
            return nextCredential.token
        } catch {
            refreshTask = nil
            guard expiration > max(now, Date()) else {
                throw error
            }
            return token
        }
    }

    private static func validatedCredential(
        _ refreshed: RefreshedToken,
        expectedIdentity: ServiceAccountIdentity,
        now: Date
    ) throws -> Credential {
        let credential = Credential(token: refreshed.token)
        guard credential.identity == expectedIdentity else {
            throw KubernetesServiceAccountTokenError.invalidRefreshResponse(
                "token identity does not match \(expectedIdentity.namespace)/\(expectedIdentity.name)"
            )
        }
        guard let tokenExpiration = credential.expiration else {
            throw KubernetesServiceAccountTokenError.invalidRefreshResponse("token has no expiration claim")
        }
        let effectiveExpiration = min(tokenExpiration, refreshed.expiration)
        guard effectiveExpiration > now else {
            throw KubernetesServiceAccountTokenError.invalidRefreshResponse("token is already expired")
        }
        return Credential(
            token: refreshed.token,
            identity: expectedIdentity,
            expiration: effectiveExpiration
        )
    }

    private func persist(_ token: String?) throws {
        guard let token, let tokenFile else {
            return
        }
        do {
            try token.write(to: tokenFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: tokenFile.path
            )
        } catch {
            throw KubernetesServiceAccountTokenError.persistenceFailed(String(describing: error))
        }
    }
}

extension KubernetesServiceAccountTokenProvider {
    struct ServiceAccountIdentity: Sendable, Equatable {
        var namespace: String
        var name: String
    }

    struct RefreshedToken: Sendable, Equatable {
        var token: String
        var expiration: Date
    }

    typealias TokenRequester =
        @Sendable (
            _ currentToken: String,
            _ identity: ServiceAccountIdentity,
            _ expirationSeconds: Int64
        ) async throws -> RefreshedToken

    private struct Credential: Sendable {
        var token: String?
        var identity: ServiceAccountIdentity?
        var expiration: Date?

        init(token: String?) {
            self.token = token
            let claims = token.flatMap(ServiceAccountJWTClaims.parse)
            self.identity = claims?.identity
            self.expiration = claims?.expiration
        }

        init(token: String?, identity: ServiceAccountIdentity?, expiration: Date?) {
            self.token = token
            self.identity = identity
            self.expiration = expiration
        }
    }
}

private enum KubernetesServiceAccountTokenRequester {
    static func request(
        server: URL,
        session: URLSession,
        currentToken: String,
        identity: KubernetesServiceAccountTokenProvider.ServiceAccountIdentity,
        expirationSeconds: Int64
    ) async throws -> KubernetesServiceAccountTokenProvider.RefreshedToken {
        guard isValidPathSegment(identity.namespace), isValidPathSegment(identity.name) else {
            throw KubernetesServiceAccountTokenError.invalidRefreshResponse("token contains an invalid ServiceAccount identity")
        }
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            throw KubernetesServiceAccountTokenError.refreshRequestFailed("invalid Kubernetes API server URL")
        }
        components.path = "/api/v1/namespaces/\(identity.namespace)/serviceaccounts/\(identity.name)/token"
        components.query = nil
        guard let url = components.url else {
            throw KubernetesServiceAccountTokenError.refreshRequestFailed("failed to construct TokenRequest URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            TokenRequest(
                apiVersion: "authentication.k8s.io/v1",
                kind: "TokenRequest",
                spec: TokenRequest.Spec(expirationSeconds: expirationSeconds)
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KubernetesServiceAccountTokenError.refreshRequestFailed("response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body =
                String(data: data.prefix(4_096), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw KubernetesServiceAccountTokenError.refreshRequestFailed(
                "POST \(url.path) returned \(httpResponse.statusCode): \(body)"
            )
        }

        let decoded: TokenRequestResponse
        do {
            decoded = try JSONDecoder().decode(TokenRequestResponse.self, from: data)
        } catch {
            throw KubernetesServiceAccountTokenError.invalidRefreshResponse("response is not valid JSON")
        }
        guard let token = decoded.status?.token, !token.isEmpty else {
            throw KubernetesServiceAccountTokenError.invalidRefreshResponse("response contains no token")
        }
        guard let expirationText = decoded.status?.expirationTimestamp,
            let expiration = parseRFC3339(expirationText)
        else {
            throw KubernetesServiceAccountTokenError.invalidRefreshResponse(
                "response contains no valid expirationTimestamp"
            )
        }
        return KubernetesServiceAccountTokenProvider.RefreshedToken(token: token, expiration: expiration)
    }

    private static func isValidPathSegment(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

private struct TokenRequest: Encodable {
    var apiVersion: String
    var kind: String
    var spec: Spec

    struct Spec: Encodable {
        var expirationSeconds: Int64
    }
}

private struct TokenRequestResponse: Decodable {
    var status: Status?

    struct Status: Decodable {
        var token: String?
        var expirationTimestamp: String?
    }
}

private struct ServiceAccountJWTClaims {
    var identity: KubernetesServiceAccountTokenProvider.ServiceAccountIdentity
    var expiration: Date

    static func parse(_ token: String) -> ServiceAccountJWTClaims? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
            let payload = decodeBase64URL(segments[1]),
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let subject = object["sub"] as? String,
            let expirationNumber = object["exp"] as? NSNumber
        else {
            return nil
        }

        let subjectParts = subject.split(separator: ":", omittingEmptySubsequences: false)
        guard subjectParts.count == 4,
            subjectParts[0] == "system",
            subjectParts[1] == "serviceaccount",
            !subjectParts[2].isEmpty,
            !subjectParts[3].isEmpty
        else {
            return nil
        }
        return ServiceAccountJWTClaims(
            identity: KubernetesServiceAccountTokenProvider.ServiceAccountIdentity(
                namespace: String(subjectParts[2]),
                name: String(subjectParts[3])
            ),
            expiration: Date(timeIntervalSince1970: expirationNumber.doubleValue)
        )
    }

    private static func decodeBase64URL(_ value: Substring) -> Data? {
        var encoded = String(value)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        guard remainder != 1 else {
            return nil
        }
        if remainder > 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: encoded)
    }
}
