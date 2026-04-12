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
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import Testing

@testable import container_runtime_macos

private typealias NetworkAttachment = ContainerResource.Attachment
private typealias NetworkDNSConfiguration = ContainerResource.Attachment.DNSConfiguration

@Suite(.serialized)
struct MacOSSandboxServiceNetworkTests {
    @Test
    func prepareInspectReleaseLifecyclePersistsLeaseAndRecoversAcrossServiceRestart() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let config = try makeConfiguration()

        let prepared = try await service.prepareSandboxNetworkState(containerConfig: config)
        let attachment = try #require(prepared.attachments.first)
        #expect(prepared.attachments.count == 1)
        #expect(attachment.network == "default")
        #expect(attachment.hostname == "sandbox-host")
        #expect(attachment.ipv4Address.address.description == "192.168.64.2")
        #expect(attachment.ipv4Gateway.description == "192.168.64.1")
        #expect(attachment.dns?.nameservers == ["9.9.9.9"])
        #expect(attachment.dns?.domain == "example.internal")
        #expect(attachment.dns?.searchDomains == ["svc.example.internal"])
        #expect(attachment.dns?.options.isEmpty == true)

        let maybeLease = try MacOSGuestNetworkLeaseStore.load(from: root)
        let lease = try #require(maybeLease)
        #expect(lease.attachments == prepared.attachments)
        #expect(await recorder.allocateCalls() == [RecordingSandboxNetworkControl.Key(network: "default", hostname: "sandbox-host")])
        #expect(await recorder.lookupCalls().isEmpty)

        let recoveredService = makeService(root: root, recorder: recorder)
        let recovered = await recoveredService.inspectSandboxNetworkState(containerConfig: config)
        #expect(recovered == prepared)
        #expect(await recorder.lookupCalls().isEmpty)

        try await recoveredService.releaseSandboxNetworkState(containerConfig: config)
        #expect(try MacOSGuestNetworkLeaseStore.load(from: root) == nil)
        #expect(await recorder.deallocateCalls() == [RecordingSandboxNetworkControl.Key(network: "default", hostname: "sandbox-host")])

        let afterRelease = await recoveredService.inspectSandboxNetworkState(containerConfig: config)
        #expect(afterRelease.attachments.isEmpty)
        #expect(await recorder.lookupCalls() == [RecordingSandboxNetworkControl.Key(network: "default", hostname: "sandbox-host")])
    }

    @Test
    func prepareReusesPersistedLeaseWithoutAllocatingAgain() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-reuse")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let config = try makeConfiguration()
        let persistedAttachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-host",
            address: "192.168.64.42",
            gateway: "192.168.64.1",
            dns: NetworkDNSConfiguration(
                nameservers: ["9.9.9.9"],
                domain: "example.internal",
                searchDomains: ["svc.example.internal"],
                options: []
            )
        )
        try MacOSGuestNetworkLeaseStore.save(
            MacOSGuestNetworkLease(
                interfaces: [
                    .init(backend: .vmnetShared, attachment: persistedAttachment)
                ]
            ),
            in: root
        )

        let prepared = try await service.prepareSandboxNetworkState(containerConfig: config)

        #expect(prepared.attachments == [persistedAttachment])
        #expect(await recorder.allocateCalls().isEmpty)
        #expect(await recorder.lookupCalls().isEmpty)
        #expect(await recorder.deallocateCalls().isEmpty)
    }

    @Test
    func inspectFallsBackToLiveLookupWhenLeaseIsAbsent() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-lookup")
        defer { try? FileManager.default.removeItem(at: root) }

        let liveAttachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-host",
            address: "192.168.64.7",
            gateway: "192.168.64.1"
        )
        let recorder = RecordingSandboxNetworkControl(
            seededAttachments: [
                RecordingSandboxNetworkControl.Key(network: "default", hostname: "sandbox-host"): liveAttachment
            ]
        )
        let service = makeService(root: root, recorder: recorder)
        let config = try makeConfiguration()

        let inspected = await service.inspectSandboxNetworkState(containerConfig: config)
        let attachment = try #require(inspected.attachments.first)

        #expect(inspected.attachments.count == 1)
        #expect(attachment.network == "default")
        #expect(attachment.hostname == "sandbox-host")
        #expect(attachment.ipv4Address.address.description == "192.168.64.7")
        #expect(attachment.dns?.nameservers == ["9.9.9.9"])
        #expect(attachment.dns?.options.isEmpty == true)
        #expect(await recorder.lookupCalls() == [RecordingSandboxNetworkControl.Key(network: "default", hostname: "sandbox-host")])
    }

    @Test
    func virtualizationNATClearsPersistedLeaseState() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-nat")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let attachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-host",
            address: "192.168.64.10",
            gateway: "192.168.64.1"
        )
        try MacOSGuestNetworkLeaseStore.save(
            MacOSGuestNetworkLease(
                interfaces: [
                    .init(backend: .vmnetShared, attachment: attachment)
                ]
            ),
            in: root
        )

        let config = try makeConfiguration(backend: .virtualizationNAT)
        let prepared = try await service.prepareSandboxNetworkState(containerConfig: config)
        let inspected = await service.inspectSandboxNetworkState(containerConfig: config)
        try await service.releaseSandboxNetworkState(containerConfig: config)

        #expect(prepared.attachments.isEmpty)
        #expect(inspected.attachments.isEmpty)
        #expect(try MacOSGuestNetworkLeaseStore.load(from: root) == nil)
        #expect(await recorder.allocateCalls().isEmpty)
        #expect(await recorder.lookupCalls().isEmpty)
        #expect(await recorder.deallocateCalls().isEmpty)
    }

    @Test
    func applySandboxPolicyPersistsPolicyState() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-policy")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let config = try makeConfiguration()
        _ = try await service.prepareSandboxNetworkState(containerConfig: config)

        let policy = try makePolicy(sandboxID: config.id, generation: 1)
        let state = try await service.testingApplySandboxPolicyState(policy, containerConfig: config)

        #expect(state.sandboxID == config.id)
        #expect(state.networkID == "default")
        #expect(state.ipv4Address.description == "192.168.64.2")
        #expect(state.macAddress?.description == "02:42:ac:11:00:02")
        #expect(state.generation == 1)
        #expect(state.policy == policy)
        #expect(state.renderedHostRuleIdentifiers.isEmpty)
        #expect(state.lastApplyResult == .stored)
        #expect(try MacOSGuestNetworkPolicyStore.load(from: root) == state)
    }

    @Test
    func applySandboxPolicyRejectsStaleGeneration() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-policy-stale")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let config = try makeConfiguration()
        _ = try await service.prepareSandboxNetworkState(containerConfig: config)

        _ = try await service.testingApplySandboxPolicyState(
            try makePolicy(sandboxID: config.id, generation: 2),
            containerConfig: config
        )

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.testingApplySandboxPolicyState(
                try makePolicy(sandboxID: config.id, generation: 1),
                containerConfig: config
            )
        }
    }

    @Test
    func applySandboxPolicyRejectsVirtualizationNAT() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-policy-nat")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let config = try makeConfiguration(backend: .virtualizationNAT)

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.testingApplySandboxPolicyState(
                try makePolicy(sandboxID: config.id, generation: 1),
                containerConfig: config
            )
        }
    }

    @Test
    func releaseSandboxNetworkRemovesPolicyState() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-policy-release")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let config = try makeConfiguration()
        _ = try await service.prepareSandboxNetworkState(containerConfig: config)
        _ = try await service.testingApplySandboxPolicyState(
            try makePolicy(sandboxID: config.id, generation: 1),
            containerConfig: config
        )

        try await service.releaseSandboxNetworkState(containerConfig: config)

        #expect(try MacOSGuestNetworkPolicyStore.load(from: root) == nil)
    }

    @Test
    func publishedPortPolicyEvaluatesGuestPortAndWritesAuditEvents() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-policy-audit")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let config = try makeConfiguration()
        _ = try await service.prepareSandboxNetworkState(containerConfig: config)
        _ = try await service.testingApplySandboxPolicyState(
            try makePolicy(sandboxID: config.id, generation: 7),
            containerConfig: config
        )

        let allowed = try await service.testingEvaluatePublishedPortPolicy(
            proto: .tcp,
            sourceIP: "10.0.0.25",
            sourcePort: 50000,
            destinationIP: "192.168.64.2",
            destinationPort: 443
        )
        let denied = try await service.testingEvaluatePublishedPortPolicy(
            proto: .udp,
            sourceIP: "10.0.1.25",
            sourcePort: 50001,
            destinationIP: "192.168.64.2",
            destinationPort: 443
        )

        #expect(allowed == .allow)
        #expect(denied == .deny)

        let logURL = MacOSSandboxLayout(root: root).networkAuditLogURL
        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.count == 2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let firstEvent = try decoder.decode(SandboxNetworkAuditEvent.self, from: Data(lines[0].utf8))
        let secondEvent = try decoder.decode(SandboxNetworkAuditEvent.self, from: Data(lines[1].utf8))

        #expect(firstEvent.sandboxID == config.id)
        #expect(firstEvent.networkID == "default")
        #expect(firstEvent.policyGeneration == 7)
        #expect(firstEvent.direction == .ingress)
        #expect(firstEvent.proto == .tcp)
        #expect(firstEvent.sourceIP.description == "10.0.0.25")
        #expect(firstEvent.sourcePort == 50000)
        #expect(firstEvent.destinationIP.description == "192.168.64.2")
        #expect(firstEvent.destinationPort == 443)
        #expect(firstEvent.action == .allow)
        #expect(firstEvent.ruleID == "ingress-web")
        #expect(firstEvent.enforcementSource == .publishedPort)

        #expect(secondEvent.proto == .udp)
        #expect(secondEvent.action == .deny)
        #expect(secondEvent.ruleID == nil)
    }

    @Test
    func sandboxStateSnapshotIncludesAppliedPolicyGeneration() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-network-policy-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let config = try makeConfiguration()
        try await service.testingPrepareSandbox(config)
        _ = try await service.prepareSandboxNetworkState(containerConfig: config)
        _ = try await service.testingApplySandboxPolicyState(
            try makePolicy(sandboxID: config.id, generation: 3),
            containerConfig: config
        )

        let snapshot = try await service.testingStateSnapshot()

        #expect(snapshot.networkPolicy?.sandboxID == config.id)
        #expect(snapshot.networkPolicy?.generation == 3)
    }

    @Test
    func socketForwarderLifecycleCreatesAndReleasesEventLoopGroup() async throws {
        let root = try makeTemporaryDirectory(prefix: "macos-sandbox-forwarder-lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingSandboxNetworkControl()
        let service = makeService(root: root, recorder: recorder)
        let attachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-host",
            address: "192.168.64.2",
            gateway: "192.168.64.1"
        )
        let publishedPort = PublishPort(
            hostAddress: try IPAddress("127.0.0.1"),
            hostPort: 0,
            containerPort: 8080,
            proto: .tcp,
            count: 1
        )

        #expect(await service.testingHasSocketForwarderEventLoopGroup() == false)

        try await service.testingStartSocketForwarders(
            attachments: [attachment],
            publishedPorts: [publishedPort]
        )

        #expect(await service.testingHasSocketForwarderEventLoopGroup() == true)

        await service.testingStopSocketForwarders()

        #expect(await service.testingHasSocketForwarderEventLoopGroup() == false)
    }
}

private actor RecordingSandboxNetworkControl {
    struct Key: Hashable, Sendable {
        let network: String
        let hostname: String
    }

    private var seededAttachments: [Key: NetworkAttachment]
    private var nextAddressOctet: UInt8
    private var allocateHistory: [Key] = []
    private var lookupHistory: [Key] = []
    private var deallocateHistory: [Key] = []

    init(
        seededAttachments: [Key: NetworkAttachment] = [:],
        nextAddressOctet: UInt8 = 2
    ) {
        self.seededAttachments = seededAttachments
        self.nextAddressOctet = nextAddressOctet
    }

    func allocate(network: String, hostname: String, macAddress: MACAddress?) async throws -> NetworkAttachment {
        let key = Key(network: network, hostname: hostname)
        allocateHistory.append(key)
        if let existing = seededAttachments[key] {
            return existing
        }

        let suffix = nextAddressOctet
        nextAddressOctet += 1
        let attachment = try makeAttachment(
            network: network,
            hostname: hostname,
            address: "192.168.64.\(suffix)",
            gateway: "192.168.64.1",
            macAddress: macAddress
        )
        seededAttachments[key] = attachment
        return attachment
    }

    func lookup(network: String, hostname: String) async -> NetworkAttachment? {
        let key = Key(network: network, hostname: hostname)
        lookupHistory.append(key)
        return seededAttachments[key]
    }

    func deallocate(network: String, hostname: String) async {
        let key = Key(network: network, hostname: hostname)
        deallocateHistory.append(key)
        seededAttachments.removeValue(forKey: key)
    }

    func allocateCalls() -> [Key] {
        allocateHistory
    }

    func lookupCalls() -> [Key] {
        lookupHistory
    }

    func deallocateCalls() -> [Key] {
        deallocateHistory
    }
}

private func makeService(root: URL, recorder: RecordingSandboxNetworkControl) -> MacOSSandboxService {
    MacOSSandboxService(
        root: root,
        connection: nil,
        log: Logger(label: "MacOSSandboxServiceNetworkTests"),
        networkControl: .init(
            allocate: { network, hostname, macAddress in
                try await recorder.allocate(
                    network: network,
                    hostname: hostname,
                    macAddress: macAddress
                )
            },
            lookup: { network, hostname in
                await recorder.lookup(network: network, hostname: hostname)
            },
            deallocate: { network, hostname in
                await recorder.deallocate(network: network, hostname: hostname)
            }
        )
    )
}

private func makeConfiguration(
    backend: ContainerConfiguration.MacOSGuestOptions.NetworkBackend = .vmnetShared
) throws -> ContainerConfiguration {
    let image = ImageDescription(
        reference: "example/macos:latest",
        descriptor: .init(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:test",
            size: 1
        )
    )
    let process = ProcessConfiguration(
        executable: "/usr/bin/true",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )

    var config = ContainerConfiguration(
        id: "sandbox-network-test",
        image: image,
        process: process
    )
    config.platform = .init(arch: "arm64", os: "darwin")
    config.runtimeHandler = "container-runtime-macos"
    config.networks = [
        .init(
            network: "default",
            options: .init(
                hostname: "sandbox-host",
                macAddress: try MACAddress("02:42:ac:11:00:02")
            )
        )
    ]
    config.dns = .init(
        nameservers: ["9.9.9.9"],
        domain: "example.internal",
        searchDomains: ["svc.example.internal"],
        options: ["ndots:5"]
    )
    config.macosGuest = .init(
        snapshotEnabled: false,
        guiEnabled: false,
        agentPort: 27000,
        networkBackend: backend
    )
    return config
}

private func makeAttachment(
    network: String,
    hostname: String,
    address: String,
    gateway: String,
    macAddress: MACAddress? = nil,
    dns: NetworkDNSConfiguration? = nil
) throws -> NetworkAttachment {
    let resolvedMACAddress: MACAddress
    if let macAddress {
        resolvedMACAddress = macAddress
    } else {
        resolvedMACAddress = try MACAddress("02:42:ac:11:00:02")
    }

    return NetworkAttachment(
        network: network,
        hostname: hostname,
        ipv4Address: try CIDRv4(
            IPv4Address(address),
            prefix: Prefix(length: 24)!
        ),
        ipv4Gateway: try IPv4Address(gateway),
        ipv6Address: nil,
        macAddress: resolvedMACAddress,
        dns: dns
    )
}

private func makePolicy(sandboxID: String, generation: UInt64) throws -> SandboxNetworkPolicy {
    SandboxNetworkPolicy(
        sandboxID: sandboxID,
        generation: generation,
        ingressACL: [
            SandboxNetworkPolicyRule(
                id: "ingress-web",
                action: .allow,
                protocols: [.tcp],
                endpoints: [
                    .ipv4CIDR(try CIDRv4("10.0.0.0/24"))
                ],
                ports: [
                    .single(443)
                ]
            )
        ],
        egressACL: [
            SandboxNetworkPolicyRule(
                id: "egress-dns",
                action: .allow,
                protocols: [.udp],
                endpoints: [
                    .ipv4Host(try IPAddress("9.9.9.9"))
                ],
                ports: [
                    .single(53)
                ]
            )
        ],
        defaultAction: .deny,
        auditMode: .all
    )
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
#endif
