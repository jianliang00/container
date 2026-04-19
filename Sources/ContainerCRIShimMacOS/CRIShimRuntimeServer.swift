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
import Foundation
import GRPC
import NIO

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
        return try CRIShimGRPCServer(socketPath: runtimeEndpoint, config: config)
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

public final class CRIShimGRPCServer: CRIShimServerLifecycle, @unchecked Sendable {
    public let socketPath: String

    private let eventLoopGroup: any EventLoopGroup
    private let ownsEventLoopGroup: Bool
    private let serviceProviders: [any CallHandlerProvider]
    private let stateLock = NSLock()
    private var server: Server?

    public convenience init(
        socketPath: String,
        config: CRIShimConfig,
        versionInfo: CRIShimRuntimeVersionInfo = CRIShimRuntimeVersionInfo(),
        runtimeManager: any CRIShimRuntimeManaging = ContainerKitCRIShimRuntimeManager(),
        imageManager: any CRIShimImageManaging = ContainerKitCRIShimImageManager(),
        cniManager: any CRIShimCNIManaging = ProcessCRIShimCNIManager()
    ) throws {
        let metadataStore = try CRIShimMetadataStore(rootURL: URL(fileURLWithPath: config.normalizedStateDirectory))
        self.init(
            socketPath: socketPath,
            serviceProviders: [
                CRIShimRuntimeServiceProvider(
                    config: config,
                    metadataStore: metadataStore,
                    versionInfo: versionInfo,
                    runtimeManager: runtimeManager,
                    imageManager: imageManager,
                    cniManager: cniManager
                ),
                CRIShimImageServiceProvider(imageManager: imageManager),
            ],
            eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
            ownsEventLoopGroup: true
        )
    }

    public convenience init(
        socketPath: String,
        config: CRIShimConfig,
        versionInfo: CRIShimRuntimeVersionInfo,
        eventLoopGroup: any EventLoopGroup,
        readinessChecker: any CRIShimReadinessChecking = ContainerKitCRIShimReadinessChecker(),
        runtimeManager: any CRIShimRuntimeManaging = ContainerKitCRIShimRuntimeManager(),
        imageManager: any CRIShimImageManaging = ContainerKitCRIShimImageManager(),
        cniManager: any CRIShimCNIManaging = ProcessCRIShimCNIManager()
    ) throws {
        let metadataStore = try CRIShimMetadataStore(rootURL: URL(fileURLWithPath: config.normalizedStateDirectory))
        self.init(
            socketPath: socketPath,
            serviceProviders: [
                CRIShimRuntimeServiceProvider(
                    config: config,
                    metadataStore: metadataStore,
                    versionInfo: versionInfo,
                    readinessChecker: readinessChecker,
                    runtimeManager: runtimeManager,
                    imageManager: imageManager,
                    cniManager: cniManager
                ),
                CRIShimImageServiceProvider(imageManager: imageManager),
            ],
            eventLoopGroup: eventLoopGroup
        )
    }

    public init(
        socketPath: String,
        serviceProviders: [any CallHandlerProvider],
        eventLoopGroup: any EventLoopGroup,
        ownsEventLoopGroup: Bool = false
    ) {
        self.socketPath = socketPath
        self.serviceProviders = serviceProviders
        self.eventLoopGroup = eventLoopGroup
        self.ownsEventLoopGroup = ownsEventLoopGroup
    }

    public func run() async throws {
        _ = try? FileManager.default.removeItem(atPath: socketPath)
        do {
            let server = try await Server.insecure(group: eventLoopGroup)
                .withServiceProviders(serviceProviders)
                .bind(unixDomainSocketPath: socketPath)
                .get()
            setServer(server)
            try await server.onClose.get()
            _ = try? FileManager.default.removeItem(atPath: socketPath)
            await shutdownOwnedEventLoopGroupIfNeeded()
        } catch {
            _ = try? FileManager.default.removeItem(atPath: socketPath)
            await shutdownOwnedEventLoopGroupIfNeeded()
            throw error
        }
    }

    public func stop() async {
        guard let server = currentServer() else {
            return
        }
        try? await server.close().get()
    }

    private func setServer(_ server: Server?) {
        stateLock.lock()
        self.server = server
        stateLock.unlock()
    }

    private func currentServer() -> Server? {
        stateLock.lock()
        let server = self.server
        stateLock.unlock()
        return server
    }

    private func shutdownOwnedEventLoopGroupIfNeeded() async {
        setServer(nil)
        guard ownsEventLoopGroup else {
            return
        }
        await withCheckedContinuation { continuation in
            eventLoopGroup.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }
}
