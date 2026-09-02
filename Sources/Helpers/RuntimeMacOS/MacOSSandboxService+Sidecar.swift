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

import ContainerPlugin
import ContainerResource
import ContainerizationError
import Darwin
import Foundation
import RuntimeMacOSSidecarShared

struct MacOSMachineStateOutcomeIndeterminate: Error, Sendable {
    let operation: String
    let stateID: String
    let lifecycleState: MacOSVMRuntimeState?

    var containerizationError: ContainerizationError {
        let lifecycle = lifecycleState?.rawValue ?? "unavailable"
        return ContainerizationError(
            .timeout,
            message:
                "machine-state \(operation) outcome remains unknown for state \(stateID); sidecar and persistence lease were retained for reconciliation (lifecycle=\(lifecycle))"
        )
    }
}

extension MacOSSandboxService {
    private static let sidecarBootstrapStartTimeoutSeconds: TimeInterval = 120.0
    private static let sidecarRestoreTimeoutSeconds: TimeInterval = 600.0
    private static let sidecarExitEventDrainTimeoutSeconds: TimeInterval = 5.0
    private static let sidecarReconciliationPollMicroseconds: useconds_t = 100_000

    func sidecarSocketPath(config: ContainerConfiguration) -> URL {
        if let path = config.macosGuest?.machineState?.controlSocketPath {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/tmp/ctrm-sidecar-\(config.id).sock")
    }

    func sidecarPlistPath() -> URL {
        root.appendingPathComponent("runtime-macos-sidecar.plist")
    }

    func sidecarStdoutLogPath() -> URL {
        root.appendingPathComponent("sidecar.stdout.log")
    }

    func sidecarStderrLogPath() -> URL {
        root.appendingPathComponent("sidecar.stderr.log")
    }

    func sidecarLaunchLabel(config: ContainerConfiguration) -> String {
        MacOSSidecarLaunchIdentity.launchLabel(
            sandboxID: config.id,
            persistenceID: config.macosGuest?.machineState?.persistenceID
        )
    }

    nonisolated func sidecarLaunchdDomain(uid: uid_t) -> String {
        MacOSSidecarLaunchIdentity.launchdDomain(effectiveUserID: UInt32(uid))
    }

    func sidecarGUIDomain() -> String {
        sidecarLaunchdDomain(uid: getuid())
    }

    nonisolated func sidecarLaunchAgentSessionOptions(uid: uid_t) -> [String: Any] {
        if uid == 0 {
            return [
                "LimitLoadToSessionType": ["Aqua", "Background", "System"]
            ]
        }
        return [
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
    }

    func sidecarFullLaunchLabel(config: ContainerConfiguration) -> String {
        "\(sidecarGUIDomain())/\(sidecarLaunchLabel(config: config))"
    }

    func sidecarBinaryURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["CONTAINER_RUNTIME_MACOS_SIDECAR_BIN"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
            throw ContainerizationError(.notFound, message: "sidecar binary override is not executable: \(override)")
        }
        if let execURL = Bundle.main.executableURL {
            let candidate = execURL.deletingLastPathComponent().appendingPathComponent("container-runtime-macos-sidecar")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw ContainerizationError(
            .notFound,
            message: "container-runtime-macos-sidecar not found next to runtime helper; install it under the plugin bin directory or set CONTAINER_RUNTIME_MACOS_SIDECAR_BIN"
        )
    }

    func startVirtualMachineViaSidecar(config: ContainerConfiguration, presentGUI: Bool = true) async throws {
        try validateMachineStateRuntimeConfiguration(config)
        if let handle = sidecarHandle {
            guard config.macosGuest?.machineState?.restoreStateID != nil, machineStateLeaseFD >= 0 else {
                throw ContainerizationError(
                    .invalidState,
                    message: "an existing sidecar can only be reconciled while a machine-state restore lease is held"
                )
            }
            try initializeVirtualMachineViaSidecar(
                client: handle.client,
                config: config,
                presentGUI: presentGUI,
                socketConnectRetries: 120
            )
            return
        }
        var retainedLease = false
        defer {
            if !retainedLease {
                releaseMachineStateLeaseIfPresent()
            }
        }
        try acquireMachineStateLeaseIfNeeded(config)
        let launchLabel = sidecarLaunchLabel(config: config)
        let plistURL = sidecarPlistPath()
        let socketURL = sidecarSocketPath(config: config)
        let stdoutURL = sidecarStdoutLogPath()
        let stderrURL = sidecarStderrLogPath()
        let binaryURL = try sidecarBinaryURL()

        try writeSidecarLaunchAgentPlist(
            plistURL: plistURL,
            launchLabel: launchLabel,
            sandboxID: config.id,
            binaryURL: binaryURL,
            socketURL: socketURL,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            machineState: config.macosGuest?.machineState
        )

        // A stable launch label lets a recreated sandbox clean up an orphaned
        // sidecar only after it has acquired the persistence lease. Refuse to
        // unlink its socket if launchd cannot terminate it.
        if config.macosGuest?.machineState == nil {
            try? bootoutLaunchAgent(fullLabel: sidecarFullLaunchLabel(config: config))
        } else {
            try bootoutLaunchAgent(fullLabel: sidecarFullLaunchLabel(config: config))
        }
        try removeStaleSidecarSocket(socketURL)

        try bootstrapLaunchAgent(plistURL: plistURL)

        let client = MacOSSidecarClient(
            socketPath: socketURL.path,
            log: log,
            bootstrapStartTimeoutSeconds: Self.sidecarBootstrapStartTimeoutSeconds
        )
        installSidecarEventPump(for: client)
        client.setDisconnectHandler { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleUnexpectedSidecarDisconnect(error)
            }
        }
        do {
            let restoreStateID = config.macosGuest?.machineState?.restoreStateID
            log.info(
                restoreStateID == nil ? "macOS sidecar bootstrap start" : "macOS sidecar machine-state restore start",
                metadata: [
                    "id": "\(config.id)",
                    "label": "\(launchLabel)",
                    "present_gui": "\(presentGUI)",
                    "restore_state_id": "\(restoreStateID ?? "-")",
                ])
            try initializeVirtualMachineViaSidecar(
                client: client,
                config: config,
                presentGUI: presentGUI,
                socketConnectRetries: 120
            )
            sidecarHandle = SidecarHandle(
                launchLabel: launchLabel,
                client: client
            )
            retainedLease = true
            writeContainerLog(Data(("sidecar vm bootstrap succeeded [label=\(launchLabel)]\n").utf8))
        } catch let error as MacOSMachineStateOutcomeIndeterminate {
            sidecarHandle = SidecarHandle(
                launchLabel: launchLabel,
                client: client
            )
            retainedLease = true
            writeContainerLog(
                Data(
                    ("sidecar machine-state outcome unknown; retaining sidecar and lease [label=\(launchLabel)] error=\(error.containerizationError.message)\n").utf8
                )
            )
            throw error
        } catch {
            writeContainerLog(Data(("sidecar vm bootstrap failed [label=\(launchLabel)] error=\(String(describing: error))\n").utf8))
            sidecarHandle = SidecarHandle(
                launchLabel: launchLabel,
                client: client
            )
            retainedLease = true
            try await stopAndQuitSidecarIfPresent()
            throw error
        }
    }

    func showGUIWindowViaSidecar() async throws {
        guard let handle = sidecarHandle else {
            throw ContainerizationError(.invalidState, message: "macOS sidecar is not initialized")
        }
        log.info("macOS sidecar show GUI request", metadata: ["label": "\(handle.launchLabel)"])
        writeContainerLog(Data(("sidecar show GUI request [label=\(handle.launchLabel)]\n").utf8))
        try handle.client.showGUI()
    }

    func stopAndQuitSidecarIfPresent() async throws {
        let config = configuration
        let requiresVerifiedCleanup = config?.macosGuest?.machineState != nil || machineStateLeaseFD >= 0
        guard let handle = sidecarHandle else {
            guard let config else {
                if requiresVerifiedCleanup {
                    throw ContainerizationError(
                        .invalidState,
                        message: "cannot release the machine-state runtime lease without its sandbox configuration"
                    )
                }
                return
            }
            do {
                try bootoutLaunchAgent(fullLabel: sidecarFullLaunchLabel(config: config))
                try removeStaleSidecarSocket(sidecarSocketPath(config: config))
            } catch {
                writeContainerLog(
                    Data(("sidecar cleanup verification failed [label=\(sidecarLaunchLabel(config: config))] error=\(String(describing: error))\n").utf8)
                )
                if requiresVerifiedCleanup {
                    throw error
                }
            }
            releaseMachineStateLeaseIfPresent()
            return
        }
        writeContainerLog(Data(("sidecar shutdown begin [label=\(handle.launchLabel)]\n").utf8))
        do {
            try handle.client.stopVM()
        } catch {
            writeContainerLog(Data(("sidecar stopVM failed [label=\(handle.launchLabel)] error=\(String(describing: error))\n").utf8))
        }
        handle.client.setDisconnectHandler(nil)
        do {
            try handle.client.quit()
        } catch {
            writeContainerLog(Data(("sidecar quit failed [label=\(handle.launchLabel)] error=\(String(describing: error))\n").utf8))
        }
        await drainPendingSidecarExitEvents()
        handle.client.setEventHandler(nil)
        await finishAndDrainSidecarEventPump()
        do {
            let fullLabel: String
            if let config {
                fullLabel = sidecarFullLaunchLabel(config: config)
            } else {
                fullLabel = "\(sidecarGUIDomain())/\(handle.launchLabel)"
            }
            try bootoutLaunchAgent(fullLabel: fullLabel)
            if let config {
                try removeStaleSidecarSocket(sidecarSocketPath(config: config))
            }
        } catch {
            writeContainerLog(Data(("sidecar bootout failed [label=\(handle.launchLabel)] error=\(String(describing: error))\n").utf8))
            if requiresVerifiedCleanup {
                throw error
            }
        }
        sidecarHandle = nil
        handle.client.closeControlConnection()
        releaseMachineStateLeaseIfPresent()
    }

    func installSidecarEventPump(for client: MacOSSidecarClient) {
        let eventPump = SidecarEventPump()
        let eventPumpTask = Task { [weak self] in
            guard let self else { return }
            for await event in eventPump.stream {
                await self.handleSidecarEvent(event)
                do {
                    try client.acknowledgeEvent(event)
                } catch {
                    self.log.warning(
                        "failed to acknowledge consumed sidecar event",
                        metadata: [
                            "process_id": "\(event.processID)",
                            "sequence": "\(event.sequence.map(String.init) ?? "-")",
                            "error": "\(error)",
                        ]
                    )
                }
            }
        }
        client.setEventHandler { event in
            eventPump.yield(event)
        }
        sidecarEventPump = eventPump
        sidecarEventPumpTask = eventPumpTask
    }

    private func drainPendingSidecarExitEvents() async {
        let deadline = Date().addingTimeInterval(Self.sidecarExitEventDrainTimeoutSeconds)
        while sessions.contains(where: { sessionID, session in
            isWorkloadSession(sessionID) && session.started && session.exitStatus == nil
        }) {
            guard Date() < deadline else {
                let pending = sessions.compactMap { sessionID, session in
                    isWorkloadSession(sessionID) && session.started && session.exitStatus == nil
                        ? session.processID
                        : nil
                }.sorted()
                writeContainerLog(
                    Data(("sidecar exit event drain timed out pending=\(pending.joined(separator: ","))\n").utf8)
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func finishAndDrainSidecarEventPump() async {
        let eventPump = sidecarEventPump
        let eventPumpTask = sidecarEventPumpTask
        sidecarEventPump = nil
        sidecarEventPumpTask = nil
        eventPump?.finish()
        if let eventPumpTask {
            await eventPumpTask.value
        }
    }

    func initializeVirtualMachineViaSidecar(
        client: MacOSSidecarClient,
        config: ContainerConfiguration,
        presentGUI: Bool,
        socketConnectRetries: Int,
        operationTimeoutSeconds: TimeInterval? = nil,
        reconciliationTimeoutSeconds: TimeInterval? = nil,
        reconciliationPollMicroseconds: useconds_t? = nil
    ) throws {
        guard let restoreStateID = config.macosGuest?.machineState?.restoreStateID else {
            writeContainerLog(
                Data(
                    ("sidecar bootstrap start [socket=\(sidecarSocketPath(config: config).path)] [presentGUI=\(presentGUI)]\n").utf8
                )
            )
            try client.bootstrapStart(
                presentGUI: presentGUI,
                socketConnectRetries: socketConnectRetries
            )
            return
        }

        writeContainerLog(Data(("sidecar restore start [state=\(restoreStateID)]\n").utf8))
        try restoreAndResumeMachineState(
            client: client,
            stateID: restoreStateID,
            socketConnectRetries: socketConnectRetries,
            operationTimeoutSeconds: operationTimeoutSeconds ?? Self.sidecarRestoreTimeoutSeconds,
            reconciliationTimeoutSeconds: reconciliationTimeoutSeconds ?? Self.sidecarRestoreTimeoutSeconds,
            reconciliationPollMicroseconds: reconciliationPollMicroseconds ?? Self.sidecarReconciliationPollMicroseconds
        )
        if config.macosGuest?.guiEnabled == true, presentGUI {
            try client.showGUI()
        }
        writeContainerLog(Data(("sidecar restore and resume succeeded [state=\(restoreStateID)]\n").utf8))
    }

    private func restoreAndResumeMachineState(
        client: MacOSSidecarClient,
        stateID: String,
        socketConnectRetries: Int,
        operationTimeoutSeconds: TimeInterval,
        reconciliationTimeoutSeconds: TimeInterval,
        reconciliationPollMicroseconds: useconds_t
    ) throws {
        let totalBudget = max(0, operationTimeoutSeconds) + max(0, reconciliationTimeoutSeconds)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(totalBudget * 1_000_000_000)
        var lastLifecycleState: MacOSVMRuntimeState?

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let remaining = TimeInterval(deadline - now) / 1_000_000_000
            let requestTimeout = min(operationTimeoutSeconds, max(0.05, remaining))
            let capabilities: MacOSSidecarCapabilities
            do {
                capabilities = try client.capabilities(
                    timeoutSeconds: requestTimeout,
                    distinguishTransportFailure: true
                )
                lastLifecycleState = capabilities.lifecycleState
            } catch {
                guard isIndeterminateMachineStateTransportError(error) else {
                    throw error
                }
                sleepBeforeMachineStateReconciliationRetry(
                    deadline: deadline,
                    pollMicroseconds: reconciliationPollMicroseconds
                )
                continue
            }

            switch capabilities.lifecycleState {
            case .created, .stopped, .paused:
                do {
                    let restored = try client.restoreMachineState(
                        stateID: stateID,
                        timeoutSeconds: requestTimeout,
                        socketConnectRetries: socketConnectRetries,
                        distinguishTransportFailure: true
                    )
                    try requireMachineStateResult(
                        restored,
                        expectedLifecycleState: .paused,
                        expectedStateID: stateID,
                        operation: "restore"
                    )
                } catch {
                    guard isIndeterminateMachineStateTransportError(error) else {
                        throw error
                    }
                    sleepBeforeMachineStateReconciliationRetry(
                        deadline: deadline,
                        pollMicroseconds: reconciliationPollMicroseconds
                    )
                    continue
                }

                do {
                    let resumed = try client.resumeVM(
                        timeoutSeconds: requestTimeout,
                        distinguishTransportFailure: true
                    )
                    try requireMachineStateResult(
                        resumed,
                        expectedLifecycleState: .running,
                        expectedStateID: stateID,
                        operation: "resume"
                    )
                    return
                } catch {
                    guard isIndeterminateMachineStateTransportError(error) else {
                        throw error
                    }
                }
            case .restoring, .resuming:
                break
            case .running:
                do {
                    let resumed = try client.resumeVM(
                        timeoutSeconds: requestTimeout,
                        distinguishTransportFailure: true
                    )
                    try requireMachineStateResult(
                        resumed,
                        expectedLifecycleState: .running,
                        expectedStateID: stateID,
                        operation: "resume"
                    )
                    return
                } catch {
                    guard isIndeterminateMachineStateTransportError(error) else {
                        throw error
                    }
                }
            case .starting, .pausing, .saving, .stopping, .failed:
                throw ContainerizationError(
                    .invalidState,
                    message:
                        "cannot reconcile machine-state restore \(stateID) from lifecycle state \(capabilities.lifecycleState.rawValue)"
                )
            }

            sleepBeforeMachineStateReconciliationRetry(
                deadline: deadline,
                pollMicroseconds: reconciliationPollMicroseconds
            )
        }

        throw MacOSMachineStateOutcomeIndeterminate(
            operation: lastLifecycleState == .resuming || lastLifecycleState == .running ? "resume" : "restore",
            stateID: stateID,
            lifecycleState: lastLifecycleState
        )
    }

    private func requireMachineStateResult(
        _ result: MacOSMachineStateOperationResult,
        expectedLifecycleState: MacOSVMRuntimeState,
        expectedStateID: String,
        operation: String
    ) throws {
        guard result.lifecycleState == expectedLifecycleState, result.stateID == expectedStateID else {
            throw ContainerizationError(
                .invalidState,
                message:
                    "machine-state \(operation) returned lifecycle=\(result.lifecycleState.rawValue) stateID=\(result.stateID ?? "-"); expected lifecycle=\(expectedLifecycleState.rawValue) stateID=\(expectedStateID)"
            )
        }
    }

    private func isIndeterminateMachineStateTransportError(_ error: Error) -> Bool {
        error is MacOSSidecarTransportFailure
    }

    private func sleepBeforeMachineStateReconciliationRetry(
        deadline: UInt64,
        pollMicroseconds: useconds_t
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return }
        let remainingMicroseconds = (deadline - now) / 1_000
        usleep(useconds_t(min(UInt64(pollMicroseconds), remainingMicroseconds)))
    }

    func validateMachineStateRuntimeConfiguration(_ config: ContainerConfiguration) throws {
        guard let machineState = config.macosGuest?.machineState else { return }
        guard machineState.protocolVersion == 2 else {
            throw ContainerizationError(
                .unsupported,
                message: "unsupported machine-state runtime protocol version \(machineState.protocolVersion)"
            )
        }
        try validateMachineStateIdentifier(machineState.persistenceID, maximumLength: 64, name: "persistence id")
        guard (machineState.restoreStateID == nil) == (machineState.restoreStateGeneration == nil) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "machine-state restore id and restore generation must be configured together"
            )
        }
        if let storageGeneration = machineState.storageGeneration, storageGeneration == 0 {
            throw ContainerizationError(.invalidArgument, message: "machine-state storage generation must be positive")
        }
        if let restoreStateID = machineState.restoreStateID {
            try validateMachineStateIdentifier(restoreStateID, maximumLength: 128, name: "restore state id")
            guard let restoreStateGeneration = machineState.restoreStateGeneration,
                restoreStateGeneration > 0,
                let storageGeneration = machineState.storageGeneration,
                storageGeneration > restoreStateGeneration
            else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "machine-state restore requires a positive saved generation and a newer writable storage generation"
                )
            }
            guard config.macosGuest?.blockDevices.first?.kind == .nbdUnixSocket else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "machine-state restore requires an explicit NBD root block device"
                )
            }
        }
        if let barrier = machineState.sidecarLifecycleBarrier {
            guard barrier.protocolVersion == MacOSSidecarLifecycleBarrierProtocol.current,
                UUID(uuidString: barrier.bootNonce)?.uuidString.lowercased() == barrier.bootNonce
            else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "machine-state sidecar lifecycle barrier is invalid"
                )
            }
        }
        try validateManagedMachineStateDirectory(machineState.storageDirectory)
        let expectedSocket = URL(fileURLWithPath: machineState.controlSocketPath).standardizedFileURL
        let socketAddress = sockaddr_un()
        guard expectedSocket.path == machineState.controlSocketPath,
            expectedSocket.path.hasPrefix("/"),
            expectedSocket.path.utf8.count < MemoryLayout.size(ofValue: socketAddress.sun_path)
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "machine-state control socket must be an absolute canonical local path"
            )
        }
        var parentValue = stat()
        let parent = expectedSocket.deletingLastPathComponent()
        try validateMachineStatePathHasNoSymbolicLinks(parent)
        guard lstat(parent.path, &parentValue) == 0, (parentValue.st_mode & S_IFMT) == S_IFDIR else {
            throw ContainerizationError(
                .invalidArgument,
                message: "machine-state control socket parent must be a directory and cannot be a symbolic link"
            )
        }
    }

    func acquireMachineStateLeaseIfNeeded(_ config: ContainerConfiguration) throws {
        guard let storageDirectory = config.macosGuest?.machineState?.storageDirectory else { return }
        if machineStateLeaseFD >= 0 { return }
        let leasePath = URL(fileURLWithPath: storageDirectory).appendingPathComponent("runtime.lock").path
        let fd = open(leasePath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else {
            throw ContainerizationError(
                .internalError,
                message: "failed to open machine-state persistence lease: \(String(cString: strerror(errno)))"
            )
        }
        var value = stat()
        guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw ContainerizationError(
                .invalidArgument,
                message: "machine-state persistence lease must be a regular file"
            )
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw ContainerizationError(.invalidState, message: "machine-state persistence id is already active")
        }
        _ = fchmod(fd, mode_t(S_IRUSR | S_IWUSR))
        machineStateLeaseFD = fd
    }

    func releaseMachineStateLeaseIfPresent() {
        guard machineStateLeaseFD >= 0 else { return }
        _ = flock(machineStateLeaseFD, LOCK_UN)
        Darwin.close(machineStateLeaseFD)
        machineStateLeaseFD = -1
    }

    private func validateManagedMachineStateDirectory(_ path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.path == path else {
            throw ContainerizationError(
                .invalidArgument,
                message: "machine-state storage directory must be an absolute canonical path"
            )
        }
        try validateMachineStatePathHasNoSymbolicLinks(url)
        var value = stat()
        guard lstat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
            throw ContainerizationError(
                .invalidArgument,
                message: "machine-state storage path must be a directory and cannot be a symbolic link"
            )
        }
    }

    private func validateMachineStatePathHasNoSymbolicLinks(_ url: URL) throws {
        let allowedSystemLinks: Set<String> = ["/etc", "/tmp", "/var"]
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var value = stat()
            if lstat(current.path, &value) != 0 {
                let code = errno
                let message: String
                if code == ENOENT {
                    message = "machine-state managed path does not exist: \(current.path)"
                } else {
                    message = "failed to inspect machine-state managed path \(current.path): \(String(cString: strerror(code)))"
                }
                throw ContainerizationError(
                    .invalidArgument,
                    message: message
                )
            }
            if (value.st_mode & S_IFMT) == S_IFLNK, !allowedSystemLinks.contains(current.path) {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "symbolic links are not allowed in machine-state managed paths"
                )
            }
        }
    }

    private func validateMachineStateIdentifier(_ value: String, maximumLength: Int, name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !value.isEmpty,
            value.utf8.count <= maximumLength,
            value != ".",
            value != "..",
            value.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw ContainerizationError(.invalidArgument, message: "invalid machine-state \(name)")
        }
    }

    private func removeStaleSidecarSocket(_ socketURL: URL) throws {
        var value = stat()
        guard lstat(socketURL.path, &value) == 0 else {
            if errno == ENOENT { return }
            throw ContainerizationError(
                .internalError,
                message: "failed to inspect sidecar socket: \(String(cString: strerror(errno)))"
            )
        }
        guard (value.st_mode & S_IFMT) == S_IFSOCK else {
            throw ContainerizationError(
                .invalidArgument,
                message: "refusing to remove non-socket sidecar control path"
            )
        }
        guard unlink(socketURL.path) == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "failed to remove stale sidecar socket: \(String(cString: strerror(errno)))"
            )
        }
    }

    func sidecarDial(port: UInt32) throws -> FileHandle {
        guard let sidecarHandle else {
            throw ContainerizationError(.invalidState, message: "macOS sidecar is not initialized")
        }
        let fd = try sidecarHandle.client.connectVsock(port: port)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func startProcessViaSidecarWithRetries(
        port: UInt32,
        processID: String,
        request: MacOSSidecarExecRequestPayload
    ) async throws {
        guard let sidecarHandle else {
            throw ContainerizationError(.invalidState, message: "macOS sidecar is not initialized")
        }

        var lastError: Error?
        let maxAttempts = 240
        for attempt in 1...maxAttempts {
            do {
                if shouldLogSidecarConnectAttempt(attempt, maxAttempts: maxAttempts) {
                    writeContainerLog(
                        Data(
                            ("sidecar process.start attempt \(attempt)/\(maxAttempts) for \(processID) on port \(port)\n").utf8
                        )
                    )
                }
                try sidecarHandle.client.processStart(port: port, processID: processID, request: request)
                if shouldLogSidecarConnectAttempt(attempt, maxAttempts: maxAttempts) {
                    writeContainerLog(
                        Data(
                            ("sidecar process.start attempt \(attempt)/\(maxAttempts) succeeded for \(processID) on port \(port)\n").utf8
                        )
                    )
                }
                return
            } catch {
                lastError = error
                if shouldLogSidecarConnectAttempt(attempt, maxAttempts: maxAttempts) {
                    writeContainerLog(
                        Data(
                            ("sidecar process.start attempt \(attempt)/\(maxAttempts) failed for \(processID): \(String(describing: error))\n").utf8
                        )
                    )
                }
                guard shouldRetrySidecarProcessStart(error), attempt < maxAttempts else {
                    throw error
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError ?? ContainerizationError(.timeout, message: "timed out waiting for sidecar process.start on port \(port)")
    }

    private func shouldRetrySidecarProcessStart(_ error: Error) -> Bool {
        if let containerError = error as? ContainerizationError {
            switch containerError.code {
            case .timeout, .interrupted, .invalidState:
                return true
            case .internalError:
                let message = containerError.message.lowercased()
                return message.contains("connection reset by peer")
                    || message.contains("broken pipe")
                    || message.contains("connection refused")
                    || message.contains("unexpected eof")
                    || message.contains("sidecar control connection closed")
                    || message.contains("failed to connect to macos sidecar control socket")
                    || message.contains("timed out waiting for guest-agent ready frame")
                    || message.contains("timed out waiting for guest-agent process start ack")
                    || message.contains("guest-agent exited before ready")
            default:
                return false
            }
        }

        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else {
            return false
        }
        return [
            Int(ECONNRESET),
            Int(EPIPE),
            Int(ENOTCONN),
            Int(ECONNREFUSED),
            Int(ETIMEDOUT),
        ].contains(nsError.code)
    }

    func writeSidecarLaunchAgentPlist(
        plistURL: URL,
        launchLabel: String,
        sandboxID: String,
        binaryURL: URL,
        socketURL: URL,
        stdoutURL: URL,
        stderrURL: URL,
        machineState: ContainerConfiguration.MacOSGuestOptions.MachineState? = nil
    ) throws {
        var args = [
            binaryURL.path,
            "--uuid", sandboxID,
            "--root", root.path,
            "--control-socket", socketURL.path,
        ]
        if let machineState, let barrier = machineState.sidecarLifecycleBarrier {
            args.append(contentsOf: [
                "--lifecycle-barrier-protocol", "\(barrier.protocolVersion)",
                "--lifecycle-barrier-nonce", barrier.bootNonce,
                "--lifecycle-persistence-id", machineState.persistenceID,
                "--lifecycle-storage-directory", machineState.storageDirectory,
            ])
        }

        let sessionOptions = sidecarLaunchAgentSessionOptions(uid: getuid())
        var plist: [String: Any] = [
            "Label": launchLabel,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProgramArguments": args,
            "StandardOutPath": stdoutURL.path,
            "StandardErrorPath": stderrURL.path,
        ]
        for (key, value) in sessionOptions {
            plist[key] = value
        }

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
    }

    func bootstrapLaunchAgent(plistURL: URL) throws {
        let domain = sidecarGUIDomain()
        try runLaunchctlChecked(args: ["bootstrap", domain, plistURL.path])
    }

    func bootoutLaunchAgent(fullLabel: String) throws {
        try ServiceManager.deregister(fullServiceLabel: fullLabel)
    }

    func runLaunchctlChecked(args: [String]) throws {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let out = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let merged = [out, err].filter { !$0.isEmpty }.joined(separator: "\\n")
            let suffix = merged.isEmpty ? "" : ", output: \(merged)"
            throw ContainerizationError(.internalError, message: "command `launchctl \(args.joined(separator: " "))` failed with status \(process.terminationStatus)\(suffix)")
        }
    }

    func shouldLogSidecarConnectAttempt(_ attempt: Int, maxAttempts: Int) -> Bool {
        if attempt <= 5 { return true }
        if attempt == maxAttempts { return true }
        return attempt % 20 == 0
    }
}
