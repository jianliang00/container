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

    @MainActor
    mutating func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let log = Self.setupLogger(debug: debug, metadata: ["uuid": "\(uuid)"])

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

struct SidecarGuestAgentFrame: Codable {
    enum FrameType: String, Codable {
        case exec
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
    let executable: String?
    let arguments: [String]?
    let environment: [String]?
    let rootDirectory: String?
    let workingDirectory: String?
    let terminal: Bool?
    let user: String?
    let signal: Int32?
    let width: UInt16?
    let height: UInt16?
    let data: Data?
    let exitCode: Int32?
    let message: String?
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
        executable: String? = nil,
        arguments: [String]? = nil,
        environment: [String]? = nil,
        rootDirectory: String? = nil,
        workingDirectory: String? = nil,
        terminal: Bool? = nil,
        user: String? = nil,
        signal: Int32? = nil,
        width: UInt16? = nil,
        height: UInt16? = nil,
        data: Data? = nil,
        exitCode: Int32? = nil,
        message: String? = nil,
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
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.rootDirectory = rootDirectory
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.user = user
        self.signal = signal
        self.width = width
        self.height = height
        self.data = data
        self.exitCode = exitCode
        self.message = message
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
        supplementalGroups: [UInt32]?
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
                MacOSSidecarMethod.vmSaveMachineState.rawValue,
                MacOSSidecarMethod.vmRestoreMachineState.rawValue,
                MacOSSidecarMethod.vmCompatibilityDescription.rawValue,
                MacOSSidecarMethod.vmStop.rawValue,
                MacOSSidecarMethod.eventsSubscribe.rawValue,
            ]
        )
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

    func saveMachineState(stateID: String, timeoutSeconds: Double?) async throws -> MacOSMachineStateOperationResult {
        try validateOperationTimeout(timeoutSeconds)
        let store = try machineStateStore()
        try MacOSMachineStateStore.validateStateID(stateID)
        try lifecycle.ensureNoOperationInProgress()
        do {
            let stored = try store.load(stateID: stateID)
            let current = try await currentCompatibilityDescription()
            let reasons = MacOSMachineStateCompatibility.compare(saved: stored.compatibility, current: current)
            guard reasons.isEmpty else {
                throw compatibilityMismatchError(reasons)
            }
            return .init(lifecycleState: state, stateID: stateID, compatibility: stored.compatibility)
        } catch let error as SidecarRPCError where error.code == "machineStateNotFound" {
            // A missing state is the expected first-save path.
        }

        #if arch(arm64)
        let configuration = try await ensurePreparedConfiguration()
        try configuration.validateSaveRestoreSupport()
        let compatibility = try await currentCompatibilityDescription()
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
            try await saveVirtualMachine(vm, to: reservation.stateURL)
            try store.commit(reservation, compatibility: compatibility)
            lifecycle.complete(.save, succeeded: true)
            return .init(lifecycleState: state, stateID: stateID, compatibility: compatibility)
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
        let store = try machineStateStore()
        let stored = try store.load(stateID: stateID)
        let configuration = try await ensurePreparedConfiguration()
        try configuration.validateSaveRestoreSupport()
        let current = try await currentCompatibilityDescription()
        let reasons = MacOSMachineStateCompatibility.compare(saved: stored.compatibility, current: current)
        guard reasons.isEmpty else {
            throw compatibilityMismatchError(reasons)
        }

        let shouldRestore = try lifecycle.begin(.restore, stateID: stateID)
        guard shouldRestore else {
            return .init(lifecycleState: state, stateID: stateID, compatibility: stored.compatibility)
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
            return .init(lifecycleState: state, stateID: stateID, compatibility: stored.compatibility)
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
        let configuration = try await makeVirtualMachineConfiguration(containerConfig: loadContainerConfiguration())
        vmConfiguration = configuration
        return configuration
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

    private func machineStateStore() throws -> MacOSMachineStateStore {
        let config = try loadContainerConfiguration()
        guard let machineState = config.macosGuest?.machineState else {
            return MacOSMachineStateStore(runtimeRootURL: rootURL)
        }
        guard machineState.protocolVersion == MacOSSidecarProtocolVersion.machineState else {
            throw SidecarRPCError(
                code: "protocolVersionMismatch",
                message: "configured machine-state protocol version is unsupported"
            )
        }
        let storageURL = URL(fileURLWithPath: machineState.storageDirectory).standardizedFileURL
        guard storageURL.path == machineState.storageDirectory, storageURL.path.hasPrefix("/") else {
            throw SidecarRPCError(
                code: "unsafeMachineStatePath",
                message: "configured machine-state storage directory is not an absolute canonical path"
            )
        }
        try MacOSMachineStateStore.rejectSymbolicLinks(below: storageURL, through: storageURL)
        return MacOSMachineStateStore(runtimeRootURL: storageURL)
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
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingResultBox<Void>()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.waitForGuestAgentReady(fd: fd)
                box.result = .success(())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        let deadline = DispatchTime.now() + timeoutSeconds
        if semaphore.wait(timeout: deadline) == .timedOut {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            throw ContainerizationError(.timeout, message: "timed out waiting for guest-agent ready frame")
        }
        switch box.result {
        case .success?:
            return
        case .failure(let error)?:
            throw error
        case nil:
            throw ContainerizationError(.internalError, message: "ready wait finished without result")
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
            case .ready, .ack, .stdout, .stderr, .exec, .stdin, .signal, .resize, .close, .networkConfigure, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd,
                .fsListDir:
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

    private func persistentIdentityDirectory(containerConfig: ContainerConfiguration) throws -> URL? {
        guard let machineState = containerConfig.macosGuest?.machineState else { return nil }
        let storage = URL(fileURLWithPath: machineState.storageDirectory).standardizedFileURL
        guard storage.path == machineState.storageDirectory, storage.path.hasPrefix("/") else {
            throw SidecarRPCError(code: "unsafeMachineStatePath", message: "invalid persistent identity root")
        }
        try MacOSMachineStateStore.rejectSymbolicLinks(below: storage, through: storage)
        let identity = storage.appendingPathComponent("Identity", isDirectory: true)
        if FileManager.default.fileExists(atPath: identity.path) {
            try MacOSMachineStateStore.rejectSymbolicLinks(below: storage, through: identity)
            var value = stat()
            guard lstat(identity.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
                throw SidecarRPCError(code: "unsafeMachineStatePath", message: "persistent identity path is not a directory")
            }
        } else {
            try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: false)
        }
        guard chmod(identity.path, mode_t(S_IRWXU)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
            case .stdout, .stderr, .ack, .exec, .stdin, .signal, .resize, .close, .networkConfigure, .networkResult, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk,
                .fsReadEnd, .fsListDir:
                continue
            }
        }
    }
}

final class SidecarControlServer: @unchecked Sendable {
    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private final class ProcessStreamSession: @unchecked Sendable {
        let processID: String
        let fd: Int32
        let writeLock = NSLock()
        let stateLock = NSLock()
        var closed = false

        init(processID: String, fd: Int32) {
            self.processID = processID
            self.fd = fd
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
    private let eventClientLock = NSLock()
    private let eventWriteLock = NSLock()
    private let processLock = NSLock()
    private let fsLock = NSLock()
    private let fsReadLock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = false
    private var eventClientFD: Int32 = -1
    private var processSessions: [String: ProcessStreamSession] = [:]
    private var fsSessions: [String: FSTransferSession] = [:]
    private var fsReadSessions: [String: FSReadSession] = [:]

    init(socketPath: String, service: MacOSSidecarService, log: Logging.Logger) {
        self.socketPath = socketPath
        self.service = service
        self.log = log
    }

    func start() throws {
        try cleanupStaleSocket()
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
        guard Darwin.listen(fd, 16) == 0 else {
            let error = makePOSIXError(errno)
            Darwin.close(fd)
            throw error
        }
        _ = chmod(socketPath, mode_t(S_IRUSR | S_IWUSR))

        lock.lock()
        listenFD = fd
        stopping = false
        lock.unlock()

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
        lock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        clearEventClient()
        closeAllProcessSessions()
        closeAllFSSessions()
        closeAllFSReadSessions()
        _ = unlink(socketPath)
    }

    private func cleanupStaleSocket() throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try MacOSMachineStateStore.rejectSymbolicLinks(below: parent, through: parent)
        var parentValue = stat()
        guard stat(parent.path, &parentValue) == 0, (parentValue.st_mode & S_IFMT) == S_IFDIR else {
            throw SidecarRPCError(
                code: "unsafeControlSocketPath",
                message: "control socket parent must be a directory and cannot be a symbolic link"
            )
        }
        var value = stat()
        if lstat(socketPath, &value) == 0 {
            guard (value.st_mode & S_IFMT) == S_IFSOCK else {
                throw SidecarRPCError(
                    code: "unsafeControlSocketPath",
                    message: "refusing to replace a non-socket control path"
                )
            }
            guard unlink(socketPath) == 0 else {
                throw makePOSIXError(errno)
            }
        } else if errno != ENOENT {
            throw makePOSIXError(errno)
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
            clearEventClientIfMatches(clientFD)
            closeOwnedFSSessions(clientFD: clientFD)
            closeOwnedFSReadSessions(clientFD: clientFD)
            Darwin.close(clientFD)
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
                try writeEnvelope(.response(response), to: clientFD)
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
        eventWriteLock.lock()
        defer { eventWriteLock.unlock() }
        try MacOSSidecarSocketIO.writeJSONFrame(envelope, fd: fd)
    }

    private func emitEvent(_ event: MacOSSidecarEvent) {
        let clientFD: Int32
        eventClientLock.lock()
        clientFD = eventClientFD
        eventClientLock.unlock()

        guard clientFD >= 0 else {
            log.warning("dropping sidecar event without control client", metadata: ["event": "\(event.event.rawValue)", "process_id": "\(event.processID)"])
            return
        }

        do {
            try writeEnvelope(.event(event), to: clientFD)
        } catch {
            log.error(
                "failed to send sidecar event",
                metadata: [
                    "event": "\(event.event.rawValue)",
                    "process_id": "\(event.processID)",
                    "error": "\(error)",
                ])
        }
    }

    private func subscribeEventClient(fd: Int32) -> Bool {
        eventClientLock.lock()
        defer { eventClientLock.unlock() }
        guard eventClientFD < 0 || eventClientFD == fd else { return false }
        eventClientFD = fd
        return true
    }

    private func setEventClientIfAbsent(fd: Int32) {
        eventClientLock.lock()
        if eventClientFD < 0 {
            eventClientFD = fd
        }
        eventClientLock.unlock()
    }

    private func clearEventClient() {
        eventClientLock.lock()
        eventClientFD = -1
        eventClientLock.unlock()
    }

    private func clearEventClientIfMatches(_ fd: Int32) {
        eventClientLock.lock()
        if eventClientFD == fd {
            eventClientFD = -1
        }
        eventClientLock.unlock()
    }

    private func isExpectedEOF(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "RuntimeMacOSSidecarShared" && nsError.localizedDescription.contains("unexpected EOF")
    }

    private func registerProcessSession(_ session: ProcessStreamSession) throws {
        processLock.lock()
        defer { processLock.unlock() }
        guard processSessions[session.processID] == nil else {
            throw ContainerizationError(.exists, message: "process \(session.processID) already exists in sidecar")
        }
        processSessions[session.processID] = session
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

    private func removeProcessSession(_ processID: String) -> ProcessStreamSession? {
        processLock.lock()
        let removed = processSessions.removeValue(forKey: processID)
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
            closeProcessStreamSession(session)
        }
    }

    private func closeProcessStreamSession(_ session: ProcessStreamSession) {
        session.stateLock.lock()
        let shouldClose = !session.closed
        session.closed = true
        session.stateLock.unlock()
        guard shouldClose else { return }
        _ = Darwin.shutdown(session.fd, SHUT_RDWR)
        Darwin.close(session.fd)
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
        try waitForProcessStartAck(fd: fd, expectedProcessID: expectedProcessID, timeoutSeconds: timeoutSeconds)
    }

    func _testGuestExecutableLaunch(executable: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        guestExecutableLaunch(executable: executable, arguments: arguments)
    }

    func _testEmitEvent(_ event: MacOSSidecarEvent) {
        emitEvent(event)
    }

    private func sendFrame(_ frame: SidecarGuestAgentFrame, to session: ProcessStreamSession) throws {
        session.writeLock.lock()
        defer { session.writeLock.unlock() }
        try MacOSSidecarSocketIO.writeJSONFrame(frame, fd: session.fd)
    }

    private func sendFrame(_ frame: SidecarGuestAgentFrame, to session: FSTransferSession) throws {
        session.writeLock.lock()
        defer { session.writeLock.unlock() }
        try MacOSSidecarSocketIO.writeJSONFrame(frame, fd: session.fd)
    }

    private func sendProcessControlFrame(processID: String, build: (ProcessStreamSession) -> SidecarGuestAgentFrame) throws {
        let session = try processSession(for: processID)
        try sendFrame(build(session), to: session)
    }

    private func startFSTransfer(port: UInt32, clientFD: Int32, payload: MacOSSidecarFSBeginRequestPayload) throws {
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
            try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
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
            try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
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
            try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
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

    private func startProcessStream(port: UInt32, processID: String, exec: MacOSSidecarExecRequestPayload) throws {
        let fd = try syncValue {
            try await self.service.connectVsock(port: port)
        }

        do {
            try waitForGuestAgentReadyWithTimeout(fd: fd, timeoutSeconds: 3)
            let env = exec.environment ?? ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
            let cwd = exec.workingDirectory ?? "/"
            let launch = guestExecutableLaunch(executable: exec.executable, arguments: exec.arguments)
            try MacOSSidecarSocketIO.writeJSONFrame(
                SidecarGuestAgentFrame.exec(
                    id: processID,
                    executable: launch.executable,
                    arguments: launch.arguments,
                    environment: env,
                    rootDirectory: exec.rootDirectory,
                    workingDirectory: cwd,
                    terminal: exec.terminal,
                    user: exec.user,
                    uid: exec.uid,
                    gid: exec.gid,
                    supplementalGroups: exec.supplementalGroups
                ),
                fd: fd
            )
            let initialFrames = try waitForProcessStartAck(fd: fd, expectedProcessID: processID, timeoutSeconds: 3)
            let session = ProcessStreamSession(processID: processID, fd: fd)
            try registerProcessSession(session)
            startProcessReadLoop(session, initialFrames: initialFrames)
        } catch {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            throw error
        }
    }

    private func guestExecutableLaunch(executable: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        guard !executable.isEmpty, !executable.contains("/") else {
            return (executable, arguments)
        }
        return ("/usr/bin/env", [executable] + arguments)
    }

    private func startProcessReadLoop(_ session: ProcessStreamSession, initialFrames: [SidecarGuestAgentFrame] = []) {
        Thread.detachNewThread { [weak self] in
            self?.processReadLoop(session, initialFrames: initialFrames)
        }
    }

    private func processReadLoop(_ session: ProcessStreamSession, initialFrames: [SidecarGuestAgentFrame] = []) {
        let processID = session.processID
        var exitEmitted = false
        var pendingExitCode: Int32?
        var bufferedFrames = ArraySlice(initialFrames)
        defer {
            closeProcessStreamSession(session)
            _ = removeProcessSession(processID)
            if !exitEmitted {
                emitEvent(.init(event: .processExit, processID: processID, exitCode: pendingExitCode ?? 1))
            }
        }

        do {
            while true {
                let frame: SidecarGuestAgentFrame
                if let bufferedFrame = bufferedFrames.first {
                    frame = bufferedFrame
                    bufferedFrames.removeFirst()
                } else if pendingExitCode == nil {
                    frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: session.fd)
                } else {
                    guard let drained = try readProcessFrameIfAvailable(fd: session.fd, timeoutMilliseconds: 100) else {
                        emitEvent(.init(event: .processExit, processID: processID, exitCode: pendingExitCode))
                        exitEmitted = true
                        return
                    }
                    frame = drained
                }
                switch frame.type {
                case .stdout:
                    if let data = frame.data, !data.isEmpty {
                        emitEvent(.init(event: .processStdout, processID: processID, data: data))
                    }
                case .stderr:
                    if let data = frame.data, !data.isEmpty {
                        emitEvent(.init(event: .processStderr, processID: processID, data: data))
                    }
                case .error:
                    emitEvent(.init(event: .processError, processID: processID, message: frame.message ?? "unknown guest-agent error"))
                case .exit:
                    pendingExitCode = frame.exitCode ?? 1
                case .ready:
                    continue
                case .ack, .exec, .stdin, .signal, .resize, .close, .networkConfigure, .networkResult, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd,
                    .fsListDir:
                    continue
                }
            }
        } catch {
            if let pendingExitCode, isExpectedEOF(error) {
                emitEvent(.init(event: .processExit, processID: processID, exitCode: pendingExitCode))
                exitEmitted = true
                return
            }
            if !isExpectedEOF(error) {
                emitEvent(.init(event: .processError, processID: processID, message: "sidecar process stream read failed: \(error.localizedDescription)"))
            }
        }
    }

    private func waitForProcessStartAck(
        fd: Int32,
        expectedProcessID: String,
        timeoutSeconds: TimeInterval
    ) throws -> [SidecarGuestAgentFrame] {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<[SidecarGuestAgentFrame]>()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                box.result = .success(try self.readProcessStartAck(fd: fd, expectedProcessID: expectedProcessID))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            throw ContainerizationError(
                .timeout,
                message: "timed out waiting for guest-agent process start ack for \(expectedProcessID)"
            )
        }
        switch box.result {
        case .success(let frames)?:
            return frames
        case .failure(let error)?:
            throw error
        case nil:
            throw ContainerizationError(
                .internalError,
                message: "guest-agent process start ack wait finished without result for \(expectedProcessID)"
            )
        }
    }

    private func readProcessStartAck(fd: Int32, expectedProcessID: String) throws -> [SidecarGuestAgentFrame] {
        var bufferedFrames: [SidecarGuestAgentFrame] = []
        while true {
            let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
            switch frame.type {
            case .ack:
                guard frame.id == expectedProcessID else {
                    throw ContainerizationError(
                        .internalError,
                        message: "guest-agent process start ack ID mismatch (expected=\(expectedProcessID) actual=\(frame.id ?? "nil"))"
                    )
                }
                return bufferedFrames
            case .error:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "guest-agent failed to start process \(expectedProcessID): \(frame.message ?? "unknown error")"
                )
            case .exit:
                throw ContainerizationError(
                    .internalError,
                    message: "guest-agent process stream exited before start ack for \(expectedProcessID) (code=\(frame.exitCode ?? 1))"
                )
            case .stdout, .stderr:
                bufferedFrames.append(frame)
            case .ready:
                continue
            case .exec, .stdin, .signal, .resize, .close, .networkConfigure, .networkResult, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd, .fsListDir:
                continue
            }
        }
    }

    private func readProcessFrameIfAvailable(fd: Int32, timeoutMilliseconds: Int32) throws -> SidecarGuestAgentFrame? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let result = withUnsafeMutablePointer(to: &descriptor) { pointer in
                Darwin.poll(pointer, 1, timeoutMilliseconds)
            }

            if result == 0 {
                return nil
            }
            if result > 0 {
                if descriptor.revents & Int16(POLLIN) != 0 {
                    return try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
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
            case .exec, .stdin, .signal, .resize, .close, .networkConfigure, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd, .fsListDir:
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
            case .exec, .stdin, .signal, .resize, .close, .networkConfigure, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk, .fsReadEnd, .fsListDir:
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

    private func waitForGuestAgentReadyWithTimeout(fd: Int32, timeoutSeconds: TimeInterval) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Void>()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                while true {
                    let frame = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: fd)
                    switch frame.type {
                    case .ready:
                        box.result = .success(())
                        semaphore.signal()
                        return
                    case .error:
                        throw ContainerizationError(.internalError, message: "guest-agent error before ready: \(frame.message ?? "unknown error")")
                    case .exit:
                        throw ContainerizationError(.internalError, message: "guest-agent exited before ready (code=\(frame.exitCode ?? 1))")
                    case .stdout, .stderr, .ack, .exec, .stdin, .signal, .resize, .close, .networkConfigure, .networkResult, .fsBegin, .fsChunk, .fsEnd, .fsReadBegin, .fsReadChunk,
                        .fsReadEnd, .fsListDir:
                        continue
                    }
                }
            } catch {
                box.result = .failure(error)
                semaphore.signal()
            }
        }

        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            throw ContainerizationError(.timeout, message: "timed out waiting for guest-agent ready frame")
        }
        switch box.result {
        case .success?:
            return
        case .failure(let error)?:
            throw error
        case nil:
            throw ContainerizationError(.internalError, message: "guest-agent ready wait finished without result")
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
            guard subscribeEventClient(fd: clientFD) else {
                return .failure(
                    requestID: requestID,
                    code: "eventClientAlreadySubscribed",
                    message: "another client already owns the sidecar event subscription",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            return .success(
                requestID: requestID,
                protocolVersion: MacOSSidecarProtocolVersion.current
            )
        case .processStart:
            guard let exec = request.exec else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing exec payload")
            }
            guard let processID = request.processID, !processID.isEmpty else {
                return .failure(requestID: requestID, code: "invalidArgument", message: "missing processID")
            }
            let port = request.port ?? 27000
            do {
                try startProcessStream(port: port, processID: processID, exec: exec)
                return .success(requestID: requestID)
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
                try sendProcessControlFrame(processID: processID) { _ in
                    SidecarGuestAgentFrame.stdin(id: processID, data: data)
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
                try sendProcessControlFrame(processID: processID) { _ in SidecarGuestAgentFrame.close(id: processID) }
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
                try sendProcessControlFrame(processID: processID) { _ in
                    .init(
                        type: .signal,
                        id: processID,
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
                try sendProcessControlFrame(processID: processID) { _ in
                    .init(
                        type: .resize,
                        id: processID,
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
        case .vmSaveMachineState:
            guard let stateID = request.machineState?.stateID else {
                return .failure(
                    requestID: requestID,
                    code: "invalidArgument",
                    message: "missing machineState.stateID",
                    protocolVersion: MacOSSidecarProtocolVersion.current
                )
            }
            return try sync(requestID: requestID) {
                let result = try await service.saveMachineState(
                    stateID: stateID,
                    timeoutSeconds: request.machineState?.timeoutSeconds
                )
                return .success(
                    requestID: requestID,
                    data: try JSONEncoder().encode(result),
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
        case .eventsSubscribe, .vmPause, .vmResume, .vmSaveMachineState, .vmRestoreMachineState,
            .vmCompatibilityDescription:
            guard request.protocolVersion == MacOSSidecarProtocolVersion.machineState else {
                return SidecarRPCError(
                    code: "protocolVersionMismatch",
                    message: "method \(request.method.rawValue) requires sidecar protocol version \(MacOSSidecarProtocolVersion.machineState)",
                    metadata: [
                        "requestedVersion": request.protocolVersion.map(String.init) ?? "legacy-unversioned",
                        "requiredVersion": "\(MacOSSidecarProtocolVersion.machineState)",
                    ]
                )
            }
        case .vmBootstrapStart, .vmShowGUI, .vmConnectVsock, .processStart, .processStdin, .processSignal,
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
        case .eventsSubscribe, .vmConnectVsock, .vmCapabilities, .vmPause, .vmResume, .vmSaveMachineState,
            .vmRestoreMachineState, .vmCompatibilityDescription, .vmStop, .sidecarQuit, .unknown:
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
