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

/// Reclaims the launchd instances and VM files belonging to one stateless
/// macOS sandbox. The bundle is the durable retry record and must outlive this
/// operation.
public struct MacOSRuntimeCleanup {
    public static let pendingFilename = "runtime-cleanup-pending"

    struct CommandResult {
        var status: Int32
        var output: String
        var error: String = ""
    }

    var run: (String, [String]) throws -> CommandResult = Self.runCommand
    var processExists: (Int32) -> Bool = { kill($0, 0) == 0 || errno != ESRCH }
    var sleep: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
    var attempts = 50

    public init() {}

    public static func markPending(root: URL) throws {
        try Data().write(to: root.appendingPathComponent(pendingFilename), options: .atomic)
    }

    public static func isPending(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(pendingFilename).path)
    }

    public static func clearPending(root: URL) throws {
        let marker = root.appendingPathComponent(pendingFilename)
        do {
            try FileManager.default.removeItem(at: marker)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// Run bounded host probes off the runtime/API actor so inventory requests
    /// for other sandboxes remain responsive while cleanup is pending.
    public static func stop(
        id: String,
        root: URL,
        parentLabel: String? = nil,
        sidecarLabel: String
    ) async throws {
        try await Task.detached {
            try Self().stop(
                id: id,
                root: root,
                parentLabel: parentLabel,
                sidecarLabel: sidecarLabel
            )
        }.value
    }

    public static func confirmStopped(
        id: String,
        root: URL,
        parentLabel: String,
        sidecarLabel: String
    ) async throws {
        try await Task.detached {
            try Self().confirmStopped(
                id: id,
                root: root,
                parentLabel: parentLabel,
                sidecarLabel: sidecarLabel
            )
        }.value
    }

    func stop(
        id: String,
        root: URL,
        parentLabel: String? = nil,
        sidecarLabel: String
    ) throws {
        try validate(id: id, root: root)
        try Self.markPending(root: root)
        // Stop the parent first so it cannot bootstrap a replacement sidecar.
        if let parentLabel {
            try removeService(label: parentLabel)
        }
        try removeService(label: sidecarLabel)
        let deadline = Date().addingTimeInterval(10)
        for _ in 0..<attempts {
            guard Date() < deadline else { break }
            if try !hasOpenVMFiles(root: root) { return }
            sleep()
        }
        throw ContainerizationError(
            .timeout,
            message: "VM still holds sandbox files for \(id); retaining cleanup state"
        )
    }

    /// Read-only check used before returning NotFound for missing API metadata.
    func confirmStopped(
        id: String,
        root: URL,
        parentLabel: String,
        sidecarLabel: String
    ) throws {
        try validate(id: id, root: root)
        guard try serviceHasExited(label: parentLabel),
            try serviceHasExited(label: sidecarLabel),
            try !hasOpenVMFiles(root: root)
        else {
            throw ContainerizationError(
                .invalidState,
                message: "sandbox \(id) still has runtime resources; retaining metadata"
            )
        }
    }

    public func serviceHasExited(label: String) throws -> Bool {
        guard let pid = try servicePID(label: label) else { return true }
        return pid == 0 || !processExists(pid)
    }

    private func validate(id: String, root: URL) throws {
        guard !id.isEmpty, id != ".", id != "..",
            id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
            root.lastPathComponent == id
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid sandbox cleanup identity"
            )
        }
    }

    private func servicePID(label: String) throws -> Int32? {
        let result = try run("/bin/launchctl", ["print", label])
        if result.status == 0 {
            for line in result.output.split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                if fields.count == 3,
                    fields[0] == "pid",
                    fields[1] == "=",
                    let pid = Int32(fields[2]),
                    pid > 0
                {
                    return pid
                }
            }
            if result.output.split(separator: "\n").contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == "state = not running"
            }) {
                return 0
            }
            throw ContainerizationError(
                .internalError,
                message: "launchd did not report a recognized process state for \(label)"
            )
        }
        if result.status == 113 || result.status == 3,
            result.error.contains("Could not find service")
                || result.error.contains("No such process")
        {
            return nil
        }
        throw ContainerizationError(
            .internalError,
            message: "cannot inspect launchd service \(label): \(result.error)"
        )
    }

    private func removeService(label: String) throws {
        guard let pid = try servicePID(label: label) else { return }
        let result = try run("/bin/launchctl", ["bootout", label])
        // A failed bootout can race a successful stop by another caller.
        // Success still requires independent absence and process-exit proof.
        let deadline = Date().addingTimeInterval(10)
        for _ in 0..<attempts {
            guard Date() < deadline else { break }
            if try servicePID(label: label) == nil,
                pid == 0 || !processExists(pid)
            {
                return
            }
            sleep()
        }
        throw ContainerizationError(
            .timeout,
            message:
                "launchd service \(label) has not exited (bootout status \(result.status)): \(result.error)"
        )
    }

    private func hasOpenVMFiles(root: URL) throws -> Bool {
        // Enumerate names instead of querying an inode so open, unlinked files
        // remain visible. Never signal processes found by this read-only scan.
        let result = try run(
            "/usr/sbin/lsof",
            ["-nP", "-w", "-Fn", "-u", String(getuid())]
        )
        guard result.status == 0, result.error.isEmpty else {
            throw ContainerizationError(
                .internalError,
                message: "cannot confirm VM file closure: \(result.error)"
            )
        }
        let roots = Set([root.standardizedFileURL.path, Self.canonicalPath(root)])
        let paths = Set(
            roots.flatMap {
                ["\($0)/Disk.img", "\($0)/AuxiliaryStorage"]
            })
        return result.output.split(separator: "\n").contains { line in
            guard line.first == "n" else { return false }
            let name = String(line.dropFirst())
            return paths.contains(name)
                || paths.contains(
                    name.replacingOccurrences(of: " (deleted)", with: "")
                )
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + suffix.reversed())
                    .joined(separator: "/")
            }
            guard ancestor.path != "/" else {
                return url.standardizedFileURL.path
            }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }

    private static func runCommand(
        _ executable: String,
        _ arguments: [String]
    ) throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer {
            try? out.close()
            try? err.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            throw ContainerizationError(
                .timeout,
                message: "timed out executing \(executable)"
            )
        }
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: try Data(contentsOf: outURL), as: UTF8.self),
            error: String(decoding: try Data(contentsOf: errURL), as: UTF8.self)
        )
    }
}
