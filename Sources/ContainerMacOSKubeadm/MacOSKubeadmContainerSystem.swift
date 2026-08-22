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

import Darwin
import Foundation

public enum MacOSKubeadmContainerSystem {
    public static let bootstrapLaunchdLabel = "com.apple.container.macos-node-bootstrap"
    public static let bootstrapLaunchdPlistPath = "/Library/LaunchDaemons/\(bootstrapLaunchdLabel).plist"

    public static func validateExistingConfiguration(
        requestedUserID: Int,
        bootstrapPlistPath: String,
        criShimPlistPath: String,
        flannelConfigurationPath: String,
        fileManager: FileManager = .default,
        requireLocalUser: Bool = true,
        userExists: (uid_t) -> Bool = { getpwuid($0) != nil }
    ) throws {
        try validate(userID: requestedUserID)

        var configuredUsers: [(source: String, userID: Int)] = []
        if fileManager.fileExists(atPath: bootstrapPlistPath) {
            configuredUsers.append(
                (
                    source: bootstrapPlistPath,
                    userID: try userID(
                        fromPlist: bootstrapPlistPath,
                        marker: "--container-service-user"
                    )
                )
            )
        }
        if fileManager.fileExists(atPath: criShimPlistPath) {
            configuredUsers.append(
                (
                    source: criShimPlistPath,
                    userID: try userID(fromPlist: criShimPlistPath, marker: "asuser")
                )
            )
        }
        if fileManager.fileExists(atPath: flannelConfigurationPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: flannelConfigurationPath))
                let configuration = try JSONDecoder().decode(PersistedFlannelConfiguration.self, from: data)
                configuredUsers.append(
                    (source: flannelConfigurationPath, userID: configuration.containerServiceUserID)
                )
            } catch {
                throw MacOSKubeadmError.preflightFailed(
                    "cannot read existing container service user from \(flannelConfigurationPath): \(error)"
                )
            }
        }

        let uniqueUsers = Set(configuredUsers.map(\.userID))
        guard uniqueUsers.count <= 1 else {
            let sources = configuredUsers.map { "\($0.source)=\($0.userID)" }.joined(separator: ", ")
            throw MacOSKubeadmError.preflightFailed(
                "existing container service user configuration is inconsistent (\(sources)); reset the node before joining"
            )
        }
        if let existingUserID = uniqueUsers.first, existingUserID != requestedUserID {
            throw MacOSKubeadmError.preflightFailed(
                "existing container service user uid \(existingUserID) differs from requested uid \(requestedUserID); rerun with --container-service-user \(existingUserID) or reset the node before changing users"
            )
        }
        guard
            !requireLocalUser
                || (uid_t(exactly: requestedUserID).map(userExists) ?? false)
        else {
            throw MacOSKubeadmError.preflightFailed(
                "container service user uid \(requestedUserID) does not identify a local account"
            )
        }
    }

    public static func userDomainBootstrapCommand(
        userID: Int,
        launchctlPath: String = "/bin/launchctl"
    ) throws -> [String]? {
        try validate(userID: userID)
        guard userID != 0 else {
            return nil
        }
        let script = """
            set -eu
            launchctl_path=$1
            domain=$2
            user_id=$3
            if "$launchctl_path" bootstrap "$domain"; then
                exit 0
            fi
            "$launchctl_path" asuser "$user_id" /usr/bin/true
            """
        return [
            "/bin/sh",
            "-c",
            script,
            "container-macos-kubeadm-user-domain",
            launchctlPath,
            "user/\(userID)",
            "\(userID)",
        ]
    }

    public static func command(userID: Int, subcommand: String) throws -> [String] {
        try validate(userID: userID)
        guard subcommand == "start" || subcommand == "stop" || subcommand == "status" else {
            throw MacOSKubeadmError.invalidInput("unsupported container system subcommand: \(subcommand)")
        }

        let containerCommand = ["/usr/local/bin/container", "system", subcommand]
        if userID == 0 {
            return ["/bin/launchctl", "asuser", "0"] + containerCommand
        }

        return [
            "/bin/launchctl",
            "asuser",
            "\(userID)",
            "/usr/bin/sudo",
            "-H",
            "-u",
            "#\(userID)",
        ] + containerCommand
    }

    public static func startCommands(userID: Int) throws -> [[String]] {
        var commands: [[String]] = []
        if let bootstrap = try userDomainBootstrapCommand(userID: userID) {
            commands.append(bootstrap)
        }
        commands.append(try command(userID: userID, subcommand: "start"))
        return commands
    }

    private static func validate(userID: Int) throws {
        guard userID >= 0 else {
            throw MacOSKubeadmError.invalidInput("--container-service-user must be a non-negative uid")
        }
        guard uid_t(exactly: userID) != nil else {
            throw MacOSKubeadmError.invalidInput(
                "--container-service-user exceeds the maximum uid \(uid_t.max)"
            )
        }
    }

    private static func userID(fromPlist path: String, marker: String) throws -> Int {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let object = propertyList as? [String: Any],
                let arguments = object["ProgramArguments"] as? [String],
                let markerIndex = arguments.firstIndex(of: marker),
                arguments.indices.contains(arguments.index(after: markerIndex)),
                let userID = Int(arguments[arguments.index(after: markerIndex)]),
                userID >= 0
            else {
                throw MacOSKubeadmError.preflightFailed(
                    "existing launchd plist does not identify a valid container service user: \(path)"
                )
            }
            return userID
        } catch let error as MacOSKubeadmError {
            throw error
        } catch {
            throw MacOSKubeadmError.preflightFailed(
                "cannot read existing container service user from \(path): \(error)"
            )
        }
    }

    private struct PersistedFlannelConfiguration: Decodable {
        var containerServiceUserID: Int

        private enum CodingKeys: String, CodingKey {
            case containerServiceUserID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            containerServiceUserID = try container.decodeIfPresent(Int.self, forKey: .containerServiceUserID) ?? 0
        }
    }
}

public struct MacOSKubeadmContainerSystemBootstrapRunner {
    public init() {}

    public func run(userID: Int, log: MacOSKubeadmLog) throws {
        guard geteuid() == 0 else {
            throw MacOSKubeadmError.preflightFailed("container system bootstrap must run as root")
        }

        for command in try MacOSKubeadmContainerSystem.startCommands(userID: userID) {
            try MacOSKubeadmProcess.run(command, bestEffort: false, log: log)
        }
    }
}
