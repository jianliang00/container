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
import ContainerizationError
import Foundation
import RuntimeMacOSSidecarShared

extension SandboxClient {
    public func fsBegin(_ payload: MacOSSidecarFSBeginRequestPayload) async throws {
        let request = XPCMessage(route: SandboxRoutes.fsBegin.rawValue)
        request.set(key: SandboxKeys.fsPayload.rawValue, value: try JSONEncoder().encode(payload))
        do {
            try await client.send(request)
        } catch {
            throw wrapFileSystemError(
                error,
                message: "failed to begin filesystem transaction \(payload.txID) in container \(id)"
            )
        }
    }

    public func fsChunk(_ payload: MacOSSidecarFSChunkRequestPayload) async throws {
        let request = XPCMessage(route: SandboxRoutes.fsChunk.rawValue)
        request.set(key: SandboxKeys.fsPayload.rawValue, value: try JSONEncoder().encode(payload))
        do {
            try await client.send(request)
        } catch {
            throw wrapFileSystemError(
                error,
                message: "failed to send filesystem chunk for transaction \(payload.txID) in container \(id)"
            )
        }
    }

    public func fsEnd(_ payload: MacOSSidecarFSEndRequestPayload) async throws {
        let request = XPCMessage(route: SandboxRoutes.fsEnd.rawValue)
        request.set(key: SandboxKeys.fsPayload.rawValue, value: try JSONEncoder().encode(payload))
        do {
            try await client.send(request)
        } catch {
            throw wrapFileSystemError(
                error,
                message: "failed to end filesystem transaction \(payload.txID) in container \(id)"
            )
        }
    }

    private func wrapFileSystemError(_ error: any Error, message: String) -> ContainerizationError {
        if let containerError = error as? ContainerizationError {
            return ContainerizationError(
                containerError.code,
                message: "\(message): \(containerError.message)",
                cause: containerError
            )
        }
        return ContainerizationError(.internalError, message: message, cause: error)
    }
}
