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
import Testing

@Suite(.serialized, .enabled(if: CLITest.isCLIServiceAvailable(), "requires running container API service"))
class TestCLIMacOSBuildBase: CLITest {
    enum FileSystemEntry {
        case file(_ path: String, content: Data)
        case directory(_ path: String)
        case symbolicLink(_ path: String, target: String)
    }

    var macOSBaseReference: String {
        ProcessInfo.processInfo.environment["CONTAINER_MACOS_BASE_REF"] ?? "local/macos-base:latest"
    }

    static func isMacOSBuildE2EEnabled() -> Bool {
        guard CLITest.isCLIServiceAvailable() else {
            return false
        }
        return ProcessInfo.processInfo.environment["CONTAINER_ENABLE_MACOS_BUILD_E2E"] == "1"
    }

    func createTempDir() throws -> URL {
        let tempDir = testDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    func createContext(tempDir: URL, dockerfile: String, context: [FileSystemEntry]? = nil) throws {
        try dockerfile.data(using: .utf8)!.write(to: tempDir.appendingPathComponent("Dockerfile"), options: .atomic)

        let contextDir = tempDir.appendingPathComponent("context")
        try FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)

        for entry in context ?? [] {
            try createEntry(entry, contextDir)
        }
    }

    func runDarwinBuild(
        tempDir: URL,
        tag: String? = nil,
        output: String? = nil,
        otherArgs: [String] = []
    ) throws -> (outputData: Data, output: String, error: String, status: Int32) {
        var args = [
            "build",
            "--platform", "darwin/arm64",
            "--progress", "plain",
            "-f", tempDir.appendingPathComponent("Dockerfile").path,
        ]

        if let output {
            args += ["-o", output]
        }
        if let tag {
            args += ["-t", tag]
        }

        args.append(tempDir.appendingPathComponent("context").path)
        args += otherArgs
        return try run(arguments: args)
    }

    func runDarwinContainer(image: String, command: [String], expectOutput: Bool = true) throws -> String {
        let args = ["run", "--os", "darwin", "--rm", image] + command
        let response = try run(arguments: args)
        if response.status != 0 {
            throw CLIError.executionFailed("darwin run failed: stdout=\(response.output) stderr=\(response.error)")
        }

        if expectOutput, response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError.executionFailed("darwin run returned empty stdout")
        }

        return response.output
    }

    func loadImage(from archive: URL) throws {
        let response = try run(arguments: ["image", "load", "-i", archive.path])
        if response.status != 0 {
            throw CLIError.executionFailed("image load failed: \(response.error)")
        }
    }

    func deleteImageIfExists(_ name: String) {
        _ = try? run(arguments: ["image", "delete", "--force", name])
    }

    func assertFailure(_ response: (outputData: Data, output: String, error: String, status: Int32), contains needle: String) {
        #expect(response.status != 0, "expected command to fail")
        let combined = response.output + "\n" + response.error
        #expect(combined.contains(needle), "expected error to contain \(needle), got: \(combined)")
    }

    func assertDidNotDialLinuxBuilder(_ response: (outputData: Data, output: String, error: String, status: Int32)) {
        let combined = response.output + "\n" + response.error
        #expect(!combined.contains("Dialing builder"), "darwin build should not route through the Linux builder")
    }

    func createTarArchive(at archiveURL: URL, sourceDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-C", sourceDirectory.path, "-cf", archiveURL.path, "."]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "tar failed"
            throw CLIError.executionFailed(message)
        }
    }

    func applicationDataRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("com.apple.container")
    }

    func directoryEntryNames(at url: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        return Set(entries.map(\.lastPathComponent))
    }

    func waitForDirectoryEntries(at url: URL, equals expected: Set<String>, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try directoryEntryNames(at: url) == expected {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let actual = try directoryEntryNames(at: url).sorted()
        throw CLIError.executionFailed(
            "directory cleanup did not converge for \(url.path); expected=\(expected.sorted()) actual=\(actual)"
        )
    }

    func waitForNoNewDirectoryEntries(at url: URL, baseline: Set<String>, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let actual = try directoryEntryNames(at: url)
            if actual.subtracting(baseline).isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let actual = try directoryEntryNames(at: url)
        let leaked = actual.subtracting(baseline).sorted()
        throw CLIError.executionFailed(
            "directory cleanup left new entries under \(url.path): \(leaked)"
        )
    }

    private func createEntry(_ entry: FileSystemEntry, _ contextDir: URL) throws {
        switch entry {
        case .file(let path, let content):
            let fullPath = contextDir.appending(path: path)
            try FileManager.default.createDirectory(at: fullPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fullPath)

        case .directory(let path):
            try FileManager.default.createDirectory(
                at: contextDir.appendingPathComponent(path),
                withIntermediateDirectories: true
            )

        case .symbolicLink(let path, let target):
            let fullPath = contextDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fullPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: fullPath.path, withDestinationPath: target)
        }
    }
}
