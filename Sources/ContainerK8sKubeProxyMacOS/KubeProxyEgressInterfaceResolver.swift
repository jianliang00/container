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

public protocol KubeProxyEgressInterfaceResolving: Sendable {
    func resolveDefaultIPv4EgressInterface() throws -> String
}

public struct KubeProxyDefaultIPv4EgressInterfaceResolver: KubeProxyEgressInterfaceResolving {
    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> String

    private let commandRunner: CommandRunner

    public init() {
        self.commandRunner = Self.runProcess
    }

    init(commandRunner: @escaping CommandRunner) {
        self.commandRunner = commandRunner
    }

    public func resolveDefaultIPv4EgressInterface() throws -> String {
        let output = try commandRunner("/sbin/route", ["-n", "get", "default"])
        let interfaces = output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "interface:" else {
                return nil
            }
            return String(fields[1])
        }
        guard interfaces.count == 1, let interface = interfaces.first,
            interface.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        else {
            throw KubeProxyMacOSError.applyFailed(
                "default IPv4 route did not identify exactly one valid egress interface"
            )
        }
        return interface
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw KubeProxyMacOSError.applyFailed("failed to inspect the default IPv4 route: \(error)")
        }
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw KubeProxyMacOSError.applyFailed(
                "failed to inspect the default IPv4 route with status \(process.terminationStatus): \(message)"
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
