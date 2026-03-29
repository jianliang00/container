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

public struct MacOSWorkloadGuestMetadata: Sendable, Codable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var workloadImageDigest: String
    public var createdAt: String
    public var processConfiguration: ProcessConfiguration

    public init(
        workloadImageDigest: String,
        createdAt: String,
        processConfiguration: ProcessConfiguration
    ) {
        self.schemaVersion = Self.schemaVersion
        self.workloadImageDigest = workloadImageDigest
        self.createdAt = createdAt
        self.processConfiguration = processConfiguration
    }
}
