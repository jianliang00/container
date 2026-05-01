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

import CryptoKit
import Darwin
import Foundation

public struct MacOSKubeadmJoinRunner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func run(options: MacOSKubeadmJoinOptions, log: MacOSKubeadmLog) throws {
        try runPreflight(options: options, log: log)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)

        log.info("prepared join plan with \(plan.steps.count) steps")
        if options.dryRun {
            log.info("dry-run enabled; no files will be written and no services will be started")
        }

        for (offset, step) in plan.steps.enumerated() {
            log.step(offset + 1, total: plan.steps.count, step.message)
            log.debug(step.action.safeDescription)
            try execute(step.action, dryRun: options.dryRun, log: log)
        }

        if options.dryRun {
            log.info("dry-run completed; no changes made")
        } else {
            log.info("join completed")
            log.info("next: approve kubelet bootstrap CSR if your control plane does not auto-approve it")
            log.info("next: apply /usr/local/share/container-macos-node/manifests/runtimeclass-macos.yaml from an admin workstation")
        }
    }

    private func runPreflight(options: MacOSKubeadmJoinOptions, log: MacOSKubeadmLog) throws {
        log.info("running preflight checks")

        if !options.dryRun && geteuid() != 0 {
            throw MacOSKubeadmError.preflightFailed("join must run as root; rerun with sudo or pass --dry-run")
        }

        #if os(macOS)
        #else
        throw MacOSKubeadmError.preflightFailed("container-macos-kubeadm only supports macOS")
        #endif

        #if arch(arm64)
        #else
        throw MacOSKubeadmError.preflightFailed("macOS node packages currently require arm64")
        #endif

        if options.bootstrapToken.range(of: #"^[a-z0-9]{6}\.[a-z0-9]{16}$"#, options: .regularExpression) == nil {
            log.warning("bootstrap token does not match Kubernetes bootstrap-token format abcdef.0123456789abcdef")
        }

        try validateReadableFile(options.caCertificatePath, name: "CA certificate")

        if let expectedSHA256 = options.caCertificateSHA256 {
            let actual = try sha256Hex(path: options.caCertificatePath)
            let normalized = expectedSHA256.replacingOccurrences(of: "sha256:", with: "").lowercased()
            guard actual == normalized else {
                throw MacOSKubeadmError.preflightFailed(
                    "CA certificate sha256 mismatch: expected \(normalized), got \(actual)"
                )
            }
            log.info("validated CA certificate sha256")
        }

        let requiredExecutables = [
            "/usr/local/bin/container",
            "/usr/local/bin/container-cri-shim-macos",
            "/usr/local/bin/container-kube-proxy-macos",
            "/usr/local/bin/kubelet",
            "/opt/cni/bin/container-cni-macvmnet",
        ]
        for executable in requiredExecutables {
            if !options.dryRun {
                try validateExecutable(options.rooted(executable), name: executable)
            } else {
                log.debug("would validate executable \(options.rooted(executable))")
            }
        }
    }

    private func execute(_ action: MacOSKubeadmAction, dryRun: Bool, log: MacOSKubeadmLog) throws {
        if dryRun {
            log.info("would \(action.safeDescription)")
            return
        }

        switch action {
        case .createDirectory(let path, let mode):
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            try setMode(path, mode: mode)
        case .copyFile(let source, let destination, let mode, _):
            try fileManager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination) {
                try fileManager.removeItem(atPath: destination)
            }
            try fileManager.copyItem(atPath: source, toPath: destination)
            try setMode(destination, mode: mode)
        case .writeFile(let path, let contents, let mode, _):
            try fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
            try setMode(path, mode: mode)
        case .runCommand(let arguments, let bestEffort):
            try runCommand(arguments, bestEffort: bestEffort, log: log)
        case .waitForPath(let path, let timeoutSeconds):
            try waitForPath(path, timeoutSeconds: timeoutSeconds)
        case .removePath:
            throw MacOSKubeadmError.invalidInput("join plan cannot remove paths")
        }
    }

    private func runCommand(_ arguments: [String], bestEffort: Bool, log: MacOSKubeadmLog) throws {
        guard let executable = arguments.first else {
            throw MacOSKubeadmError.invalidInput("empty command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty {
            log.debug(output)
        }

        guard process.terminationStatus == 0 else {
            if bestEffort {
                log.debug("best-effort command failed with status \(process.terminationStatus): \(output)")
                return
            }
            throw MacOSKubeadmError.commandFailed(
                command: MacOSKubeadmAction.runCommand(arguments: arguments, bestEffort: false).safeDescription,
                status: process.terminationStatus,
                output: output
            )
        }
    }

    private func waitForPath(_ path: String, timeoutSeconds: Int) throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if fileManager.fileExists(atPath: path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw MacOSKubeadmError.timedOut("path did not appear: \(path)")
    }

    private func validateReadableFile(_ path: String, name: String) throws {
        guard fileManager.isReadableFile(atPath: path) else {
            throw MacOSKubeadmError.preflightFailed("\(name) is not readable: \(path)")
        }
    }

    private func validateExecutable(_ path: String, name: String) throws {
        guard fileManager.isExecutableFile(atPath: path) else {
            throw MacOSKubeadmError.preflightFailed("\(name) is not executable at \(path)")
        }
    }

    private func setMode(_ path: String, mode: Int) throws {
        if chmod(path, mode_t(mode)) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func sha256Hex(path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct MacOSKubeadmResetRunner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func run(options: MacOSKubeadmResetOptions, log: MacOSKubeadmLog) throws {
        let plan = try MacOSKubeadmPlanner.resetPlan(options: options)
        try runPreflight(options: options, log: log)

        log.info("prepared reset plan with \(plan.steps.count) steps")
        if options.dryRun {
            log.info("dry-run enabled; no files will be removed and no services will be stopped")
        } else if options.purgeState {
            log.warning("purge-state enabled; kubelet, CRI/CNI state, and node logs will be removed")
        }

        for (offset, step) in plan.steps.enumerated() {
            log.step(offset + 1, total: plan.steps.count, step.message)
            log.debug(step.action.safeDescription)
            try execute(step.action, dryRun: options.dryRun, log: log)
        }

        if options.dryRun {
            log.info("dry-run completed; no changes made")
        } else {
            log.info("reset completed")
            log.info("binaries and installed package files were preserved")
        }
    }

    private func runPreflight(options: MacOSKubeadmResetOptions, log: MacOSKubeadmLog) throws {
        log.info("running reset preflight checks")

        if !options.dryRun && geteuid() != 0 {
            throw MacOSKubeadmError.preflightFailed("reset must run as root; rerun with sudo or pass --dry-run")
        }
    }

    private func execute(_ action: MacOSKubeadmAction, dryRun: Bool, log: MacOSKubeadmLog) throws {
        if dryRun {
            log.info("would \(action.safeDescription)")
            return
        }

        switch action {
        case .removePath(let path, _, let bestEffort, _):
            do {
                guard fileManager.fileExists(atPath: path) else {
                    return
                }
                try fileManager.removeItem(atPath: path)
            } catch {
                if bestEffort {
                    log.debug("best-effort remove failed for \(path): \(error)")
                    return
                }
                throw error
            }
        case .runCommand(let arguments, let bestEffort):
            try MacOSKubeadmProcess.run(arguments, bestEffort: bestEffort, log: log)
        case .createDirectory, .copyFile, .writeFile, .waitForPath:
            throw MacOSKubeadmError.invalidInput("unsupported reset action: \(action.safeDescription)")
        }
    }
}

public struct MacOSKubeadmStatusOptions: Sendable, Equatable {
    public var installRoot: String
    public var debug: Bool

    public init(installRoot: String = "/", debug: Bool = false) {
        self.installRoot = installRoot
        self.debug = debug
    }
}

extension MacOSKubeadmStatusOptions {
    public var rootPrefix: String {
        let trimmed = installRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return ""
        }
        return "/" + trimmed
    }

    public func rooted(_ absolutePath: String) -> String {
        precondition(absolutePath.hasPrefix("/"), "path must be absolute")
        guard !rootPrefix.isEmpty else {
            return absolutePath
        }
        return rootPrefix + absolutePath
    }
}

public struct MacOSKubeadmStatusRunner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func run(options: MacOSKubeadmStatusOptions, log: MacOSKubeadmLog) throws {
        guard options.installRoot.hasPrefix("/") else {
            throw MacOSKubeadmError.invalidInput("--install-root must be an absolute path")
        }

        log.info("checking macOS Kubernetes node status")

        let files = [
            "/usr/local/bin/container-macos-kubeadm",
            "/usr/local/bin/container-cri-shim-macos",
            "/usr/local/bin/container-kube-proxy-macos",
            "/usr/local/bin/kubelet",
            "/opt/cni/bin/container-cni-macvmnet",
            "/etc/kubernetes/pki/ca.crt",
            "/etc/kubernetes/bootstrap-kubelet.kubeconfig",
            "/etc/kubernetes/kubelet.kubeconfig",
            "/etc/kubernetes/kube-proxy.kubeconfig",
            "/etc/kubernetes/kubelet-config.yaml",
            "/etc/kubernetes/container-cri-shim-macos-config.json",
            "/etc/kubernetes/kube-proxy.conf",
            "/etc/cni/net.d/10-macvmnet.conflist",
        ]

        for file in files {
            let rooted = options.rooted(file)
            log.info("\(file): \(fileManager.fileExists(atPath: rooted) ? "present" : "missing")")
        }

        let socket = "/var/run/container-cri-macos.sock"
        log.info("\(socket): \(fileManager.fileExists(atPath: options.rooted(socket)) ? "present" : "missing")")

        if options.rootPrefix.isEmpty {
            for label in [
                "com.apple.container.cri-shim-macos",
                "com.apple.container.kube-proxy-macos",
                "com.apple.container.kubelet",
            ] {
                log.info("\(label): \(serviceStatus(label: label, log: log))")
            }
        } else {
            log.info("launchd services: skipped for install root \(options.installRoot)")
        }
    }

    private func serviceStatus(label: String, log: MacOSKubeadmLog) -> String {
        do {
            let output = try MacOSKubeadmProcess.runCapturing(arguments: ["/bin/launchctl", "print", "system/\(label)"])
            if output.contains("state = running") {
                return "running"
            }
            return "loaded"
        } catch {
            log.debug("launchctl status failed for \(label): \(error)")
            return "not loaded"
        }
    }
}

enum MacOSKubeadmProcess {
    static func run(_ arguments: [String], bestEffort: Bool, log: MacOSKubeadmLog) throws {
        do {
            let output = try runCapturing(arguments: arguments)
            if !output.isEmpty {
                log.debug(output)
            }
        } catch {
            if bestEffort {
                log.debug("best-effort command failed: \(error)")
                return
            }
            throw error
        }
    }

    static func runCapturing(arguments: [String]) throws -> String {
        guard let executable = arguments.first else {
            throw MacOSKubeadmError.invalidInput("empty command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw MacOSKubeadmError.commandFailed(
                command: MacOSKubeadmAction.runCommand(arguments: arguments, bestEffort: false).safeDescription,
                status: process.terminationStatus,
                output: output
            )
        }

        return output
    }
}
