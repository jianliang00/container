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
import ContainerSandboxServiceClient
import ContainerXPC
import ContainerizationError
import Foundation
import RuntimeMacOSSidecarShared

extension MacOSSandboxService {
    @Sendable
    public func fsBegin(_ message: XPCMessage) async throws -> XPCMessage {
        let payload = try message.fsBeginRequest()
        try sendFSBegin(payload)
        return message.reply()
    }

    @Sendable
    public func fsChunk(_ message: XPCMessage) async throws -> XPCMessage {
        let payload = try message.fsChunkRequest()
        try sendFSChunk(payload)
        return message.reply()
    }

    @Sendable
    public func fsEnd(_ message: XPCMessage) async throws -> XPCMessage {
        let payload = try message.fsEndRequest()
        try sendFSEnd(payload)
        return message.reply()
    }

    func sendFSBegin(_ payload: MacOSSidecarFSBeginRequestPayload) throws {
        guard let client = sidecarHandle?.client else {
            throw ContainerizationError(.invalidState, message: "macOS sidecar is not initialized")
        }
        try client.fsBegin(port: guestAgentPort(), request: payload)
    }

    func sendFSChunk(_ payload: MacOSSidecarFSChunkRequestPayload) throws {
        guard let client = sidecarHandle?.client else {
            throw ContainerizationError(.invalidState, message: "macOS sidecar is not initialized")
        }
        try client.fsChunk(request: payload)
    }

    func sendFSEnd(_ payload: MacOSSidecarFSEndRequestPayload) throws {
        guard let client = sidecarHandle?.client else {
            throw ContainerizationError(.invalidState, message: "macOS sidecar is not initialized")
        }
        try client.fsEnd(request: payload)
    }

    func guestAgentPort() throws -> UInt32 {
        guard let configuration else {
            throw ContainerizationError(.invalidState, message: "container not bootstrapped")
        }
        return configuration.macosGuest?.agentPort ?? 27000
    }
}

extension XPCMessage {
    fileprivate func fsBeginRequest() throws -> MacOSSidecarFSBeginRequestPayload {
        try decodePayload(MacOSSidecarFSBeginRequestPayload.self)
    }

    fileprivate func fsChunkRequest() throws -> MacOSSidecarFSChunkRequestPayload {
        try decodePayload(MacOSSidecarFSChunkRequestPayload.self)
    }

    fileprivate func fsEndRequest() throws -> MacOSSidecarFSEndRequestPayload {
        try decodePayload(MacOSSidecarFSEndRequestPayload.self)
    }

    private func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = dataNoCopy(key: SandboxKeys.fsPayload.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing filesystem payload")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
