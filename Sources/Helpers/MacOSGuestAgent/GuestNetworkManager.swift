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

import Foundation
import RuntimeMacOSSidecarShared

enum GuestNetworkManager {
    static func configure(_ configuration: MacOSGuestNetworkConfiguration) throws -> MacOSGuestNetworkSnapshot {
        let interfaceName = try selectInterfaceName(matching: configuration.interfaceMACAddress)

        if
            let ipv4Address = configuration.ipv4Address,
            let prefixLength = configuration.ipv4PrefixLength
        {
            let netmask = try netmaskText(prefixLength: prefixLength)
            _ = try GuestNetworkInspector.runCommand(
                executable: "/sbin/ifconfig",
                arguments: [interfaceName, "inet", ipv4Address, "netmask", netmask, "up"]
            )
        }

        if let gateway = configuration.ipv4Gateway, !gateway.isEmpty {
            do {
                _ = try GuestNetworkInspector.runCommand(
                    executable: "/usr/sbin/route",
                    arguments: ["-n", "change", "default", gateway]
                )
            } catch {
                _ = try? GuestNetworkInspector.runCommand(
                    executable: "/usr/sbin/route",
                    arguments: ["-n", "delete", "default"]
                )
                _ = try GuestNetworkInspector.runCommand(
                    executable: "/usr/sbin/route",
                    arguments: ["-n", "add", "default", gateway]
                )
            }
        }

        let requestedSearchDomains = mergedSearchDomains(
            domain: configuration.domain,
            searchDomains: configuration.searchDomains
        )
        let needsNameserverUpdate = !configuration.nameservers.isEmpty
        let needsSearchDomainUpdate = !requestedSearchDomains.isEmpty || configuration.domain != nil
        if needsNameserverUpdate || needsSearchDomainUpdate {
            let serviceName = try networkServiceName(for: interfaceName)
            if needsNameserverUpdate {
                _ = try GuestNetworkInspector.runCommand(
                    executable: "/usr/sbin/networksetup",
                    arguments: ["-setdnsservers", serviceName] + configuration.nameservers
                )
            }

            if needsSearchDomainUpdate {
                let searchDomainArgs = requestedSearchDomains.isEmpty ? ["empty"] : requestedSearchDomains
                _ = try GuestNetworkInspector.runCommand(
                    executable: "/usr/sbin/networksetup",
                    arguments: ["-setsearchdomains", serviceName] + searchDomainArgs
                )
            }
        }

        return try GuestNetworkInspector.inspect()
    }

    static func selectInterfaceName(matching macAddress: String?) throws -> String {
        if let macAddress, !macAddress.isEmpty {
            let requestedMAC = canonicalMACAddress(macAddress)
            for interfaceName in try interfaceNames() {
                guard let actualMAC = try interfaceMACAddress(for: interfaceName) else {
                    continue
                }
                if canonicalMACAddress(actualMAC) == requestedMAC {
                    return interfaceName
                }
            }
            throw makePOSIXLikeError(message: "failed to locate interface for MAC address \(macAddress)")
        }

        if let defaultInterfaceName = try? GuestNetworkInspector.inspect().interfaceName, !defaultInterfaceName.isEmpty {
            return defaultInterfaceName
        }

        if let fallback = try interfaceNames().first(where: { try interfaceMACAddress(for: $0) != nil }) {
            return fallback
        }
        throw makePOSIXLikeError(message: "failed to locate a non-loopback interface in the guest")
    }

    static func interfaceNames() throws -> [String] {
        let output = try GuestNetworkInspector.runCommand(executable: "/sbin/ifconfig", arguments: ["-l"])
        return output
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "lo0" }
    }

    static func interfaceMACAddress(for interfaceName: String) throws -> String? {
        let output = try GuestNetworkInspector.runCommand(executable: "/sbin/ifconfig", arguments: [interfaceName])
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("ether ") else {
                continue
            }
            let components = line.split(whereSeparator: \.isWhitespace)
            if components.count >= 2 {
                return String(components[1])
            }
        }
        return nil
    }

    static func networkServiceName(for interfaceName: String) throws -> String {
        let output = try GuestNetworkInspector.runCommand(
            executable: "/usr/sbin/networksetup",
            arguments: ["-listnetworkserviceorder"]
        )
        guard let serviceName = parseNetworkServiceName(output, interfaceName: interfaceName) else {
            throw makePOSIXLikeError(message: "failed to find network service for interface \(interfaceName)")
        }
        return serviceName
    }

    static func parseNetworkServiceName(_ output: String, interfaceName: String) -> String? {
        var currentServiceName: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("("), !line.contains("Hardware Port:"), let close = line.firstIndex(of: ")") {
                let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                currentServiceName = name.isEmpty ? nil : name
                continue
            }

            guard let currentServiceName, line.contains("Device: \(interfaceName)") else {
                continue
            }
            return currentServiceName
        }
        return nil
    }

    static func mergedSearchDomains(domain: String?, searchDomains: [String]) -> [String] {
        var values = [String]()
        if let domain, !domain.isEmpty {
            values.append(domain)
        }
        for searchDomain in searchDomains where !searchDomain.isEmpty && !values.contains(searchDomain) {
            values.append(searchDomain)
        }
        return values
    }

    static func canonicalMACAddress(_ macAddress: String) -> String {
        macAddress.replacingOccurrences(of: "-", with: ":").lowercased()
    }

    static func netmaskText(prefixLength: UInt8) throws -> String {
        guard prefixLength <= 32 else {
            throw makePOSIXLikeError(message: "invalid IPv4 prefix length \(prefixLength)")
        }

        let value: UInt32 =
            prefixLength == 0
            ? 0
            : UInt32.max << (32 - UInt32(prefixLength))
        let octets = stride(from: 24, through: 0, by: -8).map { shift in
            String((value >> UInt32(shift)) & 0xff)
        }
        return octets.joined(separator: ".")
    }
}
