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

@testable import ContainerCommands

struct MacOSGuestAgentInstallKitTests {
    @Test
    func writesInstallKitFromInstalledLayout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ContainerCommandsTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let cliDir = root.appendingPathComponent("bin")
        let installRoot = root

        let agentBin =
            installRoot
            .appendingPathComponent("libexec")
            .appendingPathComponent("container")
            .appendingPathComponent("macos-guest-agent")
            .appendingPathComponent("bin")
            .appendingPathComponent("container-macos-guest-agent")

        let scriptsDir =
            installRoot
            .appendingPathComponent("libexec")
            .appendingPathComponent("container")
            .appendingPathComponent("macos-guest-agent")
            .appendingPathComponent("share")

        try fm.createDirectory(at: cliDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agentBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

        let cliURL = cliDir.appendingPathComponent("container")
        #expect(fm.createFile(atPath: cliURL.path, contents: Data("x".utf8)))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        #expect(fm.createFile(atPath: agentBin.path, contents: Data("x".utf8)))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentBin.path)

        let installScript = scriptsDir.appendingPathComponent("install.sh")
        let installFromSeed = scriptsDir.appendingPathComponent("install-in-guest-from-seed.sh")
        let plist = scriptsDir.appendingPathComponent("container-macos-guest-agent.plist")

        #expect(fm.createFile(atPath: installScript.path, contents: Data("#!/bin/bash\n".utf8)))
        #expect(fm.createFile(atPath: installFromSeed.path, contents: Data("#!/bin/bash\n".utf8)))
        #expect(fm.createFile(atPath: plist.path, contents: Data("<plist/>".utf8)))

        let sources = try Application.MacOSGuestAgentInstallKit.resolveSources(cliExecutableURL: cliURL)
        #expect(sources.agentBinary.path == agentBin.path)
        #expect(sources.installScript.path == installScript.path)
        #expect(sources.installFromSeedScript.path == installFromSeed.path)
        #expect(sources.plistTemplate.path == plist.path)

        let kitDir = root.appendingPathComponent("kit")
        try Application.MacOSGuestAgentInstallKit.writeInstallKit(
            sources: sources,
            outputDirectory: kitDir,
            overwrite: false
        )

        #expect(fm.isExecutableFile(atPath: kitDir.appendingPathComponent("container-macos-guest-agent").path))
        #expect(fm.isExecutableFile(atPath: kitDir.appendingPathComponent("install.sh").path))
        #expect(fm.fileExists(atPath: kitDir.appendingPathComponent("container-macos-guest-agent.plist").path))
        #expect(fm.isExecutableFile(atPath: kitDir.appendingPathComponent("install-in-guest-from-seed.sh").path))
    }
}
