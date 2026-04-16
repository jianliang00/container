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
        let client = FakeMacvmnetNetworkClient(
            stateResult: try makeNetworkState(id: "default"),
            attachmentByHostname: ["sandbox-1": attachment]
        )
        let backend = MacvmnetLiveBackend { _ in client }
        let plan = try makePlan(command: .add, sandbox: "macvmnet://sandbox/sandbox-1")

        let result = try await backend.prepare(plan)

        #expect(result == CNIResult(attachment: attachment, interfaceName: "eth0", sandbox: plan.sandbox))
        #expect(client.lookupHostnames == ["sandbox-1"])
        #expect(client.allocatedHostnames.isEmpty)
    }

    @Test func liveBackendChecksExistingAttachmentAgainstPreviousResult() async throws {
        let attachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-1",
            ipv4Address: "192.168.64.2/24",
            ipv4Gateway: "192.168.64.1",
            macAddress: "02:42:ac:11:00:02"
        )
        let client = FakeMacvmnetNetworkClient(
            stateResult: try makeNetworkState(id: "default"),
            attachmentByHostname: ["sandbox-1": attachment]
        )
        let backend = MacvmnetLiveBackend { _ in client }
        let expected = CNIResult(attachment: attachment, interfaceName: "eth0", sandbox: try CNISandboxURI("macvmnet://sandbox/sandbox-1"))
        let plan = try makePlan(command: .check, sandbox: "macvmnet://sandbox/sandbox-1", prevResult: expected)

        try await backend.inspect(plan)

        #expect(client.lookupHostnames == ["sandbox-1"])
    }

    @Test func liveBackendReleasesOnlyWhenAttachmentExists() async throws {
        let attachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-1",
            ipv4Address: "192.168.64.2/24",
            ipv4Gateway: "192.168.64.1"
        )
        let client = FakeMacvmnetNetworkClient(
            stateResult: try makeNetworkState(id: "default"),
            attachmentByHostname: ["sandbox-1": attachment]
        )
        let backend = MacvmnetLiveBackend { _ in client }
        let plan = try makePlan(command: .delete, sandbox: nil)

        try await backend.release(plan)

        #expect(client.deallocatedHostnames == ["sandbox-1"])
    }

    @Test func liveBackendStatusChecksNetworkState() async throws {
        let client = FakeMacvmnetNetworkClient(
            stateResult: try makeNetworkState(id: "default"),
            attachmentByHostname: [:]
        )
        let backend = MacvmnetLiveBackend { _ in client }
        let plan = try makePlan(command: .status, sandbox: nil)

        try await backend.health(networkName: plan.networkName)

        #expect(client.stateRequests == 1)
    }

    @Test func handlerDispatchesCommandsAndRequiresPrevResultForCheck() async throws {
        let attachment = try makeAttachment(
            network: "default",
            hostname: "sandbox-1",
            ipv4Address: "192.168.64.2/24",
            ipv4Gateway: "192.168.64.1"
        )
        let client = FakeMacvmnetNetworkClient(
            stateResult: try makeNetworkState(id: "default"),
            attachmentByHostname: ["sandbox-1": attachment]
        )
        let handler = MacvmnetOperationHandler(backend: MacvmnetLiveBackend { _ in client })

        let addRequest = try makeRequest(command: .add, sandbox: "macvmnet://sandbox/sandbox-1")
        let addResult = try await handler.handle(addRequest)
        #expect(addResult == CNIResult(attachment: attachment, interfaceName: "eth0", sandbox: addRequest.sandbox))

        let statusRequest = try makeRequest(command: .status, sandbox: nil)
        let statusResult = try await handler.handle(statusRequest)
        #expect(statusResult == nil)

        let deleteRequest = try makeRequest(command: .delete, sandbox: nil)
        _ = try await handler.handle(deleteRequest)

        let checkWithoutPrevResult = try makeRequest(command: .check, sandbox: "macvmnet://sandbox/sandbox-1")
        do {
            _ = try await handler.handle(checkWithoutPrevResult)
            Issue.record("expected CHECK without prevResult to fail")
        } catch {
            #expect(error as? CNIError == .invalidConfiguration("CHECK requires prevResult"))
        }
    }
}

private final class FakeMacvmnetNetworkClient: MacvmnetNetworkClient, @unchecked Sendable {
    var stateResult: NetworkState
    var attachmentByHostname: [String: NetworkAttachment]
    var allocatedHostnames: [String] = []
    var lookupHostnames: [String] = []
    var deallocatedHostnames: [String] = []
    var stateRequests = 0

    init(stateResult: NetworkState, attachmentByHostname: [String: NetworkAttachment]) {
        self.stateResult = stateResult
        self.attachmentByHostname = attachmentByHostname
    }

    func state() async throws -> NetworkState {
        stateRequests += 1
        return stateResult
    }

    func allocateAttachment(hostname: String, macAddress: MACAddress?) async throws -> NetworkAttachment {
        allocatedHostnames.append(hostname)
        guard var attachment = attachmentByHostname[hostname] else {
            throw CNIError.backendUnavailable("missing attachment for \(hostname)")
        }
        if attachment.macAddress == nil, let macAddress {
            attachment = NetworkAttachment(
                network: attachment.network,
                hostname: attachment.hostname,
                ipv4Address: attachment.ipv4Address,
                ipv4Gateway: attachment.ipv4Gateway,
                ipv6Address: attachment.ipv6Address,
                macAddress: macAddress,
                dns: attachment.dns
            )
        }
        attachmentByHostname[hostname] = attachment
        return attachment
    }

    func deallocate(hostname: String) async throws {
        deallocatedHostnames.append(hostname)
        attachmentByHostname[hostname] = nil
    }

    func lookup(hostname: String) async throws -> NetworkAttachment? {
        lookupHostnames.append(hostname)
        return attachmentByHostname[hostname]
    }

    func disableAllocator() async throws -> Bool {
        false
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
