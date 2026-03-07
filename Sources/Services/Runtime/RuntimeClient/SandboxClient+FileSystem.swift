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
            throw ContainerizationError(
                .internalError,
                message: "failed to begin filesystem transaction \(payload.txID) in container \(id)",
                cause: error
            )
        }
    }

    public func fsChunk(_ payload: MacOSSidecarFSChunkRequestPayload) async throws {
        let request = XPCMessage(route: SandboxRoutes.fsChunk.rawValue)
        request.set(key: SandboxKeys.fsPayload.rawValue, value: try JSONEncoder().encode(payload))
        do {
            try await client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to send filesystem chunk for transaction \(payload.txID) in container \(id)",
                cause: error
            )
        }
    }

    public func fsEnd(_ payload: MacOSSidecarFSEndRequestPayload) async throws {
        let request = XPCMessage(route: SandboxRoutes.fsEnd.rawValue)
        request.set(key: SandboxKeys.fsPayload.rawValue, value: try JSONEncoder().encode(payload))
        do {
            try await client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to end filesystem transaction \(payload.txID) in container \(id)",
                cause: error
            )
        }
    }
}
