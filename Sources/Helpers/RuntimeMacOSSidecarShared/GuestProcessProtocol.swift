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

/// Guest-agent capability for processes whose lifetime is independent from a
/// single host-to-guest transport connection.
public enum MacOSGuestProcessProtocol {
    public static let durableProcessV1 = "durableProcessV1"
    /// Adds launch-fingerprint verification and storage-generation fencing to
    /// durable process creation and attachment.
    public static let durableProcessV2 = "durableProcessV2"
    /// Keeps guest replay events until the attached host explicitly
    /// acknowledges consumer delivery.
    public static let durableProcessV3 = "durableProcessV3"
    /// Separates the trusted runtime launch identity from the guest process
    /// specification hash and fences delayed requests by incarnation.
    public static let durableProcessV4 = "durableProcessV4"
}

public enum MacOSGuestProcessDisposition: String, Codable, Sendable, Equatable {
    case created
    case existing
    case inspected
    case attached
    case stopping
    case deleted
}

public enum MacOSGuestProcessState: String, Codable, Sendable, Equatable {
    case running
    case exited
    case deleted
}

/// Structured result encoded in the data field of a guest-agent ACK.
public struct MacOSGuestProcessStatusPayload: Codable, Sendable, Equatable {
    public let executionID: String
    public let disposition: MacOSGuestProcessDisposition
    public let state: MacOSGuestProcessState
    public let launchFingerprint: String
    /// Trusted runtime launch-contract hash, distinct from launchFingerprint.
    public let trustedLaunchFingerprint: String?
    /// Concrete runtime request incarnation currently controlling this process.
    public let incarnation: String?
    /// Writable storage generation currently bound to the durable process.
    /// Nil is reserved for legacy durableProcessV1 sessions.
    public let storageGeneration: UInt64?
    public let processIdentifier: Int32
    public let exitCode: Int32?
    /// Highest process event sequence emitted when this status was captured.
    /// Attachment clients advance their replay cursor only after consuming
    /// the corresponding event frame, not merely after receiving this status.
    public let cursor: UInt64
    /// First event sequence still available for replay.
    public let oldestAvailableSequence: UInt64
    /// True when the requested cursor predates the bounded replay buffer.
    public let replayTruncated: Bool

    public init(
        executionID: String,
        disposition: MacOSGuestProcessDisposition,
        state: MacOSGuestProcessState,
        launchFingerprint: String,
        trustedLaunchFingerprint: String? = nil,
        incarnation: String? = nil,
        storageGeneration: UInt64? = nil,
        processIdentifier: Int32,
        exitCode: Int32?,
        cursor: UInt64,
        oldestAvailableSequence: UInt64,
        replayTruncated: Bool
    ) {
        self.executionID = executionID
        self.disposition = disposition
        self.state = state
        self.launchFingerprint = launchFingerprint
        self.trustedLaunchFingerprint = trustedLaunchFingerprint
        self.incarnation = incarnation
        self.storageGeneration = storageGeneration
        self.processIdentifier = processIdentifier
        self.exitCode = exitCode
        self.cursor = cursor
        self.oldestAvailableSequence = oldestAvailableSequence
        self.replayTruncated = replayTruncated
    }
}
