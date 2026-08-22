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

import ContainerNetworkServer
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import Synchronization
import XPC
import vmnet

/// Creates a vmnet network with reservation APIs.
@available(macOS 26, *)
public final class ReservedVmnetNetwork: ContainerNetworkServer.Network {
    private enum Transition {
        case starting
        case stopping
    }

    final class ManagedVmnetCFReference: @unchecked Sendable {
        typealias Releaser = @Sendable (OpaquePointer) -> Void

        let value: OpaquePointer
        private let releaser: Releaser

        init(
            _ value: OpaquePointer,
            releaser: @escaping Releaser = ManagedVmnetCFReference.release
        ) {
            self.value = value
            self.releaser = releaser
        }

        deinit {
            releaser(value)
        }

        private static func release(_ value: OpaquePointer) {
            // vmnet's create APIs follow the CF_RETURNS_RETAINED rule. Swift
            // marks CFRelease unavailable, so balance that ownership through
            // the equivalent Unmanaged release operation.
            Unmanaged<AnyObject>.fromOpaque(UnsafeMutableRawPointer(value)).release()
        }
    }

    private struct State {
        var status: NetworkStatus?
        var network: ManagedVmnetCFReference?
        var transition: Transition?
    }

    private struct NetworkInfo {
        let network: ManagedVmnetCFReference
        let ipv4Subnet: CIDRv4
        let ipv4Gateway: IPv4Address
        let ipv6Subnet: CIDRv6
    }

    private let configuration: NetworkConfiguration
    private let stateMutex: Mutex<State>
    private let hostIPv6GatewayWaiter: VmnetHostIPv6GatewayWaiter
    private let log: Logger

    /// Configure a bridge network that allows external system access using
    /// network address translation.
    public convenience init(
        configuration: NetworkConfiguration,
        log: Logger
    ) throws {
        try self.init(
            configuration: configuration,
            log: log,
            hostIPv6GatewayReadinessChecker: SystemVmnetHostIPv6GatewayReadinessChecker()
        )
    }

    init(
        configuration: NetworkConfiguration,
        log: Logger,
        hostIPv6GatewayReadinessChecker: any VmnetHostIPv6GatewayReadinessChecking
    ) throws {
        guard configuration.mode == .nat || configuration.mode == .hostOnly else {
            throw ContainerizationError(.unsupported, message: "invalid network mode \(configuration.mode)")
        }

        log.info("creating vmnet network")
        self.configuration = configuration
        self.log = log
        self.hostIPv6GatewayWaiter = VmnetHostIPv6GatewayWaiter(checker: hostIPv6GatewayReadinessChecker)
        stateMutex = Mutex(State())
        log.info("created vmnet network")
    }

    public nonisolated var id: String { configuration.id }

    public nonisolated var variant: String? { "reserved" }

    public var status: NetworkStatus? {
        stateMutex.withLock { $0.status }
    }

    public nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        try stateMutex.withLock { state in
            try handler(state.network.map { try Self.serializeNetworkRef(ref: $0.value) })
        }
    }

    public func start() async throws {
        try stateMutex.withLock { state in
            guard state.status == nil, state.transition == nil else {
                throw ContainerizationError(.invalidArgument, message: "cannot start network \(configuration.id): already started or transitioning")
            }
            state.transition = .starting
        }

        do {
            let networkInfo = try startNetwork(configuration: configuration, log: log)
            if let requestedIPv6Subnet = configuration.ipv6Subnet {
                guard requestedIPv6Subnet == networkInfo.ipv6Subnet else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "vmnet returned IPv6 subnet \(networkInfo.ipv6Subnet), expected \(requestedIPv6Subnet)"
                    )
                }
            }

            stateMutex.withLock { state in
                state.status = NetworkStatus(
                    ipv4Subnet: networkInfo.ipv4Subnet,
                    ipv4Gateway: networkInfo.ipv4Gateway,
                    ipv6Subnet: networkInfo.ipv6Subnet,
                    ipv6Gateway: configuration.ipv6Subnet.map { IPv6Address($0.lower.value + 1) }
                )
                state.network = networkInfo.network
                state.transition = nil
            }
        } catch {
            stateMutex.withLock { $0.transition = nil }
            throw error
        }
    }

    public func activate() async throws {
        guard configuration.mode == .hostOnly, configuration.ipv6Subnet != nil else {
            return
        }
        let status = try stateMutex.withLock { state -> NetworkStatus in
            guard state.network != nil, let status = state.status, status.ipv6Gateway != nil else {
                throw ContainerizationError(.invalidState, message: "cannot activate network \(configuration.id) before it is started")
            }
            return status
        }

        guard let ipv6Gateway = status.ipv6Gateway, let ipv6Subnet = status.ipv6Subnet else {
            throw ContainerizationError(.invalidState, message: "network \(configuration.id) has no explicit IPv6 gateway")
        }
        try await hostIPv6GatewayWaiter.wait(
            ipv4Gateway: status.ipv4Gateway,
            ipv6Gateway: ipv6Gateway,
            prefixLength: ipv6Subnet.prefix.length
        )
    }

    public func stop() async throws {
        let shouldStop = try stateMutex.withLock { state -> Bool in
            guard state.transition == nil else {
                throw ContainerizationError(.invalidState, message: "cannot stop network \(configuration.id) while it is transitioning")
            }
            guard state.status != nil || state.network != nil else {
                return false
            }
            state.transition = .stopping
            return true
        }
        guard shouldStop else { return }

        stateMutex.withLock { state in
            state.status = nil
            state.network = nil
            state.transition = nil
        }
    }

    private static func serializeNetworkRef(ref: vmnet_network_ref) throws -> XPCMessage {
        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let refObject = vmnet_network_copy_serialization(ref, &status) else {
            throw ContainerizationError(.invalidArgument, message: "cannot serialize vmnet_network_ref to XPC object, status \(status)")
        }
        return XPCMessage(object: refObject)
    }

    private func startNetwork(configuration: NetworkConfiguration, log: Logger) throws -> NetworkInfo {
        log.info(
            "starting vmnet network",
            metadata: [
                "id": "\(configuration.id)",
                "mode": "\(configuration.mode)",
            ]
        )

        // set up the vmnet configuration
        var status: vmnet_return_t = .VMNET_SUCCESS
        let mode: vmnet.operating_modes_t = configuration.mode == .hostOnly ? .VMNET_HOST_MODE : .VMNET_SHARED_MODE
        guard let vmnetConfiguration = vmnet_network_configuration_create(mode, &status), status == .VMNET_SUCCESS else {
            throw ContainerizationError(.unsupported, message: "failed to create vmnet config with status \(status)")
        }
        let managedConfiguration = ManagedVmnetCFReference(vmnetConfiguration)

        vmnet_network_configuration_disable_dhcp(managedConfiguration.value)

        let ipv4Subnet = configuration.ipv4Subnet
        let ipv6Subnet = configuration.ipv6Subnet

        // set the IPv4 subnet
        if let ipv4Subnet {
            let gateway = IPv4Address(ipv4Subnet.lower.value + 1)
            var gatewayAddr = in_addr()
            inet_pton(AF_INET, gateway.description, &gatewayAddr)
            let mask = IPv4Address(ipv4Subnet.prefix.prefixMask32)
            var maskAddr = in_addr()
            inet_pton(AF_INET, mask.description, &maskAddr)
            log.info(
                "configuring vmnet IPv4 subnet",
                metadata: ["cidr": "\(ipv4Subnet)"]
            )
            let status = vmnet_network_configuration_set_ipv4_subnet(managedConfiguration.value, &gatewayAddr, &maskAddr)
            guard status == .VMNET_SUCCESS else {
                throw ContainerizationError(.internalError, message: "failed to set subnet \(ipv4Subnet) for IPv4 network \(configuration.id)")
            }
        }

        // set the IPv6 network prefix
        if let ipv6Subnet {
            guard ipv6Subnet.prefix.length == 64,
                !ipv6Subnet.lower.isUnspecified,
                !ipv6Subnet.lower.isLoopback,
                !ipv6Subnet.lower.isMulticast,
                !ipv6Subnet.lower.isLinkLocal
            else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "explicit vmnet IPv6 subnet must be a usable /64 network"
                )
            }
            var prefixAddr = in6_addr()
            inet_pton(AF_INET6, ipv6Subnet.lower.description, &prefixAddr)
            log.info(
                "configuring vmnet IPv6 prefix",
                metadata: ["cidr": "\(ipv6Subnet)"]
            )
            let status = vmnet_network_configuration_set_ipv6_prefix(
                managedConfiguration.value,
                &prefixAddr,
                ipv6Subnet.prefix.length
            )
            guard status == .VMNET_SUCCESS else {
                throw ContainerizationError(.internalError, message: "failed to set prefix \(ipv6Subnet) for IPv6 network \(configuration.id)")
            }
        }

        // reserve the network
        guard let network = vmnet_network_create(managedConfiguration.value, &status), status == .VMNET_SUCCESS else {
            throw ContainerizationError(.unsupported, message: "failed to create vmnet network with status \(status)")
        }
        let managedNetwork = ManagedVmnetCFReference(network)

        // retrieve the subnet since the caller may not have provided one
        var subnetAddr = in_addr()
        var maskAddr = in_addr()
        vmnet_network_get_ipv4_subnet(network, &subnetAddr, &maskAddr)
        let subnetValue = UInt32(bigEndian: subnetAddr.s_addr)
        let maskValue = UInt32(bigEndian: maskAddr.s_addr)
        let lower = IPv4Address(subnetValue & maskValue)
        let upper = IPv4Address(lower.value + ~maskValue)
        let runningSubnet = try CIDRv4(lower: lower, upper: upper)
        let runningGateway = IPv4Address(runningSubnet.lower.value + 1)

        var prefixAddr = in6_addr()
        var prefixLength = UInt8(0)
        vmnet_network_get_ipv6_prefix(network, &prefixAddr, &prefixLength)
        guard let prefix = Prefix(length: prefixLength) else {
            throw ContainerizationError(.internalError, message: "invalid IPv6 prefix length \(prefixLength) for network \(configuration.id)")
        }
        let prefixIpv6Bytes = withUnsafeBytes(of: prefixAddr.__u6_addr.__u6_addr8) {
            Array($0)
        }
        let prefixIpv6Addr = try IPv6Address(prefixIpv6Bytes)
        let runningV6Subnet = try CIDRv6(prefixIpv6Addr, prefix: prefix)

        log.info(
            "started vmnet network",
            metadata: [
                "id": "\(configuration.id)",
                "mode": "\(configuration.mode)",
                "cidr": "\(runningSubnet)",
                "cidrv6": "\(runningV6Subnet)",
            ]
        )

        return NetworkInfo(
            network: managedNetwork,
            ipv4Subnet: runningSubnet,
            ipv4Gateway: runningGateway,
            ipv6Subnet: runningV6Subnet,
        )
    }
}
