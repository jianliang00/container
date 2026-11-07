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

/// Requests a guest-wide sync, not a filesystem freeze or application checkpoint.
public struct MacOSGuestFileSystemSyncRequest: Codable, Sendable, Equatable {
    public static let capability = "filesystemSyncV1"
    public let requestID: String
    public let timeoutSeconds: Double

    public init(requestID: String, timeoutSeconds: Double = 30) {
        self.requestID = requestID
        self.timeoutSeconds = timeoutSeconds
    }

    public var isValid: Bool {
        !requestID.isEmpty && requestID.utf8.count <= 128
            && timeoutSeconds.isFinite && (0.01...120).contains(timeoutSeconds)
    }
}

/// Acknowledges that sync() returned. Writers can still dirty pages afterwards.
public struct MacOSGuestFileSystemSyncResult: Codable, Sendable, Equatable {
    public let requestID: String

    public init(requestID: String) { self.requestID = requestID }
}
