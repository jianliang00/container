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
@preconcurrency import Virtualization
import vmnet

struct PreparedMacOSNetwork {
    let devices: [VZNetworkDeviceConfiguration]
    let lease: MacOSGuestNetworkLease?
    let ownedNetworks: [ManagedVMNetNetwork]
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
        existingLease: MacOSGuestNetworkLease?,
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
        existingLease: MacOSGuestNetworkLease?,
        log: Logger
    ) async throws -> PreparedMacOSNetwork {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return PreparedMacOSNetwork(
            devices: [device],
            lease: nil,
            ownedNetworks: []
        )
    }
}

struct VMNetSharedNetworkBackend: MacOSNetworkBackend {
    let backendID: ContainerConfiguration.MacOSGuestOptions.NetworkBackend = .vmnetShared

    func prepareNetwork(
        containerConfig: ContainerConfiguration,
        existingLease: MacOSGuestNetworkLease?,
        log: Logger
    ) async throws -> PreparedMacOSNetwork {
        guard #available(macOS 26, *) else {
            throw ContainerizationError(
                .unsupported,
                message: "macOS guest network backend vmnetShared requires macOS 26 or newer"
            )
        }

        if let existingLease,
            let recovered = try await recoverPreparedNetwork(
                containerConfig: containerConfig,
                lease: existingLease,
                log: log
            )
        {
            return recovered
        }

        throw ContainerizationError(
            .invalidState,
            message: "vmnetShared requires a prepared persisted sandbox network lease before sidecar bootstrap"
        )
    }

    @available(macOS 26, *)
    private func recoverPreparedNetwork(
        containerConfig: ContainerConfiguration,
        lease: MacOSGuestNetworkLease,
        log: Logger
    ) async throws -> PreparedMacOSNetwork? {
        let requests = containerConfig.macOSGuestNetworkRequests()
        guard lease.interfaces.count == requests.count else {
            log.info(
                "skipping macOS guest network lease recovery due to interface count mismatch",
                metadata: [
                    "lease_interfaces": "\(lease.interfaces.count)",
                    "requested_interfaces": "\(requests.count)",
                ]
            )
            return nil
        }

        var leaseByKey: [LeaseKey: MacOSGuestNetworkLease.Interface] = [:]
        for leasedInterface in lease.interfaces {
            let key = LeaseKey(
                network: leasedInterface.attachment.network,
                hostname: leasedInterface.attachment.hostname
            )
            guard leaseByKey[key] == nil else {
                log.warning(
                    "skipping macOS guest network lease recovery due to duplicate interface entry",
                    metadata: [
                        "network": "\(leasedInterface.attachment.network)",
                        "hostname": "\(leasedInterface.attachment.hostname)",
                    ]
                )
                return nil
            }
            leaseByKey[key] = leasedInterface
        }

        var liveAttachments: [Attachment] = []
        var ownedNetworks: [ManagedVMNetNetwork] = []
        var preparedDevices: [VZNetworkDeviceConfiguration] = []
        var networkRefs: [String: ManagedVMNetNetwork] = [:]

        do {
            for request in requests {
                let key = LeaseKey(network: request.network, hostname: request.hostname)
                guard let leasedInterface = leaseByKey[key] else {
                    log.info(
                        "skipping macOS guest network lease recovery due to missing requested interface",
                        metadata: [
                            "network": "\(request.network)",
                            "hostname": "\(request.hostname)",
                        ]
                    )
                    return nil
                }
                guard leasedInterface.backend == backendID else {
                    log.info(
                        "skipping macOS guest network lease recovery due to backend mismatch",
                        metadata: [
                            "network": "\(request.network)",
                            "hostname": "\(request.hostname)",
                            "lease_backend": "\(leasedInterface.backend.rawValue)",
                            "expected_backend": "\(backendID.rawValue)",
                        ]
                    )
                    return nil
                }
                if let requestedMAC = request.macAddress,
                    leasedInterface.attachment.macAddress != requestedMAC
                {
                    log.info(
                        "skipping macOS guest network lease recovery due to MAC mismatch",
                        metadata: [
                            "network": "\(request.network)",
                            "hostname": "\(request.hostname)",
                            "lease_mac": "\(leasedInterface.attachment.macAddress?.description ?? "-")",
                            "requested_mac": "\(requestedMAC.description)",
                        ]
                    )
                    return nil
                }

                let client = NetworkClient(id: request.network)
                let (attachment, additionalData) = try await client.allocate(
                    hostname: leasedInterface.attachment.hostname,
                    macAddress: leasedInterface.attachment.macAddress
                )

                let managedNetwork = try resolveManagedNetwork(
                    networkID: request.network,
                    additionalData: additionalData,
                    networkRefs: &networkRefs,
                    ownedNetworks: &ownedNetworks,
                    log: log
                )

                liveAttachments.append(attachment)
                preparedDevices.append(
                    try createDeviceConfiguration(
                        attachment: attachment,
                        network: managedNetwork.reference
                    )
                )
            }

            log.info(
                "recovered macOS guest network state from persisted lease",
                metadata: ["interfaces": "\(liveAttachments.count)"]
            )
            return PreparedMacOSNetwork(
                devices: preparedDevices,
                lease: makeLease(
                    containerConfig: containerConfig,
                    attachments: liveAttachments
                ),
                ownedNetworks: ownedNetworks
            )
        } catch {
            log.warning(
                "failed to recover macOS guest network state from persisted lease",
                metadata: ["error": "\(error)"]
            )
            return nil
        }
    }

    @available(macOS 26, *)
    private func resolveManagedNetwork(
        networkID: String,
        additionalData: XPCMessage?,
        networkRefs: inout [String: ManagedVMNetNetwork],
        ownedNetworks: inout [ManagedVMNetNetwork],
        log: Logger
    ) throws -> ManagedVMNetNetwork {
        if let existing = networkRefs[networkID] {
            return existing
        }
        guard let additionalData else {
            throw ContainerizationError(
                .unsupported,
                message: "network \(networkID) does not expose a serialized vmnet network reference"
            )
        }
        let created = try createManagedNetwork(
            networkID: networkID,
            additionalData: additionalData,
            log: log
        )
        networkRefs[networkID] = created
        ownedNetworks.append(created)
        return created
    }

    private func makeLease(
        containerConfig: ContainerConfiguration,
        attachments: [Attachment]
    ) -> MacOSGuestNetworkLease {
        let projectedAttachments = containerConfig.macOSGuestReportedNetworkAttachments(attachments)
        return MacOSGuestNetworkLease(
            interfaces: projectedAttachments.map {
                .init(backend: backendID, attachment: $0)
            }
        )
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

    private struct LeaseKey: Hashable {
        let network: String
        let hostname: String
    }
}
