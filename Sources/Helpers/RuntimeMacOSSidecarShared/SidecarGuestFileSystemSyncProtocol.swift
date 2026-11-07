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

/// A cold disk checkpoint. The caller must use a fresh ID for each attempt.
/// Ownership lasts until finish succeeds or the sidecar process exits.
public struct MacOSFilesystemCheckpointRequest: Codable, Sendable, Equatable {
    public let checkpointID: String
    public let timeoutSeconds: Double

    public init(checkpointID: String, timeoutSeconds: Double = 30) {
        self.checkpointID = checkpointID
        self.timeoutSeconds = timeoutSeconds
    }

    public var syncRequest: MacOSGuestFileSystemSyncRequest {
        .init(requestID: checkpointID, timeoutSeconds: timeoutSeconds)
    }
}

public struct MacOSFilesystemCheckpointFinishRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case resume, stop }
    public let checkpointID: String
    public let action: Action

    public init(checkpointID: String, action: Action) {
        self.checkpointID = checkpointID
        self.action = action
    }
}

public struct MacOSFilesystemCheckpointResult: Codable, Sendable, Equatable {
    public let checkpointID: String
    public let lifecycleState: MacOSVMRuntimeState

    public init(checkpointID: String, lifecycleState: MacOSVMRuntimeState) {
        self.checkpointID = checkpointID
        self.lifecycleState = lifecycleState
    }
}
