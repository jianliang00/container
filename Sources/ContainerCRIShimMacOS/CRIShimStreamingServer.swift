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

private struct CRIShimPreparedWebSocketUpgrade {
    var subprotocol: String
    var handler: CRIShimStreamingWebSocketHandler
}

private struct CRIShimPreparedSPDYUpgrade {
    var protocolVersion: String
    var handler: CRIShimPortForwardSPDYHandler
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

public final class CRIShimStreamingServer: @unchecked Sendable {
    private let config: CRIShimConfig
    private let runtimeManager: any CRIShimRuntimeManaging
    private let sessionStore: CRIShimStreamingSessionStore
    private let activeSessionIdleTimeout: TimeAmount?
    private let websocketMaxFrameSize: Int
    private let stateLock = NSLock()
    private var serverChannel: Channel?
    private var activeChannels: [ObjectIdentifier: Channel] = [:]
    private var baseURL: URL?

    public init(
        config: CRIShimConfig,
        runtimeManager: any CRIShimRuntimeManaging,
        sessionTimeoutSeconds: TimeInterval = 30,
        activeSessionIdleTimeoutSeconds: TimeInterval = 300,
        websocketMaxFrameSize: Int = 1 << 20
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
        guard path.route == .portForward else {
            throw CRIShimStreamingHTTPError(status: .badRequest, message: "SPDY upgrade is only supported for port-forward")
        }
        guard let preview = await sessionStore.peek(token: path.token) else {
            throw CRIShimStreamingHTTPError(status: .notFound, message: "stream token not found")
        }
        guard case .portForward(let invocation) = preview else {
            throw CRIShimStreamingHTTPError(status: .badRequest, message: "SPDY upgrade is only supported for port-forward")
        }

        let offeredProtocols = spdyStreamProtocols(from: requestHead.headers)
        guard offeredProtocols.contains(criShimPortForwardProtocol) else {
            throw CRIShimStreamingHTTPError(
                status: .badRequest,
                message: "\(criShimSPDYStreamProtocolHeader) must include \(criShimPortForwardProtocol)"
            )
        }

        guard let session = await sessionStore.consume(token: path.token) else {
            throw CRIShimStreamingHTTPError(status: .notFound, message: "stream token not found")
        }
        guard case .portForward = session else {
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
            handler: handler
        )
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
        return channel.pipeline.removeHandler(self).flatMap {
            channel.pipeline.addHandler(
                NIOWebSocketFrameAggregator(
                    minNonFinalFragmentSize: 1,
                    maxAccumulatedFrameCount: 64,
                    maxAccumulatedFrameSize: self.websocketMaxFrameSize
                )
            ).flatMap {
                channel.pipeline.addHandler(preparedUpgrade.handler)
            }
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
        let removeRequestHandler: EventLoopFuture<Void>
        if let requestHandler {
            removeRequestHandler = context.pipeline.removeHandler(requestHandler)
        } else {
            removeRequestHandler = context.eventLoop.makeSucceededFuture(())
        }
        return removeRequestHandler.flatMap {
            context.pipeline.addHandler(preparedUpgrade.handler)
        }
    }
}

private final class CRIShimPortForwardSPDYHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    fileprivate enum StreamKind {
        case data
        case error
    }

    private struct Stream {
        var id: UInt32
        var requestID: String
        var port: UInt32
        var kind: StreamKind
    }

    private struct Pair {
        var dataStreamID: UInt32?
        var errorStreamID: UInt32?
        var port: UInt32?
        var handle: FileHandle?
    }

    private let server: CRIShimStreamingServer
    private let runtimeManager: any CRIShimRuntimeManaging
    private let invocation: CRIShimPortForwardInvocation
    private let idleTimeout: TimeAmount?
    private let lock = NSLock()
    private var channel: Channel?
    private var inboundBuffer: ByteBuffer?
    private var streams: [UInt32: Stream] = [:]
    private var pairs: [String: Pair] = [:]
    private var tasks: [Task<Void, Never>] = []
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
        var incoming = unwrapInboundIn(data)
        inboundBuffer?.writeBuffer(&incoming)
        recordActivity()
        do {
            try parseAvailableFrames()
        } catch {
            Task {
                await failSession(String(describing: error))
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
            Task {
                await cleanup()
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
            let streamID = payload.readInteger(endianness: .big, as: UInt32.self),
            payload.readInteger(endianness: .big, as: UInt32.self) != nil,
            payload.readInteger(endianness: .big, as: UInt8.self) != nil,
            payload.readInteger(endianness: .big, as: UInt8.self) != nil
        else {
            throw CRIShimError.invalidArgument("SPDY SYN_STREAM payload is truncated")
        }

        let headerData = Data(payload.readableBytesView)
        let headers = try parseSPDYHeaders(try inflater.decompress(headerData))
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

        let requestID = headers["requestid"]?.first ?? fallbackRequestID(streamID: streamID, kind: kind)
        let stream = Stream(id: streamID, requestID: requestID, port: port, kind: kind)
        lock.withLock {
            streams[streamID] = stream
            var pair = pairs[requestID] ?? Pair()
            pair.port = pair.port ?? port
            switch kind {
            case .data:
                pair.dataStreamID = streamID
            case .error:
                pair.errorStreamID = streamID
            }
            pairs[requestID] = pair
        }

        try writeSynReplyFrame(streamID: streamID)

        if kind == .data {
            startPortForwardIfNeeded(requestID: requestID, port: port, dataStreamID: streamID)
        }

        if (flags & 0x01) != 0 {
            handleStreamFinished(streamID)
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
        let stream = lock.withLock { streams[streamID] }
        if case .data? = stream?.kind, !data.isEmpty {
            let handle = lock.withLock { pairs[stream!.requestID]?.handle }
            do {
                try handle?.write(contentsOf: data)
            } catch {
                Task {
                    await failSession(String(describing: error))
                }
            }
        }

        if (flags & 0x01) != 0 {
            handleStreamFinished(streamID)
        }
    }

    private func startPortForwardIfNeeded(
        requestID: String,
        port: UInt32,
        dataStreamID: UInt32
    ) {
        let shouldStart = lock.withLock { () -> Bool in
            var pair = pairs[requestID] ?? Pair()
            if pair.handle != nil {
                return false
            }
            pair.port = port
            pair.dataStreamID = dataStreamID
            pairs[requestID] = pair
            return true
        }
        guard shouldStart else {
            return
        }

        let task = Task {
            do {
                let handle = try await runtimeManager.streamPortForward(sandboxID: invocation.sandboxID, port: port)
                lock.withLock {
                    var pair = pairs[requestID] ?? Pair()
                    pair.port = port
                    pair.dataStreamID = dataStreamID
                    pair.handle = handle
                    pairs[requestID] = pair
                }
                await pumpPortForward(requestID: requestID, dataStreamID: dataStreamID, handle: handle)
            } catch {
                await sendPortForwardError(requestID: requestID, message: String(describing: error))
            }
        }
        appendTask(task)
    }

    private func pumpPortForward(
        requestID: String,
        dataStreamID: UInt32,
        handle: FileHandle
    ) async {
        for await data in fileHandleStream(handle) {
            do {
                try await writeDataFrame(streamID: dataStreamID, data: data)
                recordActivity()
            } catch {
                await failSession(String(describing: error))
                return
            }
        }
        try? await writeDataFrame(streamID: dataStreamID, data: Data(), flags: 0x01)
        finishPair(requestID: requestID)
    }

    private func sendPortForwardError(
        requestID: String,
        message: String
    ) async {
        let errorStreamID = lock.withLock { pairs[requestID]?.errorStreamID }
        guard let errorStreamID else {
            return
        }
        try? await writeDataFrame(streamID: errorStreamID, data: Data(message.utf8), flags: 0x01)
    }

    private func handleStreamFinished(_ streamID: UInt32) {
        let stream = lock.withLock {
            streams[streamID]
        }
        guard let stream else {
            return
        }
        if case .data = stream.kind {
            finishPair(requestID: stream.requestID)
        }
    }

    private func finishPair(requestID: String) {
        let handle = lock.withLock { () -> FileHandle? in
            guard var pair = pairs[requestID] else {
                return nil
            }
            let handle = pair.handle
            pair.handle = nil
            pairs[requestID] = pair
            return handle
        }
        try? handle?.close()
    }

    private func failSession(_ message: String) async {
        fputs("container-cri-shim-macos SPDY port-forward failed: \(message)\n", stderr)
        let errorStreams = lock.withLock {
            pairs.values.compactMap(\.errorStreamID)
        }
        for streamID in errorStreams {
            try? await writeDataFrame(streamID: streamID, data: Data(message.utf8), flags: 0x01)
        }
        await cleanup()
        if let channel {
            try? await channel.close().get()
        }
    }

    private func cleanup() async {
        let (handles, tasksToCancel): ([FileHandle], [Task<Void, Never>]) = lock.withLock {
            if cleanupPerformed {
                return ([], [])
            }
            cleanupPerformed = true
            idleTimeoutTask?.cancel()
            idleTimeoutTask = nil
            let handles = pairs.values.compactMap(\.handle)
            pairs.removeAll()
            streams.removeAll()
            let tasksToCancel = tasks
            tasks.removeAll()
            return (handles, tasksToCancel)
        }

        for task in tasksToCancel {
            task.cancel()
        }
        for handle in handles {
            try? handle.close()
        }
    }

    private func appendTask(_ task: Task<Void, Never>) {
        lock.withLock {
            tasks.append(task)
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
        guard let channel else {
            return
        }
        var buffer = channel.allocator.buffer(capacity: 8 + payload.count)
        buffer.writeInteger(UInt32(0x8000_0000) | (UInt32(3) << 16) | UInt32(type), endianness: .big)
        writeSPDYLength(flags: flags, length: payload.count, to: &buffer)
        buffer.writeBytes(payload)
        channel.writeAndFlush(Self.wrapOutboundOut(buffer), promise: nil)
    }

    private func writeDataFrame(
        streamID: UInt32,
        data: Data,
        flags: UInt8 = 0
    ) async throws {
        guard let channel else {
            return
        }
        var buffer = channel.allocator.buffer(capacity: 8 + data.count)
        buffer.writeInteger(streamID & 0x7FFF_FFFF, endianness: .big)
        writeSPDYLength(flags: flags, length: data.count, to: &buffer)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(Self.wrapOutboundOut(buffer)).get()
    }
}

private final class CRIShimStreamingWebSocketHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

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

    private final class CRIShimPortForwardState {
        let invocation: CRIShimPortForwardInvocation
        private let lock = NSLock()
        private var streams: [UInt8: (port: UInt32, handle: FileHandle)] = [:]

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

        func stream(for stream: UInt8) -> (port: UInt32, handle: FileHandle)? {
            lock.withLock {
                streams[stream]
            }
        }

        func register(stream: UInt8, port: UInt32, handle: FileHandle) {
            lock.withLock {
                streams[stream] = (port: port, handle: handle)
            }
        }

        func close(stream: UInt8) {
            let entry = lock.withLock {
                streams.removeValue(forKey: stream)
            }
            try? entry?.handle.close()
        }

        func handles() -> [FileHandle] {
            lock.withLock {
                streams.values.map(\.handle)
            }
        }
    }

    private let server: CRIShimStreamingServer
    private let runtimeManager: any CRIShimRuntimeManaging
    private let session: CRIShimStreamingSessionDescriptor
    private let negotiatedSubprotocol: String
    private let idleTimeout: TimeAmount?
    private let stateLock = NSLock()
    private var channel: Channel?
    private var cleanupPerformed = false
    private var backgroundTasks: [Task<Void, Never>] = []
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
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        recordActivity()
        startSession()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        recordActivity()

        switch frame.opcode {
        case .binary:
            Task {
                await handleBinaryFrame(frame.unmaskedData)
            }
        case .ping:
            Task {
                try? await writeFrame(opcode: .pong, payload: frame.unmaskedData)
            }
        case .connectionClose:
            Task {
                await closeWebSocket(killProcess: true)
            }
        case .text, .continuation:
            Task {
                await failSession("unsupported websocket frame")
            }
        case .pong:
            break
        default:
            Task {
                await failSession("unsupported websocket opcode")
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

    private func startSession() {
        let task = Task {
            do {
                switch session {
                case .exec(let invocation):
                    try await startExecSession(invocation)
                case .portForward(let invocation):
                    try await startPortForwardSession(invocation)
                }
            } catch {
                await failSession(String(describing: error))
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
        let process = try await runtimeManager.streamExec(
            containerID: invocation.containerID,
            configuration: invocation.configuration,
            stdio: [
                stdinPipe?.fileHandleForReading,
                stdoutPipe?.fileHandleForWriting,
                stderrPipe?.fileHandleForWriting,
            ]
        )
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

        var outputTasks: [Task<Void, Never>] = []
        if let stdoutPipe {
            outputTasks.append(
                Task {
                    await pumpExecOutput(
                        stream: 1,
                        handle: stdoutPipe.fileHandleForReading
                    )
                })
        }
        if let stderrPipe {
            outputTasks.append(
                Task {
                    await pumpExecOutput(
                        stream: 2,
                        handle: stderrPipe.fileHandleForReading
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
                    await sendExecExitStatus(protocolVersion: protocolVersion, exitCode: exitCode)
                    await closeWebSocket(killProcess: false)
                } catch {
                    await failSession(String(describing: error))
                }
            })
    }

    private func startPortForwardSession(_ invocation: CRIShimPortForwardInvocation) async throws {
        let state = CRIShimPortForwardState(invocation: invocation)
        sessionState = .portForward(state)

        for (index, port) in invocation.ports.enumerated() {
            do {
                let handle = try await runtimeManager.streamPortForward(sandboxID: invocation.sandboxID, port: port)
                let stream = UInt8(index * 2)
                state.register(stream: stream, port: port, handle: handle)
                appendTask(
                    Task {
                        await pumpPortForward(stream: stream, port: port, handle: handle)
                    })
            } catch {
                try await sendPortForwardError(port: port, message: String(describing: error))
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

        switch sessionState {
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

        let handle: FileHandle
        if let existing = state.stream(for: stream) {
            guard existing.port == port else {
                await failSession("portforward stream \(stream) changed port from \(existing.port) to \(port)")
                return
            }
            handle = existing.handle
        } else {
            do {
                handle = try await runtimeManager.streamPortForward(sandboxID: state.invocation.sandboxID, port: port)
                state.register(stream: stream, port: port, handle: handle)
                appendTask(
                    Task {
                        await pumpPortForward(stream: stream, port: port, handle: handle)
                    })
            } catch {
                try? await sendPortForwardError(stream: stream, port: port, message: String(describing: error))
                return
            }
        }

        let data = Data(payload.readableBytesView)
        guard !data.isEmpty else {
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            await failSession(String(describing: error))
        }
    }

    private func pumpExecOutput(
        stream: UInt8,
        handle: FileHandle
    ) async {
        for await data in fileHandleStream(handle) {
            do {
                try await writeBinaryMessage(stream: stream, payload: data)
            } catch {
                await failSession(String(describing: error))
                return
            }
        }
    }

    private func pumpPortForward(
        stream: UInt8,
        port: UInt32,
        handle: FileHandle
    ) async {
        defer {
            Task {
                await finishPortForward(stream: stream)
            }
        }

        for await data in fileHandleStream(handle) {
            do {
                try await writeBinaryMessage(
                    stream: stream,
                    payload: portPrefix(port: port) + data
                )
            } catch {
                await failSession(String(describing: error))
                return
            }
        }
    }

    private func finishPortForward(stream: UInt8) async {
        guard case .portForward(let state) = sessionState else {
            return
        }
        state.close(stream: stream)
    }

    private func sendExecExitStatus(
        protocolVersion: CRIShimExecStreamProtocol,
        exitCode: Int32
    ) async {
        let payload: Data
        if protocolVersion.supportsStructuredExitStatus {
            payload = makeStructuredExecStatus(exitCode: exitCode)
        } else if exitCode == 0 {
            payload = Data()
        } else {
            payload = Data("command terminated with exit code \(exitCode)".utf8)
        }

        if !payload.isEmpty {
            try? await writeBinaryMessage(stream: 3, payload: payload)
        }
    }

    private func sendPortForwardError(
        port: UInt32,
        message: String
    ) async throws {
        guard case .portForward(let state) = session else {
            return
        }
        guard let index = state.ports.firstIndex(of: port) else {
            return
        }
        let stream = UInt8(index * 2 + 1)
        try await writeBinaryMessage(stream: stream, payload: portPrefix(port: port) + Data(message.utf8))
    }

    private func sendPortForwardError(
        stream: UInt8,
        port: UInt32,
        message: String
    ) async throws {
        try await writeBinaryMessage(stream: stream + 1, payload: portPrefix(port: port) + Data(message.utf8))
    }

    private func failSession(_ message: String) async {
        switch sessionState {
        case .exec(let state):
            let payload =
                if state.protocolVersion.supportsStructuredExitStatus {
                    makeStructuredExecFailureStatus(message: message)
                } else {
                    Data(message.utf8)
                }
            if !payload.isEmpty {
                try? await writeBinaryMessage(stream: 3, payload: payload)
            }
        case .portForward(let state):
            for port in state.invocation.ports {
                try? await sendPortForwardError(port: port, message: message)
            }
        case .none:
            break
        }
        await closeWebSocket(killProcess: true)
    }

    private func closeWebSocket(killProcess: Bool) async {
        if let closePayload = makeWebSocketClosePayload() {
            try? await writeFrame(opcode: .connectionClose, payload: closePayload)
        }
        await cleanup(killProcess: killProcess)
        if let channel {
            try? await channel.close().get()
        }
    }

    private func cleanup(killProcess: Bool) async {
        let shouldRun = stateLock.withLock {
            if cleanupPerformed {
                return false
            }
            cleanupPerformed = true
            idleTimeoutTask?.cancel()
            idleTimeoutTask = nil
            return true
        }
        guard shouldRun else {
            return
        }

        for task in backgroundTasks {
            task.cancel()
        }

        switch sessionState {
        case .exec(let state):
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
            for handle in state.handles() {
                try? handle.close()
            }
        case .none:
            break
        }
    }

    private func appendTask(_ task: Task<Void, Never>) {
        stateLock.withLock {
            backgroundTasks.append(task)
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
        guard let buffer = makeFramePayload(stream: stream, payload: payload) else {
            return
        }
        try await writeFrame(opcode: .binary, payload: buffer)
        recordActivity()
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

private func fallbackRequestID(
    streamID: UInt32,
    kind: CRIShimPortForwardSPDYHandler.StreamKind
) -> String {
    switch kind {
    case .error:
        "\(streamID)"
    case .data:
        "\(streamID - 2)"
    }
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
    var offset = 0
    let headerCount = try readSPDYUInt32(data, &offset)
    var headers: [String: [String]] = [:]
    for _ in 0..<headerCount {
        let nameLength = Int(try readSPDYUInt32(data, &offset))
        guard offset + nameLength <= data.count else {
            throw CRIShimError.invalidArgument("SPDY header name is truncated")
        }
        let name = String(decoding: data[offset..<(offset + nameLength)], as: UTF8.self).lowercased()
        offset += nameLength

        let valueLength = Int(try readSPDYUInt32(data, &offset))
        guard offset + valueLength <= data.count else {
            throw CRIShimError.invalidArgument("SPDY header value is truncated")
        }
        let value = String(decoding: data[offset..<(offset + valueLength)], as: UTF8.self)
        offset += valueLength
        headers[name] = value.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }
    return headers
}

private func makeSPDYHeaderBlock(_ headers: [String: [String]]) -> Data {
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

private final class CRIShimSPDYHeaderInflater {
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

private final class CRIShimSPDYHeaderDeflater {
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

private func fileHandleStream(_ handle: FileHandle) -> AsyncStream<Data> {
    AsyncStream { continuation in
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(data)
        }
    }
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
