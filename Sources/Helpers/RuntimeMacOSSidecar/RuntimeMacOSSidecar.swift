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

import AppKit
import ArgumentParser
import ContainerLog
import ContainerResource
import ContainerVersion
import ContainerXPC
import ContainerizationError
import CryptoKit
import Darwin
import Foundation
import Logging
import RuntimeMacOSSidecarShared
@preconcurrency import Virtualization

@MainActor
@main
struct RuntimeMacOSSidecar: @preconcurrency ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-runtime-macos-sidecar",
        abstract: "GUI-domain sidecar host for macOS guest VMs",
        version: ReleaseVersion.singleLine(appName: "container-runtime-macos-sidecar")
    )

    @Flag(name: .long, help: "Enable debug logging")
    var debug = false

    @Option(name: .shortAndLong, help: "Sandbox UUID")
    var uuid: String

    @Option(name: .shortAndLong, help: "Root directory for the sandbox")
    var root: String

    @Option(name: .long, help: "Unix socket path for control RPC")
    var controlSocket: String

    @Option(name: .customLong("lifecycle-barrier-protocol"), help: "Sidecar lifecycle barrier protocol")
    var lifecycleBarrierProtocol: Int?

    @Option(name: .customLong("lifecycle-barrier-nonce"), help: "Sidecar lifecycle boot nonce")
    var lifecycleBarrierNonce: String?

    @Option(name: .customLong("lifecycle-persistence-id"), help: "Machine-state persistence identity")
    var lifecyclePersistenceID: String?

    @Option(name: .customLong("lifecycle-storage-directory"), help: "Machine-state storage directory")
    var lifecycleStorageDirectory: String?

    @MainActor
    mutating func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let log = Self.setupLogger(debug: debug, metadata: ["uuid": "\(uuid)"])

        let lifecycleArguments = [
            lifecycleBarrierProtocol.map(String.init),
            lifecycleBarrierNonce,
            lifecyclePersistenceID,
            lifecycleStorageDirectory,
        ]
        let suppliedLifecycleArgumentCount = lifecycleArguments.compactMap { $0 }.count
        let lifecycleLock: MacOSSidecarLifecycleLock?
        if suppliedLifecycleArgumentCount == 0 {
            lifecycleLock = nil
        } else {
            guard suppliedLifecycleArgumentCount == lifecycleArguments.count,
                let lifecycleBarrierProtocol,
                let lifecycleBarrierNonce,
                let lifecyclePersistenceID,
                let lifecycleStorageDirectory
            else {
                throw ValidationError("sidecar lifecycle barrier arguments must be supplied together")
            }
            lifecycleLock = try MacOSSidecarLifecycleLock(
                protocolVersion: lifecycleBarrierProtocol,
                persistenceID: lifecyclePersistenceID,
                sandboxID: uuid,
                bootNonce: lifecycleBarrierNonce,
                storageDirectory: lifecycleStorageDirectory
            )
        }
        defer { withExtendedLifetime(lifecycleLock) {} }

        log.info("starting sidecar", metadata: ["root": "\(root)", "control_socket": "\(controlSocket)"])
        let app = NSApplication.shared
        let appDelegate = SidecarApplicationDelegate()
        app.delegate = appDelegate
        app.setActivationPolicy(.prohibited)
        log.info("host context", metadata: Self.hostContextMetadata())

        let service = MacOSSidecarService(rootURL: URL(fileURLWithPath: root), log: log)
        let server = SidecarControlServer(socketPath: controlSocket, service: service, log: log)
        DispatchQueue.main.async {
            do {
                try server.start()
                log.info("sidecar entering app run loop")
            } catch {
                log.error("failed to start control server", metadata: ["error": "\(error)"])
                NSApplication.shared.terminate(nil)
            }
        }
        withExtendedLifetime(appDelegate) {
            app.run()
        }
        server.stop()
        log.info("sidecar stopped")
    }

    static func setupLogger(debug: Bool, metadata: [String: Logging.Logger.Metadata.Value] = [:]) -> Logging.Logger {
        LoggingSystem.bootstrap { label in
            OSLogHandler(label: label, category: "RuntimeMacOSSidecar")
        }
        var log = Logging.Logger(label: "com.apple.container")
        if debug { log.logLevel = .debug }
        for (key, val) in metadata { log[metadataKey: key] = val }
        return log
    }

    @MainActor
    static func hostContextMetadata() -> Logger.Metadata {
        var metadata: Logger.Metadata = [:]
        metadata["pid"] = "\(getpid())"
        metadata["uid"] = "\(getuid())"
        metadata["stdin_tty"] = "\(isatty(STDIN_FILENO) == 1)"
        metadata["screens"] = "\(NSScreen.screens.count)"
        metadata["has_main_screen"] = "\(NSScreen.main != nil)"
        metadata["launch_label"] = "\(ProcessInfo.processInfo.environment["LAUNCH_JOB_LABEL"] ?? "-")"
        metadata["session"] = "\(currentSessionSummary())"
        return metadata
    }

    @MainActor
    static func currentSessionSummary() -> String {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return "unavailable"
        }
        let onConsole = dict["kCGSessionOnConsoleKey"].map { "\($0)" } ?? "nil"
        let loginDone = dict["kCGSessionLoginDoneKey"].map { "\($0)" } ?? "nil"
        let userName = dict["kCGSessionUserNameKey"].map { "\($0)" } ?? "nil"
        let userID = dict["kCGSessionUserIDKey"].map { "\($0)" } ?? "nil"
        return "onConsole=\(onConsole) loginDone=\(loginDone) user=\(userName) uid=\(userID)"
    }
}

private final class SidecarApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    private let log: Logging.Logger

    init(log: Logging.Logger) {
        self.log = log
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log.info("vm guest did stop")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        log.error("vm stopped with error", metadata: ["error": "\(error)"])
    }
}

private final class GUIWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: @MainActor @Sendable () -> Void

    init(onClose: @escaping @MainActor @Sendable () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            onClose()
        }
    }
}

private func sidecarReadDeadline(timeoutSeconds: TimeInterval) -> UInt64 {
    let timeoutNanoseconds = UInt64(max(timeoutSeconds, 0) * 1_000_000_000)
    let now = DispatchTime.now().uptimeNanoseconds
    let (deadline, overflow) = now.addingReportingOverflow(timeoutNanoseconds)
    return overflow ? UInt64.max : deadline
}

private func sidecarRemainingReadMilliseconds(until deadline: UInt64) throws -> Int32 {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadline else {
        throw POSIXError(.ETIMEDOUT)
    }
    let remainingNanoseconds = deadline - now
    let roundedMilliseconds = 1 + ((remainingNanoseconds - 1) / 1_000_000)
    return Int32(min(roundedMilliseconds, UInt64(Int32.max)))
}

private func isSidecarReadTimeout(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ETIMEDOUT)
}

struct SidecarGuestAgentFrame: Codable {
    enum FrameType: String, Codable {
        case exec
        case processInspect
        case processAttach
        case processEventAck
        case processStop
        case processDelete
        case stdin
        case signal
        case resize
        case close
        case networkConfigure
        case networkResult
        case fsBegin
        case fsChunk
        case fsEnd
        case fsReadBegin
        case fsReadChunk
        case fsReadEnd
        case fsListDir
        case ack
        case stdout
        case stderr
        case exit
        case error
        case ready
    }

    let type: FrameType
    let id: String?
    let capabilities: [String]?
    let executable: String?
    let arguments: [String]?
    let environment: [String]?
    let rootDirectory: String?
    let workingDirectory: String?
    let terminal: Bool?
    let durable: Bool?
    let cursor: UInt64?
    let sequence: UInt64?
    let expectedLaunchFingerprint: String?
    let trustedLaunchFingerprint: String?
    let incarnation: String?
    let storageGeneration: UInt64?
    let previousStorageGeneration: UInt64?
    let user: String?
    let signal: Int32?
    let width: UInt16?
    let height: UInt16?
    let data: Data?
    let exitCode: Int32?
    let message: String?
    let errorCode: Int32?
    let op: MacOSSidecarFSOperation?
    let path: String?
    let mode: UInt32?
    let uid: UInt32?
    let gid: UInt32?
    let supplementalGroups: [UInt32]?
    let mtime: Int64?
    let linkTarget: String?
    let overwrite: Bool?
    let autoCommit: Bool?
    let offset: UInt64?
    let action: MacOSSidecarFSEndAction?
    let digest: String?
    let maxLength: Int?

    init(
        type: FrameType,
        id: String? = nil,
        capabilities: [String]? = nil,
        executable: String? = nil,
        arguments: [String]? = nil,
        environment: [String]? = nil,
        rootDirectory: String? = nil,
        workingDirectory: String? = nil,
        terminal: Bool? = nil,
        durable: Bool? = nil,
        cursor: UInt64? = nil,
        sequence: UInt64? = nil,
        expectedLaunchFingerprint: String? = nil,
        trustedLaunchFingerprint: String? = nil,
        incarnation: String? = nil,
        storageGeneration: UInt64? = nil,
        previousStorageGeneration: UInt64? = nil,
        user: String? = nil,
        signal: Int32? = nil,
        width: UInt16? = nil,
        height: UInt16? = nil,
        data: Data? = nil,
        exitCode: Int32? = nil,
        message: String? = nil,
        errorCode: Int32? = nil,
        op: MacOSSidecarFSOperation? = nil,
        path: String? = nil,
        mode: UInt32? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        supplementalGroups: [UInt32]? = nil,
        mtime: Int64? = nil,
        linkTarget: String? = nil,
        overwrite: Bool? = nil,
        autoCommit: Bool? = nil,
        offset: UInt64? = nil,
        action: MacOSSidecarFSEndAction? = nil,
        digest: String? = nil,
        maxLength: Int? = nil
    ) {
        self.type = type
        self.id = id
        self.capabilities = capabilities
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.rootDirectory = rootDirectory
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.durable = durable
        self.cursor = cursor
        self.sequence = sequence
        self.expectedLaunchFingerprint = expectedLaunchFingerprint
        self.trustedLaunchFingerprint = trustedLaunchFingerprint
        self.incarnation = incarnation
        self.storageGeneration = storageGeneration
        self.previousStorageGeneration = previousStorageGeneration
        self.user = user
        self.signal = signal
        self.width = width
        self.height = height
        self.data = data
        self.exitCode = exitCode
        self.message = message
        self.errorCode = errorCode
        self.op = op
        self.path = path
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.supplementalGroups = supplementalGroups
        self.mtime = mtime
        self.linkTarget = linkTarget
        self.overwrite = overwrite
        self.autoCommit = autoCommit
        self.offset = offset
        self.action = action
        self.digest = digest
        self.maxLength = maxLength
    }

    static func exec(
        id: String,
        executable: String,
        arguments: [String],
        environment: [String]?,
        rootDirectory: String?,
        workingDirectory: String?,
        terminal: Bool,
        user: String?,
        uid: UInt32?,
        gid: UInt32?,
        supplementalGroups: [UInt32]?,
        durable: Bool = false,
        cursor: UInt64? = nil,
        expectedLaunchFingerprint: String? = nil,
        trustedLaunchFingerprint: String? = nil,
        incarnation: String? = nil,
        storageGeneration: UInt64? = nil,
        previousStorageGeneration: UInt64? = nil
    ) -> Self {
        .init(
            type: .exec,
            id: id,
            executable: executable,
            arguments: arguments,
            environment: environment,
            rootDirectory: rootDirectory,
            workingDirectory: workingDirectory,
            terminal: terminal,
            durable: durable,
            cursor: cursor,
            expectedLaunchFingerprint: expectedLaunchFingerprint,
            trustedLaunchFingerprint: trustedLaunchFingerprint,
            incarnation: incarnation,
            storageGeneration: storageGeneration,
            previousStorageGeneration: previousStorageGeneration,
            user: user,
            signal: nil,
            width: nil,
            height: nil,
            data: nil,
            exitCode: nil,
            message: nil,
            uid: uid,
            gid: gid,
            supplementalGroups: supplementalGroups
        )
    }

    static func close(id: String) -> Self {
        .init(type: .close, id: id)
    }

    static func processAttach(
        id: String,
        cursor: UInt64,
        expectedLaunchFingerprint: String? = nil,
        trustedLaunchFingerprint: String? = nil,
        incarnation: String? = nil,
        storageGeneration: UInt64? = nil,
        previousStorageGeneration: UInt64? = nil
    ) -> Self {
        .init(
            type: .processAttach,
            id: id,
            cursor: cursor,
            expectedLaunchFingerprint: expectedLaunchFingerprint,
            trustedLaunchFingerprint: trustedLaunchFingerprint,
            incarnation: incarnation,
            storageGeneration: storageGeneration,
            previousStorageGeneration: previousStorageGeneration
        )
    }

    static func processDelete(
        id: String,
        expectedLaunchFingerprint: String?,
        trustedLaunchFingerprint: String,
        incarnation: String,
        storageGeneration: UInt64?
    ) -> Self {
        .init(
            type: .processDelete,
            id: id,
            expectedLaunchFingerprint: expectedLaunchFingerprint,
            trustedLaunchFingerprint: trustedLaunchFingerprint,
            incarnation: incarnation,
            storageGeneration: storageGeneration
        )
    }

    static func processEventAck(id: String, sequence: UInt64) -> Self {
        .init(type: .processEventAck, id: id, sequence: sequence)
    }

    static func stdin(id: String, data: Data) -> Self {
        .init(type: .stdin, id: id, data: data)
    }

    static func networkConfigure(_ payload: MacOSGuestNetworkConfigurationRequest) throws -> Self {
        .init(type: .networkConfigure, data: try JSONEncoder().encode(payload))
    }

    static func networkResult(_ payload: MacOSGuestNetworkConfigurationResult) throws -> Self {
        .init(type: .networkResult, data: try JSONEncoder().encode(payload))
    }

    static func fsBegin(_ payload: MacOSSidecarFSBeginRequestPayload) -> Self {
        .init(
            type: .fsBegin,
            id: payload.txID,
            data: payload.inlineData,
            op: payload.op,
            path: payload.path,
            mode: payload.mode,
            uid: payload.uid,
            gid: payload.gid,
            mtime: payload.mtime,
            linkTarget: payload.linkTarget,
            overwrite: payload.overwrite,
            autoCommit: payload.autoCommit,
            digest: payload.digest
        )
    }

    static func fsChunk(_ payload: MacOSSidecarFSChunkRequestPayload) -> Self {
        .init(type: .fsChunk, id: payload.txID, data: payload.data, offset: payload.offset)
    }

    static func fsEnd(_ payload: MacOSSidecarFSEndRequestPayload) -> Self {
        .init(type: .fsEnd, id: payload.txID, action: payload.action, digest: payload.digest)
    }

    static func fsReadBegin(_ payload: MacOSSidecarFSReadBeginRequestPayload) -> Self {
        .init(type: .fsReadBegin, id: payload.txID, path: payload.path)
    }

    static func fsReadChunk(_ payload: MacOSSidecarFSReadChunkRequestPayload) -> Self {
        .init(type: .fsReadChunk, id: payload.txID, offset: payload.offset, maxLength: payload.maxLength)
    }

    static func fsReadEnd(txID: String) -> Self {
        .init(type: .fsReadEnd, id: txID)
    }

    static func fsListDir(txID: String, path: String) -> Self {
        .init(type: .fsListDir, id: txID, path: path)
    }

    static func ack(id: String) -> Self {
        .init(type: .ack, id: id)
    }
}

actor MacOSSidecarService {
    private static let bootstrapGuestAgentRetryDelayNanoseconds: UInt64 = 500_000_000
    private static let bootstrapGuestAgentMaxAttempts = 120
    private static let bootstrapGuestAgentReadyTimeoutSeconds: TimeInterval = 3

    private final class UnsafeSendableBox<T>: @unchecked Sendable {
        let value: T

        init(_ value: T) {
            self.value = value
        }
    }

    private final class BlockingResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func tryComplete() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if completed {
                return false
            }
            completed = true
            return true
        }
    }

    private final class CreatedVM: @unchecked Sendable {
        let vm: VZVirtualMachine
        let delegate: VMDelegate

        init(vm: VZVirtualMachine, delegate: VMDelegate) {
            self.vm = vm
            self.delegate = delegate
        }
    }

    private let rootURL: URL
    private let log: Logging.Logger

    private var vm: VZVirtualMachine?
    private var vmConfiguration: VZVirtualMachineConfiguration?
    private var vmDelegate: VMDelegate?
    private var vmWindow: UnsafeSendableBox<NSWindow>?
    private var vmWindowView: UnsafeSendableBox<VZVirtualMachineView>?
    private var vmWindowDelegate: UnsafeSendableBox<GUIWindowDelegate>?
    private var networkLease: MacOSGuestNetworkLease?
    private var ownedVMNetNetworks: [ManagedVMNetNetwork] = []
    private var networkSessions: [XPCClientSession] = []
    private var networkActivations: [PreparedMacOSNetworkActivation] = []
    private var nbdObservers: [MacOSNBDConnectionObserver] = []
    private var currentCompatibility: MacOSMachineStateCompatibilityDescription?
    private var lifecycle = MacOSVMLifecycleCoordinator()

    private var state: MacOSVMRuntimeState { lifecycle.state }

    init(rootURL: URL, log: Logging.Logger) {
        self.rootURL = rootURL
        self.log = log
    }

    func bootstrapStart(presentGUI: Bool = true) async throws {
        let shouldStart = try lifecycle.begin(.start)
        if !shouldStart {
            log.info(
                "bootstrapStart skipped; vm already running",
                metadata: ["present_gui": "\(presentGUI)"])
            return
        }

        log.info("bootstrapStart: loading container config")
        let config: ContainerConfiguration
        do {
            config = try loadContainerConfiguration()
        } catch {
            lifecycle.complete(.start, succeeded: false)
            throw error
        }
        let guiEnabled = config.macosGuest?.guiEnabled ?? false
        log.info(
            "bootstrapStart: building vm configuration",
            metadata: [
                "cpus": "\(config.resources.cpus)",
                "memory": "\(config.resources.memoryInBytes)",
                "gui_enabled": "\(guiEnabled)",
            ])

        do {
            let vmConfiguration: VZVirtualMachineConfiguration
            if let prepared = self.vmConfiguration {
                vmConfiguration = prepared
            } else {
                vmConfiguration = try await makeVirtualMachineConfiguration(containerConfig: config)
            }
            self.vmConfiguration = vmConfiguration
            log.info("bootstrapStart: creating VZVirtualMachine")
            let created = try await createVirtualMachineOnMain(configuration: vmConfiguration)
            let vm = created.vm
            self.vmDelegate = created.delegate
            self.vm = vm
            log.info(
                "bootstrapStart: GUI presentation decision",
                metadata: [
                    "gui_enabled": "\(guiEnabled)",
                    "present_gui": "\(presentGUI)",
                    "will_present_gui": "\(guiEnabled && presentGUI)",
                ])
            if guiEnabled && presentGUI {
                try await presentGUIWindowOnMain(vm: vm, containerID: config.id)
            }
            log.info(
                "bootstrapStart: starting vm",
                metadata: [
                    "gui_enabled": "\(guiEnabled)",
                    "present_gui": "\(presentGUI)",
                ])
            let agentPort = config.macosGuest?.agentPort ?? 27000
            try await startVirtualMachine(vm)
            try await activatePreparedNetworks()
            try await validateSocketDeviceAvailable(on: vm)
            try await waitForGuestAgentDuringBootstrap(port: agentPort)
            try await configureGuestNetworkingIfNeeded(containerConfig: config, agentPort: agentPort)
            lifecycle.complete(.start, succeeded: true)
            log.info("vm started", metadata: ["state": "\(state.rawValue)", "agent_port": "\(agentPort)"])
        } catch {
            if let vm, vm.state != .stopped {
                try? await stopVirtualMachine(vm)
            }
            await discardVirtualMachineResources()
            lifecycle.complete(.start, succeeded: false)
            throw error
        }
    }

    func stopVM() async throws {
        log.info("stopVM requested", metadata: ["state": "\(state.rawValue)", "has_window": "\(vmWindow != nil)"])
        let shouldStop = try lifecycle.begin(.stop)
        if !shouldStop {
            if state == .stopped {
                await discardVirtualMachineResources()
            }
            return
        }
        guard let vm else {
            await discardVirtualMachineResources()
            lifecycle.complete(.stop, succeeded: true)
            return
        }
        do {
            try await stopVirtualMachine(vm)
            await discardVirtualMachineResources()
            lifecycle.complete(.stop, succeeded: true)
            log.info("vm stopped", metadata: ["state": "\(state.rawValue)"])
        } catch {
            lifecycle.complete(.stop, succeeded: false)
            throw error
        }
    }

    func capabilities() async -> MacOSSidecarCapabilities {
        let capability: MacOSMachineStateCapability
        #if arch(arm64)
        do {
            let configuration = try await ensurePreparedConfiguration()
            try configuration.validateSaveRestoreSupport()
            capability = .init(supported: true)
        } catch let error as SidecarRPCError {
            capability = .init(
                supported: false,
                unsupportedReason: .init(code: error.code, message: error.message)
            )
        } catch {
            capability = .init(
                supported: false,
                unsupportedReason: .init(
                    code: "unsupportedVMConfiguration",
                    message: (error as NSError).localizedDescription,
                    configurationComponent: "virtualMachineConfiguration"
                )
            )
        }
        #else
        capability = .init(
            supported: false,
            unsupportedReason: .init(
                code: "unsupportedHostArchitecture",
                message: "machine-state save and restore requires an Apple silicon Mac"
            )
        )
        #endif
        return .init(
            lifecycleState: state,
            machineState: capability,
            methods: [
                MacOSSidecarMethod.vmCapabilities.rawValue,
                MacOSSidecarMethod.vmPause.rawValue,
                MacOSSidecarMethod.vmResume.rawValue,
                MacOSSidecarMethod.vmPrepareCheckpoint.rawValue,
                MacOSSidecarMethod.vmSaveMachineState.rawValue,
                MacOSSidecarMethod.vmMachineStateReceipt.rawValue,
                MacOSSidecarMethod.vmAbortCheckpoint.rawValue,
                MacOSSidecarMethod.vmStorageAttachments.rawValue,
                MacOSSidecarMethod.vmRestoreMachineState.rawValue,
                MacOSSidecarMethod.vmDeleteMachineState.rawValue,
                MacOSSidecarMethod.vmCompatibilityDescription.rawValue,
                MacOSSidecarMethod.vmStop.rawValue,
                MacOSSidecarMethod.eventsSubscribe.rawValue,
                MacOSSidecarMethod.eventsAcknowledge.rawValue,
            ]
        )
    }

    func acquireProcessStartAdmission() throws -> UUID {
        try lifecycle.acquireProcessStartAdmission()
    }

    func releaseProcessStartAdmission(_ token: UUID) {
        lifecycle.releaseProcessStartAdmission(token)
    }

    func _testSetLifecycleRunning() throws {
        let shouldStart = try lifecycle.begin(.start)
        if shouldStart {
            lifecycle.complete(.start, succeeded: true)
        }
    }

    func pauseVM(timeoutSeconds: Double? = nil) async throws -> MacOSMachineStateOperationResult {
        try validateOperationTimeout(timeoutSeconds)
        let shouldPause = try lifecycle.begin(.pause)
        guard shouldPause else { return .init(lifecycleState: state) }
        guard let vm else {
            lifecycle.complete(.pause, succeeded: false)
            throw SidecarRPCError(code: "invalidLifecycleState", message: "VM instance is unavailable")
        }
        do {
            try await pauseVirtualMachine(vm)
            lifecycle.complete(.pause, succeeded: true)
            return .init(lifecycleState: state)
        } catch {
            lifecycle.complete(.pause, succeeded: false)
            throw error
        }
    }

    func resumeVM(timeoutSeconds: Double? = nil) async throws -> MacOSMachineStateOperationResult {
        try validateOperationTimeout(timeoutSeconds)
        let shouldResume = try lifecycle.begin(.resume)
        guard shouldResume else {
            return .init(lifecycleState: state, stateID: lifecycle.activeStateID)
        }
        guard let vm else {
            lifecycle.complete(.resume, succeeded: false)
            throw SidecarRPCError(code: "invalidLifecycleState", message: "VM instance is unavailable")
        }
        do {
            try await resumeVirtualMachine(vm)
            lifecycle.complete(.resume, succeeded: true)
            return .init(lifecycleState: state, stateID: lifecycle.activeStateID)
        } catch {
            lifecycle.complete(.resume, succeeded: false)
            throw error
        }
    }

    func saveMachineState(
        stateID: String,
        timeoutSeconds: Double?,
        adoption: MacOSMachineStateAdoptionManifest? = nil,
        pair: MacOSMachineStateDurablePair? = nil
    ) async throws -> MacOSMachineStateOperationResult {
        try validateOperationTimeout(timeoutSeconds)
        let store = try machineStateStore()
        try MacOSMachineStateStore.validateStateID(stateID)
        guard (adoption == nil) == (pair == nil) else {
            throw SidecarRPCError(
                code: "invalidArgument",
                message: "durable-pair save requires both adoption manifest and pair"
            )
        }
        try lifecycle.ensureNoOperationInProgress()
        do {
            let stored = try store.load(stateID: stateID)
            try MacOSMachineIdentityBundleStore.verify(in: stored.directoryURL)
            let current = try await currentCompatibilityDescription()
            let reasons = MacOSMachineStateCompatibility.compare(saved: stored.compatibility, current: current)
            guard reasons.isEmpty else {
                throw compatibilityMismatchError(reasons)
            }
            try MacOSMachineStateStorageGeneration.validateIdempotentSave(
                saved: stored.compatibility,
                current: current
            )
            if let pair {
                guard stored.receipt?.pair == pair, stored.receipt?.adoption == adoption else {
                    throw SidecarRPCError(
                        code: "durablePairMismatch",
                        message: "existing machine state belongs to a different durable pair"
                    )
                }
            }
            return .init(
                lifecycleState: state,
                stateID: stateID,
                compatibility: stored.compatibility,
                receipt: stored.receipt
            )
        } catch let error as SidecarRPCError where error.code == "machineStateNotFound" {
            // A missing state is the expected first-save path.
        }

        #if arch(arm64)
        let configuration = try await ensurePreparedConfiguration()
        try configuration.validateSaveRestoreSupport()
        let compatibility = try await currentCompatibilityDescription()
        if let adoption, let pair {
            guard pair.stateID == stateID,
                pair.persistenceID == adoption.persistenceID,
                pair.stateGeneration == adoption.sourceStorageGeneration,
                pair.diskSnapshot.storageGeneration == pair.stateGeneration,
                compatibility.storageGeneration == pair.stateGeneration
            else {
                throw SidecarRPCError(
                    code: "durablePairMismatch",
                    message: "durable pair does not match the paused VM storage generation"
                )
            }
        }
        let shouldSave = try lifecycle.begin(.save, stateID: stateID)
        guard shouldSave else {
            return .init(lifecycleState: state, stateID: stateID, compatibility: compatibility)
        }
        guard let vm else {
            lifecycle.complete(.save, succeeded: false)
            throw SidecarRPCError(code: "invalidLifecycleState", message: "VM instance is unavailable")
        }

        let reservation: MacOSMachineStateStore.Reservation
        do {
            reservation = try store.reserve(stateID: stateID)
        } catch {
            lifecycle.complete(.save, succeeded: false)
            throw error
        }
        do {
            try MacOSMachineIdentityBundleStore.capture(from: rootURL, into: reservation.directoryURL)
            try await saveVirtualMachine(vm, to: reservation.stateURL)
            try MacOSMachineIdentityBundleStore.verify(in: reservation.directoryURL)
            let receipt: MacOSMachineStateReceipt?
            if let adoption, let pair {
                receipt = try store.commit(
                    reservation,
                    compatibility: compatibility,
                    adoption: adoption,
                    pair: pair
                )
            } else {
                try store.commit(reservation, compatibility: compatibility)
                receipt = nil
            }
            lifecycle.complete(.save, succeeded: true)
            return .init(
                lifecycleState: state,
                stateID: stateID,
                compatibility: compatibility,
                receipt: receipt
            )
        } catch {
            store.abort(reservation)
            lifecycle.complete(.save, succeeded: false)
            throw error
        }
        #else
        throw SidecarRPCError(code: "unsupportedHostArchitecture", message: "machine-state save requires an Apple silicon Mac")
        #endif
    }

    func restoreMachineState(stateID: String, timeoutSeconds: Double?) async throws -> MacOSMachineStateOperationResult {
        try validateOperationTimeout(timeoutSeconds)
        #if arch(arm64)
        let config = try loadContainerConfiguration()
        if let requested = config.macosGuest?.machineState {
            guard requested.restoreStateID == stateID,
                requested.restoreStateGeneration != nil
            else {
                throw SidecarRPCError(
                    code: "machineStateRequestMismatch",
                    message: "restore request does not match the configured machine state"
                )
            }
        }
        let store = try machineStateStore(containerConfig: config)
        let stored = try store.load(stateID: stateID)
        if let requested = config.macosGuest?.machineState,
            requested.protocolVersion >= MacOSSidecarProtocolVersion.durableCheckpointAdoption
        {
            guard let receipt = stored.receipt,
                requested.pairID == receipt.pair.pairID,
                requested.adoptionManifestDigest == receipt.pair.adoptionManifestDigest,
                requested.persistenceID == receipt.pair.persistenceID,
                requested.restoreStateGeneration == receipt.pair.stateGeneration
            else {
                throw SidecarRPCError(
                    code: "durablePairMismatch",
                    message: "configured restore contract does not match the committed durable pair"
                )
            }
        }
        try MacOSMachineStateStorageGeneration.validateRestore(
            saved: stored.compatibility,
            selectedSavedGeneration: config.macosGuest?.machineState?.restoreStateGeneration
        )
        let configuration = try await ensurePreparedConfiguration()
        try configuration.validateSaveRestoreSupport()
        let current = try await currentCompatibilityDescription()
        let reasons = MacOSMachineStateCompatibility.compare(saved: stored.compatibility, current: current)
        guard reasons.isEmpty else {
            throw compatibilityMismatchError(reasons)
        }

        let shouldRestore = try lifecycle.begin(.restore, stateID: stateID)
        guard shouldRestore else {
            return .init(
                lifecycleState: state,
                stateID: stateID,
                compatibility: stored.compatibility,
                receipt: stored.receipt
            )
        }
        do {
            if vm == nil {
                let created = try await createVirtualMachineOnMain(configuration: configuration)
                vm = created.vm
                vmDelegate = created.delegate
            }
            guard let vm else {
                throw SidecarRPCError(code: "invalidLifecycleState", message: "VM instance is unavailable")
            }
            try await restoreVirtualMachine(vm, from: stored.stateURL)
            try await activatePreparedNetworks()
            lifecycle.complete(.restore, succeeded: true)
            return .init(
                lifecycleState: state,
                stateID: stateID,
                compatibility: stored.compatibility,
                receipt: stored.receipt
            )
        } catch {
            if let vm, vm.state != .stopped {
                try? await stopVirtualMachine(vm)
            }
            await discardVirtualMachineResources()
            lifecycle.complete(.restore, succeeded: false)
            throw error
        }
        #else
        throw SidecarRPCError(code: "unsupportedHostArchitecture", message: "machine-state restore requires an Apple silicon Mac")
        #endif
    }

    func deleteMachineState(stateID: String) throws -> MacOSMachineStateDeleteResult {
        try MacOSMachineStateStore.validateStateID(stateID)
        try lifecycle.ensureStateCanBeDeleted(stateID)
        let deleted = try machineStateStore().delete(stateID: stateID)
        return .init(stateID: stateID, deleted: deleted)
    }

    func machineStateReceipt(stateID: String) throws -> MacOSMachineStateReceipt {
        try MacOSMachineStateStore.validateStateID(stateID)
        return try machineStateStore().receipt(stateID: stateID)
    }

    func storageAttachments() -> [MacOSStorageAttachmentStatus] {
        nbdObservers.map { $0.status() }
    }

    func compatibilityDescription(stateID: String? = nil) async throws -> MacOSMachineStateCompatibilityResult {
        let current = try await currentCompatibilityDescription()
        guard let stateID else {
            return .init(current: current, compatible: true)
        }
        let saved = try machineStateStore().load(stateID: stateID).compatibility
        let reasons = MacOSMachineStateCompatibility.compare(saved: saved, current: current)
        return .init(current: current, saved: saved, compatible: reasons.isEmpty, reasons: reasons)
    }

    private func currentCompatibilityDescription() async throws -> MacOSMachineStateCompatibilityDescription {
        _ = try await ensurePreparedConfiguration()
        guard let currentCompatibility else {
            throw SidecarRPCError(code: "compatibilityDescriptionUnavailable", message: "VM compatibility description is unavailable")
        }
        return currentCompatibility
    }

    private func ensurePreparedConfiguration() async throws -> VZVirtualMachineConfiguration {
        if let vmConfiguration { return vmConfiguration }
        let containerConfig = try loadContainerConfiguration()
        if let machineState = containerConfig.macosGuest?.machineState,
            let stateID = machineState.restoreStateID
        {
            let stored = try machineStateStore(containerConfig: containerConfig).load(stateID: stateID)
            try MacOSMachineIdentityBundleStore.materialize(from: stored.directoryURL, into: rootURL)
        }
        let configuration = try await makeVirtualMachineConfiguration(containerConfig: containerConfig)
        vmConfiguration = configuration
        return configuration
    }

    func machineStateStore(
        containerConfig: ContainerConfiguration? = nil
    ) throws -> MacOSMachineStateStore {
        let config = try containerConfig ?? loadContainerConfiguration()
        let storeRoot = try persistentMachineStateRoot(containerConfig: config) ?? rootURL
        return MacOSMachineStateStore(runtimeRootURL: storeRoot)
    }

    private func persistentMachineStateRoot(containerConfig: ContainerConfiguration) throws -> URL? {
        guard let machineState = containerConfig.macosGuest?.machineState else { return nil }
        guard
            machineState.protocolVersion == MacOSSidecarProtocolVersion.machineState
                || machineState.protocolVersion == MacOSSidecarProtocolVersion.durableCheckpointAdoption
        else {
            throw SidecarRPCError(
                code: "protocolVersionMismatch",
                message: "configured machine-state protocol version is unsupported"
            )
        }
        guard let path = MacOSManagedPath.canonicalPath(machineState.storageDirectory) else {
            throw SidecarRPCError(
                code: "unsafeMachineStatePath",
                message: "configured machine-state storage directory is not an absolute canonical path"
            )
        }
        let storeRoot = URL(fileURLWithPath: path, isDirectory: true)
        try MacOSMachineStateStore.preparePersistentRoot(at: storeRoot)
        return storeRoot
    }

    private func compatibilityMismatchError(_ reasons: [MacOSMachineStateUnsupportedReason]) -> SidecarRPCError {
        let reasonCodes = reasons.map(\.code).joined(separator: ",")
        return SidecarRPCError(
            code: "machineStateIncompatible",
            message: "machine state is not compatible with this VM and physical host",
            details: reasonCodes,
            metadata: ["reasonCodes": reasonCodes]
        )
    }

    private func validateOperationTimeout(_ timeoutSeconds: Double?) throws {
        guard let timeoutSeconds else { return }
        guard timeoutSeconds.isFinite, (1...600).contains(timeoutSeconds) else {
            throw SidecarRPCError(code: "invalidTimeout", message: "operation timeout must be between 1 and 600 seconds")
        }
    }

    private func discardVirtualMachineResources() async {
        await closeGUIWindowOnMain()
        vm = nil
        vmConfiguration = nil
        vmDelegate = nil
        currentCompatibility = nil
        nbdObservers = []
        discardPreparedNetworkResources()
    }

    func showGUIWindow() async throws {
        let config = try loadContainerConfiguration()
        log.info(
            "showGUIWindow requested",
            metadata: [
                "id": "\(config.id)",
                "state": "\(state.rawValue)",
                "has_window": "\(vmWindow != nil)",
            ])
        guard config.macosGuest?.guiEnabled == true else {
            throw ContainerizationError(.unsupported, message: "macOS guest GUI is not enabled for this sandbox")
        }
        guard state == .running, let vm else {
            throw ContainerizationError(.invalidState, message: "cannot show GUI window while VM is not running")
        }
        try await presentGUIWindowOnMain(vm: vm, containerID: config.id)
    }

    func connectVsock(port: UInt32) async throws -> Int32 {
        guard let vm else {
            throw ContainerizationError(.invalidState, message: "vm is not running")
        }
        log.info("sidecar connectVsock begin", metadata: ["port": "\(port)"])
        let connection = try await connectSocketOnMainWithTimeout(vm, toPort: port, timeoutSeconds: 3)
        let duplicated = dup(connection.fileDescriptor)
        guard duplicated >= 0 else {
            throw makePOSIXError(errno)
        }
        connection.close()
        return duplicated
    }

    private func waitForGuestAgentReadyWithTimeout(fd: Int32, timeoutSeconds: TimeInterval) throws {
        let deadline = sidecarReadDeadline(timeoutSeconds: timeoutSeconds)
        do {
            while true {
                let frame = try MacOSSidecarSocketIO.readJSONFrame(
                    SidecarGuestAgentFrame.self,
                    fd: fd,
                    timeoutMilliseconds: try sidecarRemainingReadMilliseconds(until: deadline)
                )
                switch frame.type {
                case .ready:
                    return
                case .error:
                    throw ContainerizationError(.internalError, message: "guest-agent error before ready: \(frame.message ?? "unknown error")")
                case .exit:
                    throw ContainerizationError(.internalError, message: "guest-agent exited before ready (code=\(frame.exitCode ?? 1))")
                case .stdout, .stderr, .ack, .exec, .processInspect, .processAttach, .processEventAck, .processStop,
                    .processDelete, .stdin, .signal, .resize, .close, .networkConfigure, .networkResult,
                    .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd, .fsListDir:
                    continue
                }
            }
        } catch  where isSidecarReadTimeout(error) {
            throw ContainerizationError(.timeout, message: "timed out waiting for guest-agent ready frame")
        }
    }

    private func waitForGuestAgentDuringBootstrap(port: UInt32) async throws {
        try await GuestAgentBootstrapRetrier.run(
            maxAttempts: Self.bootstrapGuestAgentMaxAttempts,
            retryDelayNanoseconds: Self.bootstrapGuestAgentRetryDelayNanoseconds
        ) { [self] attempt, maxAttempts in
            if shouldLogBootstrapGuestAgentAttempt(attempt, maxAttempts: maxAttempts) {
                log.info(
                    "bootstrap guest-agent probe attempt",
                    metadata: [
                        "attempt": "\(attempt)",
                        "max_attempts": "\(maxAttempts)",
                        "port": "\(port)",
                    ]
                )
            }

            let fd = try await connectVsock(port: port)
            defer {
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }

            do {
                try await self.waitForGuestAgentReadyWithTimeout(
                    fd: fd,
                    timeoutSeconds: Self.bootstrapGuestAgentReadyTimeoutSeconds
                )
                if shouldLogBootstrapGuestAgentAttempt(attempt, maxAttempts: maxAttempts) {
                    log.info(
                        "bootstrap guest-agent probe succeeded",
                        metadata: [
                            "attempt": "\(attempt)",
                            "max_attempts": "\(maxAttempts)",
                            "port": "\(port)",
                        ]
                    )
                }
            } catch {
                if shouldLogBootstrapGuestAgentAttempt(attempt, maxAttempts: maxAttempts) {
                    log.warning(
                        "bootstrap guest-agent probe failed",
                        metadata: [
                            "attempt": "\(attempt)",
                            "max_attempts": "\(maxAttempts)",
                            "port": "\(port)",
                            "error": "\(error)",
                        ]
                    )
                }
                throw error
            }
        }
    }

    private func configureGuestNetworkingIfNeeded(
        containerConfig: ContainerConfiguration,
        agentPort: UInt32
    ) async throws {
        guard
            let request = try MacOSGuestNetworkBootstrap.makeRequest(
                containerConfig: containerConfig,
                lease: networkLease
            )
        else {
            return
        }

        let fd = try await connectVsock(port: agentPort)
        defer {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }

        try waitForGuestAgentReadyWithTimeout(
            fd: fd,
            timeoutSeconds: Self.bootstrapGuestAgentReadyTimeoutSeconds
        )
        try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame.networkConfigure(request), fd: fd)

        while true {
            let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
            switch frame.type {
            case .networkResult:
                let result = try decodeGuestNetworkConfigurationResult(frame)
                try MacOSGuestNetworkBootstrap.validateResult(result, for: request)
                log.info(
                    "guest network configuration applied",
                    metadata: [
                        "interfaces": "\(result.interfaces.count)",
                        "dns_applied": "\(result.dnsApplied)",
                        "dns_service_id": "\(result.effectiveDNS?.serviceID ?? "none")",
                        "dns_interface": "\(result.effectiveDNS?.interfaceName ?? "none")",
                        "dns_nameservers": "\(result.effectiveDNS?.nameservers.joined(separator: ",") ?? "none")",
                    ]
                )
                for warning in result.warnings {
                    log.warning("guest network configuration warning", metadata: ["warning": "\(warning)"])
                }
                return
            case .error:
                throw ContainerizationError(
                    .internalError,
                    message: "guest network configuration failed: \(frame.message ?? "unknown error")"
                )
            case .exit:
                throw ContainerizationError(
                    .internalError,
                    message: "guest network configuration stream exited unexpectedly (code=\(frame.exitCode ?? 1))"
                )
            case .ready, .ack, .stdout, .stderr, .exec, .processInspect, .processAttach, .processEventAck, .processStop,
                .processDelete, .stdin, .signal, .resize, .close, .networkConfigure, .fsBegin, .fsChunk, .fsEnd,
                .fsReadBegin, .fsReadChunk, .fsReadEnd, .fsListDir:
                continue
            }
        }
    }

    private func decodeGuestNetworkConfigurationResult(
        _ frame: SidecarGuestAgentFrame
    ) throws -> MacOSGuestNetworkConfigurationResult {
        guard let data = frame.data else {
            throw ContainerizationError(.invalidState, message: "guest network configuration result missing payload")
        }
        return try JSONDecoder().decode(MacOSGuestNetworkConfigurationResult.self, from: data)
    }

    func prepareForQuit() async throws {
        log.info("prepareForQuit requested", metadata: ["state": "\(state.rawValue)", "has_window": "\(vmWindow != nil)"])
        try await stopVM()
    }

    private func configPath() -> URL { rootURL.appendingPathComponent("config.json") }
    private func auxiliaryStoragePath(containerConfig: ContainerConfiguration) throws -> URL {
        guard let identityDirectory = try persistentIdentityDirectory(containerConfig: containerConfig) else {
            return rootURL.appendingPathComponent("AuxiliaryStorage")
        }
        let target = identityDirectory.appendingPathComponent("AuxiliaryStorage")
        if !FileManager.default.fileExists(atPath: target.path) {
            let source = rootURL.appendingPathComponent("AuxiliaryStorage")
            var sourceValue = stat()
            guard lstat(source.path, &sourceValue) == 0, (sourceValue.st_mode & S_IFMT) == S_IFREG else {
                throw SidecarRPCError(
                    code: "unsafeMachineStatePath",
                    message: "sandbox auxiliary storage must be a regular file"
                )
            }
            let temporary = identityDirectory.appendingPathComponent(".AuxiliaryStorage.\(UUID().uuidString).tmp")
            do {
                try FileManager.default.copyItem(at: source, to: temporary)
                guard chmod(temporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try FileManager.default.moveItem(at: temporary, to: target)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
        try requirePrivateRegularIdentityFile(target)
        return target
    }
    private func hardwareModelPath() -> URL { rootURL.appendingPathComponent("HardwareModel.bin") }
    private func machineIdentifierPath(containerConfig: ContainerConfiguration) throws -> URL {
        guard let identityDirectory = try persistentIdentityDirectory(containerConfig: containerConfig) else {
            return rootURL.appendingPathComponent("MachineIdentifier.bin")
        }
        return identityDirectory.appendingPathComponent("MachineIdentifier.bin")
    }

    func persistentIdentityDirectory(containerConfig: ContainerConfiguration) throws -> URL? {
        guard let storage = try persistentMachineStateRoot(containerConfig: containerConfig) else { return nil }
        let identity = storage.appendingPathComponent("Identity", isDirectory: true)
        try MacOSMachineStateStore.preparePersistentRoot(at: identity)
        return identity
    }

    private func requirePrivateRegularIdentityFile(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            throw SidecarRPCError(code: "unsafeMachineStatePath", message: "persistent identity file is not regular")
        }
        guard chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func loadContainerConfiguration() throws -> ContainerConfiguration {
        let data = try Data(contentsOf: configPath())
        return try JSONDecoder().decode(ContainerConfiguration.self, from: data)
    }

    private func makeVirtualMachineConfiguration(containerConfig: ContainerConfiguration) async throws -> VZVirtualMachineConfiguration {
        let storage = try MacOSBlockDeviceBuilder.build(rootURL: rootURL, options: containerConfig.macosGuest, log: log)
        let hardwareData = try Data(contentsOf: hardwareModelPath())
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw ContainerizationError(.invalidState, message: "invalid hardware model data")
        }
        let machineIdentifier = try loadOrCreateMachineIdentifier(at: machineIdentifierPath(containerConfig: containerConfig))

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: try auxiliaryStoragePath(containerConfig: containerConfig))

        let vmConfiguration = VZVirtualMachineConfiguration()
        vmConfiguration.bootLoader = VZMacOSBootLoader()
        vmConfiguration.platform = platform
        vmConfiguration.cpuCount = max(
            Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            min(Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount), containerConfig.resources.cpus)
        )
        vmConfiguration.memorySize = max(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(VZVirtualMachineConfiguration.maximumAllowedMemorySize, containerConfig.resources.memoryInBytes)
        )
        vmConfiguration.storageDevices = storage.devices
        nbdObservers = storage.observers
        let networkBackend = MacOSNetworkBackendFactory.backend(for: containerConfig)
        log.info("resolved macOS guest network backend", metadata: ["backend": "\(networkBackend.backendID.rawValue)"])
        let existingLease = try MacOSGuestNetworkLeaseStore.load(from: rootURL)
        let preparedNetwork = try await networkBackend.prepareNetwork(
            containerConfig: containerConfig,
            existingLease: existingLease,
            virtualMachineIdentity: machineIdentifier.dataRepresentation,
            log: log
        )
        networkLease = preparedNetwork.lease
        ownedVMNetNetworks = preparedNetwork.ownedNetworks
        networkSessions = preparedNetwork.sessions
        networkActivations = preparedNetwork.activations
        if let lease = preparedNetwork.lease {
            try MacOSGuestNetworkLeaseStore.save(lease, in: rootURL)
        } else {
            try MacOSGuestNetworkLeaseStore.remove(from: rootURL)
        }
        vmConfiguration.networkDevices = preparedNetwork.devices
        vmConfiguration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        vmConfiguration.directorySharingDevices = try createDirectorySharingDevices(containerConfig: containerConfig)
        vmConfiguration.graphicsDevices = [createGraphicsDevice()]
        if containerConfig.macosGuest?.guiEnabled == true {
            vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
            vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
        try vmConfiguration.validate()
        currentCompatibility = try MacOSCompatibilityDescriptionBuilder.make(
            containerConfig: containerConfig,
            hardwareModelData: hardwareData,
            machineIdentifierData: machineIdentifier.dataRepresentation,
            networkDeviceMACAddresses: preparedNetwork.devices.compactMap {
                ($0 as? VZVirtioNetworkDeviceConfiguration)?.macAddress.description
            },
            storageDescriptions: storage.descriptions
        )
        return vmConfiguration
    }

    private func discardPreparedNetworkResources() {
        let lease = networkLease ?? (try? MacOSGuestNetworkLeaseStore.load(from: rootURL)) ?? nil
        networkLease = nil
        networkActivations = []
        for session in networkSessions {
            session.close()
        }
        networkSessions = []
        ownedVMNetNetworks = []
        guard let lease else {
            return
        }
        log.info("discarded prepared macOS guest network resources", metadata: ["interfaces": "\(lease.interfaces.count)"])
    }

    private func activatePreparedNetworks() async throws {
        for activation in networkActivations {
            log.info("activating macOS guest network data plane", metadata: ["network": "\(activation.network)"])
            try await activation.activate()
        }
    }

    private func createDirectorySharingDevices(
        containerConfig: ContainerConfiguration
    ) throws -> [VZDirectorySharingDeviceConfiguration] {
        let shares = try MacOSGuestMountMapping.hostPathShares(from: containerConfig.mounts)
        guard !shares.isEmpty else {
            return []
        }

        let directories = Dictionary(
            uniqueKeysWithValues: shares.map { share in
                (
                    share.name,
                    VZSharedDirectory(
                        url: URL(fileURLWithPath: share.source),
                        readOnly: share.readOnly
                    )
                )
            })

        let fileSystemDevice = VZVirtioFileSystemDeviceConfiguration(
            tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
        )
        fileSystemDevice.share = VZMultipleDirectoryShare(directories: directories)
        return [fileSystemDevice]
    }

    private func createGraphicsDevice() -> VZMacGraphicsDeviceConfiguration {
        let graphics = VZMacGraphicsDeviceConfiguration()
        let applyScreenBackedDisplay = {
            let screen = NSScreen.main ?? NSScreen.screens.first
            if let screen {
                graphics.displays = [
                    VZMacGraphicsDisplayConfiguration(
                        for: screen,
                        sizeInPoints: NSSize(width: 1440, height: 900)
                    )
                ]
            } else {
                graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1440, heightInPixels: 900, pixelsPerInch: 80)]
            }
        }
        if Thread.isMainThread {
            applyScreenBackedDisplay()
        } else {
            DispatchQueue.main.sync(execute: applyScreenBackedDisplay)
        }
        return graphics
    }

    private func presentGUIWindowOnMain(vm: VZVirtualMachine, containerID: String) async throws {
        if let windowBox = vmWindow {
            log.info("presentGUIWindow: reusing existing GUI window", metadata: ["id": "\(containerID)"])
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    let app = NSApplication.shared
                    _ = app.setActivationPolicy(.regular)
                    windowBox.value.makeKeyAndOrderFront(nil)
                    app.activate(ignoringOtherApps: true)
                    continuation.resume()
                }
            }
            return
        }

        let vmBox = UnsafeSendableBox(vm)
        let title = "Container macOS Guest (\(String(containerID.prefix(12))))"
        let service = self
        log.info("presentGUIWindow: creating GUI window", metadata: ["id": "\(containerID)"])
        let created = try await withCheckedThrowingContinuation {
            (
                continuation: CheckedContinuation<
                    (
                        UnsafeSendableBox<NSWindow>,
                        UnsafeSendableBox<VZVirtualMachineView>,
                        UnsafeSendableBox<GUIWindowDelegate>
                    ),
                    Error
                >
            ) in
            DispatchQueue.main.async {
                let app = NSApplication.shared
                let previousFrontmostApp = NSWorkspace.shared.frontmostApplication.map(UnsafeSendableBox.init)
                guard app.setActivationPolicy(.regular) else {
                    continuation.resume(
                        throwing: ContainerizationError(.internalError, message: "failed to enable GUI activation policy")
                    )
                    return
                }

                let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
                let window = NSWindow(
                    contentRect: frame,
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = title
                window.minSize = NSSize(width: 800, height: 500)
                window.center()

                let vmView = VZVirtualMachineView(frame: frame)
                vmView.virtualMachine = vmBox.value
                vmView.capturesSystemKeys = true
                vmView.autoresizingMask = [.width, .height]

                window.contentView = vmView
                let delegate = GUIWindowDelegate {
                    Task {
                        await service.handleManualGUIWindowClose(previousFrontmostApp: previousFrontmostApp)
                    }
                }
                window.delegate = delegate
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                continuation.resume(
                    returning: (
                        UnsafeSendableBox(window),
                        UnsafeSendableBox(vmView),
                        UnsafeSendableBox(delegate)
                    )
                )
            }
        }
        vmWindow = created.0
        vmWindowView = created.1
        vmWindowDelegate = created.2
    }

    private func closeGUIWindowOnMain() async {
        let windowBox = vmWindow
        vmWindow = nil
        vmWindowView = nil
        vmWindowDelegate = nil
        guard let windowBox else {
            log.info("closeGUIWindow skipped; no GUI window", metadata: ["state": "\(state.rawValue)"])
            return
        }
        log.info("closeGUIWindow closing GUI window", metadata: ["state": "\(state.rawValue)"])

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                windowBox.value.delegate = nil
                windowBox.value.orderOut(nil)
                windowBox.value.contentView = nil
                windowBox.value.close()
                _ = NSApplication.shared.setActivationPolicy(.prohibited)
                continuation.resume()
            }
        }
    }

    private func handleManualGUIWindowClose(
        previousFrontmostApp: UnsafeSendableBox<NSRunningApplication>?
    ) async {
        log.info("manual GUI window close", metadata: ["state": "\(state.rawValue)", "vm_present": "\(vm != nil)"])
        vmWindow = nil
        vmWindowView = nil
        vmWindowDelegate = nil

        await MainActor.run {
            _ = NSApplication.shared.setActivationPolicy(.prohibited)
            if let previousFrontmostApp, !previousFrontmostApp.value.isTerminated {
                _ = previousFrontmostApp.value.activate(options: [])
            }
        }
    }

    private func loadOrCreateMachineIdentifier(at path: URL) throws -> VZMacMachineIdentifier {
        if FileManager.default.fileExists(atPath: path.path) {
            try requirePrivateRegularIdentityFile(path)
            let data = try Data(contentsOf: path)
            if let value = VZMacMachineIdentifier(dataRepresentation: data) {
                return value
            }
        }
        let value = VZMacMachineIdentifier()
        try value.dataRepresentation.write(to: path, options: .atomic)
        try requirePrivateRegularIdentityFile(path)
        return value
    }

    private func startVirtualMachine(_ vm: VZVirtualMachine) async throws {
        // Virtualization callbacks must be invoked on the main queue. We wrap the VM reference
        // so the compiler knows we are intentionally transferring it to that queue.
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vmBox.value.start { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func createVirtualMachineOnMain(configuration: VZVirtualMachineConfiguration) async throws -> CreatedVM {
        let configurationBox = UnsafeSendableBox(configuration)
        let log = self.log
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CreatedVM, Error>) in
            DispatchQueue.main.async {
                log.info("creating vm on main thread")
                let vm = VZVirtualMachine(configuration: configurationBox.value)
                let delegate = VMDelegate(log: log)
                vm.delegate = delegate
                continuation.resume(returning: CreatedVM(vm: vm, delegate: delegate))
            }
        }
    }

    private func stopVirtualMachine(_ vm: VZVirtualMachine) async throws {
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vmBox.value.stop { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    private func pauseVirtualMachine(_ vm: VZVirtualMachine) async throws {
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vmBox.value.pause { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func resumeVirtualMachine(_ vm: VZVirtualMachine) async throws {
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vmBox.value.resume { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    #if arch(arm64)
    private func saveVirtualMachine(_ vm: VZVirtualMachine, to url: URL) async throws {
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vmBox.value.saveMachineStateTo(url: url) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    private func restoreVirtualMachine(_ vm: VZVirtualMachine, from url: URL) async throws {
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vmBox.value.restoreMachineStateFrom(url: url) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }
    #endif

    private func connectSocketOnMainWithTimeout(
        _ vm: VZVirtualMachine,
        toPort port: UInt32,
        timeoutSeconds: TimeInterval
    ) async throws -> VZVirtioSocketConnection {
        let vmBox = UnsafeSendableBox(vm)
        let log = self.log
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VZVirtioSocketConnection, Error>) in
            let gate = CompletionGate()
            if timeoutSeconds > 0 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                    guard gate.tryComplete() else { return }
                    log.error("sidecar vsock connect callback timed out", metadata: ["port": "\(port)"])
                    continuation.resume(
                        throwing: ContainerizationError(
                            .timeout,
                            message: "timed out waiting for vsock connect callback on port \(port)"
                        )
                    )
                }
            }
            DispatchQueue.main.async {
                log.info("sidecar issuing vsock connect on main queue", metadata: ["port": "\(port)"])
                guard let socketDevice = vmBox.value.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
                    log.error("sidecar vsock connect missing socket device", metadata: ["port": "\(port)"])
                    guard gate.tryComplete() else { return }
                    continuation.resume(
                        throwing: ContainerizationError(.invalidState, message: "vm socket device unavailable on main thread")
                    )
                    return
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let connection):
                        log.info("sidecar vsock connect callback succeeded", metadata: ["port": "\(port)"])
                        guard gate.tryComplete() else {
                            connection.close()
                            return
                        }
                        nonisolated(unsafe) let unsafeConnection = connection
                        continuation.resume(returning: unsafeConnection)
                    case .failure(let error):
                        log.error("sidecar vsock connect callback failed", metadata: ["port": "\(port)", "error": "\(error)"])
                        guard gate.tryComplete() else { return }
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func validateSocketDeviceAvailable(on vm: VZVirtualMachine) async throws {
        let vmBox = UnsafeSendableBox(vm)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let hasSocketDevice = vmBox.value.socketDevices.contains { $0 is VZVirtioSocketDevice }
                if hasSocketDevice {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ContainerizationError(.invalidState, message: "vm socket device is unavailable"))
                }
            }
        }
    }

    private nonisolated func waitForGuestAgentReady(fd: Int32) throws {
        while true {
            let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
            switch frame.type {
            case .ready:
                return
            case .error:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent error before ready: \(frame.message ?? "unknown error")"
                )
            case .exit:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent exited before ready (code=\(frame.exitCode ?? 1))"
                )
            case .stdout, .stderr, .ack, .exec, .processInspect, .processAttach, .processEventAck, .processStop, .processDelete,
                .stdin, .signal, .resize, .close, .networkConfigure, .networkResult, .fsBegin, .fsChunk, .fsEnd,
                .fsReadBegin, .fsReadChunk, .fsReadEnd, .fsListDir:
                continue
            }
        }
    }
}

final class SidecarControlServer: @unchecked Sendable {
    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private struct BoundSocketIdentity: Sendable {
        let device: dev_t
        let inode: ino_t
    }

    private struct ProcessStartHandshake {
        let bufferedFrames: [SidecarGuestAgentFrame]
        let status: MacOSGuestProcessStatusPayload?
    }

    private struct ActiveCheckpoint {
        let result: MacOSMachineStateCheckpointResult
        let sourcePodUID: String?
    }

    private struct ProcessLaunchIdentity: Codable {
        let executable: String
        let arguments: [String]
        let environment: [String]?
        let rootDirectory: String?
        let workingDirectory: String?
        let terminal: Bool
        let user: String?
        let uid: UInt32?
        let gid: UInt32?
        let supplementalGroups: [UInt32]?
        let durableExecutionID: String?
        let durableLaunchFingerprint: String?
        let durableIncarnation: String?
        let storageGeneration: UInt64?
        let previousStorageGeneration: UInt64?

        init(_ exec: MacOSSidecarExecRequestPayload) {
            self.executable = exec.executable
            self.arguments = exec.arguments
            self.environment = exec.environment
            self.rootDirectory = exec.rootDirectory
            self.workingDirectory = exec.workingDirectory
            self.terminal = exec.terminal
            self.user = exec.user
            self.uid = exec.uid
            self.gid = exec.gid
            self.supplementalGroups = exec.supplementalGroups
            self.durableExecutionID = exec.durableExecutionID
            self.durableLaunchFingerprint = exec.durableLaunchFingerprint
            self.durableIncarnation = exec.durableIncarnation
            self.storageGeneration = exec.storageGeneration
            self.previousStorageGeneration = exec.previousStorageGeneration
        }
    }

    private struct ProcessStreamConnection: Equatable, Sendable {
        let fd: Int32
        let readerFD: Int32
        let generation: UInt64
    }

    private struct ProcessReconnectIdentityError: LocalizedError {
        let reason: String

        var errorDescription: String? { reason }
    }

    private final class ProcessStreamSession: @unchecked Sendable {
        let processID: String
        let guestProcessID: String
        let durable: Bool
        let requestFingerprint: String
        let port: UInt32
        let launchFingerprint: String?
        let storageGeneration: UInt64?
        let processIdentifier: Int32?
        let trustedLaunchFingerprint: String?
        let incarnation: String?

        private let stateLock = NSLock()
        private let writeQueue: DispatchQueue
        private let writeTimeoutMilliseconds: Int32
        private var connection: ProcessStreamConnection?
        private var nextConnectionGeneration: UInt64 = 2
        private var cancelled = false
        private var terminal = false
        private var reconnecting = false
        private var reconnectBlocked = false
        private var deletePending = false
        private var readerStartedGenerations: Set<UInt64> = []
        private var lastDeliveredSequence: UInt64
        private var highestQueuedSequence: UInt64

        init(
            processID: String,
            guestProcessID: String,
            durable: Bool,
            requestFingerprint: String,
            port: UInt32,
            launchFingerprint: String?,
            storageGeneration: UInt64?,
            processIdentifier: Int32?,
            trustedLaunchFingerprint: String?,
            incarnation: String?,
            replayCursor: UInt64,
            fd: Int32,
            writeTimeoutMilliseconds: Int32 = 1_000
        ) throws {
            self.processID = processID
            self.guestProcessID = guestProcessID
            self.durable = durable
            self.requestFingerprint = requestFingerprint
            self.port = port
            self.launchFingerprint = launchFingerprint
            self.storageGeneration = storageGeneration
            self.processIdentifier = processIdentifier
            self.trustedLaunchFingerprint = trustedLaunchFingerprint
            self.incarnation = incarnation
            self.lastDeliveredSequence = replayCursor
            self.highestQueuedSequence = replayCursor
            let readerFD = Darwin.dup(fd)
            guard readerFD >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = Darwin.fcntl(readerFD, F_SETFD, FD_CLOEXEC)
            self.connection = .init(fd: fd, readerFD: readerFD, generation: 1)
            self.writeTimeoutMilliseconds = max(writeTimeoutMilliseconds, 1)
            self.writeQueue = DispatchQueue(label: "container.runtime.macos.sidecar.process-stream.\(processID)")
        }

        func reserve(sequence: UInt64?) -> Bool {
            guard durable else { return true }
            guard let sequence else { return false }
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !cancelled, sequence > lastDeliveredSequence, sequence > highestQueuedSequence else {
                return false
            }
            highestQueuedSequence = sequence
            return true
        }

        func markDelivered(sequence: UInt64?) {
            guard durable, let sequence else { return }
            stateLock.lock()
            if sequence > lastDeliveredSequence {
                lastDeliveredSequence = sequence
            }
            if highestQueuedSequence < lastDeliveredSequence {
                highestQueuedSequence = lastDeliveredSequence
            }
            stateLock.unlock()
        }

        func deliveredCursor() -> UInt64 {
            stateLock.lock()
            let result = lastDeliveredSequence
            stateLock.unlock()
            return result
        }

        func checkpointWorkload(
            expectedStorageGeneration: UInt64
        ) throws -> MacOSMachineStateAdoptionWorkload {
            guard durable,
                let launchFingerprint,
                let trustedLaunchFingerprint,
                let incarnation,
                let storageGeneration,
                let processIdentifier,
                storageGeneration == expectedStorageGeneration
            else {
                throw SidecarRPCError(
                    code: "checkpointWorkloadUnavailable",
                    message: "process \(processID) does not expose a complete durable identity"
                )
            }
            return .init(
                runtimeWorkloadID: processID,
                guestProcessID: guestProcessID,
                trustedLaunchFingerprint: trustedLaunchFingerprint,
                guestLaunchFingerprint: launchFingerprint,
                processIncarnation: incarnation,
                storageGeneration: storageGeneration,
                processIdentifier: processIdentifier,
                lastPersistedEventSequence: deliveredCursor()
            )
        }

        func acknowledgeDeliveredEvent(sequence: UInt64?) throws {
            guard durable, let sequence else { return }
            markDelivered(sequence: sequence)

            try writeQueue.sync {
                stateLock.lock()
                let current = connection
                let closeAfterWrite = terminal
                let unavailable = cancelled || deletePending
                stateLock.unlock()
                guard !unavailable, let current else { return }

                defer {
                    if closeAfterWrite {
                        stateLock.lock()
                        let shouldClose = connection == current
                        let closeUnclaimedReader = shouldClose && !readerStartedGenerations.contains(current.generation)
                        if shouldClose {
                            connection = nil
                        }
                        stateLock.unlock()
                        if shouldClose {
                            _ = Darwin.shutdown(current.fd, SHUT_RDWR)
                            Darwin.close(current.fd)
                            if closeUnclaimedReader {
                                Darwin.close(current.readerFD)
                            }
                        }
                    }
                }
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame.processEventAck(id: guestProcessID, sequence: sequence),
                    fd: current.fd,
                    timeoutMilliseconds: 1_000
                )
            }
        }

        func currentConnection() -> ProcessStreamConnection? {
            stateLock.lock()
            let result = connection
            stateLock.unlock()
            return result
        }

        func claimReader(_ expected: ProcessStreamConnection) -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard connection == expected, !readerStartedGenerations.contains(expected.generation) else {
                return false
            }
            readerStartedGenerations.insert(expected.generation)
            return true
        }

        func connectionDescriptors() -> (owner: Int32, reader: Int32)? {
            stateLock.lock()
            let result = connection.map { ($0.fd, $0.readerFD) }
            stateLock.unlock()
            return result
        }

        func send(
            _ frame: SidecarGuestAgentFrame,
            timeoutMilliseconds: Int32? = nil
        ) throws {
            try writeQueue.sync {
                stateLock.lock()
                let current = connection
                let unavailable = cancelled || terminal || deletePending
                stateLock.unlock()
                guard !unavailable, let current else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "process \(processID) stream is not attached"
                    )
                }
                try MacOSSidecarSocketIO.writeJSONFrame(
                    frame,
                    fd: current.fd,
                    timeoutMilliseconds: timeoutMilliseconds ?? writeTimeoutMilliseconds
                )
            }
        }

        @discardableResult
        func detach(_ expected: ProcessStreamConnection) -> Bool {
            stateLock.lock()
            guard connection == expected else {
                stateLock.unlock()
                return false
            }
            connection = nil
            let closeUnclaimedReader = !readerStartedGenerations.contains(expected.generation)
            stateLock.unlock()

            _ = Darwin.shutdown(expected.fd, SHUT_RDWR)
            _ = writeQueue.sync {
                Darwin.close(expected.fd)
            }
            if closeUnclaimedReader {
                Darwin.close(expected.readerFD)
            }
            return true
        }

        func beginReconnect() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard durable, !cancelled, !terminal, !reconnectBlocked, !deletePending, connection == nil, !reconnecting else {
                return false
            }
            reconnecting = true
            return true
        }

        func shouldContinueReconnect() -> Bool {
            stateLock.lock()
            let result = durable && !cancelled && !terminal && !reconnectBlocked && !deletePending && connection == nil && reconnecting
            stateLock.unlock()
            return result
        }

        func isReconnectPending() -> Bool {
            stateLock.lock()
            let result = reconnecting
            stateLock.unlock()
            return result
        }

        func installReconnected(fd: Int32, status: MacOSGuestProcessStatusPayload) throws -> ProcessStreamConnection? {
            try writeQueue.sync {
                guard status.executionID == guestProcessID else {
                    throw ProcessReconnectIdentityError(reason: "durable process attach returned a different execution identifier")
                }
                guard status.launchFingerprint == launchFingerprint else {
                    throw ProcessReconnectIdentityError(reason: "durable process launch fingerprint changed during reconnect")
                }
                guard status.trustedLaunchFingerprint == trustedLaunchFingerprint else {
                    throw ProcessReconnectIdentityError(reason: "durable process trusted launch fingerprint changed during reconnect")
                }
                guard status.incarnation == incarnation else {
                    throw ProcessReconnectIdentityError(reason: "durable process incarnation changed during reconnect")
                }
                guard status.storageGeneration == storageGeneration else {
                    throw ProcessReconnectIdentityError(reason: "durable process storage generation changed during reconnect")
                }
                guard status.processIdentifier == processIdentifier else {
                    throw ProcessReconnectIdentityError(reason: "durable process identifier changed during reconnect")
                }

                let readerFD = Darwin.dup(fd)
                guard readerFD >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                _ = Darwin.fcntl(readerFD, F_SETFD, FD_CLOEXEC)

                stateLock.lock()
                defer { stateLock.unlock() }
                guard !cancelled, !terminal, !reconnectBlocked, !deletePending, reconnecting, connection == nil else {
                    reconnecting = false
                    Darwin.close(readerFD)
                    return nil
                }
                let installed = ProcessStreamConnection(fd: fd, readerFD: readerFD, generation: nextConnectionGeneration)
                nextConnectionGeneration &+= 1
                connection = installed
                reconnecting = false
                return installed
            }
        }

        func finishReconnect(blocked: Bool) {
            stateLock.lock()
            reconnecting = false
            if blocked {
                reconnectBlocked = true
            }
            stateLock.unlock()
        }

        func markTerminal() {
            stateLock.lock()
            terminal = true
            reconnecting = false
            stateLock.unlock()
        }

        func startRetryError() -> ContainerizationError? {
            stateLock.lock()
            defer { stateLock.unlock() }
            if cancelled {
                return ContainerizationError(.invalidState, message: "process \(processID) session is cancelled")
            }
            if deletePending {
                return ContainerizationError(.invalidState, message: "process \(processID) durable deletion is pending")
            }
            if terminal {
                return ContainerizationError(.invalidState, message: "process \(processID) is terminal")
            }
            if reconnectBlocked {
                return ContainerizationError(.invalidState, message: "process \(processID) reconnect is permanently blocked")
            }
            return nil
        }

        func matchesDeleteIdentity(_ identity: MacOSSidecarDurableProcessDeleteIdentity) -> Bool {
            durable && guestProcessID == identity.executionID
                && trustedLaunchFingerprint == identity.trustedLaunchFingerprint
                && incarnation == identity.incarnation
                && storageGeneration == identity.storageGeneration
        }

        func prepareForDelete(_ identity: MacOSSidecarDurableProcessDeleteIdentity) throws {
            guard matchesDeleteIdentity(identity) else {
                throw ContainerizationError(.invalidState, message: "durable delete identity does not match the process session")
            }

            stateLock.lock()
            guard !cancelled else {
                stateLock.unlock()
                throw ContainerizationError(.invalidState, message: "process \(processID) session is cancelled")
            }
            deletePending = true
            reconnecting = false
            let current = connection
            connection = nil
            let closeUnclaimedReader = current.map { !readerStartedGenerations.contains($0.generation) } ?? false
            stateLock.unlock()

            guard let current else { return }
            _ = Darwin.shutdown(current.fd, SHUT_RDWR)
            _ = writeQueue.sync {
                Darwin.close(current.fd)
            }
            if closeUnclaimedReader {
                Darwin.close(current.readerFD)
            }
        }

        func cancelAndClose() {
            stateLock.lock()
            cancelled = true
            reconnecting = false
            let current = connection
            connection = nil
            let closeUnclaimedReader = current.map { !readerStartedGenerations.contains($0.generation) } ?? false
            stateLock.unlock()

            if let current {
                _ = Darwin.shutdown(current.fd, SHUT_RDWR)
                _ = writeQueue.sync {
                    Darwin.close(current.fd)
                }
                if closeUnclaimedReader {
                    Darwin.close(current.readerFD)
                }
            }
        }

    }

    private final class FSTransferSession: @unchecked Sendable {
        let txID: String
        let fd: Int32
        let ownerClientFD: Int32
        let op: MacOSSidecarFSOperation
        let path: String
        let writeLock = NSLock()
        let stateLock = NSLock()
        var closed = false

        init(txID: String, fd: Int32, ownerClientFD: Int32, op: MacOSSidecarFSOperation, path: String) {
            self.txID = txID
            self.fd = fd
            self.ownerClientFD = ownerClientFD
            self.op = op
            self.path = path
        }
    }

    private final class FSReadSession: @unchecked Sendable {
        let txID: String
        let fd: Int32
        let ownerClientFD: Int32
        let path: String
        let writeLock = NSLock()
        let stateLock = NSLock()
        var closed = false

        init(txID: String, fd: Int32, ownerClientFD: Int32, path: String) {
            self.txID = txID
            self.fd = fd
            self.ownerClientFD = ownerClientFD
            self.path = path
        }
    }

    private let socketPath: String
    private let service: MacOSSidecarService
    private let log: Logging.Logger
    private let lock = NSLock()
    private let eventDelivery: SidecarEventDeliveryBuffer
    private let eventClientLock = NSLock()
    private let processLock = NSLock()
    private let checkpointAdmissionLock = NSLock()
    private let processReconnectQueue = DispatchQueue(
        label: "container.runtime.macos.sidecar.process-reconnect",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let processConnectionFactory: (@Sendable (UInt32) throws -> Int32)?
    private let processReconnectDelayMicroseconds: useconds_t
    private let fsLock = NSLock()
    private let fsReadLock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = false
    private var boundSocketIdentity: BoundSocketIdentity?
    private var eventClientFD: Int32 = -1
    private var eventClientSubscriptionID: String?
    private var processSessions: [String: ProcessStreamSession] = [:]
    private var activeCheckpoint: ActiveCheckpoint?
    private var fsSessions: [String: FSTransferSession] = [:]
    private var fsReadSessions: [String: FSReadSession] = [:]

    init(
        socketPath: String,
        service: MacOSSidecarService,
        log: Logging.Logger,
        processConnectionFactory: (@Sendable (UInt32) throws -> Int32)? = nil,
        processReconnectDelayMicroseconds: useconds_t = 100_000,
        maximumBufferedEventCount: Int = 256,
        maximumBufferedEventBytes: Int = 16 * 1024 * 1024,
        controlWriteTimeoutMilliseconds: Int32 = 1_000
    ) {
        self.socketPath = socketPath
        self.service = service
        self.log = log
        self.processConnectionFactory = processConnectionFactory
        self.processReconnectDelayMicroseconds = processReconnectDelayMicroseconds
        self.eventDelivery = SidecarEventDeliveryBuffer(
            log: log,
            maximumEventCount: maximumBufferedEventCount,
            maximumRetainedBytes: maximumBufferedEventBytes,
            writeTimeoutMilliseconds: controlWriteTimeoutMilliseconds
        )
    }

    func start() throws {
        try cleanupStaleSocket(requiredOwnerID: geteuid())
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw makePOSIXError(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxPathCount = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxPathCount else {
            Darwin.close(fd)
            throw makePOSIXLikeError(message: "unix socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            let error = makePOSIXError(errno)
            Darwin.close(fd)
            throw error
        }

        var identity: BoundSocketIdentity?
        do {
            let boundIdentity = try inspectBoundSocketIdentity()
            identity = boundIdentity
            guard chmod(socketPath, mode_t(0o600)) == 0 else {
                throw makePOSIXError(errno)
            }
            try validateBoundSocket(identity: boundIdentity)
            guard Darwin.listen(fd, 16) == 0 else {
                throw makePOSIXError(errno)
            }
        } catch {
            Darwin.close(fd)
            if let identity {
                try? removeBoundSocketIfMatches(identity)
            }
            throw error
        }

        lock.lock()
        listenFD = fd
        boundSocketIdentity = identity
        stopping = false
        lock.unlock()
        eventDelivery.start()

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
        log.info("control socket listening", metadata: ["path": "\(socketPath)"])
    }

    func stop() {
        lock.lock()
        if stopping {
            lock.unlock()
            return
        }
        stopping = true
        let fd = listenFD
        listenFD = -1
        let socketIdentity = boundSocketIdentity
        boundSocketIdentity = nil
        lock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        clearEventClient()
        eventDelivery.stop()
        closeAllProcessSessions()
        closeAllFSSessions()
        closeAllFSReadSessions()
        if let socketIdentity {
            do {
                try removeBoundSocketIfMatches(socketIdentity)
            } catch {
                log.error("failed to remove control socket", metadata: ["path": "\(socketPath)", "error": "\(error)"])
            }
        }
    }

    private func cleanupStaleSocket(requiredOwnerID: uid_t) throws {
        let validatedSocketPath = try validatedSocketPathForCleanup()
        try ensureSecureSocketParent(for: validatedSocketPath)

        var value = stat()
        guard lstat(validatedSocketPath, &value) == 0 else {
            if errno == ENOENT {
                return
            }
            throw makePOSIXError(errno)
        }
        guard (value.st_mode & S_IFMT) == S_IFSOCK else {
            throw makePOSIXLikeError(message: "refusing to replace non-socket control path \(socketPath)")
        }
        guard value.st_uid == requiredOwnerID else {
            throw makePOSIXLikeError(message: "refusing to replace control socket not owned by the current user")
        }
        guard try shouldRemoveStaleSocket(at: validatedSocketPath) else {
            return
        }
        guard unlink(validatedSocketPath) == 0 else {
            throw makePOSIXError(errno)
        }
    }

    private func shouldRemoveStaleSocket(at path: String) throws -> Bool {
        do {
            let activeFD = try MacOSSidecarSocketIO.connectUnixSocket(path: path)
            Darwin.close(activeFD)
            throw makePOSIXLikeError(message: "refusing to replace an active control socket")
        } catch let error as NSError {
            guard error.domain == NSPOSIXErrorDomain else {
                throw error
            }
            switch error.code {
            case Int(ECONNREFUSED):
                return true
            case Int(ENOENT):
                return false
            default:
                throw error
            }
        }
    }

    private func inspectBoundSocketIdentity() throws -> BoundSocketIdentity {
        var value = stat()
        guard lstat(socketPath, &value) == 0 else {
            throw makePOSIXError(errno)
        }
        guard (value.st_mode & S_IFMT) == S_IFSOCK, value.st_uid == geteuid() else {
            throw makePOSIXLikeError(message: "new control socket has an unexpected type or owner")
        }
        return BoundSocketIdentity(device: value.st_dev, inode: value.st_ino)
    }

    private func validateBoundSocket(identity: BoundSocketIdentity) throws {
        var value = stat()
        guard lstat(socketPath, &value) == 0 else {
            throw makePOSIXError(errno)
        }
        let isSameSocket =
            (value.st_mode & S_IFMT) == S_IFSOCK
            && value.st_uid == geteuid()
            && value.st_dev == identity.device
            && value.st_ino == identity.inode
        guard isSameSocket, value.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw makePOSIXLikeError(message: "new control socket has unsafe owner, type, or permissions")
        }
    }

    private func removeBoundSocketIfMatches(_ identity: BoundSocketIdentity) throws {
        let validatedSocketPath = try validatedSocketPathForCleanup()
        var value = stat()
        guard lstat(validatedSocketPath, &value) == 0 else {
            if errno == ENOENT {
                return
            }
            throw makePOSIXError(errno)
        }
        let isSameSocket =
            (value.st_mode & S_IFMT) == S_IFSOCK
            && value.st_dev == identity.device
            && value.st_ino == identity.inode
        guard isSameSocket else {
            log.warning("control socket path changed before cleanup; preserving replacement", metadata: ["path": "\(socketPath)"])
            return
        }
        guard unlink(validatedSocketPath) == 0 else {
            throw makePOSIXError(errno)
        }
    }

    private func validatedSocketPathForCleanup() throws -> String {
        guard socketPath.hasPrefix("/"), !socketPath.utf8.contains(0), !socketPath.hasSuffix("/") else {
            throw makePOSIXLikeError(message: "control socket path must be an absolute file path")
        }
        let components = NSString(string: socketPath).pathComponents
        guard !components.contains("."), !components.contains("..") else {
            throw makePOSIXLikeError(message: "control socket path must not contain relative components")
        }

        guard let physicalPath = MacOSManagedPath.canonicalPath(socketPath) else {
            throw makePOSIXLikeError(message: "control socket path must be normalized with only trusted system aliases")
        }
        return physicalPath
    }

    private func ensureSecureSocketParent(for validatedSocketPath: String) throws {
        let parentPath = URL(fileURLWithPath: validatedSocketPath).deletingLastPathComponent().path
        let components = NSString(string: parentPath).pathComponents
        guard components.first == "/" else {
            throw makePOSIXLikeError(message: "control socket parent must be absolute")
        }

        try validateSocketDirectory(path: "/", wasCreated: false)
        var currentPath = "/"
        for component in components.dropFirst() {
            currentPath = URL(fileURLWithPath: currentPath, isDirectory: true).appendingPathComponent(component).path
            var value = stat()
            var wasCreated = false
            if lstat(currentPath, &value) != 0 {
                guard errno == ENOENT else {
                    throw makePOSIXError(errno)
                }
                if mkdir(currentPath, mode_t(0o700)) == 0 {
                    wasCreated = true
                } else if errno != EEXIST {
                    throw makePOSIXError(errno)
                }
            }
            try validateSocketDirectory(path: currentPath, wasCreated: wasCreated)
        }
    }

    private func validateSocketDirectory(path: String, wasCreated: Bool) throws {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            throw makePOSIXError(errno)
        }
        guard (value.st_mode & S_IFMT) == S_IFDIR else {
            throw makePOSIXLikeError(message: "control socket path must not traverse symbolic links or non-directories")
        }

        let permissions = value.st_mode & mode_t(0o7777)
        if wasCreated {
            guard value.st_uid == geteuid(), permissions == mode_t(0o700) else {
                throw makePOSIXLikeError(message: "new control socket parent has unsafe owner or permissions")
            }
            return
        }
        let permittedOwner = value.st_uid == 0 || value.st_uid == geteuid()
        guard permittedOwner,
            MacOSManagedPath.hasTrustedParentWritePermissions(
                path: path, ownerID: value.st_uid, groupID: value.st_gid, mode: value.st_mode
            )
        else {
            throw makePOSIXLikeError(message: "control socket parent has unsafe owner or permissions")
        }
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let isStopping = stopping
            lock.unlock()
            if isStopping || fd < 0 { return }

            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD >= 0 {
                Thread.detachNewThread { [weak self] in
                    self?.handleClient(fd: clientFD)
                }
                continue
            }
            let code = errno
            if code == EINTR { continue }
            lock.lock()
            let shouldExit = stopping
            lock.unlock()
            if shouldExit { return }
            log.error("accept failed", metadata: ["error": "\(String(cString: strerror(code)))", "code": "\(code)"])
            usleep(50_000)
        }
    }

    private func handleClient(fd clientFD: Int32) {
        defer {
            closeOwnedFSSessions(clientFD: clientFD)
            closeOwnedFSReadSessions(clientFD: clientFD)
            closeControlClient(clientFD)
        }

        while true {
            var parsedRequest: MacOSSidecarRequest?
            do {
                let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: clientFD)
                guard envelope.kind == .request, let request = envelope.request else {
                    throw ContainerizationError(.invalidArgument, message: "control envelope must be a request")
                }
                parsedRequest = request
                if request.method.claimsLegacyEventSubscription {
                    setEventClientIfAbsent(fd: clientFD)
                }

                log.info("control request received", metadata: ["method": "\(request.method.rawValue)", "request_id": "\(request.requestID)"])
                let response = try perform(request: request, clientFD: clientFD)
                if request.method == .eventsSubscribe, response.ok {
                    try writeEventSubscriptionResponse(
                        response,
                        to: clientFD,
                        subscriptionID: eventSubscriptionID(for: clientFD)
                    )
                } else {
                    try writeEnvelope(.response(response), to: clientFD)
                }
                log.info("control request completed", metadata: ["method": "\(request.method.rawValue)", "request_id": "\(request.requestID)", "ok": "\(response.ok)"])
            } catch {
                if parsedRequest == nil, isExpectedEOF(error) {
                    return
                }
                log.error("control request failed", metadata: ["error": "\(error)"])
                guard let request = parsedRequest else {
                    return
                }
                if request.method == .vmConnectVsock {
                    try? MacOSSidecarSocketIO.sendNoFileDescriptorMarker(socketFD: clientFD)
                }
                let response = failureResponse(requestID: request.requestID, error: error)
                try? writeEnvelope(.response(response), to: clientFD)
            }
        }
    }

    private func writeEnvelope(_ envelope: MacOSSidecarEnvelope, to fd: Int32) throws {
        try eventDelivery.write(envelope, to: fd)
    }

    private func writeEventSubscriptionResponse(
        _ response: MacOSSidecarResponse,
        to fd: Int32,
        subscriptionID: String?
    ) throws {
        try eventDelivery.writeSubscriptionResponse(response, to: fd, subscriptionID: subscriptionID)
    }

    @discardableResult
    private func emitEvent(
        _ event: MacOSSidecarEvent,
        acknowledged: (@Sendable () -> Void)? = nil
    ) -> Bool {
        eventDelivery.enqueue(event, acknowledged: acknowledged)
    }

    private func subscribeEventClient(fd: Int32, acknowledgementRequired: Bool) -> (claimed: Bool, subscriptionID: String?) {
        eventClientLock.lock()
        defer { eventClientLock.unlock() }
        guard eventClientFD < 0 || eventClientFD == fd else { return (false, nil) }
        eventClientFD = fd
        if acknowledgementRequired {
            if eventClientSubscriptionID == nil {
                eventClientSubscriptionID = UUID().uuidString
            }
        } else {
            eventClientSubscriptionID = nil
        }
        return (true, eventClientSubscriptionID)
    }

    private func eventSubscriptionID(for fd: Int32) -> String? {
        eventClientLock.lock()
        let result = eventClientFD == fd ? eventClientSubscriptionID : nil
        eventClientLock.unlock()
        return result
    }

    private func setEventClientIfAbsent(fd: Int32) {
        let claimed: Bool
        eventClientLock.lock()
        if eventClientFD < 0 {
            eventClientFD = fd
            eventClientSubscriptionID = nil
            claimed = true
        } else {
            claimed = eventClientFD == fd
        }
        eventClientLock.unlock()

        if claimed {
            eventDelivery.setClient(fd)
        }
    }

    private func setEventClient(fd: Int32) {
        eventClientLock.lock()
        eventClientFD = fd
        eventClientSubscriptionID = nil
        eventClientLock.unlock()
        eventDelivery.setClient(fd)
    }

    private func clearEventClient() {
        eventClientLock.lock()
        eventClientFD = -1
        eventClientSubscriptionID = nil
        eventClientLock.unlock()
        eventDelivery.clearClient()
    }

    private func closeControlClient(_ fd: Int32) {
        eventClientLock.lock()
        if eventClientFD == fd {
            eventClientFD = -1
            eventClientSubscriptionID = nil
        }
        eventClientLock.unlock()
        eventDelivery.closeClient(fd)
    }

    private func isExpectedEOF(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "RuntimeMacOSSidecarShared" && nsError.localizedDescription.contains("unexpected EOF")
    }

    private func registerProcessSession(_ session: ProcessStreamSession) throws {
        processLock.lock()
        defer { processLock.unlock() }
        try registerProcessSessionLocked(session)
    }

    private func registerProcessSessionLocked(_ session: ProcessStreamSession) throws {
        guard processSessions[session.processID] == nil else {
            throw ContainerizationError(.exists, message: "process \(session.processID) already exists in sidecar")
        }
        guard !processSessions.values.contains(where: { $0.guestProcessID == session.guestProcessID }) else {
            throw ContainerizationError(
                .exists,
                message: "durable execution \(session.guestProcessID) already has a sidecar process stream"
            )
        }
        processSessions[session.processID] = session
    }

    private func registerProcessSessionAndStartReadLoop(
        _ session: ProcessStreamSession,
        connection: ProcessStreamConnection,
        initialFrames: [SidecarGuestAgentFrame]
    ) throws {
        processLock.lock()
        do {
            try registerProcessSessionLocked(session)
            guard startProcessReadLoop(session, connection: connection, initialFrames: initialFrames) else {
                processSessions.removeValue(forKey: session.processID)
                throw ContainerizationError(.invalidState, message: "new process stream was detached before reader startup")
            }
            processLock.unlock()
        } catch {
            processLock.unlock()
            throw error
        }
    }

    private func existingProcessSession(for processID: String) -> ProcessStreamSession? {
        processLock.lock()
        let session = processSessions[processID]
        processLock.unlock()
        return session
    }

    private func processRequestFingerprint(_ exec: MacOSSidecarExecRequestPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(ProcessLaunchIdentity(exec)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func validateDurableProcessRequest(_ exec: MacOSSidecarExecRequestPayload) throws {
        let hasDurableMetadata =
            exec.durableLaunchFingerprint != nil
            || exec.durableIncarnation != nil
            || exec.storageGeneration != nil
            || exec.previousStorageGeneration != nil
        guard exec.durableExecutionID != nil || !hasDurableMetadata else {
            throw ContainerizationError(
                .invalidArgument,
                message: "durable launch metadata requires a durable execution identifier"
            )
        }
        if let durableLaunchFingerprint = exec.durableLaunchFingerprint,
            durableLaunchFingerprint.isEmpty
        {
            throw ContainerizationError(.invalidArgument, message: "durable launch fingerprint must not be empty")
        }
        if let durableIncarnation = exec.durableIncarnation, durableIncarnation.isEmpty {
            throw ContainerizationError(.invalidArgument, message: "durable process incarnation must not be empty")
        }
        if exec.durableIncarnation != nil, exec.durableLaunchFingerprint == nil {
            throw ContainerizationError(
                .invalidArgument,
                message: "durable process incarnation requires a trusted launch fingerprint"
            )
        }
        if let storageGeneration = exec.storageGeneration, storageGeneration == 0 {
            throw ContainerizationError(.invalidArgument, message: "durable storage generation must be positive")
        }
        if exec.storageGeneration != nil, exec.durableLaunchFingerprint == nil {
            throw ContainerizationError(
                .invalidArgument,
                message: "generation-fenced durable execution requires a launch fingerprint"
            )
        }
        if let previousStorageGeneration = exec.previousStorageGeneration {
            guard previousStorageGeneration > 0, let storageGeneration = exec.storageGeneration else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "durable generation adoption requires positive previous and current generations"
                )
            }
            guard storageGeneration > previousStorageGeneration else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "durable storage generation must be newer than its previous generation"
                )
            }
        }
    }

    private func processSession(for processID: String) throws -> ProcessStreamSession {
        processLock.lock()
        let session = processSessions[processID]
        processLock.unlock()
        guard let session else {
            throw ContainerizationError(.notFound, message: "process \(processID) not found in sidecar")
        }
        return session
    }

    private func removeProcessSession(
        _ processID: String,
        matching expected: ProcessStreamSession? = nil
    ) -> ProcessStreamSession? {
        processLock.lock()
        let removed: ProcessStreamSession?
        if let expected, processSessions[processID] !== expected {
            removed = nil
        } else {
            removed = processSessions.removeValue(forKey: processID)
        }
        processLock.unlock()
        return removed
    }

    private func closeAllProcessSessions() {
        let sessions: [ProcessStreamSession]
        processLock.lock()
        sessions = Array(processSessions.values)
        processSessions.removeAll()
        processLock.unlock()

        for session in sessions {
            session.cancelAndClose()
        }
    }

    private func cancelProcessSession(_ session: ProcessStreamSession) {
        session.cancelAndClose()
        processLock.lock()
        if processSessions[session.processID] === session {
            processSessions.removeValue(forKey: session.processID)
        }
        processLock.unlock()
    }

    private func processSession(forExecutionID executionID: String) -> ProcessStreamSession? {
        processLock.lock()
        let result = processSessions.values.first { $0.guestProcessID == executionID }
        processLock.unlock()
        return result
    }

    private func registerFSSession(_ session: FSTransferSession) throws {
        fsLock.lock()
        defer { fsLock.unlock() }
        guard fsSessions[session.txID] == nil else {
            throw ContainerizationError(.exists, message: "filesystem transaction \(session.txID) already exists in sidecar")
        }
        fsSessions[session.txID] = session
    }

    private func fsSession(for txID: String) throws -> FSTransferSession {
        fsLock.lock()
        let session = fsSessions[txID]
        fsLock.unlock()
        guard let session else {
            throw ContainerizationError(.notFound, message: "filesystem transaction \(txID) not found in sidecar")
        }
        return session
    }

    private func removeFSSession(_ txID: String) -> FSTransferSession? {
        fsLock.lock()
        let removed = fsSessions.removeValue(forKey: txID)
        fsLock.unlock()
        return removed
    }

    private func closeOwnedFSSessions(clientFD: Int32) {
        let sessions: [FSTransferSession]
        fsLock.lock()
        let txIDs = fsSessions.values.filter { $0.ownerClientFD == clientFD }.map(\.txID)
        sessions = txIDs.compactMap { fsSessions.removeValue(forKey: $0) }
        fsLock.unlock()

        for session in sessions {
            closeFSSession(session, reason: "owner client disconnected")
        }
    }

    private func closeAllFSSessions() {
        let sessions: [FSTransferSession]
        fsLock.lock()
        sessions = Array(fsSessions.values)
        fsSessions.removeAll()
        fsLock.unlock()

        for session in sessions {
            closeFSSession(session, reason: "sidecar shutdown")
        }
    }

    private func closeFSSession(_ session: FSTransferSession, reason: String? = nil) {
        session.stateLock.lock()
        let shouldClose = !session.closed
        session.closed = true
        session.stateLock.unlock()
        guard shouldClose else { return }
        logFS("closing", session: session, extra: reason.map { ["reason": $0] } ?? [:])
        _ = Darwin.shutdown(session.fd, SHUT_RDWR)
        Darwin.close(session.fd)
    }

    // MARK: - FSReadSession management

    private func registerFSReadSession(_ session: FSReadSession) throws {
        fsReadLock.lock()
        defer { fsReadLock.unlock() }
        guard fsReadSessions[session.txID] == nil else {
            throw ContainerizationError(.exists, message: "filesystem read transaction \(session.txID) already exists in sidecar")
        }
        fsReadSessions[session.txID] = session
    }

    private func fsReadSession(for txID: String) throws -> FSReadSession {
        fsReadLock.lock()
        let session = fsReadSessions[txID]
        fsReadLock.unlock()
        guard let session else {
            throw ContainerizationError(.notFound, message: "filesystem read transaction \(txID) not found in sidecar")
        }
        return session
    }

    private func removeFSReadSession(_ txID: String) -> FSReadSession? {
        fsReadLock.lock()
        let removed = fsReadSessions.removeValue(forKey: txID)
        fsReadLock.unlock()
        return removed
    }

    private func closeOwnedFSReadSessions(clientFD: Int32) {
        let sessions: [FSReadSession]
        fsReadLock.lock()
        let txIDs = fsReadSessions.values.filter { $0.ownerClientFD == clientFD }.map(\.txID)
        sessions = txIDs.compactMap { fsReadSessions.removeValue(forKey: $0) }
        fsReadLock.unlock()

        for session in sessions {
            closeFSReadSession(session, reason: "owner client disconnected")
        }
    }

    private func closeAllFSReadSessions() {
        let sessions: [FSReadSession]
        fsReadLock.lock()
        sessions = Array(fsReadSessions.values)
        fsReadSessions.removeAll()
        fsReadLock.unlock()

        for session in sessions {
            closeFSReadSession(session, reason: "sidecar shutdown")
        }
    }

    private func closeFSReadSession(_ session: FSReadSession, reason: String? = nil) {
        session.stateLock.lock()
        let shouldClose = !session.closed
        session.closed = true
        session.stateLock.unlock()
        guard shouldClose else { return }
        log.info(
            "filesystem read session closing",
            metadata: [
                "tx_id": "\(session.txID)",
                "path": "\(session.path)",
                "reason": "\(reason ?? "normal")",
            ]
        )
        _ = Darwin.shutdown(session.fd, SHUT_RDWR)
        Darwin.close(session.fd)
    }

    private func sendFrame(_ frame: SidecarGuestAgentFrame, to session: FSReadSession) throws {
        session.writeLock.lock()
        defer { session.writeLock.unlock() }
        try MacOSSidecarSocketIO.writeJSONFrame(frame, fd: session.fd)
    }

    func _testRegisterFSSession(
        txID: String,
        fd: Int32,
        ownerClientFD: Int32,
        op: MacOSSidecarFSOperation,
        path: String
    ) throws {
        try registerFSSession(
            FSTransferSession(
                txID: txID,
                fd: fd,
                ownerClientFD: ownerClientFD,
                op: op,
                path: path
            )
        )
    }

    func _testHasFSSession(txID: String) -> Bool {
        fsLock.lock()
        let exists = fsSessions[txID] != nil
        fsLock.unlock()
        return exists
    }

    func _testCloseOwnedFSSessions(clientFD: Int32) {
        closeOwnedFSSessions(clientFD: clientFD)
    }

    func _testCloseAllFSSessions() {
        closeAllFSSessions()
    }

    func _testSendFSChunk(_ payload: MacOSSidecarFSChunkRequestPayload) throws {
        try sendFSChunk(payload)
    }

    func _testWaitForProcessStartAck(
        fd: Int32,
        expectedProcessID: String,
        timeoutSeconds: TimeInterval = 1
    ) throws -> [SidecarGuestAgentFrame] {
        try waitForProcessStartAck(
            fd: fd,
            expectedProcessID: expectedProcessID,
            timeoutSeconds: timeoutSeconds
        ).bufferedFrames
    }

    func _testGuestExecutableLaunch(executable: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        guestExecutableLaunch(executable: executable, arguments: arguments)
    }

    func _testCleanupStaleSocket(requiredOwnerID: uid_t) throws {
        try cleanupStaleSocket(requiredOwnerID: requiredOwnerID)
    }

    func _testEmitEvent(
        _ event: MacOSSidecarEvent,
        acknowledged: (@Sendable () -> Void)? = nil
    ) {
        emitEvent(event, acknowledged: acknowledged)
    }

    func _testHasEventClient() -> Bool {
        eventDelivery.hasClient()
    }

    func _testSetVMLifecycleRunning() throws {
        try syncValue {
            try await self.service._testSetLifecycleRunning()
        }
    }

    func _testPendingEventCount() -> Int {
        eventDelivery.pendingCount()
    }

    func _testSetEventClient(fd: Int32) {
        setEventClient(fd: fd)
    }

    func _testClearEventClient() {
        clearEventClient()
    }

    func _testRegisterProcessSession(
        processID: String,
        guestProcessID: String,
        durable: Bool,
        exec: MacOSSidecarExecRequestPayload,
        replayCursor: UInt64,
        fd: Int32,
        port: UInt32 = 27_000,
        launchFingerprint: String = "test-launch-fingerprint",
        storageGeneration: UInt64? = nil,
        processIdentifier: Int32 = 42,
        trustedLaunchFingerprint: String? = nil,
        incarnation: String? = nil,
        writeTimeoutMilliseconds: Int32 = 1_000
    ) throws {
        let session = try ProcessStreamSession(
            processID: processID,
            guestProcessID: guestProcessID,
            durable: durable,
            requestFingerprint: try processRequestFingerprint(exec),
            port: port,
            launchFingerprint: durable ? launchFingerprint : nil,
            storageGeneration: durable ? storageGeneration : nil,
            processIdentifier: durable ? processIdentifier : nil,
            trustedLaunchFingerprint: durable ? trustedLaunchFingerprint ?? exec.durableLaunchFingerprint : nil,
            incarnation: durable ? incarnation ?? exec.durableIncarnation : nil,
            replayCursor: replayCursor,
            fd: fd,
            writeTimeoutMilliseconds: writeTimeoutMilliseconds
        )
        do {
            try registerProcessSession(session)
        } catch {
            session.cancelAndClose()
            throw error
        }
    }

    func _testStartProcessReadLoop(processID: String) throws {
        let session = try processSession(for: processID)
        guard let connection = session.currentConnection() else {
            throw ContainerizationError(.invalidState, message: "test process stream is detached")
        }
        _ = startProcessReadLoop(session, connection: connection)
    }

    func _testStartProcessStream(
        port: UInt32 = 27_000,
        processID: String,
        exec: MacOSSidecarExecRequestPayload
    ) throws {
        try startProcessStream(port: port, processID: processID, exec: exec)
    }

    func _testPrepareCheckpoint(
        _ payload: MacOSMachineStateRequestPayload
    ) throws -> MacOSMachineStateCheckpointResult {
        try prepareCheckpoint(payload)
    }

    func _testInspectDurableProcess(
        port: UInt32 = 27_000,
        processID: String,
        exec: MacOSSidecarExecRequestPayload
    ) throws -> MacOSGuestProcessStatusPayload {
        try inspectDurableProcess(port: port, processID: processID, exec: exec)
    }

    func _testCloseAllProcessSessions() {
        closeAllProcessSessions()
    }

    func _testProcessDeliveredCursor(processID: String) -> UInt64? {
        try? processSession(for: processID).deliveredCursor()
    }

    func _testProcessConnectionDescriptors(processID: String) -> (owner: Int32, reader: Int32)? {
        try? processSession(for: processID).connectionDescriptors()
    }

    func _testHasProcessSession(processID: String) -> Bool {
        (try? processSession(for: processID)) != nil
    }

    func _testIsProcessReconnectPending(processID: String) -> Bool {
        (try? processSession(for: processID).isReconnectPending()) == true
    }

    func _testMarkProcessTerminal(processID: String) throws {
        try processSession(for: processID).markTerminal()
    }

    func _testBlockProcessReconnect(processID: String) throws {
        try processSession(for: processID).finishReconnect(blocked: true)
    }

    func _testCancelProcessSessionWithoutRemoval(processID: String) throws {
        try processSession(for: processID).cancelAndClose()
    }

    func _testSendProcessStdin(processID: String, data: Data) throws {
        let session = try processSession(for: processID)
        try session.send(.stdin(id: session.guestProcessID, data: data))
    }

    func _testDeleteDurableProcess(
        port: UInt32 = 27_000,
        identity: MacOSSidecarDurableProcessDeleteIdentity
    ) throws {
        try deleteDurableProcess(port: port, identity: identity)
    }

    func _testGuestProcessErrorCode(errorCode: Int32?, message: String) -> ContainerizationError.Code {
        guestProcessCommandError(
            .init(type: .error, message: message, errorCode: errorCode),
            operation: "test"
        ).code
    }

    func _testIsPermanentProcessReconnectFailure(errorCode: Int32?, message: String) -> Bool {
        isPermanentProcessReconnectFailure(
            guestProcessCommandError(
                .init(type: .error, message: message, errorCode: errorCode),
                operation: "test"
            )
        )
    }

    private func sendFrame(_ frame: SidecarGuestAgentFrame, to session: ProcessStreamSession) throws {
        try session.send(frame)
    }

    private func sendFrame(_ frame: SidecarGuestAgentFrame, to session: FSTransferSession) throws {
        session.writeLock.lock()
        defer { session.writeLock.unlock() }
        try MacOSSidecarSocketIO.writeJSONFrame(frame, fd: session.fd)
    }

    private func sendProcessControlFrame(processID: String, build: (ProcessStreamSession) -> SidecarGuestAgentFrame) throws {
        let session = try processSession(for: processID)
        do {
            try sendFrame(build(session), to: session)
        } catch {
            if let connection = session.currentConnection(), session.detach(connection), session.durable {
                scheduleProcessReconnect(session)
            }
            throw error
        }
    }

    private func startFSTransfer(port: UInt32, clientFD: Int32, payload: MacOSSidecarFSBeginRequestPayload) throws {
        checkpointAdmissionLock.lock()
        defer { checkpointAdmissionLock.unlock() }
        try ensureCheckpointAllowsNewSession()

        logFS(
            "begin",
            txID: payload.txID,
            op: payload.op,
            path: payload.path,
            extra: [
                "port": "\(port)",
                "owner_client_fd": "\(clientFD)",
                "auto_commit": "\(payload.autoCommit)",
                "inline_bytes": "\(payload.inlineData?.count ?? 0)",
                "digest": payload.digest ?? "-",
            ]
        )
        let fd = try syncValue {
            try await self.service.connectVsock(port: port)
        }

        do {
            _ = try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
            try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame.fsBegin(payload), fd: fd)
            try waitForFSAck(fd: fd, expectedID: payload.txID)

            if payload.autoCommit {
                logFS("auto-commit completed", txID: payload.txID, op: payload.op, path: payload.path)
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
                return
            }

            let session = FSTransferSession(
                txID: payload.txID,
                fd: fd,
                ownerClientFD: clientFD,
                op: payload.op,
                path: payload.path
            )
            try registerFSSession(session)
            logFS("session registered", session: session)
        } catch {
            logFS(
                "begin failed",
                txID: payload.txID,
                op: payload.op,
                path: payload.path,
                extra: ["error": "\(error)"]
            )
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            throw error
        }
    }

    private func sendFSChunk(_ payload: MacOSSidecarFSChunkRequestPayload) throws {
        let session = try fsSession(for: payload.txID)
        do {
            logFS(
                "chunk",
                session: session,
                extra: [
                    "offset": "\(payload.offset)",
                    "bytes": "\(payload.data.count)",
                ]
            )
            try sendFrame(.fsChunk(payload), to: session)
            try waitForFSAck(fd: session.fd, expectedID: payload.txID)
        } catch {
            logFS("chunk failed", session: session, extra: ["error": "\(error)"])
            closeFSSession(session, reason: "chunk failed")
            _ = removeFSSession(payload.txID)
            throw error
        }
    }

    private func finishFSTransfer(_ payload: MacOSSidecarFSEndRequestPayload) throws {
        let session = try fsSession(for: payload.txID)
        defer {
            closeFSSession(session, reason: "transfer finished")
            _ = removeFSSession(payload.txID)
        }
        logFS(
            "end",
            session: session,
            extra: [
                "action": payload.action.rawValue,
                "digest": payload.digest ?? "-",
            ]
        )
        try sendFrame(.fsEnd(payload), to: session)
        try waitForFSAck(fd: session.fd, expectedID: payload.txID)
    }

    // MARK: - Read direction operations

    private func startFSRead(port: UInt32, clientFD: Int32, payload: MacOSSidecarFSReadBeginRequestPayload) throws -> MacOSSidecarFSReadBeginResponsePayload {
        checkpointAdmissionLock.lock()
        defer { checkpointAdmissionLock.unlock() }
        try ensureCheckpointAllowsNewSession()

        log.info(
            "filesystem read begin",
            metadata: [
                "tx_id": "\(payload.txID)",
                "path": "\(payload.path)",
                "port": "\(port)",
                "owner_client_fd": "\(clientFD)",
            ]
        )
        let fd = try syncValue {
            try await self.service.connectVsock(port: port)
        }

        do {
            _ = try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
            try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame.fsReadBegin(payload), fd: fd)
            let responseData = try waitForFSAckWithData(fd: fd, expectedID: payload.txID)
            guard let responseData else {
                throw ContainerizationError(.internalError, message: "filesystem read begin ack missing response data for \(payload.txID)")
            }
            let meta = try JSONDecoder().decode(MacOSSidecarFSReadBeginResponsePayload.self, from: responseData)

            let session = FSReadSession(
                txID: payload.txID,
                fd: fd,
                ownerClientFD: clientFD,
                path: payload.path
            )
            try registerFSReadSession(session)
            log.info("filesystem read session registered", metadata: ["tx_id": "\(payload.txID)", "path": "\(payload.path)", "file_type": "\(meta.fileType.rawValue)"])
            return meta
        } catch {
            log.error("filesystem read begin failed", metadata: ["tx_id": "\(payload.txID)", "path": "\(payload.path)", "error": "\(error)"])
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            throw error
        }
    }

    private func sendFSReadChunk(_ payload: MacOSSidecarFSReadChunkRequestPayload) throws -> Data? {
        let session = try fsReadSession(for: payload.txID)
        do {
            log.info(
                "filesystem read chunk",
                metadata: [
                    "tx_id": "\(payload.txID)",
                    "offset": "\(payload.offset)",
                    "max_length": "\(payload.maxLength)",
                ]
            )
            try sendFrame(.fsReadChunk(payload), to: session)
            return try waitForFSAckWithData(fd: session.fd, expectedID: payload.txID)
        } catch {
            log.error("filesystem read chunk failed", metadata: ["tx_id": "\(payload.txID)", "error": "\(error)"])
            closeFSReadSession(session, reason: "chunk read failed")
            _ = removeFSReadSession(payload.txID)
            throw error
        }
    }

    private func finishFSRead(txID: String) throws {
        guard let session = removeFSReadSession(txID) else {
            // Session may have already been closed; not an error
            log.info("filesystem read end: session not found (may be already closed)", metadata: ["tx_id": "\(txID)"])
            return
        }
        defer {
            closeFSReadSession(session, reason: "read finished")
        }
        log.info("filesystem read end", metadata: ["tx_id": "\(txID)", "path": "\(session.path)"])
        try sendFrame(.fsReadEnd(txID: txID), to: session)
        try waitForFSAck(fd: session.fd, expectedID: txID)
    }

    private func listDir(port: UInt32, path: String, txID: String) throws -> [MacOSSidecarFSListDirEntry] {
        log.info("filesystem listdir", metadata: ["tx_id": "\(txID)", "path": "\(path)", "port": "\(port)"])
        let fd = try syncValue {
            try await self.service.connectVsock(port: port)
        }
        defer {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }

        do {
            _ = try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
            try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame.fsListDir(txID: txID, path: path), fd: fd)
            let responseData = try waitForFSAckWithData(fd: fd, expectedID: txID)
            guard let responseData else {
                throw ContainerizationError(.internalError, message: "filesystem listdir ack missing response data for \(txID)")
            }
            return try JSONDecoder().decode([MacOSSidecarFSListDirEntry].self, from: responseData)
        } catch {
            log.error("filesystem listdir failed", metadata: ["tx_id": "\(txID)", "path": "\(path)", "error": "\(error)"])
            throw error
        }
    }

    private func inspectExistingDurableProcess(
        fd: Int32,
        executionID: String
    ) throws -> MacOSGuestProcessStatusPayload? {
        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame(type: .processInspect, id: executionID),
            fd: fd
        )
        do {
            guard
                let status = try waitForGuestProcessCommandAck(
                    fd: fd,
                    expectedExecutionID: executionID,
                    operation: "inspect",
                    timeoutSeconds: 3
                )
            else {
                throw ContainerizationError(
                    .invalidState,
                    message: "durable process inspect ack is missing identity status"
                )
            }
            try validateDurableProcessStatus(status, expectedExecutionID: executionID)
            return status
        } catch let error as ContainerizationError where error.code == .notFound {
            return nil
        }
    }

    private func guestAttachmentSelection(
        exec: MacOSSidecarExecRequestPayload,
        existingStatus: MacOSGuestProcessStatusPayload?
    ) throws -> (expectedLaunchFingerprint: String?, previousStorageGeneration: UInt64?) {
        guard let currentGeneration = exec.storageGeneration else {
            return (nil, nil)
        }
        guard let existingStatus else {
            // A restored VM may not contain a process for a container that was
            // introduced after the save point. It is created directly in the
            // current writable generation rather than adopted.
            return (nil, nil)
        }
        if let trustedLaunchFingerprint = exec.durableLaunchFingerprint,
            existingStatus.trustedLaunchFingerprint != trustedLaunchFingerprint
        {
            throw ContainerizationError(
                .invalidState,
                message: "existing durable process trusted launch fingerprint does not match"
            )
        }
        if let incarnation = exec.durableIncarnation,
            exec.previousStorageGeneration == nil,
            existingStatus.incarnation != incarnation
        {
            throw ContainerizationError(
                .invalidState,
                message: "existing durable process incarnation does not match"
            )
        }
        guard let boundGeneration = existingStatus.storageGeneration else {
            throw ContainerizationError(
                .invalidState,
                message: "existing durable process does not expose a storage generation"
            )
        }
        if boundGeneration == currentGeneration {
            return (existingStatus.launchFingerprint, nil)
        }
        if let previousGeneration = exec.previousStorageGeneration,
            boundGeneration == previousGeneration,
            currentGeneration > previousGeneration
        {
            return (existingStatus.launchFingerprint, previousGeneration)
        }
        throw ContainerizationError(
            .invalidState,
            message:
                "durable process is bound to storage generation \(boundGeneration), not current generation \(currentGeneration) or its selected predecessor"
        )
    }

    private func startProcessStream(port: UInt32, processID: String, exec: MacOSSidecarExecRequestPayload) throws {
        checkpointAdmissionLock.lock()
        defer { checkpointAdmissionLock.unlock() }
        try ensureCheckpointAllowsNewSession()

        try validateDurableProcessRequest(exec)
        let requestFingerprint = try processRequestFingerprint(exec)
        if let existing = existingProcessSession(for: processID) {
            guard existing.requestFingerprint == requestFingerprint else {
                throw ContainerizationError(
                    .exists,
                    message: "process \(processID) already exists with a different launch request"
                )
            }
            if let retryError = existing.startRetryError() {
                throw retryError
            }
            if existing.durable, existing.currentConnection() == nil {
                scheduleProcessReconnect(existing)
            }
            return
        }
        if let executionID = exec.durableExecutionID,
            let existing = processSession(forExecutionID: executionID)
        {
            guard existing.requestFingerprint == requestFingerprint else {
                throw ContainerizationError(
                    .exists,
                    message: "durable execution \(executionID) already exists with a different launch request"
                )
            }
            throw ContainerizationError(
                .exists,
                message: "durable execution \(executionID) is already bound to process \(existing.processID)"
            )
        }

        let fd = try connectProcessStream(port: port)
        var unregisteredSession: ProcessStreamSession?

        do {
            let durable = exec.durableExecutionID != nil
            let generationFenced = exec.storageGeneration != nil
            let identityFenced = exec.durableIncarnation != nil
            let capabilities = try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
            if durable, !capabilities.contains(MacOSGuestProcessProtocol.durableProcessV1) {
                throw ContainerizationError(
                    .unsupported,
                    message: "guest agent does not support durable workload processes"
                )
            }
            if durable, !capabilities.contains(MacOSGuestProcessProtocol.durableProcessV3) {
                throw ContainerizationError(
                    .unsupported,
                    message: "guest agent does not support consumer-acknowledged durable process events"
                )
            }
            if generationFenced, !capabilities.contains(MacOSGuestProcessProtocol.durableProcessV2) {
                throw ContainerizationError(
                    .unsupported,
                    message: "guest agent does not support generation-fenced durable workload processes"
                )
            }
            if identityFenced, !capabilities.contains(MacOSGuestProcessProtocol.durableProcessV4) {
                throw ContainerizationError(
                    .unsupported,
                    message: "guest agent does not support incarnation-fenced durable workload processes"
                )
            }
            let env = exec.environment ?? ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
            let cwd = exec.workingDirectory ?? "/"
            let launch = guestExecutableLaunch(executable: exec.executable, arguments: exec.arguments)
            let guestProcessID = exec.durableExecutionID ?? processID
            let replayCursor = exec.replayCursor ?? 0
            let existingStatus: MacOSGuestProcessStatusPayload?
            if generationFenced {
                existingStatus = try inspectExistingDurableProcess(fd: fd, executionID: guestProcessID)
            } else {
                existingStatus = nil
            }
            let attachment = try guestAttachmentSelection(exec: exec, existingStatus: existingStatus)
            try MacOSSidecarSocketIO.writeJSONFrame(
                SidecarGuestAgentFrame.exec(
                    id: guestProcessID,
                    executable: launch.executable,
                    arguments: launch.arguments,
                    environment: env,
                    rootDirectory: exec.rootDirectory,
                    workingDirectory: cwd,
                    terminal: exec.terminal,
                    user: exec.user,
                    uid: exec.uid,
                    gid: exec.gid,
                    supplementalGroups: exec.supplementalGroups,
                    durable: durable,
                    cursor: durable ? replayCursor : nil,
                    expectedLaunchFingerprint: attachment.expectedLaunchFingerprint,
                    trustedLaunchFingerprint: exec.durableLaunchFingerprint,
                    incarnation: exec.durableIncarnation,
                    storageGeneration: exec.storageGeneration,
                    previousStorageGeneration: attachment.previousStorageGeneration
                ),
                fd: fd
            )
            let handshake = try waitForProcessStartAck(
                fd: fd,
                expectedProcessID: guestProcessID,
                timeoutSeconds: 3
            )
            let durableStatus: MacOSGuestProcessStatusPayload?
            if durable {
                guard let status = handshake.status else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "durable process start ack is missing identity status"
                    )
                }
                try validateDurableProcessStatus(status, expectedExecutionID: guestProcessID)
                guard status.disposition == .created || status.state == .running else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "durable process retry returned terminal state \(status.state.rawValue)"
                    )
                }
                if generationFenced, status.storageGeneration != exec.storageGeneration {
                    throw ContainerizationError(
                        .invalidState,
                        message: "durable process start ack returned a different storage generation"
                    )
                }
                if identityFenced,
                    status.trustedLaunchFingerprint != exec.durableLaunchFingerprint
                        || status.incarnation != exec.durableIncarnation
                {
                    throw ContainerizationError(
                        .invalidState,
                        message: "durable process start ack returned a different trusted identity"
                    )
                }
                durableStatus = status
            } else {
                durableStatus = nil
            }
            let session = try ProcessStreamSession(
                processID: processID,
                guestProcessID: guestProcessID,
                durable: durable,
                requestFingerprint: requestFingerprint,
                port: port,
                launchFingerprint: durableStatus?.launchFingerprint,
                storageGeneration: durableStatus?.storageGeneration,
                processIdentifier: durableStatus?.processIdentifier,
                trustedLaunchFingerprint: exec.durableLaunchFingerprint,
                incarnation: exec.durableIncarnation,
                replayCursor: replayCursor,
                fd: fd
            )
            unregisteredSession = session
            if handshake.status?.replayTruncated == true {
                emitEvent(
                    .init(
                        event: .processError,
                        processID: processID,
                        message: "durable process output replay was truncated before cursor \(replayCursor)"
                    )
                )
            }
            guard let connection = session.currentConnection() else {
                throw ContainerizationError(.invalidState, message: "new process stream was detached before registration")
            }
            try registerProcessSessionAndStartReadLoop(
                session,
                connection: connection,
                initialFrames: handshake.bufferedFrames
            )
            unregisteredSession = nil
        } catch {
            if let unregisteredSession {
                unregisteredSession.cancelAndClose()
            } else {
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
            throw error
        }
    }

    private func connectProcessStream(port: UInt32) throws -> Int32 {
        if let processConnectionFactory {
            return try processConnectionFactory(port)
        }
        return try syncValue {
            try await self.service.connectVsock(port: port)
        }
    }

    private func inspectDurableProcess(
        port: UInt32,
        processID: String,
        exec: MacOSSidecarExecRequestPayload
    ) throws -> MacOSGuestProcessStatusPayload {
        let session = try processSession(for: processID)
        guard session.durable else {
            throw ContainerizationError(.invalidArgument, message: "process \(processID) is not durable")
        }
        guard session.port == port else {
            throw ContainerizationError(.invalidArgument, message: "process \(processID) uses a different guest-agent port")
        }
        guard session.requestFingerprint == (try processRequestFingerprint(exec)) else {
            throw ContainerizationError(.exists, message: "process \(processID) has a different launch request")
        }
        if let retryError = session.startRetryError() {
            throw retryError
        }

        let status = try queryDurableProcess(port: port, executionID: session.guestProcessID)
        if let retryError = session.startRetryError() {
            throw retryError
        }
        do {
            try validateDurableProcessStatus(status, session: session)
        } catch let error as ProcessReconnectIdentityError {
            throw ContainerizationError(.invalidState, message: error.reason)
        }
        return status
    }

    private func queryDurableProcess(port: UInt32, executionID: String) throws -> MacOSGuestProcessStatusPayload {
        let fd = try connectProcessStream(port: port)
        defer {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }

        let capabilities = try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
        guard capabilities.contains(MacOSGuestProcessProtocol.durableProcessV1) else {
            throw ContainerizationError(.unsupported, message: "guest agent does not support durable workload processes")
        }
        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame(type: .processInspect, id: executionID),
            fd: fd
        )
        guard
            let status = try waitForGuestProcessCommandAck(
                fd: fd,
                expectedExecutionID: executionID,
                operation: "inspect",
                timeoutSeconds: 3
            )
        else {
            throw ContainerizationError(.invalidState, message: "durable process inspect ack is missing identity status")
        }
        try validateDurableProcessStatus(status, expectedExecutionID: executionID)
        return status
    }

    private func validateDurableProcessStatus(
        _ status: MacOSGuestProcessStatusPayload,
        expectedExecutionID: String
    ) throws {
        guard status.executionID == expectedExecutionID else {
            throw ContainerizationError(.invalidState, message: "durable process status returned a different execution identifier")
        }
        guard !status.launchFingerprint.isEmpty else {
            throw ContainerizationError(.invalidState, message: "durable process status is missing a launch fingerprint")
        }
        if let storageGeneration = status.storageGeneration, storageGeneration == 0 {
            throw ContainerizationError(.invalidState, message: "durable process status has an invalid storage generation")
        }
        guard status.processIdentifier > 0 else {
            throw ContainerizationError(.invalidState, message: "durable process status has an invalid process identifier")
        }
    }

    private func validateDurableProcessStatus(
        _ status: MacOSGuestProcessStatusPayload,
        session: ProcessStreamSession
    ) throws {
        try validateDurableProcessStatus(status, expectedExecutionID: session.guestProcessID)
        guard status.launchFingerprint == session.launchFingerprint else {
            throw ProcessReconnectIdentityError(reason: "durable process launch fingerprint changed")
        }
        guard status.trustedLaunchFingerprint == session.trustedLaunchFingerprint else {
            throw ProcessReconnectIdentityError(reason: "durable process trusted launch fingerprint changed")
        }
        guard status.incarnation == session.incarnation else {
            throw ProcessReconnectIdentityError(reason: "durable process incarnation changed")
        }
        guard status.storageGeneration == session.storageGeneration else {
            throw ProcessReconnectIdentityError(reason: "durable process storage generation changed")
        }
        guard status.processIdentifier == session.processIdentifier else {
            throw ProcessReconnectIdentityError(reason: "durable process identifier changed")
        }
    }

    private func deleteDurableProcess(
        port: UInt32,
        identity: MacOSSidecarDurableProcessDeleteIdentity
    ) throws {
        try validateDurableProcessDeleteIdentity(identity)
        let existing = processSession(forExecutionID: identity.executionID)
        let matchingExisting = existing.flatMap { $0.matchesDeleteIdentity(identity) ? $0 : nil }
        if let matchingExisting {
            guard matchingExisting.port == port else {
                throw ContainerizationError(.invalidArgument, message: "durable delete uses a different guest-agent port")
            }
            try matchingExisting.prepareForDelete(identity)
        }

        let fd = try connectProcessStream(port: port)
        defer {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }

        let capabilities = try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
        guard capabilities.contains(MacOSGuestProcessProtocol.durableProcessV1) else {
            throw ContainerizationError(
                .unsupported,
                message: "guest agent does not support durable workload processes"
            )
        }
        if identity.storageGeneration != nil,
            !capabilities.contains(MacOSGuestProcessProtocol.durableProcessV2)
        {
            throw ContainerizationError(
                .unsupported,
                message: "guest agent does not support generation-fenced durable workload processes"
            )
        }
        guard capabilities.contains(MacOSGuestProcessProtocol.durableProcessV4) else {
            throw ContainerizationError(
                .unsupported,
                message: "guest agent does not support incarnation-fenced durable workload processes"
            )
        }

        let status: MacOSGuestProcessStatusPayload?
        do {
            try MacOSSidecarSocketIO.writeJSONFrame(
                SidecarGuestAgentFrame(type: .processInspect, id: identity.executionID),
                fd: fd,
                timeoutMilliseconds: 1_000
            )
            guard
                let inspected = try waitForGuestProcessCommandAck(
                    fd: fd,
                    expectedExecutionID: identity.executionID,
                    operation: "inspect for delete",
                    timeoutSeconds: 3
                )
            else {
                throw ContainerizationError(.invalidState, message: "durable delete inspect ack is missing identity status")
            }
            try validateDurableProcessStatus(inspected, expectedExecutionID: identity.executionID)
            if inspected.incarnation == identity.incarnation {
                guard inspected.trustedLaunchFingerprint == identity.trustedLaunchFingerprint else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "durable delete trusted launch fingerprint does not match the guest process"
                    )
                }
                guard inspected.storageGeneration == identity.storageGeneration else {
                    throw ContainerizationError(.invalidState, message: "durable delete storage generation does not match the guest process")
                }
                if let matchingExisting {
                    do {
                        try validateDurableProcessStatus(inspected, session: matchingExisting)
                    } catch let error as ProcessReconnectIdentityError {
                        throw ContainerizationError(.invalidState, message: error.reason)
                    }
                }
                status = inspected
            } else {
                status = nil
            }
        } catch let error as ContainerizationError where error.code == .notFound {
            status = nil
        }

        try MacOSSidecarSocketIO.writeJSONFrame(
            SidecarGuestAgentFrame.processDelete(
                id: identity.executionID,
                expectedLaunchFingerprint: status?.launchFingerprint,
                trustedLaunchFingerprint: identity.trustedLaunchFingerprint,
                incarnation: identity.incarnation,
                storageGeneration: identity.storageGeneration
            ),
            fd: fd,
            timeoutMilliseconds: 1_000
        )
        _ = try waitForGuestProcessCommandAck(
            fd: fd,
            expectedExecutionID: identity.executionID,
            operation: "delete",
            timeoutSeconds: 3
        )
        if let matchingExisting {
            cancelProcessSession(matchingExisting)
        }
    }

    private func validateDurableProcessDeleteIdentity(
        _ identity: MacOSSidecarDurableProcessDeleteIdentity
    ) throws {
        guard !identity.executionID.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "durable delete execution identifier must not be empty")
        }
        let prefix = "sha256:"
        let digest = identity.trustedLaunchFingerprint.dropFirst(prefix.count)
        guard identity.trustedLaunchFingerprint.hasPrefix(prefix), digest.count == 64,
            digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        else {
            throw ContainerizationError(.invalidArgument, message: "durable delete launch fingerprint must be canonical SHA-256")
        }
        let incarnationDigest = identity.incarnation.dropFirst(prefix.count)
        guard identity.incarnation.hasPrefix(prefix), incarnationDigest.count == 64,
            incarnationDigest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        else {
            throw ContainerizationError(.invalidArgument, message: "durable delete incarnation must be canonical SHA-256")
        }
        if let storageGeneration = identity.storageGeneration, storageGeneration == 0 {
            throw ContainerizationError(.invalidArgument, message: "durable delete storage generation must be positive")
        }
    }

    private func scheduleProcessReconnect(_ session: ProcessStreamSession) {
        guard session.beginReconnect() else { return }
        processReconnectQueue.async { [weak self, session] in
            self?.reconnectProcessSession(session)
        }
    }

    private func reconnectProcessSession(_ session: ProcessStreamSession) {
        var retryDelay = processReconnectDelayMicroseconds
        while session.shouldContinueReconnect() {
            if retryDelay > 0 {
                usleep(retryDelay)
            }
            guard session.shouldContinueReconnect() else { return }

            var fd: Int32 = -1
            do {
                fd = try connectProcessStream(port: session.port)
                let capabilities = try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
                guard capabilities.contains(MacOSGuestProcessProtocol.durableProcessV1) else {
                    throw ContainerizationError(
                        .unsupported,
                        message: "guest agent does not support durable workload processes"
                    )
                }
                guard capabilities.contains(MacOSGuestProcessProtocol.durableProcessV3) else {
                    throw ContainerizationError(
                        .unsupported,
                        message: "guest agent does not support consumer-acknowledged durable process events"
                    )
                }
                if session.storageGeneration != nil,
                    !capabilities.contains(MacOSGuestProcessProtocol.durableProcessV2)
                {
                    throw ContainerizationError(
                        .unsupported,
                        message: "guest agent does not support generation-fenced durable workload processes"
                    )
                }
                if session.incarnation != nil,
                    !capabilities.contains(MacOSGuestProcessProtocol.durableProcessV4)
                {
                    throw ContainerizationError(
                        .unsupported,
                        message: "guest agent does not support incarnation-fenced durable workload processes"
                    )
                }

                let cursor = session.deliveredCursor()
                try MacOSSidecarSocketIO.writeJSONFrame(
                    SidecarGuestAgentFrame.processAttach(
                        id: session.guestProcessID,
                        cursor: cursor,
                        expectedLaunchFingerprint: session.launchFingerprint,
                        trustedLaunchFingerprint: session.trustedLaunchFingerprint,
                        incarnation: session.incarnation,
                        storageGeneration: session.storageGeneration
                    ),
                    fd: fd
                )
                guard
                    let status = try waitForGuestProcessCommandAck(
                        fd: fd,
                        expectedExecutionID: session.guestProcessID,
                        operation: "attach",
                        timeoutSeconds: 3
                    )
                else {
                    throw ContainerizationError(.invalidState, message: "durable process attach ack is missing identity status")
                }
                try validateDurableProcessStatus(status, session: session)
                guard let connection = try session.installReconnected(fd: fd, status: status) else {
                    _ = Darwin.shutdown(fd, SHUT_RDWR)
                    Darwin.close(fd)
                    return
                }
                if status.replayTruncated {
                    emitEvent(
                        .init(
                            event: .processError,
                            processID: session.processID,
                            message: "durable process output replay was truncated before cursor \(cursor)"
                        )
                    )
                }
                log.info(
                    "durable process stream reattached",
                    metadata: [
                        "process_id": "\(session.processID)",
                        "execution_id": "\(session.guestProcessID)",
                        "cursor": "\(cursor)",
                        "pid": "\(status.processIdentifier)",
                    ]
                )
                _ = startProcessReadLoop(session, connection: connection)
                return
            } catch {
                if fd >= 0 {
                    _ = Darwin.shutdown(fd, SHUT_RDWR)
                    Darwin.close(fd)
                }
                if isPermanentProcessReconnectFailure(error) {
                    session.finishReconnect(blocked: true)
                    emitEvent(
                        .init(
                            event: .processError,
                            processID: session.processID,
                            message: "durable process reconnect was rejected: \(error.localizedDescription)"
                        )
                    )
                    return
                }
                log.warning(
                    "durable process reconnect attempt failed",
                    metadata: [
                        "process_id": "\(session.processID)",
                        "execution_id": "\(session.guestProcessID)",
                        "error": "\(error)",
                    ]
                )
                retryDelay = min(max(retryDelay, 50_000) * 2, 1_000_000)
            }
        }
        session.finishReconnect(blocked: false)
    }

    private func isPermanentProcessReconnectFailure(_ error: Error) -> Bool {
        if error is ProcessReconnectIdentityError {
            return true
        }
        guard let containerError = error as? ContainerizationError else {
            return false
        }
        switch containerError.code {
        case .notFound, .exists, .invalidArgument, .invalidState, .unsupported:
            return true
        default:
            return false
        }
    }

    private func waitForGuestProcessCommandAck(
        fd: Int32,
        expectedExecutionID: String,
        operation: String,
        timeoutSeconds: TimeInterval
    ) throws -> MacOSGuestProcessStatusPayload? {
        let deadline = sidecarReadDeadline(timeoutSeconds: timeoutSeconds)
        do {
            while true {
                let frame = try MacOSSidecarSocketIO.readJSONFrame(
                    SidecarGuestAgentFrame.self,
                    fd: fd,
                    timeoutMilliseconds: try sidecarRemainingReadMilliseconds(until: deadline)
                )
                switch frame.type {
                case .ack:
                    guard frame.id == expectedExecutionID else {
                        throw ContainerizationError(
                            .internalError,
                            message:
                                "durable process \(operation) ack ID mismatch (expected=\(expectedExecutionID) actual=\(frame.id ?? "nil"))"
                        )
                    }
                    return try frame.data.map {
                        try JSONDecoder().decode(MacOSGuestProcessStatusPayload.self, from: $0)
                    }
                case .error:
                    throw guestProcessCommandError(frame, operation: operation)
                case .stdout, .stderr, .exit, .ready:
                    continue
                case .exec, .processInspect, .processAttach, .processEventAck, .processStop, .processDelete, .stdin, .signal,
                    .resize, .close, .networkConfigure, .networkResult, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin,
                    .fsReadChunk, .fsReadEnd, .fsListDir:
                    continue
                }
            }
        } catch  where isSidecarReadTimeout(error) {
            throw ContainerizationError(
                .timeout,
                message: "timed out waiting for durable process \(operation) ack for \(expectedExecutionID)"
            )
        }
    }

    private func guestProcessCommandError(
        _ frame: SidecarGuestAgentFrame,
        operation: String
    ) -> ContainerizationError {
        let message = frame.message ?? "unknown guest-agent error"
        let code: ContainerizationError.Code
        if let errorCode = frame.errorCode {
            switch errorCode {
            case ENOENT:
                code = .notFound
            case EEXIST:
                code = .exists
            case EINVAL:
                code = .invalidArgument
            case ESTALE, EPERM:
                code = .invalidState
            case EBUSY:
                code = .interrupted
            default:
                code = .internalError
            }
        } else {
            // Compatibility fallback for guest agents predating structured
            // errno frames. Structured errorCode always takes precedence.
            let lowered = message.lowercased()
            if lowered.contains("not found") || lowered.contains("code=2") {
                code = .notFound
            } else if lowered.contains("conflict") || lowered.contains("already exists") {
                code = .exists
            } else {
                code = .internalError
            }
        }
        return ContainerizationError(
            code,
            message: "guest-agent durable process \(operation) failed: \(message)"
        )
    }

    private func guestExecutableLaunch(executable: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        guard !executable.isEmpty, !executable.contains("/") else {
            return (executable, arguments)
        }
        return ("/usr/bin/env", [executable] + arguments)
    }

    @discardableResult
    private func startProcessReadLoop(
        _ session: ProcessStreamSession,
        connection: ProcessStreamConnection,
        initialFrames: [SidecarGuestAgentFrame] = []
    ) -> Bool {
        guard session.claimReader(connection) else { return false }
        Thread.detachNewThread { [weak self] in
            guard let self else {
                Darwin.close(connection.readerFD)
                return
            }
            self.processReadLoop(session, connection: connection, initialFrames: initialFrames)
        }
        return true
    }

    private func processReadLoop(
        _ session: ProcessStreamSession,
        connection: ProcessStreamConnection,
        initialFrames: [SidecarGuestAgentFrame] = []
    ) {
        let processID = session.processID
        var exitEmitted = false
        var pendingExitCode: Int32?
        var pendingExitSequence: UInt64?
        var bufferedFrames = ArraySlice(initialFrames)
        defer { Darwin.close(connection.readerFD) }
        defer {
            let detached = session.durable && exitEmitted ? false : session.detach(connection)
            if session.durable {
                if detached, !exitEmitted {
                    scheduleProcessReconnect(session)
                }
            } else {
                _ = removeProcessSession(processID, matching: session)
                if !exitEmitted {
                    emitEvent(
                        .init(
                            event: .processExit,
                            processID: processID,
                            exitCode: pendingExitCode ?? 1,
                            sequence: pendingExitSequence
                        )
                    )
                }
            }
        }

        do {
            while true {
                let frame: SidecarGuestAgentFrame
                if let bufferedFrame = bufferedFrames.first {
                    frame = bufferedFrame
                    bufferedFrames.removeFirst()
                } else if pendingExitCode == nil {
                    frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: connection.readerFD)
                } else {
                    guard let drained = try readProcessFrameIfAvailable(fd: connection.readerFD, timeoutMilliseconds: 100) else {
                        session.markTerminal()
                        emitProcessEvent(
                            .init(
                                event: .processExit,
                                processID: processID,
                                exitCode: pendingExitCode,
                                sequence: pendingExitSequence
                            ),
                            session: session,
                            sequence: pendingExitSequence
                        )
                        exitEmitted = true
                        return
                    }
                    frame = drained
                }
                if session.durable {
                    guard frame.id == session.guestProcessID else {
                        if frame.type == .stdout || frame.type == .stderr || frame.type == .exit {
                            emitEvent(
                                .init(
                                    event: .processError,
                                    processID: processID,
                                    message: "durable process event identifier mismatch"
                                )
                            )
                        }
                        continue
                    }
                    if frame.type == .stdout || frame.type == .stderr || frame.type == .exit {
                        guard session.reserve(sequence: frame.sequence) else { continue }
                    }
                }
                switch frame.type {
                case .stdout:
                    if let data = frame.data, !data.isEmpty {
                        emitProcessEvent(
                            .init(
                                event: .processStdout,
                                processID: processID,
                                data: data,
                                sequence: frame.sequence
                            ),
                            session: session,
                            sequence: frame.sequence
                        )
                    } else {
                        acknowledgeProcessEvent(session: session, sequence: frame.sequence)
                    }
                case .stderr:
                    if let data = frame.data, !data.isEmpty {
                        emitProcessEvent(
                            .init(
                                event: .processStderr,
                                processID: processID,
                                data: data,
                                sequence: frame.sequence
                            ),
                            session: session,
                            sequence: frame.sequence
                        )
                    } else {
                        acknowledgeProcessEvent(session: session, sequence: frame.sequence)
                    }
                case .error:
                    emitEvent(.init(event: .processError, processID: processID, message: frame.message ?? "unknown guest-agent error"))
                case .exit:
                    pendingExitCode = frame.exitCode ?? 1
                    pendingExitSequence = frame.sequence
                case .ready:
                    continue
                case .ack, .exec, .processInspect, .processAttach, .processEventAck, .processStop, .processDelete, .stdin, .signal,
                    .resize, .close, .networkConfigure, .networkResult, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin,
                    .fsReadChunk, .fsReadEnd, .fsListDir:
                    continue
                }
            }
        } catch {
            if let pendingExitCode, isExpectedEOF(error) {
                session.markTerminal()
                emitProcessEvent(
                    .init(
                        event: .processExit,
                        processID: processID,
                        exitCode: pendingExitCode,
                        sequence: pendingExitSequence
                    ),
                    session: session,
                    sequence: pendingExitSequence
                )
                exitEmitted = true
                return
            }
            if session.durable {
                log.warning(
                    "durable process stream detached",
                    metadata: [
                        "process_id": "\(processID)",
                        "execution_id": "\(session.guestProcessID)",
                        "cursor": "\(session.deliveredCursor())",
                        "error": "\(error)",
                    ]
                )
            } else if !isExpectedEOF(error) {
                emitEvent(.init(event: .processError, processID: processID, message: "sidecar process stream read failed: \(error.localizedDescription)"))
            }
        }
    }

    @discardableResult
    private func emitProcessEvent(
        _ event: MacOSSidecarEvent,
        session: ProcessStreamSession,
        sequence: UInt64?
    ) -> Bool {
        emitEvent(event) { [weak self, weak session] in
            guard let self, let session else { return }
            self.acknowledgeProcessEvent(session: session, sequence: sequence)
        }
    }

    private func acknowledgeProcessEvent(
        session: ProcessStreamSession,
        sequence: UInt64?
    ) {
        do {
            try session.acknowledgeDeliveredEvent(sequence: sequence)
        } catch {
            log.warning(
                "failed to forward durable process event acknowledgement",
                metadata: [
                    "process_id": "\(session.processID)",
                    "execution_id": "\(session.guestProcessID)",
                    "sequence": "\(sequence.map(String.init) ?? "-")",
                    "error": "\(error)",
                ]
            )
        }
    }

    private func waitForProcessStartAck(
        fd: Int32,
        expectedProcessID: String,
        timeoutSeconds: TimeInterval
    ) throws -> ProcessStartHandshake {
        let deadline = sidecarReadDeadline(timeoutSeconds: timeoutSeconds)
        do {
            return try readProcessStartAck(
                fd: fd,
                expectedProcessID: expectedProcessID,
                deadlineUptimeNanoseconds: deadline
            )
        } catch  where isSidecarReadTimeout(error) {
            throw ContainerizationError(
                .timeout,
                message: "timed out waiting for guest-agent process start ack for \(expectedProcessID)"
            )
        }
    }

    private func readProcessStartAck(
        fd: Int32,
        expectedProcessID: String,
        deadlineUptimeNanoseconds: UInt64
    ) throws -> ProcessStartHandshake {
        var bufferedFrames: [SidecarGuestAgentFrame] = []
        while true {
            let frame = try MacOSSidecarSocketIO.readJSONFrame(
                SidecarGuestAgentFrame.self,
                fd: fd,
                timeoutMilliseconds: try sidecarRemainingReadMilliseconds(until: deadlineUptimeNanoseconds)
            )
            switch frame.type {
            case .ack:
                guard frame.id == expectedProcessID else {
                    throw ContainerizationError(
                        .internalError,
                        message: "guest-agent process start ack ID mismatch (expected=\(expectedProcessID) actual=\(frame.id ?? "nil"))"
                    )
                }
                let status = try frame.data.map {
                    try JSONDecoder().decode(MacOSGuestProcessStatusPayload.self, from: $0)
                }
                return .init(bufferedFrames: bufferedFrames, status: status)
            case .error:
                throw guestProcessCommandError(frame, operation: "start")
            case .exit:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent process stream exited before start ack for \(expectedProcessID) (code=\(frame.exitCode ?? 1))"
                )
            case .stdout, .stderr:
                bufferedFrames.append(frame)
            case .ready:
                continue
            case .exec, .processInspect, .processAttach, .processEventAck, .processStop, .processDelete, .stdin, .signal, .resize,
                .close, .networkConfigure, .networkResult, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk,
                .fsReadEnd, .fsListDir:
                continue
            }
        }
    }

    private func readProcessFrameIfAvailable(fd: Int32, timeoutMilliseconds: Int32) throws -> SidecarGuestAgentFrame? {
        let deadline = sidecarReadDeadline(timeoutSeconds: Double(timeoutMilliseconds) / 1_000)
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let result = withUnsafeMutablePointer(to: &descriptor) { pointer in
                Darwin.poll(pointer, 1, (try? sidecarRemainingReadMilliseconds(until: deadline)) ?? 0)
            }

            if result == 0 {
                return nil
            }
            if result > 0 {
                if descriptor.revents & Int16(POLLIN) != 0 {
                    return try MacOSSidecarSocketIO.readJSONFrame(
                        SidecarGuestAgentFrame.self,
                        fd: fd,
                        timeoutMilliseconds: try sidecarRemainingReadMilliseconds(until: deadline)
                    )
                }
                if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    return nil
                }
                continue
            }

            if errno == EINTR {
                continue
            }
            throw POSIXError.fromErrno()
        }
    }

    private func waitForFSAck(fd: Int32, expectedID: String) throws {
        while true {
            let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
            switch frame.type {
            case .ack:
                guard frame.id == expectedID else {
                    throw ContainerizationError(
                        .internalError,
                        message: "filesystem ack transaction ID mismatch (expected=\(expectedID) actual=\(frame.id ?? "nil"))"
                    )
                }
                return
            case .error:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent filesystem error for transaction \(expectedID): \(frame.message ?? "unknown error")"
                )
            case .exit:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent filesystem stream exited for transaction \(expectedID) (code=\(frame.exitCode ?? 1))"
                )
            case .ready, .stdout, .stderr, .networkResult:
                continue
            case .exec, .processInspect, .processAttach, .processEventAck, .processStop, .processDelete, .stdin, .signal, .resize,
                .close, .networkConfigure, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd,
                .fsListDir:
                continue
            }
        }
    }

    /// Like waitForFSAck but also returns the data payload from the ack frame.
    /// Returns nil data if the ack frame has no data (e.g. EOF for fsReadChunk).
    private func waitForFSAckWithData(fd: Int32, expectedID: String) throws -> Data? {
        while true {
            let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
            switch frame.type {
            case .ack:
                guard frame.id == expectedID else {
                    throw ContainerizationError(
                        .internalError,
                        message: "filesystem ack transaction ID mismatch (expected=\(expectedID) actual=\(frame.id ?? "nil"))"
                    )
                }
                return frame.data
            case .error:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent filesystem error for transaction \(expectedID): \(frame.message ?? "unknown error")"
                )
            case .exit:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent filesystem stream exited for transaction \(expectedID) (code=\(frame.exitCode ?? 1))"
                )
            case .ready, .stdout, .stderr, .networkResult:
                continue
            case .exec, .processInspect, .processAttach, .processEventAck, .processStop, .processDelete, .stdin, .signal, .resize,
                .close, .networkConfigure, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd,
                .fsListDir:
                continue
            }
        }
    }

    private func logFS(
        _ message: String,
        txID: String,
        op: MacOSSidecarFSOperation,
        path: String,
        extra: [String: String] = [:]
    ) {
        var metadata: Logger.Metadata = [
            "tx_id": "\(txID)",
            "op": "\(op.rawValue)",
            "path": "\(path)",
        ]
        for (key, value) in extra {
            metadata[key] = "\(value)"
        }
        log.info("filesystem transfer \(message)", metadata: metadata)
    }

    private func logFS(_ message: String, session: FSTransferSession, extra: [String: String] = [:]) {
        logFS(message, txID: session.txID, op: session.op, path: session.path, extra: extra)
    }

    private func waitForGuestAgentReadyWithTimeout(fd: Int32, timeoutSeconds: TimeInterval) throws -> Set<String> {
        let deadline = sidecarReadDeadline(timeoutSeconds: timeoutSeconds)
        do {
            while true {
                let frame = try MacOSSidecarSocketIO.readJSONFrame(
                    SidecarGuestAgentFrame.self,
                    fd: fd,
                    timeoutMilliseconds: try sidecarRemainingReadMilliseconds(until: deadline)
                )
                switch frame.type {
                case .ready:
                    return Set(frame.capabilities ?? [])
                case .error:
                    throw ContainerizationError(.internalError, message: "guest-agent error before ready: \(frame.message ?? "unknown error")")
                case .exit:
                    throw ContainerizationError(.internalError, message: "guest-agent exited before ready (code=\(frame.exitCode ?? 1))")
                case .stdout, .stderr, .ack, .exec, .processInspect, .processAttach, .processEventAck, .processStop,
                    .processDelete, .stdin, .signal, .resize, .close, .networkConfigure, .networkResult,
                    .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd, .fsListDir:
                    continue
                }
            }
        } catch  where isSidecarReadTimeout(error) {
            throw ContainerizationError(.timeout, message: "timed out waiting for guest-agent ready frame")
        }
    }

    private func failureResponse(requestID: String, error: Error) -> MacOSSidecarResponse {
        if let rpcError = error as? SidecarRPCError {
            return .failure(
                requestID: requestID,
                code: rpcError.code,
                message: rpcError.message,
                details: rpcError.details,
                metadata: rpcError.metadata,
                protocolVersion: MacOSSidecarProtocolVersion.current
            )
        }
        let normalized = normalizedError(error)
        return .failure(
            requestID: requestID,
            code: normalized.code.description,
            message: normalized.message,
            details: responseErrorDetails(for: normalized),
            protocolVersion: MacOSSidecarProtocolVersion.current
        )
    }

    private func normalizedError(_ error: Error) -> ContainerizationError {
        if let containerError = error as? ContainerizationError {
            return containerError
        }
        let nsError = error as NSError
        return ContainerizationError(.internalError, message: nsError.localizedDescription, cause: error)
    }

    private func responseErrorDetails(for error: ContainerizationError) -> String? {
        if let cause = error.cause {
            return String(describing: cause)
        }
        return nil
    }

    private func ensureCheckpointAllowsNewSession() throws {
        processLock.lock()
        let checkpointInProgress = activeCheckpoint != nil
        processLock.unlock()
        guard !checkpointInProgress else {
            throw SidecarRPCError(
                code: "checkpointInProgress",
                message: "new sidecar sessions are blocked by checkpoint preparation"
            )
        }
    }

    private func replayPreparedCheckpoint(
        checkpointID: String,
        persistenceID: String,
        storageGeneration: UInt64,
        sourcePodUID: String?
    ) throws -> MacOSMachineStateCheckpointResult? {
        processLock.lock()
        defer { processLock.unlock() }
        guard let activeCheckpoint else {
            return nil
        }
        guard activeCheckpoint.result.checkpointID == checkpointID,
            activeCheckpoint.result.persistenceID == persistenceID,
            activeCheckpoint.result.storageGeneration == storageGeneration,
            activeCheckpoint.result.adoption.sourcePodUID == sourcePodUID
        else {
            throw SidecarRPCError(
                code: "checkpointConflict",
                message: "another checkpoint already owns the sidecar"
            )
        }
        return activeCheckpoint.result
    }

    private func prepareCheckpoint(
        _ payload: MacOSMachineStateRequestPayload
    ) throws -> MacOSMachineStateCheckpointResult {
        guard let checkpointID = payload.checkpointID, !checkpointID.isEmpty,
            let persistenceID = payload.persistenceID, !persistenceID.isEmpty,
            let storageGeneration = payload.sourceStorageGeneration, storageGeneration > 0
        else {
            throw SidecarRPCError(
                code: "invalidArgument",
                message: "checkpoint preparation requires checkpoint, persistence, and storage generation identities"
            )
        }

        checkpointAdmissionLock.lock()
        defer { checkpointAdmissionLock.unlock() }

        if let replay = try replayPreparedCheckpoint(
            checkpointID: checkpointID,
            persistenceID: persistenceID,
            storageGeneration: storageGeneration,
            sourcePodUID: payload.sourcePodUID
        ) {
            return replay
        }

        guard eventDelivery.pendingCount() == 0 else {
            throw SidecarRPCError(
                code: "checkpointOutputPending",
                message: "durable process output is still awaiting consumer acknowledgement"
            )
        }
        fsLock.lock()
        let hasFSSessions = !fsSessions.isEmpty
        fsLock.unlock()
        fsReadLock.lock()
        let hasFSReadSessions = !fsReadSessions.isEmpty
        fsReadLock.unlock()
        guard !hasFSSessions, !hasFSReadSessions else {
            throw SidecarRPCError(
                code: "checkpointTransientSessionActive",
                message: "filesystem transfer is active during checkpoint preparation"
            )
        }

        processLock.lock()
        defer { processLock.unlock() }
        let workloads = try processSessions.values
            .map { try $0.checkpointWorkload(expectedStorageGeneration: storageGeneration) }
            .sorted { $0.runtimeWorkloadID < $1.runtimeWorkloadID }
        guard !workloads.isEmpty else {
            throw SidecarRPCError(
                code: "checkpointWorkloadUnavailable",
                message: "checkpoint preparation requires at least one durable workload"
            )
        }
        let adoption = MacOSMachineStateAdoptionManifest(
            checkpointID: checkpointID,
            persistenceID: persistenceID,
            sourcePodUID: payload.sourcePodUID,
            sourceStorageGeneration: storageGeneration,
            workloads: workloads
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(adoption))
            .map { String(format: "%02x", $0) }
            .joined()
        let result = MacOSMachineStateCheckpointResult(
            checkpointID: checkpointID,
            persistenceID: persistenceID,
            storageGeneration: storageGeneration,
            adoption: adoption,
            adoptionManifestDigest: digest
        )
        activeCheckpoint = ActiveCheckpoint(result: result, sourcePodUID: payload.sourcePodUID)
        return result
    }

    private func durablePairSaveInputs(
        stateID: String,
        payload: MacOSMachineStateRequestPayload
    ) throws -> (
        adoption: MacOSMachineStateAdoptionManifest,
        pair: MacOSMachineStateDurablePair
    ) {
        processLock.lock()
        defer { processLock.unlock() }
        guard let checkpoint = activeCheckpoint?.result,
            payload.checkpointID == checkpoint.checkpointID,
            payload.persistenceID == checkpoint.persistenceID,
            let diskSnapshot = payload.diskSnapshot,
            diskSnapshot.snapshotID == stateID,
            diskSnapshot.storageGeneration == checkpoint.storageGeneration,
            let pairID = payload.pairID,
            let compatibilityClass = payload.compatibilityClass,
            payload.adoptionManifestDigest == checkpoint.adoptionManifestDigest
        else {
            throw SidecarRPCError(
                code: "durablePairMismatch",
                message: "machine-state save does not match the prepared checkpoint"
            )
        }
        return (
            checkpoint.adoption,
            .init(
                pairID: pairID,
                persistenceID: checkpoint.persistenceID,
                stateID: stateID,
                stateGeneration: checkpoint.storageGeneration,
                diskSnapshot: diskSnapshot,
                compatibilityClass: compatibilityClass,
                adoptionManifestDigest: checkpoint.adoptionManifestDigest
            )
        )
    }

    private func abortCheckpoint(_ payload: MacOSMachineStateRequestPayload) throws {
        guard let checkpointID = payload.checkpointID, !checkpointID.isEmpty else {
            throw SidecarRPCError(code: "invalidArgument", message: "checkpoint id is required")
        }
        checkpointAdmissionLock.lock()
        defer { checkpointAdmissionLock.unlock() }
        processLock.lock()
        defer { processLock.unlock() }
        guard let activeCheckpoint else {
            return
        }
        guard activeCheckpoint.result.checkpointID == checkpointID else {
            throw SidecarRPCError(
                code: "checkpointConflict",
                message: "checkpoint abort does not own the active checkpoint"
            )
        }
        self.activeCheckpoint = nil
    }

    private func perform(request: MacOSSidecarRequest, clientFD: Int32) throws -> MacOSSidecarResponse {
        let service = self.service
        let requestID = request.requestID
        if let versionError = protocolVersionError(for: request) {
            return failureResponse(requestID: requestID, error: versionError)
        }
        switch request.method {
        case .vmBootstrapStart:
            log.info(
                "sidecar control vmBootstrapStart request",
                metadata: [
                    "request_id": "\(requestID)",
                    "present_gui": "\(request.presentGUI ?? true)",
                ])
            return try sync(requestID: requestID) {
                try await service.bootstrapStart(presentGUI: request.presentGUI ?? true)
                return .success(requestID: requestID)
            }
        case .vmShowGUI:
            log.info("sidecar control vmShowGUI request", metadata: ["request_id": "\(requestID)"])
            return try sync(requestID: requestID) {
                try await service.showGUIWindow()
                return .success(requestID: requestID)
            }
        case .vmConnectVsock:
            guard let port = request.port else {
                try MacOSSidecarSocketIO.sendNoFileDescriptorMarker(socketFD: clientFD)
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing port")
            }
            do {
                let fd = try syncValue {
                    try await service.connectVsock(port: port)
                }
                defer { Darwin.close(fd) }
                try MacOSSidecarSocketIO.sendFileDescriptorMarker(socketFD: clientFD, descriptorFD: fd)
                return .success(requestID: requestID, fdAttached: true)
            } catch {
                try MacOSSidecarSocketIO.sendNoFileDescriptorMarker(socketFD: clientFD)
                return failureResponse(requestID: requestID, error: error)
            }
        case .eventsSubscribe:
            let acknowledgementRequired = request.protocolVersion == MacOSSidecarProtocolVersion.durableEventAcknowledgement
            let subscription = subscribeEventClient(fd: clientFD, acknowledgementRequired: acknowledgementRequired)
            guard subscription.claimed else {
                return .failure(
                    requestID: requestID,
                    code: "eventClientAlreadySubscribed",
                    message: "another client already owns the sidecar event subscription",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            let data = try subscription.subscriptionID.map {
                try JSONEncoder().encode(MacOSSidecarEventSubscription(subscriptionID: $0))
            }
            return .success(
                requestID: requestID,
                data: data,
                protocolVersion: MacOSSidecarProtocolVersion.current
            )
        case .eventsAcknowledge:
            guard let acknowledgement = request.eventAcknowledgement else {
                return .failure(
                    requestID: requestID,
                    code: "invalidArgument",
                    message: "missing eventAcknowledgement payload",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            guard !acknowledgement.subscriptionID.isEmpty, !acknowledgement.processID.isEmpty,
                acknowledgement.sequence > 0
            else {
                return .failure(
                    requestID: requestID,
                    code: "invalidArgument",
                    message: "event acknowledgement requires non-empty identities and a positive sequence",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            do {
                try eventDelivery.acknowledge(acknowledgement, from: clientFD)
                return .success(
                    requestID: requestID,
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processStart:
            guard let exec = request.exec else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing exec payload")
            }
            guard let processID = request.processID, !processID.isEmpty else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            let port = request.port ?? 27000
            do {
                let admission = try syncValue {
                    try await self.service.acquireProcessStartAdmission()
                }
                defer {
                    _ = try? syncValue {
                        await self.service.releaseProcessStartAdmission(admission)
                    }
                }
                try startProcessStream(port: port, processID: processID, exec: exec)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processInspect:
            guard let exec = request.exec else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing exec payload")
            }
            guard let processID = request.processID, !processID.isEmpty else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            do {
                let status = try inspectDurableProcess(
                    port: request.port ?? 27_000,
                    processID: processID,
                    exec: exec
                )
                return .success(requestID: requestID, data: try JSONEncoder().encode(status))
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processStdin:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            guard let data = request.data else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing data")
            }
            do {
                try sendProcessControlFrame(processID: processID) { session in
                    SidecarGuestAgentFrame.stdin(id: session.guestProcessID, data: data)
                }
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processClose:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            do {
                try sendProcessControlFrame(processID: processID) { session in
                    SidecarGuestAgentFrame.close(id: session.guestProcessID)
                }
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processDelete:
            guard let identity = request.durableProcessDeleteIdentity else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing durable process delete identity")
            }
            if let processID = request.processID, processID != identity.executionID {
                return .failure(requestID: requestID, code: "invalidArgument", message: "durable process delete identities disagree")
            }
            do {
                try deleteDurableProcess(port: request.port ?? 27000, identity: identity)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processSignal:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            guard let signal = request.signal else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing signal")
            }
            do {
                try sendProcessControlFrame(processID: processID) { session in
                    .init(
                        type: .signal,
                        id: session.guestProcessID,
                        executable: nil,
                        arguments: nil,
                        environment: nil,
                        workingDirectory: nil,
                        terminal: nil,
                        signal: signal,
                        width: nil,
                        height: nil,
                        data: nil,
                        exitCode: nil,
                        message: nil
                    )
                }
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .processResize:
            guard let processID = request.processID else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            guard let width = request.width, let height = request.height else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing width/height")
            }
            do {
                try sendProcessControlFrame(processID: processID) { session in
                    .init(
                        type: .resize,
                        id: session.guestProcessID,
                        executable: nil,
                        arguments: nil,
                        environment: nil,
                        workingDirectory: nil,
                        terminal: nil,
                        signal: nil,
                        width: width,
                        height: height,
                        data: nil,
                        exitCode: nil,
                        message: nil
                    )
                }
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsBegin:
            guard let payload = request.fsBegin else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing filesystem begin payload")
            }
            let port = request.port ?? 27000
            do {
                try startFSTransfer(port: port, clientFD: clientFD, payload: payload)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsChunk:
            guard let payload = request.fsChunk else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing filesystem chunk payload")
            }
            do {
                try sendFSChunk(payload)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsEnd:
            guard let payload = request.fsEnd else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing filesystem end payload")
            }
            do {
                try finishFSTransfer(payload)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsReadBegin:
            guard let payload = request.fsReadBegin else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing filesystem read begin payload")
            }
            let port = request.port ?? 27000
            do {
                let meta = try startFSRead(port: port, clientFD: clientFD, payload: payload)
                let data = try JSONEncoder().encode(meta)
                return .success(requestID: requestID, data: data)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsReadChunk:
            guard let payload = request.fsReadChunk else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing filesystem read chunk payload")
            }
            do {
                let chunkData = try sendFSReadChunk(payload)
                return .success(requestID: requestID, data: chunkData)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsReadEnd:
            guard let txID = request.processID, !txID.isEmpty else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing txID for filesystem read end")
            }
            do {
                try finishFSRead(txID: txID)
                return .success(requestID: requestID)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .fsListDir:
            guard let payload = request.fsListDir else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing filesystem listdir payload")
            }
            let port = request.port ?? 27000
            do {
                let entries = try listDir(port: port, path: payload.path, txID: payload.txID)
                let data = try JSONEncoder().encode(entries)
                return .success(requestID: requestID, data: data)
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .vmCapabilities:
            return try sync(requestID: requestID) {
                let capabilities = await service.capabilities()
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(capabilities),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
        case .vmPause:
            return try sync(requestID: requestID) {
                let result = try await service.pauseVM(timeoutSeconds: request.machineState?.timeoutSeconds)
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(result),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
        case .vmResume:
            return try sync(requestID: requestID) {
                let result = try await service.resumeVM(timeoutSeconds: request.machineState?.timeoutSeconds)
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(result),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
        case .vmPrepareCheckpoint:
            guard let payload = request.machineState else {
                return .failure(
                    requestID: requestID,
                    code: "invalidArgument",
                    message: "missing machineState checkpoint payload",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            do {
                let result = try prepareCheckpoint(payload)
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(result),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .vmSaveMachineState:
            guard let payload = request.machineState, let stateID = payload.stateID else {
                return .failure(
                    requestID: requestID,
                    code: "invalidArgument",
                    message: "missing machineState.stateID",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            return try sync(requestID: requestID) {
                let durableInputs =
                    request.protocolVersion == MacOSSidecarProtocolVersion.durableCheckpointAdoption
                    ? try self.durablePairSaveInputs(stateID: stateID, payload: payload)
                    : nil
                let result = try await service.saveMachineState(
                    stateID: stateID,
                    timeoutSeconds: payload.timeoutSeconds,
                    adoption: durableInputs?.adoption,
                    pair: durableInputs?.pair
                )
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(result),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
        case .vmMachineStateReceipt:
            guard let stateID = request.machineState?.stateID else {
                return .failure(
                    requestID: requestID,
                    code: "invalidArgument",
                    message: "missing machineState.stateID",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            return try sync(requestID: requestID) {
                let receipt = try await service.machineStateReceipt(stateID: stateID)
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(receipt),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
        case .vmAbortCheckpoint:
            guard let payload = request.machineState else {
                return .failure(
                    requestID: requestID,
                    code: "invalidArgument",
                    message: "missing machineState checkpoint payload",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            do {
                try abortCheckpoint(payload)
                return .success(
                    requestID: requestID,
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            } catch {
                return failureResponse(requestID: requestID, error: error)
            }
        case .vmStorageAttachments:
            return try sync(requestID: requestID) {
                let attachments = await service.storageAttachments()
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(attachments),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
        case .vmRestoreMachineState:
            guard let stateID = request.machineState?.stateID else {
                return .failure(
                    requestID: requestID,
                    code: "invalidArgument",
                    message: "missing machineState.stateID",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            return try sync(requestID: requestID) {
                let result = try await service.restoreMachineState(
                    stateID: stateID,
                    timeoutSeconds: request.machineState?.timeoutSeconds
                )
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(result),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
        case .vmDeleteMachineState:
            guard let stateID = request.machineState?.stateID else {
                return .failure(
                    requestID: requestID,
                    code: "invalidArgument",
                    message: "missing machineState.stateID",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            return try sync(requestID: requestID) {
                let result = try await service.deleteMachineState(stateID: stateID)
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(result),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
        case .vmCompatibilityDescription:
            return try sync(requestID: requestID) {
                let result = try await service.compatibilityDescription(stateID: request.machineState?.stateID)
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(result),
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
        case .vmStop:
            log.info("sidecar control vmStop request", metadata: ["request_id": "\(requestID)"])
            return try sync(requestID: requestID) {
                self.closeAllProcessSessions()
                self.closeAllFSSessions()
                self.closeAllFSReadSessions()
                try await service.stopVM()
                return .success(requestID: requestID)
            }
        case .sidecarQuit:
            log.info("sidecar control sidecarQuit request", metadata: ["request_id": "\(requestID)"])
            let response: MacOSSidecarResponse = try sync(requestID: requestID) {
                self.closeAllProcessSessions()
                self.closeAllFSSessions()
                self.closeAllFSReadSessions()
                try await service.prepareForQuit()
                return .success(requestID: requestID)
            }
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            return response
        case .unknown(let method):
            return .failure(
                requestID: requestID,
                code: "unknownMethod",
                message: "unknown sidecar control method \(method)",
                metadata: ["method": method],
                protocolVersion: MacOSSidecarProtocolVersion.current
            )
        }
    }

    private func protocolVersionError(for request: MacOSSidecarRequest) -> SidecarRPCError? {
        if let version = request.protocolVersion, !MacOSSidecarProtocolVersion.supported.contains(version) {
            return SidecarRPCError(
                code: "protocolVersionMismatch",
                message: "unsupported sidecar protocol version \(version)",
                metadata: [
                    "requestedVersion": "\(version)",
                    "currentVersion": "\(MacOSSidecarProtocolVersion.current)",
                    "supportedVersions": MacOSSidecarProtocolVersion.supported.map(String.init).joined(separator: ","),
                ]
            )
        }

        switch request.method {
        case .processDelete:
            guard request.protocolVersion == MacOSSidecarProtocolVersion.durableProcessIdentity else {
                return SidecarRPCError(
                    code: "protocolVersionMismatch",
                    message:
                        "method \(request.method.rawValue) requires sidecar protocol version \(MacOSSidecarProtocolVersion.durableProcessIdentity)",
                    metadata: [
                        "requestedVersion": request.protocolVersion.map(String.init) ?? "legacy-unversioned",
                        "requiredVersion": "\(MacOSSidecarProtocolVersion.durableProcessIdentity)",
                    ]
                )
            }
        case .eventsAcknowledge:
            guard request.protocolVersion == MacOSSidecarProtocolVersion.durableEventAcknowledgement else {
                return SidecarRPCError(
                    code: "protocolVersionMismatch",
                    message:
                        "method \(request.method.rawValue) requires sidecar protocol version \(MacOSSidecarProtocolVersion.durableEventAcknowledgement)",
                    metadata: [
                        "requestedVersion": request.protocolVersion.map(String.init) ?? "legacy-unversioned",
                        "requiredVersion": "\(MacOSSidecarProtocolVersion.durableEventAcknowledgement)",
                    ]
                )
            }
        case .eventsSubscribe:
            guard
                request.protocolVersion == MacOSSidecarProtocolVersion.machineState
                    || request.protocolVersion == MacOSSidecarProtocolVersion.durableEventAcknowledgement
            else {
                return SidecarRPCError(
                    code: "protocolVersionMismatch",
                    message: "method \(request.method.rawValue) requires sidecar protocol version 2 or 3",
                    metadata: [
                        "requestedVersion": request.protocolVersion.map(String.init) ?? "legacy-unversioned",
                        "requiredVersion":
                            "\(MacOSSidecarProtocolVersion.machineState),\(MacOSSidecarProtocolVersion.durableEventAcknowledgement)",
                    ]
                )
            }
        case .vmPrepareCheckpoint, .vmMachineStateReceipt, .vmAbortCheckpoint, .vmStorageAttachments:
            guard request.protocolVersion == MacOSSidecarProtocolVersion.durableCheckpointAdoption else {
                return SidecarRPCError(
                    code: "protocolVersionMismatch",
                    message:
                        "method \(request.method.rawValue) requires sidecar protocol version \(MacOSSidecarProtocolVersion.durableCheckpointAdoption)",
                    metadata: [
                        "requestedVersion": request.protocolVersion.map(String.init) ?? "legacy-unversioned",
                        "requiredVersion": "\(MacOSSidecarProtocolVersion.durableCheckpointAdoption)",
                    ]
                )
            }
        case .vmPause, .vmResume, .vmSaveMachineState, .vmRestoreMachineState, .vmDeleteMachineState,
            .vmCompatibilityDescription:
            guard
                request.protocolVersion == MacOSSidecarProtocolVersion.machineState
                    || request.protocolVersion == MacOSSidecarProtocolVersion.durableCheckpointAdoption
            else {
                return SidecarRPCError(
                    code: "protocolVersionMismatch",
                    message: "method \(request.method.rawValue) requires sidecar protocol version 2 or 6",
                    metadata: [
                        "requestedVersion": request.protocolVersion.map(String.init) ?? "legacy-unversioned",
                        "requiredVersion":
                            "\(MacOSSidecarProtocolVersion.machineState),\(MacOSSidecarProtocolVersion.durableCheckpointAdoption)",
                    ]
                )
            }
        case .vmBootstrapStart, .vmShowGUI, .vmConnectVsock, .processStart, .processInspect, .processStdin, .processSignal,
            .processResize, .processClose, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd,
            .fsListDir, .vmCapabilities, .vmStop, .sidecarQuit, .unknown:
            break
        }
        return nil
    }

    private func sync(requestID: String, _ body: @Sendable @escaping () async throws -> MacOSSidecarResponse) throws -> MacOSSidecarResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<MacOSSidecarResponse>()
        Task { @Sendable in
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result! {
        case .success(let response):
            return response
        case .failure(let error):
            return failureResponse(requestID: requestID, error: error)
        }
    }

    private func syncValue<T>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task { @Sendable in
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result {
        case .success(let value)?:
            return value
        case .failure(let error)?:
            throw error
        case nil:
            throw ContainerizationError(.internalError, message: "sidecar syncValue finished without result")
        }
    }
}

extension MacOSSidecarMethod {
    fileprivate var claimsLegacyEventSubscription: Bool {
        switch self {
        case .vmBootstrapStart, .vmShowGUI, .processStart, .processStdin, .processSignal, .processResize,
            .processClose, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd, .fsListDir:
            true
        case .eventsSubscribe, .eventsAcknowledge, .vmConnectVsock, .processInspect, .processDelete, .vmCapabilities, .vmPause, .vmResume, .vmSaveMachineState,
            .vmRestoreMachineState, .vmDeleteMachineState, .vmCompatibilityDescription, .vmPrepareCheckpoint,
            .vmMachineStateReceipt, .vmAbortCheckpoint, .vmStorageAttachments, .vmStop, .sidecarQuit, .unknown:
            false
        }
    }
}

package enum GuestAgentBootstrapRetrier {
    package static func run(
        maxAttempts: Int,
        retryDelayNanoseconds: UInt64,
        operation: @escaping @Sendable (_ attempt: Int, _ maxAttempts: Int) async throws -> Void
    ) async throws {
        let attempts = max(1, maxAttempts)
        var lastError: Error?

        for attempt in 1...attempts {
            do {
                try await operation(attempt, attempts)
                return
            } catch {
                lastError = error
                if attempt < attempts, retryDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                }
            }
        }

        throw lastError
            ?? ContainerizationError(
                .timeout,
                message: "guest-agent bootstrap probe finished without result"
            )
    }
}

private func shouldLogBootstrapGuestAgentAttempt(_ attempt: Int, maxAttempts: Int) -> Bool {
    if attempt <= 5 {
        return true
    }
    if attempt == maxAttempts {
        return true
    }
    return attempt % 10 == 0
}
