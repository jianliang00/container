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
    let applySystemConfiguration:
        @Sendable (
            _ interfaces: [GuestSystemNetworkConfigurator.InterfaceConfiguration],
            _ primaryInterfaceIndex: Int,
            _ dns: MacOSGuestDNSConfiguration?
        ) throws -> GuestSystemNetworkConfigurator.Result

    init(
        runCommand: @escaping @Sendable (_ executable: String, _ arguments: [String]) throws -> CommandResult = GuestNetworkConfigurator.runSystemCommand,
        applySystemConfiguration:
            @escaping @Sendable (
                _ interfaces: [GuestSystemNetworkConfigurator.InterfaceConfiguration],
                _ primaryInterfaceIndex: Int,
                _ dns: MacOSGuestDNSConfiguration?
            ) throws -> GuestSystemNetworkConfigurator.Result = GuestSystemNetworkConfigurator.apply
    ) {
        self.runCommand = runCommand
        self.applySystemConfiguration = applySystemConfiguration
    }

    func apply(_ request: MacOSGuestNetworkConfigurationRequest) throws -> MacOSGuestNetworkConfigurationResult {
        guard !request.interfaces.isEmpty else {
            return .init(interfaces: [], dnsApplied: false, effectiveDNS: nil)
        }

        let interfaceLookup = try Self.parseInterfaceNamesByMAC(
            from: runCommand("/sbin/ifconfig", ["-a"]).stdout
        )

        var resolvedInterfaces: [GuestSystemNetworkConfigurator.InterfaceConfiguration] = []
        var effectiveMTUs: [String: UInt32] = [:]
        for interface in request.interfaces {
            let normalizedMAC = Self.normalizeMACAddress(interface.macAddress)
            guard let interfaceName = interfaceLookup[normalizedMAC] else {
                throw Self.makeError("guest network interface not found for MAC \(interface.macAddress)")
            }
            effectiveMTUs[interfaceName] = try prepareInterface(
                interfaceName: interfaceName,
                requestedMTU: interface.mtu
            )
            resolvedInterfaces.append(
                .init(
                    networkID: interface.networkID,
                    interfaceName: interfaceName,
                    macAddress: interface.macAddress,
                    ipv4Address: interface.ipv4Address,
                    ipv4PrefixLength: interface.ipv4PrefixLength,
                    ipv4Gateway: interface.ipv4Gateway
                )
            )
        }

        let primaryIndex = min(max(request.primaryInterfaceIndex, 0), resolvedInterfaces.count - 1)
        let effectiveConfiguration = try applySystemConfiguration(resolvedInterfaces, primaryIndex, request.dns)
        guard effectiveConfiguration.interfaces.count == resolvedInterfaces.count else {
            throw Self.makeError(
                "SystemConfiguration returned \(effectiveConfiguration.interfaces.count) interfaces; expected \(resolvedInterfaces.count)"
            )
        }

        var appliedInterfaces: [MacOSGuestAppliedNetworkInterface] = []
        for effective in effectiveConfiguration.interfaces {
            guard let effectiveMTU = effectiveMTUs[effective.interfaceName] else {
                throw Self.makeError(
                    "SystemConfiguration returned unexpected interface \(effective.interfaceName)"
                )
            }
            appliedInterfaces.append(
                .init(
                    networkID: effective.networkID,
                    interfaceName: effective.interfaceName,
                    macAddress: effective.macAddress,
                    ipv4Address: effective.ipv4Address,
                    effectiveMTU: effectiveMTU
                )
            )
        }

        return .init(
            interfaces: appliedInterfaces,
            dnsApplied: effectiveConfiguration.effectiveDNS != nil,
            effectiveDNS: effectiveConfiguration.effectiveDNS
        )
    }

    private func prepareInterface(interfaceName: String, requestedMTU: UInt32?) throws -> UInt32 {
        var arguments = [interfaceName]
        if let requestedMTU {
            arguments.append(contentsOf: ["mtu", String(requestedMTU)])
        }
        arguments.append("up")
        _ = try run("/sbin/ifconfig", arguments)

        let output = try run("/sbin/ifconfig", [interfaceName]).stdout
        let effectiveMTU = try Self.parseInterfaceMTU(from: output, interfaceName: interfaceName)
        if let requestedMTU, effectiveMTU != requestedMTU {
            throw Self.makeError(
                "guest network interface \(interfaceName) MTU mismatch: requested \(requestedMTU), effective \(effectiveMTU)"
            )
        }
        return effectiveMTU
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

    static func parseInterfaceMTU(from ifconfigOutput: String, interfaceName: String) throws -> UInt32 {
        guard
            let header = ifconfigOutput.split(separator: "\n", omittingEmptySubsequences: false).first,
            header.hasPrefix("\(interfaceName):")
        else {
            throw makeError("guest network interface status is missing for \(interfaceName)")
        }
        let fields = header.split(whereSeparator: { $0.isWhitespace })
        guard
            let mtuIndex = fields.firstIndex(of: "mtu"),
            fields.indices.contains(mtuIndex + 1),
            let mtu = UInt32(fields[mtuIndex + 1])
        else {
            throw makeError("guest network interface MTU is missing for \(interfaceName)")
        }
        return mtu
    }

    static func normalizeMACAddress(_ macAddress: String) -> String {
        macAddress.lowercased().replacingOccurrences(of: "-", with: ":")
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
