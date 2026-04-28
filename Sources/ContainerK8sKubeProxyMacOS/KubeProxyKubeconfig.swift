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

public struct KubeProxyKubeconfigClientConfig: Sendable, Equatable {
    public var server: URL
    public var bearerToken: String?
    public var certificateAuthorityData: Data?
    public var insecureSkipTLSVerify: Bool

    public init(
        server: URL,
        bearerToken: String? = nil,
        certificateAuthorityData: Data? = nil,
        insecureSkipTLSVerify: Bool = false
    ) {
        self.server = server
        self.bearerToken = bearerToken
        self.certificateAuthorityData = certificateAuthorityData
        self.insecureSkipTLSVerify = insecureSkipTLSVerify
    }
}

public enum KubeProxyKubeconfig {
    public static func load(from url: URL) throws -> KubeProxyKubeconfigClientConfig {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(content, baseURL: url.deletingLastPathComponent())
    }

    public static func parse(_ content: String, baseURL: URL) throws -> KubeProxyKubeconfigClientConfig {
        let raw = try parseRaw(content)
        let contextName = raw.currentContext ?? raw.contexts.first?.name
        guard let contextName else {
            throw KubeProxyMacOSError.invalidKubeconfig("current-context is required")
        }
        guard let context = raw.contexts.first(where: { $0.name == contextName }) else {
            throw KubeProxyMacOSError.invalidKubeconfig("context \(contextName) was not found")
        }
        guard let clusterName = context.cluster else {
            throw KubeProxyMacOSError.invalidKubeconfig("context \(contextName) does not reference a cluster")
        }
        guard let cluster = raw.clusters.first(where: { $0.name == clusterName }) else {
            throw KubeProxyMacOSError.invalidKubeconfig("cluster \(clusterName) was not found")
        }
        guard let serverValue = cluster.server, let server = URL(string: serverValue) else {
            throw KubeProxyMacOSError.invalidKubeconfig("cluster \(clusterName) has an invalid server")
        }

        let user = context.user.flatMap { userName in
            raw.users.first { $0.name == userName }
        }

        return KubeProxyKubeconfigClientConfig(
            server: server,
            bearerToken: try resolveToken(user, baseURL: baseURL),
            certificateAuthorityData: try resolveCertificateAuthorityData(cluster, baseURL: baseURL),
            insecureSkipTLSVerify: cluster.insecureSkipTLSVerify ?? false
        )
    }

    private static func resolveToken(_ user: RawUser?, baseURL: URL) throws -> String? {
        if let token = user?.token, !token.isEmpty {
            return token
        }
        guard let tokenFile = user?.tokenFile, !tokenFile.isEmpty else {
            return nil
        }
        let url = tokenFile.hasPrefix("/") ? URL(fileURLWithPath: tokenFile) : baseURL.appendingPathComponent(tokenFile)
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveCertificateAuthorityData(_ cluster: RawCluster, baseURL: URL) throws -> Data? {
        if let data = cluster.certificateAuthorityData, !data.isEmpty {
            guard let decoded = Data(base64Encoded: data) else {
                throw KubeProxyMacOSError.invalidKubeconfig("certificate-authority-data is not valid base64")
            }
            return pemToDER(decoded) ?? decoded
        }
        guard let path = cluster.certificateAuthority, !path.isEmpty else {
            return nil
        }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseURL.appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        return pemToDER(data) ?? data
    }

    private static func pemToDER(_ data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8), string.contains("-----BEGIN CERTIFICATE-----") else {
            return nil
        }
        let lines = string.components(separatedBy: .newlines).filter { line in
            !line.hasPrefix("-----BEGIN") && !line.hasPrefix("-----END") && !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return Data(base64Encoded: lines.joined())
    }

    private static func parseRaw(_ content: String) throws -> RawKubeconfig {
        var raw = RawKubeconfig()
        var section: RawSection = .root
        var subsection: RawSubsection = .none
        var cluster: RawCluster?
        var user: RawUser?
        var context: RawContext?

        func flushCurrent() {
            if let current = cluster, current.name != nil {
                raw.clusters.append(current)
            }
            if let current = user, current.name != nil {
                raw.users.append(current)
            }
            if let current = context, current.name != nil {
                raw.contexts.append(current)
            }
            cluster = nil
            user = nil
            context = nil
            subsection = .none
        }

        for line in content.components(separatedBy: .newlines) {
            let isTopLevel = !(line.first?.isWhitespace ?? false)
            let trimmed = stripInlineComment(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                continue
            }

            if isTopLevel, let value = value(after: "current-context:", in: trimmed) {
                flushCurrent()
                section = .root
                raw.currentContext = value
                continue
            }

            switch trimmed {
            case "clusters:":
                flushCurrent()
                section = .clusters
                continue
            case "users:":
                flushCurrent()
                section = .users
                continue
            case "contexts:":
                flushCurrent()
                section = .contexts
                continue
            default:
                break
            }

            if section == .root {
                if let value = value(after: "current-context:", in: trimmed) {
                    raw.currentContext = value
                }
                continue
            }

            if trimmed.hasPrefix("- ") {
                flushCurrent()
                subsection = .none
                switch section {
                case .clusters:
                    cluster = RawCluster()
                case .users:
                    user = RawUser()
                case .contexts:
                    context = RawContext()
                case .root:
                    break
                }
                let remainder = String(trimmed.dropFirst(2))
                if remainder == "cluster:" {
                    subsection = .cluster
                    continue
                }
                if remainder == "user:" {
                    subsection = .user
                    continue
                }
                if remainder == "context:" {
                    subsection = .context
                    continue
                }
                applyField(remainder, section: section, subsection: subsection, cluster: &cluster, user: &user, context: &context)
                continue
            }

            switch trimmed {
            case "cluster:":
                subsection = .cluster
            case "user:":
                subsection = .user
            case "context:":
                subsection = .context
            default:
                applyField(trimmed, section: section, subsection: subsection, cluster: &cluster, user: &user, context: &context)
            }
        }
        flushCurrent()

        return raw
    }

    private static func applyField(
        _ line: String,
        section: RawSection,
        subsection: RawSubsection,
        cluster: inout RawCluster?,
        user: inout RawUser?,
        context: inout RawContext?
    ) {
        if let value = value(after: "name:", in: line) {
            switch section {
            case .clusters:
                cluster?.name = value
            case .users:
                user?.name = value
            case .contexts:
                context?.name = value
            case .root:
                break
            }
            return
        }

        switch (section, subsection) {
        case (.clusters, .cluster):
            if let value = value(after: "server:", in: line) {
                cluster?.server = value
            } else if let value = value(after: "certificate-authority-data:", in: line) {
                cluster?.certificateAuthorityData = value
            } else if let value = value(after: "certificate-authority:", in: line) {
                cluster?.certificateAuthority = value
            } else if let value = value(after: "insecure-skip-tls-verify:", in: line) {
                cluster?.insecureSkipTLSVerify = parseBool(value)
            }
        case (.users, .user):
            if let value = value(after: "token:", in: line) {
                user?.token = value
            } else if let value = value(after: "tokenFile:", in: line) ?? value(after: "token-file:", in: line) {
                user?.tokenFile = value
            }
        case (.contexts, .context):
            if let value = value(after: "cluster:", in: line) {
                context?.cluster = value
            } else if let value = value(after: "user:", in: line) {
                context?.user = value
            }
        default:
            break
        }
    }

    private static func value(after key: String, in line: String) -> String? {
        guard line.hasPrefix(key) else {
            return nil
        }
        let value = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return stripQuotes(String(value))
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func stripQuotes(_ value: String) -> String {
        if value.count >= 2,
            let first = value.first,
            let last = value.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func stripInlineComment(_ line: String) -> String {
        guard let index = line.firstIndex(of: "#") else {
            return line
        }
        return String(line[..<index])
    }
}

private enum RawSection {
    case root
    case clusters
    case users
    case contexts
}

private enum RawSubsection {
    case none
    case cluster
    case user
    case context
}

private struct RawKubeconfig {
    var currentContext: String?
    var clusters: [RawCluster] = []
    var users: [RawUser] = []
    var contexts: [RawContext] = []
}

private struct RawCluster {
    var name: String?
    var server: String?
    var certificateAuthorityData: String?
    var certificateAuthority: String?
    var insecureSkipTLSVerify: Bool?
}

private struct RawUser {
    var name: String?
    var token: String?
    var tokenFile: String?
}

private struct RawContext {
    var name: String?
    var cluster: String?
    var user: String?
}
