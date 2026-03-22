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

/// Configuration for a workload that runs inside a sandbox.
public struct WorkloadConfiguration: Sendable, Codable {
    /// Identifier of the workload within the sandbox.
    public var id: String
    /// Process configuration used to start the workload.
    public var processConfiguration: ProcessConfiguration

    public init(id: String, processConfiguration: ProcessConfiguration) {
        self.id = id
        self.processConfiguration = processConfiguration
    }
}

/// A snapshot of workload runtime state inside a sandbox.
public struct WorkloadSnapshot: Sendable, Codable {
    /// Static workload configuration.
    public var configuration: WorkloadConfiguration
    /// Current runtime status of the workload.
    public var status: RuntimeStatus
    /// Exit code once the workload has stopped.
    public var exitCode: Int32?
    /// When the workload was started.
    public var startedDate: Date?
    /// When the workload exited.
    public var exitedAt: Date?
    /// Host path to the workload stdout log, if available.
    public var stdoutLogPath: String?
    /// Host path to the workload stderr log, if available.
    public var stderrLogPath: String?

    public var id: String {
        configuration.id
    }

    public init(
        configuration: WorkloadConfiguration,
        status: RuntimeStatus,
        exitCode: Int32? = nil,
        startedDate: Date? = nil,
        exitedAt: Date? = nil,
        stdoutLogPath: String? = nil,
        stderrLogPath: String? = nil
    ) {
        self.configuration = configuration
        self.status = status
        self.exitCode = exitCode
        self.startedDate = startedDate
        self.exitedAt = exitedAt
        self.stdoutLogPath = stdoutLogPath
        self.stderrLogPath = stderrLogPath
    }
}
