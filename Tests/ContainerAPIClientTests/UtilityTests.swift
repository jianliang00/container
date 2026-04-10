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
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient

struct UtilityTests {

    @Test("Parse simple key-value pairs")
    func testSimpleKeyValuePairs() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["key2"] == "value2")
    }

    @Test("Parse standalone keys")
    func testStandaloneKeys() {
        let result = Utility.parseKeyValuePairs(["standalone"])

        #expect(result["standalone"] == "")
    }

    @Test("Parse empty input")
    func testEmptyInput() {
        let result = Utility.parseKeyValuePairs([])

        #expect(result.isEmpty)
    }

    @Test("Parse mixed format")
    func testMixedFormat() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "standalone", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["standalone"] == "")
        #expect(result["key2"] == "value2")
    }

    @Test("Valid MAC address with colons")
    func testValidMACAddressWithColons() throws {
        try Utility.validMACAddress("02:42:ac:11:00:02")
        try Utility.validMACAddress("AA:BB:CC:DD:EE:FF")
        try Utility.validMACAddress("00:00:00:00:00:00")
        try Utility.validMACAddress("ff:ff:ff:ff:ff:ff")
    }

    @Test("Valid MAC address with hyphens")
    func testValidMACAddressWithHyphens() throws {
        try Utility.validMACAddress("02-42-ac-11-00-02")
        try Utility.validMACAddress("AA-BB-CC-DD-EE-FF")
    }

    @Test("Invalid MAC address format")
    func testInvalidMACAddressFormat() {
        #expect(throws: Error.self) {
            try Utility.validMACAddress("invalid")
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00")  // Too short
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:02:03")  // Too long
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("ZZ:ZZ:ZZ:ZZ:ZZ:ZZ")  // Invalid hex
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:")  // Incomplete
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02.42.ac.11.00.02")  // Wrong separator
        }
    }

    @Test
    func testPublishPortParser() throws {
        let ports = try Parser.publishPorts([
            "127.0.0.1:8000:9080",
            "8080-8179:9000-9099/udp",
        ])
        #expect(ports.count == 2)
        #expect(ports[0].hostAddress.description == "127.0.0.1")
        #expect(ports[0].hostPort == 8000)
        #expect(ports[0].containerPort == 9080)
        #expect(ports[0].proto == .tcp)
        #expect(ports[0].count == 1)
        #expect(ports[1].hostAddress.description == "0.0.0.0")
        #expect(ports[1].hostPort == 8080)
        #expect(ports[1].containerPort == 9000)
        #expect(ports[1].proto == .udp)
        #expect(ports[1].count == 100)
    }

    @Test("Infer runtime from linux platform")
    func testInferRuntimeLinux() throws {
        let platform = Parser.platform(os: "linux", arch: "arm64")
        let runtime = try Utility.resolveRuntimeHandler(platform: platform, explicitRuntime: nil)
        #expect(runtime == "container-runtime-linux")
    }

    @Test("Infer runtime from darwin platform")
    func testInferRuntimeDarwin() throws {
        let platform = Parser.platform(os: "darwin", arch: "arm64")
        let runtime = try Utility.resolveRuntimeHandler(platform: platform, explicitRuntime: nil)
        #expect(runtime == "container-runtime-macos")
    }

    @Test("Runtime conflict between --os and --runtime")
    func testRuntimeConflict() throws {
        let platform = Parser.platform(os: "darwin", arch: "arm64")
        #expect(throws: ContainerizationError.self) {
            _ = try Utility.resolveRuntimeHandler(platform: platform, explicitRuntime: "container-runtime-linux")
        }
    }

    @Test("Management flags do not set os/arch when omitted")
    func testManagementFlagsLeavePlatformUnsetByDefault() throws {
        let flags = try Flags.Management.parse([])
        #expect(flags.os == nil)
        #expect(flags.arch == nil)
    }

    @Test("Auto-detect macOS guest platform from darwin-only image")
    func testAutoDetectMacOSGuestPlatform() throws {
        let override = try Utility.autoDetectedPlatformOverrideIfNeeded(
            availablePlatforms: [Parser.platform(os: "darwin", arch: "arm64")]
        )
        #expect(override == Parser.platform(os: "darwin", arch: "arm64"))
    }

    @Test("Auto-detect does not override linux-only images")
    func testAutoDetectDoesNotOverrideLinuxOnlyImage() throws {
        let override = try Utility.autoDetectedPlatformOverrideIfNeeded(
            availablePlatforms: [
                Parser.platform(os: "linux", arch: "arm64"),
                Parser.platform(os: "linux", arch: "amd64"),
            ]
        )
        #expect(override == nil)
    }

    @Test("Auto-detect rejects mixed linux and darwin images")
    func testAutoDetectRejectsMixedOSImage() throws {
        #expect(throws: ContainerizationError.self) {
            _ = try Utility.autoDetectedPlatformOverrideIfNeeded(
                availablePlatforms: [
                    Parser.platform(os: "linux", arch: "arm64"),
                    Parser.platform(os: "darwin", arch: "arm64"),
                ]
            )
        }
    }

    @Test("macOS guest networking override keeps internal attachments and sanitizes explicit DNS")
    func testResolveMacOSGuestNetworkingUsesOverride() throws {
        let management = try Flags.Management.parse([])
        let attachment = AttachmentConfiguration(
            network: "default",
            options: .init(hostname: "macos-guest")
        )
        let dns = ContainerConfiguration.DNSConfiguration(
            nameservers: ["8.8.8.8"],
            domain: "example.com",
            searchDomains: ["svc.example.com"],
            options: ["debug"]
        )

        let maybeResolved = try Utility.resolveMacOSGuestNetworking(
            containerID: "macos-guest",
            management: management,
            override: .init(networks: [attachment], dns: dns)
        )
        let resolved = try #require(maybeResolved)

        #expect(resolved.networks.count == 1)
        #expect(resolved.networks[0].network == "default")
        #expect(resolved.networks[0].options.hostname == "macos-guest")

        let resolvedDNS = try #require(resolved.dns)
        #expect(resolvedDNS.nameservers == ["8.8.8.8"])
        #expect(resolvedDNS.domain == "example.com")
        #expect(resolvedDNS.searchDomains == ["svc.example.com"])
        #expect(resolvedDNS.options.isEmpty)
    }

    @Test("macOS guest networking override falls back to supported management DNS flags")
    func testResolveMacOSGuestNetworkingBuildsDNSFromManagementFlags() throws {
        var management = try Flags.Management.parse([])
        management.dns.nameservers = ["9.9.9.9"]
        management.dns.domain = "example.internal"
        management.dns.searchDomains = ["svc.example.internal"]

        let maybeResolved = try Utility.resolveMacOSGuestNetworking(
            containerID: "macos-guest",
            management: management,
            override: .init(networks: [])
        )
        let resolved = try #require(maybeResolved)

        let resolvedDNS = try #require(resolved.dns)
        #expect(resolvedDNS.nameservers == ["9.9.9.9"])
        #expect(resolvedDNS.domain == "example.internal")
        #expect(resolvedDNS.searchDomains == ["svc.example.internal"])
        #expect(resolvedDNS.options.isEmpty)
    }

    @Test("macOS guest networking override respects no-dns")
    func testResolveMacOSGuestNetworkingRespectsNoDNS() throws {
        var management = try Flags.Management.parse([])
        management.dnsDisabled = true
        let attachment = AttachmentConfiguration(
            network: "default",
            options: .init(hostname: "macos-guest")
        )

        let maybeResolved = try Utility.resolveMacOSGuestNetworking(
            containerID: "macos-guest",
            management: management,
            override: .init(
                networks: [attachment],
                dns: .init(nameservers: ["1.1.1.1"])
            )
        )
        let resolved = try #require(maybeResolved)

        #expect(resolved.networks.count == 1)
        #expect(resolved.networks[0].options.hostname == "macos-guest")
        #expect(resolved.dns == nil)
    }

    @Test("macOS guest networking remains unset without CLI networking flags")
    func testResolveMacOSGuestNetworkingReturnsNilWithoutOverrideOrFlags() throws {
        let management = try Flags.Management.parse([])

        let resolved = try Utility.resolveMacOSGuestNetworking(
            containerID: "macos-guest",
            management: management,
            override: nil
        )

        #expect(resolved == nil)
    }

    @Test("macOS guest networking parses a single CLI network attachment")
    func testResolveMacOSGuestNetworkingParsesSingleCLINetwork() throws {
        var management = try Flags.Management.parse([])
        management.networks = ["backend,mac=02:42:ac:11:00:02"]

        let maybeResolved = try Utility.resolveMacOSGuestNetworking(
            containerID: "macos-guest",
            management: management,
            override: nil
        )
        let resolved = try #require(maybeResolved)

        #expect(resolved.networks.count == 1)
        #expect(resolved.networks[0].network == "backend")
        #expect(resolved.networks[0].options.hostname == "macos-guest")
        #expect(resolved.networks[0].options.macAddress?.description == "02:42:ac:11:00:02")
        let dns = try #require(resolved.dns)
        #expect(dns.nameservers.isEmpty)
    }

    @Test("macOS guest networking uses default network when only DNS is specified")
    func testResolveMacOSGuestNetworkingUsesDefaultNetworkForDNSOnly() throws {
        var management = try Flags.Management.parse([])
        management.dns.nameservers = ["9.9.9.9"]

        let maybeResolved = try Utility.resolveMacOSGuestNetworking(
            containerID: "macos-guest",
            management: management,
            override: nil
        )
        let resolved = try #require(maybeResolved)

        #expect(resolved.networks.count == 1)
        #expect(resolved.networks[0].network == ClientNetwork.defaultNetworkName)
        let dns = try #require(resolved.dns)
        #expect(dns.nameservers == ["9.9.9.9"])
    }

    @Test("macOS guest networking uses default network when publish is specified")
    func testResolveMacOSGuestNetworkingUsesDefaultNetworkForPublishedPorts() throws {
        var management = try Flags.Management.parse([])
        management.publishPorts = ["127.0.0.1:8080:80"]

        let maybeResolved = try Utility.resolveMacOSGuestNetworking(
            containerID: "macos-guest",
            management: management,
            override: nil
        )
        let resolved = try #require(maybeResolved)

        #expect(resolved.networks.count == 1)
        #expect(resolved.networks[0].network == ClientNetwork.defaultNetworkName)
        #expect(resolved.dns?.nameservers.isEmpty ?? true)
    }

    @Test("macOS published ports reject IPv6 host bindings")
    func testValidateMacOSPublishedPortsRejectIPv6() throws {
        let publishedPorts = try Parser.publishPorts(["[::1]:8080:80"])

        #expect(throws: ContainerizationError.self) {
            try Utility.validateMacOSPublishedPorts(publishedPorts)
        }
    }

    @Test("macOS guest networking rejects unsupported DNS options")
    func testResolveMacOSGuestNetworkingRejectsDNSOptions() throws {
        var management = try Flags.Management.parse([])
        management.dns.options = ["ndots:2"]

        #expect(throws: ContainerizationError.self) {
            _ = try Utility.resolveMacOSGuestNetworking(
                containerID: "macos-guest",
                management: management,
                override: nil
            )
        }
    }

    @Test("macOS guest networking rejects multiple CLI network attachments")
    func testResolveMacOSGuestNetworkingRejectsMultipleNetworks() throws {
        var management = try Flags.Management.parse([])
        management.networks = ["default", "extra"]

        #expect(throws: ContainerizationError.self) {
            _ = try Utility.resolveMacOSGuestNetworking(
                containerID: "macos-guest",
                management: management,
                override: nil
            )
        }
    }

    @Test("macOS guest networking rejects none network")
    func testResolveMacOSGuestNetworkingRejectsNoneNetwork() throws {
        var management = try Flags.Management.parse([])
        management.networks = [ClientNetwork.noNetworkName]

        #expect(throws: ContainerizationError.self) {
            _ = try Utility.resolveMacOSGuestNetworking(
                containerID: "macos-guest",
                management: management,
                override: nil
            )
        }
    }
}
