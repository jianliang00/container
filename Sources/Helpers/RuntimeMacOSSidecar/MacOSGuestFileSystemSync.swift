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

import ContainerizationError
import Darwin
import Foundation
import RuntimeMacOSSidecarShared

enum MacOSGuestFileSystemSync {
    static func synchronize(
        _ request: MacOSGuestFileSystemSyncRequest,
        connect: @Sendable (TimeInterval) async throws -> Int32
    ) async throws -> MacOSGuestFileSystemSyncResult {
        guard request.isValid else {
            throw SidecarRPCError(code: "invalidArgument", message: "invalid filesystem sync request")
        }
        let deadline = sidecarReadDeadline(timeoutSeconds: request.timeoutSeconds)
        let connection = try await GuestAgentHandshake.connect(timeoutSeconds: request.timeoutSeconds, connect: connect)
        let fd = connection.fd
        defer {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        guard connection.capabilities.contains(MacOSGuestFileSystemSyncRequest.capability) else {
            throw SidecarRPCError(code: "unsupportedGuestCapability", message: "guest does not support filesystemSyncV1")
        }
        do {
            try Task.checkCancellation()
            try MacOSSidecarSocketIO.writeJSONFrame(
                SidecarGuestAgentFrame(type: .filesystemSync, id: request.requestID, data: JSONEncoder().encode(request)),
                fd: fd, timeoutMilliseconds: try sidecarRemainingReadMilliseconds(until: deadline)
            )
            // Never reconnect/replay after dispatch: a timeout is not a successful flush.
            let frame = try MacOSSidecarSocketIO.readJSONFrame(
                SidecarGuestAgentFrame.self, fd: fd,
                timeoutMilliseconds: try sidecarRemainingReadMilliseconds(until: deadline)
            )
            try Task.checkCancellation()
            guard frame.id == request.requestID else {
                throw SidecarRPCError(code: "invalidGuestResponse", message: "filesystem sync response ID mismatch")
            }
            if frame.type == .error {
                throw SidecarRPCError(
                    code: frame.errorCode == EBUSY ? "operationInProgress" : "guestSyncFailed",
                    message: "guest filesystem sync did not complete"
                )
            }
            guard frame.type == .filesystemSyncResult, let data = frame.data else {
                throw SidecarRPCError(code: "invalidGuestResponse", message: "missing filesystem sync result")
            }
            let result = try JSONDecoder().decode(MacOSGuestFileSystemSyncResult.self, from: data)
            guard result.requestID == request.requestID else {
                throw SidecarRPCError(code: "invalidGuestResponse", message: "filesystem sync payload ID mismatch")
            }
            return result
        } catch let error as POSIXError where error.code == .ETIMEDOUT {
            throw ContainerizationError(.timeout, message: "guest filesystem sync timed out; completion is unknown")
        }
    }
}
