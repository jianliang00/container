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

import ContainerCRI
import Darwin
import Foundation

public protocol CRIShimServerLifecycle: Sendable {
    func run() async throws
    func stop() async
}

public protocol CRIShimServerFactory: Sendable {
    func makeServer(config: CRIShimConfig) throws -> any CRIShimServerLifecycle
}

public struct CRIShimRunner<Factory: CRIShimServerFactory>: Sendable {
    public var config: CRIShimConfig
    public var serverFactory: Factory

    public init(config: CRIShimConfig, serverFactory: Factory) {
        self.config = config
        self.serverFactory = serverFactory
    }

    public func run() async throws {
        try config.validate()
        let server = try serverFactory.makeServer(config: config)
        try await server.run()
    }
}

public struct DefaultCRIShimServerFactory: CRIShimServerFactory {
    public init() {}

    public func makeServer(config: CRIShimConfig) throws -> any CRIShimServerLifecycle {
        guard let runtimeEndpoint = config.normalizedRuntimeEndpoint else {
            throw CRIShimServerFactoryError.missingRuntimeEndpoint
        }
        let listener = try CRIShimUnixDomainSocketListener(socketPath: runtimeEndpoint)
        let runtimeService = DeterministicUnsupportedCRIRuntimeService()
        return CRIShimRuntimeServer(listener: listener, runtimeService: runtimeService)
    }
}

public enum CRIShimServerFactoryError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingRuntimeEndpoint

    public var description: String {
        switch self {
        case .missingRuntimeEndpoint:
            return "runtimeEndpoint is required"
        }
    }
}

public struct CRIShimRuntimeServer: CRIShimServerLifecycle {
    public var listener: any CRIShimSocketLifecycle
    public var runtimeService: any CRIRuntimeService

    public init(listener: any CRIShimSocketLifecycle, runtimeService: any CRIRuntimeService) {
        self.listener = listener
        self.runtimeService = runtimeService
    }

    public func run() async throws {
        try await listener.start()
        await listener.waitUntilStopped()
    }

    public func stop() async {
        await listener.stop()
    }

    public func disposition(for operation: CRIRuntimeOperation) -> CRIRuntimeOperationDisposition {
        runtimeService.disposition(for: operation)
    }
}

public protocol CRIShimSocketLifecycle: Sendable {
    var socketPath: String { get }
    func start() async throws
    func waitUntilStopped() async
    func stop() async
}

public actor CRIShimUnixDomainSocketListener: CRIShimSocketLifecycle {
    public let socketPath: String
    private let cleanupExistingSocketFile: Bool

    private var socketFD: Int32?
    private var acceptTask: Task<Void, Never>?
    private var started = false

    public init(socketPath: String, cleanupExistingSocketFile: Bool = true) throws {
        guard !socketPath.isEmpty else {
            throw CRIShimSocketListenerError.emptySocketPath
        }
        self.socketPath = socketPath
        self.cleanupExistingSocketFile = cleanupExistingSocketFile
    }

    public func start() async throws {
        guard !started else {
            return
        }

        if cleanupExistingSocketFile {
            _ = try? FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else {
            throw makePOSIXError(errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxLength else {
            _ = Darwin.close(fd)
            throw CRIShimSocketListenerError.socketPathTooLong(socketPath)
        }
        socketPath.withCString { cString in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                pathPointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { destination in
                    _ = strncpy(destination, cString, maxLength - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = makePOSIXError(errno)
            _ = Darwin.close(fd)
            throw error
        }

        guard listen(fd, 16) == 0 else {
            let error = makePOSIXError(errno)
            _ = Darwin.close(fd)
            _ = try? FileManager.default.removeItem(atPath: socketPath)
            throw error
        }

        socketFD = fd
        started = true
        acceptTask = Task.detached(priority: .background) { [fd] in
            await Self.acceptLoop(socketFD: fd)
        }
    }

    public func waitUntilStopped() async {
        _ = await acceptTask?.value
    }

    public func stop() async {
        guard started else {
            return
        }

        started = false
        if let socketFD {
            _ = Darwin.shutdown(socketFD, SHUT_RDWR)
            _ = Darwin.close(socketFD)
            self.socketFD = nil
        }
        acceptTask?.cancel()
        if let acceptTask {
            _ = await acceptTask.value
        }
        self.acceptTask = nil
        _ = try? FileManager.default.removeItem(atPath: socketPath)
    }

    private static func acceptLoop(socketFD: Int32) async {
        while !Task.isCancelled {
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(socketFD, $0, &length)
                }
            }

            guard clientFD >= 0 else {
                let code = errno
                if code == EINTR {
                    continue
                }
                if code == EBADF || code == EINVAL {
                    break
                }
                continue
            }

            _ = Darwin.close(clientFD)
        }
    }
}

public enum CRIShimSocketListenerError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptySocketPath
    case socketPathTooLong(String)

    public var description: String {
        switch self {
        case .emptySocketPath:
            return "socket path is required"
        case .socketPathTooLong(let socketPath):
            return "unix socket path too long: \(socketPath)"
        }
    }
}

public enum CRIShimSocketErrorMapper {
    public static func makePOSIXError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

private func makePOSIXError(_ code: Int32) -> POSIXError {
    CRIShimSocketErrorMapper.makePOSIXError(code)
}
