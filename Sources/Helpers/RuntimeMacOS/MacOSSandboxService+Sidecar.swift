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

import ContainerResource
import ContainerizationError
import Darwin
import Foundation
import RuntimeMacOSSidecarShared

extension MacOSSandboxService {
    private static let sidecarBootstrapStartTimeoutSeconds: TimeInterval = 120.0
    private static let sidecarRestoreTimeoutSeconds: TimeInterval = 600.0
    private static let sidecarExitEventDrainTimeoutSeconds: TimeInterval = 5.0

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
        if let persistenceID = config.macosGuest?.machineState?.persistenceID {
            return "com.apple.container.runtime.container-runtime-macos-sidecar.state.\(persistenceID)"
        }
        return "com.apple.container.runtime.container-runtime-macos-sidecar.\(config.id)"
    }

    nonisolated func sidecarLaunchdDomain(uid: uid_t) -> String {
        if uid == 0 {
            return "user/0"
        }
        return "gui/\(uid)"
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
            stderrURL: stderrURL
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
        } catch {
            writeContainerLog(Data(("sidecar vm bootstrap failed [label=\(launchLabel)] error=\(String(describing: error))\n").utf8))
            client.setEventHandler(nil)
            client.setDisconnectHandler(nil)
            await finishAndDrainSidecarEventPump()
            try? client.quit()
            try? bootoutLaunchAgent(fullLabel: sidecarFullLaunchLabel(config: config))
            sidecarHandle = nil
            releaseMachineStateLeaseIfPresent()
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

    func stopAndQuitSidecarIfPresent() async {
        guard let handle = sidecarHandle else {
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
        sidecarHandle = nil
        handle.client.closeControlConnection()
        do {
            try bootoutLaunchAgent(fullLabel: "\(sidecarGUIDomain())/\(handle.launchLabel)")
        } catch {
            writeContainerLog(Data(("sidecar bootout failed [label=\(handle.launchLabel)] error=\(String(describing: error))\n").utf8))
        }
        releaseMachineStateLeaseIfPresent()
    }

    func installSidecarEventPump(for client: MacOSSidecarClient) {
        let eventPump = SidecarEventPump()
        let eventPumpTask = Task { [weak self] in
            guard let self else { return }
            for await event in eventPump.stream {
                await self.handleSidecarEvent(event)
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
        socketConnectRetries: Int
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
        let restored = try client.restoreMachineState(
            stateID: restoreStateID,
            timeoutSeconds: Self.sidecarRestoreTimeoutSeconds,
            socketConnectRetries: socketConnectRetries
        )
        guard restored.lifecycleState == .paused else {
            throw ContainerizationError(
                .invalidState,
                message: "machine-state restore did not leave the VM paused"
            )
        }
        let resumed = try client.resumeVM(timeoutSeconds: Self.sidecarRestoreTimeoutSeconds)
        guard resumed.lifecycleState == .running else {
            throw ContainerizationError(
                .invalidState,
                message: "machine-state resume did not leave the VM running"
            )
        }
        if config.macosGuest?.guiEnabled == true, presentGUI {
            try client.showGUI()
        }
        writeContainerLog(Data(("sidecar restore and resume succeeded [state=\(restoreStateID)]\n").utf8))
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
        if let restoreStateID = machineState.restoreStateID {
            try validateMachineStateIdentifier(restoreStateID, maximumLength: 128, name: "restore state id")
            guard config.macosGuest?.blockDevices.first?.kind == .nbdUnixSocket else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "machine-state restore requires an explicit NBD root block device"
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
        let fd = open(leasePath, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
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
        stderrURL: URL
    ) throws {
        let args = [
            binaryURL.path,
            "--uuid", sandboxID,
            "--root", root.path,
            "--control-socket", socketURL.path,
        ]

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
        do {
            try runLaunchctlChecked(args: ["bootout", fullLabel])
        } catch {
            let text = String(describing: error)
            if text.contains("No such process") || text.contains("status 3") {
                return
            }
            throw error
        }
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
