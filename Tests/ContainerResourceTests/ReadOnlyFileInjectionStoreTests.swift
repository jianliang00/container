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

@testable import ContainerResource

struct ReadOnlyFileInjectionStoreTests {
    @Test
    func stageCopiesFilesIntoSandboxReadonlyLayoutAndLoadsPreparedEntries() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceRoot = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let configURL = sourceRoot.appendingPathComponent("config.json")
        let scriptURL = sourceRoot.appendingPathComponent("boot.sh")
        try Data("{\"name\":\"demo\"}\n".utf8).write(to: configURL)
        try Data("#!/bin/sh\necho boot\n".utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptURL.path)

        let layout = MacOSSandboxLayout(root: root.appendingPathComponent("bundle"))
        try MacOSReadOnlyFileInjectionStore.stage(
            [
                .init(source: configURL.path, destination: "/etc/demo/config.json"),
                .init(source: scriptURL.path, destination: "/usr/local/bin/boot.sh"),
            ],
            in: layout
        )

        let entries = try MacOSReadOnlyFileInjectionStore.load(from: layout)

        #expect(entries.count == 2)
        #expect(entries[0].destination == "/etc/demo/config.json")
        #expect(entries[0].mode == 0o444)
        #expect(entries[1].destination == "/usr/local/bin/boot.sh")
        #expect(entries[1].mode == 0o555)
        #expect(FileManager.default.fileExists(atPath: entries[0].sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: entries[1].sourceURL.path))
        #expect(try Data(contentsOf: entries[0].sourceURL) == Data(contentsOf: configURL))
        #expect(try Data(contentsOf: entries[1].sourceURL) == Data(contentsOf: scriptURL))
    }

    @Test
    func stageRejectsNonAbsoluteGuestDestinations() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("payload.txt")
        try Data("payload\n".utf8).write(to: sourceURL)

        let layout = MacOSSandboxLayout(root: root.appendingPathComponent("bundle"))

        #expect(throws: MacOSReadOnlyFileInjectionStore.Error.destinationNotAbsolute("relative/path")) {
            try MacOSReadOnlyFileInjectionStore.stage(
                [.init(source: sourceURL.path, destination: "relative/path")],
                in: layout
            )
        }
    }

    @Test
    func stageRejectsMissingRegularFiles() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = MacOSSandboxLayout(root: root.appendingPathComponent("bundle"))
        let missingPath = root.appendingPathComponent("missing.txt").path

        #expect(throws: MacOSReadOnlyFileInjectionStore.Error.sourceNotRegularFile(missingPath)) {
            try MacOSReadOnlyFileInjectionStore.stage(
                [.init(source: missingPath, destination: "/etc/demo.txt")],
                in: layout
            )
        }
    }
}

private func makeTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ReadOnlyFileInjectionStoreTests-\(UUID().uuidString)")
}
