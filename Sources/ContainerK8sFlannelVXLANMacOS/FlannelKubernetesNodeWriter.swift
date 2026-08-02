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

struct FlannelNodePatchRequest: Sendable {
    var url: URL
    var certificateAuthorityDER: Data
    var clientCertificate: Data
    var clientKey: Data
    var body: Data
}

protocol FlannelNodeAnnotationTransport: Sendable {
    func patch(_ request: FlannelNodePatchRequest) async throws -> Data
}

final class FlannelKubernetesNodeWriter: FlannelKubernetesWriting, @unchecked Sendable {
    private let kubeconfigURL: URL
    private let nodeName: String
    private let transport: any FlannelNodeAnnotationTransport

    init(
        kubeconfigPath: String,
        nodeName: String,
        transport: any FlannelNodeAnnotationTransport = FlannelCurlNodeAnnotationTransport()
    ) throws {
        guard kubeconfigPath.hasPrefix("/") else {
            throw FlannelVXLANError.invalidConfiguration("node kubeconfig must be an absolute path")
        }
        guard !nodeName.isEmpty, !nodeName.contains("/"), nodeName != ".", nodeName != ".." else {
            throw FlannelVXLANError.invalidConfiguration("nodeName is not a valid Kubernetes resource name")
        }
        self.kubeconfigURL = URL(fileURLWithPath: kubeconfigPath)
        self.nodeName = nodeName
        self.transport = transport
    }

    func patchOwnNodeAnnotations(_ patch: FlannelNodeAnnotationPatch) async throws -> FlannelNode {
        let config: KubeProxyKubeconfigClientConfig
        do {
            config = try KubeProxyKubeconfig.load(from: kubeconfigURL)
        } catch {
            throw FlannelVXLANError.invalidConfiguration("failed to load node kubeconfig: \(error)")
        }
        guard config.server.scheme?.lowercased() == "https", config.server.host != nil else {
            throw FlannelVXLANError.invalidConfiguration("node kubeconfig Kubernetes API server must use HTTPS")
        }
        guard !config.insecureSkipTLSVerify else {
            throw FlannelVXLANError.invalidConfiguration("node kubeconfig cannot skip TLS verification")
        }
        guard let certificateAuthorityDER = config.certificateAuthorityData, !certificateAuthorityDER.isEmpty else {
            throw FlannelVXLANError.invalidConfiguration("node kubeconfig must contain a certificate authority")
        }
        guard let clientCertificate = config.clientCertificateData, !clientCertificate.isEmpty else {
            throw FlannelVXLANError.invalidConfiguration("node kubeconfig must contain a client certificate")
        }
        guard let clientKey = config.clientKeyData, !clientKey.isEmpty else {
            throw FlannelVXLANError.invalidConfiguration("node kubeconfig must contain a client key")
        }
        guard var components = URLComponents(url: config.server, resolvingAgainstBaseURL: false) else {
            throw FlannelVXLANError.invalidConfiguration("invalid node kubeconfig Kubernetes API server URL")
        }
        components.path = "/api/v1/nodes/\(nodeName)/status"
        components.query = nil
        guard let url = components.url else {
            throw FlannelVXLANError.invalidConfiguration("failed to construct Node annotation patch URL")
        }

        let body = try FlannelKubernetesClient.annotationMergePatchData(patch)
        let data = try await transport.patch(
            FlannelNodePatchRequest(
                url: url,
                certificateAuthorityDER: certificateAuthorityDER,
                clientCertificate: clientCertificate,
                clientKey: clientKey,
                body: body
            ))
        do {
            return try JSONDecoder().decode(FlannelNode.self, from: data)
        } catch {
            throw FlannelVXLANError.kubernetesAPI("failed to decode Node annotation patch response: \(error)")
        }
    }
}

actor FlannelCurlNodeAnnotationTransport: FlannelNodeAnnotationTransport {
    private static let curlPath = "/usr/bin/curl"
    private static let opensslPath = "/usr/bin/openssl"
    private var cachedIdentity: CachedIdentity?

    func patch(_ request: FlannelNodePatchRequest) async throws -> Data {
        guard request.url.scheme?.lowercased() == "https" else {
            throw FlannelVXLANError.invalidConfiguration("Node annotation patch URL must use HTTPS")
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-flannel-node-client-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw FlannelVXLANError.persistence("failed to create private node client credential directory: \(error)")
        }
        defer { try? fileManager.removeItem(at: directory) }

        let caURL = directory.appendingPathComponent("ca.crt")
        let identityURL = directory.appendingPathComponent("client.p12")
        let responseURL = directory.appendingPathComponent("response.json")
        try writePrivate(Self.pemCertificate(request.certificateAuthorityDER), to: caURL)
        try writePrivate(
            try identityData(
                clientCertificate: request.clientCertificate,
                clientKey: request.clientKey,
                directory: directory
            ),
            to: identityURL
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.curlPath)
        process.arguments = Self.curlArguments(
            requestURL: request.url,
            caURL: caURL,
            identityURL: identityURL,
            responseURL: responseURL
        )

        let input = Pipe()
        let status = Pipe()
        let standardError = Pipe()
        process.standardInput = input
        process.standardOutput = status
        process.standardError = standardError

        do {
            try process.run()
            input.fileHandleForWriting.write(request.body)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            try? input.fileHandleForWriting.close()
            throw FlannelVXLANError.kubernetesAPI("failed to execute HTTPS Node annotation patch: \(error)")
        }

        let statusText =
            String(
                data: status.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorText =
            String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let response = (try? Data(contentsOf: responseURL)) ?? Data()
        let responseText =
            String(data: response.prefix(4_096), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = [errorText, responseText].filter { !$0.isEmpty }.joined(separator: ": ")
            throw FlannelVXLANError.kubernetesAPI(
                "HTTPS Node annotation patch failed with curl status \(process.terminationStatus): \(detail)"
            )
        }
        guard let httpStatus = Int(statusText), (200..<300).contains(httpStatus) else {
            guard let httpStatus = Int(statusText) else {
                throw FlannelVXLANError.kubernetesAPI(
                    "PATCH \(request.url.path) returned an unknown HTTP status: \(responseText)"
                )
            }
            throw FlannelVXLANError.kubernetesAPIStatus(
                code: httpStatus,
                path: "PATCH \(request.url.path)",
                message: responseText
            )
        }
        return response
    }

    static func curlArguments(
        requestURL: URL,
        caURL: URL,
        identityURL: URL,
        responseURL: URL
    ) -> [String] {
        [
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--connect-timeout",
            "10",
            "--max-time",
            "30",
            "--request",
            "PATCH",
            "--header",
            "Accept: application/json",
            "--header",
            "Content-Type: application/merge-patch+json",
            "--cacert",
            caURL.path,
            "--cert",
            "\(identityURL.path):",
            "--cert-type",
            "P12",
            "--data-binary",
            "@-",
            "--output",
            responseURL.path,
            "--write-out",
            "%{http_code}",
            requestURL.absoluteString,
        ]
    }

    private func identityData(clientCertificate: Data, clientKey: Data, directory: URL) throws -> Data {
        if let cachedIdentity,
            cachedIdentity.clientCertificate == clientCertificate,
            cachedIdentity.clientKey == clientKey
        {
            return cachedIdentity.pkcs12
        }

        let certificateURL = directory.appendingPathComponent("client.crt")
        let keyURL = directory.appendingPathComponent("client.key")
        let outputURL = directory.appendingPathComponent("generated-client.p12")
        try writePrivate(Self.pemCertificate(clientCertificate), to: certificateURL)
        try writePrivate(clientKey, to: keyURL)
        try makePKCS12(certificateURL: certificateURL, keyURL: keyURL, outputURL: outputURL)
        let pkcs12: Data
        do {
            pkcs12 = try Data(contentsOf: outputURL)
        } catch {
            throw FlannelVXLANError.persistence("failed to load prepared node client identity: \(error)")
        }
        cachedIdentity = CachedIdentity(
            clientCertificate: clientCertificate,
            clientKey: clientKey,
            pkcs12: pkcs12
        )
        return pkcs12
    }

    private func makePKCS12(certificateURL: URL, keyURL: URL, outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.opensslPath)
        process.arguments = [
            "pkcs12",
            "-export",
            "-in",
            certificateURL.path,
            "-inkey",
            keyURL.path,
            "-out",
            outputURL.path,
            "-passout",
            "pass:",
        ]
        let standardError = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FlannelVXLANError.persistence("failed to prepare node client identity: \(error)")
        }
        let errorText =
            String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw FlannelVXLANError.invalidConfiguration(
                "node kubeconfig client certificate and key could not form an identity: \(errorText)"
            )
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: outputURL.path
            )
        } catch {
            throw FlannelVXLANError.persistence("failed to protect node client identity: \(error)")
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch {
            throw FlannelVXLANError.persistence("failed to stage node client credential: \(error)")
        }
    }

    private static func pemCertificate(_ data: Data) -> Data {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            return data
        }
        let encoded = data.base64EncodedString()
        let lines = stride(from: 0, to: encoded.count, by: 64).map { offset -> String in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(64, encoded.distance(from: start, to: encoded.endIndex)))
            return String(encoded[start..<end])
        }
        return Data(
            (["-----BEGIN CERTIFICATE-----"] + lines + ["-----END CERTIFICATE-----", ""])
                .joined(separator: "\n").utf8
        )
    }

    private struct CachedIdentity {
        var clientCertificate: Data
        var clientKey: Data
        var pkcs12: Data
    }
}
