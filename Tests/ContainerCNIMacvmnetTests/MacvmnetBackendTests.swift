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

import ContainerResource
import ContainerSandboxServiceClient
import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerCNIMacvmnet

private typealias NetworkAttachment = ContainerResource.Attachment

struct MacvmnetBackendTests {
    @Test func liveBackendPreparesAttachmentIntoCNIResult() async throws {
        let attachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-1",
            ipv4Address: "192.168.64.2/24",
            ipv4Gateway: "192.168.64.1",
            macAddress: "02:42:ac:11:00:02",
            dnsNameservers: ["192.168.64.1"]
        )
        let healthClient = FakeMacvmnetNetworkHealthClient(stateResult: try makeNetworkState(id: "default"))
        let sandboxClient = FakeMacvmnetSandboxNetworkClient(
            state: SandboxNetworkState(attachments: [attachment])
        )
        let sandboxFactory = FakeMacvmnetSandboxNetworkClientFactory(clientsBySandboxID: [
            "sandbox-1": sandboxClient
        ])
        let ledger = FakeMacvmnetAttachmentLedger()
        let backend = MacvmnetLiveBackend(
            makeNetworkClient: { _ in healthClient },
            makeSandboxClient: sandboxFactory.make,
            makeAttachmentLedger: { _ in ledger }
        )
        let plan = try makePlan(command: .add, sandbox: "macvmnet://sandbox/sandbox-1")

        let result = try await backend.prepare(plan)

        #expect(result == CNIResult(attachment: attachment, interfaceName: "eth0", sandbox: plan.sandbox))
        #expect(sandboxFactory.requests == [.init(sandboxID: "sandbox-1", runtimeName: CNISpec.defaultRuntimeName)])
        #expect(sandboxClient.prepareRequests == 1)
        #expect(
            ledger.recordsByNetwork["default"] == [
                MacvmnetAttachmentRecord(
                    identity: .init(containerID: "sandbox-1", ifName: "eth0"),
                    networkName: "default",
                    result: result
                )
            ])
    }

    @Test func liveBackendChecksExistingAttachmentAgainstPreviousResult() async throws {
        let attachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-1",
            ipv4Address: "192.168.64.2/24",
            ipv4Gateway: "192.168.64.1",
            macAddress: "02:42:ac:11:00:02"
        )
        let healthClient = FakeMacvmnetNetworkHealthClient(stateResult: try makeNetworkState(id: "default"))
        let sandboxClient = FakeMacvmnetSandboxNetworkClient(
            state: SandboxNetworkState(attachments: [attachment])
        )
        let sandboxFactory = FakeMacvmnetSandboxNetworkClientFactory(clientsBySandboxID: [
            "sandbox-1": sandboxClient
        ])
        let ledger = FakeMacvmnetAttachmentLedger()
        let backend = MacvmnetLiveBackend(
            makeNetworkClient: { _ in healthClient },
            makeSandboxClient: sandboxFactory.make,
            makeAttachmentLedger: { _ in ledger }
        )
        let expected = CNIResult(attachment: attachment, interfaceName: "eth0", sandbox: try CNISandboxURI("macvmnet://sandbox/sandbox-1"))
        let plan = try makePlan(command: .check, sandbox: "macvmnet://sandbox/sandbox-1", prevResult: expected)

        try await backend.inspect(plan)

        #expect(sandboxFactory.requests == [.init(sandboxID: "sandbox-1", runtimeName: CNISpec.defaultRuntimeName)])
        #expect(sandboxClient.inspectRequests == 1)
    }

    @Test func liveBackendReleasesSandboxNetworkAndLedger() async throws {
        let attachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-1",
            ipv4Address: "192.168.64.2/24",
            ipv4Gateway: "192.168.64.1"
        )
        let healthClient = FakeMacvmnetNetworkHealthClient(stateResult: try makeNetworkState(id: "default"))
        let sandboxClient = FakeMacvmnetSandboxNetworkClient(
            state: SandboxNetworkState(attachments: [attachment])
        )
        let sandboxFactory = FakeMacvmnetSandboxNetworkClientFactory(clientsBySandboxID: [
            "sandbox-1": sandboxClient
        ])
        let ledger = FakeMacvmnetAttachmentLedger(
            recordsByNetwork: [
                "default": [
                    MacvmnetAttachmentRecord(
                        identity: .init(containerID: "sandbox-1", ifName: "eth0"),
                        networkName: "default",
                        result: CNIResult(attachment: attachment, interfaceName: "eth0", sandbox: nil)
                    )
                ]
            ])
        let backend = MacvmnetLiveBackend(
            makeNetworkClient: { _ in healthClient },
            makeSandboxClient: sandboxFactory.make,
            makeAttachmentLedger: { _ in ledger }
        )
        let plan = try makePlan(command: .delete, sandbox: nil)

        try await backend.release(plan)

        #expect(sandboxFactory.requests == [.init(sandboxID: "sandbox-1", runtimeName: CNISpec.defaultRuntimeName)])
        #expect(sandboxClient.releaseRequests == 1)
        #expect(ledger.recordsByNetwork["default"]?.isEmpty == true)
    }

    @Test func liveBackendStatusChecksNetworkState() async throws {
        let client = FakeMacvmnetNetworkHealthClient(stateResult: try makeNetworkState(id: "default"))
        let backend = MacvmnetLiveBackend { _ in client }
        let plan = try makePlan(command: .status, sandbox: nil)

        try await backend.health(networkName: plan.networkName)

        #expect(client.stateRequests == 1)
    }

    @Test func liveBackendGarbageCollectsStaleLedgerAttachments() async throws {
        let staleIdentity = MacvmnetAttachmentIdentity(containerID: "sandbox-stale", ifName: "eth0")
        let liveIdentity = MacvmnetAttachmentIdentity(containerID: "sandbox-live", ifName: "eth0")
        let staleAttachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-stale",
            ipv4Address: "192.168.64.21/24",
            ipv4Gateway: "192.168.64.1"
        )
        let liveAttachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-live",
            ipv4Address: "192.168.64.22/24",
            ipv4Gateway: "192.168.64.1"
        )
        let healthClient = FakeMacvmnetNetworkHealthClient(stateResult: try makeNetworkState(id: "default"))
        let staleSandboxClient = FakeMacvmnetSandboxNetworkClient(
            state: SandboxNetworkState(attachments: [staleAttachment])
        )
        let liveSandboxClient = FakeMacvmnetSandboxNetworkClient(
            state: SandboxNetworkState(attachments: [liveAttachment])
        )
        let sandboxFactory = FakeMacvmnetSandboxNetworkClientFactory(clientsBySandboxID: [
            "sandbox-stale": staleSandboxClient,
            "sandbox-live": liveSandboxClient,
        ])
        let ledger = FakeMacvmnetAttachmentLedger(
            recordsByNetwork: [
                "default": [
                    MacvmnetAttachmentRecord(
                        identity: staleIdentity,
                        networkName: "default",
                        result: CNIResult(attachment: staleAttachment, interfaceName: staleIdentity.ifName, sandbox: nil)
                    ),
                    MacvmnetAttachmentRecord(
                        identity: liveIdentity,
                        networkName: "default",
                        result: CNIResult(attachment: liveAttachment, interfaceName: liveIdentity.ifName, sandbox: nil)
                    ),
                ]
            ])
        let backend = MacvmnetLiveBackend(
            makeNetworkClient: { _ in healthClient },
            makeSandboxClient: sandboxFactory.make,
            makeAttachmentLedger: { _ in ledger }
        )
        let plan = MacvmnetOperationPlan(request: try makeGCRequest(validAttachments: [liveIdentity]))

        try await backend.garbageCollect(plan)

        #expect(sandboxFactory.requests == [.init(sandboxID: "sandbox-stale", runtimeName: CNISpec.defaultRuntimeName)])
        #expect(staleSandboxClient.releaseRequests == 1)
        #expect(liveSandboxClient.releaseRequests == 0)
        #expect(ledger.recordsByNetwork["default"]?.map(\.identity) == [liveIdentity])
    }

    @Test func handlerDispatchesCommandsAndRequiresPrevResultForCheck() async throws {
        let backend = FakeMacvmnetSandboxBackend(
            initialAttachments: [
                MacvmnetAttachmentIdentity(containerID: "sandbox-1", ifName: "eth0"): try makeAttachment(
                    network: "default",
                    hostname: "sandbox-1",
                    ipv4Address: "192.168.64.2/24",
                    ipv4Gateway: "192.168.64.1"
                )
            ]
        )
        let handler = MacvmnetOperationHandler(backend: backend)

        let addRequest = try makeRequest(command: .add, sandbox: "macvmnet://sandbox/sandbox-1")
        let addResult = try await handler.handle(addRequest)
        let storedAttachment = try #require(backend.attachment(for: .init(containerID: "sandbox-1", ifName: "eth0")))
        #expect(addResult == CNIResult(attachment: storedAttachment, interfaceName: "eth0", sandbox: addRequest.sandbox))

        let statusRequest = try makeRequest(command: .status, sandbox: nil)
        let statusResult = try await handler.handle(statusRequest)
        #expect(statusResult == nil)
        #expect(backend.statusChecks == ["default"])

        let checkWithoutPrevResult = try makeRequest(command: .check, sandbox: "macvmnet://sandbox/sandbox-1")
        do {
            _ = try await handler.handle(checkWithoutPrevResult)
            Issue.record("expected CHECK without prevResult to fail")
        } catch {
            #expect(error as? CNIError == .invalidConfiguration("CHECK requires prevResult"))
        }

        let mismatchedResult = CNIResult(
            interfaces: [
                CNIInterface(
                    name: "eth0",
                    mac: "02:42:ac:11:00:02",
                    sandbox: "macvmnet://sandbox/sandbox-1"
                )
            ],
            ips: [
                CNIIPConfig(interface: 0, address: "192.168.64.99/24", gateway: "192.168.64.1")
            ],
            routes: [
                CNIRoute(dst: "0.0.0.0/0", gw: "192.168.64.1")
            ]
        )
        let checkWithMismatchedPrevResult = try makeRequest(
            command: .check,
            sandbox: "macvmnet://sandbox/sandbox-1",
            prevResult: mismatchedResult
        )
        do {
            _ = try await handler.handle(checkWithMismatchedPrevResult)
            Issue.record("expected CHECK with mismatched prevResult to fail")
        } catch {
            #expect(error as? CNIError == .backendUnavailable("sandbox attachment state does not match prevResult"))
        }

        let deleteRequest = try makeRequest(command: .delete, sandbox: nil)
        _ = try await handler.handle(deleteRequest)
        #expect(backend.releasedIdentities == [.init(containerID: "sandbox-1", ifName: "eth0")])
    }

    @Test func fakeBackendKeepsValidGCAttachmentsAndDropsStaleState() async throws {
        let staleIdentity = MacvmnetAttachmentIdentity(containerID: "sandbox-stale", ifName: "eth0")
        let liveIdentity = MacvmnetAttachmentIdentity(containerID: "sandbox-live", ifName: "eth0")
        let backend = FakeMacvmnetSandboxBackend(
            initialAttachments: [
                staleIdentity: try makeAttachment(
                    network: "default",
                    hostname: "sandbox-stale",
                    ipv4Address: "192.168.64.21/24",
                    ipv4Gateway: "192.168.64.1"
                ),
                liveIdentity: try makeAttachment(
                    network: "default",
                    hostname: "sandbox-live",
                    ipv4Address: "192.168.64.22/24",
                    ipv4Gateway: "192.168.64.1"
                ),
            ]
        )
        let handler = MacvmnetOperationHandler(backend: backend)
        let request = try makeGCRequest(validAttachments: [liveIdentity])

        try await handler.handle(request)

        #expect(backend.gcValidAttachments == [liveIdentity])
        #expect(backend.releasedIdentities == [staleIdentity])
        #expect(backend.attachment(for: staleIdentity) == nil)
        #expect(backend.attachment(for: liveIdentity) != nil)
    }

    @Test func fileAttachmentLedgerPersistsAndRemovesRecords() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileMacvmnetAttachmentLedger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let identity = MacvmnetAttachmentIdentity(containerID: "sandbox/with/slashes", ifName: "eth0")
        let attachment = try makeAttachment(
            network: "default",
            hostname: identity.containerID,
            ipv4Address: "192.168.64.42/24",
            ipv4Gateway: "192.168.64.1"
        )
        let record = MacvmnetAttachmentRecord(
            identity: identity,
            networkName: "default",
            result: CNIResult(attachment: attachment, interfaceName: identity.ifName, sandbox: nil)
        )

        try FileMacvmnetAttachmentLedger(rootURL: rootURL).upsert(record)

        let reloaded = FileMacvmnetAttachmentLedger(rootURL: rootURL)
        #expect(try reloaded.records(networkName: "default") == [record])

        try reloaded.remove(identity: identity, networkName: "default")
        #expect(try reloaded.records(networkName: "default").isEmpty)
    }
}

private final class FakeMacvmnetNetworkHealthClient: MacvmnetNetworkHealthClient, @unchecked Sendable {
    var stateResult: NetworkState
    var stateRequests = 0

    init(stateResult: NetworkState) {
        self.stateResult = stateResult
    }

    func state() async throws -> NetworkState {
        stateRequests += 1
        return stateResult
    }
}

private final class FakeMacvmnetSandboxNetworkClient: MacvmnetSandboxNetworkClient, @unchecked Sendable {
    var state: SandboxNetworkState
    var prepareRequests = 0
    var inspectRequests = 0
    var releaseRequests = 0

    init(state: SandboxNetworkState) {
        self.state = state
    }

    func prepareSandboxNetwork() async throws -> SandboxNetworkState {
        prepareRequests += 1
        return state
    }

    func inspectSandboxNetwork() async throws -> SandboxNetworkState {
        inspectRequests += 1
        return state
    }

    func releaseSandboxNetwork() async throws {
        releaseRequests += 1
        state = SandboxNetworkState(attachments: [])
    }
}

private final class FakeMacvmnetSandboxNetworkClientFactory: @unchecked Sendable {
    struct Request: Equatable {
        var sandboxID: String
        var runtimeName: String
    }

    var clientsBySandboxID: [String: FakeMacvmnetSandboxNetworkClient]
    private(set) var requests: [Request] = []

    init(clientsBySandboxID: [String: FakeMacvmnetSandboxNetworkClient]) {
        self.clientsBySandboxID = clientsBySandboxID
    }

    func make(_ sandboxID: String, _ runtimeName: String) async throws -> any MacvmnetSandboxNetworkClient {
        requests.append(Request(sandboxID: sandboxID, runtimeName: runtimeName))
        guard let client = clientsBySandboxID[sandboxID] else {
            throw CNIError.backendUnavailable("missing sandbox client for \(sandboxID)")
        }
        return client
    }
}

private final class FakeMacvmnetSandboxBackend: MacvmnetBackend, @unchecked Sendable {
    private var attachmentsByIdentity: [MacvmnetAttachmentIdentity: NetworkAttachment]
    private(set) var releasedIdentities: [MacvmnetAttachmentIdentity] = []
    private(set) var gcValidAttachments: [MacvmnetAttachmentIdentity] = []
    private(set) var statusChecks: [String] = []

    init(initialAttachments: [MacvmnetAttachmentIdentity: NetworkAttachment]) {
        self.attachmentsByIdentity = initialAttachments
    }

    func attachment(for identity: MacvmnetAttachmentIdentity) -> NetworkAttachment? {
        attachmentsByIdentity[identity]
    }

    func health(networkName: String) async throws {
        statusChecks.append(networkName)
    }

    func prepare(_ plan: MacvmnetOperationPlan) async throws -> CNIResult {
        let identity = try requireAttachmentIdentity(plan)
        guard let attachment = attachmentsByIdentity[identity] else {
            throw CNIError.backendUnavailable("missing sandbox attachment for \(identity.containerID)")
        }
        return CNIResult(attachment: attachment, interfaceName: identity.ifName, sandbox: plan.sandbox)
    }

    func inspect(_ plan: MacvmnetOperationPlan) async throws {
        let identity = try requireAttachmentIdentity(plan)
        guard let attachment = attachmentsByIdentity[identity] else {
            throw CNIError.backendUnavailable("missing sandbox attachment for \(identity.containerID)")
        }
        let current = CNIResult(attachment: attachment, interfaceName: identity.ifName, sandbox: plan.sandbox)
        guard plan.previousResult == current else {
            throw CNIError.backendUnavailable("sandbox attachment state does not match prevResult")
        }
    }

    func release(_ plan: MacvmnetOperationPlan) async throws {
        let identity = try requireAttachmentIdentity(plan)
        releasedIdentities.append(identity)
        attachmentsByIdentity[identity] = nil
    }

    func garbageCollect(_ plan: MacvmnetOperationPlan) async throws {
        gcValidAttachments = plan.validAttachments.sorted(by: { lhs, rhs in
            lhs.containerID == rhs.containerID ? lhs.ifName < rhs.ifName : lhs.containerID < rhs.containerID
        })
        let staleIdentities = Set(attachmentsByIdentity.keys).subtracting(plan.validAttachments)
        attachmentsByIdentity = attachmentsByIdentity.filter { plan.validAttachments.contains($0.key) }
        releasedIdentities.append(
            contentsOf: staleIdentities.sorted(by: { lhs, rhs in
                lhs.containerID == rhs.containerID ? lhs.ifName < rhs.ifName : lhs.containerID < rhs.containerID
            }))
    }

    private func requireAttachmentIdentity(_ plan: MacvmnetOperationPlan) throws -> MacvmnetAttachmentIdentity {
        guard let identity = plan.attachmentIdentity else {
            throw CNIError.invalidConfiguration("CNI_CONTAINERID and CNI_IFNAME are required")
        }
        return identity
    }
}

private final class FakeMacvmnetAttachmentLedger: MacvmnetAttachmentLedger, @unchecked Sendable {
    var recordsByNetwork: [String: [MacvmnetAttachmentRecord]]

    init(recordsByNetwork: [String: [MacvmnetAttachmentRecord]] = [:]) {
        self.recordsByNetwork = recordsByNetwork
    }

    func upsert(_ record: MacvmnetAttachmentRecord) throws {
        var records = recordsByNetwork[record.networkName] ?? []
        records.removeAll { $0.identity == record.identity }
        records.append(record)
        recordsByNetwork[record.networkName] = records
    }

    func remove(identity: MacvmnetAttachmentIdentity, networkName: String) throws {
        recordsByNetwork[networkName]?.removeAll { $0.identity == identity }
    }

    func records(networkName: String) throws -> [MacvmnetAttachmentRecord] {
        recordsByNetwork[networkName] ?? []
    }
}

private func makePlan(
    command: CNICommand,
    sandbox: String?,
    prevResult: CNIResult? = nil
) throws -> MacvmnetOperationPlan {
    let environment = CNIEnvironment(
        command: command,
        containerID: "sandbox-1",
        netns: sandbox,
        ifName: command == .delete ? "eth0" : "eth0"
    )
    let config = CNIPluginConfig(
        cniVersion: "1.1.0",
        name: "kind",
        type: "macvmnet",
        prevResult: prevResult,
        extra: ["network": .string("default")]
    )
    let sandboxURI = try sandbox.map { value in
        try CNISandboxURI(value)
    }
    let request = CNIRequest(environment: environment, config: config, sandbox: sandboxURI)
    return MacvmnetOperationPlan(request: request)
}

private func makeRequest(
    command: CNICommand,
    sandbox: String?,
    prevResult: CNIResult? = nil
) throws -> CNIRequest {
    let environment = CNIEnvironment(
        command: command,
        containerID: command == .status ? nil : "sandbox-1",
        netns: sandbox,
        ifName: command == .status ? nil : "eth0"
    )
    let config = CNIPluginConfig(
        cniVersion: "1.1.0",
        name: "kind",
        type: "macvmnet",
        prevResult: prevResult,
        extra: ["network": .string("default")]
    )
    let sandboxURI = try sandbox.map { value in
        try CNISandboxURI(value)
    }
    return CNIRequest(environment: environment, config: config, sandbox: sandboxURI)
}

private func makeGCRequest(validAttachments: [MacvmnetAttachmentIdentity]) throws -> CNIRequest {
    let environment = CNIEnvironment(
        command: .garbageCollect,
        path: ["/opt/cni/bin"]
    )
    let config = CNIPluginConfig(
        cniVersion: "1.1.0",
        name: "kind",
        type: "macvmnet",
        extra: [
            "cni.dev/valid-attachments": .array(
                validAttachments.map { attachment in
                    .object([
                        "containerID": .string(attachment.containerID),
                        "ifname": .string(attachment.ifName),
                    ])
                })
        ]
    )
    return CNIRequest(
        environment: environment,
        config: config,
        validAttachments: Set(validAttachments)
    )
}

private func makeAttachment(
    network: String,
    hostname: String,
    ipv4Address: String,
    ipv4Gateway: String,
    macAddress: String? = nil,
    dnsNameservers: [String] = []
) throws -> NetworkAttachment {
    NetworkAttachment(
        network: network,
        hostname: hostname,
        ipv4Address: try CIDRv4(ipv4Address),
        ipv4Gateway: try IPv4Address(ipv4Gateway),
        ipv6Address: nil,
        macAddress: try macAddress.map(MACAddress.init),
        dns: dnsNameservers.isEmpty
            ? nil
            : NetworkAttachment.DNSConfiguration(
                nameservers: dnsNameservers,
                domain: nil,
                searchDomains: [],
                options: []
            )
    )
}

private func makeNetworkState(id: String) throws -> NetworkState {
    try .created(NetworkConfiguration(id: id, mode: .nat))
}
