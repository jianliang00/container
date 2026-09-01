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
        let virtualMachineIdentity = Data("network-backend-vm".utf8)
        let prepared = try await backend.prepareNetwork(
            containerConfig: config,
            existingLease: nil,
            virtualMachineIdentity: virtualMachineIdentity,
            log: Logger(label: "RuntimeMacOSSidecarTests")
        )

        #expect(backend.backendID == .virtualizationNAT)
        #expect(prepared.lease == nil)
        #expect(prepared.ownedNetworks.isEmpty)
        #expect(prepared.devices.count == 1)

        let device = try #require(prepared.devices.first as? VZVirtioNetworkDeviceConfiguration)
        #expect(device.attachment is VZNATNetworkDeviceAttachment)
        #expect(
            device.macAddress.description
                == MacOSNATNetworkIdentity.addressString(virtualMachineIdentity: virtualMachineIdentity)
        )
    }

    @Test
    func virtualizationNATBackendUsesStablePerVMNetworkIdentity() async throws {
        let config = try makeContainerConfiguration(networkBackend: "virtualizationNAT")
        let backend = MacOSNetworkBackendFactory.backend(for: config)
        let virtualMachineIdentity = Data("stable-vm".utf8)
        let otherVirtualMachineIdentity = Data("other-vm".utf8)

        let first = try await backend.prepareNetwork(
            containerConfig: config,
            existingLease: nil,
            virtualMachineIdentity: virtualMachineIdentity,
            log: Logger(label: "RuntimeMacOSSidecarTests")
        )
        let second = try await backend.prepareNetwork(
            containerConfig: config,
            existingLease: nil,
            virtualMachineIdentity: virtualMachineIdentity,
            log: Logger(label: "RuntimeMacOSSidecarTests")
        )
        let other = try await backend.prepareNetwork(
            containerConfig: config,
            existingLease: nil,
            virtualMachineIdentity: otherVirtualMachineIdentity,
            log: Logger(label: "RuntimeMacOSSidecarTests")
        )

        let firstDevice = try #require(first.devices.first as? VZVirtioNetworkDeviceConfiguration)
        let secondDevice = try #require(second.devices.first as? VZVirtioNetworkDeviceConfiguration)
        let otherDevice = try #require(other.devices.first as? VZVirtioNetworkDeviceConfiguration)
        #expect(firstDevice.macAddress.description == secondDevice.macAddress.description)
        #expect(firstDevice.macAddress.description != otherDevice.macAddress.description)
    }

    @Test
    func vmnetSharedBackendIsSelectable() throws {
        let config = try makeContainerConfiguration(networkBackend: "vmnetShared")

        let backend = MacOSNetworkBackendFactory.backend(for: config)

        #expect(backend.backendID == .vmnetShared)
    }

    @Test
    func vmnetSharedBackendRequiresPreparedLease() async throws {
        let config = try makeContainerConfiguration(networkBackend: "vmnetShared")
        let backend = MacOSNetworkBackendFactory.backend(for: config)

        await #expect(throws: Error.self) {
            _ = try await backend.prepareNetwork(
                containerConfig: config,
                existingLease: nil,
                virtualMachineIdentity: Data("vmnet-vm".utf8),
                log: Logger(label: "RuntimeMacOSSidecarTests")
            )
        }
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
