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

/// Host log paths for a sandbox and its helper processes.
public struct SandboxLogPaths: Sendable, Codable, Equatable {
    /// Host path to the sandbox event log.
    public var eventLogPath: String
    /// Host path to the sandbox boot log.
    public var bootLogPath: String
    /// Host path to the mirrored guest-agent stdout log, if present.
    public var guestAgentLogPath: String?
    /// Host path to the mirrored guest-agent stderr log, if present.
    public var guestAgentStderrLogPath: String?
    /// Host path to the sandbox network audit log, if present.
    public var networkAuditLogPath: String?

    public init(
        eventLogPath: String,
        bootLogPath: String,
        guestAgentLogPath: String? = nil,
        guestAgentStderrLogPath: String? = nil,
        networkAuditLogPath: String? = nil
    ) {
        self.eventLogPath = eventLogPath
        self.bootLogPath = bootLogPath
        self.guestAgentLogPath = guestAgentLogPath
        self.guestAgentStderrLogPath = guestAgentStderrLogPath
        self.networkAuditLogPath = networkAuditLogPath
    }
}
