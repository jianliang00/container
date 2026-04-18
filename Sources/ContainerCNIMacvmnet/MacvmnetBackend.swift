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
import Foundation

public protocol MacvmnetNetworkHealthClient: Sendable {
    func state() async throws -> NetworkState
}

extension NetworkClient: MacvmnetNetworkHealthClient {}

public protocol MacvmnetSandboxNetworkClient: Sendable {
    func prepareSandboxNetwork() async throws -> SandboxNetworkState
    func inspectSandboxNetwork() async throws -> SandboxNetworkState
    func releaseSandboxNetwork() async throws
}

extension SandboxClient: MacvmnetSandboxNetworkClient {}

public protocol MacvmnetBackend: Sendable {
    func health(networkName: String) async throws
    func prepare(_ plan: MacvmnetOperationPlan) async throws -> CNIResult
    func inspect(_ plan: MacvmnetOperationPlan) async throws
    func release(_ plan: MacvmnetOperationPlan) async throws
    func garbageCollect(_ plan: MacvmnetOperationPlan) async throws
}

public struct MacvmnetLiveBackend: MacvmnetBackend {
    public typealias NetworkHealthClientFactory = @Sendable (String) -> any MacvmnetNetworkHealthClient
    public typealias SandboxNetworkClientFactory = @Sendable (String, String) async throws -> any MacvmnetSandboxNetworkClient
    public typealias AttachmentLedgerFactory = @Sendable (MacvmnetOperationPlan) -> any MacvmnetAttachmentLedger

    private let makeNetworkClient: NetworkHealthClientFactory
    private let makeSandboxClient: SandboxNetworkClientFactory
    private let makeAttachmentLedger: AttachmentLedgerFactory

    public init(
        makeNetworkClient: @escaping NetworkHealthClientFactory = { NetworkClient(id: $0) },
        makeSandboxClient: @escaping SandboxNetworkClientFactory = { sandboxID, runtimeName in
            try await SandboxClient.create(id: sandboxID, runtime: runtimeName)
        },
        makeAttachmentLedger: @escaping AttachmentLedgerFactory = {
            FileMacvmnetAttachmentLedger(rootURL: URL(fileURLWithPath: $0.dataDirectory, isDirectory: true))
        }
    ) {
        self.makeNetworkClient = makeNetworkClient
        self.makeSandboxClient = makeSandboxClient
        self.makeAttachmentLedger = makeAttachmentLedger
    }

    public func health(networkName: String) async throws {
        _ = try await makeNetworkClient(networkName).state()
    }

    public func prepare(_ plan: MacvmnetOperationPlan) async throws -> CNIResult {
        let identity = try requireAttachmentIdentity(plan)
        let client = try await makeSandboxClient(identity.containerID, plan.runtimeName)
        let state = try await client.prepareSandboxNetwork()
        let attachment = try attachment(from: state, for: plan)
        let result = CNIResult(
            attachment: attachment,
            interfaceName: identity.ifName,
            sandbox: plan.sandbox
        )
        try makeAttachmentLedger(plan).upsert(
            MacvmnetAttachmentRecord(identity: identity, networkName: plan.networkName, result: result)
        )
        return result
    }

    public func inspect(_ plan: MacvmnetOperationPlan) async throws {
        let identity = try requireAttachmentIdentity(plan)
        guard let previousResult = plan.previousResult else {
            throw CNIError.invalidConfiguration("CHECK requires prevResult")
        }
        let client = try await makeSandboxClient(identity.containerID, plan.runtimeName)
        let state = try await client.inspectSandboxNetwork()
        let attachment = try attachment(from: state, for: plan)
        let currentResult = CNIResult(
            attachment: attachment,
            interfaceName: identity.ifName,
            sandbox: plan.sandbox
        )
        guard previousResult == currentResult else {
            throw CNIError.backendUnavailable(
                "CHECK failed: current sandbox network state does not match the previous CNI result"
            )
        }
    }

    public func release(_ plan: MacvmnetOperationPlan) async throws {
        let identity = try requireAttachmentIdentity(plan)
        let client = try await makeSandboxClient(identity.containerID, plan.runtimeName)
        try await client.releaseSandboxNetwork()
        try makeAttachmentLedger(plan).remove(identity: identity, networkName: plan.networkName)
    }

    public func garbageCollect(_ plan: MacvmnetOperationPlan) async throws {
        let ledger = makeAttachmentLedger(plan)
        let staleRecords = try ledger.records(networkName: plan.networkName)
            .filter { !plan.validAttachments.contains($0.identity) }

        for record in staleRecords {
            let client = try await makeSandboxClient(record.identity.containerID, plan.runtimeName)
            try await client.releaseSandboxNetwork()
            try ledger.remove(identity: record.identity, networkName: record.networkName)
        }
    }

    private func requireAttachmentIdentity(_ plan: MacvmnetOperationPlan) throws -> MacvmnetAttachmentIdentity {
        guard let identity = plan.attachmentIdentity else {
            throw CNIError.invalidConfiguration("CNI_CONTAINERID and CNI_IFNAME are required")
        }
        return identity
    }

    private func attachment(
        from state: SandboxNetworkState,
        for plan: MacvmnetOperationPlan
    ) throws -> Attachment {
        let identity = try requireAttachmentIdentity(plan)
        let networkAttachments = state.attachments.filter { $0.network == plan.networkName }
        if let attachment = networkAttachments.first(where: { $0.hostname == identity.containerID }) {
            return attachment
        }
        if networkAttachments.count == 1, let attachment = networkAttachments.first {
            return attachment
        }

        if networkAttachments.isEmpty {
            throw CNIError.backendUnavailable(
                "no sandbox network attachment found for sandbox \(identity.containerID) on network \(plan.networkName)"
            )
        }

        throw CNIError.backendUnavailable(
            "multiple sandbox network attachments found for sandbox \(identity.containerID) on network \(plan.networkName)"
        )
    }
}

extension CNIResult {
    public init(
        attachment: Attachment,
        interfaceName: String,
        sandbox: CNISandboxURI?
    ) {
        let interface = CNIInterface(
            name: interfaceName,
            mac: attachment.macAddress?.description,
            sandbox: sandbox?.rawValue
        )

        var ips: [CNIIPConfig] = [
            CNIIPConfig(
                interface: 0,
                address: attachment.ipv4Address.description,
                gateway: attachment.ipv4Gateway.description
            )
        ]

        if let ipv6Address = attachment.ipv6Address {
            ips.append(
                CNIIPConfig(
                    interface: 0,
                    address: ipv6Address.description,
                    gateway: nil
                )
            )
        }

        let routes = [
            CNIRoute(dst: "0.0.0.0/0", gw: attachment.ipv4Gateway.description)
        ]

        let dns = attachment.dns.map {
            CNIDNS(
                nameservers: $0.nameservers,
                domain: $0.domain,
                search: $0.searchDomains,
                options: $0.options
            )
        }

        self.init(
            interfaces: [interface],
            ips: ips,
            routes: routes,
            dns: dns
        )
    }

    public func matches(
        attachment: Attachment,
        interfaceName: String,
        sandbox: CNISandboxURI?
    ) -> Bool {
        self
            == CNIResult(
                attachment: attachment,
                interfaceName: interfaceName,
                sandbox: sandbox
            )
    }
}
