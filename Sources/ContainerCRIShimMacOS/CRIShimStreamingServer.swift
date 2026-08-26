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

import Dispatch
import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
import zlib

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private let criShimStreamingUpgradeRequired = HTTPResponseStatus(statusCode: 426, reasonPhrase: "Upgrade Required")
private let criShimSPDYProtocol = "SPDY/3.1"
private let criShimSPDYStreamProtocolHeader = "X-Stream-Protocol-Version"
private let criShimPortForwardProtocol = "portforward.k8s.io"

private enum CRIShimStreamingRoute: String, Sendable {
    case exec
    case portForward = "portforward"
}

private enum CRIShimExecStreamProtocol: String, Sendable, CaseIterable {
    case v5 = "v5.channel.k8s.io"
    case v4 = "v4.channel.k8s.io"
    case v3 = "v3.channel.k8s.io"
    case v2 = "v2.channel.k8s.io"
    case v1 = "channel.k8s.io"

    var supportsResize: Bool {
        switch self {
        case .v1, .v2:
            false
        case .v3, .v4, .v5:
            true
        }
    }

    var supportsStructuredExitStatus: Bool {
        switch self {
        case .v4, .v5:
            true
        case .v1, .v2, .v3:
            false
        }
    }

    var supportsCloseSignal: Bool {
        self == .v5
    }

    static func negotiate(offered: [String]) -> CRIShimExecStreamProtocol? {
        let normalized = Set(offered.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return allCases.first(where: { normalized.contains($0.rawValue) })
    }
}

private enum CRIShimStreamingSessionDescriptor: Sendable {
    case exec(CRIShimExecStreamingInvocation)
    case portForward(CRIShimPortForwardInvocation)
}

private struct CRIShimPreparedWebSocketUpgrade: Sendable {
    var subprotocol: String
    var handler: CRIShimStreamingWebSocketHandler
}

private struct CRIShimPreparedSPDYUpgrade: Sendable {
    var protocolVersion: String
    var handler: CRIShimSPDYHandler

    func addHandler(to pipeline: ChannelPipeline) throws {
        switch handler {
        case .exec(let handler):
            try pipeline.syncOperations.addHandler(handler)
        case .portForward(let handler):
            try pipeline.syncOperations.addHandler(handler)
        }
    }
}

private enum CRIShimSPDYHandler: Sendable {
    case exec(CRIShimExecSPDYHandler)
    case portForward(CRIShimPortForwardSPDYHandler)
}

private struct CRIShimStreamingPath {
    var route: CRIShimStreamingRoute
    var token: String
}

private struct CRIShimStreamingHTTPError: Error {
    var status: HTTPResponseStatus
    var message: String
}

private actor CRIShimStreamingSessionStore {
    private struct Entry {
        var expiresAt: Date
        var session: CRIShimStreamingSessionDescriptor
    }

    private let sessionTTL: TimeInterval
    private var entries: [String: Entry] = [:]

    init(sessionTTL: TimeInterval) {
        self.sessionTTL = sessionTTL
    }

    func insert(_ session: CRIShimStreamingSessionDescriptor) -> String {
        sweepExpired()
        let token = UUID().uuidString.lowercased()
        entries[token] = Entry(
            expiresAt: Date().addingTimeInterval(sessionTTL),
            session: session
        )
        return token
    }

    func peek(token: String) -> CRIShimStreamingSessionDescriptor? {
        sweepExpired()
        return entries[token]?.session
    }

    func consume(token: String) -> CRIShimStreamingSessionDescriptor? {
        sweepExpired()
        guard let entry = entries.removeValue(forKey: token) else {
            return nil
        }
        return entry.session
    }

    private func sweepExpired() {
        let now = Date()
        entries = entries.filter { _, entry in
            entry.expiresAt > now
        }
    }
}

actor CRIShimStartSynchronizedStreamingProcess: CRIShimStreamingProcess {
    private struct TerminationAttempt {
        let id: UUID
        let task: Task<Void, Error>
    }

    private enum State {
        case created
        case starting
        case started
        case failed
        case terminated
    }

    private let process: any CRIShimStreamingProcess
    private var state = State.created
    private var pendingResizes: [CRIShimTerminalSize]
    private var terminationAttempt: TerminationAttempt?
    private var terminationWaiterCount = 0

    var isWaitingForTerminationOutcome: Bool {
        terminationWaiterCount > 0
    }

    init(
        process: any CRIShimStreamingProcess,
        pendingResizes: [CRIShimTerminalSize] = []
    ) {
        self.process = process
        self.pendingResizes = pendingResizes
    }

    func start() async throws {
        guard case .created = state, terminationAttempt == nil else {
            throw CRIShimError.internalError("streaming process start was requested more than once")
        }
        state = .starting

        do {
            try await process.start()
            let terminatedWhileStarting = await terminationCompletedSuccessfully()
            guard !terminatedWhileStarting, case .starting = state else {
                throw CRIShimError.internalError("streaming process was terminated while starting")
            }
            while !pendingResizes.isEmpty {
                let resizes = pendingResizes
                pendingResizes.removeAll(keepingCapacity: true)
                for size in resizes {
                    try await process.resize(size)
                    let terminatedWhileResizing = await terminationCompletedSuccessfully()
                    guard !terminatedWhileResizing, case .starting = state else {
                        throw CRIShimError.internalError("streaming process was terminated while applying resize")
                    }
                }
            }
            state = .started
        } catch {
            if case .terminated = state {
                throw error
            }
            state = .failed
            throw error
        }
    }

    func resize(_ size: CRIShimTerminalSize) async throws {
        let terminationCompleted = await terminationCompletedSuccessfully()
        guard !terminationCompleted else {
            throw CRIShimError.internalError("streaming process was terminated")
        }
        switch state {
        case .created, .starting:
            pendingResizes.append(size)
        case .started:
            try await process.resize(size)
            let terminationCompleted = await terminationCompletedSuccessfully()
            guard !terminationCompleted else {
                throw CRIShimError.internalError("streaming process was terminated")
            }
        case .failed:
            throw CRIShimError.internalError("streaming process did not start")
        case .terminated:
            throw CRIShimError.internalError("streaming process was terminated")
        }
    }

    func kill(_ signal: Int32) async throws {
        if case .terminated = state {
            return
        }

        let attempt: TerminationAttempt
        if let terminationAttempt {
            attempt = terminationAttempt
        } else {
            let process = process
            attempt = TerminationAttempt(
                id: UUID(),
                task: Task {
                    try await process.kill(signal)
                }
            )
            terminationAttempt = attempt
        }

        do {
            try await attempt.task.value
            guard terminationAttempt?.id == attempt.id else {
                return
            }
            terminationAttempt = nil
            state = .terminated
            pendingResizes.removeAll()
        } catch {
            if terminationAttempt?.id == attempt.id {
                terminationAttempt = nil
            }
            throw error
        }
    }

    private func terminationCompletedSuccessfully() async -> Bool {
        while let attempt = terminationAttempt {
            terminationWaiterCount += 1
            let result: Result<Void, Error>
            do {
                try await attempt.task.value
                result = .success(())
            } catch {
                result = .failure(error)
            }
            terminationWaiterCount -= 1

            switch result {
            case .success:
                guard terminationAttempt?.id == attempt.id else {
                    if case .terminated = state {
                        return true
                    }
                    continue
                }
                terminationAttempt = nil
                state = .terminated
                pendingResizes.removeAll()
                return true
            case .failure:
                if terminationAttempt?.id == attempt.id {
                    terminationAttempt = nil
                }
            }
        }

        if case .terminated = state {
            return true
        }
        return false
    }

    func wait() async throws -> Int32 {
        try await process.wait()
    }
}

public final class CRIShimStreamingServer: @unchecked Sendable {
    private let config: CRIShimConfig
    private let runtimeManager: any CRIShimRuntimeManaging
    private let sessionStore: CRIShimStreamingSessionStore
    private let activeSessionIdleTimeout: TimeAmount?
    private let websocketMaxFrameSize: Int
    private let maximumActivePortForwardTunnels: Int
    private let stateLock = NSLock()
    private var serverChannel: Channel?
    private var activeChannels: [ObjectIdentifier: Channel] = [:]
    private var activePortForwardTunnelLeases: Set<UUID> = []
    private var baseURL: URL?

    public init(
        config: CRIShimConfig,
        runtimeManager: any CRIShimRuntimeManaging,
        sessionTimeoutSeconds: TimeInterval = 30,
        activeSessionIdleTimeoutSeconds: TimeInterval = 300,
        websocketMaxFrameSize: Int = 1 << 20,
        maximumActivePortForwardTunnels: Int = 256
    ) {
        self.config = config
        self.runtimeManager = runtimeManager
        self.sessionStore = CRIShimStreamingSessionStore(sessionTTL: sessionTimeoutSeconds)
        self.activeSessionIdleTimeout =
            if activeSessionIdleTimeoutSeconds > 0 {
                .nanoseconds(Int64((activeSessionIdleTimeoutSeconds * 1_000_000_000).rounded()))
            } else {
                nil
            }
        self.websocketMaxFrameSize = websocketMaxFrameSize
        self.maximumActivePortForwardTunnels = max(maximumActivePortForwardTunnels, 1)
    }

    public func start(eventLoopGroup: any EventLoopGroup) async throws {
        let (host, port) = try streamingListenAddress()
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                self.registerActiveChannel(channel)
                let requestHandler = CRIShimStreamingHTTPRequestHandler(
                    server: self,
                    websocketMaxFrameSize: self.websocketMaxFrameSize
                )
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: self.websocketMaxFrameSize,
                    shouldUpgrade: { channel, head in
                        requestHandler.shouldUpgrade(channel: channel, head: head)
                    },
                    upgradePipelineHandler: { channel, head in
                        requestHandler.upgradePipeline(channel: channel, head: head)
                    }
                )
                let spdyUpgrader = CRIShimSPDYServerUpgrader(
                    server: self,
                    requestHandler: requestHandler
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false,
                    withServerUpgrade: (
                        upgraders: [upgrader, spdyUpgrader],
                        completionHandler: { _ in }
                    ),
                    withErrorHandling: true
                ).flatMap {
                    channel.pipeline.addHandler(requestHandler)
                }
            }

        let channel = try await bootstrap.bind(host: host, port: port).get()
        let actualPort = channel.localAddress?.port ?? port
        let baseURL = try makeBaseURL(host: host, port: actualPort)
        stateLock.withLock {
            serverChannel = channel
            self.baseURL = baseURL
        }
    }

    public func stop() async {
        let channels: [Channel]
        let server: Channel?
        (channels, server) = stateLock.withLock {
            let channels = Array(activeChannels.values)
            activeChannels.removeAll()
            let server = serverChannel
            serverChannel = nil
            baseURL = nil
            return (channels, server)
        }

        for channel in channels {
            try? await channel.close().get()
        }
        if let server {
            try? await server.close().get()
        }
    }

    func registerExecURL(
        _ invocation: CRIShimExecStreamingInvocation
    ) async throws -> String {
        let token = await sessionStore.insert(.exec(invocation))
        return try makeStreamingURL(route: .exec, token: token)
    }

    func registerPortForwardURL(
        _ invocation: CRIShimPortForwardInvocation
    ) async throws -> String {
        let token = await sessionStore.insert(.portForward(invocation))
        return try makeStreamingURL(route: .portForward, token: token)
    }

    fileprivate func prepareWebSocketUpgrade(
        requestHead: HTTPRequestHead
    ) async throws -> CRIShimPreparedWebSocketUpgrade {
        let path = try parseStreamingPath(requestHead.uri)
        guard let preview = await sessionStore.peek(token: path.token) else {
            throw CRIShimStreamingHTTPError(status: .notFound, message: "stream token not found")
        }

        let offeredProtocols = websocketProtocols(from: requestHead.headers)
        let selectedSubprotocol: String
        switch preview {
        case .exec:
            guard let protocolVersion = CRIShimExecStreamProtocol.negotiate(offered: offeredProtocols) else {
                throw CRIShimStreamingHTTPError(
                    status: .badRequest,
                    message: "exec websocket subprotocol is required"
                )
            }
            selectedSubprotocol = protocolVersion.rawValue
        case .portForward:
            guard offeredProtocols.contains("portforward.k8s.io") else {
                throw CRIShimStreamingHTTPError(
                    status: .badRequest,
                    message: "portforward.k8s.io websocket subprotocol is required"
                )
            }
            selectedSubprotocol = "portforward.k8s.io"
        }

        guard let session = await sessionStore.consume(token: path.token) else {
            throw CRIShimStreamingHTTPError(status: .notFound, message: "stream token not found")
        }

        switch (path.route, preview) {
        case (.exec, .exec), (.portForward, .portForward):
            break
        default:
            throw CRIShimStreamingHTTPError(status: .notFound, message: "stream token not found")
        }

        let handler = CRIShimStreamingWebSocketHandler(
            server: self,
            runtimeManager: runtimeManager,
            session: session,
            negotiatedSubprotocol: selectedSubprotocol,
            idleTimeout: activeSessionIdleTimeout
        )
        return CRIShimPreparedWebSocketUpgrade(
            subprotocol: selectedSubprotocol,
            handler: handler
        )
    }

    fileprivate func prepareSPDYUpgrade(
        requestHead: HTTPRequestHead
    ) async throws -> CRIShimPreparedSPDYUpgrade {
        let path = try parseStreamingPath(requestHead.uri)
        guard let preview = await sessionStore.peek(token: path.token) else {
            throw CRIShimStreamingHTTPError(status: .notFound, message: "stream token not found")
        }
        let offeredProtocols = spdyStreamProtocols(from: requestHead.headers)

        switch (path.route, preview) {
        case (.exec, .exec(let invocation)):
            guard let protocolVersion = CRIShimExecStreamProtocol.negotiate(offered: offeredProtocols) else {
                throw CRIShimStreamingHTTPError(
                    status: .badRequest,
                    message: "\(criShimSPDYStreamProtocolHeader) must include a supported exec protocol"
                )
            }
            guard let session = await sessionStore.consume(token: path.token), case .exec = session else {
                throw CRIShimStreamingHTTPError(status: .notFound, message: "stream token not found")
            }
            let handler = CRIShimExecSPDYHandler(
                server: self,
                runtimeManager: runtimeManager,
                invocation: invocation,
                protocolVersion: protocolVersion,
                idleTimeout: activeSessionIdleTimeout
            )
            return CRIShimPreparedSPDYUpgrade(
                protocolVersion: protocolVersion.rawValue,
                handler: .exec(handler)
            )

        case (.portForward, .portForward(let invocation)):
            guard offeredProtocols.contains(criShimPortForwardProtocol) else {
                throw CRIShimStreamingHTTPError(
                    status: .badRequest,
                    message: "\(criShimSPDYStreamProtocolHeader) must include \(criShimPortForwardProtocol)"
                )
            }
            guard let session = await sessionStore.consume(token: path.token), case .portForward = session else {
                throw CRIShimStreamingHTTPError(status: .notFound, message: "stream token not found")
            }
            let handler = CRIShimPortForwardSPDYHandler(
                server: self,
                runtimeManager: runtimeManager,
                invocation: invocation,
                idleTimeout: activeSessionIdleTimeout
            )
            return CRIShimPreparedSPDYUpgrade(
                protocolVersion: criShimPortForwardProtocol,
                handler: .portForward(handler)
            )

        default:
            throw CRIShimStreamingHTTPError(status: .notFound, message: "stream token not found")
        }
    }

    fileprivate func plainHTTPRequestError(
        requestHead: HTTPRequestHead
    ) -> CRIShimStreamingHTTPError {
        do {
            _ = try parseStreamingPath(requestHead.uri)
            return CRIShimStreamingHTTPError(
                status: criShimStreamingUpgradeRequired,
                message: "websocket upgrade is required"
            )
        } catch {
            return CRIShimStreamingHTTPError(status: .notFound, message: "not found")
        }
    }

    fileprivate func unregisterActiveChannel(_ channel: Channel) {
        _ = stateLock.withLock {
            activeChannels.removeValue(forKey: ObjectIdentifier(channel))
        }
    }

    fileprivate func acquirePortForwardTunnelLease() -> UUID? {
        stateLock.withLock {
            guard activePortForwardTunnelLeases.count < maximumActivePortForwardTunnels else {
                return nil
            }
            let lease = UUID()
            activePortForwardTunnelLeases.insert(lease)
            return lease
        }
    }

    fileprivate func releasePortForwardTunnelLease(_ lease: UUID) {
        _ = stateLock.withLock {
            activePortForwardTunnelLeases.remove(lease)
        }
    }

    var activePortForwardTunnelCount: Int {
        stateLock.withLock {
            activePortForwardTunnelLeases.count
        }
    }

    private func registerActiveChannel(_ channel: Channel) {
        stateLock.withLock {
            activeChannels[ObjectIdentifier(channel)] = channel
        }
    }

    private func streamingListenAddress() throws -> (String, Int) {
        guard let streaming = config.streaming else {
            throw CRIShimError.invalidArgument("streaming is required")
        }
        guard let host = streaming.address?.trimmed, !host.isEmpty else {
            throw CRIShimError.invalidArgument("streaming.address is required")
        }
        guard isLoopbackHost(host) else {
            throw CRIShimError.invalidArgument("streaming.address must be a loopback address")
        }
        guard let port = streaming.port else {
            throw CRIShimError.invalidArgument("streaming.port is required")
        }
        return (host, port)
    }

    private func makeStreamingURL(
        route: CRIShimStreamingRoute,
        token: String
    ) throws -> String {
        let baseURL = stateLock.withLock { self.baseURL }
        guard let baseURL else {
            throw CRIShimError.internalError("streaming server is not running")
        }
        return baseURL.appendingPathComponent(route.rawValue).appendingPathComponent(token).absoluteString
    }
}

private final class CRIShimStreamingHTTPRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: CRIShimStreamingServer
    private let websocketMaxFrameSize: Int
    private var currentRequestHead: HTTPRequestHead?
    private var rejection: CRIShimStreamingHTTPError?
    private var preparedUpgrade: CRIShimPreparedWebSocketUpgrade?

    init(
        server: CRIShimStreamingServer,
        websocketMaxFrameSize: Int
    ) {
        self.server = server
        self.websocketMaxFrameSize = websocketMaxFrameSize
    }

    func shouldUpgrade(
        channel: Channel,
        head: HTTPRequestHead
    ) -> EventLoopFuture<HTTPHeaders?> {
        let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
        Task {
            do {
                let preparedUpgrade = try await server.prepareWebSocketUpgrade(requestHead: head)
                self.preparedUpgrade = preparedUpgrade
                var headers = HTTPHeaders()
                headers.add(name: "Sec-WebSocket-Protocol", value: preparedUpgrade.subprotocol)
                promise.succeed(headers)
            } catch let error as CRIShimStreamingHTTPError {
                rejection = error
                promise.succeed(nil)
            } catch {
                rejection = CRIShimStreamingHTTPError(status: .internalServerError, message: String(describing: error))
                promise.succeed(nil)
            }
        }
        return promise.futureResult
    }

    func upgradePipeline(
        channel: Channel,
        head: HTTPRequestHead
    ) -> EventLoopFuture<Void> {
        guard let preparedUpgrade else {
            return channel.eventLoop.makeFailedFuture(CRIShimError.internalError("missing prepared websocket upgrade"))
        }
        return channel.pipeline.removeHandler(self).flatMapThrowing {
            try channel.pipeline.syncOperations.addHandler(
                NIOWebSocketFrameAggregator(
                    minNonFinalFragmentSize: 1,
                    maxAccumulatedFrameCount: 64,
                    maxAccumulatedFrameSize: self.websocketMaxFrameSize
                )
            )
            try channel.pipeline.syncOperations.addHandler(preparedUpgrade.handler)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            currentRequestHead = head
            if rejection == nil {
                rejection = server.plainHTTPRequestError(requestHead: head)
            }
        case .body:
            break
        case .end:
            writeRejectedResponseIfNeeded(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.unregisterActiveChannel(context.channel)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        server.unregisterActiveChannel(context.channel)
        context.close(promise: nil)
    }

    private func writeRejectedResponseIfNeeded(context: ChannelHandlerContext) {
        guard let requestHead = currentRequestHead, let rejection else {
            return
        }

        currentRequestHead = nil
        let body = ByteBuffer(string: rejection.message + "\n")
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.readableBytes)")
        if rejection.status.code == criShimStreamingUpgradeRequired.code {
            headers.add(name: "Upgrade", value: "websocket")
        }

        let responseHead = HTTPResponseHead(
            version: requestHead.version,
            status: rejection.status,
            headers: headers
        )
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
}

private final class CRIShimSPDYServerUpgrader: HTTPServerProtocolUpgrader, @unchecked Sendable {
    let supportedProtocol = criShimSPDYProtocol
    let requiredUpgradeHeaders: [String] = []

    private let server: CRIShimStreamingServer
    private weak var requestHandler: CRIShimStreamingHTTPRequestHandler?
    private let lock = NSLock()
    private var preparedUpgrade: CRIShimPreparedSPDYUpgrade?

    init(
        server: CRIShimStreamingServer,
        requestHandler: CRIShimStreamingHTTPRequestHandler
    ) {
        self.server = server
        self.requestHandler = requestHandler
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        let promise = channel.eventLoop.makePromise(of: HTTPHeaders.self)
        Task {
            do {
                let preparedUpgrade = try await server.prepareSPDYUpgrade(requestHead: upgradeRequest)
                self.lock.withLock {
                    self.preparedUpgrade = preparedUpgrade
                }
                var headers = initialResponseHeaders
                headers.add(name: criShimSPDYStreamProtocolHeader, value: preparedUpgrade.protocolVersion)
                promise.succeed(headers)
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    func upgrade(
        context: ChannelHandlerContext,
        upgradeRequest: HTTPRequestHead
    ) -> EventLoopFuture<Void> {
        guard let preparedUpgrade = lock.withLock({ self.preparedUpgrade }) else {
            return context.eventLoop.makeFailedFuture(CRIShimError.internalError("missing prepared SPDY upgrade"))
        }
        let pipeline = context.pipeline
        let removeRequestHandler: EventLoopFuture<Void>
        if let requestHandler {
            removeRequestHandler = pipeline.removeHandler(requestHandler)
        } else {
            removeRequestHandler = context.eventLoop.makeSucceededFuture(())
        }
        return removeRequestHandler.flatMapThrowing {
            try preparedUpgrade.addHandler(to: pipeline)
        }
    }
}

final class CRIShimSPDYControlWriteGate: @unchecked Sendable {
    private static let maximumPendingWrites = 64

    private let lock = NSLock()
    private var pendingWrites = 0
    private var rejected = false

    var isRejected: Bool {
        lock.withLock { rejected }
    }

    func reserve(channel: Channel) -> Bool {
        reserve(isActive: channel.isActive, isWritable: channel.isWritable)
    }

    func reserve(isActive: Bool, isWritable: Bool) -> Bool {
        lock.withLock {
            guard
                !rejected,
                isActive,
                isWritable,
                pendingWrites < Self.maximumPendingWrites
            else {
                rejected = true
                return false
            }
            pendingWrites += 1
            return true
        }
    }

    func complete(succeeded: Bool) -> Bool {
        lock.withLock {
            pendingWrites -= min(pendingWrites, 1)
            guard !succeeded, !rejected else {
                return false
            }
            rejected = true
            return true
        }
    }

    func reject() -> Bool {
        lock.withLock {
            guard !rejected else {
                return false
            }
            rejected = true
            return true
        }
    }
}

private final class CRIShimExecSPDYHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    fileprivate enum StreamKind: String, Hashable {
        case error
        case stdin
        case stdout
        case stderr
        case resize
    }

    private let server: CRIShimStreamingServer
    private let runtimeManager: any CRIShimRuntimeManaging
    private let invocation: CRIShimExecStreamingInvocation
    private let protocolVersion: CRIShimExecStreamProtocol
    private let idleTimeout: TimeAmount?
    private let controlWriteGate = CRIShimSPDYControlWriteGate()
    private let lock = NSLock()
    private var channel: Channel?
    private var inboundBuffer: ByteBuffer?
    private var streamsByID: [UInt32: StreamKind] = [:]
    private var streamIDsByKind: [StreamKind: UInt32] = [:]
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var process: (any CRIShimStreamingProcess)?
    private var pendingStdin = Data()
    private var pendingResizes: [CRIShimTerminalSize] = []
    private var stdinClosed = false
    private var processStarting = false
    private var tasks: [Task<Void, Never>] = []
    private var cleanupPerformed = false
    private var idleTimeoutTask: Scheduled<Void>?
    private var inflater = try! CRIShimSPDYHeaderInflater()
    private var deflater = try! CRIShimSPDYHeaderDeflater()

    init(
        server: CRIShimStreamingServer,
        runtimeManager: any CRIShimRuntimeManaging,
        invocation: CRIShimExecStreamingInvocation,
        protocolVersion: CRIShimExecStreamProtocol,
        idleTimeout: TimeAmount?
    ) {
        self.server = server
        self.runtimeManager = runtimeManager
        self.invocation = invocation
        self.protocolVersion = protocolVersion
        self.idleTimeout = idleTimeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        inboundBuffer = context.channel.allocator.buffer(capacity: 0)
        recordActivity()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !controlWriteGate.isRejected else {
            return
        }
        var incoming = unwrapInboundIn(data)
        inboundBuffer?.writeBuffer(&incoming)
        recordActivity()
        do {
            try parseAvailableFrames()
        } catch {
            if controlWriteGate.reject() {
                context.close(promise: nil)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.unregisterActiveChannel(context.channel)
        Task {
            await cleanup(killProcess: true)
        }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        Task {
            await cleanup(killProcess: true)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        server.unregisterActiveChannel(context.channel)
        Task {
            await cleanup(killProcess: true)
        }
        context.close(promise: nil)
    }

    private var expectedStreamKinds: Set<StreamKind> {
        var kinds: Set<StreamKind> = [.error]
        if invocation.stdin {
            kinds.insert(.stdin)
        }
        if invocation.stdout {
            kinds.insert(.stdout)
        }
        if invocation.stderr && !invocation.tty {
            kinds.insert(.stderr)
        }
        if invocation.tty && protocolVersion.supportsResize {
            kinds.insert(.resize)
        }
        return kinds
    }

    private func parseAvailableFrames() throws {
        guard var buffer = inboundBuffer else {
            return
        }

        while true {
            guard buffer.readableBytes >= 8 else {
                break
            }
            let frameStart = buffer.readerIndex
            guard
                let firstWord = buffer.getInteger(at: frameStart, endianness: .big, as: UInt32.self),
                let flagsAndLength = buffer.getInteger(at: frameStart + 4, endianness: .big, as: UInt32.self)
            else {
                break
            }
            let length = Int(flagsAndLength & 0x00FF_FFFF)
            guard buffer.readableBytes >= 8 + length else {
                break
            }

            buffer.moveReaderIndex(forwardBy: 8)
            guard var payload = buffer.readSlice(length: length) else {
                break
            }
            let flags = UInt8((flagsAndLength & 0xFF00_0000) >> 24)
            if (firstWord & 0x8000_0000) != 0 {
                let version = UInt16((firstWord >> 16) & 0x7FFF)
                let frameType = UInt16(firstWord & 0xFFFF)
                try handleControlFrame(version: version, type: frameType, flags: flags, payload: &payload)
            } else {
                let streamID = firstWord & 0x7FFF_FFFF
                handleDataFrame(streamID: streamID, flags: flags, payload: payload)
            }
        }

        buffer.discardReadBytes()
        inboundBuffer = buffer
    }

    private func handleControlFrame(
        version: UInt16,
        type: UInt16,
        flags: UInt8,
        payload: inout ByteBuffer
    ) throws {
        guard version == 3 else {
            throw CRIShimError.invalidArgument("unsupported SPDY version \(version)")
        }

        switch type {
        case 1:
            try handleSynStream(flags: flags, payload: &payload)
        case 3:
            handleRstStream(payload: &payload)
        case 4:
            break
        case 6:
            try handlePing(payload: &payload)
        case 7:
            if controlWriteGate.reject() {
                channel?.close(promise: nil)
            }
        case 9:
            break
        default:
            break
        }
    }

    private func handleSynStream(
        flags: UInt8,
        payload: inout ByteBuffer
    ) throws {
        guard
            let rawStreamID = payload.readInteger(endianness: .big, as: UInt32.self),
            payload.readInteger(endianness: .big, as: UInt32.self) != nil,
            payload.readInteger(endianness: .big, as: UInt8.self) != nil,
            payload.readInteger(endianness: .big, as: UInt8.self) != nil
        else {
            throw CRIShimError.invalidArgument("SPDY SYN_STREAM payload is truncated")
        }

        let streamID = rawStreamID & 0x7FFF_FFFF
        let headerData = Data(payload.readableBytesView)
        let headers = try parseSPDYHeaders(try inflater.decompress(headerData))
        guard
            let streamType = headers["streamtype"]?.first,
            let kind = execStreamKind(streamType),
            acceptsStream(kind)
        else {
            try writeResetFrame(streamID: streamID, status: 1)
            return
        }

        let registered = lock.withLock { () -> Bool in
            guard streamsByID[streamID] == nil, streamIDsByKind[kind] == nil else {
                return false
            }
            streamsByID[streamID] = kind
            streamIDsByKind[kind] = streamID
            return true
        }
        guard registered else {
            try writeResetFrame(streamID: streamID, status: 1)
            return
        }

        try writeSynReplyFrame(streamID: streamID)

        if (flags & 0x01) != 0 {
            handleStreamFinished(streamID)
        }
        startExecIfReady()
    }

    private func acceptsStream(_ kind: StreamKind) -> Bool {
        switch kind {
        case .error:
            true
        case .stdin:
            invocation.stdin
        case .stdout:
            invocation.stdout
        case .stderr:
            invocation.stderr && !invocation.tty
        case .resize:
            invocation.tty && protocolVersion.supportsResize
        }
    }

    private func handleRstStream(payload: inout ByteBuffer) {
        guard let streamID = payload.readInteger(endianness: .big, as: UInt32.self) else {
            return
        }
        handleStreamFinished(streamID & 0x7FFF_FFFF)
    }

    private func handlePing(payload: inout ByteBuffer) throws {
        guard let pingID = payload.readInteger(endianness: .big, as: UInt32.self) else {
            return
        }
        try writePingFrame(id: pingID)
    }

    private func handleDataFrame(
        streamID: UInt32,
        flags: UInt8,
        payload: ByteBuffer
    ) {
        let data = Data(payload.readableBytesView)
        let kind = lock.withLock { streamsByID[streamID] }
        switch kind {
        case .stdin:
            handleStdinData(data)
        case .resize:
            handleResizeData(data)
        case .error, .stdout, .stderr, .none:
            break
        }

        if (flags & 0x01) != 0 {
            handleStreamFinished(streamID)
        }
    }

    private func handleStdinData(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        let handle = lock.withLock { () -> FileHandle? in
            if let handle = stdinPipe?.fileHandleForWriting {
                return handle
            }
            pendingStdin.append(data)
            return nil
        }
        guard let handle else {
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            Task {
                await failSession(String(describing: error))
            }
        }
    }

    private func handleResizeData(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        do {
            let size = try decodeTerminalSize(data)
            let process = lock.withLock { () -> (any CRIShimStreamingProcess)? in
                guard let process = self.process else {
                    pendingResizes.append(size)
                    return nil
                }
                return process
            }
            guard let process else {
                return
            }
            let task = Task {
                do {
                    try await process.resize(size)
                } catch {
                    await failSession(String(describing: error))
                }
            }
            appendTask(task)
        } catch {
            Task {
                await failSession(String(describing: error))
            }
        }
    }

    private func handleStreamFinished(_ streamID: UInt32) {
        let (kind, handle) = lock.withLock { () -> (StreamKind?, FileHandle?) in
            guard let kind = streamsByID[streamID] else {
                return (nil, nil)
            }
            if kind == .stdin {
                stdinClosed = true
                return (kind, stdinPipe?.fileHandleForWriting)
            }
            return (kind, nil)
        }
        guard kind == .stdin else {
            return
        }
        try? handle?.close()
    }

    private func startExecIfReady() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !cleanupPerformed, !processStarting else {
                return false
            }
            guard expectedStreamKinds.isSubset(of: Set(streamIDsByKind.keys)) else {
                return false
            }
            processStarting = true
            stdinPipe = invocation.stdin ? Pipe() : nil
            stdoutPipe = invocation.stdout ? Pipe() : nil
            stderrPipe = invocation.stderr && !invocation.tty ? Pipe() : nil
            return true
        }
        guard shouldStart else {
            return
        }

        let task = Task {
            await runExecSession()
        }
        appendTask(task)
    }

    private func runExecSession() async {
        do {
            let stdio = lock.withLock {
                [
                    stdinPipe?.fileHandleForReading,
                    stdoutPipe?.fileHandleForWriting,
                    stderrPipe?.fileHandleForWriting,
                ]
            }
            let rawProcess = try await runtimeManager.streamExec(
                containerID: invocation.containerID,
                workloadID: invocation.workloadID,
                configuration: invocation.configuration,
                stdio: stdio
            )

            let startupState:
                (
                    process: CRIShimStartSynchronizedStreamingProcess,
                    stdinWriter: FileHandle?,
                    stdoutStream: FileHandleByteStream?,
                    stderrStream: FileHandleByteStream?,
                    pendingStdin: Data,
                    stdinClosed: Bool
                )?
            do {
                startupState = try lock.withLock {
                    guard !cleanupPerformed else {
                        return nil
                    }
                    let stdoutStream = try stdoutPipe.map {
                        try fileHandleStream($0.fileHandleForReading)
                    }
                    let stderrStream = try stderrPipe.map {
                        try fileHandleStream($0.fileHandleForReading)
                    }
                    let process = CRIShimStartSynchronizedStreamingProcess(
                        process: rawProcess,
                        pendingResizes: pendingResizes
                    )
                    self.process = process
                    pendingResizes.removeAll()
                    return (
                        process: process,
                        stdinWriter: stdinPipe?.fileHandleForWriting,
                        stdoutStream: stdoutStream,
                        stderrStream: stderrStream,
                        pendingStdin: pendingStdin,
                        stdinClosed: stdinClosed
                    )
                }
            } catch {
                try? await rawProcess.kill(SIGTERM)
                throw error
            }
            guard let startupState else {
                try? await rawProcess.kill(SIGTERM)
                return
            }

            if let stdinWriter = startupState.stdinWriter {
                if !startupState.pendingStdin.isEmpty {
                    try stdinWriter.write(contentsOf: startupState.pendingStdin)
                }
                if startupState.stdinClosed {
                    try? stdinWriter.close()
                }
            }

            var outputTasks: [Task<Void, Never>] = []
            if let stdoutStream = startupState.stdoutStream {
                outputTasks.append(
                    Task {
                        await pumpExecOutput(kind: .stdout, input: stdoutStream)
                    })
            }
            if let stderrStream = startupState.stderrStream {
                outputTasks.append(
                    Task {
                        await pumpExecOutput(kind: .stderr, input: stderrStream)
                    })
            }
            for task in outputTasks {
                appendTask(task)
            }

            try await startupState.process.start()

            let exitCode = try await startupState.process.wait()
            try? stdoutPipe?.fileHandleForWriting.close()
            try? stderrPipe?.fileHandleForWriting.close()
            for task in outputTasks {
                _ = await task.result
            }
            await sendExecExitStatus(exitCode: exitCode)
            await closeChannel(killProcess: false)
        } catch {
            await failSession(String(describing: error))
        }
    }

    private func pumpExecOutput(
        kind: StreamKind,
        input: FileHandleByteStream
    ) async {
        guard let streamID = lock.withLock({ streamIDsByKind[kind] }) else {
            return
        }
        for await data in input.bytes {
            do {
                try await writeDataFrame(streamID: streamID, data: data)
                recordActivity()
            } catch {
                await failSession(String(describing: error))
                return
            }
        }
        try? await writeDataFrame(streamID: streamID, data: Data(), flags: 0x01)
    }

    private func sendExecExitStatus(exitCode: Int32) async {
        let payload: Data
        if protocolVersion.supportsStructuredExitStatus {
            payload = makeStructuredExecStatus(exitCode: exitCode)
        } else if exitCode == 0 {
            payload = Data()
        } else {
            payload = Data("command terminated with exit code \(exitCode)".utf8)
        }
        guard let errorStreamID = lock.withLock({ streamIDsByKind[.error] }) else {
            return
        }
        try? await writeDataFrame(streamID: errorStreamID, data: payload, flags: 0x01)
    }

    private func failSession(_ message: String) async {
        fputs("container-cri-shim-macos SPDY exec failed: \(message)\n", stderr)
        if let errorStreamID = lock.withLock({ streamIDsByKind[.error] }) {
            let payload =
                if protocolVersion.supportsStructuredExitStatus {
                    makeStructuredExecFailureStatus(message: message)
                } else {
                    Data(message.utf8)
                }
            try? await writeDataFrame(streamID: errorStreamID, data: payload, flags: 0x01)
        }
        await closeChannel(killProcess: true)
    }

    private func closeChannel(killProcess: Bool) async {
        await cleanup(killProcess: killProcess)
        if let channel {
            try? await channel.close().get()
        }
    }

    private func cleanup(killProcess: Bool) async {
        _ = controlWriteGate.reject()
        let cleanupState = lock.withLock {
            () -> (
                process: (any CRIShimStreamingProcess)?,
                tasks: [Task<Void, Never>],
                stdinPipe: Pipe?,
                stdoutPipe: Pipe?,
                stderrPipe: Pipe?
            ) in
            if cleanupPerformed {
                return (nil, [], nil, nil, nil)
            }
            cleanupPerformed = true
            idleTimeoutTask?.cancel()
            idleTimeoutTask = nil
            let cleanupState = (
                process: process,
                tasks: tasks,
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
            tasks.removeAll()
            streamsByID.removeAll()
            streamIDsByKind.removeAll()
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            return cleanupState
        }

        for task in cleanupState.tasks {
            task.cancel()
        }
        try? cleanupState.stdinPipe?.fileHandleForReading.close()
        try? cleanupState.stdinPipe?.fileHandleForWriting.close()
        try? cleanupState.stdoutPipe?.fileHandleForReading.close()
        try? cleanupState.stdoutPipe?.fileHandleForWriting.close()
        try? cleanupState.stderrPipe?.fileHandleForReading.close()
        try? cleanupState.stderrPipe?.fileHandleForWriting.close()
        if killProcess {
            try? await cleanupState.process?.kill(SIGTERM)
        }
    }

    private func appendTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !cleanupPerformed else {
                return true
            }
            tasks.append(task)
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func recordActivity() {
        guard let idleTimeout, let channel else {
            return
        }

        let scheduled = channel.eventLoop.scheduleTask(in: idleTimeout) { [weak self] in
            guard let self else {
                return
            }
            Task {
                await self.failSession("streaming session timed out due to inactivity")
            }
        }

        let staleTask = lock.withLock { () -> Scheduled<Void>? in
            guard !cleanupPerformed else {
                scheduled.cancel()
                return nil
            }
            let previous = idleTimeoutTask
            idleTimeoutTask = scheduled
            return previous
        }
        staleTask?.cancel()
    }

    private func writeSynReplyFrame(streamID: UInt32) throws {
        let compressedHeaders = try deflater.compress(makeSPDYHeaderBlock([:]))
        var payload = Data()
        payload.append(contentsOf: spdyUInt32(streamID & 0x7FFF_FFFF))
        payload.append(compressedHeaders)
        try writeControlFrame(type: 2, flags: 0, payload: payload)
    }

    private func writeResetFrame(streamID: UInt32, status: UInt32) throws {
        var payload = Data()
        payload.append(contentsOf: spdyUInt32(streamID & 0x7FFF_FFFF))
        payload.append(contentsOf: spdyUInt32(status))
        try writeControlFrame(type: 3, flags: 0, payload: payload)
    }

    private func writePingFrame(id: UInt32) throws {
        try writeControlFrame(type: 6, flags: 0, payload: Data(spdyUInt32(id)))
    }

    private func writeControlFrame(
        type: UInt16,
        flags: UInt8,
        payload: Data
    ) throws {
        guard let channel, controlWriteGate.reserve(channel: channel) else {
            channel?.close(promise: nil)
            throw CRIShimError.unavailable("SPDY control output is backpressured")
        }
        var buffer = channel.allocator.buffer(capacity: 8 + payload.count)
        buffer.writeInteger(UInt32(0x8000_0000) | (UInt32(3) << 16) | UInt32(type), endianness: .big)
        writeSPDYLength(flags: flags, length: payload.count, to: &buffer)
        buffer.writeBytes(payload)
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self] result in
            let succeeded: Bool
            switch result {
            case .success:
                succeeded = true
            case .failure:
                succeeded = false
            }
            if self?.controlWriteGate.complete(succeeded: succeeded) == true {
                channel.close(promise: nil)
            }
        }
        channel.writeAndFlush(buffer, promise: promise)
    }

    private func writeDataFrame(
        streamID: UInt32,
        data: Data,
        flags: UInt8 = 0
    ) async throws {
        guard let channel, channel.isActive else {
            return
        }
        var buffer = channel.allocator.buffer(capacity: 8 + data.count)
        buffer.writeInteger(streamID & 0x7FFF_FFFF, endianness: .big)
        writeSPDYLength(flags: flags, length: data.count, to: &buffer)
        buffer.writeBytes(data)
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            await handleWriteFailure()
            throw error
        }
    }

    private func handleWriteFailure() async {
        _ = controlWriteGate.reject()
        await cleanup(killProcess: true)
        guard let channel else {
            return
        }
        try? await channel.close().get()
    }
}

private let criShimPortForwardMaximumPendingOutputBytes = 256 << 10
private let criShimPortForwardMaximumPendingOutputElements = 256

struct CRIShimPendingInputBuffer {
    private static let minimumCapacity = 16

    private var storage: [Data?] = []
    private var head = 0
    private var elementCount = 0

    var first: Data? {
        guard elementCount > 0 else {
            return nil
        }
        return storage[head]
    }

    var isEmpty: Bool {
        elementCount == 0
    }

    var count: Int {
        elementCount
    }

    var allocatedSlotCount: Int {
        storage.count
    }

    mutating func append(_ data: Data) {
        if elementCount == storage.count {
            grow()
        }
        let tail = (head + elementCount) % storage.count
        storage[tail] = data
        elementCount += 1
    }

    @discardableResult
    mutating func removeFirst() -> Data? {
        guard elementCount > 0 else {
            return nil
        }
        let data = storage[head]
        storage[head] = nil
        elementCount -= 1
        if elementCount == 0 {
            storage.removeAll(keepingCapacity: false)
            head = 0
        } else {
            head = (head + 1) % storage.count
        }
        return data
    }

    private mutating func grow() {
        let newCapacity = max(Self.minimumCapacity, storage.count * 2)
        var newStorage = [Data?](repeating: nil, count: newCapacity)
        if !storage.isEmpty {
            for index in 0..<elementCount {
                newStorage[index] = storage[(head + index) % storage.count]
            }
        }
        storage = newStorage
        head = 0
    }
}

private final class CRIShimPortForwardSPDYHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let maximumPendingClientInputBytesPerPair = 1 << 20
    private static let maximumPendingClientInputBytesPerSession = 4 << 20
    private static let maximumPendingClientInputElementsPerPair = 256
    private static let maximumPendingClientInputElementsPerSession = 1024
    private static let maximumActivePairs = 64
    private static let maximumPairTombstones = 128
    private static let maximumRequestIDBytes = 256

    fileprivate enum StreamKind {
        case data
        case error
    }

    private struct Stream {
        var requestID: String
        var generation: UUID
        var port: UInt32
        var kind: StreamKind
    }

    private struct Pair {
        var generation = UUID()
        var dataStreamID: UInt32?
        var errorStreamID: UInt32?
        var port: UInt32
        var openingToken: UUID?
        var writerToken: UUID?
        var outputToken: UUID?
        var tunnelLease: UUID?
        var handle: FileHandle?
        var controlConnection: CRIShimBackendControlConnection?
        var writer: FileHandleByteWriter?
        var input: FileHandleByteStream?
        var pendingInput = CRIShimPendingInputBuffer()
        var pendingInputBytes = 0
        var clientWriteClosed = false
        var backendWriteShutdown = false
        var inputRejected = false
        var terminating = false
        var terminal: PairTerminal?

        init(port: UInt32) {
            self.port = port
        }
    }

    private enum PairTerminal {
        case success
        case failure(String)
    }

    private struct PairIdentity: Hashable {
        var requestID: String
        var generation: UUID
    }

    private struct DialLaunch {
        var identity: PairIdentity
        var token: UUID
        var port: UInt32
        var dataStreamID: UInt32
        var tunnelLease: UUID
    }

    private struct WriterLaunch {
        var identity: PairIdentity
        var token: UUID
        var writer: FileHandleByteWriter
        var controlConnection: CRIShimBackendControlConnection
    }

    private struct OutputLaunch {
        var identity: PairIdentity
        var token: UUID
        var input: FileHandleByteStream?
        var backendEOFMeansSuccess: Bool
    }

    private struct PairFailure {
        var identity: PairIdentity
        var message: String
    }

    private enum ClientInputAction {
        case none
        case startWriter(WriterLaunch)
        case fail(PairFailure)
    }

    private enum BackendWriterAction {
        case stop
        case write(Data)
        case shutdown
    }

    private struct PairTerminalFrames {
        var terminal: PairTerminal
        var dataStreamID: UInt32?
        var errorStreamID: UInt32?
    }

    private final class TrackedTask: @unchecked Sendable {
        let owner: PairIdentity?
        var task: Task<Void, Never>?

        init(owner: PairIdentity?) {
            self.owner = owner
        }
    }

    private let server: CRIShimStreamingServer
    private let runtimeManager: any CRIShimRuntimeManaging
    private let invocation: CRIShimPortForwardInvocation
    private let idleTimeout: TimeAmount?
    private let controlWriteGate = CRIShimSPDYControlWriteGate()
    private let lock = NSLock()
    private var channel: Channel?
    private var inboundBuffer: ByteBuffer?
    private var highestAcceptedClientStreamID: UInt32 = 0
    private var streams: [UInt32: Stream] = [:]
    private var pairs: [String: Pair] = [:]
    private var sessionPendingInputBytes = 0
    private var sessionPendingInputElements = 0
    private var pairTombstones: Set<String> = []
    private var pairTombstoneOrder: [String] = []
    private var tasks: [UUID: TrackedTask] = [:]
    private var cleanupPerformed = false
    private var idleTimeoutTask: Scheduled<Void>?
    private var inflater = try! CRIShimSPDYHeaderInflater()
    private var deflater = try! CRIShimSPDYHeaderDeflater()

    init(
        server: CRIShimStreamingServer,
        runtimeManager: any CRIShimRuntimeManaging,
        invocation: CRIShimPortForwardInvocation,
        idleTimeout: TimeAmount?
    ) {
        self.server = server
        self.runtimeManager = runtimeManager
        self.invocation = invocation
        self.idleTimeout = idleTimeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        inboundBuffer = context.channel.allocator.buffer(capacity: 0)
        recordActivity()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !controlWriteGate.isRejected else {
            return
        }
        var incoming = unwrapInboundIn(data)
        inboundBuffer?.writeBuffer(&incoming)
        recordActivity()
        do {
            try parseAvailableFrames()
        } catch {
            if controlWriteGate.reject() {
                context.close(promise: nil)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.unregisterActiveChannel(context.channel)
        Task {
            await cleanup()
        }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        Task {
            await cleanup()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        server.unregisterActiveChannel(context.channel)
        Task {
            await cleanup()
        }
        context.close(promise: nil)
    }

    private func parseAvailableFrames() throws {
        guard var buffer = inboundBuffer else {
            return
        }

        while true {
            guard buffer.readableBytes >= 8 else {
                break
            }
            let frameStart = buffer.readerIndex
            guard
                let firstWord = buffer.getInteger(at: frameStart, endianness: .big, as: UInt32.self),
                let flagsAndLength = buffer.getInteger(at: frameStart + 4, endianness: .big, as: UInt32.self)
            else {
                break
            }
            let length = Int(flagsAndLength & 0x00FF_FFFF)
            guard buffer.readableBytes >= 8 + length else {
                break
            }

            buffer.moveReaderIndex(forwardBy: 8)
            guard var payload = buffer.readSlice(length: length) else {
                break
            }
            let flags = UInt8((flagsAndLength & 0xFF00_0000) >> 24)
            if (firstWord & 0x8000_0000) != 0 {
                let version = UInt16((firstWord >> 16) & 0x7FFF)
                let frameType = UInt16(firstWord & 0xFFFF)
                try handleControlFrame(version: version, type: frameType, flags: flags, payload: &payload)
            } else {
                let streamID = firstWord & 0x7FFF_FFFF
                handleDataFrame(streamID: streamID, flags: flags, payload: payload)
            }
        }

        buffer.discardReadBytes()
        inboundBuffer = buffer
    }

    private func handleControlFrame(
        version: UInt16,
        type: UInt16,
        flags: UInt8,
        payload: inout ByteBuffer
    ) throws {
        guard version == 3 else {
            throw CRIShimError.invalidArgument("unsupported SPDY version \(version)")
        }

        switch type {
        case 1:
            try handleSynStream(flags: flags, payload: &payload)
        case 3:
            handleRstStream(payload: &payload)
        case 4:
            break
        case 6:
            try handlePing(payload: &payload)
        case 7:
            if controlWriteGate.reject() {
                channel?.close(promise: nil)
            }
        case 9:
            break
        default:
            break
        }
    }

    private func handleSynStream(
        flags: UInt8,
        payload: inout ByteBuffer
    ) throws {
        guard
            let encodedStreamID = payload.readInteger(endianness: .big, as: UInt32.self),
            payload.readInteger(endianness: .big, as: UInt32.self) != nil,
            payload.readInteger(endianness: .big, as: UInt8.self) != nil,
            payload.readInteger(endianness: .big, as: UInt8.self) != nil
        else {
            throw CRIShimError.invalidArgument("SPDY SYN_STREAM payload is truncated")
        }
        let streamID = encodedStreamID & 0x7FFF_FFFF

        let headerData = Data(payload.readableBytesView)
        let headers = try parseSPDYHeaders(try inflater.decompress(headerData))
        guard streamID > 0, streamID.isMultiple(of: 2) == false else {
            try writeResetFrame(streamID: streamID, status: 1)
            return
        }
        guard let streamType = headers["streamtype"]?.first else {
            try writeResetFrame(streamID: streamID, status: 1)
            return
        }
        guard let kind = streamKind(streamType) else {
            try writeResetFrame(streamID: streamID, status: 1)
            return
        }
        guard let portText = headers["port"]?.first, let port = UInt32(portText), port > 0, port <= UInt32(UInt16.max) else {
            try writeResetFrame(streamID: streamID, status: 1)
            return
        }
        if !invocation.ports.isEmpty && !invocation.ports.contains(port) {
            try writeResetFrame(streamID: streamID, status: 1)
            return
        }

        let requestID: String
        if let explicitRequestIDs = headers["requestid"] {
            guard
                explicitRequestIDs.count == 1,
                let explicitRequestID = explicitRequestIDs.first,
                !explicitRequestID.isEmpty,
                explicitRequestID.utf8.count <= Self.maximumRequestIDBytes
            else {
                try writeResetFrame(streamID: streamID, status: 1)
                return
            }
            requestID = explicitRequestID
        } else if let inferredRequestID = fallbackRequestID(streamID: streamID, kind: kind) {
            requestID = inferredRequestID
        } else {
            try writeResetFrame(streamID: streamID, status: 1)
            return
        }

        let accepted = lock.withLock { () -> (PairIdentity, DialLaunch?)? in
            guard
                !cleanupPerformed,
                streamID > highestAcceptedClientStreamID,
                streams[streamID] == nil,
                !pairTombstones.contains(requestID)
            else {
                return nil
            }

            var pair: Pair
            if let existingPair = pairs[requestID] {
                guard
                    existingPair.port == port,
                    existingPair.terminal == nil,
                    !existingPair.terminating
                else {
                    return nil
                }
                pair = existingPair
            } else {
                guard pairs.count < Self.maximumActivePairs else {
                    return nil
                }
                pair = Pair(port: port)
            }

            switch kind {
            case .data:
                guard pair.dataStreamID == nil else {
                    return nil
                }
                pair.dataStreamID = streamID
            case .error:
                guard pair.errorStreamID == nil else {
                    return nil
                }
                pair.errorStreamID = streamID
            }

            let identity = PairIdentity(requestID: requestID, generation: pair.generation)
            var dialLaunch: DialLaunch?
            if kind == .data {
                guard pair.handle == nil, pair.openingToken == nil else {
                    return nil
                }
                guard let tunnelLease = server.acquirePortForwardTunnelLease() else {
                    return nil
                }
                let token = UUID()
                pair.openingToken = token
                dialLaunch = DialLaunch(
                    identity: identity,
                    token: token,
                    port: port,
                    dataStreamID: streamID,
                    tunnelLease: tunnelLease
                )
            }

            streams[streamID] = Stream(
                requestID: requestID,
                generation: pair.generation,
                port: port,
                kind: kind
            )
            highestAcceptedClientStreamID = streamID
            pairs[requestID] = pair
            return (identity, dialLaunch)
        }
        guard let accepted else {
            try writeResetFrame(streamID: streamID, status: 1)
            return
        }

        do {
            try writeSynReplyFrame(streamID: streamID)
        } catch {
            if let dialLaunch = accepted.1 {
                server.releasePortForwardTunnelLease(dialLaunch.tunnelLease)
            }
            throw error
        }

        if let dialLaunch = accepted.1 {
            startPortForward(dialLaunch)
        }

        if (flags & 0x01) != 0 {
            handleStreamFinished(streamID)
        }
    }

    private func handleRstStream(payload: inout ByteBuffer) {
        guard let streamID = payload.readInteger(endianness: .big, as: UInt32.self) else {
            return
        }
        abortPair(for: streamID & 0x7FFF_FFFF)
    }

    private func handlePing(payload: inout ByteBuffer) throws {
        guard let pingID = payload.readInteger(endianness: .big, as: UInt32.self) else {
            return
        }
        try writePingFrame(id: pingID)
    }

    private func handleDataFrame(
        streamID: UInt32,
        flags: UInt8,
        payload: ByteBuffer
    ) {
        let data = Data(payload.readableBytesView)
        let stream = lock.withLock { streams[streamID] }
        if let stream, case .data = stream.kind, !data.isEmpty {
            switch enqueueClientInput(
                requestID: stream.requestID,
                generation: stream.generation,
                data: data
            ) {
            case .none:
                break
            case .startWriter(let launch):
                startBackendWriter(launch)
            case .fail(let failure):
                failPair(failure.identity, message: failure.message)
            }
        }

        if (flags & 0x01) != 0 {
            handleStreamFinished(streamID)
        }
    }

    private func startPortForward(_ launch: DialLaunch) {
        let tunnelLeaseServer = server
        let started = startTrackedTask(owner: launch.identity) { [weak self] in
            var ownsTunnelLease = true
            defer {
                if ownsTunnelLease {
                    tunnelLeaseServer.releasePortForwardTunnelLease(launch.tunnelLease)
                }
            }
            guard let self else {
                return
            }
            var unownedHandle: FileHandle?
            var unownedControlConnection: CRIShimBackendControlConnection?
            var unownedWriter: FileHandleByteWriter?
            do {
                let openedHandle = try await runtimeManager.streamPortForward(
                    sandboxID: invocation.sandboxID,
                    port: launch.port
                )
                unownedHandle = openedHandle
                let controlConnection = try CRIShimBackendControlConnection(
                    duplicating: openedHandle.fileDescriptor
                )
                unownedControlConnection = controlConnection
                let writer = try FileHandleByteWriter(handle: openedHandle)
                unownedWriter = writer
                let input = try fileHandleStream(
                    openedHandle,
                    maximumPendingBytes: criShimPortForwardMaximumPendingOutputBytes,
                    maximumPendingElements: criShimPortForwardMaximumPendingOutputElements
                )
                let registration = lock.withLock { () -> (OutputLaunch, WriterLaunch?)? in
                    guard
                        !cleanupPerformed,
                        var pair = pairs[launch.identity.requestID],
                        pair.generation == launch.identity.generation,
                        pair.openingToken == launch.token,
                        pair.port == launch.port,
                        pair.dataStreamID == launch.dataStreamID,
                        !pair.terminating,
                        !pair.inputRejected,
                        pair.terminal == nil
                    else {
                        return nil
                    }
                    pair.openingToken = nil
                    pair.handle = openedHandle
                    pair.controlConnection = controlConnection
                    pair.writer = writer
                    pair.input = input
                    pair.tunnelLease = launch.tunnelLease
                    let outputToken = UUID()
                    pair.outputToken = outputToken
                    let writerLaunch = makeWriterLaunchIfNeeded(
                        identity: launch.identity,
                        pair: &pair
                    )
                    pairs[launch.identity.requestID] = pair
                    return (
                        OutputLaunch(
                            identity: launch.identity,
                            token: outputToken,
                            input: input,
                            backendEOFMeansSuccess: true
                        ),
                        writerLaunch
                    )
                }
                guard let registration else {
                    input.cancel()
                    controlConnection.shutdownAllAndClose()
                    writer.cancel()
                    try? openedHandle.close()
                    unownedHandle = nil
                    unownedControlConnection = nil
                    unownedWriter = nil
                    return
                }
                ownsTunnelLease = false
                unownedHandle = nil
                unownedControlConnection = nil
                unownedWriter = nil
                startOutputPump(registration.0)
                if let writerLaunch = registration.1 {
                    startBackendWriter(writerLaunch)
                }
            } catch {
                let stillOpening = lock.withLock {
                    guard let pair = pairs[launch.identity.requestID] else {
                        return false
                    }
                    return pair.generation == launch.identity.generation
                        && pair.openingToken == launch.token
                }
                if stillOpening {
                    failPair(launch.identity, message: String(describing: error))
                }
                unownedControlConnection?.shutdownAllAndClose()
                unownedWriter?.cancel()
                try? unownedHandle?.close()
            }
        }
        if !started {
            server.releasePortForwardTunnelLease(launch.tunnelLease)
        }
    }

    private func startOutputPump(_ launch: OutputLaunch) {
        startTrackedTask(owner: launch.identity) { [weak self] in
            guard let self else {
                return
            }
            if let input = launch.input {
                for await data in input.bytes {
                    let dataStreamID = lock.withLock { () -> UInt32? in
                        guard let pair = pairs[launch.identity.requestID] else {
                            return nil
                        }
                        guard
                            pair.generation == launch.identity.generation,
                            pair.outputToken == launch.token,
                            pair.terminal == nil
                        else {
                            return nil
                        }
                        return pair.dataStreamID
                    }
                    guard let dataStreamID else {
                        break
                    }
                    do {
                        try await writeDataFrame(streamID: dataStreamID, data: data)
                        input.acknowledge(data.count)
                        recordActivity()
                    } catch {
                        return
                    }
                }
            }
            await emitPairTerminal(launch)
        }
    }

    private func emitPairTerminal(_ launch: OutputLaunch) async {
        let frames = lock.withLock { () -> PairTerminalFrames? in
            guard
                var pair = pairs[launch.identity.requestID],
                pair.generation == launch.identity.generation,
                pair.outputToken == launch.token
            else {
                return nil
            }
            if pair.terminal == nil {
                guard launch.backendEOFMeansSuccess, !pair.inputRejected else {
                    return nil
                }
                pair.terminal = .success
                pair.terminating = true
                pairs[launch.identity.requestID] = pair
            }
            guard let terminal = pair.terminal else {
                return nil
            }
            return PairTerminalFrames(
                terminal: terminal,
                dataStreamID: pair.dataStreamID,
                errorStreamID: pair.errorStreamID
            )
        }
        guard let frames else {
            return
        }

        do {
            switch frames.terminal {
            case .success:
                if let dataStreamID = frames.dataStreamID {
                    try await writeDataFrame(streamID: dataStreamID, data: Data(), flags: 0x01)
                }
                if let errorStreamID = frames.errorStreamID {
                    try await writeDataFrame(streamID: errorStreamID, data: Data(), flags: 0x01)
                }
            case .failure(let message):
                if let errorStreamID = frames.errorStreamID {
                    try await writeDataFrame(
                        streamID: errorStreamID,
                        data: Data(message.utf8),
                        flags: 0x01
                    )
                }
                if let dataStreamID = frames.dataStreamID {
                    try await writeDataFrame(streamID: dataStreamID, data: Data(), flags: 0x01)
                }
            }
        } catch {
            return
        }
        finishPair(launch.identity)
    }

    private func failPair(_ identity: PairIdentity, message: String) {
        let failure = lock.withLock { () -> (FileHandleByteStream?, OutputLaunch?)? in
            guard
                var pair = pairs[identity.requestID],
                pair.generation == identity.generation,
                pair.terminal == nil
            else {
                return nil
            }
            pair.inputRejected = true
            pair.terminating = true
            pair.terminal = .failure(message)
            var outputLaunch: OutputLaunch?
            if pair.outputToken == nil {
                let token = UUID()
                pair.outputToken = token
                outputLaunch = OutputLaunch(
                    identity: identity,
                    token: token,
                    input: nil,
                    backendEOFMeansSuccess: false
                )
            }
            pairs[identity.requestID] = pair
            return (pair.input, outputLaunch)
        }
        guard let failure else {
            return
        }
        failure.0?.cancel()
        if let outputLaunch = failure.1 {
            startOutputPump(outputLaunch)
        }
    }

    private func handleStreamFinished(_ streamID: UInt32) {
        let stream = lock.withLock {
            streams[streamID]
        }
        guard let stream else {
            return
        }
        if case .data = stream.kind {
            let writerLaunch = lock.withLock { () -> WriterLaunch? in
                guard
                    var pair = pairs[stream.requestID],
                    pair.generation == stream.generation,
                    !pair.terminating,
                    !pair.inputRejected
                else {
                    return nil
                }
                pair.clientWriteClosed = true
                let identity = PairIdentity(
                    requestID: stream.requestID,
                    generation: stream.generation
                )
                let launch = makeWriterLaunchIfNeeded(identity: identity, pair: &pair)
                pairs[stream.requestID] = pair
                return launch
            }
            if let writerLaunch {
                startBackendWriter(writerLaunch)
            }
        }
    }

    private func enqueueClientInput(
        requestID: String,
        generation: UUID,
        data: Data
    ) -> ClientInputAction {
        lock.withLock {
            guard
                var pair = pairs[requestID],
                pair.generation == generation,
                !pair.terminating,
                !pair.inputRejected,
                !pair.clientWriteClosed
            else {
                return .none
            }
            let identity = PairIdentity(requestID: requestID, generation: generation)
            guard
                pair.pendingInputBytes <= Self.maximumPendingClientInputBytesPerPair,
                data.count
                    <= Self.maximumPendingClientInputBytesPerPair - pair.pendingInputBytes
            else {
                pair.inputRejected = true
                pairs[requestID] = pair
                return .fail(
                    PairFailure(
                        identity: identity,
                        message: "port-forward pending client input exceeded \(Self.maximumPendingClientInputBytesPerPair) bytes"
                    )
                )
            }
            guard
                sessionPendingInputBytes <= Self.maximumPendingClientInputBytesPerSession,
                data.count
                    <= Self.maximumPendingClientInputBytesPerSession - sessionPendingInputBytes
            else {
                pair.inputRejected = true
                pairs[requestID] = pair
                return .fail(
                    PairFailure(
                        identity: identity,
                        message: "port-forward session pending client input exceeded \(Self.maximumPendingClientInputBytesPerSession) bytes"
                    )
                )
            }
            guard pair.pendingInput.count < Self.maximumPendingClientInputElementsPerPair else {
                pair.inputRejected = true
                pairs[requestID] = pair
                return .fail(
                    PairFailure(
                        identity: identity,
                        message: "port-forward pending client input exceeded \(Self.maximumPendingClientInputElementsPerPair) chunks"
                    )
                )
            }
            guard sessionPendingInputElements < Self.maximumPendingClientInputElementsPerSession else {
                pair.inputRejected = true
                pairs[requestID] = pair
                return .fail(
                    PairFailure(
                        identity: identity,
                        message: "port-forward session pending client input exceeded \(Self.maximumPendingClientInputElementsPerSession) chunks"
                    )
                )
            }
            pair.pendingInput.append(data)
            pair.pendingInputBytes += data.count
            sessionPendingInputBytes += data.count
            sessionPendingInputElements += 1
            let writerLaunch = makeWriterLaunchIfNeeded(identity: identity, pair: &pair)
            pairs[requestID] = pair
            if let writerLaunch {
                return .startWriter(writerLaunch)
            }
            return .none
        }
    }

    private func makeWriterLaunchIfNeeded(
        identity: PairIdentity,
        pair: inout Pair
    ) -> WriterLaunch? {
        guard
            pair.generation == identity.generation,
            pair.writerToken == nil,
            pair.terminal == nil,
            !pair.inputRejected,
            let writer = pair.writer,
            let controlConnection = pair.controlConnection,
            !pair.pendingInput.isEmpty || (pair.clientWriteClosed && !pair.backendWriteShutdown)
        else {
            return nil
        }
        let token = UUID()
        pair.writerToken = token
        return WriterLaunch(
            identity: identity,
            token: token,
            writer: writer,
            controlConnection: controlConnection
        )
    }

    private func startBackendWriter(_ launch: WriterLaunch) {
        startTrackedTask(owner: launch.identity) { [weak self] in
            await self?.runBackendWriter(launch)
        }
    }

    private func runBackendWriter(_ launch: WriterLaunch) async {
        var completedBytes = 0
        while true {
            let action = lock.withLock { () -> BackendWriterAction in
                guard
                    var pair = pairs[launch.identity.requestID],
                    pair.generation == launch.identity.generation,
                    pair.writerToken == launch.token,
                    pair.writer === launch.writer
                else {
                    return .stop
                }
                if completedBytes > 0 {
                    assert(pair.pendingInputBytes >= completedBytes)
                    assert(sessionPendingInputBytes >= completedBytes)
                    assert(sessionPendingInputElements > 0)
                    assert(pair.pendingInput.first?.count == completedBytes)
                    pair.pendingInput.removeFirst()
                    pair.pendingInputBytes -= min(pair.pendingInputBytes, completedBytes)
                    sessionPendingInputBytes -= min(sessionPendingInputBytes, completedBytes)
                    sessionPendingInputElements -= 1
                    completedBytes = 0
                }
                guard !pair.terminating, !pair.inputRejected, pair.terminal == nil else {
                    pair.writerToken = nil
                    pairs[launch.identity.requestID] = pair
                    return .stop
                }
                if let data = pair.pendingInput.first {
                    pairs[launch.identity.requestID] = pair
                    return .write(data)
                }

                if pair.clientWriteClosed, !pair.backendWriteShutdown {
                    pair.backendWriteShutdown = true
                    pair.writerToken = nil
                    pairs[launch.identity.requestID] = pair
                    return .shutdown
                }
                pair.writerToken = nil
                pairs[launch.identity.requestID] = pair
                return .stop
            }

            switch action {
            case .stop:
                return
            case .write(let data):
                do {
                    try await launch.writer.write(data)
                    completedBytes = data.count
                } catch {
                    failPair(launch.identity, message: String(describing: error))
                    return
                }
            case .shutdown:
                do {
                    try launch.controlConnection.shutdownWrite()
                } catch {
                    failPair(launch.identity, message: String(describing: error))
                }
                return
            }
        }
    }

    private func abortPair(for streamID: UInt32) {
        let identity = lock.withLock { () -> PairIdentity? in
            guard let stream = streams[streamID] else {
                return nil
            }
            return PairIdentity(requestID: stream.requestID, generation: stream.generation)
        }
        guard let identity else {
            return
        }
        finishPair(identity)
    }

    private func finishPair(_ identity: PairIdentity) {
        let resources = lock.withLock {
            () -> (
                FileHandle?,
                CRIShimBackendControlConnection?,
                FileHandleByteWriter?,
                FileHandleByteStream?,
                UUID?,
                [Task<Void, Never>]
            ) in
            guard
                let pair = pairs[identity.requestID],
                pair.generation == identity.generation
            else {
                return (nil, nil, nil, nil, nil, [])
            }
            pairs.removeValue(forKey: identity.requestID)
            streams = streams.filter { $0.value.generation != identity.generation }
            assert(sessionPendingInputBytes >= pair.pendingInputBytes)
            sessionPendingInputBytes -= min(sessionPendingInputBytes, pair.pendingInputBytes)
            assert(sessionPendingInputElements >= pair.pendingInput.count)
            sessionPendingInputElements -= min(
                sessionPendingInputElements,
                pair.pendingInput.count
            )
            addPairTombstoneLocked(identity.requestID)

            let taskIDs = tasks.compactMap { id, trackedTask in
                trackedTask.owner == identity ? id : nil
            }
            let tasksToCancel = taskIDs.compactMap { id in
                tasks.removeValue(forKey: id)?.task
            }
            return (
                pair.handle,
                pair.controlConnection,
                pair.writer,
                pair.input,
                pair.tunnelLease,
                tasksToCancel
            )
        }
        resources.1?.shutdownAllAndClose()
        resources.2?.cancel()
        for task in resources.5 {
            task.cancel()
        }
        resources.3?.cancel()
        try? resources.0?.close()
        if let tunnelLease = resources.4 {
            server.releasePortForwardTunnelLease(tunnelLease)
        }
    }

    private func addPairTombstoneLocked(_ requestID: String) {
        if pairTombstones.insert(requestID).inserted {
            pairTombstoneOrder.append(requestID)
        }
        while pairTombstoneOrder.count > Self.maximumPairTombstones {
            pairTombstones.remove(pairTombstoneOrder.removeFirst())
        }
    }

    private func failSession(_ message: String) async {
        fputs("container-cri-shim-macos SPDY port-forward failed: \(message)\n", stderr)
        await cleanup()
        if let channel {
            try? await channel.close().get()
        }
    }

    private func cleanup() async {
        _ = controlWriteGate.reject()
        let (connections, tunnelLeases, tasksToCancel):
            (
                [(
                    FileHandle?,
                    CRIShimBackendControlConnection?,
                    FileHandleByteWriter?,
                    FileHandleByteStream?
                )],
                [UUID],
                [Task<Void, Never>]
            ) = lock.withLock {
                if cleanupPerformed {
                    return ([], [], [])
                }
                cleanupPerformed = true
                idleTimeoutTask?.cancel()
                idleTimeoutTask = nil
                let connections = pairs.values.map {
                    ($0.handle, $0.controlConnection, $0.writer, $0.input)
                }
                let tunnelLeases = pairs.values.compactMap(\.tunnelLease)
                pairs.removeAll()
                streams.removeAll()
                highestAcceptedClientStreamID = 0
                sessionPendingInputBytes = 0
                sessionPendingInputElements = 0
                pairTombstones.removeAll()
                pairTombstoneOrder.removeAll()
                let tasksToCancel = tasks.values.compactMap(\.task)
                tasks.removeAll()
                return (connections, tunnelLeases, tasksToCancel)
            }

        for (_, controlConnection, writer, _) in connections {
            controlConnection?.shutdownAllAndClose()
            writer?.cancel()
        }
        for task in tasksToCancel {
            task.cancel()
        }
        for (handle, _, _, input) in connections {
            input?.cancel()
            try? handle?.close()
        }
        for tunnelLease in tunnelLeases {
            server.releasePortForwardTunnelLease(tunnelLease)
        }
    }

    @discardableResult
    private func startTrackedTask(
        owner: PairIdentity?,
        operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        let id = UUID()
        let trackedTask = TrackedTask(owner: owner)
        let shouldStart = lock.withLock {
            guard !cleanupPerformed else {
                return false
            }
            tasks[id] = trackedTask
            return true
        }
        guard shouldStart else {
            return false
        }

        let task = Task { [weak self] in
            await operation()
            self?.trackedTaskFinished(id)
        }
        let shouldCancel = lock.withLock {
            trackedTask.task = task
            return cleanupPerformed || tasks[id] !== trackedTask
        }
        if shouldCancel {
            task.cancel()
        }
        return true
    }

    private func trackedTaskFinished(_ id: UUID) {
        _ = lock.withLock {
            tasks.removeValue(forKey: id)
        }
    }

    private func recordActivity() {
        guard let idleTimeout, let channel else {
            return
        }

        let scheduled = channel.eventLoop.scheduleTask(in: idleTimeout) { [weak self] in
            guard let self else {
                return
            }
            Task {
                await self.failSession("streaming session timed out due to inactivity")
            }
        }

        let staleTask = lock.withLock { () -> Scheduled<Void>? in
            guard !cleanupPerformed else {
                scheduled.cancel()
                return nil
            }
            let previous = idleTimeoutTask
            idleTimeoutTask = scheduled
            return previous
        }
        staleTask?.cancel()
    }

    private func writeSynReplyFrame(streamID: UInt32) throws {
        let compressedHeaders = try deflater.compress(makeSPDYHeaderBlock([:]))
        var payload = Data()
        payload.append(contentsOf: spdyUInt32(streamID & 0x7FFF_FFFF))
        payload.append(compressedHeaders)
        try writeControlFrame(type: 2, flags: 0, payload: payload)
    }

    private func writeResetFrame(streamID: UInt32, status: UInt32) throws {
        var payload = Data()
        payload.append(contentsOf: spdyUInt32(streamID & 0x7FFF_FFFF))
        payload.append(contentsOf: spdyUInt32(status))
        try writeControlFrame(type: 3, flags: 0, payload: payload)
    }

    private func writePingFrame(id: UInt32) throws {
        try writeControlFrame(type: 6, flags: 0, payload: Data(spdyUInt32(id)))
    }

    private func writeControlFrame(
        type: UInt16,
        flags: UInt8,
        payload: Data
    ) throws {
        guard let channel, controlWriteGate.reserve(channel: channel) else {
            channel?.close(promise: nil)
            throw CRIShimError.unavailable("SPDY control output is backpressured")
        }
        var buffer = channel.allocator.buffer(capacity: 8 + payload.count)
        buffer.writeInteger(UInt32(0x8000_0000) | (UInt32(3) << 16) | UInt32(type), endianness: .big)
        writeSPDYLength(flags: flags, length: payload.count, to: &buffer)
        buffer.writeBytes(payload)
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self] result in
            let succeeded: Bool
            switch result {
            case .success:
                succeeded = true
            case .failure:
                succeeded = false
            }
            if self?.controlWriteGate.complete(succeeded: succeeded) == true {
                channel.close(promise: nil)
            }
        }
        channel.writeAndFlush(buffer, promise: promise)
    }

    private func writeDataFrame(
        streamID: UInt32,
        data: Data,
        flags: UInt8 = 0
    ) async throws {
        guard let channel, channel.isActive else {
            return
        }
        var buffer = channel.allocator.buffer(capacity: 8 + data.count)
        buffer.writeInteger(streamID & 0x7FFF_FFFF, endianness: .big)
        writeSPDYLength(flags: flags, length: data.count, to: &buffer)
        buffer.writeBytes(data)
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            await handleWriteFailure()
            throw error
        }
    }

    private func handleWriteFailure() async {
        _ = controlWriteGate.reject()
        await cleanup()
        guard let channel else {
            return
        }
        try? await channel.close().get()
    }
}

final class CRIShimPortForwardOutboundSequence: @unchecked Sendable {
    private final class Work: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        var task: Task<Void, Never>?
        private var result = false

        func record(_ result: Bool) {
            lock.withLock {
                self.result = result
            }
        }

        var recordedResult: Bool {
            lock.withLock { result }
        }
    }

    private let lock = NSLock()
    private var tail: Work?
    private var works: [UUID: Work] = [:]
    private var terminalRequested = false
    private var stopped = false

    func sendData(
        _ operation: @escaping @Sendable () async -> Bool
    ) async -> Bool? {
        guard let work = enqueue(terminal: false, operation: operation) else {
            return nil
        }
        await work.task?.value
        let result = work.recordedResult
        workFinished(work)
        return result
    }

    func sendTerminal(
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        guard
            let work = enqueue(
                terminal: true,
                operation: {
                    await operation()
                    return true
                })
        else {
            return
        }
        await work.task?.value
        workFinished(work)
    }

    func stop() {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            guard !stopped else {
                return []
            }
            stopped = true
            terminalRequested = true
            let tasks = works.values.compactMap(\.task)
            works.removeAll()
            tail = nil
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
    }

    private func enqueue(
        terminal: Bool,
        operation: @escaping @Sendable () async -> Bool
    ) -> Work? {
        lock.withLock {
            guard !stopped, terminal || !terminalRequested else {
                return nil
            }
            guard !terminal || !terminalRequested else {
                return nil
            }
            if terminal {
                terminalRequested = true
            }
            let previousTask = tail?.task
            let work = Work()
            let task = Task.detached { [weak work] in
                if let previousTask {
                    await previousTask.value
                }
                guard let work, !Task.isCancelled else {
                    return
                }
                work.record(await operation())
            }
            work.task = task
            works[work.id] = work
            tail = work
            return work
        }
    }

    private func workFinished(_ work: Work) {
        lock.withLock {
            works.removeValue(forKey: work.id)
            if tail === work {
                tail = nil
            }
        }
    }

    var pendingWorkCount: Int {
        lock.withLock { works.count }
    }
}

private final class CRIShimStreamingWebSocketHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private static let maximumInboundBinaryFrameBytes = 4 << 20

    private enum InboundBinaryFrameAdmission {
        case accepted
        case reject
        case ignored
    }

    private enum SessionState {
        case exec(CRIShimExecSessionState)
        case portForward(CRIShimPortForwardState)
    }

    private final class CRIShimExecSessionState {
        let protocolVersion: CRIShimExecStreamProtocol
        let invocation: CRIShimExecStreamingInvocation
        let process: any CRIShimStreamingProcess
        let stdinPipe: Pipe?
        let stdoutPipe: Pipe?
        let stderrPipe: Pipe?

        init(
            protocolVersion: CRIShimExecStreamProtocol,
            invocation: CRIShimExecStreamingInvocation,
            process: any CRIShimStreamingProcess,
            stdinPipe: Pipe?,
            stdoutPipe: Pipe?,
            stderrPipe: Pipe?
        ) {
            self.protocolVersion = protocolVersion
            self.invocation = invocation
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }
    }

    private final class CRIShimPortForwardState: @unchecked Sendable {
        private static let maximumPendingInputBytesPerStream = 1 << 20
        private static let maximumPendingInputBytesPerSession = 4 << 20
        private static let maximumPendingInputElementsPerStream = 256
        private static let maximumPendingInputElementsPerSession = 1024

        struct StreamIdentity: Hashable, Sendable {
            var stream: UInt8
            var generation: UUID
        }

        struct Connection {
            var handle: FileHandle
            var controlConnection: CRIShimBackendControlConnection
            var writer: FileHandleByteWriter
            var input: FileHandleByteStream
            var tunnelLease: UUID
        }

        struct OpenLaunch {
            var identity: StreamIdentity
            var token: UUID
            var port: UInt32
        }

        struct WriterLaunch {
            var identity: StreamIdentity
            var token: UUID
            var port: UInt32
            var writer: FileHandleByteWriter
        }

        struct StreamFailure {
            var identity: StreamIdentity
            var port: UInt32
            var message: String
        }

        struct CommitResult {
            var identity: StreamIdentity
            var writer: WriterLaunch?
        }

        struct Removal {
            var connection: Connection?
            var outputSequence: CRIShimPortForwardOutboundSequence
        }

        enum InputAction {
            case none
            case open(OpenLaunch)
            case startWriter(WriterLaunch)
            case fail(StreamFailure)
            case portMismatch(UInt32)
            case closed
        }

        enum WriterAction {
            case stop
            case write(Data)
        }

        private struct StreamState {
            var generation = UUID()
            var port: UInt32
            var openingToken: UUID?
            var connection: Connection?
            var pendingInput = CRIShimPendingInputBuffer()
            var pendingInputBytes = 0
            var writerToken: UUID?
            var rejected = false
            let outputSequence = CRIShimPortForwardOutboundSequence()

            init(port: UInt32) {
                self.port = port
            }
        }

        let invocation: CRIShimPortForwardInvocation
        private let lock = NSLock()
        private var streams: [UInt8: StreamState] = [:]
        private var closedStreams: Set<UInt8> = []
        private var pendingInputBytes = 0
        private var pendingInputElements = 0

        init(invocation: CRIShimPortForwardInvocation) {
            self.invocation = invocation
        }

        var usesDynamicPorts: Bool {
            invocation.ports.isEmpty
        }

        var isEmpty: Bool {
            lock.withLock {
                streams.isEmpty
            }
        }

        func requestedPort(for stream: UInt8) -> UInt32? {
            guard !invocation.ports.isEmpty else {
                return nil
            }
            let index = Int(stream / 2)
            guard index < invocation.ports.count else {
                return nil
            }
            return invocation.ports[index]
        }

        func enqueue(
            stream: UInt8,
            port: UInt32,
            input: Data
        ) -> InputAction {
            lock.withLock {
                guard !closedStreams.contains(stream) else {
                    return .closed
                }
                let isNewStream = streams[stream] == nil
                var state = streams[stream] ?? StreamState(port: port)
                guard state.port == port else {
                    return .portMismatch(state.port)
                }
                let identity = StreamIdentity(stream: stream, generation: state.generation)
                guard
                    state.pendingInputBytes <= Self.maximumPendingInputBytesPerStream,
                    input.count <= Self.maximumPendingInputBytesPerStream - state.pendingInputBytes
                else {
                    state.rejected = true
                    streams[stream] = state
                    return .fail(
                        StreamFailure(
                            identity: identity,
                            port: port,
                            message: "websocket port-forward stream pending input exceeded \(Self.maximumPendingInputBytesPerStream) bytes"
                        ))
                }
                guard
                    pendingInputBytes <= Self.maximumPendingInputBytesPerSession,
                    input.count <= Self.maximumPendingInputBytesPerSession - pendingInputBytes
                else {
                    state.rejected = true
                    streams[stream] = state
                    return .fail(
                        StreamFailure(
                            identity: identity,
                            port: port,
                            message: "websocket port-forward session pending input exceeded \(Self.maximumPendingInputBytesPerSession) bytes"
                        ))
                }
                if !input.isEmpty {
                    guard state.pendingInput.count < Self.maximumPendingInputElementsPerStream else {
                        state.rejected = true
                        streams[stream] = state
                        return .fail(
                            StreamFailure(
                                identity: identity,
                                port: port,
                                message: "websocket port-forward stream pending input exceeded \(Self.maximumPendingInputElementsPerStream) chunks"
                            ))
                    }
                    guard pendingInputElements < Self.maximumPendingInputElementsPerSession else {
                        state.rejected = true
                        streams[stream] = state
                        return .fail(
                            StreamFailure(
                                identity: identity,
                                port: port,
                                message: "websocket port-forward session pending input exceeded \(Self.maximumPendingInputElementsPerSession) chunks"
                            ))
                    }
                    state.pendingInput.append(input)
                    state.pendingInputBytes += input.count
                    pendingInputBytes += input.count
                    pendingInputElements += 1
                }
                if isNewStream {
                    let token = UUID()
                    state.openingToken = token
                    streams[stream] = state
                    return .open(OpenLaunch(identity: identity, token: token, port: port))
                }
                if let writer = makeWriterLaunchIfNeeded(identity: identity, state: &state) {
                    streams[stream] = state
                    return .startWriter(writer)
                }
                streams[stream] = state
                return .none
            }
        }

        func commitOpening(
            _ launch: OpenLaunch,
            connection: Connection
        ) -> CommitResult? {
            lock.withLock {
                guard
                    var state = streams[launch.identity.stream],
                    state.generation == launch.identity.generation,
                    state.openingToken == launch.token,
                    state.port == launch.port,
                    state.connection == nil,
                    !state.rejected
                else {
                    return nil
                }
                state.openingToken = nil
                state.connection = connection
                let writer = makeWriterLaunchIfNeeded(identity: launch.identity, state: &state)
                streams[launch.identity.stream] = state
                return CommitResult(identity: launch.identity, writer: writer)
            }
        }

        func nextWriterAction(
            _ launch: WriterLaunch,
            completedBytes: Int
        ) -> WriterAction {
            lock.withLock {
                guard
                    var state = streams[launch.identity.stream],
                    state.generation == launch.identity.generation,
                    state.writerToken == launch.token,
                    state.connection?.writer === launch.writer
                else {
                    return .stop
                }
                if completedBytes > 0 {
                    assert(state.pendingInputBytes >= completedBytes)
                    assert(pendingInputBytes >= completedBytes)
                    assert(pendingInputElements > 0)
                    assert(state.pendingInput.first?.count == completedBytes)
                    state.pendingInput.removeFirst()
                    state.pendingInputBytes -= min(state.pendingInputBytes, completedBytes)
                    pendingInputBytes -= min(pendingInputBytes, completedBytes)
                    pendingInputElements -= 1
                }
                guard !state.rejected else {
                    state.writerToken = nil
                    streams[launch.identity.stream] = state
                    return .stop
                }
                if let input = state.pendingInput.first {
                    streams[launch.identity.stream] = state
                    return .write(input)
                }
                state.writerToken = nil
                streams[launch.identity.stream] = state
                return .stop
            }
        }

        func remove(_ identity: StreamIdentity) -> Removal? {
            lock.withLock {
                guard
                    let state = streams[identity.stream],
                    state.generation == identity.generation
                else {
                    return nil
                }
                streams.removeValue(forKey: identity.stream)
                assert(pendingInputBytes >= state.pendingInputBytes)
                pendingInputBytes -= min(pendingInputBytes, state.pendingInputBytes)
                assert(pendingInputElements >= state.pendingInput.count)
                pendingInputElements -= min(pendingInputElements, state.pendingInput.count)
                closedStreams.insert(identity.stream)
                return Removal(
                    connection: state.connection,
                    outputSequence: state.outputSequence
                )
            }
        }

        func outputSequence(for identity: StreamIdentity) -> CRIShimPortForwardOutboundSequence? {
            lock.withLock {
                guard
                    let state = streams[identity.stream],
                    state.generation == identity.generation
                else {
                    return nil
                }
                return state.outputSequence
            }
        }

        func takeRemovals() -> [Removal] {
            lock.withLock {
                let removals = streams.values.map {
                    Removal(
                        connection: $0.connection,
                        outputSequence: $0.outputSequence
                    )
                }
                streams.removeAll()
                closedStreams.removeAll()
                pendingInputBytes = 0
                pendingInputElements = 0
                return removals
            }
        }

        private func makeWriterLaunchIfNeeded(
            identity: StreamIdentity,
            state: inout StreamState
        ) -> WriterLaunch? {
            guard
                state.generation == identity.generation,
                state.writerToken == nil,
                !state.rejected,
                !state.pendingInput.isEmpty,
                let writer = state.connection?.writer
            else {
                return nil
            }
            let token = UUID()
            state.writerToken = token
            return WriterLaunch(identity: identity, token: token, port: state.port, writer: writer)
        }
    }

    private final class PortForwardTrackedTask: @unchecked Sendable {
        let owner: CRIShimPortForwardState.StreamIdentity
        var task: Task<Void, Never>?

        init(owner: CRIShimPortForwardState.StreamIdentity) {
            self.owner = owner
        }
    }

    private final class TrackedPongTask: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    private let server: CRIShimStreamingServer
    private let runtimeManager: any CRIShimRuntimeManaging
    private let session: CRIShimStreamingSessionDescriptor
    private let negotiatedSubprotocol: String
    private let idleTimeout: TimeAmount?
    private let stateLock = NSLock()
    private let inboundBinaryFrames: AsyncStream<ByteBuffer>
    private let inboundBinaryFrameContinuation: AsyncStream<ByteBuffer>.Continuation
    private var channel: Channel?
    private var cleanupPerformed = false
    private var terminalCloseStarted = false
    private var inboundBinaryFrameBytes = 0
    private var inboundBinaryInputRejected = false
    private var backgroundTasks: [Task<Void, Never>] = []
    private var portForwardTasks: [UUID: PortForwardTrackedTask] = [:]
    private var pongTask: TrackedPongTask?
    private var sessionState: SessionState?
    private var idleTimeoutTask: Scheduled<Void>?

    init(
        server: CRIShimStreamingServer,
        runtimeManager: any CRIShimRuntimeManaging,
        session: CRIShimStreamingSessionDescriptor,
        negotiatedSubprotocol: String,
        idleTimeout: TimeAmount?
    ) {
        self.server = server
        self.runtimeManager = runtimeManager
        self.session = session
        self.negotiatedSubprotocol = negotiatedSubprotocol
        self.idleTimeout = idleTimeout
        let inboundFrames = AsyncStream.makeStream(
            of: ByteBuffer.self,
            bufferingPolicy: .bufferingOldest(256)
        )
        self.inboundBinaryFrames = inboundFrames.stream
        self.inboundBinaryFrameContinuation = inboundFrames.continuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        recordActivity()
        startSession()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !terminalCloseSnapshot() else {
            return
        }
        let frame = unwrapInboundIn(data)
        recordActivity()

        switch frame.opcode {
        case .binary:
            let payload = frame.unmaskedData
            switch reserveInboundBinaryFrame(payload) {
            case .ignored:
                return
            case .reject:
                closeSessionSynchronously(context: context)
                return
            case .accepted:
                break
            }
            switch inboundBinaryFrameContinuation.yield(payload) {
            case .enqueued:
                break
            case .dropped(let droppedPayload):
                if rejectInboundBinaryInput(releasing: droppedPayload.readableBytes) {
                    closeSessionSynchronously(context: context)
                }
            case .terminated:
                releaseInboundBinaryFrame(payload)
                break
            @unknown default:
                if rejectInboundBinaryInput(releasing: payload.readableBytes) {
                    closeSessionSynchronously(context: context)
                }
            }
        case .ping:
            guard context.channel.isWritable else {
                closeSessionSynchronously(context: context)
                return
            }
            startPong(frame.unmaskedData)
        case .connectionClose:
            closeSessionSynchronously(context: context)
        case .text, .continuation:
            closeSessionSynchronously(context: context)
        case .pong:
            break
        default:
            closeSessionSynchronously(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.unregisterActiveChannel(context.channel)
        Task {
            await cleanup(killProcess: true)
        }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        Task {
            await cleanup(killProcess: true)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        server.unregisterActiveChannel(context.channel)
        Task {
            await cleanup(killProcess: true)
        }
        context.close(promise: nil)
    }

    private func startSession() {
        let frames = inboundBinaryFrames
        let session = session
        let task = Task { [weak self] in
            do {
                switch session {
                case .exec(let invocation):
                    try await self?.startExecSession(invocation)
                case .portForward(let invocation):
                    try await self?.startPortForwardSession(invocation)
                }
                for await payload in frames {
                    self?.releaseInboundBinaryFrame(payload)
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.handleBinaryFrame(payload)
                }
            } catch {
                await self?.failSession(String(describing: error))
            }
        }
        appendTask(task)
    }

    private func startExecSession(_ invocation: CRIShimExecStreamingInvocation) async throws {
        guard let protocolVersion = CRIShimExecStreamProtocol(rawValue: negotiatedSubprotocol) else {
            throw CRIShimError.invalidArgument("exec websocket subprotocol negotiation is missing")
        }

        let stdinPipe = invocation.stdin ? Pipe() : nil
        let stdoutPipe = invocation.stdout ? Pipe() : nil
        let stderrPipe = invocation.stderr && !invocation.tty ? Pipe() : nil
        let stdoutInput = try stdoutPipe.map {
            try fileHandleStream($0.fileHandleForReading)
        }
        let stderrInput = try stderrPipe.map {
            try fileHandleStream($0.fileHandleForReading)
        }
        let rawProcess = try await runtimeManager.streamExec(
            containerID: invocation.containerID,
            workloadID: invocation.workloadID,
            configuration: invocation.configuration,
            stdio: [
                stdinPipe?.fileHandleForReading,
                stdoutPipe?.fileHandleForWriting,
                stderrPipe?.fileHandleForWriting,
            ]
        )
        let process = CRIShimStartSynchronizedStreamingProcess(process: rawProcess)
        let registered = stateLock.withLock { () -> Bool in
            guard !cleanupPerformed else {
                return false
            }
            sessionState = .exec(
                CRIShimExecSessionState(
                    protocolVersion: protocolVersion,
                    invocation: invocation,
                    process: process,
                    stdinPipe: stdinPipe,
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe
                )
            )
            return true
        }
        guard registered else {
            stdoutInput?.cancel()
            stderrInput?.cancel()
            try? stdinPipe?.fileHandleForReading.close()
            try? stdinPipe?.fileHandleForWriting.close()
            try? stdoutPipe?.fileHandleForReading.close()
            try? stdoutPipe?.fileHandleForWriting.close()
            try? stderrPipe?.fileHandleForReading.close()
            try? stderrPipe?.fileHandleForWriting.close()
            try? await process.kill(SIGTERM)
            return
        }

        var outputTasks: [Task<Void, Never>] = []
        if let stdoutInput {
            outputTasks.append(
                Task {
                    await pumpExecOutput(
                        stream: 1,
                        input: stdoutInput
                    )
                })
        }
        if let stderrInput {
            outputTasks.append(
                Task {
                    await pumpExecOutput(
                        stream: 2,
                        input: stderrInput
                    )
                })
        }
        for task in outputTasks {
            appendTask(task)
        }

        try await process.start()

        appendTask(
            Task {
                do {
                    let exitCode = try await process.wait()
                    try? stdoutPipe?.fileHandleForWriting.close()
                    try? stderrPipe?.fileHandleForWriting.close()
                    for task in outputTasks {
                        _ = await task.result
                    }
                    await finishExecSession(protocolVersion: protocolVersion, exitCode: exitCode)
                } catch {
                    await failSession(String(describing: error))
                }
            })
    }

    private func startPortForwardSession(_ invocation: CRIShimPortForwardInvocation) async throws {
        guard invocation.ports.count <= 128 else {
            throw CRIShimError.invalidArgument("websocket port-forward supports at most 128 ports")
        }
        let state = CRIShimPortForwardState(invocation: invocation)
        let sessionRegistered = stateLock.withLock { () -> Bool in
            guard !cleanupPerformed else {
                return false
            }
            sessionState = .portForward(state)
            return true
        }
        guard sessionRegistered else {
            return
        }

        for (index, port) in invocation.ports.enumerated() {
            guard let stream = UInt8(exactly: index * 2) else {
                throw CRIShimError.invalidArgument("websocket port-forward stream index is out of range")
            }
            switch state.enqueue(stream: stream, port: port, input: Data()) {
            case .open(let launch):
                await openPortForwardStream(state: state, launch: launch)
            case .fail(let failure):
                await failPortForwardStream(state: state, failure: failure)
            case .portMismatch(let existingPort):
                throw CRIShimError.invalidArgument(
                    "portforward stream \(stream) changed port from \(existingPort) to \(port)"
                )
            case .closed:
                continue
            case .none, .startWriter:
                break
            }
        }

        if !invocation.ports.isEmpty && state.isEmpty {
            await closeWebSocket(killProcess: false)
        }
    }

    private func handleBinaryFrame(_ payload: ByteBuffer) async {
        var payload = payload
        guard let stream = payload.readInteger(as: UInt8.self) else {
            await failSession("websocket frame did not contain a stream identifier")
            return
        }

        switch sessionStateSnapshot() {
        case .exec(let state):
            await handleExecFrame(stream: stream, payload: payload, state: state)
        case .portForward(let state):
            await handlePortForwardFrame(stream: stream, payload: payload, state: state)
        case .none:
            await failSession("streaming session is not ready")
        }
    }

    private func handleExecFrame(
        stream: UInt8,
        payload: ByteBuffer,
        state: CRIShimExecSessionState
    ) async {
        switch stream {
        case 0:
            guard let stdin = state.stdinPipe?.fileHandleForWriting else {
                return
            }
            let data = Data(payload.readableBytesView)
            guard !data.isEmpty else {
                return
            }
            do {
                try stdin.write(contentsOf: data)
            } catch {
                await failSession(String(describing: error))
            }
        case 4:
            guard state.protocolVersion.supportsResize else {
                return
            }
            let data = Data(payload.readableBytesView)
            do {
                let size = try decodeTerminalSize(data)
                try await state.process.resize(size)
            } catch {
                await failSession(String(describing: error))
            }
        case 255:
            guard state.protocolVersion.supportsCloseSignal else {
                return
            }
            try? state.stdinPipe?.fileHandleForWriting.close()
        default:
            break
        }
    }

    private func handlePortForwardFrame(
        stream: UInt8,
        payload: ByteBuffer,
        state: CRIShimPortForwardState
    ) async {
        guard stream % 2 == 0 else {
            return
        }

        var payload = payload
        guard let forwardedPort = payload.readInteger(endianness: .little, as: UInt16.self) else {
            await failSession("portforward frame missing forwarded port")
            return
        }
        let requestedPort = UInt32(forwardedPort)

        let port: UInt32
        if state.usesDynamicPorts {
            port = requestedPort
        } else {
            guard let configuredPort = state.requestedPort(for: stream) else {
                await failSession("portforward stream \(stream) is out of range")
                return
            }
            guard requestedPort == configuredPort else {
                await failSession("portforward stream \(stream) forwarded port \(forwardedPort) does not match \(configuredPort)")
                return
            }
            port = configuredPort
        }

        let data = Data(payload.readableBytesView)
        switch state.enqueue(stream: stream, port: port, input: data) {
        case .none:
            return
        case .open(let launch):
            startPortForwardTask(owner: launch.identity) { [weak self] in
                await self?.openPortForwardStream(state: state, launch: launch)
            }
        case .startWriter(let launch):
            startPortForwardWriter(state: state, launch: launch)
        case .fail(let failure):
            await failPortForwardStream(state: state, failure: failure)
        case .portMismatch(let existingPort):
            await failSession("portforward stream \(stream) changed port from \(existingPort) to \(port)")
        case .closed:
            try? await sendPortForwardError(
                stream: stream,
                port: port,
                message: "websocket port-forward stream is closed"
            )
        }
    }

    private func openPortForwardStream(
        state: CRIShimPortForwardState,
        launch: CRIShimPortForwardState.OpenLaunch
    ) async {
        var openedHandle: FileHandle?
        var unownedControlConnection: CRIShimBackendControlConnection?
        var unownedWriter: FileHandleByteWriter?
        var unownedTunnelLease: UUID?
        do {
            guard let tunnelLease = server.acquirePortForwardTunnelLease() else {
                await failPortForwardStream(
                    state: state,
                    failure: CRIShimPortForwardState.StreamFailure(
                        identity: launch.identity,
                        port: launch.port,
                        message: "port-forward server active tunnel limit reached"
                    )
                )
                return
            }
            unownedTunnelLease = tunnelLease
            let handle = try await runtimeManager.streamPortForward(
                sandboxID: state.invocation.sandboxID,
                port: launch.port
            )
            openedHandle = handle
            let controlConnection = try CRIShimBackendControlConnection(
                duplicating: handle.fileDescriptor
            )
            unownedControlConnection = controlConnection
            let writer = try FileHandleByteWriter(handle: handle)
            unownedWriter = writer
            let input = try fileHandleStream(
                handle,
                maximumPendingBytes: criShimPortForwardMaximumPendingOutputBytes,
                maximumPendingElements: criShimPortForwardMaximumPendingOutputElements
            )
            let connection = CRIShimPortForwardState.Connection(
                handle: handle,
                controlConnection: controlConnection,
                writer: writer,
                input: input,
                tunnelLease: tunnelLease
            )
            let registration = stateLock.withLock { () -> CRIShimPortForwardState.CommitResult? in
                guard !cleanupPerformed else {
                    return nil
                }
                return state.commitOpening(launch, connection: connection)
            }
            guard let registration else {
                input.cancel()
                controlConnection.shutdownAllAndClose()
                writer.cancel()
                try? handle.close()
                server.releasePortForwardTunnelLease(tunnelLease)
                openedHandle = nil
                unownedControlConnection = nil
                unownedWriter = nil
                unownedTunnelLease = nil
                return
            }
            openedHandle = nil
            unownedControlConnection = nil
            unownedWriter = nil
            unownedTunnelLease = nil
            startPortForwardTask(owner: registration.identity) { [weak self] in
                await self?.pumpPortForward(
                    state: state,
                    identity: registration.identity,
                    port: launch.port,
                    input: input
                )
            }
            if let writer = registration.writer {
                startPortForwardWriter(state: state, launch: writer)
            }
        } catch {
            if let unownedTunnelLease {
                server.releasePortForwardTunnelLease(unownedTunnelLease)
            }
            unownedControlConnection?.shutdownAllAndClose()
            unownedWriter?.cancel()
            try? openedHandle?.close()
            await failPortForwardStream(
                state: state,
                failure: CRIShimPortForwardState.StreamFailure(
                    identity: launch.identity,
                    port: launch.port,
                    message: String(describing: error)
                )
            )
        }
    }

    private func startPortForwardWriter(
        state: CRIShimPortForwardState,
        launch: CRIShimPortForwardState.WriterLaunch
    ) {
        startPortForwardTask(owner: launch.identity) { [weak self] in
            await self?.runPortForwardWriter(state: state, launch: launch)
        }
    }

    private func runPortForwardWriter(
        state: CRIShimPortForwardState,
        launch: CRIShimPortForwardState.WriterLaunch
    ) async {
        var completedBytes = 0
        while true {
            switch state.nextWriterAction(launch, completedBytes: completedBytes) {
            case .stop:
                return
            case .write(let data):
                do {
                    try await launch.writer.write(data)
                    completedBytes = data.count
                } catch {
                    await failPortForwardStream(
                        state: state,
                        failure: CRIShimPortForwardState.StreamFailure(
                            identity: launch.identity,
                            port: launch.port,
                            message: String(describing: error)
                        )
                    )
                    return
                }
            }
        }
    }

    private func pumpExecOutput(
        stream: UInt8,
        input: FileHandleByteStream
    ) async {
        for await data in input.bytes {
            do {
                try await writeBinaryMessage(stream: stream, payload: data)
            } catch {
                await failSession(String(describing: error))
                return
            }
        }
    }

    private func pumpPortForward(
        state: CRIShimPortForwardState,
        identity: CRIShimPortForwardState.StreamIdentity,
        port: UInt32,
        input: FileHandleByteStream
    ) async {
        for await data in input.bytes {
            guard let outputSequence = state.outputSequence(for: identity) else {
                return
            }
            let writeSucceeded = await outputSequence.sendData { [weak self] in
                guard let self else {
                    return false
                }
                do {
                    try await writeBinaryMessage(
                        stream: identity.stream,
                        payload: portPrefix(port: port) + data
                    )
                    return true
                } catch {
                    return false
                }
            }
            guard let writeSucceeded else {
                return
            }
            if writeSucceeded {
                input.acknowledge(data.count)
                continue
            }
            await failSession("websocket port-forward output write failed")
            return
        }
        finishPortForward(state: state, identity: identity)
    }

    private func finishPortForward(
        state: CRIShimPortForwardState,
        identity: CRIShimPortForwardState.StreamIdentity
    ) {
        guard let removal = state.remove(identity) else {
            return
        }
        closePortForwardStream(identity: identity, removal: removal)
    }

    private func failPortForwardStream(
        state: CRIShimPortForwardState,
        failure: CRIShimPortForwardState.StreamFailure
    ) async {
        guard let removal = state.remove(failure.identity) else {
            return
        }
        closePortForwardStream(
            identity: failure.identity,
            removal: removal,
            stopOutput: false
        )
        await removal.outputSequence.sendTerminal { [weak self] in
            try? await self?.sendPortForwardError(
                stream: failure.identity.stream,
                port: failure.port,
                message: failure.message
            )
        }
        removal.outputSequence.stop()
    }

    private func closePortForwardStream(
        identity: CRIShimPortForwardState.StreamIdentity,
        removal: CRIShimPortForwardState.Removal,
        stopOutput: Bool = true
    ) {
        removal.connection?.controlConnection.shutdownAllAndClose()
        removal.connection?.writer.cancel()
        let tasks = takePortForwardTasks(owner: identity)
        for task in tasks {
            task.cancel()
        }
        removal.connection?.input.cancel()
        try? removal.connection?.handle.close()
        if let tunnelLease = removal.connection?.tunnelLease {
            server.releasePortForwardTunnelLease(tunnelLease)
        }
        if stopOutput {
            removal.outputSequence.stop()
        }
    }

    private func finishExecSession(
        protocolVersion: CRIShimExecStreamProtocol,
        exitCode: Int32
    ) async {
        guard beginTerminalClose() else {
            return
        }
        let payload: Data
        if protocolVersion.supportsStructuredExitStatus {
            payload = makeStructuredExecStatus(exitCode: exitCode)
        } else if exitCode == 0 {
            payload = Data()
        } else {
            payload = Data("command terminated with exit code \(exitCode)".utf8)
        }

        await cleanup(killProcess: false)
        if !payload.isEmpty {
            writeBinaryMessageBestEffortAndClose(stream: 3, payload: payload)
        } else if let closePayload = makeWebSocketClosePayload() {
            writeFrameBestEffortAndClose(opcode: .connectionClose, payload: closePayload)
        } else {
            channel?.close(promise: nil)
        }
    }

    private func sendPortForwardError(
        stream: UInt8,
        port: UInt32,
        message: String
    ) async throws {
        try await writeBinaryMessage(stream: stream + 1, payload: portPrefix(port: port) + Data(message.utf8))
    }

    private func failSession(_ message: String) async {
        guard beginTerminalClose() else {
            return
        }
        let execFailureFrame: (stream: UInt8, payload: Data)?
        switch sessionStateSnapshot() {
        case .exec(let state):
            let payload =
                if state.protocolVersion.supportsStructuredExitStatus {
                    makeStructuredExecFailureStatus(message: message)
                } else {
                    Data(message.utf8)
                }
            execFailureFrame = payload.isEmpty ? nil : (3, payload)
        case .portForward, .none:
            execFailureFrame = nil
        }
        await cleanup(killProcess: true)
        if let execFailureFrame {
            writeBinaryMessageBestEffortAndClose(
                stream: execFailureFrame.stream,
                payload: execFailureFrame.payload
            )
        } else {
            channel?.close(promise: nil)
        }
    }

    private func closeWebSocket(killProcess: Bool) async {
        guard beginTerminalClose() else {
            return
        }
        await cleanup(killProcess: killProcess)
        if let closePayload = makeWebSocketClosePayload() {
            writeFrameBestEffortAndClose(opcode: .connectionClose, payload: closePayload)
        } else {
            channel?.close(promise: nil)
        }
    }

    private func cleanup(killProcess: Bool) async {
        let cleanupState = stateLock.withLock {
            () -> (
                backgroundTasks: [Task<Void, Never>],
                portForwardTasks: [Task<Void, Never>],
                pongTask: Task<Void, Never>?,
                sessionState: SessionState?
            )? in
            if cleanupPerformed {
                return nil
            }
            cleanupPerformed = true
            inboundBinaryFrameBytes = 0
            idleTimeoutTask?.cancel()
            idleTimeoutTask = nil
            let cleanupState = (
                backgroundTasks: backgroundTasks,
                portForwardTasks: portForwardTasks.values.compactMap(\.task),
                pongTask: pongTask?.task,
                sessionState: sessionState
            )
            backgroundTasks.removeAll()
            portForwardTasks.removeAll()
            pongTask = nil
            return cleanupState
        }
        guard let cleanupState else {
            return
        }

        inboundBinaryFrameContinuation.finish()

        switch cleanupState.sessionState {
        case .exec(let state):
            for task in cleanupState.backgroundTasks + cleanupState.portForwardTasks
                + [cleanupState.pongTask].compactMap({ $0 })
            {
                task.cancel()
            }
            try? state.stdinPipe?.fileHandleForReading.close()
            try? state.stdinPipe?.fileHandleForWriting.close()
            try? state.stdoutPipe?.fileHandleForReading.close()
            try? state.stdoutPipe?.fileHandleForWriting.close()
            try? state.stderrPipe?.fileHandleForReading.close()
            try? state.stderrPipe?.fileHandleForWriting.close()
            if killProcess {
                try? await state.process.kill(SIGTERM)
            }
        case .portForward(let state):
            let removals = state.takeRemovals()
            for removal in removals {
                removal.connection?.controlConnection.shutdownAllAndClose()
                removal.connection?.writer.cancel()
                removal.outputSequence.stop()
            }
            for task in cleanupState.backgroundTasks + cleanupState.portForwardTasks
                + [cleanupState.pongTask].compactMap({ $0 })
            {
                task.cancel()
            }
            for removal in removals {
                removal.connection?.input.cancel()
                try? removal.connection?.handle.close()
                if let tunnelLease = removal.connection?.tunnelLease {
                    server.releasePortForwardTunnelLease(tunnelLease)
                }
            }
        case .none:
            for task in cleanupState.backgroundTasks + cleanupState.portForwardTasks
                + [cleanupState.pongTask].compactMap({ $0 })
            {
                task.cancel()
            }
        }
    }

    private func appendTask(_ task: Task<Void, Never>) {
        let shouldCancel = stateLock.withLock { () -> Bool in
            guard !cleanupPerformed else {
                return true
            }
            backgroundTasks.append(task)
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func reserveInboundBinaryFrame(
        _ payload: ByteBuffer
    ) -> InboundBinaryFrameAdmission {
        stateLock.withLock {
            guard !cleanupPerformed, !inboundBinaryInputRejected else {
                return .ignored
            }
            let byteCount = payload.readableBytes
            guard
                inboundBinaryFrameBytes <= Self.maximumInboundBinaryFrameBytes,
                byteCount <= Self.maximumInboundBinaryFrameBytes - inboundBinaryFrameBytes
            else {
                inboundBinaryInputRejected = true
                return .reject
            }
            inboundBinaryFrameBytes += byteCount
            return .accepted
        }
    }

    private func terminalCloseSnapshot() -> Bool {
        stateLock.withLock {
            cleanupPerformed || terminalCloseStarted
        }
    }

    private func beginTerminalClose() -> Bool {
        stateLock.withLock {
            guard !cleanupPerformed, !terminalCloseStarted else {
                return false
            }
            terminalCloseStarted = true
            return true
        }
    }

    private func closeSessionSynchronously(context: ChannelHandlerContext) {
        guard beginTerminalClose() else {
            return
        }
        context.close(promise: nil)
    }

    private func startPong(_ payload: ByteBuffer) {
        let trackedTask = TrackedPongTask()
        let shouldStart = stateLock.withLock { () -> Bool in
            guard
                !cleanupPerformed,
                !terminalCloseStarted,
                pongTask == nil
            else {
                return false
            }
            pongTask = trackedTask
            return true
        }
        guard shouldStart else {
            return
        }

        let task = Task { [weak self, weak trackedTask] in
            guard let self, let trackedTask else {
                return
            }
            do {
                try await writeFrame(opcode: .pong, payload: payload)
            } catch {
                if beginTerminalClose() {
                    channel?.close(promise: nil)
                }
            }
            pongFinished(trackedTask)
        }
        let shouldCancel = stateLock.withLock {
            trackedTask.task = task
            return cleanupPerformed || pongTask !== trackedTask
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func pongFinished(_ trackedTask: TrackedPongTask) {
        stateLock.withLock {
            if pongTask === trackedTask {
                pongTask = nil
            }
        }
    }

    private func releaseInboundBinaryFrame(_ payload: ByteBuffer) {
        stateLock.withLock {
            inboundBinaryFrameBytes -= min(inboundBinaryFrameBytes, payload.readableBytes)
        }
    }

    private func rejectInboundBinaryInput(releasing byteCount: Int) -> Bool {
        stateLock.withLock {
            inboundBinaryFrameBytes -= min(inboundBinaryFrameBytes, byteCount)
            guard !cleanupPerformed, !inboundBinaryInputRejected else {
                return false
            }
            inboundBinaryInputRejected = true
            return true
        }
    }

    private func startPortForwardTask(
        owner: CRIShimPortForwardState.StreamIdentity,
        operation: @escaping @Sendable () async -> Void
    ) {
        let id = UUID()
        let trackedTask = PortForwardTrackedTask(owner: owner)
        let shouldStart = stateLock.withLock {
            guard !cleanupPerformed else {
                return false
            }
            portForwardTasks[id] = trackedTask
            return true
        }
        guard shouldStart else {
            return
        }

        let task = Task { [weak self] in
            await operation()
            self?.portForwardTaskFinished(id)
        }
        let shouldCancel = stateLock.withLock {
            trackedTask.task = task
            return cleanupPerformed || portForwardTasks[id] !== trackedTask
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func takePortForwardTasks(
        owner: CRIShimPortForwardState.StreamIdentity
    ) -> [Task<Void, Never>] {
        stateLock.withLock {
            let taskIDs = portForwardTasks.compactMap { id, trackedTask in
                trackedTask.owner == owner ? id : nil
            }
            return taskIDs.compactMap { id in
                portForwardTasks.removeValue(forKey: id)?.task
            }
        }
    }

    private func portForwardTaskFinished(_ id: UUID) {
        _ = stateLock.withLock {
            portForwardTasks.removeValue(forKey: id)
        }
    }

    private func sessionStateSnapshot() -> SessionState? {
        stateLock.withLock {
            sessionState
        }
    }

    private func recordActivity() {
        guard let idleTimeout, let channel else {
            return
        }

        let scheduled = channel.eventLoop.scheduleTask(in: idleTimeout) { [weak self] in
            guard let self else {
                return
            }
            Task {
                await self.failSession("streaming session timed out due to inactivity")
            }
        }

        let staleTask = stateLock.withLock { () -> Scheduled<Void>? in
            guard !cleanupPerformed else {
                scheduled.cancel()
                return nil
            }
            let previous = idleTimeoutTask
            idleTimeoutTask = scheduled
            return previous
        }
        staleTask?.cancel()
    }

    private func writeBinaryMessage(
        stream: UInt8,
        payload: Data
    ) async throws {
        guard !terminalCloseSnapshot() else {
            throw CancellationError()
        }
        guard let buffer = makeFramePayload(stream: stream, payload: payload) else {
            return
        }
        try await writeFrame(opcode: .binary, payload: buffer)
        recordActivity()
    }

    private func writeBinaryMessageBestEffortAndClose(
        stream: UInt8,
        payload: Data
    ) {
        guard let buffer = makeFramePayload(stream: stream, payload: payload) else {
            channel?.close(promise: nil)
            return
        }
        writeFrameBestEffortAndClose(opcode: .binary, payload: buffer)
    }

    private func writeFrameBestEffortAndClose(
        opcode: WebSocketOpcode,
        payload: ByteBuffer
    ) {
        guard let channel, channel.isActive, channel.isWritable else {
            channel?.close(promise: nil)
            return
        }
        let frame = WebSocketFrame(
            fin: true,
            opcode: opcode,
            maskKey: nil,
            data: payload
        )
        let closeTimeout = channel.eventLoop.scheduleTask(in: .milliseconds(100)) {
            channel.close(promise: nil)
        }
        let writeFuture: EventLoopFuture<Void> = channel.writeAndFlush(frame)
        writeFuture.whenComplete { _ in
            closeTimeout.cancel()
            channel.close(promise: nil)
        }
    }

    private func writeFrame(
        opcode: WebSocketOpcode,
        payload: ByteBuffer
    ) async throws {
        guard let channel else {
            return
        }
        let frame = WebSocketFrame(
            fin: true,
            opcode: opcode,
            maskKey: nil,
            data: payload
        )
        try await channel.writeAndFlush(frame).get()
    }

    private func makeFramePayload(
        stream: UInt8,
        payload: Data
    ) -> ByteBuffer? {
        guard let channel else {
            return nil
        }
        var buffer = channel.allocator.buffer(capacity: payload.count + 1)
        buffer.writeInteger(stream)
        buffer.writeBytes(payload)
        return buffer
    }

    private func makeWebSocketClosePayload() -> ByteBuffer? {
        guard let channel else {
            return nil
        }
        var buffer = channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: .normalClosure)
        return buffer
    }

}

private func websocketProtocols(from headers: HTTPHeaders) -> [String] {
    headers["Sec-WebSocket-Protocol"]
        .flatMap { value in
            value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
}

private func spdyStreamProtocols(from headers: HTTPHeaders) -> [String] {
    headers[criShimSPDYStreamProtocolHeader]
        .flatMap { value in
            value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
}

private func streamKind(_ value: String) -> CRIShimPortForwardSPDYHandler.StreamKind? {
    switch value {
    case "data":
        .data
    case "error":
        .error
    default:
        nil
    }
}

private func execStreamKind(_ value: String) -> CRIShimExecSPDYHandler.StreamKind? {
    switch value {
    case "error":
        .error
    case "stdin":
        .stdin
    case "stdout":
        .stdout
    case "stderr":
        .stderr
    case "resize":
        .resize
    default:
        nil
    }
}

private func fallbackRequestID(
    streamID: UInt32,
    kind: CRIShimPortForwardSPDYHandler.StreamKind
) -> String? {
    switch kind {
    case .error:
        guard streamID > 0 else {
            return nil
        }
        return "\(streamID)"
    case .data:
        guard streamID >= 3 else {
            return nil
        }
        return "\(streamID - 2)"
    }
}

final class CRIShimBackendControlConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptor: Int32?

    init(duplicating fileDescriptor: Int32) throws {
        let duplicatedFileDescriptor = Darwin.fcntl(fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicatedFileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.fileDescriptor = duplicatedFileDescriptor
        configureBackendSocketNoSIGPIPE(duplicatedFileDescriptor)
    }

    init(owning fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        configureBackendSocketNoSIGPIPE(fileDescriptor)
    }

    deinit {
        shutdownAllAndClose()
    }

    func shutdownWrite() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let fileDescriptor else {
            return
        }
        guard Darwin.shutdown(fileDescriptor, SHUT_WR) != 0 else {
            return
        }
        let code = errno
        if code == ENOTCONN || code == EPIPE {
            return
        }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    func shutdownAllAndClose() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileDescriptor else {
            return
        }
        self.fileDescriptor = nil
        _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        _ = Darwin.close(fileDescriptor)
    }
}

private func configureBackendSocketNoSIGPIPE(_ fileDescriptor: Int32) {
    #if !os(Linux)
    var noSignal = CInt(1)
    _ = setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<CInt>.size)
    )
    #endif
}

private func writeSPDYLength(
    flags: UInt8,
    length: Int,
    to buffer: inout ByteBuffer
) {
    let boundedLength = UInt32(length & 0x00FF_FFFF)
    buffer.writeInteger(flags)
    buffer.writeInteger(UInt8((boundedLength >> 16) & 0xFF))
    buffer.writeInteger(UInt8((boundedLength >> 8) & 0xFF))
    buffer.writeInteger(UInt8(boundedLength & 0xFF))
}

private func spdyUInt32(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
}

private func readSPDYUInt32(
    _ data: Data,
    _ offset: inout Int
) throws -> UInt32 {
    guard offset + 4 <= data.count else {
        throw CRIShimError.invalidArgument("SPDY header block is truncated")
    }
    let value =
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    offset += 4
    return value
}

private func parseSPDYHeaders(_ data: Data) throws -> [String: [String]] {
    let maximumHeaderCount: UInt32 = 256
    let maximumHeaderNameBytes = 8 * 1024
    let maximumHeaderValueBytes = 32 * 1024
    var offset = 0
    let headerCount = try readSPDYUInt32(data, &offset)
    guard headerCount <= maximumHeaderCount else {
        throw CRIShimError.invalidArgument("SPDY header count exceeds \(maximumHeaderCount)")
    }
    var headers: [String: [String]] = [:]
    for _ in 0..<headerCount {
        let nameLength = Int(try readSPDYUInt32(data, &offset))
        guard nameLength <= maximumHeaderNameBytes else {
            throw CRIShimError.invalidArgument("SPDY header name exceeds \(maximumHeaderNameBytes) bytes")
        }
        guard nameLength <= data.count - offset else {
            throw CRIShimError.invalidArgument("SPDY header name is truncated")
        }
        let name = String(decoding: data[offset..<(offset + nameLength)], as: UTF8.self).lowercased()
        offset += nameLength

        let valueLength = Int(try readSPDYUInt32(data, &offset))
        guard valueLength <= maximumHeaderValueBytes else {
            throw CRIShimError.invalidArgument("SPDY header value exceeds \(maximumHeaderValueBytes) bytes")
        }
        guard valueLength <= data.count - offset else {
            throw CRIShimError.invalidArgument("SPDY header value is truncated")
        }
        let value = String(decoding: data[offset..<(offset + valueLength)], as: UTF8.self)
        offset += valueLength
        headers[name] = value.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }
    return headers
}

func makeSPDYHeaderBlock(_ headers: [String: [String]]) -> Data {
    var data = Data(spdyUInt32(UInt32(headers.count)))
    for (name, values) in headers.sorted(by: { $0.key < $1.key }) {
        let normalizedName = Data(name.lowercased().utf8)
        let value = Data(values.joined(separator: "\0").utf8)
        data.append(contentsOf: spdyUInt32(UInt32(normalizedName.count)))
        data.append(normalizedName)
        data.append(contentsOf: spdyUInt32(UInt32(value.count)))
        data.append(value)
    }
    return data
}

final class CRIShimSPDYHeaderInflater {
    private static let maximumDecompressedHeaderBytes = 64 * 1024

    private var stream = z_stream()
    private var initialized = false

    init() throws {
        let result = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else {
            throw CRIShimError.internalError("failed to initialize SPDY header inflater: \(result)")
        }
        initialized = true
    }

    deinit {
        if initialized {
            inflateEnd(&stream)
        }
    }

    func decompress(_ data: Data) throws -> Data {
        var output = Data()
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let produced = chunk.withUnsafeMutableBufferPointer { pointer in
                    stream.next_out = pointer.baseAddress
                    stream.avail_out = uInt(pointer.count)
                    var result = inflate(&stream, Z_SYNC_FLUSH)
                    if result == Z_NEED_DICT {
                        result = setInflateDictionary()
                        if result == Z_OK {
                            result = inflate(&stream, Z_SYNC_FLUSH)
                        }
                    }
                    return (pointer.count - Int(stream.avail_out), result)
                }
                if produced.0 > 0 {
                    guard
                        output.count <= Self.maximumDecompressedHeaderBytes,
                        produced.0 <= Self.maximumDecompressedHeaderBytes - output.count
                    else {
                        throw CRIShimError.invalidArgument(
                            "SPDY decompressed header block exceeds \(Self.maximumDecompressedHeaderBytes) bytes"
                        )
                    }
                    output.append(contentsOf: chunk.prefix(produced.0))
                }
                guard produced.1 == Z_OK || produced.1 == Z_STREAM_END || produced.1 == Z_BUF_ERROR else {
                    throw CRIShimError.invalidArgument("failed to inflate SPDY headers: \(produced.1)")
                }
                if produced.1 == Z_STREAM_END {
                    break
                }
                if produced.0 == 0 && stream.avail_in == 0 {
                    break
                }
            } while stream.avail_in > 0
        }
        return output
    }

    private func setInflateDictionary() -> Int32 {
        spdyHeaderDictionaryBytes.withUnsafeBytes { dictionary in
            inflateSetDictionary(
                &stream,
                dictionary.bindMemory(to: Bytef.self).baseAddress,
                uInt(spdyHeaderDictionaryBytes.count)
            )
        }
    }
}

final class CRIShimSPDYHeaderDeflater {
    private var stream = z_stream()
    private var initialized = false

    init() throws {
        let result = deflateInit_(&stream, Z_BEST_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else {
            throw CRIShimError.internalError("failed to initialize SPDY header deflater: \(result)")
        }
        let dictionaryResult = setDeflateDictionary()
        guard dictionaryResult == Z_OK else {
            throw CRIShimError.internalError("failed to configure SPDY header deflater dictionary: \(dictionaryResult)")
        }
        initialized = true
    }

    deinit {
        if initialized {
            deflateEnd(&stream)
        }
    }

    func compress(_ data: Data) throws -> Data {
        var output = Data()
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let produced = chunk.withUnsafeMutableBufferPointer { pointer in
                    stream.next_out = pointer.baseAddress
                    stream.avail_out = uInt(pointer.count)
                    let result = deflate(&stream, Z_SYNC_FLUSH)
                    return (pointer.count - Int(stream.avail_out), result)
                }
                if produced.0 > 0 {
                    output.append(contentsOf: chunk.prefix(produced.0))
                }
                guard produced.1 == Z_OK else {
                    throw CRIShimError.internalError("failed to deflate SPDY headers: \(produced.1)")
                }
                if produced.0 == 0 && stream.avail_in == 0 {
                    break
                }
            } while stream.avail_in > 0
        }
        return output
    }

    private func setDeflateDictionary() -> Int32 {
        spdyHeaderDictionaryBytes.withUnsafeBytes { dictionary in
            deflateSetDictionary(
                &stream,
                dictionary.bindMemory(to: Bytef.self).baseAddress,
                uInt(spdyHeaderDictionaryBytes.count)
            )
        }
    }
}

private let spdyHeaderDictionaryBytes = Data(
    base64Encoded: """
        AAAAB29wdGlvbnMAAAAEaGVhZAAAAARwb3N0AAAAA3B1dAAAAAZkZWxldGUAAAAFdHJhY2UAAAAGYWNjZXB0AAAADmFjY2VwdC1j
        aGFyc2V0AAAAD2FjY2VwdC1lbmNvZGluZwAAAA9hY2NlcHQtbGFuZ3VhZ2UAAAANYWNjZXB0LXJhbmdlcwAAAANhZ2UAAAAFYWxs
        b3cAAAANYXV0aG9yaXphdGlvbgAAAA1jYWNoZS1jb250cm9sAAAACmNvbm5lY3Rpb24AAAAMY29udGVudC1iYXNlAAAAEGNvbnRl
        bnQtZW5jb2RpbmcAAAAQY29udGVudC1sYW5ndWFnZQAAAA5jb250ZW50LWxlbmd0aAAAABBjb250ZW50LWxvY2F0aW9uAAAAC2Nv
        bnRlbnQtbWQ1AAAADWNvbnRlbnQtcmFuZ2UAAAAMY29udGVudC10eXBlAAAABGRhdGUAAAAEZXRhZwAAAAZleHBlY3QAAAAHZXhw
        aXJlcwAAAARmcm9tAAAABGhvc3QAAAAIaWYtbWF0Y2gAAAARaWYtbW9kaWZpZWQtc2luY2UAAAANaWYtbm9uZS1tYXRjaAAAAAhp
        Zi1yYW5nZQAAABNpZi11bm1vZGlmaWVkLXNpbmNlAAAADWxhc3QtbW9kaWZpZWQAAAAIbG9jYXRpb24AAAAMbWF4LWZvcndhcmRz
        AAAABnByYWdtYQAAABJwcm94eS1hdXRoZW50aWNhdGUAAAATcHJveHktYXV0aG9yaXphdGlvbgAAAAVyYW5nZQAAAAdyZWZlcmVy
        AAAAC3JldHJ5LWFmdGVyAAAABnNlcnZlcgAAAAJ0ZQAAAAd0cmFpbGVyAAAAEXRyYW5zZmVyLWVuY29kaW5nAAAAB3VwZ3JhZGUA
        AAAKdXNlci1hZ2VudAAAAAR2YXJ5AAAAA3ZpYQAAAAd3YXJuaW5nAAAAEHd3dy1hdXRoZW50aWNhdGUAAAAGbWV0aG9kAAAAA2dl
        dAAAAAZzdGF0dXMAAAAGMjAwIE9LAAAAB3ZlcnNpb24AAAAISFRUUC8xLjEAAAADdXJsAAAABnB1YmxpYwAAAApzZXQtY29va2ll
        AAAACmtlZXAtYWxpdmUAAAAGb3JpZ2luMTAwMTAxMjAxMjAyMjA1MjA2MzAwMzAyMzAzMzA0MzA1MzA2MzA3NDAyNDA1NDA2NDA3
        NDA4NDA5NDEwNDExNDEyNDEzNDE0NDE1NDE2NDE3NTAyNTA0NTA1MjAzIE5vbi1BdXRob3JpdGF0aXZlIEluZm9ybWF0aW9uMjA0
        IE5vIENvbnRlbnQzMDEgTW92ZWQgUGVybWFuZW50bHk0MDAgQmFkIFJlcXVlc3Q0MDEgVW5hdXRob3JpemVkNDAzIEZvcmJpZGRl
        bjQwNCBOb3QgRm91bmQ1MDAgSW50ZXJuYWwgU2VydmVyIEVycm9yNTAxIE5vdCBJbXBsZW1lbnRlZDUwMyBTZXJ2aWNlIFVuYXZh
        aWxhYmxlSmFuIEZlYiBNYXIgQXByIE1heSBKdW4gSnVsIEF1ZyBTZXB0IE9jdCBOb3YgRGVjIDAwOjAwOjAwIE1vbiwgVHVlLCBX
        ZWQsIFRodSwgRnJpLCBTYXQsIFN1biwgR01UY2h1bmtlZCx0ZXh0L2h0bWwsaW1hZ2UvcG5nLGltYWdlL2pwZyxpbWFnZS9naWYs
        YXBwbGljYXRpb24veG1sLGFwcGxpY2F0aW9uL3hodG1sK3htbCx0ZXh0L3BsYWluLHRleHQvamF2YXNjcmlwdCxwdWJsaWNwcml2
        YXRlbWF4LWFnZT1nemlwLGRlZmxhdGUsc2RjaGNoYXJzZXQ9dXRmLThjaGFyc2V0PWlzby04ODU5LTEsdXRmLSwqLGVucT0wLg==
        """,
    options: .ignoreUnknownCharacters
)!

private func parseStreamingPath(_ uri: String) throws -> CRIShimStreamingPath {
    let path = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? uri
    let components = path.split(separator: "/").map(String.init)
    guard components.count == 2 else {
        throw CRIShimStreamingHTTPError(status: .notFound, message: "not found")
    }
    guard let route = CRIShimStreamingRoute(rawValue: components[0]) else {
        throw CRIShimStreamingHTTPError(status: .notFound, message: "not found")
    }
    guard !components[1].isEmpty else {
        throw CRIShimStreamingHTTPError(status: .notFound, message: "not found")
    }
    return CRIShimStreamingPath(route: route, token: components[1])
}

private func makeBaseURL(host: String, port: Int) throws -> URL {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = port
    guard let url = components.url else {
        throw CRIShimError.internalError("failed to construct streaming base URL")
    }
    return url
}

private func isLoopbackHost(_ host: String) -> Bool {
    switch host.lowercased() {
    case "127.0.0.1", "::1", "localhost":
        true
    default:
        false
    }
}

final class FileHandleByteWriter: @unchecked Sendable {
    private final class PendingWrite: @unchecked Sendable {
        let data: Data
        var offset = 0
        let continuation: CheckedContinuation<Void, any Error>

        init(
            data: Data,
            continuation: CheckedContinuation<Void, any Error>
        ) {
            self.data = data
            self.continuation = continuation
        }
    }

    private enum DrainAction {
        case stop
        case retry
        case wait
        case complete(CheckedContinuation<Void, any Error>)
        case fail(CheckedContinuation<Void, any Error>, any Error)
    }

    private enum WriterError: Error {
        case closed
        case concurrentWrite
    }

    private static let workerQueue = DispatchQueue(
        label: "com.apple.container.cri-shim.streaming-write",
        attributes: .concurrent
    )

    private let fileDescriptor: Int32
    private let source: DispatchSourceWrite
    private let lock = NSLock()
    private var pendingWrite: PendingWrite?
    private var sourceSuspended = true
    private var stopped = false

    init(handle: FileHandle) throws {
        let duplicate = Darwin.fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw CRIShimError.internalError("failed to duplicate streaming write descriptor: errno \(errno)")
        }

        let flags = Darwin.fcntl(duplicate, F_GETFL)
        guard flags >= 0, Darwin.fcntl(duplicate, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            _ = Darwin.close(duplicate)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        configureBackendSocketNoSIGPIPE(duplicate)

        let queue = DispatchQueue(
            label: "com.apple.container.cri-shim.streaming-write.\(UUID().uuidString)",
            target: Self.workerQueue
        )
        self.fileDescriptor = duplicate
        self.source = DispatchSource.makeWriteSource(
            fileDescriptor: duplicate,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.writeAvailableData()
        }
        source.setCancelHandler { [fileDescriptor] in
            _ = Darwin.close(fileDescriptor)
        }
    }

    deinit {
        cancel()
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let failure = lock.withLock { () -> (any Error)? in
                    guard !stopped else {
                        return WriterError.closed
                    }
                    guard pendingWrite == nil else {
                        return WriterError.concurrentWrite
                    }
                    pendingWrite = PendingWrite(data: data, continuation: continuation)
                    if sourceSuspended {
                        sourceSuspended = false
                        source.resume()
                    }
                    return nil
                }
                if let failure {
                    continuation.resume(throwing: failure)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let continuation = lock.withLock {
            () -> CheckedContinuation<Void, any Error>? in
            guard !stopped else {
                return nil
            }
            stopped = true
            let continuation = pendingWrite?.continuation
            pendingWrite = nil
            if sourceSuspended {
                sourceSuspended = false
                source.resume()
            }
            source.setEventHandler {}
            source.cancel()
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func writeAvailableData() {
        while true {
            let action = lock.withLock { () -> DrainAction in
                guard !stopped, let pendingWrite else {
                    return .stop
                }
                let result = pendingWrite.data.withUnsafeBytes { buffer in
                    Darwin.write(
                        fileDescriptor,
                        buffer.baseAddress?.advanced(by: pendingWrite.offset),
                        buffer.count - pendingWrite.offset
                    )
                }
                let code = result < 0 ? errno : EIO
                if result > 0 {
                    pendingWrite.offset += result
                    guard pendingWrite.offset == pendingWrite.data.count else {
                        return .retry
                    }
                    self.pendingWrite = nil
                    sourceSuspended = true
                    source.suspend()
                    return .complete(pendingWrite.continuation)
                }
                if result < 0, code == EINTR {
                    return .retry
                }
                if result < 0, code == EAGAIN || code == EWOULDBLOCK {
                    return .wait
                }

                self.pendingWrite = nil
                stopped = true
                source.setEventHandler {}
                source.cancel()
                return .fail(
                    pendingWrite.continuation,
                    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                )
            }

            switch action {
            case .stop, .wait:
                return
            case .retry:
                continue
            case .complete(let continuation):
                continuation.resume()
                return
            case .fail(let continuation, let error):
                continuation.resume(throwing: error)
                return
            }
        }
    }
}

final class FileHandleByteStream: @unchecked Sendable {
    private static let maximumReadSize = 64 * 1024
    private static let workerQueue = DispatchQueue(
        label: "com.apple.container.cri-shim.streaming-read",
        attributes: .concurrent
    )

    private let fileDescriptor: Int32
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private let maximumPendingBytes: Int?
    private let maximumPendingElements: Int?
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var pendingBytes = 0
    private var pendingElements = 0
    private var sourceSuspended = false
    private var sourceResumeScheduled = false
    private var stopped = false
    let bytes: AsyncStream<Data>

    init(
        handle: FileHandle,
        maximumPendingBytes: Int? = nil,
        maximumPendingElements: Int? = nil
    ) throws {
        let duplicate = Darwin.fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw CRIShimError.internalError("failed to duplicate streaming file descriptor: errno \(errno)")
        }

        let queue = DispatchQueue(
            label: "com.apple.container.cri-shim.streaming-read.\(UUID().uuidString)",
            target: Self.workerQueue
        )
        self.maximumPendingBytes = maximumPendingBytes.map { max($0, 1) }
        self.maximumPendingElements = maximumPendingElements.map { max($0, 1) }
        var capturedContinuation: AsyncStream<Data>.Continuation?
        self.bytes = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.fileDescriptor = duplicate
        self.queue = queue
        self.continuation = capturedContinuation
        self.source = DispatchSource.makeReadSource(
            fileDescriptor: duplicate,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        source.setCancelHandler { [fileDescriptor] in
            _ = Darwin.close(fileDescriptor)
        }
        continuation?.onTermination = { [weak self] _ in
            self?.stop()
        }
        source.resume()
    }

    deinit {
        stop()
    }

    func cancel() {
        stop()
    }

    var pendingByteCount: Int {
        lock.withLock { pendingBytes }
    }

    var pendingElementCount: Int {
        lock.withLock { pendingElements }
    }

    func acknowledge(_ byteCount: Int) {
        guard byteCount > 0 else {
            return
        }
        let shouldScheduleResume = lock.withLock {
            guard
                !stopped,
                maximumPendingBytes != nil || maximumPendingElements != nil
            else {
                return false
            }
            assert(pendingBytes >= byteCount)
            assert(pendingElements > 0)
            pendingBytes -= min(pendingBytes, byteCount)
            pendingElements -= 1
            if sourceSuspended, !sourceResumeScheduled {
                sourceResumeScheduled = true
                return true
            }
            return false
        }
        if shouldScheduleResume {
            queue.async { [weak self] in
                self?.resumeSourceAfterAcknowledgement()
            }
        }
    }

    private func resumeSourceAfterAcknowledgement() {
        lock.withLock {
            guard !stopped, sourceSuspended, sourceResumeScheduled else {
                sourceResumeScheduled = false
                return
            }
            sourceResumeScheduled = false
            sourceSuspended = false
            source.resume()
        }
    }

    private func readAvailableData() {
        let estimatedSize = source.data
        guard estimatedSize > 0 else {
            stop()
            return
        }
        let readSize = lock.withLock { () -> Int in
            guard !stopped else {
                return 0
            }
            let estimatedReadSize = Int(min(estimatedSize, UInt(Self.maximumReadSize)))
            if let maximumPendingElements, pendingElements >= maximumPendingElements {
                return 0
            }
            guard let maximumPendingBytes else {
                return estimatedReadSize
            }
            return min(estimatedReadSize, max(maximumPendingBytes - pendingBytes, 0))
        }
        guard readSize > 0 else {
            return
        }
        var bytes = [UInt8](repeating: 0, count: readSize)

        while true {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if result > 0 {
                let data = Data(bytes.prefix(Int(result)))
                let continuation: AsyncStream<Data>.Continuation? = lock.withLock {
                    guard !stopped else {
                        return nil
                    }
                    if maximumPendingBytes != nil || maximumPendingElements != nil {
                        pendingBytes += data.count
                        pendingElements += 1
                        let reachedByteLimit = maximumPendingBytes.map { pendingBytes >= $0 } ?? false
                        let reachedElementLimit = maximumPendingElements.map { pendingElements >= $0 } ?? false
                        if reachedByteLimit || reachedElementLimit, !sourceSuspended {
                            sourceSuspended = true
                            source.suspend()
                        }
                    }
                    return self.continuation
                }
                guard let continuation else {
                    return
                }
                if case .terminated = continuation.yield(data) {
                    stop()
                }
                return
            }
            if result == 0 {
                stop()
                return
            }

            let readError = errno
            if readError == EINTR {
                continue
            }
            if readError == EAGAIN || readError == EWOULDBLOCK {
                return
            }
            stop()
            return
        }
    }

    private func stop() {
        let continuation = lock.withLock { () -> AsyncStream<Data>.Continuation? in
            guard !stopped else {
                return nil
            }
            stopped = true
            pendingBytes = 0
            pendingElements = 0
            sourceResumeScheduled = false
            if sourceSuspended {
                sourceSuspended = false
                source.resume()
            }
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else {
            return
        }

        continuation.onTermination = nil
        source.setEventHandler {}
        source.cancel()
        continuation.finish()
    }
}

func fileHandleStream(
    _ handle: FileHandle,
    maximumPendingBytes: Int? = nil,
    maximumPendingElements: Int? = nil
) throws -> FileHandleByteStream {
    try FileHandleByteStream(
        handle: handle,
        maximumPendingBytes: maximumPendingBytes,
        maximumPendingElements: maximumPendingElements
    )
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func decodeTerminalSize(_ data: Data) throws -> CRIShimTerminalSize {
    guard
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw CRIShimError.invalidArgument("resize payload must be a JSON object")
    }

    func decode(_ keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }

    guard let width = decode(["Width", "width"]), width > 0 else {
        throw CRIShimError.invalidArgument("resize payload width must be greater than zero")
    }
    guard let height = decode(["Height", "height"]), height > 0 else {
        throw CRIShimError.invalidArgument("resize payload height must be greater than zero")
    }
    return CRIShimTerminalSize(width: width, height: height)
}

private func makeStructuredExecStatus(exitCode: Int32) -> Data {
    if exitCode == 0 {
        return try! JSONSerialization.data(
            withJSONObject: [
                "kind": "Status",
                "apiVersion": "v1",
                "status": "Success",
            ]
        )
    }

    return try! JSONSerialization.data(
        withJSONObject: [
            "kind": "Status",
            "apiVersion": "v1",
            "status": "Failure",
            "message": "command terminated with exit code \(exitCode)",
            "reason": "NonZeroExitCode",
            "details": [
                "causes": [
                    [
                        "reason": "ExitCode",
                        "message": "\(exitCode)",
                    ]
                ]
            ],
        ]
    )
}

private func makeStructuredExecFailureStatus(message: String) -> Data {
    try! JSONSerialization.data(
        withJSONObject: [
            "kind": "Status",
            "apiVersion": "v1",
            "status": "Failure",
            "message": message,
        ]
    )
}

private func portPrefix(port: UInt32) -> Data {
    let narrowedPort = UInt16(truncatingIfNeeded: port)
    return Data(
        [
            UInt8(truncatingIfNeeded: narrowedPort & 0x00FF),
            UInt8(truncatingIfNeeded: (narrowedPort & 0xFF00) >> 8),
        ]
    )
}
