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

import ContainerNetworkServiceClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import Foundation
import Logging
import vmnet
@preconcurrency import Virtualization

struct PreparedMacOSNetwork {
    let devices: [VZNetworkDeviceConfiguration]
    let allocations: [MacOSGuestNetworkAllocation]
    let ownedNetworks: [ManagedVMNetNetwork]
}

struct MacOSGuestNetworkAllocation: Sendable {
    let network: String
    let hostname: String
    let attachment: Attachment
}

final class ManagedVMNetNetwork: @unchecked Sendable {
    let network: String
    let reference: vmnet_network_ref

    init(network: String, reference: vmnet_network_ref) {
        self.network = network
        self.reference = reference
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(UnsafeMutableRawPointer(reference)).release()
    }
}

protocol MacOSNetworkBackend {
    var backendID: ContainerConfiguration.MacOSGuestOptions.NetworkBackend { get }

    func prepareNetwork(
        containerConfig: ContainerConfiguration,
        log: Logger
    ) async throws -> PreparedMacOSNetwork
}

enum MacOSNetworkBackendFactory {
    static func backend(for config: ContainerConfiguration) -> any MacOSNetworkBackend {
        switch config.macosGuest?.networkBackend ?? .virtualizationNAT {
        case .virtualizationNAT:
            return VirtualizationNATNetworkBackend()
        case .vmnetShared:
            return VMNetSharedNetworkBackend()
        }
    }
}

struct VirtualizationNATNetworkBackend: MacOSNetworkBackend {
    let backendID: ContainerConfiguration.MacOSGuestOptions.NetworkBackend = .virtualizationNAT

    func prepareNetwork(
        containerConfig: ContainerConfiguration,
        log: Logger
    ) async throws -> PreparedMacOSNetwork {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return PreparedMacOSNetwork(
            devices: [device],
            allocations: [],
            ownedNetworks: []
        )
    }
}

struct VMNetSharedNetworkBackend: MacOSNetworkBackend {
    let backendID: ContainerConfiguration.MacOSGuestOptions.NetworkBackend = .vmnetShared

    func prepareNetwork(
        containerConfig: ContainerConfiguration,
        log: Logger
    ) async throws -> PreparedMacOSNetwork {
        guard #available(macOS 26, *) else {
            throw ContainerizationError(
                .unsupported,
                message: "macOS guest network backend vmnetShared requires macOS 26 or newer"
            )
        }

        var allocations: [MacOSGuestNetworkAllocation] = []
        var ownedNetworks: [ManagedVMNetNetwork] = []
        var preparedDevices: [VZNetworkDeviceConfiguration] = []
        var networkRefs: [String: ManagedVMNetNetwork] = [:]

        do {
            let requests = containerConfig.macOSGuestNetworkRequests()
            for request in requests {
                let client = NetworkClient(id: request.network)
                let (attachment, additionalData) = try await client.allocate(
                    hostname: request.hostname,
                    macAddress: request.macAddress
                )

                let allocation = MacOSGuestNetworkAllocation(
                    network: request.network,
                    hostname: request.hostname,
                    attachment: attachment
                )
                allocations.append(allocation)

                let managedNetwork: ManagedVMNetNetwork
                if let existing = networkRefs[request.network] {
                    managedNetwork = existing
                } else {
                    guard let additionalData else {
                        throw ContainerizationError(
                            .unsupported,
                            message: "network \(request.network) does not expose a serialized vmnet network reference"
                        )
                    }
                    let created = try createManagedNetwork(
                        networkID: request.network,
                        additionalData: additionalData,
                        log: log
                    )
                    networkRefs[request.network] = created
                    ownedNetworks.append(created)
                    managedNetwork = created
                }

                preparedDevices.append(try createDeviceConfiguration(
                    attachment: attachment,
                    network: managedNetwork.reference
                ))
            }

            return PreparedMacOSNetwork(
                devices: preparedDevices,
                allocations: allocations,
                ownedNetworks: ownedNetworks
            )
        } catch {
            for allocation in allocations {
                let client = NetworkClient(id: allocation.network)
                try? await client.deallocate(hostname: allocation.hostname)
            }
            throw error
        }
    }

    @available(macOS 26, *)
    private func createManagedNetwork(
        networkID: String,
        additionalData: XPCMessage,
        log: Logger
    ) throws -> ManagedVMNetNetwork {
        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let networkRef = vmnet_network_create_with_serialization(additionalData.underlying, &status) else {
            throw ContainerizationError(
                .invalidState,
                message: "cannot deserialize vmnet network reference for \(networkID), status \(status)"
            )
        }
        log.info("deserialized vmnet network reference", metadata: ["network": "\(networkID)"])
        return ManagedVMNetNetwork(network: networkID, reference: networkRef)
    }

    @available(macOS 26, *)
    private func createDeviceConfiguration(
        attachment: Attachment,
        network: vmnet_network_ref
    ) throws -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZVmnetNetworkDeviceAttachment(network: network)
        if let macAddress = attachment.macAddress {
            guard let vzMACAddress = VZMACAddress(string: macAddress.description) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "invalid MAC address for vmnetShared device: \(macAddress)"
                )
            }
            device.macAddress = vzMACAddress
        }
        return device
    }
}
