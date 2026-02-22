import ContainerizationError
import Darwin
import Foundation
import Logging
import RuntimeMacOSSidecarShared

struct MacOSSidecarClient {
    let socketPath: String
    let log: Logger

    func bootstrapStart(socketConnectRetries: Int = 120) throws {
        _ = try request(method: .vmBootstrapStart, socketConnectRetries: socketConnectRetries)
    }

    func stopVM() throws {
        _ = try request(method: .vmStop)
    }

    func quit() throws {
        _ = try request(method: .sidecarQuit)
    }

    func state() throws -> String? {
        try request(method: .vmState).state
    }

    func connectVsock(port: UInt32) throws -> Int32 {
        let fd = try connectControlSocket(retries: 1)
        defer { Darwin.close(fd) }

        let request = MacOSSidecarRequest(method: .vmConnectVsock, port: port)
        try MacOSSidecarSocketIO.writeJSONFrame(request, fd: fd)
        let receivedFD = try MacOSSidecarSocketIO.receiveOptionalFileDescriptorMarker(socketFD: fd)
        let response = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarResponse.self, fd: fd)
        try validate(response: response, expectedRequestID: request.requestID)
        guard let receivedFD else {
            throw ContainerizationError(.internalError, message: "sidecar response for vm.connectVsock missing file descriptor")
        }
        return receivedFD
    }

    func execSync(
        port: UInt32,
        executable: String,
        arguments: [String],
        environment: [String]? = nil,
        workingDirectory: String? = nil,
        terminal: Bool = false
    ) throws -> MacOSSidecarExecResultPayload {
        let request = MacOSSidecarRequest(
            method: .processExecSync,
            port: port,
            exec: MacOSSidecarExecRequestPayload(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                terminal: terminal
            )
        )
        let response = try requestResponse(request, socketConnectRetries: 1)
        guard let execResult = response.execResult else {
            throw ContainerizationError(.internalError, message: "sidecar response for process.execSync missing exec result")
        }
        return execResult
    }

    private func request(method: MacOSSidecarMethod, port: UInt32? = nil, socketConnectRetries: Int = 1) throws -> MacOSSidecarResponse {
        try requestResponse(
            MacOSSidecarRequest(method: method, port: port),
            socketConnectRetries: socketConnectRetries
        )
    }

    private func requestResponse(_ request: MacOSSidecarRequest, socketConnectRetries: Int) throws -> MacOSSidecarResponse {
        let fd = try connectControlSocket(retries: socketConnectRetries)
        defer { Darwin.close(fd) }
        try MacOSSidecarSocketIO.writeJSONFrame(request, fd: fd)
        let response = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarResponse.self, fd: fd)
        try validate(response: response, expectedRequestID: request.requestID)
        return response
    }

    private func validate(response: MacOSSidecarResponse, expectedRequestID: String) throws {
        guard response.requestID == expectedRequestID else {
            throw ContainerizationError(.internalError, message: "sidecar response requestID mismatch")
        }
        guard response.ok else {
            let error = response.error
            let code = error?.code ?? "unknown"
            let message = error?.message ?? "unknown sidecar error"
            let details = error?.details.map { " (\($0))" } ?? ""
            throw ContainerizationError(.internalError, message: "sidecar \(code): \(message)\(details)")
        }
    }

    private func connectControlSocket(retries: Int) throws -> Int32 {
        var lastError: Error?
        let attempts = max(1, retries)
        for attempt in 1...attempts {
            do {
                if attempt > 1 {
                    log.debug("sidecar control socket connect attempt", metadata: ["attempt": "\(attempt)", "path": "\(socketPath)"])
                }
                return try MacOSSidecarSocketIO.connectUnixSocket(path: socketPath)
            } catch {
                lastError = error
                if attempt < attempts {
                    usleep(500_000)
                }
            }
        }
        throw ContainerizationError(
            .internalError,
            message: "failed to connect to macOS sidecar control socket at \(socketPath): \(describe(error: lastError))"
        )
    }

    private func describe(error: Error?) -> String {
        guard let error else { return "unknown error" }
        let nsError = error as NSError
        return "\(nsError.domain) Code=\(nsError.code) \"\(nsError.localizedDescription)\""
    }
}
