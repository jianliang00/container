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

public enum FlannelBootstrapContextOutcome: Sendable, Equatable {
    case ready
    case reexecuted(exitCode: Int32)
}

public struct FlannelBootstrapContext {
    typealias ManagerUserIDProvider = () throws -> Int
    typealias Reexecutor = (
        _ userID: Int,
        _ executablePath: String,
        _ arguments: [String],
        _ environment: [String: String]
    ) throws -> Int32

    private static let reexecutionEnvironmentKey = "_CONTAINER_FLANNEL_VXLAN_MACOS_BOOTSTRAP_UID"

    private let managerUserID: ManagerUserIDProvider
    private let reexecute: Reexecutor

    public init() {
        self.init(
            managerUserID: Self.currentManagerUserID,
            reexecute: Self.runAsUser
        )
    }

    init(
        managerUserID: @escaping ManagerUserIDProvider,
        reexecute: @escaping Reexecutor
    ) {
        self.managerUserID = managerUserID
        self.reexecute = reexecute
    }

    public func ensure(
        containerServiceUserID: Int,
        executablePath: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> FlannelBootstrapContextOutcome {
        guard containerServiceUserID >= 0 else {
            throw FlannelVXLANError.invalidConfiguration("containerServiceUserID must be non-negative")
        }
        guard containerServiceUserID != 0 else {
            return .ready
        }

        let currentUserID = try managerUserID()
        guard currentUserID != containerServiceUserID else {
            return .ready
        }
        guard environment[Self.reexecutionEnvironmentKey] == nil else {
            throw FlannelVXLANError.runtime(
                "launchctl asuser did not enter bootstrap context for uid \(containerServiceUserID)"
            )
        }
        guard !executablePath.isEmpty else {
            throw FlannelVXLANError.runtime("cannot re-execute Flannel without an executable path")
        }

        var childEnvironment = environment
        childEnvironment[Self.reexecutionEnvironmentKey] = String(containerServiceUserID)
        let exitCode = try reexecute(
            containerServiceUserID,
            executablePath,
            arguments,
            childEnvironment
        )
        return .reexecuted(exitCode: exitCode)
    }

    private static func currentManagerUserID() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["manageruid"]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let error = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = error.isEmpty ? "" : ": \(error)"
            throw FlannelVXLANError.runtime(
                "launchctl manageruid failed with status \(process.terminationStatus)\(suffix)"
            )
        }
        guard let userID = Int(output), userID >= 0 else {
            throw FlannelVXLANError.runtime("launchctl manageruid returned invalid uid \(output)")
        }
        return userID
    }

    private static func runAsUser(
        userID: Int,
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["asuser", String(userID), executablePath] + arguments
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()
        switch process.terminationReason {
        case .exit:
            return process.terminationStatus
        case .uncaughtSignal:
            return process.terminationStatus + 128
        @unknown default:
            return 1
        }
    }
}
