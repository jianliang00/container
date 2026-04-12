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
import ContainerSandboxServiceClient
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation

public struct SandboxNetworkControl: Sendable {
    let allocate: @Sendable (_ network: String, _ hostname: String, _ macAddress: MACAddress?) async throws -> Attachment
    let lookup: @Sendable (_ network: String, _ hostname: String) async throws -> Attachment?
    let deallocate: @Sendable (_ network: String, _ hostname: String) async throws -> Void

    public static let live = SandboxNetworkControl(
        allocate: { network, hostname, macAddress in
            let client = NetworkClient(id: network)
            let (attachment, _) = try await client.allocate(
                hostname: hostname,
                macAddress: macAddress
            )
            return attachment
        },
        lookup: { network, hostname in
            let client = NetworkClient(id: network)
            return try await client.lookup(hostname: hostname)
        },
        deallocate: { network, hostname in
            let client = NetworkClient(id: network)
            try await client.deallocate(hostname: hostname)
        }
    )
}

extension MacOSSandboxService {
    private struct GuestNetworkReleaseTarget {
        let network: String
        let hostname: String
    }

    @Sendable
    func prepareSandboxNetwork(_ message: XPCMessage) async throws -> XPCMessage {
        let config = try loadContainerConfigurationForNetworkControl()
        let networkState = try await prepareSandboxNetworkState(containerConfig: config)
        let reply = message.reply()
        try reply.setSandboxNetworkState(networkState)
        return reply
    }

    @Sendable
    func inspectSandboxNetwork(_ message: XPCMessage) async throws -> XPCMessage {
        let config = try loadContainerConfigurationForNetworkControl()
        let networkState = await inspectSandboxNetworkState(containerConfig: config)
        let reply = message.reply()
        try reply.setSandboxNetworkState(networkState)
        return reply
    }

    @Sendable
    func releaseSandboxNetwork(_ message: XPCMessage) async throws -> XPCMessage {
        let config = try loadContainerConfigurationForNetworkControl()
        try await releaseSandboxNetworkState(containerConfig: config)
        return message.reply()
    }

    @Sendable
    func applySandboxPolicy(_ message: XPCMessage) async throws -> XPCMessage {
        let config = try loadContainerConfigurationForNetworkControl()
        let policy = try message.sandboxNetworkPolicy()
        let policyState = try applySandboxPolicyState(policy, containerConfig: config)
        let reply = message.reply()
        try reply.setSandboxNetworkPolicyState(policyState)
        return reply
    }

    @Sendable
    func removeSandboxPolicy(_ message: XPCMessage) async throws -> XPCMessage {
        try MacOSGuestHostPacketPolicyController(root: root).remove()
        try MacOSGuestNetworkPolicyStore.remove(from: root)
        return message.reply()
    }

    @Sendable
    func inspectSandboxPolicy(_ message: XPCMessage) async throws -> XPCMessage {
        let policyState = try MacOSGuestNetworkPolicyStore.load(from: root)
        let reply = message.reply()
        try reply.setSandboxNetworkPolicyState(policyState)
        return reply
    }

    func prepareSandboxNetworkState(
        containerConfig: ContainerConfiguration
    ) async throws -> SandboxNetworkState {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        guard containerConfig.macosGuest?.networkBackend == .vmnetShared else {
            try? MacOSGuestNetworkLeaseStore.remove(from: root)
            try? MacOSGuestNetworkPolicyStore.remove(from: root)
            try? MacOSGuestHostPacketPolicyController(root: root).remove()
            return SandboxNetworkState(attachments: [])
        }

        if let lease = try MacOSGuestNetworkLeaseStore.load(from: root) {
            writeContainerLog(Data(("reused persisted guest network lease interfaces=\(lease.interfaces.count)\n").utf8))
            return SandboxNetworkState(attachments: lease.attachments)
        }

        var attachments: [Attachment] = []
        do {
            for request in containerConfig.macOSGuestNetworkRequests() {
                let attachment = try await networkControl.allocate(
                    request.network,
                    request.hostname,
                    request.macAddress
                )
                attachments.append(attachment)
            }

            let projectedAttachments = containerConfig.macOSGuestReportedNetworkAttachments(attachments)
            let lease = MacOSGuestNetworkLease(
                interfaces: projectedAttachments.map {
                    .init(backend: .vmnetShared, attachment: $0)
                }
            )
            try MacOSGuestNetworkLeaseStore.save(lease, in: root)
            writeContainerLog(Data(("prepared persisted guest network lease interfaces=\(projectedAttachments.count)\n").utf8))
            return SandboxNetworkState(attachments: projectedAttachments)
        } catch {
            for attachment in attachments {
                try? await networkControl.deallocate(
                    attachment.network,
                    attachment.hostname
                )
            }
            try? MacOSGuestNetworkLeaseStore.remove(from: root)
            throw error
        }
    }

    func inspectSandboxNetworkState(
        containerConfig: ContainerConfiguration
    ) async -> SandboxNetworkState {
        guard containerConfig.macosGuest?.networkBackend == .vmnetShared else {
            return SandboxNetworkState(attachments: [])
        }

        if let lease = try? MacOSGuestNetworkLeaseStore.load(from: root) {
            return SandboxNetworkState(attachments: lease.attachments)
        }

        var attachments: [Attachment] = []
        for request in containerConfig.macOSGuestNetworkRequests() {
            do {
                guard
                    let attachment = try await networkControl.lookup(
                        request.network,
                        request.hostname
                    )
                else {
                    continue
                }
                attachments.append(attachment)
            } catch {
                writeContainerLog(
                    Data(
                        ("failed to lookup guest network attachment network=\(request.network) hostname=\(request.hostname): \(error)\n").utf8
                    )
                )
            }
        }
        return SandboxNetworkState(attachments: containerConfig.macOSGuestReportedNetworkAttachments(attachments))
    }

    func releaseSandboxNetworkState(
        containerConfig: ContainerConfiguration
    ) async throws {
        guard containerConfig.macosGuest?.networkBackend == .vmnetShared else {
            try? MacOSGuestNetworkLeaseStore.remove(from: root)
            try? MacOSGuestNetworkPolicyStore.remove(from: root)
            try? MacOSGuestHostPacketPolicyController(root: root).remove()
            return
        }

        let lease = try MacOSGuestNetworkLeaseStore.load(from: root)
        let releaseTargets: [GuestNetworkReleaseTarget]
        if let lease {
            releaseTargets = lease.attachments.map {
                GuestNetworkReleaseTarget(network: $0.network, hostname: $0.hostname)
            }
        } else {
            releaseTargets = containerConfig.macOSGuestNetworkRequests().map {
                GuestNetworkReleaseTarget(network: $0.network, hostname: $0.hostname)
            }
        }

        var releaseFailed = false
        for target in releaseTargets {
            do {
                try await networkControl.deallocate(
                    target.network,
                    target.hostname
                )
                writeContainerLog(
                    Data(
                        ("released guest network allocation network=\(target.network) hostname=\(target.hostname)\n").utf8
                    )
                )
            } catch {
                releaseFailed = true
                writeContainerLog(
                    Data(
                        ("failed to release guest network allocation network=\(target.network) hostname=\(target.hostname): \(error)\n").utf8
                    )
                )
            }
        }

        if !releaseFailed {
            try MacOSGuestNetworkLeaseStore.remove(from: root)
            try MacOSGuestNetworkPolicyStore.remove(from: root)
            try MacOSGuestHostPacketPolicyController(root: root).remove()
            return
        }

        throw ContainerizationError(
            .internalError,
            message: "failed to release one or more guest network allocations"
        )
    }

    func releaseSandboxNetworkStateIfNeeded() async {
        let config: ContainerConfiguration
        do {
            config = try loadContainerConfigurationForNetworkControl()
        } catch {
            writeContainerLog(Data(("failed to load container configuration for guest network release: \(error)\n").utf8))
            return
        }

        do {
            try await releaseSandboxNetworkState(containerConfig: config)
        } catch {
            writeContainerLog(Data(("failed to release guest network state: \(error)\n").utf8))
        }
    }

    func testingApplySandboxPolicyState(
        _ policy: SandboxNetworkPolicy,
        containerConfig: ContainerConfiguration
    ) throws -> SandboxNetworkPolicyState {
        try applySandboxPolicyState(policy, containerConfig: containerConfig)
    }

    private func loadContainerConfigurationForNetworkControl() throws -> ContainerConfiguration {
        if let configuration {
            return configuration
        }

        let configURL = root.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
            self.configuration = config
            return config
        }

        let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: root)
        guard let config = runtimeConfig.containerConfiguration else {
            throw ContainerizationError(.invalidState, message: "runtime configuration missing container configuration")
        }
        self.configuration = config
        return config
    }

    private func applySandboxPolicyState(
        _ policy: SandboxNetworkPolicy,
        containerConfig: ContainerConfiguration
    ) throws -> SandboxNetworkPolicyState {
        guard containerConfig.macosGuest?.networkBackend == .vmnetShared else {
            throw ContainerizationError(
                .unsupported,
                message: "sandbox network policy requires the vmnetShared network backend"
            )
        }
        guard policy.sandboxID == containerConfig.id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "network policy sandbox id \(policy.sandboxID) does not match container id \(containerConfig.id)"
            )
        }
        try validate(policy)

        guard let lease = try MacOSGuestNetworkLeaseStore.load(from: root),
            let attachment = lease.attachments.first
        else {
            throw ContainerizationError(
                .invalidState,
                message: "sandbox network policy requires a prepared sandbox network lease"
            )
        }

        if let existing = try MacOSGuestNetworkPolicyStore.load(from: root),
            policy.generation < existing.generation
        {
            throw ContainerizationError(
                .invalidArgument,
                message: "network policy generation \(policy.generation) is older than current generation \(existing.generation)"
            )
        }

        let state = SandboxNetworkPolicyState(
            sandboxID: policy.sandboxID,
            networkID: attachment.network,
            ipv4Address: try IPAddress(attachment.ipv4Address.address.description),
            macAddress: attachment.macAddress,
            generation: policy.generation,
            policy: policy,
            renderedHostRuleIdentifiers: [],
            lastApplyResult: .stored
        )
        let renderedState = try MacOSGuestHostPacketPolicyController(root: root).replace(with: state)
        try MacOSGuestNetworkPolicyStore.save(renderedState, in: root)
        return renderedState
    }

    private func validate(_ policy: SandboxNetworkPolicy) throws {
        if let issue = policy.validationIssues.first {
            throw ContainerizationError(.invalidArgument, message: issue)
        }
    }
}

extension XPCMessage {
    fileprivate func sandboxNetworkPolicy() throws -> SandboxNetworkPolicy {
        guard let data = self.dataNoCopy(key: SandboxKeys.networkPolicy.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing sandbox network policy payload")
        }
        return try JSONDecoder().decode(SandboxNetworkPolicy.self, from: data)
    }

    fileprivate func setSandboxNetworkPolicyState(_ state: SandboxNetworkPolicyState?) throws {
        guard let state else {
            return
        }
        let data = try JSONEncoder().encode(state)
        self.set(key: SandboxKeys.networkPolicyState.rawValue, value: data)
    }
}
