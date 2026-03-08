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
