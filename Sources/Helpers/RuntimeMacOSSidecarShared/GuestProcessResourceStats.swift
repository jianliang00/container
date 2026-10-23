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

/// Resource usage of a workload process tree inside a macOS guest.
public struct GuestProcessResourceStats: Codable, Sendable, Equatable {
    public static let capability = "processResourceStatsV1"
    public let executionID: String
    public let timestampNanoseconds: Int64
    public let cpuUsageNanoseconds: UInt64
    /// Sum of process resident sets; shared pages can appear in more than one process.
    public let residentMemoryBytes: UInt64
    public let processCount: UInt64

    public init(
        executionID: String, timestampNanoseconds: Int64, cpuUsageNanoseconds: UInt64,
        residentMemoryBytes: UInt64, processCount: UInt64
    ) {
        self.executionID = executionID
        self.timestampNanoseconds = timestampNanoseconds
        self.cpuUsageNanoseconds = cpuUsageNanoseconds
        self.residentMemoryBytes = residentMemoryBytes
        self.processCount = processCount
    }
}
