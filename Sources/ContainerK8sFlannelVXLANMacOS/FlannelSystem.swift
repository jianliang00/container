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

import ContainerKit
import ContainerizationExtras
import Foundation

public struct FlannelUnderlayInterface: Sendable, Equatable {
    public var name: String
    public var ipv4Address: String
    public var mtu: Int

    public init(name: String, ipv4Address: String, mtu: Int) {
        self.name = name
        self.ipv4Address = ipv4Address
        self.mtu = mtu
    }
}

public protocol FlannelNetworkManaging: Sendable {
    func ensureHostOnlyNetwork(
        name: String,
        podCIDR: String,
        plugin: String,
        variant: String,
        knownOwnership: FlannelHostOnlyNetworkOwnership?
    ) async throws -> FlannelHostOnlyNetworkReconcileResult

    func purgeHostOnlyNetwork(
        ownership: FlannelHostOnlyNetworkOwnership
    ) async throws -> FlannelHostOnlyNetworkPurgeResult

    func validateOwnedHostOnlyNetwork(
        ownership: FlannelHostOnlyNetworkOwnership
    ) async throws -> Bool
}

public struct FlannelHostOnlyNetworkReconcileResult: Sendable, Equatable {
    public var created: Bool
    public var ownership: FlannelHostOnlyNetworkOwnership?

    public init(created: Bool, ownership: FlannelHostOnlyNetworkOwnership?) {
        self.created = created
        self.ownership = ownership
    }
}

public struct FlannelHostOnlyNetworkPurgeResult: Sendable, Equatable {
    public var networkWasPresent: Bool
    public var removed: Bool

    public init(networkWasPresent: Bool, removed: Bool) {
        self.networkWasPresent = networkWasPresent
        self.removed = removed
    }
}

public protocol FlannelNetworkBackend: Sendable {
    func listNetworks() async throws -> [NetworkState]
    func createNetwork(configuration: NetworkConfiguration) async throws -> NetworkState
    func deleteNetwork(id: String) async throws
}

public struct ContainerKitFlannelNetworkBackend: FlannelNetworkBackend {
    public var kit: ContainerKit

    public init(kit: ContainerKit = ContainerKit()) {
        self.kit = kit
    }

    public func listNetworks() async throws -> [NetworkState] {
        try await kit.listNetworks()
    }

    public func createNetwork(configuration: NetworkConfiguration) async throws -> NetworkState {
        try await kit.createNetwork(configuration: configuration)
    }

    public func deleteNetwork(id: String) async throws {
        try await kit.deleteNetwork(id: id)
    }
}

public struct ContainerKitFlannelNetworkManager: FlannelNetworkManaging {
    public static let ownershipOptionKey = "com.apple.container.flannel-vxlan.owner-id"

    public var backend: any FlannelNetworkBackend

    public init(kit: ContainerKit = ContainerKit()) {
        self.backend = ContainerKitFlannelNetworkBackend(kit: kit)
    }

    public init(backend: any FlannelNetworkBackend) {
        self.backend = backend
    }

    public func ensureHostOnlyNetwork(
        name: String,
        podCIDR: String,
        plugin: String,
        variant: String,
        knownOwnership: FlannelHostOnlyNetworkOwnership?
    ) async throws -> FlannelHostOnlyNetworkReconcileResult {
        let existing = try await backend.listNetworks().first(where: { $0.id == name })
        if let existing {
            try validate(existing: existing, name: name, podCIDR: podCIDR, plugin: plugin, variant: variant)
            return FlannelHostOnlyNetworkReconcileResult(
                created: false,
                ownership: matchingOwnership(existing: existing, knownOwnership: knownOwnership)
            )
        }

        let ownershipID = UUID().uuidString.lowercased()
        let configuration = try NetworkConfiguration(
            name: name,
            mode: .hostOnly,
            ipv4Subnet: try CIDRv4(podCIDR),
            plugin: plugin,
            options: [
                "variant": variant,
                Self.ownershipOptionKey: ownershipID,
            ]
        )
        let created: NetworkState
        do {
            created = try await backend.createNetwork(configuration: configuration)
        } catch {
            // Creation can race with a restarted daemon. Accept only an exact
            // network that is visible after the failed create.
            guard let raced = try await backend.listNetworks().first(where: { $0.id == name }) else {
                throw error
            }
            try validate(existing: raced, name: name, podCIDR: podCIDR, plugin: plugin, variant: variant)
            return FlannelHostOnlyNetworkReconcileResult(
                created: false,
                ownership: ownership(
                    existing: raced,
                    name: name,
                    podCIDR: podCIDR,
                    plugin: plugin,
                    variant: variant,
                    ownershipID: ownershipID
                )
            )
        }
        try validate(existing: created, name: name, podCIDR: podCIDR, plugin: plugin, variant: variant)
        guard
            let ownership = ownership(
                existing: created,
                name: name,
                podCIDR: podCIDR,
                plugin: plugin,
                variant: variant,
                ownershipID: ownershipID
            )
        else {
            throw FlannelVXLANError.runtime("created network \(name) did not preserve its ownership marker")
        }
        return FlannelHostOnlyNetworkReconcileResult(created: true, ownership: ownership)
    }

    public func purgeHostOnlyNetwork(
        ownership: FlannelHostOnlyNetworkOwnership
    ) async throws -> FlannelHostOnlyNetworkPurgeResult {
        guard let existing = try await backend.listNetworks().first(where: { $0.id == ownership.name }) else {
            return FlannelHostOnlyNetworkPurgeResult(networkWasPresent: false, removed: false)
        }
        try validate(existing: existing, ownership: ownership)
        do {
            try await backend.deleteNetwork(id: ownership.name)
        } catch {
            throw FlannelVXLANError.runtime(
                "failed to purge owned network \(ownership.name); stop kubelet and CRI and remove all sandbox attachments first: \(error)"
            )
        }
        guard try await backend.listNetworks().allSatisfy({ $0.id != ownership.name }) else {
            throw FlannelVXLANError.runtime("owned network \(ownership.name) still exists after deletion")
        }
        return FlannelHostOnlyNetworkPurgeResult(networkWasPresent: true, removed: true)
    }

    public func validateOwnedHostOnlyNetwork(
        ownership: FlannelHostOnlyNetworkOwnership
    ) async throws -> Bool {
        guard let existing = try await backend.listNetworks().first(where: { $0.id == ownership.name }) else {
            return false
        }
        try validate(existing: existing, ownership: ownership)
        return true
    }

    private func validate(
        existing: NetworkState,
        name: String,
        podCIDR: String,
        plugin: String,
        variant: String
    ) throws {
        guard existing.configuration.mode == .hostOnly else {
            throw FlannelVXLANError.runtime("network \(name) exists but is not host-only")
        }
        guard existing.configuration.plugin == plugin else {
            throw FlannelVXLANError.runtime(
                "network \(name) uses plugin \(existing.configuration.plugin), expected \(plugin)"
            )
        }
        guard existing.configuration.options["variant"] == variant else {
            throw FlannelVXLANError.runtime("network \(name) does not use vmnet variant \(variant)")
        }
        guard let configuredCIDR = existing.configuration.ipv4Subnet?.description,
            let configured = FlannelIPv4.parseCIDR(configuredCIDR),
            let running = FlannelIPv4.parseCIDR(existing.status.ipv4Subnet.description),
            let expected = FlannelIPv4.parseCIDR(podCIDR),
            configured == expected,
            running == expected
        else {
            throw FlannelVXLANError.runtime("network \(name) does not match PodCIDR \(podCIDR)")
        }
    }

    private func validate(
        existing: NetworkState,
        ownership: FlannelHostOnlyNetworkOwnership
    ) throws {
        try validate(
            existing: existing,
            name: ownership.name,
            podCIDR: ownership.podCIDR,
            plugin: ownership.plugin,
            variant: ownership.variant
        )
        guard existing.configuration.options[Self.ownershipOptionKey] == ownership.ownershipID else {
            throw FlannelVXLANError.runtime(
                "network \(ownership.name) ownership marker does not match persisted ownership"
            )
        }
    }

    private func matchingOwnership(
        existing: NetworkState,
        knownOwnership: FlannelHostOnlyNetworkOwnership?
    ) -> FlannelHostOnlyNetworkOwnership? {
        guard let knownOwnership,
            existing.configuration.options[Self.ownershipOptionKey] == knownOwnership.ownershipID,
            existing.id == knownOwnership.name,
            FlannelIPv4.parseCIDR(existing.status.ipv4Subnet.description)
                == FlannelIPv4.parseCIDR(knownOwnership.podCIDR),
            existing.configuration.plugin == knownOwnership.plugin,
            existing.configuration.options["variant"] == knownOwnership.variant
        else {
            return nil
        }
        return knownOwnership
    }

    private func ownership(
        existing: NetworkState,
        name: String,
        podCIDR: String,
        plugin: String,
        variant: String,
        ownershipID: String
    ) -> FlannelHostOnlyNetworkOwnership? {
        guard existing.configuration.options[Self.ownershipOptionKey] == ownershipID,
            let canonicalCIDR = FlannelIPv4.parseCIDR(podCIDR)?.string
        else {
            return nil
        }
        return FlannelHostOnlyNetworkOwnership(
            name: name,
            podCIDR: canonicalCIDR,
            plugin: plugin,
            variant: variant,
            ownershipID: ownershipID
        )
    }
}

public protocol FlannelSystemManaging: Sendable {
    func inspectUnderlayInterface(_ name: String) throws -> FlannelUnderlayInterface
    func resolveUnderlayInterface(nodeInternalIP: String?) throws -> FlannelUnderlayInterface
    func validateUnderlayRoute(destination: String, interface: String) throws
    func interfaceExists(_ name: String) throws -> Bool
    func enableIPv4Forwarding() throws
    func configureTunnelInterface(_ name: String, localAddress: String, mtu: Int) throws
    func ensureRoute(podCIDR: String, interface: String) throws
    func removeRoute(podCIDR: String, interface: String) throws
}

public struct FlannelSystemManager: FlannelSystemManaging {
    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> String

    private let commandRunner: CommandRunner

    public init() {
        self.commandRunner = Self.runProcess
    }

    init(commandRunner: @escaping CommandRunner) {
        self.commandRunner = commandRunner
    }

    public func inspectUnderlayInterface(_ name: String) throws -> FlannelUnderlayInterface {
        try inspectUnderlayInterface(name, requiredIPv4Address: nil)
    }

    public func resolveUnderlayInterface(nodeInternalIP: String?) throws -> FlannelUnderlayInterface {
        if let nodeInternalIP {
            guard FlannelIPv4.parseAddress(nodeInternalIP) != nil else {
                throw FlannelVXLANError.runtime("Node InternalIP is not a valid IPv4 address")
            }
            let interfaceNames = try run("/sbin/ifconfig", ["-l"])
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            let matches = interfaceNames.compactMap { name in
                try? inspectUnderlayInterface(name, requiredIPv4Address: nodeInternalIP)
            }
            guard matches.count == 1, let match = matches.first else {
                throw FlannelVXLANError.runtime(
                    "Node InternalIP \(nodeInternalIP) must match exactly one local IPv4 interface; found \(matches.count)"
                )
            }
            return match
        }

        let output = try run("/sbin/route", ["-n", "get", "default"])
        let interfaces = Self.routeInterfaces(in: output)
        guard interfaces.count == 1, let interface = interfaces.first else {
            throw FlannelVXLANError.runtime("default IPv4 route did not identify exactly one egress interface")
        }
        return try inspectUnderlayInterface(interface)
    }

    public func validateUnderlayRoute(destination: String, interface: String) throws {
        guard FlannelIPv4.parseAddress(destination) != nil else {
            throw FlannelVXLANError.runtime("underlay route destination is not a valid IPv4 address")
        }
        guard interface.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw FlannelVXLANError.runtime("underlay route interface is invalid")
        }

        let output = try run("/sbin/route", ["-n", "get", destination])
        let interfaces = Self.routeInterfaces(in: output)
        guard interfaces.count == 1, let resolvedInterface = interfaces.first else {
            throw FlannelVXLANError.runtime(
                "underlay route to \(destination) did not identify exactly one egress interface"
            )
        }
        guard resolvedInterface == interface else {
            throw FlannelVXLANError.runtime(
                "underlay route to \(destination) uses \(resolvedInterface), expected \(interface)"
            )
        }
    }

    private func inspectUnderlayInterface(
        _ name: String,
        requiredIPv4Address: String?
    ) throws -> FlannelUnderlayInterface {
        guard name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw FlannelVXLANError.runtime("underlay interface name is invalid")
        }
        let output = try run("/sbin/ifconfig", [name])
        let lines = output.split(separator: "\n")
        let ipv4Addresses = lines.compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "inet", FlannelIPv4.parseAddress(String(fields[1])) != nil else {
                return nil
            }
            return String(fields[1])
        }
        let ipv4Address = requiredIPv4Address ?? ipv4Addresses.first
        let mtu = lines.lazy.compactMap { line -> Int? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let index = fields.firstIndex(of: "mtu"), fields.indices.contains(index + 1) else {
                return nil
            }
            return Int(fields[index + 1])
        }.first
        guard let ipv4Address, ipv4Addresses.contains(ipv4Address), let mtu, mtu >= 576 else {
            throw FlannelVXLANError.runtime("underlay interface \(name) has no usable IPv4 address or MTU")
        }
        return FlannelUnderlayInterface(name: name, ipv4Address: ipv4Address, mtu: mtu)
    }

    public func interfaceExists(_ name: String) throws -> Bool {
        do {
            _ = try run("/sbin/ifconfig", [name])
            return true
        } catch {
            guard String(describing: error).localizedCaseInsensitiveContains("does not exist") else {
                throw error
            }
            return false
        }
    }

    public func enableIPv4Forwarding() throws {
        let value = try run("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != "1" else {
            return
        }
        _ = try run("/usr/sbin/sysctl", ["-w", "net.inet.ip.forwarding=1"])
    }

    public func configureTunnelInterface(_ name: String, localAddress: String, mtu: Int) throws {
        guard FlannelIPv4.parseAddress(localAddress) != nil else {
            throw FlannelVXLANError.runtime("tunnel local address is not valid IPv4")
        }
        _ = try run(
            "/sbin/ifconfig",
            [name, "inet", localAddress, localAddress, "netmask", "255.255.255.255", "mtu", "\(mtu)", "up"]
        )
    }

    public func ensureRoute(podCIDR: String, interface: String) throws {
        let canonicalCIDR = try Self.validateManagedRoute(podCIDR: podCIDR, interface: interface)
        if case .present(let existingInterface) = try exactRouteState(for: canonicalCIDR) {
            guard existingInterface == interface else {
                throw FlannelVXLANError.runtime(
                    "route \(canonicalCIDR.string) already exists on \(existingInterface), expected \(interface)"
                )
            }
            return
        }

        do {
            _ = try run("/sbin/route", ["-n", "add", "-net", canonicalCIDR.string, "-interface", interface])
        } catch {
            let state = try exactRouteState(for: canonicalCIDR)
            if state == .present(interface: interface) {
                return
            }
            if case .present(let existingInterface) = state {
                throw FlannelVXLANError.runtime(
                    "route \(canonicalCIDR.string) appeared on \(existingInterface) while adding it to \(interface)"
                )
            }
            throw error
        }
        let state = try exactRouteState(for: canonicalCIDR)
        guard state == .present(interface: interface) else {
            throw FlannelVXLANError.runtime(
                "route \(canonicalCIDR.string) was not installed on \(interface); found \(state.description)"
            )
        }
    }

    public func removeRoute(podCIDR: String, interface: String) throws {
        let canonicalCIDR = try Self.validateManagedRoute(podCIDR: podCIDR, interface: interface)
        let initialState = try exactRouteState(for: canonicalCIDR)
        guard case .present(let existingInterface) = initialState else {
            return
        }
        guard existingInterface == interface else {
            throw FlannelVXLANError.runtime(
                "refusing to remove route \(canonicalCIDR.string) from \(interface) because it exists on \(existingInterface)"
            )
        }
        do {
            _ = try run("/sbin/route", ["-n", "delete", "-net", canonicalCIDR.string, "-interface", interface])
        } catch {
            let state = try exactRouteState(for: canonicalCIDR)
            if state == .absent {
                return
            }
            if case .present(let currentInterface) = state, currentInterface != interface {
                throw FlannelVXLANError.runtime(
                    "route \(canonicalCIDR.string) moved to \(currentInterface) while removing it from \(interface)"
                )
            }
            throw error
        }
        let finalState = try exactRouteState(for: canonicalCIDR)
        guard finalState == .absent else {
            throw FlannelVXLANError.runtime(
                "route \(canonicalCIDR.string) remains after removal: \(finalState.description)"
            )
        }
    }

    private static func validateManagedRoute(podCIDR: String, interface: String) throws -> FlannelIPv4.CIDR {
        guard let canonicalCIDR = FlannelIPv4.parseCIDR(podCIDR), canonicalCIDR.prefixLength > 0 else {
            throw FlannelVXLANError.runtime("managed route PodCIDR must be valid IPv4 and must not be default")
        }
        guard interface.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw FlannelVXLANError.runtime("managed route interface is invalid")
        }
        return canonicalCIDR
    }

    private func exactRouteState(for podCIDR: FlannelIPv4.CIDR) throws -> ManagedRouteState {
        // route(8) reports the best match, which may be the default route. The
        // destination and mask must match before its interface is actionable.
        let output = try run("/sbin/route", ["-n", "get", "-net", podCIDR.string])
        guard let routeCIDR = Self.routeCIDR(in: output) else {
            throw FlannelVXLANError.runtime("route query for \(podCIDR.string) returned an invalid destination or mask")
        }
        let interfaces = Self.routeInterfaces(in: output)
        guard interfaces.count == 1, let interface = interfaces.first else {
            throw FlannelVXLANError.runtime(
                "route query for \(podCIDR.string) did not identify exactly one interface"
            )
        }
        guard routeCIDR == podCIDR else {
            return .absent
        }
        return .present(interface: interface)
    }

    private enum ManagedRouteState: Equatable {
        case absent
        case present(interface: String)

        var description: String {
            switch self {
            case .absent:
                "absent"
            case .present(let interface):
                "interface \(interface)"
            }
        }
    }

    private static func routeCIDR(in output: String) -> FlannelIPv4.CIDR? {
        guard let destination = routeField("destination", in: output),
            let netmask = routeField("mask", in: output)
        else {
            return nil
        }
        if destination == "default" || netmask == "default" {
            guard destination == "default", netmask == "default" else {
                return nil
            }
            return FlannelIPv4.parseCIDR("0.0.0.0/0")
        }
        guard let address = FlannelIPv4.parseAddress(destination),
            let mask = FlannelIPv4.parseAddress(netmask)
        else {
            return nil
        }
        let prefixLength = mask.nonzeroBitCount
        let expectedMask = prefixLength == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefixLength)
        guard mask == expectedMask else {
            return nil
        }
        return FlannelIPv4.CIDR(network: address & mask, prefixLength: prefixLength)
    }

    private static func routeField(_ name: String, in output: String) -> String? {
        let values = output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "\(name):" else {
                return nil
            }
            return String(fields[1])
        }
        guard values.count == 1 else {
            return nil
        }
        return values[0]
    }

    private static func routeInterfaces(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "interface:" else {
                return nil
            }
            return String(fields[1])
        }
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        try commandRunner(executable, arguments)
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw FlannelVXLANError.runtime("failed to run \(executable): \(error)")
        }
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FlannelVXLANError.runtime(
                "\(executable) \(arguments.joined(separator: " ")) failed with status \(process.terminationStatus): \(message)"
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
