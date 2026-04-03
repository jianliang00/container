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

import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation
import TerminalProgress

/// A handle for an active workload stream attachment.
public protocol ClientWorkloadAttachment: Sendable {
    /// Identifier for the attached workload.
    var id: String { get }
    /// Identifier for this attachment instance.
    var attachmentID: String { get }
    /// Whether the attachment owns stdin/resize/signal control.
    var takesControl: Bool { get }

    /// Send a terminal resize request through this attachment.
    func resize(_ size: Terminal.Size) async throws
    /// Send a signal through this attachment.
    func signal(_ signal: Int32) async throws
    /// Wait for the attached workload to exit.
    func wait() async throws -> Int32
    /// Detach this attachment without stopping the workload.
    func detach() async throws
}

struct ClientWorkloadAttachmentImpl: ClientWorkloadAttachment, Sendable {
    public let containerId: String
    public let workloadId: String
    public let attachmentID: String
    public let takesControl: Bool

    private let xpcClient: XPCClient

    public var id: String { workloadId }

    init(
        containerId: String,
        workloadId: String,
        attachmentID: String,
        takesControl: Bool,
        xpcClient: XPCClient
    ) {
        self.containerId = containerId
        self.workloadId = workloadId
        self.attachmentID = attachmentID
        self.takesControl = takesControl
        self.xpcClient = xpcClient
    }

    public func resize(_ size: Terminal.Size) async throws {
        guard takesControl else {
            throw ContainerizationError(.invalidState, message: "attachment \(attachmentID) does not own control")
        }

        let request = XPCMessage(route: .containerResize)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: workloadId)
        request.set(key: .attachmentIdentifier, value: attachmentID)
        request.set(key: .width, value: UInt64(size.width))
        request.set(key: .height, value: UInt64(size.height))

        try await xpcClient.send(request)
    }

    public func signal(_ signal: Int32) async throws {
        guard takesControl else {
            throw ContainerizationError(.invalidState, message: "attachment \(attachmentID) does not own control")
        }

        let request = XPCMessage(route: .containerKill)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: workloadId)
        request.set(key: .attachmentIdentifier, value: attachmentID)
        request.set(key: .signal, value: Int64(signal))

        try await xpcClient.send(request)
    }

    public func wait() async throws -> Int32 {
        let request = XPCMessage(route: .containerWait)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: workloadId)

        let response = try await xpcClient.send(request)
        return Int32(response.int64(key: .exitCode))
    }

    public func detach() async throws {
        let request = XPCMessage(route: .containerDetachWorkloadAttachment)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: workloadId)
        request.set(key: .attachmentIdentifier, value: attachmentID)

        try await xpcClient.send(request)
    }
}
