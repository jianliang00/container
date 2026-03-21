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

#if os(macOS)
import ContainerResource
import Foundation
import Logging
import Testing
@preconcurrency import Virtualization

@testable import container_runtime_macos_sidecar

struct MacOSNetworkBackendTests {
    @Test
    func virtualizationNATBackendBuildsVirtioDevice() async throws {
        let config = try makeContainerConfiguration(networkBackend: "virtualizationNAT")

        let backend = MacOSNetworkBackendFactory.backend(for: config)
        let prepared = try await backend.prepareNetwork(
            containerConfig: config,
            existingLease: nil,
            log: Logger(label: "RuntimeMacOSSidecarTests")
        )

        #expect(backend.backendID == .virtualizationNAT)
        #expect(prepared.lease == nil)
        #expect(prepared.ownedNetworks.isEmpty)
        #expect(prepared.devices.count == 1)

        let device = try #require(prepared.devices.first as? VZVirtioNetworkDeviceConfiguration)
        #expect(device.attachment is VZNATNetworkDeviceAttachment)
    }

    @Test
    func vmnetSharedBackendIsSelectable() throws {
        let config = try makeContainerConfiguration(networkBackend: "vmnetShared")

        let backend = MacOSNetworkBackendFactory.backend(for: config)

        #expect(backend.backendID == .vmnetShared)
    }
}

private func makeContainerConfiguration(networkBackend: String) throws -> ContainerConfiguration {
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
        executable: "/usr/bin/true",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )

    var config = ContainerConfiguration(
        id: "macos-network-backend-test",
        image: image,
        process: process
    )
    config.runtimeHandler = "container-runtime-macos"
    guard let selectedBackend = ContainerConfiguration.MacOSGuestOptions.NetworkBackend(rawValue: networkBackend) else {
        throw CocoaError(.coderInvalidValue)
    }
    config.macosGuest = .init(
        snapshotEnabled: false,
        guiEnabled: false,
        agentPort: 27000,
        networkBackend: selectedBackend
    )
    return config
}
#endif
