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

public struct CRIShimCNIResult: Equatable, Sendable {
    public var networkName: String
    public var interfaceName: String
    public var sandboxURI: String
    public var podIPs: [String]

    public init(
        networkName: String,
        interfaceName: String,
        sandboxURI: String,
        podIPs: [String] = []
    ) {
        self.networkName = networkName
        self.interfaceName = interfaceName
        self.sandboxURI = sandboxURI
        self.podIPs = podIPs
    }
}

public protocol CRIShimCNIManaging: Sendable {
    func add(
        sandboxID: String,
        networkName: String,
        config: CRIShimConfig
    ) async throws -> CRIShimCNIResult

    func delete(
        sandboxID: String,
        networkName: String,
        config: CRIShimConfig
    ) async throws
}

public struct ProcessCRIShimCNIManager: CRIShimCNIManaging {
    public init() {}

    public func add(
        sandboxID: String,
        networkName: String,
        config: CRIShimConfig
    ) async throws -> CRIShimCNIResult {
        let invocation = try makeInvocation(
            command: "ADD",
            sandboxID: sandboxID,
            networkName: networkName,
            config: config
        )
        let output = try await run(invocation)
        return try decodeResult(output, networkName: networkName)
    }

    public func delete(
        sandboxID: String,
        networkName: String,
        config: CRIShimConfig
    ) async throws {
        let invocation = try makeInvocation(
            command: "DEL",
            sandboxID: sandboxID,
            networkName: networkName,
            config: config
        )
        _ = try await run(invocation)
    }

    private func makeInvocation(
        command: String,
        sandboxID: String,
        networkName: String,
        config: CRIShimConfig
    ) throws -> CNIInvocation {
        let networkName = networkName.trimmed
        guard !networkName.isEmpty else {
            throw CRIShimError.invalidArgument("CNI network name is required")
        }
        let cni = try resolvedCNIConfig(config)
        let pluginURL = try pluginURL(binDir: cni.binDir, plugin: cni.plugin)
        let configData = try pluginConfigData(
            confDir: cni.confDir,
            plugin: cni.plugin,
            networkName: networkName
        )
        let sandboxURI = "macvmnet://sandbox/\(sandboxID)"
        return CNIInvocation(
            executableURL: pluginURL,
            stdin: configData,
            environment: [
                "CNI_COMMAND": command,
                "CNI_CONTAINERID": sandboxID,
                "CNI_NETNS": sandboxURI,
                "CNI_IFNAME": "eth0",
                "CNI_PATH": cni.binDir,
            ],
            networkName: networkName
        )
    }

    private func resolvedCNIConfig(_ config: CRIShimConfig) throws -> ResolvedCNIConfig {
        guard let cni = config.cni else {
            throw CRIShimError.invalidArgument("cni config is required")
        }

        guard let binDir = cni.binDir?.trimmed, !binDir.isEmpty else {
            throw CRIShimError.invalidArgument("cni.binDir is required")
        }
        guard let confDir = cni.confDir?.trimmed, !confDir.isEmpty else {
            throw CRIShimError.invalidArgument("cni.confDir is required")
        }
        guard let plugin = cni.plugin?.trimmed, !plugin.isEmpty else {
            throw CRIShimError.invalidArgument("cni.plugin is required")
        }

        return ResolvedCNIConfig(binDir: binDir, confDir: confDir, plugin: plugin)
    }

    private func pluginURL(binDir: String, plugin: String) throws -> URL {
        let binDirURL = URL(fileURLWithPath: binDir, isDirectory: true)
        let candidates = [
            binDirURL.appendingPathComponent(plugin, isDirectory: false),
            binDirURL.appendingPathComponent("container-cni-\(plugin)", isDirectory: false),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw CRIShimError.notFound(
            "CNI plugin \(plugin) not found in \(binDir); tried \(candidates.map(\.path).joined(separator: ", "))"
        )
    }

    private func pluginConfigData(confDir: String, plugin: String, networkName: String) throws -> Data {
        let confDirURL = URL(fileURLWithPath: confDir, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: confDirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let candidates =
            entries
            .filter { ["conf", "conflist", "json"].contains($0.pathExtension) }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        for candidate in candidates {
            let data = try Data(contentsOf: candidate)
            if let config = try pluginConfigData(data, plugin: plugin, networkName: networkName) {
                return config
            }
        }
        throw CRIShimError.notFound(
            "CNI config for network \(networkName) and plugin \(plugin) not found in \(confDir)"
        )
    }

    private func pluginConfigData(_ data: Data, plugin: String, networkName: String) throws -> Data? {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else {
            return nil
        }
        guard object["name"] as? String == networkName else {
            return nil
        }
        if object["type"] as? String == plugin {
            return data
        }

        let plugins = object["plugins"] as? [[String: Any]] ?? []
        guard var pluginConfig = plugins.first(where: { $0["type"] as? String == plugin }) else {
            return nil
        }

        pluginConfig["name"] = networkName
        if pluginConfig["cniVersion"] == nil {
            pluginConfig["cniVersion"] = object["cniVersion"]
        }
        return try JSONSerialization.data(withJSONObject: pluginConfig, options: [.sortedKeys])
    }

    private func run(_ invocation: CNIInvocation) async throws -> Data {
        try await Task.detached {
            try runSync(invocation)
        }.value
    }

    private func runSync(_ invocation: CNIInvocation) throws -> Data {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.environment = invocation.environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(invocation.stdin)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorOutput.isEmpty ? output : errorOutput, encoding: .utf8) ?? ""
            throw CRIShimError.internalError("CNI \(invocation.environment["CNI_COMMAND"] ?? "") failed: \(detail)")
        }
        return output
    }

    private func decodeResult(_ data: Data, networkName: String) throws -> CRIShimCNIResult {
        let result = try JSONDecoder().decode(CNIResultPayload.self, from: data)
        let interfaces = result.interfaces ?? []
        let ips = result.ips ?? []
        let interfaceName = interfaces.first?.name ?? "eth0"
        let sandboxURI = interfaces.first?.sandbox ?? ""
        return CRIShimCNIResult(
            networkName: networkName,
            interfaceName: interfaceName,
            sandboxURI: sandboxURI,
            podIPs: ips.map(\.address)
        )
    }
}

private struct ResolvedCNIConfig: Sendable {
    var binDir: String
    var confDir: String
    var plugin: String
}

private struct CNIInvocation: Sendable {
    var executableURL: URL
    var stdin: Data
    var environment: [String: String]
    var networkName: String
}

private struct CNIResultPayload: Decodable {
    struct Interface: Decodable {
        var name: String
        var sandbox: String?
    }

    struct IP: Decodable {
        var address: String
    }

    var interfaces: [Interface]?
    var ips: [IP]?
}
