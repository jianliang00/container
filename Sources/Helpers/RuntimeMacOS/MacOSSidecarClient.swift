import ContainerizationError
import Darwin
import Foundation
import Logging
import RuntimeMacOSSidecarShared

final class MacOSSidecarClient: @unchecked Sendable {
    private final class PendingResponse: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<MacOSSidecarResponse, Error>?
    }

    private let socketPath: String
    private let log: Logger
    private let stateLock = NSLock()
    private let writeLock = NSLock()

    private var controlFD: Int32 = -1
    private var readerThread: Thread?
    private var pending: [String: PendingResponse] = [:]
    private var lastControlError: Error?
    private var eventHandler: (@Sendable (MacOSSidecarEvent) -> Void)?

    init(socketPath: String, log: Logger) {
        self.socketPath = socketPath
        self.log = log
    }

    deinit {
        closeControlConnection()
    }

    func setEventHandler(_ handler: (@Sendable (MacOSSidecarEvent) -> Void)?) {
        stateLock.lock()
        eventHandler = handler
        stateLock.unlock()
    }

    func bootstrapStart(socketConnectRetries: Int = 120) throws {
        _ = try request(method: .vmBootstrapStart, socketConnectRetries: socketConnectRetries)
    }

    func stopVM() throws {
        _ = try request(method: .vmStop)
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
        _ = try requestResponse(
            MacOSSidecarRequest(method: .processStart, port: port, processID: processID, exec: exec),
            socketConnectRetries: 1
        )
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

    func closeControlConnection() {
        let pendingToFail: [PendingResponse]
        stateLock.lock()
        let fd = controlFD
        controlFD = -1
        let thread = readerThread
        readerThread = nil
        pendingToFail = Array(pending.values)
        pending.removeAll()
        stateLock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        thread?.cancel()

        if !pendingToFail.isEmpty {
            let error = ContainerizationError(.internalError, message: "sidecar control connection closed")
            for waiter in pendingToFail {
                waiter.result = .failure(error)
                waiter.semaphore.signal()
            }
        }
    }

    private func request(method: MacOSSidecarMethod, port: UInt32? = nil, socketConnectRetries: Int = 1) throws -> MacOSSidecarResponse {
        try requestResponse(MacOSSidecarRequest(method: method, port: port), socketConnectRetries: socketConnectRetries)
    }

    private func requestResponse(_ request: MacOSSidecarRequest, socketConnectRetries: Int) throws -> MacOSSidecarResponse {
        let waiter = PendingResponse()
        let fd = try ensureControlConnection(retries: socketConnectRetries)

        stateLock.lock()
        pending[request.requestID] = waiter
        stateLock.unlock()

        do {
            writeLock.lock()
            defer { writeLock.unlock() }
            try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(request), fd: fd)
        } catch {
            removePending(requestID: request.requestID)
            handleReaderFailure(error)
            throw error
        }

        waiter.semaphore.wait()
        switch waiter.result {
        case .success(let response)?:
            try validate(response: response, expectedRequestID: request.requestID)
            return response
        case .failure(let error)?:
            throw error
        case nil:
            throw ContainerizationError(.internalError, message: "sidecar response waiter completed without result")
        }
    }

    private func ensureControlConnection(retries: Int) throws -> Int32 {
        stateLock.lock()
        if controlFD >= 0 {
            let fd = controlFD
            stateLock.unlock()
            return fd
        }
        stateLock.unlock()

        let fd = try connectControlSocket(retries: retries)
        let thread = Thread { [weak self] in
            self?.readerLoop(fd: fd)
        }
        thread.name = "container-runtime-macos-sidecar-client-reader"

        stateLock.lock()
        if controlFD >= 0 {
            let existing = controlFD
            stateLock.unlock()
            Darwin.close(fd)
            return existing
        }
        controlFD = fd
        readerThread = thread
        lastControlError = nil
        stateLock.unlock()

        thread.start()
        return fd
    }

    private func readerLoop(fd: Int32) {
        while true {
            do {
                let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: fd)
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
                handleReaderFailure(error)
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

    private func handleReaderFailure(_ error: Error) {
        let pendingToFail: [PendingResponse]
        stateLock.lock()
        let shouldHandle = controlFD >= 0
        let fd = controlFD
        controlFD = -1
        readerThread = nil
        lastControlError = error
        pendingToFail = Array(pending.values)
        pending.removeAll()
        stateLock.unlock()

        if fd >= 0 {
            Darwin.close(fd)
        }
        if !shouldHandle && pendingToFail.isEmpty {
            return
        }

        let wrapped = ContainerizationError(
            .internalError,
            message: "sidecar control connection closed: \(describe(error: error))"
        )
        for waiter in pendingToFail {
            waiter.result = .failure(wrapped)
            waiter.semaphore.signal()
        }
        log.error("sidecar control reader failed", metadata: ["error": "\(error)"])
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
