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

import Containerization
import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerResource

struct SandboxConfigurationTests {
    @Test
    func convertsContainerConfigurationToSandboxConfiguration() throws {
        var container = try makeContainerConfiguration()
        let network = AttachmentConfiguration(
            network: "sandbox-net",
            options: .init(hostname: "sandbox-host", macAddress: try MACAddress("02:42:ac:11:00:02"))
        )
        container.mounts = [.virtiofs(source: "/tmp/shared", destination: "/shared", options: [])]
        container.readOnlyFiles = [.init(source: "/tmp/config.json", destination: "/etc/config.json", mode: 0o444)]
        container.publishedPorts = [
            .init(
                hostAddress: try IPAddress("127.0.0.1"),
                hostPort: 8080,
                containerPort: 80,
                proto: .tcp,
                count: 1
            )
        ]
        container.labels = ["role": "sandbox"]
        container.networks = [network]
        container.dns = .init(nameservers: ["1.1.1.1"], domain: "example.test", searchDomains: ["svc.local"])
        container.rosetta = true
        container.virtualization = true
        container.ssh = true
        container.readOnly = true
        container.macosGuest = .init(
            snapshotEnabled: true,
            guiEnabled: false,
            agentPort: 27000,
            networkBackend: .vmnetShared
        )

        let sandbox = SandboxConfiguration(containerConfiguration: container)

        #expect(sandbox.id == container.id)
        #expect(sandbox.image.reference == container.image.reference)
        #expect(sandbox.mounts.count == 1)
        #expect(sandbox.mounts[0].source == "/tmp/shared")
        #expect(sandbox.mounts[0].destination == "/shared")
        #expect(sandbox.readOnlyFiles == [.init(source: "/tmp/config.json", destination: "/etc/config.json", mode: 0o444)])
        #expect(sandbox.publishedPorts.count == 1)
        #expect(sandbox.publishedPorts[0].hostPort == 8080)
        #expect(sandbox.publishedPorts[0].containerPort == 80)
        #expect(sandbox.labels == container.labels)
        #expect(sandbox.networks.count == 1)
        #expect(sandbox.networks[0].network == "sandbox-net")
        #expect(sandbox.networks[0].options.hostname == "sandbox-host")
        #expect(sandbox.dns?.domain == "example.test")
        #expect(sandbox.rosetta)
        #expect(sandbox.virtualization)
        #expect(sandbox.ssh)
        #expect(sandbox.readOnly)
        #expect(sandbox.macosGuest?.networkBackend == .vmnetShared)
    }

    @Test
    func macOSSandboxLayoutBuildsExpectedPathsAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = MacOSSandboxLayout(root: root)
        try layout.prepareBaseDirectories()

        #expect(layout.sandboxConfigurationURL == root.appendingPathComponent("sandbox.json"))
        #expect(layout.readonlyInjectionManifestURL == root.appendingPathComponent("readonly/manifest.json"))
        #expect(layout.workloadConfigurationURL(id: "exec-1") == root.appendingPathComponent("workloads/exec-1/config.json"))
        #expect(layout.workloadStdoutLogURL(id: "exec-1") == root.appendingPathComponent("workloads/exec-1/stdout.log"))
        #expect(FileManager.default.fileExists(atPath: layout.temporaryDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.readonlyInjectionDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.workloadsDirectoryURL.path))
    }

    private func makeContainerConfiguration() throws -> ContainerConfiguration {
        let imageJSON = """
            {
              "reference": "example/macos:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:test",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "echo hello"],
            environment: ["FOO=bar"],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        var configuration = ContainerConfiguration(id: "sandbox-1", image: image, process: process)
        configuration.platform = .init(arch: "arm64", os: "darwin")
        configuration.runtimeHandler = "container-runtime-macos"
        return configuration
    }
}
