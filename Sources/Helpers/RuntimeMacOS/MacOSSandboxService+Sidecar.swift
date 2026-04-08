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
    func sidecarSocketPath(config: ContainerConfiguration) -> URL {
        URL(fileURLWithPath: "/tmp/ctrm-sidecar-\(config.id).sock")
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
        "com.apple.container.runtime.container-runtime-macos-sidecar.\(config.id)"
    }

    func sidecarGUIDomain() -> String {
        "gui/\(getuid())"
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

    func startVirtualMachineViaSidecar(config: ContainerConfiguration) async throws {
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

        // Best-effort cleanup of stale unit/socket before bootstrap.
        try? bootoutLaunchAgent(fullLabel: sidecarFullLaunchLabel(config: config))
        _ = unlink(socketURL.path)

        try bootstrapLaunchAgent(plistURL: plistURL)

        let client = MacOSSidecarClient(socketPath: socketURL.path, log: log)
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
        client.setDisconnectHandler { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleUnexpectedSidecarDisconnect(error)
            }
        }
        sidecarEventPump = eventPump
        sidecarEventPumpTask = eventPumpTask
        do {
            writeContainerLog(Data(("sidecar bootstrap start [label=\(launchLabel)] [socket=\(socketURL.path)]\n").utf8))
            try client.bootstrapStart(socketConnectRetries: 120)
            sidecarHandle = SidecarHandle(
                launchLabel: launchLabel,
                client: client
            )
            writeContainerLog(Data(("sidecar vm bootstrap succeeded [label=\(launchLabel)]\n").utf8))
        } catch {
            writeContainerLog(Data(("sidecar vm bootstrap failed [label=\(launchLabel)] error=\(String(describing: error))\n").utf8))
            client.setEventHandler(nil)
            client.setDisconnectHandler(nil)
            eventPump.finish()
            eventPumpTask.cancel()
            sidecarEventPump = nil
            sidecarEventPumpTask = nil
            try? client.quit()
            try? bootoutLaunchAgent(fullLabel: sidecarFullLaunchLabel(config: config))
            sidecarHandle = nil
            throw error
        }
    }

    func stopAndQuitSidecarIfPresent() async {
        guard let handle = sidecarHandle else { return }
        writeContainerLog(Data(("sidecar shutdown begin [label=\(handle.launchLabel)]\n").utf8))
        do {
            try handle.client.stopVM()
        } catch {
            writeContainerLog(Data(("sidecar stopVM failed [label=\(handle.launchLabel)] error=\(String(describing: error))\n").utf8))
        }
        do {
            try handle.client.quit()
        } catch {
            writeContainerLog(Data(("sidecar quit failed [label=\(handle.launchLabel)] error=\(String(describing: error))\n").utf8))
        }
        do {
            try bootoutLaunchAgent(fullLabel: "\(sidecarGUIDomain())/\(handle.launchLabel)")
        } catch {
            writeContainerLog(Data(("sidecar bootout failed [label=\(handle.launchLabel)] error=\(String(describing: error))\n").utf8))
        }
        handle.client.setEventHandler(nil)
        handle.client.setDisconnectHandler(nil)
        handle.client.closeControlConnection()
        sidecarEventPump?.finish()
        sidecarEventPumpTask?.cancel()
        sidecarEventPump = nil
        sidecarEventPumpTask = nil
        sidecarHandle = nil
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

        let plist: [String: Any] = [
            "Label": launchLabel,
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ProgramArguments": args,
            "StandardOutPath": stdoutURL.path,
            "StandardErrorPath": stderrURL.path,
        ]

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
