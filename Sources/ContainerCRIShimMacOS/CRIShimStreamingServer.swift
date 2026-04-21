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

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private let criShimStreamingSessionTimeoutSeconds: TimeInterval = 30
private let criShimStreamingUpgradeRequired = HTTPResponseStatus(statusCode: 426, reasonPhrase: "Upgrade Required")

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
    private let websocketMaxFrameSize: Int
    private let stateLock = NSLock()
    private var serverChannel: Channel?
    private var activeChannels: [ObjectIdentifier: Channel] = [:]
    private var baseURL: URL?

    public init(
        config: CRIShimConfig,
        runtimeManager: any CRIShimRuntimeManaging,
        sessionTimeoutSeconds: TimeInterval = 30,
        websocketMaxFrameSize: Int = 1 << 20
    ) {
        self.config = config
        self.runtimeManager = runtimeManager
        self.sessionStore = CRIShimStreamingSessionStore(sessionTTL: sessionTimeoutSeconds)
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
                return channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false,
                    withServerUpgrade: (
                        upgraders: [upgrader],
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
            negotiatedSubprotocol: selectedSubprotocol
        )
        return CRIShimPreparedWebSocketUpgrade(
            subprotocol: selectedSubprotocol,
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
        var handles: [UInt32: FileHandle]
        var openPorts: Set<UInt32>

        init(invocation: CRIShimPortForwardInvocation, handles: [UInt32: FileHandle]) {
            self.invocation = invocation
            self.handles = handles
            self.openPorts = Set(handles.keys)
        }
    }

    private let server: CRIShimStreamingServer
    private let runtimeManager: any CRIShimRuntimeManaging
    private let session: CRIShimStreamingSessionDescriptor
    private let negotiatedSubprotocol: String
    private let stateLock = NSLock()
    private var channel: Channel?
    private var cleanupPerformed = false
    private var backgroundTasks: [Task<Void, Never>] = []
    private var sessionState: SessionState?

    init(
        server: CRIShimStreamingServer,
        runtimeManager: any CRIShimRuntimeManaging,
        session: CRIShimStreamingSessionDescriptor,
        negotiatedSubprotocol: String
    ) {
        self.server = server
        self.runtimeManager = runtimeManager
        self.session = session
        self.negotiatedSubprotocol = negotiatedSubprotocol
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        startSession()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

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
                await closeWebSocket()
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

        if let stdoutPipe {
            appendTask(
                Task {
                    await pumpExecOutput(
                        stream: 1,
                        handle: stdoutPipe.fileHandleForReading
                    )
                })
        }
        if let stderrPipe {
            appendTask(
                Task {
                    await pumpExecOutput(
                        stream: 2,
                        handle: stderrPipe.fileHandleForReading
                    )
                })
        }

        try await process.start()

        appendTask(
            Task {
                do {
                    let exitCode = try await process.wait()
                    await sendExecExitStatus(protocolVersion: protocolVersion, exitCode: exitCode)
                    await closeWebSocket()
                } catch {
                    await failSession(String(describing: error))
                }
            })
    }

    private func startPortForwardSession(_ invocation: CRIShimPortForwardInvocation) async throws {
        var handles: [UInt32: FileHandle] = [:]
        for port in invocation.ports {
            do {
                handles[port] = try await runtimeManager.streamPortForward(sandboxID: invocation.sandboxID, port: port)
            } catch {
                try await sendPortForwardError(port: port, message: String(describing: error))
            }
        }

        let state = CRIShimPortForwardState(invocation: invocation, handles: handles)
        sessionState = .portForward(state)
        if handles.isEmpty {
            await closeWebSocket()
            return
        }

        for (port, handle) in handles.sorted(by: { $0.key < $1.key }) {
            appendTask(
                Task {
                    await pumpPortForward(port: port, handle: handle)
                })
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

        let index = Int(stream / 2)
        guard index < state.invocation.ports.count else {
            await failSession("portforward stream \(stream) is out of range")
            return
        }

        var payload = payload
        guard let forwardedPort = payload.readInteger(endianness: .little, as: UInt16.self) else {
            await failSession("portforward frame missing forwarded port")
            return
        }

        let port = state.invocation.ports[index]
        guard forwardedPort == UInt16(port) else {
            await failSession("portforward stream \(stream) forwarded port \(forwardedPort) does not match \(port)")
            return
        }

        guard let handle = state.handles[port] else {
            return
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
        port: UInt32,
        handle: FileHandle
    ) async {
        defer {
            Task {
                await finishPortForward(port: port)
            }
        }

        let index: UInt8
        switch sessionState {
        case .portForward(let state):
            guard let resolvedIndex = state.invocation.ports.firstIndex(of: port) else {
                return
            }
            index = UInt8(resolvedIndex * 2)
        default:
            return
        }

        for await data in fileHandleStream(handle) {
            do {
                try await writeBinaryMessage(
                    stream: index,
                    payload: portPrefix(port: port) + data
                )
            } catch {
                await failSession(String(describing: error))
                return
            }
        }
    }

    private func finishPortForward(port: UInt32) async {
        guard case .portForward(let state) = sessionState else {
            return
        }
        state.openPorts.remove(port)
        if state.openPorts.isEmpty {
            await closeWebSocket()
        }
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
        await closeWebSocket()
    }

    private func closeWebSocket() async {
        try? await writeFrame(opcode: .connectionClose, payload: ByteBuffer())
        await cleanup(killProcess: false)
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
            for handle in state.handles.values {
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

    private func writeBinaryMessage(
        stream: UInt8,
        payload: Data
    ) async throws {
        guard let buffer = makeFramePayload(stream: stream, payload: payload) else {
            return
        }
        try await writeFrame(opcode: .binary, payload: buffer)
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

}

private func websocketProtocols(from headers: HTTPHeaders) -> [String] {
    headers["Sec-WebSocket-Protocol"]
        .flatMap { value in
            value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
}

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
