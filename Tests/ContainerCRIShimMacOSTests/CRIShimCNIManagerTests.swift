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

@testable import ContainerCRIShimMacOS

struct CRIShimCNIManagerTests {
    @Test
    func passesSelectedConflistPluginConfigToCNIPlugin() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let binDir = rootURL.appendingPathComponent("bin", isDirectory: true)
        let confDir = rootURL.appendingPathComponent("net.d", isDirectory: true)
        let stateDir = rootURL.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let capturedConfigURL = rootURL.appendingPathComponent("captured-config.json")
        let pluginURL = binDir.appendingPathComponent("container-cni-macvmnet")
        try fakeCNIPluginScript(captureURL: capturedConfigURL).write(to: pluginURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginURL.path)

        try """
        {
          "cniVersion": "1.1.0",
          "name": "default",
          "plugins": [
            {
              "type": "noop"
            },
            {
              "type": "macvmnet",
              "runtime": "container-runtime-macos-test",
              "stateDir": "\(stateDir.path)"
            }
          ]
        }
        """.write(to: confDir.appendingPathComponent("10-macvmnet.conflist"), atomically: true, encoding: .utf8)

        let manager = ProcessCRIShimCNIManager()
        let result = try await manager.add(
            sandboxID: "sandbox-1",
            networkName: "default",
            config: CRIShimConfig(
                cni: CNIConfig(
                    binDir: binDir.path,
                    confDir: confDir.path,
                    plugin: "macvmnet"
                )
            )
        )

        #expect(result.networkName == "default")
        #expect(result.interfaceName == "eth0")
        #expect(result.sandboxURI == "macvmnet://sandbox/sandbox-1")
        #expect(result.podIPs == ["192.168.64.10/24"])

        let capturedData = try Data(contentsOf: capturedConfigURL)
        let captured = try #require(JSONSerialization.jsonObject(with: capturedData) as? [String: Any])
        #expect(captured["cniVersion"] as? String == "1.1.0")
        #expect(captured["name"] as? String == "default")
        #expect(captured["type"] as? String == "macvmnet")
        #expect(captured["runtime"] as? String == "container-runtime-macos-test")
        #expect(captured["stateDir"] as? String == stateDir.path)
        #expect(captured["plugins"] == nil)
    }
}

private func fakeCNIPluginScript(captureURL: URL) -> String {
    """
    #!/bin/sh
    cat > \(shQuote(captureURL.path))
    cat <<'JSON'
    {
      "cniVersion": "1.1.0",
      "interfaces": [
        {
          "name": "eth0",
          "sandbox": "macvmnet://sandbox/sandbox-1"
        }
      ],
      "ips": [
        {
          "address": "192.168.64.10/24"
        }
      ]
    }
    JSON
    """
}

private func shQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CRIShimCNIManagerTests-\(UUID().uuidString)", isDirectory: true)
}
