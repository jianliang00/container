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

public struct CNIEnvironment: Equatable {
    public var command: CNICommand
    public var containerID: String?
    public var netns: String?
    public var ifName: String?
    public var rawArguments: String?
    public var arguments: [String: String]
    public var path: [String]

    public init(
        command: CNICommand,
        containerID: String? = nil,
        netns: String? = nil,
        ifName: String? = nil,
        rawArguments: String? = nil,
        arguments: [String: String] = [:],
        path: [String] = []
    ) {
        self.command = command
        self.containerID = containerID
        self.netns = netns
        self.ifName = ifName
        self.rawArguments = rawArguments
        self.arguments = arguments
        self.path = path
    }

    public static func parse(_ environment: [String: String]) throws -> CNIEnvironment {
        guard let commandValue = environment["CNI_COMMAND"], !commandValue.isEmpty else {
            throw CNIError.missingEnvironment("CNI_COMMAND")
        }
        guard let command = CNICommand(rawValue: commandValue) else {
            throw CNIError.invalidCommand(commandValue)
        }

        let rawArguments = environment["CNI_ARGS"]
        let arguments = try rawArguments.map(parseArguments) ?? [:]
        let path = try environment["CNI_PATH"].map(parsePath) ?? []

        let parsed = CNIEnvironment(
            command: command,
            containerID: environment["CNI_CONTAINERID"],
            netns: environment["CNI_NETNS"],
            ifName: environment["CNI_IFNAME"],
            rawArguments: rawArguments,
            arguments: arguments,
            path: path
        )
        try parsed.validate()
        return parsed
    }

    private func validate() throws {
        switch command {
        case .add, .check:
            try require("CNI_CONTAINERID", containerID)
            try require("CNI_NETNS", netns)
            try require("CNI_IFNAME", ifName)
        case .delete:
            try require("CNI_CONTAINERID", containerID)
            try require("CNI_IFNAME", ifName)
        case .garbageCollect, .status, .version:
            break
        }
    }

    private static func parseArguments(_ rawValue: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for segment in rawValue.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else {
                throw CNIError.invalidArguments(rawValue)
            }
            values[String(parts[0])] = String(parts[1])
        }
        return values
    }

    private static func parsePath(_ rawValue: String) throws -> [String] {
        let entries = rawValue.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !entries.contains(where: { $0.isEmpty }) else {
            throw CNIError.invalidPath(rawValue)
        }
        return entries
    }

    private func require(_ name: String, _ value: String?) throws {
        guard let value, !value.isEmpty else {
            throw CNIError.missingEnvironment(name)
        }
    }
}

public struct CNIRequest: Equatable {
    public var environment: CNIEnvironment
    public var config: CNIPluginConfig
    public var sandbox: CNISandboxURI?
    public var validAttachments: Set<MacvmnetAttachmentIdentity>

    public init(
        environment: CNIEnvironment,
        config: CNIPluginConfig,
        sandbox: CNISandboxURI? = nil,
        validAttachments: Set<MacvmnetAttachmentIdentity> = []
    ) {
        self.environment = environment
        self.config = config
        self.sandbox = sandbox
        self.validAttachments = validAttachments
    }

    public static func parse(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdin: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> CNIRequest {
        let parsedEnvironment = try CNIEnvironment.parse(environment)
        let config = try decoder.decode(CNIPluginConfig.self, from: stdin)
        try config.validate()
        let sandbox = try parsedEnvironment.netns.map(CNISandboxURI.init)
        try validateSandboxIdentity(environment: parsedEnvironment, sandbox: sandbox)
        let validAttachments =
            parsedEnvironment.command == .garbageCollect
            ? try config.validAttachments()
            : []
        return CNIRequest(
            environment: parsedEnvironment,
            config: config,
            sandbox: sandbox,
            validAttachments: validAttachments
        )
    }

    private static func validateSandboxIdentity(
        environment: CNIEnvironment,
        sandbox: CNISandboxURI?
    ) throws {
        switch environment.command {
        case .add, .check:
            guard let containerID = environment.containerID, let sandbox else {
                return
            }
            guard sandbox.sandboxID == containerID else {
                throw CNIError.invalidConfiguration("CNI_NETNS sandbox ID must match CNI_CONTAINERID")
            }
        case .delete, .garbageCollect, .status, .version:
            return
        }
    }
}
