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
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Logging

public actor DefaultNetworkService: NetworkService {
    private let network: any Network
    private let log: Logger
    private var allocator: AttachmentAllocator
    private var macAddresses: [UInt32: MACAddress]
    private var allocationsBySession: [XPCServerSession: [String: UInt32]]
    private var ownersByHostname: [String: Set<XPCServerSession>]
    private var releaseWaitersByHostname: [String: [CheckedContinuation<Void, Never>]]

    /// Set up a network service for the specified network.
    public init(
        network: any Network,
        log: Logger
    ) async throws {
        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        let subnet = status.ipv4Subnet
        let size = Int(subnet.upper.value - subnet.lower.value - 3)
        self.network = network
        self.log = log
        self.allocator = try AttachmentAllocator(lower: subnet.lower.value + 2, size: size)
        self.macAddresses = [:]
        self.allocationsBySession = [:]
        self.ownersByHostname = [:]
        self.releaseWaitersByHostname = [:]
    }

    @Sendable
    public func status() async throws -> NetworkStatus {
        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) is not running")
        }
        return status
    }

    @Sendable
    public func allocate(
        hostname: String,
        macAddress: MACAddress?,
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        let index = try await allocateIndex(hostname: hostname)
        let macAddress =
            macAddresses[index]
            ?? macAddress
            ?? MACAddress((UInt64.random(in: 0...UInt64.max) & 0x0cff_ffff_ffff) | 0xf200_0000_0000)
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let ip = IPv4Address(index)
        let attachment = Attachment(
            network: network.id,
            hostname: hostname,
            ipv4Address: try CIDRv4(ip, prefix: status.ipv4Subnet.prefix),
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress,
            variant: network.variant
        )
        log.info(
            "allocated attachment",
            metadata: [
                "hostname": "\(hostname)",
                "ipv4Address": "\(attachment.ipv4Address)",
                "ipv4Gateway": "\(attachment.ipv4Gateway)",
                "ipv6Address": "\(attachment.ipv6Address?.description ?? "unavailable")",
                "macAddress": "\(attachment.macAddress?.description ?? "unspecified")",
            ])

        var additionalData: XPCMessage?
        try network.withAdditionalData {
            additionalData = $0
        }
        macAddresses[index] = macAddress

        let isNewSession = allocationsBySession[session] == nil
        if allocationsBySession[session]?[hostname] == nil {
            allocationsBySession[session, default: [:]][hostname] = index
            ownersByHostname[hostname, default: []].insert(session)
        }
        if isNewSession {
            await session.onDisconnect { [weak self, weak session] in
                guard let self, let session else {
                    return
                }
                await self.releaseSession(session)
            }
        }

        return (attachment: attachment, additionalData: additionalData)
    }

    private func releaseSession(_ session: XPCServerSession) async {
        guard let allocations = allocationsBySession.removeValue(forKey: session) else {
            return
        }
        for (hostname, index) in allocations {
            guard var owners = ownersByHostname[hostname] else {
                continue
            }
            owners.remove(session)
            guard owners.isEmpty else {
                ownersByHostname[hostname] = owners
                continue
            }

            ownersByHostname.removeValue(forKey: hostname)
            releaseWaitersByHostname[hostname] = []
            do {
                _ = try await allocator.deallocate(hostname: hostname)
            } catch {
                log.error(
                    "failed to release attachment",
                    metadata: [
                        "hostname": "\(hostname)",
                        "error": "\(error)",
                    ])
            }
            macAddresses.removeValue(forKey: index)
            finishRelease(hostname: hostname)
        }
        log.info("released session", metadata: ["allocations": "\(allocations.count)"])
    }

    private func allocateIndex(hostname: String) async throws -> UInt32 {
        while true {
            await waitForRelease(hostname: hostname)
            do {
                let index = try await allocator.allocate(hostname: hostname)
                if releaseWaitersByHostname[hostname] == nil {
                    return index
                }
            } catch {
                guard releaseWaitersByHostname[hostname] != nil else {
                    throw error
                }
            }
        }
    }

    private func waitForRelease(hostname: String) async {
        while releaseWaitersByHostname[hostname] != nil {
            await withCheckedContinuation { continuation in
                guard releaseWaitersByHostname[hostname] != nil else {
                    continuation.resume()
                    return
                }
                releaseWaitersByHostname[hostname, default: []].append(continuation)
            }
        }
    }

    private func finishRelease(hostname: String) {
        let waiters = releaseWaitersByHostname.removeValue(forKey: hostname) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    @Sendable
    public func lookup(hostname: String) async throws -> Attachment? {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        // Invariant: hostname -> index if and only if index -> MAC address
        let index = try await allocator.lookup(hostname: hostname)
        guard let index else {
            return nil
        }
        guard let macAddress = macAddresses[index] else {
            return nil
        }

        let address = IPv4Address(index)
        let subnet = status.ipv4Subnet
        let ipv4Address = try CIDRv4(address, prefix: subnet.prefix)
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let attachment = Attachment(
            network: network.id,
            hostname: hostname,
            ipv4Address: ipv4Address,
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress,
            variant: network.variant
        )
        log.debug(
            "lookup attachment",
            metadata: [
                "hostname": "\(hostname)",
                "address": "\(address)",
            ])

        return attachment
    }
}
