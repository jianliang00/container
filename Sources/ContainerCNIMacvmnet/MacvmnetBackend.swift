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
import ContainerizationExtras
import Foundation

public protocol MacvmnetNetworkClient: Sendable {
    func state() async throws -> NetworkState
    func allocateAttachment(hostname: String, macAddress: MACAddress?) async throws -> Attachment
    func deallocate(hostname: String) async throws
    func lookup(hostname: String) async throws -> Attachment?
    func disableAllocator() async throws -> Bool
}

extension NetworkClient: MacvmnetNetworkClient {
    public func allocateAttachment(hostname: String, macAddress: MACAddress?) async throws -> Attachment {
        let (attachment, _) = try await allocate(hostname: hostname, macAddress: macAddress)
        return attachment
    }
}

public protocol MacvmnetBackend: Sendable {
    func health(networkName: String) async throws
    func prepare(_ plan: MacvmnetOperationPlan) async throws -> CNIResult
    func inspect(_ plan: MacvmnetOperationPlan) async throws
    func release(_ plan: MacvmnetOperationPlan) async throws
    func garbageCollect(_ plan: MacvmnetOperationPlan) async throws
}

public struct MacvmnetLiveBackend: MacvmnetBackend {
    public typealias NetworkClientFactory = @Sendable (String) -> any MacvmnetNetworkClient

    private let makeNetworkClient: NetworkClientFactory

    public init(makeNetworkClient: @escaping NetworkClientFactory = { NetworkClient(id: $0) }) {
        self.makeNetworkClient = makeNetworkClient
    }

    public func health(networkName: String) async throws {
        _ = try await makeNetworkClient(networkName).state()
    }

    public func prepare(_ plan: MacvmnetOperationPlan) async throws -> CNIResult {
        let attachment = try await allocatedAttachment(for: plan)
        return CNIResult(
            attachment: attachment,
            interfaceName: plan.interfaceName ?? "eth0",
            sandbox: plan.sandbox
        )
    }

    public func inspect(_ plan: MacvmnetOperationPlan) async throws {
        let attachment = try await existingAttachment(for: plan)
        guard let previousResult = plan.previousResult else {
            throw CNIError.invalidConfiguration("CHECK requires prevResult")
        }
        let currentResult = CNIResult(
            attachment: attachment,
            interfaceName: plan.interfaceName ?? "eth0",
            sandbox: plan.sandbox
        )
        guard previousResult == currentResult else {
            throw CNIError.backendUnavailable(
                "CHECK failed: current sandbox network state does not match the previous CNI result"
            )
        }
    }

    public func release(_ plan: MacvmnetOperationPlan) async throws {
        let client = makeNetworkClient(plan.networkName)
        guard let hostName = plan.containerID, !hostName.isEmpty else {
            throw CNIError.missingEnvironment("CNI_CONTAINERID")
        }
        guard try await client.lookup(hostname: hostName) != nil else {
            return
        }
        try await client.deallocate(hostname: hostName)
    }

    public func garbageCollect(_ plan: MacvmnetOperationPlan) async throws {
        _ = plan
    }

    private func allocatedAttachment(for plan: MacvmnetOperationPlan) async throws -> Attachment {
        let client = makeNetworkClient(plan.networkName)
        guard let hostName = plan.containerID, !hostName.isEmpty else {
            throw CNIError.missingEnvironment("CNI_CONTAINERID")
        }

        if let attachment = try await client.lookup(hostname: hostName) {
            return attachment
        }

        return try await client.allocateAttachment(hostname: hostName, macAddress: nil)
    }

    private func existingAttachment(for plan: MacvmnetOperationPlan) async throws -> Attachment {
        let client = makeNetworkClient(plan.networkName)
        guard let hostName = plan.containerID, !hostName.isEmpty else {
            throw CNIError.missingEnvironment("CNI_CONTAINERID")
        }
        guard let attachment = try await client.lookup(hostname: hostName) else {
            throw CNIError.backendUnavailable(
                "no network attachment found for sandbox \(hostName) on network \(plan.networkName)"
            )
        }
        return attachment
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
