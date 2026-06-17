//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerizationError
import Foundation

public struct ServiceManager {
    private static let bootoutPollIntervalSeconds = 0.1
    private static let bootoutTimeoutSeconds = 5.0

    private struct LaunchctlCommandResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var combinedOutput: String {
            [stdout, stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private static func decodeOutput(data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    private static func runLaunchctlCommand(args: [String], captureOutput: Bool) throws -> LaunchctlCommandResult {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = args

        guard captureOutput else {
            let null = FileHandle.nullDevice
            launchctl.standardOutput = null
            launchctl.standardError = null

            try launchctl.run()
            launchctl.waitUntilExit()

            return LaunchctlCommandResult(
                status: launchctl.terminationStatus,
                stdout: "",
                stderr: ""
            )
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        launchctl.standardOutput = stdoutPipe
        launchctl.standardError = stderrPipe

        try launchctl.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()

        return LaunchctlCommandResult(
            status: launchctl.terminationStatus,
            stdout: decodeOutput(data: stdoutData),
            stderr: decodeOutput(data: stderrData)
        )
    }

    private static func runLaunchctlCommand(args: [String]) throws -> Int32 {
        try runLaunchctlCommand(args: args, captureOutput: false).status
    }

    private static func runLaunchctlCommandChecked(args: [String]) throws {
        let result = try runLaunchctlCommand(args: args, captureOutput: true)
        guard result.status == 0 else {
            try throwLaunchctlCommandFailure(args: args, result: result)
        }
    }

    private static func throwLaunchctlCommandFailure(args: [String], result: LaunchctlCommandResult) throws -> Never {
        let command = (["launchctl"] + args).joined(separator: " ")
        let output = result.combinedOutput
        let details = output.isEmpty ? "" : ", output: \(output)"
        throw ContainerizationError(
            .internalError,
            message: "command `\(command)` failed with status \(result.status)\(details)"
        )
    }

    /// Register a service by providing the path to a plist.
    public static func register(plistPath: String) throws {
        let domain = try Self.getDomainString()
        let serviceLabel = try Self.serviceLabel(plistPath: plistPath)
        if let serviceLabel, try Self.isRegistered(fullServiceLabel: fullServiceLabel(serviceLabel, domain: domain)) {
            return
        }

        let args = ["bootstrap", domain, plistPath]
        let result = try runLaunchctlCommand(args: args, captureOutput: true)
        if result.status == 0 {
            return
        }
        if let serviceLabel, try Self.isRegistered(fullServiceLabel: fullServiceLabel(serviceLabel, domain: domain)) {
            return
        }

        try throwLaunchctlCommandFailure(args: args, result: result)
    }

    /// Deregister a service by a launchd label.
    public static func deregister(fullServiceLabel label: String) throws {
        let result = try runLaunchctlCommand(args: ["bootout", label], captureOutput: true)
        if result.status == 0 {
            try waitForServiceToDisappear(fullServiceLabel: label)
            return
        }

        let output = result.combinedOutput
        if result.status == 3 && output.contains("No such process") {
            return
        }

        let command = "launchctl bootout \(label)"
        let details = output.isEmpty ? "" : ", output: \(output)"
        throw ContainerizationError(
            .internalError,
            message: "command `\(command)` failed with status \(result.status)\(details)"
        )
    }

    /// Deregister a service and pass return status
    public static func deregister(fullServiceLabel label: String, status: inout Int32) throws {
        status = try runLaunchctlCommand(args: ["bootout", label])
    }

    /// Restart a service by a launchd label.
    public static func kickstart(fullServiceLabel label: String) throws {
        try runLaunchctlCommandChecked(args: ["kickstart", "-k", label])
    }

    /// Send a signal to a service by a launchd label.
    public static func kill(fullServiceLabel label: String, signal: Int32 = 15) throws {
        try runLaunchctlCommandChecked(args: ["kill", "\(signal)", label])
    }

    /// Retrieve labels for all loaded launch units.
    public static func enumerate() throws -> [String] {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["list"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        launchctl.standardOutput = stdoutPipe
        launchctl.standardError = stderrPipe

        try launchctl.run()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()
        let status = launchctl.terminationStatus
        guard status == 0 else {
            throw ContainerizationError(
                .internalError, message: "command `launchctl list` failed with status \(status), message: \(String(data: stderrData, encoding: .utf8) ?? "no error message")")
        }

        guard let outputText = String(data: outputData, encoding: .utf8) else {
            throw ContainerizationError(
                .internalError, message: "could not decode output of command `launchctl list`, message: \(String(data: stderrData, encoding: .utf8) ?? "no error message")")
        }

        // The third field of each line of launchctl list output is the label
        return outputText.split { $0.isNewline }
            .map { String($0).split { $0.isWhitespace } }
            .filter { $0.count >= 3 }
            .map { String($0[2]) }
    }

    /// Check if a service has been registered or not.
    public static func isRegistered(fullServiceLabel label: String) throws -> Bool {
        let label = try fullServiceLabel(label)
        let result = try runLaunchctlCommand(args: ["print", label], captureOutput: true)
        return result.status == 0
    }

    private static func getLaunchdSessionType() throws -> String {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["managername"]

        let null = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        launchctl.standardOutput = stdoutPipe
        launchctl.standardError = null

        try launchctl.run()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()
        let status = launchctl.terminationStatus
        guard status == 0 else {
            throw ContainerizationError(.internalError, message: "command `launchctl managername` failed with status \(status)")
        }
        guard let outputText = String(data: outputData, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "could not decode output of command `launchctl managername`")
        }
        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func getDomainString() throws -> String {
        let currentSessionType = try getLaunchdSessionType()
        switch currentSessionType {
        case LaunchPlist.Domain.System.rawValue:
            return LaunchPlist.Domain.System.rawValue.lowercased()
        case LaunchPlist.Domain.Background.rawValue:
            return "user/\(getuid())"
        case LaunchPlist.Domain.Aqua.rawValue:
            return "gui/\(getuid())"
        default:
            throw ContainerizationError(.internalError, message: "unsupported session type \(currentSessionType)")
        }
    }

    private static func fullServiceLabel(_ label: String, domain: String? = nil) throws -> String {
        if label.contains("/") {
            return label
        }
        let domain = try domain ?? Self.getDomainString()
        return "\(domain)/\(label)"
    }

    private static func serviceLabel(plistPath: String) throws -> String? {
        let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary["Label"] as? String
    }

    private static func waitForServiceToDisappear(fullServiceLabel label: String) throws {
        let launchdLabel = String(label.split(separator: "/").last ?? Substring(label))
        let deadline = Date().addingTimeInterval(Self.bootoutTimeoutSeconds)

        while Date() < deadline {
            if try !Self.isRegistered(fullServiceLabel: label) {
                return
            }
            Thread.sleep(forTimeInterval: Self.bootoutPollIntervalSeconds)
        }

        throw ContainerizationError(
            .timeout,
            message: "timed out waiting for launchd to remove service `\(launchdLabel)`"
        )
    }
}
