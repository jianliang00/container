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

struct GuestNetworkConfigurator {
    struct CommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    let runCommand: @Sendable (_ executable: String, _ arguments: [String]) throws -> CommandResult

    init(
        runCommand: @escaping @Sendable (_ executable: String, _ arguments: [String]) throws -> CommandResult = GuestNetworkConfigurator.runSystemCommand
    ) {
        self.runCommand = runCommand
    }

    func apply(_ request: MacOSGuestNetworkConfigurationRequest) throws -> MacOSGuestNetworkConfigurationResult {
        guard !request.interfaces.isEmpty else {
            return .init(interfaces: [], dnsApplied: false)
        }

        let interfaceLookup = try Self.parseInterfaceNamesByMAC(
            from: runCommand("/sbin/ifconfig", ["-a"]).stdout
        )

        var appliedInterfaces: [MacOSGuestAppliedNetworkInterface] = []
        for interface in request.interfaces {
            let normalizedMAC = Self.normalizeMACAddress(interface.macAddress)
            guard let interfaceName = interfaceLookup[normalizedMAC] else {
                throw Self.makeError("guest network interface not found for MAC \(interface.macAddress)")
            }
            try configureInterface(interfaceName: interfaceName, interface: interface)
            appliedInterfaces.append(
                .init(
                    networkID: interface.networkID,
                    interfaceName: interfaceName,
                    macAddress: interface.macAddress,
                    ipv4Address: "\(interface.ipv4Address)/\(interface.ipv4PrefixLength)"
                )
            )
        }

        let primaryIndex = min(max(request.primaryInterfaceIndex, 0), appliedInterfaces.count - 1)
        try configureDefaultRoute(gateway: request.interfaces[primaryIndex].ipv4Gateway)

        var warnings: [String] = []
        let dnsApplied = try configureDNSIfNeeded(
            request.dns,
            primaryInterfaceName: appliedInterfaces[primaryIndex].interfaceName,
            warnings: &warnings
        )
        return .init(interfaces: appliedInterfaces, dnsApplied: dnsApplied, warnings: warnings)
    }

    private func configureInterface(
        interfaceName: String,
        interface: MacOSGuestNetworkInterfaceConfiguration
    ) throws {
        _ = try run("/sbin/ifconfig", [
            interfaceName,
            "inet",
            interface.ipv4Address,
            "netmask",
            Self.ipv4NetmaskString(prefixLength: interface.ipv4PrefixLength),
            "up",
        ])
    }

    private func configureDefaultRoute(gateway: String) throws {
        _ = try? runCommand("/sbin/route", ["-n", "delete", "default"])
        _ = try run("/sbin/route", ["-n", "add", "default", gateway])
    }

    private func configureDNSIfNeeded(
        _ dns: MacOSGuestDNSConfiguration?,
        primaryInterfaceName: String,
        warnings: inout [String]
    ) throws -> Bool {
        guard let dns else {
            return false
        }

        if !dns.options.isEmpty {
            warnings.append("dns options are not yet applied inside the macOS guest")
        }

        let servicesByInterface = try Self.parseNetworkServicesByDevice(
            from: runCommand("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).stdout
        )
        guard let serviceName = servicesByInterface[primaryInterfaceName] else {
            throw Self.makeError("guest network service not found for interface \(primaryInterfaceName)")
        }

        let nameservers = dns.nameservers.isEmpty ? ["Empty"] : dns.nameservers
        _ = try run("/usr/sbin/networksetup", ["-setdnsservers", serviceName] + nameservers)

        var searchDomains = dns.searchDomains
        if let domain = dns.domain, !domain.isEmpty, !searchDomains.contains(domain) {
            searchDomains.insert(domain, at: 0)
        }
        let searchArgs = searchDomains.isEmpty ? ["Empty"] : searchDomains
        _ = try run("/usr/sbin/networksetup", ["-setsearchdomains", serviceName] + searchArgs)
        return true
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let result = try runCommand(executable, arguments)
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? stdout : stderr
            throw Self.makeError("command failed: \(executable) \(arguments.joined(separator: " ")) (\(detail))")
        }
        return result
    }

    static func parseInterfaceNamesByMAC(from ifconfigOutput: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var currentInterface: String?

        for rawLine in ifconfigOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                continue
            }
            if !rawLine.hasPrefix("\t") && !rawLine.hasPrefix(" ") && line.contains(": flags=") {
                currentInterface = String(line.split(separator: ":", maxSplits: 1)[0])
                continue
            }
            guard let currentInterface, line.hasPrefix("ether ") else {
                continue
            }
            let macAddress = String(line.dropFirst("ether ".count)).split(separator: " ").first.map(String.init) ?? ""
            guard !macAddress.isEmpty else {
                continue
            }
            result[normalizeMACAddress(macAddress)] = currentInterface
        }

        return result
    }

    static func parseNetworkServicesByDevice(from serviceOrderOutput: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var currentService: String?

        for rawLine in serviceOrderOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continue
            }

            if line.hasPrefix("("), let closing = line.firstIndex(of: ")") {
                let service = line[line.index(after: closing)...].trimmingCharacters(in: .whitespaces)
                if !service.isEmpty, !service.hasPrefix("(Hardware Port:") {
                    currentService = service
                    continue
                }
            }

            guard
                line.hasPrefix("(Hardware Port:"),
                let deviceRange = line.range(of: "Device: ")
            else {
                continue
            }

            let deviceSuffix = line[deviceRange.upperBound...]
            let device = deviceSuffix
                .replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let currentService, !device.isEmpty else {
                continue
            }
            result[device] = currentService
        }

        return result
    }

    static func normalizeMACAddress(_ macAddress: String) -> String {
        macAddress.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    static func ipv4NetmaskString(prefixLength: UInt8) -> String {
        let bits = Int(prefixLength)
        let value: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return [
            String((value >> 24) & 0xff),
            String((value >> 16) & 0xff),
            String((value >> 8) & 0xff),
            String(value & 0xff),
        ].joined(separator: ".")
    }

    private static func runSystemCommand(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return .init(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(
            domain: "container.macos.guest-agent.network",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
