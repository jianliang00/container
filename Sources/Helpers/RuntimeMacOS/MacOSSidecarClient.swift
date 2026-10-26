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

import ContainerizationError
import Darwin
import Foundation
import Logging
import RuntimeMacOSSidecarShared

struct MacOSSidecarTransportFailure: Error {
    let error: ContainerizationError
}

final class MacOSSidecarClient: @unchecked Sendable {
    private static let defaultBootstrapStartTimeoutSeconds: TimeInterval = 120.0

    private final class PendingResponse: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<MacOSSidecarResponse, Error>?
    }

    private struct ControlConnection: Sendable {
        let fd: Int32
        let readerFD: Int32
        let generation: UInt64
    }

    private let socketPath: String
    private let log: Logger
    private let requestTimeoutSeconds: TimeInterval
    private let bootstrapStartTimeoutSeconds: TimeInterval
    private let stateLock = NSLock()
    private let connectionLock = NSLock()
    private let writeLock = NSLock()

    private var controlFD: Int32 = -1
    private var controlReaderFD: Int32 = -1
    private var controlGeneration: UInt64 = 0
    private var subscribedControlGeneration: UInt64?
    private var eventSubscriptionID: String?
    private var readerThread: Thread?
    private var pending: [String: PendingResponse] = [:]
    private var lastControlError: Error?
    private var eventHandler: (@Sendable (MacOSSidecarEvent) -> Void)?
    private var disconnectHandler: (@Sendable (ContainerizationError) -> Void)?

    init(
        socketPath: String,
        log: Logger,
        requestTimeoutSeconds: TimeInterval = 10.0,
        bootstrapStartTimeoutSeconds: TimeInterval? = nil
    ) {
        self.socketPath = socketPath
        self.log = log
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.bootstrapStartTimeoutSeconds =
            bootstrapStartTimeoutSeconds
            ?? max(requestTimeoutSeconds, Self.defaultBootstrapStartTimeoutSeconds)
    }

    deinit {
        closeControlConnection()
    }

    func setEventHandler(_ handler: (@Sendable (MacOSSidecarEvent) -> Void)?) {
        stateLock.lock()
        eventHandler = handler
        stateLock.unlock()
    }

    func setDisconnectHandler(_ handler: (@Sendable (ContainerizationError) -> Void)?) {
        stateLock.lock()
        disconnectHandler = handler
        stateLock.unlock()
    }

    func _testControlConnectionDescriptors() throws -> (owner: Int32, reader: Int32) {
        let connection = try ensureControlConnection(retries: 1, distinguishTransportFailure: false)
        return (connection.fd, connection.readerFD)
    }

    func bootstrapStart(presentGUI: Bool = true, socketConnectRetries: Int = 120) throws {
        _ = try request(
            method: .vmBootstrapStart,
            presentGUI: presentGUI,
            timeoutSeconds: bootstrapStartTimeoutSeconds,
            socketConnectRetries: socketConnectRetries
        )
    }

    func showGUI() throws {
        _ = try request(method: .vmShowGUI)
    }

    func stopVM() throws {
        _ = try request(method: .vmStop)
    }

    func capabilities(
        timeoutSeconds: TimeInterval? = nil,
        distinguishTransportFailure: Bool = false
    ) throws -> MacOSSidecarCapabilities {
        let response = try request(
            method: .vmCapabilities,
            protocolVersion: MacOSSidecarProtocolVersion.machineState,
            timeoutSeconds: timeoutSeconds,
            distinguishTransportFailure: distinguishTransportFailure
        )
        return try decodeResponseData(MacOSSidecarCapabilities.self, response: response, method: .vmCapabilities)
    }

    func pauseVM(timeoutSeconds: TimeInterval = 30) throws -> MacOSMachineStateOperationResult {
        let response = try request(
            method: .vmPause,
            protocolVersion: MacOSSidecarProtocolVersion.machineState,
            machineState: .init(timeoutSeconds: timeoutSeconds),
            timeoutSeconds: timeoutSeconds
        )
        return try decodeResponseData(MacOSMachineStateOperationResult.self, response: response, method: .vmPause)
    }

    func resumeVM(
        timeoutSeconds: TimeInterval = 30,
        distinguishTransportFailure: Bool = false
    ) throws -> MacOSMachineStateOperationResult {
        let response = try request(
            method: .vmResume,
            protocolVersion: MacOSSidecarProtocolVersion.machineState,
            machineState: .init(timeoutSeconds: timeoutSeconds),
            timeoutSeconds: timeoutSeconds,
            distinguishTransportFailure: distinguishTransportFailure
        )
        return try decodeResponseData(MacOSMachineStateOperationResult.self, response: response, method: .vmResume)
    }

    func saveMachineState(stateID: String, timeoutSeconds: TimeInterval = 300) throws -> MacOSMachineStateOperationResult {
        let response = try request(
            method: .vmSaveMachineState,
            protocolVersion: MacOSSidecarProtocolVersion.machineState,
            machineState: .init(stateID: stateID, timeoutSeconds: timeoutSeconds),
            timeoutSeconds: timeoutSeconds
        )
        return try decodeResponseData(MacOSMachineStateOperationResult.self, response: response, method: .vmSaveMachineState)
    }

    func prepareCheckpoint(
        _ payload: MacOSMachineStateRequestPayload,
        timeoutSeconds: TimeInterval = 30
    ) throws -> MacOSMachineStateCheckpointResult {
        let response = try request(
            method: .vmPrepareCheckpoint,
            protocolVersion: MacOSSidecarProtocolVersion.durableCheckpointAdoption,
            machineState: payload,
            timeoutSeconds: timeoutSeconds
        )
        return try decodeResponseData(
            MacOSMachineStateCheckpointResult.self,
            response: response,
            method: .vmPrepareCheckpoint
        )
    }

    func saveDurableMachineState(
        _ payload: MacOSMachineStateRequestPayload,
        timeoutSeconds: TimeInterval = 300
    ) throws -> MacOSMachineStateOperationResult {
        let response = try request(
            method: .vmSaveMachineState,
            protocolVersion: MacOSSidecarProtocolVersion.durableCheckpointAdoption,
            machineState: payload,
            timeoutSeconds: timeoutSeconds
        )
        return try decodeResponseData(
            MacOSMachineStateOperationResult.self,
            response: response,
            method: .vmSaveMachineState
        )
    }

    func machineStateReceipt(stateID: String) throws -> MacOSMachineStateReceipt {
        let response = try request(
            method: .vmMachineStateReceipt,
            protocolVersion: MacOSSidecarProtocolVersion.durableCheckpointAdoption,
            machineState: .init(stateID: stateID)
        )
        return try decodeResponseData(
            MacOSMachineStateReceipt.self,
            response: response,
            method: .vmMachineStateReceipt
        )
    }

    func abortCheckpoint(checkpointID: String) throws {
        _ = try request(
            method: .vmAbortCheckpoint,
            protocolVersion: MacOSSidecarProtocolVersion.durableCheckpointAdoption,
            machineState: .init(checkpointID: checkpointID)
        )
    }

    func storageAttachments() throws -> [MacOSStorageAttachmentStatus] {
        let response = try request(
            method: .vmStorageAttachments,
            protocolVersion: MacOSSidecarProtocolVersion.durableCheckpointAdoption
        )
        return try decodeResponseData(
            [MacOSStorageAttachmentStatus].self,
            response: response,
            method: .vmStorageAttachments
        )
    }

    func restoreMachineState(
        stateID: String,
        timeoutSeconds: TimeInterval = 300,
        socketConnectRetries: Int = 1,
        distinguishTransportFailure: Bool = false
    ) throws -> MacOSMachineStateOperationResult {
        let response = try request(
            method: .vmRestoreMachineState,
            protocolVersion: MacOSSidecarProtocolVersion.machineState,
            machineState: .init(stateID: stateID, timeoutSeconds: timeoutSeconds),
            timeoutSeconds: timeoutSeconds,
            socketConnectRetries: socketConnectRetries,
            distinguishTransportFailure: distinguishTransportFailure
        )
        return try decodeResponseData(MacOSMachineStateOperationResult.self, response: response, method: .vmRestoreMachineState)
    }

    func deleteMachineState(stateID: String) throws -> MacOSMachineStateDeleteResult {
        let response = try request(
            method: .vmDeleteMachineState,
            protocolVersion: MacOSSidecarProtocolVersion.machineState,
            machineState: .init(stateID: stateID)
        )
        return try decodeResponseData(
            MacOSMachineStateDeleteResult.self,
            response: response,
            method: .vmDeleteMachineState
        )
    }

    func compatibilityDescription(stateID: String? = nil) throws -> MacOSMachineStateCompatibilityResult {
        let response = try request(
            method: .vmCompatibilityDescription,
            protocolVersion: MacOSSidecarProtocolVersion.machineState,
            machineState: .init(stateID: stateID)
        )
        return try decodeResponseData(
            MacOSMachineStateCompatibilityResult.self,
            response: response,
            method: .vmCompatibilityDescription
        )
    }

    func quit() throws {
        _ = try request(method: .sidecarQuit)
    }

    func connectVsock(port: UInt32) throws -> Int32 {
        let fd = try connectControlSocket(retries: 1)
        defer { Darwin.close(fd) }

        let request = MacOSSidecarRequest(method: .vmConnectVsock, port: port)
        try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(request), fd: fd)
        let receivedFD = try MacOSSidecarSocketIO.receiveOptionalFileDescriptorMarker(socketFD: fd)
        let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: fd)
        guard envelope.kind == .response, let response = envelope.response else {
            throw ContainerizationError(.internalError, message: "sidecar vm.connectVsock returned invalid envelope")
        }
        try validate(response: response, expectedRequestID: request.requestID)
        guard let receivedFD else {
            throw ContainerizationError(.internalError, message: "sidecar response for vm.connectVsock missing file descriptor")
        }
        return receivedFD
    }

    func processStart(port: UInt32, processID: String, request exec: MacOSSidecarExecRequestPayload) throws {
        let request = MacOSSidecarRequest(method: .processStart, port: port, processID: processID, exec: exec)
        do {
            _ = try requestResponse(request, socketConnectRetries: 1)
        } catch let error as ContainerizationError where error.code == .timeout && exec.durableExecutionID != nil {
            try recoverDurableProcessStart(
                port: port,
                processID: processID,
                exec: exec,
                originalRequest: request
            )
        }
    }

    func processInspect(
        port: UInt32,
        processID: String,
        request exec: MacOSSidecarExecRequestPayload
    ) throws -> MacOSGuestProcessStatusPayload {
        let response = try requestResponse(
            MacOSSidecarRequest(
                method: .processInspect,
                port: port,
                processID: processID,
                exec: exec
            ),
            socketConnectRetries: 1
        )
        return try decodeResponseData(
            MacOSGuestProcessStatusPayload.self,
            response: response,
            method: .processInspect
        )
    }

    private func recoverDurableProcessStart(
        port: UInt32,
        processID: String,
        exec: MacOSSidecarExecRequestPayload,
        originalRequest: MacOSSidecarRequest
    ) throws {
        do {
            let response = try requestResponse(
                MacOSSidecarRequest(method: .processInspect, port: port, processID: processID, exec: exec),
                socketConnectRetries: 1
            )
            let status = try decodeResponseData(
                MacOSGuestProcessStatusPayload.self,
                response: response,
                method: .processInspect
            )
            guard status.executionID == exec.durableExecutionID else {
                throw ContainerizationError(
                    .invalidState,
                    message: "sidecar durable process inspection returned a different execution identifier"
                )
            }
            guard status.state == .running else {
                throw ContainerizationError(
                    .invalidState,
                    message: "sidecar durable process is \(status.state.rawValue) during start recovery"
                )
            }
            return
        } catch let error as ContainerizationError where error.code == .notFound {
            // The timed-out request may still be finishing on the old control
            // connection. A durable retry is idempotent by execution identity
            // and launch fingerprint, so it cannot spawn a second process.
        }

        _ = try requestResponse(originalRequest, socketConnectRetries: 1)
    }

    func processStdin(processID: String, data: Data) throws {
        _ = try requestResponse(
            MacOSSidecarRequest(method: .processStdin, processID: processID, data: data),
            socketConnectRetries: 1
        )
    }

    func processClose(processID: String) throws {
        _ = try requestResponse(
            MacOSSidecarRequest(method: .processClose, processID: processID),
            socketConnectRetries: 1
        )
    }

    func processDelete(
        port: UInt32,
        identity: MacOSSidecarDurableProcessDeleteIdentity
    ) throws {
        let request = MacOSSidecarRequest(
            method: .processDelete,
            protocolVersion: MacOSSidecarProtocolVersion.durableProcessIdentity,
            port: port,
            processID: identity.executionID,
            durableProcessDeleteIdentity: identity
        )
        do {
            _ = try requestResponse(request, socketConnectRetries: 1)
        } catch let error as ContainerizationError
            where error.code == .timeout || error.code == .internalError || error.code == .interrupted
        {
            // The guest delete may have committed while its response was lost.
            // Retrying the trusted identity converges through structured ENOENT.
            _ = try requestResponse(request, socketConnectRetries: 3)
        }
    }

    func processSignal(processID: String, signal: Int32) throws {
        _ = try requestResponse(
            MacOSSidecarRequest(method: .processSignal, processID: processID, signal: signal),
            socketConnectRetries: 1
        )
    }

    func processResize(processID: String, width: UInt16, height: UInt16) throws {
        _ = try requestResponse(
            MacOSSidecarRequest(method: .processResize, processID: processID, width: width, height: height),
            socketConnectRetries: 1
        )
    }

    func fsBegin(port: UInt32, request payload: MacOSSidecarFSBeginRequestPayload) throws {
        _ = try requestResponse(
            MacOSSidecarRequest(method: .fsBegin, port: port, fsBegin: payload),
            socketConnectRetries: 1
        )
    }

    func fsChunk(request payload: MacOSSidecarFSChunkRequestPayload) throws {
        _ = try requestResponse(
            MacOSSidecarRequest(method: .fsChunk, fsChunk: payload),
            socketConnectRetries: 1
        )
    }

    func fsEnd(request payload: MacOSSidecarFSEndRequestPayload) throws {
        _ = try requestResponse(
            MacOSSidecarRequest(method: .fsEnd, fsEnd: payload),
            socketConnectRetries: 1
        )
    }

    func fsReadBegin(port: UInt32, request payload: MacOSSidecarFSReadBeginRequestPayload) throws -> MacOSSidecarFSReadBeginResponsePayload {
        let response = try requestResponse(
            MacOSSidecarRequest(method: .fsReadBegin, port: port, fsReadBegin: payload),
            socketConnectRetries: 1
        )
        guard let data = response.data else {
            throw ContainerizationError(.internalError, message: "sidecar fsReadBegin response missing data")
        }
        return try JSONDecoder().decode(MacOSSidecarFSReadBeginResponsePayload.self, from: data)
    }

    func fsReadChunk(request payload: MacOSSidecarFSReadChunkRequestPayload) throws -> Data? {
        let response = try requestResponse(
            MacOSSidecarRequest(method: .fsReadChunk, fsReadChunk: payload),
            socketConnectRetries: 1
        )
        return response.data
    }

    func fsReadEnd(txID: String) throws {
        _ = try requestResponse(
            MacOSSidecarRequest(method: .fsReadEnd, processID: txID),
            socketConnectRetries: 1
        )
    }

    func fsListDir(port: UInt32, path: String, txID: String) throws -> [MacOSSidecarFSListDirEntry] {
        let payload = MacOSSidecarFSListDirRequestPayload(txID: txID, path: path)
        let response = try requestResponse(
            MacOSSidecarRequest(method: .fsListDir, port: port, fsListDir: payload),
            socketConnectRetries: 1
        )
        guard let data = response.data else {
            throw ContainerizationError(.internalError, message: "sidecar fsListDir response missing data")
        }
        return try JSONDecoder().decode([MacOSSidecarFSListDirEntry].self, from: data)
    }

    func closeControlConnection() {
        connectionLock.lock()
        writeLock.lock()

        let pendingToFail: [PendingResponse]
        stateLock.lock()
        let fd = controlFD
        controlFD = -1
        controlReaderFD = -1
        let thread = readerThread
        readerThread = nil
        subscribedControlGeneration = nil
        eventSubscriptionID = nil
        pendingToFail = Array(pending.values)
        pending.removeAll()
        stateLock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        thread?.cancel()
        writeLock.unlock()
        connectionLock.unlock()

        if !pendingToFail.isEmpty {
            let error = ContainerizationError(.internalError, message: "sidecar control connection closed")
            for waiter in pendingToFail {
                waiter.result = .failure(error)
                waiter.semaphore.signal()
            }
        }
    }

    private func request(
        method: MacOSSidecarMethod,
        protocolVersion: Int? = nil,
        presentGUI: Bool? = nil,
        port: UInt32? = nil,
        machineState: MacOSMachineStateRequestPayload? = nil,
        timeoutSeconds: TimeInterval? = nil,
        socketConnectRetries: Int = 1,
        distinguishTransportFailure: Bool = false
    ) throws -> MacOSSidecarResponse {
        try requestResponse(
            MacOSSidecarRequest(
                method: method,
                protocolVersion: protocolVersion,
                presentGUI: presentGUI,
                port: port,
                machineState: machineState
            ),
            timeoutSeconds: timeoutSeconds ?? requestTimeoutSeconds,
            socketConnectRetries: socketConnectRetries,
            distinguishTransportFailure: distinguishTransportFailure
        )
    }

    private func decodeResponseData<T: Decodable>(
        _ type: T.Type,
        response: MacOSSidecarResponse,
        method: MacOSSidecarMethod
    ) throws -> T {
        guard let data = response.data else {
            throw ContainerizationError(.internalError, message: "sidecar \(method.rawValue) response missing data")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func requestResponse(
        _ request: MacOSSidecarRequest,
        timeoutSeconds: TimeInterval? = nil,
        socketConnectRetries: Int,
        distinguishTransportFailure: Bool = false
    ) throws -> MacOSSidecarResponse {
        let connection = try ensureControlConnection(
            retries: socketConnectRetries,
            distinguishTransportFailure: distinguishTransportFailure
        )
        let effectiveTimeoutSeconds = timeoutSeconds ?? requestTimeoutSeconds
        return try requestResponse(
            request,
            on: connection,
            timeoutSeconds: effectiveTimeoutSeconds,
            distinguishTransportFailure: distinguishTransportFailure
        )
    }

    private func requestResponse(
        _ request: MacOSSidecarRequest,
        on connection: ControlConnection,
        timeoutSeconds: TimeInterval,
        distinguishTransportFailure: Bool = false
    ) throws -> MacOSSidecarResponse {
        let waiter = PendingResponse()

        stateLock.lock()
        pending[request.requestID] = waiter
        stateLock.unlock()

        do {
            writeLock.lock()
            defer { writeLock.unlock() }
            stateLock.lock()
            let isCurrentConnection =
                controlFD == connection.fd
                && controlGeneration == connection.generation
            stateLock.unlock()
            guard isCurrentConnection else {
                let error = ContainerizationError(
                    .internalError,
                    message: "sidecar control connection changed before request write"
                )
                throw classifiedTransportFailure(error, distinguish: distinguishTransportFailure)
            }
            try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(request), fd: connection.fd)
        } catch {
            removePending(requestID: request.requestID)
            handleReaderFailure(error, connection: connection, notifyDisconnect: true)
            throw classifiedTransportFailure(error, distinguish: distinguishTransportFailure)
        }

        let timeoutResult = waiter.semaphore.wait(timeout: .now() + timeoutSeconds)
        if timeoutResult == .timedOut {
            let timeoutError = ContainerizationError(
                .timeout,
                message: "sidecar request \(request.method.rawValue) timed out after \(timeoutSeconds) seconds"
            )
            removePending(requestID: request.requestID)
            handleReaderFailure(timeoutError, connection: connection, notifyDisconnect: false)
            throw classifiedTransportFailure(timeoutError, distinguish: distinguishTransportFailure)
        }
        switch waiter.result {
        case .success(let response)?:
            try validate(response: response, expectedRequestID: request.requestID)
            return response
        case .failure(let error)?:
            throw classifiedTransportFailure(error, distinguish: distinguishTransportFailure)
        case nil:
            throw ContainerizationError(.internalError, message: "sidecar response waiter completed without result")
        }
    }

    private func ensureControlConnection(
        retries: Int,
        distinguishTransportFailure: Bool
    ) throws -> ControlConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        stateLock.lock()
        if controlFD >= 0 {
            let connection = ControlConnection(fd: controlFD, readerFD: controlReaderFD, generation: controlGeneration)
            let needsEventSubscription = eventHandler != nil && subscribedControlGeneration != connection.generation
            stateLock.unlock()
            if needsEventSubscription {
                try subscribeToEvents(on: connection, distinguishTransportFailure: distinguishTransportFailure)
            }
            return connection
        }
        stateLock.unlock()

        let fd: Int32
        do {
            fd = try connectControlSocket(retries: retries)
        } catch {
            throw classifiedTransportFailure(error, distinguish: distinguishTransportFailure)
        }
        let readerFD = Darwin.dup(fd)
        guard readerFD >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw classifiedTransportFailure(error, distinguish: distinguishTransportFailure)
        }
        _ = Darwin.fcntl(readerFD, F_SETFD, FD_CLOEXEC)

        stateLock.lock()
        controlFD = fd
        controlReaderFD = readerFD
        controlGeneration &+= 1
        let connection = ControlConnection(fd: fd, readerFD: readerFD, generation: controlGeneration)
        let thread = Thread { [weak self] in
            self?.readerLoop(connection: connection)
        }
        thread.name = "container-runtime-macos-sidecar-client-reader"
        readerThread = thread
        lastControlError = nil
        let needsEventSubscription = eventHandler != nil
        stateLock.unlock()

        thread.start()
        if needsEventSubscription {
            try subscribeToEvents(on: connection, distinguishTransportFailure: distinguishTransportFailure)
        }
        return connection
    }

    private func subscribeToEvents(
        on connection: ControlConnection,
        distinguishTransportFailure: Bool
    ) throws {
        let response: MacOSSidecarResponse
        do {
            response = try requestResponse(
                MacOSSidecarRequest(
                    method: .eventsSubscribe,
                    protocolVersion: MacOSSidecarProtocolVersion.durableEventAcknowledgement
                ),
                on: connection,
                timeoutSeconds: requestTimeoutSeconds,
                distinguishTransportFailure: distinguishTransportFailure
            )
        } catch let error as ContainerizationError where error.code == .unsupported {
            do {
                response = try requestResponse(
                    MacOSSidecarRequest(
                        method: .eventsSubscribe,
                        protocolVersion: MacOSSidecarProtocolVersion.machineState
                    ),
                    on: connection,
                    timeoutSeconds: requestTimeoutSeconds,
                    distinguishTransportFailure: distinguishTransportFailure
                )
            } catch let fallbackError as ContainerizationError where fallbackError.code == .unsupported {
                log.debug(
                    "sidecar does not support explicit event subscription; using request compatibility",
                    metadata: ["error": "\(fallbackError)"]
                )
                stateLock.lock()
                if controlFD == connection.fd, controlGeneration == connection.generation {
                    subscribedControlGeneration = connection.generation
                    eventSubscriptionID = nil
                }
                stateLock.unlock()
                return
            }
        }

        let subscription: MacOSSidecarEventSubscription?
        if let data = response.data {
            subscription = try JSONDecoder().decode(MacOSSidecarEventSubscription.self, from: data)
        } else {
            subscription = nil
        }

        stateLock.lock()
        if controlFD == connection.fd, controlGeneration == connection.generation {
            subscribedControlGeneration = connection.generation
            eventSubscriptionID = subscription?.subscriptionID
        }
        stateLock.unlock()
    }

    func acknowledgeEvent(_ event: MacOSSidecarEvent) throws {
        guard let sequence = event.sequence, let subscriptionID = event.subscriptionID else {
            return
        }
        _ = try requestResponse(
            MacOSSidecarRequest(
                method: .eventsAcknowledge,
                protocolVersion: MacOSSidecarProtocolVersion.durableEventAcknowledgement,
                eventAcknowledgement: .init(
                    subscriptionID: subscriptionID,
                    processID: event.processID,
                    sequence: sequence
                )
            ),
            timeoutSeconds: requestTimeoutSeconds,
            socketConnectRetries: 1
        )
    }

    private func readerLoop(connection: ControlConnection) {
        defer { Darwin.close(connection.readerFD) }
        while true {
            do {
                let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: connection.readerFD)
                switch envelope.kind {
                case .response:
                    guard let response = envelope.response else {
                        throw ContainerizationError(.internalError, message: "sidecar response envelope missing response payload")
                    }
                    deliverResponse(response)
                case .event:
                    guard let event = envelope.event else {
                        throw ContainerizationError(.internalError, message: "sidecar event envelope missing event payload")
                    }
                    stateLock.lock()
                    let handler = eventHandler
                    stateLock.unlock()
                    handler?(event)
                case .request:
                    continue
                }
            } catch {
                handleReaderFailure(error, connection: connection, notifyDisconnect: true)
                return
            }
        }
    }

    private func deliverResponse(_ response: MacOSSidecarResponse) {
        stateLock.lock()
        let waiter = pending.removeValue(forKey: response.requestID)
        stateLock.unlock()
        guard let waiter else {
            log.error("unexpected sidecar response requestID", metadata: ["request_id": "\(response.requestID)"])
            return
        }
        waiter.result = .success(response)
        waiter.semaphore.signal()
    }

    private func removePending(requestID: String) {
        stateLock.lock()
        _ = pending.removeValue(forKey: requestID)
        stateLock.unlock()
    }

    private func handleReaderFailure(
        _ error: Error,
        connection: ControlConnection,
        notifyDisconnect: Bool
    ) {
        writeLock.lock()

        let pendingToFail: [PendingResponse]
        let disconnectHandler: (@Sendable (ContainerizationError) -> Void)?
        stateLock.lock()
        guard controlFD == connection.fd, controlGeneration == connection.generation else {
            stateLock.unlock()
            writeLock.unlock()
            return
        }
        let fd = controlFD
        controlFD = -1
        controlReaderFD = -1
        readerThread = nil
        subscribedControlGeneration = nil
        eventSubscriptionID = nil
        lastControlError = error
        pendingToFail = Array(pending.values)
        pending.removeAll()
        // A peer-side connection loss must restart event subscription even
        // when a request outcome is ambiguous. Lifecycle recovery reconciles
        // the VM and durable processes instead of treating this as VM death.
        // A local request timeout passes notifyDisconnect=false because that
        // caller owns operation-specific reconciliation.
        disconnectHandler = notifyDisconnect ? self.disconnectHandler : nil
        stateLock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        writeLock.unlock()

        let wrapped = ContainerizationError(
            .internalError,
            message: "sidecar control connection closed: \(describe(error: error))"
        )
        for waiter in pendingToFail {
            waiter.result = .failure(wrapped)
            waiter.semaphore.signal()
        }
        if disconnectHandler != nil {
            log.error("sidecar control reader failed", metadata: ["error": "\(error)"])
            disconnectHandler?(wrapped)
        } else {
            log.warning("sidecar control transport reset; request recovery remains with the caller", metadata: ["error": "\(error)"])
        }
    }

    private func validate(response: MacOSSidecarResponse, expectedRequestID: String) throws {
        guard response.requestID == expectedRequestID else {
            throw ContainerizationError(.internalError, message: "sidecar response requestID mismatch")
        }
        guard response.ok else {
            let error = response.error
            let rawCode = error?.code ?? "unknown"
            let message = error?.message ?? "unknown sidecar error"
            let details = error?.details.map { " (\($0))" } ?? ""
            let metadata =
                error?.metadata.map { values in
                    let rendered = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                    return rendered.isEmpty ? "" : " {\(rendered)}"
                } ?? ""
            let codeSuffix = rawCode == "internalError" || rawCode == "unknown" ? "" : " [code=\(rawCode)]"
            throw ContainerizationError(
                Self.containerizationCode(forSidecarCode: rawCode),
                message: "sidecar \(message)\(details)\(metadata)\(codeSuffix)"
            )
        }
    }

    private func classifiedTransportFailure(
        _ error: Error,
        distinguish: Bool
    ) -> Error {
        if let error = error as? MacOSSidecarTransportFailure {
            return distinguish ? error : error.error
        }
        let normalized =
            error as? ContainerizationError
            ?? ContainerizationError(
                .internalError,
                message: "sidecar control transport failed: \(describe(error: error))"
            )
        return distinguish ? MacOSSidecarTransportFailure(error: normalized) : normalized
    }

    private static func containerizationCode(forSidecarCode code: String) -> ContainerizationError.Code {
        switch code {
        case "invalidArgument", "invalid_request", "invalidMachineStateID", "invalidTimeout", "unsafeMachineStatePath", "invalidStorageConfiguration",
            "eventAcknowledgementOutOfRange":
            .invalidArgument
        case "internalError", "request_failed", "sidecar_error", "unknown":
            .internalError
        case "exists", "machineStateAlreadyExists":
            .exists
        case "notFound", "machineStateNotFound":
            .notFound
        case "cancelled":
            .cancelled
        case "invalidState", "invalidLifecycleState", "operationInProgress", "machineStateInUse", "machineStateIncompatible", "machineStateIncomplete", "storageUnavailable",
            "staleEventSubscription":
            .invalidState
        case "empty":
            .empty
        case "timeout":
            .timeout
        case "unsupported", "protocolVersionMismatch", "unknownMethod", "unsupportedHostArchitecture", "unsupportedVMConfiguration":
            .unsupported
        case "interrupted":
            .interrupted
        default:
            .internalError
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
