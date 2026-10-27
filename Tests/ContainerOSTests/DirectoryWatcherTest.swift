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

import ContainerOS
import ContainerizationError
import DNSServer
import Foundation
import Synchronization
import SystemPackage
import Testing

struct DirectoryWatcherTest {
    let testUUID = UUID().uuidString

    private var testDir: FilePath {
        let tempURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".clitests")
            .appendingPathComponent(testUUID)
        try! FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        return FilePath(tempURL.path)
    }

    private func withTempDir<T>(_ body: (FilePath) async throws -> T) async throws -> T {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let tempPath = FilePath(tempURL.path)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return try await body(tempPath)
    }

    private final class CreatedPaths: Sendable {
        private let storage = Mutex<[FilePath]>([])

        var paths: [FilePath] {
            storage.withLock { $0 }
        }

        func append(_ path: FilePath) {
            storage.withLock { $0.append(path) }
        }
    }

    private func waitForPaths(_ expected: Set<String>, in createdPaths: CreatedPaths) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let observed = Set(createdPaths.paths.compactMap { $0.lastComponent?.string })
            if expected.isSubset(of: observed) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let observed = Set(createdPaths.paths.compactMap { $0.lastComponent?.string })
        try #require(expected.isSubset(of: observed), "directory watcher did not observe \(expected); observed \(observed)")
    }

    @Test func testWatchingExistingDirectory() async throws {
        try await withTempDir { tempPath in

            let watcher = DirectoryWatcher(directoryPath: tempPath, log: nil)
            let createdPaths = CreatedPaths()
            let name = "newFile"

            await watcher.startWatching { [createdPaths] paths in
                for path in paths where path.lastComponent?.string == name {
                    createdPaths.append(path)
                }
            }

            try await Task.sleep(for: .milliseconds(100))
            let newFile = tempPath.appending(name)
            FileManager.default.createFile(atPath: newFile.string, contents: nil)
            try await waitForPaths([name], in: createdPaths)

            #expect(!createdPaths.paths.isEmpty, "directory watcher failed to detect new file")
            #expect(createdPaths.paths.first?.lastComponent?.string == name)
        }
    }

    @Test func testStoredSourceObservesRepeatedChanges() async throws {
        try await withTempDir { tempPath in
            let watcher = DirectoryWatcher(directoryPath: tempPath, log: nil)
            let createdPaths = CreatedPaths()
            let expectedNames = ["first", "second"]

            await watcher.startWatching { [createdPaths] paths in
                for path in paths where expectedNames.contains(path.lastComponent?.string ?? "") {
                    createdPaths.append(path)
                }
            }

            try await Task.sleep(for: .milliseconds(100))
            for name in expectedNames {
                FileManager.default.createFile(atPath: tempPath.appending(name).string, contents: nil)
                try await waitForPaths([name], in: createdPaths)
            }

            let observedNames = Set(createdPaths.paths.compactMap { $0.lastComponent?.string })
            #expect(observedNames == Set(expectedNames))
        }
    }

    @Test func testWatchingNonExistingDirectory() async throws {
        try await withTempDir { tempPath in
            let uuid = UUID().uuidString
            let childPath = tempPath.appending(uuid)

            let watcher = DirectoryWatcher(directoryPath: childPath, log: nil)
            let createdPaths = CreatedPaths()
            let name = "newFile"

            await watcher.startWatching { [createdPaths] paths in
                for path in paths where path.lastComponent?.string == name {
                    createdPaths.append(path)
                }
            }

            try await Task.sleep(for: .milliseconds(100))
            try FileManager.default.createDirectory(atPath: childPath.string, withIntermediateDirectories: true)

            try await Task.sleep(for: DirectoryWatcher.watchPeriod)
            let newFile = childPath.appending(name)
            FileManager.default.createFile(atPath: newFile.string, contents: nil)
            try await waitForPaths([name], in: createdPaths)

            #expect(!createdPaths.paths.isEmpty, "directory watcher failed to detect parent directory")
            #expect(createdPaths.paths.first?.lastComponent?.string == name)
        }
    }

    @Test func testWatchingNonExistingParent() async throws {
        try await withTempDir { tempPath in
            let parent = UUID().uuidString
            let child = UUID().uuidString
            let childPath = tempPath.appending(parent).appending(child)

            let watcher = DirectoryWatcher(directoryPath: childPath, log: nil)
            let createdPaths = CreatedPaths()
            let name = "newFile"

            await watcher.startWatching { paths in
                for path in paths where path.lastComponent?.string == name {
                    createdPaths.append(path)
                }
            }

            try await Task.sleep(for: .milliseconds(100))
            try FileManager.default.createDirectory(atPath: childPath.string, withIntermediateDirectories: true)

            try await Task.sleep(for: DirectoryWatcher.watchPeriod)

            let newFile = childPath.appending(name)
            FileManager.default.createFile(atPath: newFile.string, contents: nil)
            try await waitForPaths([name], in: createdPaths)

            #expect(!createdPaths.paths.isEmpty, "directory watcher failed to detect parent directory")
            #expect(createdPaths.paths.first?.lastComponent?.string == name)
        }
    }

    @Test func testWatchingRecreatedDirectory() async throws {
        try await withTempDir { tempPath in
            let dirPath = tempPath.appending(UUID().uuidString)
            try FileManager.default.createDirectory(atPath: dirPath.string, withIntermediateDirectories: true)

            let watcher = DirectoryWatcher(directoryPath: dirPath, log: nil)
            let createdPaths = CreatedPaths()
            let beforeDelete = "beforeDelete"
            let afterDelete = "afterDelete"

            await watcher.startWatching { [createdPaths] paths in
                for path in paths
                where path.lastComponent?.string == beforeDelete || path.lastComponent?.string == afterDelete {
                    createdPaths.append(path)
                }
            }

            try await Task.sleep(for: .milliseconds(100))
            let file1 = dirPath.appending(beforeDelete)
            FileManager.default.createFile(atPath: file1.string, contents: nil)
            try await waitForPaths([beforeDelete], in: createdPaths)

            try FileManager.default.removeItem(atPath: dirPath.string)
            try await Task.sleep(for: .milliseconds(100))
            try FileManager.default.createDirectory(atPath: dirPath.string, withIntermediateDirectories: true)
            try await Task.sleep(for: DirectoryWatcher.watchPeriod)

            let file2 = dirPath.appending(afterDelete)
            FileManager.default.createFile(atPath: file2.string, contents: nil)

            try await waitForPaths([beforeDelete, afterDelete], in: createdPaths)

            #expect(!createdPaths.paths.isEmpty, "directory watcher failed to detect new file")
            #expect(
                Set(createdPaths.paths.compactMap { $0.lastComponent?.string }) == Set([beforeDelete, afterDelete]))
        }

    }
}
