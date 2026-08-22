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

#if os(macOS)
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import container_macos_guest_agent

struct GuestNetworkConfiguratorTests {
    @Test
    func parsesIfconfigOutputByMACAddress() throws {
        let output = """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \toptions=6463<RXCSUM,TXCSUM,TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
            \tether 02:42:ac:11:00:02
            \tinet6 fe80::1%en0 prefixlen 64 secured scopeid 0x4
            bridge100: flags=41<UP,RUNNING> mtu 1500
            \tether 12:34:56:78:9a:bc
            """

        let mapping = try GuestNetworkConfigurator.parseInterfaceNamesByMAC(from: output)

        #expect(mapping["02:42:ac:11:00:02"] == "en0")
        #expect(mapping["12:34:56:78:9a:bc"] == "bridge100")
    }

    @Test
    func parsesEffectiveInterfaceMTU() throws {
        let output = """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1450
            \tether 02:42:ac:11:00:02
            """

        let mtu = try GuestNetworkConfigurator.parseInterfaceMTU(from: output, interfaceName: "en0")

        #expect(mtu == 1_450)
    }

    @Test
    func appliesNetworkThroughSystemConfigurationAndReportsEffectiveDNS() throws {
        let request = MacOSGuestNetworkConfigurationRequest(
            interfaces: [
                .init(
                    networkID: "default",
                    hostname: "guest-1",
                    macAddress: "02:42:ac:11:00:02",
                    ipv4Address: "192.168.64.2",
                    ipv4PrefixLength: 24,
                    ipv4Gateway: "192.168.64.1",
                    ipv6Address: "fd42:10:244:22::2",
                    ipv6PrefixLength: 64,
                    ipv6Gateway: "fd42:10:244:22::1",
                    mtu: 1_450
                )
            ],
            dns: .init(
                nameservers: ["192.168.64.1"],
                domain: "cluster.local",
                searchDomains: ["svc.cluster.local"],
                options: ["ndots:5"]
            )
        )

        let recorder = CommandRecorder()
        let systemRecorder = SystemConfigurationRecorder()
        let proxyRecorder = DNSProxyRecorder()
        let configurator = GuestNetworkConfigurator(
            runCommand: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                switch (executable, arguments) {
                case ("/sbin/ifconfig", ["-a"]):
                    return .init(
                        stdout: """
                            en0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500
                            \tether 02:42:ac:11:00:02
                            """,
                        stderr: "",
                        exitCode: 0
                    )
                case ("/sbin/ifconfig", ["en0"]):
                    return .init(
                        stdout: "en0: flags=8863<UP,BROADCAST,RUNNING> mtu 1450\n",
                        stderr: "",
                        exitCode: 0
                    )
                default:
                    return .init(stdout: "", stderr: "", exitCode: 0)
                }
            },
            applySystemConfiguration: { interfaces, primaryIndex, dns in
                systemRecorder.record(interfaces: interfaces, primaryIndex: primaryIndex, dns: dns)
                return Self.makeSystemConfigurationResult(interfaces: interfaces, dns: dns)
            },
            configureDNSProxy: { dns in
                proxyRecorder.record(dns)
                return MacOSGuestDNSConfiguration(
                    nameservers: ["127.0.0.1"],
                    domain: dns.domain,
                    searchDomains: dns.searchDomains,
                    options: dns.options
                )
            }
        )

        let result = try configurator.apply(request)

        #expect(result.dnsApplied)
        #expect(result.warnings.isEmpty)
        #expect(result.effectiveDNS?.serviceID == "service-en0")
        #expect(result.effectiveDNS?.interfaceName == "en0")
        #expect(result.effectiveDNS?.nameservers == ["192.168.64.1"])
        #expect(result.effectiveDNS?.domain == "cluster.local")
        #expect(result.effectiveDNS?.searchDomains == ["svc.cluster.local"])
        #expect(result.effectiveDNS?.options == ["ndots:5"])
        #expect(result.interfaces[0].effectiveMTU == 1_450)
        #expect(result.interfaces[0].ipv6Address == "fd42:10:244:22::2/64")

        let invocation = try #require(systemRecorder.invocation())
        #expect(invocation.primaryIndex == 0)
        #expect(invocation.interfaces[0].interfaceName == "en0")
        #expect(invocation.interfaces[0].ipv4Address == "192.168.64.2")
        #expect(invocation.interfaces[0].ipv6Address == "fd42:10:244:22::2")
        #expect(invocation.interfaces[0].ipv6PrefixLength == 64)
        #expect(invocation.interfaces[0].ipv6Gateway == "fd42:10:244:22::1")
        #expect(invocation.dns?.nameservers == ["127.0.0.1"])
        #expect(invocation.dns?.options == ["ndots:5"])
        #expect(proxyRecorder.configuration()?.nameservers == ["192.168.64.1"])

        let commands = recorder.commands()
        #expect(
            commands.contains {
                $0.executable == "/sbin/ifconfig"
                    && $0.arguments == ["en0", "mtu", "1450", "up"]
            })
        #expect(!commands.contains { $0.executable == "/usr/sbin/networksetup" })
        #expect(!commands.contains { $0.executable == "/sbin/route" })
    }

    @Test
    func buildsManualIPv4AndDNSProtocolConfiguration() throws {
        let interface = GuestSystemNetworkConfigurator.InterfaceConfiguration(
            networkID: "default",
            interfaceName: "en0",
            macAddress: "02:42:ac:11:00:02",
            ipv4Address: "192.168.64.2",
            ipv4PrefixLength: 24,
            ipv4Gateway: "192.168.64.1"
        )
        let ipv4 = GuestSystemNetworkConfigurator.ipv4ConfigurationDictionary(for: interface)
        let dns = GuestSystemNetworkConfigurator.dnsConfigurationDictionary(
            for: .init(
                nameservers: ["10.96.0.10"],
                domain: "cluster.local",
                searchDomains: ["default.svc.cluster.local", "svc.cluster.local"],
                options: ["ndots:5", "timeout:2"]
            )
        )

        #expect(ipv4["ConfigMethod"] as? String == "Manual")
        #expect(ipv4["Addresses"] as? [String] == ["192.168.64.2"])
        #expect(ipv4["SubnetMasks"] as? [String] == ["255.255.255.0"])
        #expect(ipv4["Router"] as? String == "192.168.64.1")
        #expect(
            GuestSystemNetworkConfigurator.ipv4ConfigurationDictionary(
                for: interface,
                includeDefaultRoute: false
            )["Router"] == nil
        )
        #expect(dns["ServerAddresses"] as? [String] == ["10.96.0.10"])
        #expect(dns["DomainName"] as? String == "cluster.local")
        #expect(dns["SearchDomains"] as? [String] == ["default.svc.cluster.local", "svc.cluster.local"])
        #expect(dns["Options"] as? String == "ndots:5 timeout:2")
    }

    @Test
    func buildsManualIPv6ProtocolConfiguration() throws {
        let interface = GuestSystemNetworkConfigurator.InterfaceConfiguration(
            networkID: "default",
            interfaceName: "en0",
            macAddress: "02:42:ac:11:00:02",
            ipv4Address: "192.168.64.2",
            ipv4PrefixLength: 24,
            ipv4Gateway: "192.168.64.1",
            ipv6Address: "fd42:10:244:22::2",
            ipv6PrefixLength: 64,
            ipv6Gateway: "fd42:10:244:22::1"
        )

        let primary = try GuestSystemNetworkConfigurator.ipv6ConfigurationDictionary(for: interface)
        let secondary = try GuestSystemNetworkConfigurator.ipv6ConfigurationDictionary(
            for: interface,
            includeDefaultRoute: false
        )

        #expect(primary["ConfigMethod"] as? String == "Manual")
        #expect(primary["Addresses"] as? [String] == ["fd42:10:244:22::2"])
        #expect(primary["PrefixLength"] as? [Int] == [64])
        #expect(primary["Router"] as? String == "fd42:10:244:22::1")
        #expect(secondary["Router"] == nil)
    }

    @Test
    func validatesIPv6RouterFromConfiguredAndGlobalState() throws {
        let interface = Self.makeIPv6Interface()

        for effectiveProperties in [
            Self.makeEffectiveIPv6Properties(),
            Self.makeEffectiveIPv6Properties(router: "fd42:10:244:22::1"),
        ] {
            let address = try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                request: interface,
                serviceID: "service-en0",
                isPrimary: true,
                protocolEnabled: true,
                configuredProperties: Self.makeConfiguredIPv6Properties(),
                setupProperties: Self.makeConfiguredIPv6Properties(),
                effectiveProperties: effectiveProperties,
                globalProperties: Self.makeGlobalIPv6Properties()
            )

            #expect(address == "fd42:10:244:22::2/64")
        }
    }

    @Test
    func rejectsInvalidActiveIPv6AddressPrefixOrInterface() {
        let interface = Self.makeIPv6Interface()
        let invalidStates: [NSDictionary] = [
            [
                "Addresses": ["fd42:10:244:22::3"],
                "PrefixLength": [64],
                "InterfaceName": "en0",
            ],
            [
                "Addresses": ["fd42:10:244:22::2"],
                "PrefixLength": [63],
                "InterfaceName": "en0",
            ],
            [
                "Addresses": ["fd42:10:244:22::2"],
                "PrefixLength": [64],
            ],
            [
                "Addresses": ["fd42:10:244:22::2"],
                "PrefixLength": [64],
                "InterfaceName": "en1",
            ],
            [
                "Addresses": ["fd42:10:244:22::2"],
                "PrefixLength": [64],
                "InterfaceName": "en0",
                "Router": "fd42:10:244:22::9",
            ],
            [
                "Addresses": ["fd42:10:244:22::2", "fd42:10:244:22::3"],
                "PrefixLength": [63, 64],
                "InterfaceName": "en0",
            ],
        ]

        for state in invalidStates {
            #expect(throws: (any Error).self) {
                try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                    request: interface,
                    serviceID: "service-en0",
                    isPrimary: true,
                    protocolEnabled: true,
                    configuredProperties: Self.makeConfiguredIPv6Properties(),
                    setupProperties: Self.makeConfiguredIPv6Properties(),
                    effectiveProperties: state,
                    globalProperties: Self.makeGlobalIPv6Properties()
                )
            }
        }
    }

    @Test
    func rejectsInvalidConfiguredIPv6State() {
        let interface = Self.makeIPv6Interface()

        for configuredProperties: NSDictionary? in [
            nil,
            Self.makeConfiguredIPv6Properties(configMethod: "Automatic"),
            Self.makeConfiguredIPv6Properties(addresses: ["fd42:10:244:22::3"]),
            Self.makeConfiguredIPv6Properties(
                addresses: ["fd42:10:244:22::2", "fd42:10:244:22::3"]
            ),
            Self.makeConfiguredIPv6Properties(prefixLengths: [63]),
            Self.makeConfiguredIPv6Properties(router: nil),
            Self.makeConfiguredIPv6Properties(router: "fd42:10:244:22::9"),
        ] {
            #expect(throws: (any Error).self) {
                try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                    request: interface,
                    serviceID: "service-en0",
                    isPrimary: true,
                    protocolEnabled: true,
                    configuredProperties: configuredProperties,
                    setupProperties: Self.makeConfiguredIPv6Properties(),
                    effectiveProperties: Self.makeEffectiveIPv6Properties(),
                    globalProperties: Self.makeGlobalIPv6Properties()
                )
            }
        }

        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                request: interface,
                serviceID: "service-en0",
                isPrimary: true,
                protocolEnabled: false,
                configuredProperties: Self.makeConfiguredIPv6Properties(),
                setupProperties: Self.makeConfiguredIPv6Properties(),
                effectiveProperties: Self.makeEffectiveIPv6Properties(),
                globalProperties: Self.makeGlobalIPv6Properties()
            )
        }
    }

    @Test
    func rejectsInvalidSetupIPv6State() {
        let interface = Self.makeIPv6Interface()

        for setupProperties: NSDictionary? in [
            nil,
            Self.makeConfiguredIPv6Properties(configMethod: "Automatic"),
            Self.makeConfiguredIPv6Properties(addresses: ["fd42:10:244:22::3"]),
            Self.makeConfiguredIPv6Properties(prefixLengths: [63]),
            Self.makeConfiguredIPv6Properties(router: nil),
            Self.makeConfiguredIPv6Properties(router: "fd42:10:244:22::9"),
        ] {
            #expect(throws: (any Error).self) {
                try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                    request: interface,
                    serviceID: "service-en0",
                    isPrimary: true,
                    protocolEnabled: true,
                    configuredProperties: Self.makeConfiguredIPv6Properties(),
                    setupProperties: setupProperties,
                    effectiveProperties: Self.makeEffectiveIPv6Properties(),
                    globalProperties: Self.makeGlobalIPv6Properties()
                )
            }
        }
    }

    @Test
    func rejectsInvalidActivePrimaryIPv6Route() {
        let interface = Self.makeIPv6Interface()
        let invalidGlobalStates: [NSDictionary?] = [
            nil,
            Self.makeGlobalIPv6Properties(serviceID: "service-en1"),
            Self.makeGlobalIPv6Properties(interfaceName: "en1"),
            Self.makeGlobalIPv6Properties(router: "fd42:10:244:22::9"),
        ]

        for globalState in invalidGlobalStates {
            #expect(throws: (any Error).self) {
                try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                    request: interface,
                    serviceID: "service-en0",
                    isPrimary: true,
                    protocolEnabled: true,
                    configuredProperties: Self.makeConfiguredIPv6Properties(),
                    setupProperties: Self.makeConfiguredIPv6Properties(),
                    effectiveProperties: Self.makeEffectiveIPv6Properties(),
                    globalProperties: globalState
                )
            }
        }
    }

    @Test
    func secondaryIPv6InterfaceMustNotOwnOrConfigureDefaultRoute() throws {
        let interface = Self.makeIPv6Interface(interfaceName: "en1")
        let unrelatedGlobalState = Self.makeGlobalIPv6Properties(
            serviceID: "service-en0",
            interfaceName: "en0"
        )

        let address = try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
            request: interface,
            serviceID: "service-en1",
            isPrimary: false,
            protocolEnabled: true,
            configuredProperties: Self.makeConfiguredIPv6Properties(router: nil),
            setupProperties: Self.makeConfiguredIPv6Properties(router: nil),
            effectiveProperties: Self.makeEffectiveIPv6Properties(interfaceName: "en1"),
            globalProperties: unrelatedGlobalState
        )
        #expect(address == "fd42:10:244:22::2/64")

        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                request: interface,
                serviceID: "service-en1",
                isPrimary: false,
                protocolEnabled: true,
                configuredProperties: Self.makeConfiguredIPv6Properties(),
                setupProperties: Self.makeConfiguredIPv6Properties(router: nil),
                effectiveProperties: Self.makeEffectiveIPv6Properties(interfaceName: "en1"),
                globalProperties: unrelatedGlobalState
            )
        }
        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                request: interface,
                serviceID: "service-en1",
                isPrimary: false,
                protocolEnabled: true,
                configuredProperties: Self.makeConfiguredIPv6Properties(router: nil),
                setupProperties: Self.makeConfiguredIPv6Properties(),
                effectiveProperties: Self.makeEffectiveIPv6Properties(interfaceName: "en1"),
                globalProperties: unrelatedGlobalState
            )
        }
        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                request: interface,
                serviceID: "service-en1",
                isPrimary: false,
                protocolEnabled: true,
                configuredProperties: Self.makeConfiguredIPv6Properties(router: nil),
                setupProperties: Self.makeConfiguredIPv6Properties(router: nil),
                effectiveProperties: Self.makeEffectiveIPv6Properties(
                    interfaceName: "en1",
                    router: "fd42:10:244:22::1"
                ),
                globalProperties: unrelatedGlobalState
            )
        }
        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.validateEnabledIPv6State(
                request: interface,
                serviceID: "service-en1",
                isPrimary: false,
                protocolEnabled: true,
                configuredProperties: Self.makeConfiguredIPv6Properties(router: nil),
                setupProperties: Self.makeConfiguredIPv6Properties(router: nil),
                effectiveProperties: Self.makeEffectiveIPv6Properties(interfaceName: "en1"),
                globalProperties: Self.makeGlobalIPv6Properties(
                    serviceID: "service-en1",
                    interfaceName: "en1"
                )
            )
        }
    }

    @Test
    func rejectsPartialIPv6ProtocolConfiguration() throws {
        let interface = GuestSystemNetworkConfigurator.InterfaceConfiguration(
            networkID: "default",
            interfaceName: "en0",
            macAddress: "02:42:ac:11:00:02",
            ipv4Address: "192.168.64.2",
            ipv4PrefixLength: 24,
            ipv4Gateway: "192.168.64.1",
            ipv6Address: "fd42:10:244:22::2"
        )

        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.ipv6ConfigurationDictionary(for: interface)
        }
    }

    @Test(
        arguments: [
            ("fd42:10:244:22::2", UInt8(80), "fd42:10:244:22::1"),
            ("fd42:10:244:22::2", UInt8(64), "fd42:10:244:23::1"),
            ("fd42:10:244:22::2", UInt8(64), "fd42:10:244:22::2"),
            ("fd42:10:244:22::2", UInt8(64), "fd42:10:244:22::"),
            ("fe80::2", UInt8(64), "fe80::1"),
            ("ff02::2", UInt8(64), "ff02::1"),
        ]
    )
    func rejectsUnsafeIPv6ProtocolConfiguration(
        address: String,
        prefixLength: UInt8,
        gateway: String
    ) {
        let interface = GuestSystemNetworkConfigurator.InterfaceConfiguration(
            networkID: "default",
            interfaceName: "en0",
            macAddress: "02:42:ac:11:00:02",
            ipv4Address: "192.168.64.2",
            ipv4PrefixLength: 24,
            ipv4Gateway: "192.168.64.1",
            ipv6Address: address,
            ipv6PrefixLength: prefixLength,
            ipv6Gateway: gateway
        )

        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.ipv6ConfigurationDictionary(for: interface)
        }
    }

    @Test
    func validatesDisabledIPv6StateAfterCleanup() throws {
        try GuestSystemNetworkConfigurator.validateDisabledIPv6State(
            protocolEnabled: nil,
            configuredProperties: nil,
            effectiveProperties: nil,
            interfaceName: "en0"
        )
        try GuestSystemNetworkConfigurator.validateDisabledIPv6State(
            protocolEnabled: false,
            configuredProperties: nil,
            setupProperties: [
                "ConfigMethod": "LinkLocal",
                "Addresses": ["fe80::1%en0"],
            ],
            effectiveProperties: [
                "Addresses": ["fe80::1%en0"],
                "PrefixLength": [64],
                "InterfaceName": "en0",
            ],
            interfaceName: "en0"
        )
    }

    @Test
    func rejectsDisabledIPv6StateWithResidualAddressOrRouter() {
        let residualStates: [NSDictionary] = [
            [
                "Addresses": ["fe80::1", "fd42:10:244:22::2"],
                "PrefixLength": [64, 64],
                "InterfaceName": "en0",
            ],
            [
                "Addresses": ["fe80::1"],
                "PrefixLength": [64],
                "Router": "fe80::ffff%en0",
                "InterfaceName": "en0",
            ],
        ]

        for residualState in residualStates {
            #expect(throws: (any Error).self) {
                try GuestSystemNetworkConfigurator.validateDisabledIPv6State(
                    protocolEnabled: false,
                    configuredProperties: nil,
                    effectiveProperties: residualState,
                    interfaceName: "en0"
                )
            }
        }
    }

    @Test
    func rejectsDisabledIPv6StateWithStaleSetup() {
        let residualSetupStates: [NSDictionary] = [
            ["ConfigMethod": "Manual"],
            ["Addresses": ["fd42:10:244:22::2"]],
            ["Router": "fd42:10:244:22::1"],
        ]

        for setupState in residualSetupStates {
            #expect(throws: (any Error).self) {
                try GuestSystemNetworkConfigurator.validateDisabledIPv6State(
                    protocolEnabled: false,
                    configuredProperties: nil,
                    setupProperties: setupState,
                    effectiveProperties: nil,
                    interfaceName: "en0"
                )
            }
        }
    }

    @Test
    func rejectsDisabledIPv6StateWithDefaultRouteOnInterface() throws {
        let unrelatedGlobalState = Self.makeGlobalIPv6Properties(
            serviceID: "service-en1",
            interfaceName: "en1"
        )
        try GuestSystemNetworkConfigurator.validateDisabledIPv6State(
            protocolEnabled: false,
            configuredProperties: nil,
            effectiveProperties: nil,
            serviceID: "service-en0",
            interfaceName: "en0",
            globalProperties: unrelatedGlobalState
        )

        for globalState in [
            Self.makeGlobalIPv6Properties(serviceID: "service-en0", interfaceName: "en1"),
            Self.makeGlobalIPv6Properties(serviceID: "service-en1", interfaceName: "en0"),
        ] {
            #expect(throws: (any Error).self) {
                try GuestSystemNetworkConfigurator.validateDisabledIPv6State(
                    protocolEnabled: false,
                    configuredProperties: nil,
                    effectiveProperties: nil,
                    serviceID: "service-en0",
                    interfaceName: "en0",
                    globalProperties: globalState
                )
            }
        }
    }

    @Test
    func rejectsDisabledIPv6StateWithEnabledOrConfiguredProtocol() {
        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.validateDisabledIPv6State(
                protocolEnabled: true,
                configuredProperties: nil,
                effectiveProperties: nil,
                interfaceName: "en0"
            )
        }
        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.validateDisabledIPv6State(
                protocolEnabled: false,
                configuredProperties: ["ConfigMethod": "Manual"],
                effectiveProperties: nil,
                interfaceName: "en0"
            )
        }
    }

    @Test
    func validatesDNSFromActiveSystemConfigurationState() throws {
        let requested = MacOSGuestDNSConfiguration(
            nameservers: ["10.96.0.10"],
            domain: nil,
            searchDomains: ["default.svc.cluster.local", "svc.cluster.local", "cluster.local"],
            options: ["ndots:5"]
        )
        let properties: NSDictionary = [
            "ServerAddresses": ["10.96.0.10"],
            "SearchDomains": ["default.svc.cluster.local", "svc.cluster.local", "cluster.local"],
            "Options": "ndots:5",
        ]

        let effective = try GuestSystemNetworkConfigurator.effectiveDNSConfiguration(
            serviceID: "service-1",
            interfaceName: "en0",
            requested: requested,
            configuredProperties: properties,
            effectiveProperties: properties
        )

        #expect(effective.serviceID == "service-1")
        #expect(effective.interfaceName == "en0")
        #expect(effective.nameservers == ["10.96.0.10"])
        #expect(effective.options == ["ndots:5"])
    }

    @Test
    func rejectsDNSThatIsNotEffectiveInSystemConfiguration() throws {
        let requested = MacOSGuestDNSConfiguration(
            nameservers: ["10.96.0.10"],
            domain: nil,
            searchDomains: ["cluster.local"],
            options: ["ndots:5"]
        )
        let configuredProperties: NSDictionary = [
            "ServerAddresses": ["10.96.0.10"],
            "SearchDomains": ["cluster.local"],
            "Options": "ndots:5",
        ]
        let effectiveProperties: NSDictionary = [
            "ServerAddresses": ["192.168.64.1"],
            "SearchDomains": ["cluster.local"],
            "Options": "ndots:5",
        ]

        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.effectiveDNSConfiguration(
                serviceID: "service-1",
                interfaceName: "en0",
                requested: requested,
                configuredProperties: configuredProperties,
                effectiveProperties: effectiveProperties
            )
        }
    }

    @Test
    func rejectsDNSThatWasNotPersistedInSystemConfiguration() throws {
        let requested = MacOSGuestDNSConfiguration(
            nameservers: ["10.96.0.10"],
            domain: nil,
            searchDomains: ["cluster.local"],
            options: ["ndots:5"]
        )
        let configuredProperties: NSDictionary = [
            "ServerAddresses": ["192.168.64.1"],
            "SearchDomains": ["cluster.local"],
            "Options": "ndots:5",
        ]
        let effectiveProperties: NSDictionary = [
            "ServerAddresses": ["10.96.0.10"],
            "SearchDomains": ["cluster.local"],
            "Options": "ndots:5",
        ]

        #expect(throws: (any Error).self) {
            try GuestSystemNetworkConfigurator.effectiveDNSConfiguration(
                serviceID: "service-1",
                interfaceName: "en0",
                requested: requested,
                configuredProperties: configuredProperties,
                effectiveProperties: effectiveProperties
            )
        }
    }

    @Test
    func rejectsEffectiveMTUThatDoesNotMatchRequest() throws {
        let request = MacOSGuestNetworkConfigurationRequest(
            interfaces: [
                .init(
                    networkID: "default",
                    hostname: "guest-1",
                    macAddress: "02:42:ac:11:00:02",
                    ipv4Address: "192.168.64.2",
                    ipv4PrefixLength: 24,
                    ipv4Gateway: "192.168.64.1",
                    mtu: 1_450
                )
            ],
            dns: nil
        )
        let configurator = GuestNetworkConfigurator(
            runCommand: { executable, arguments in
                switch (executable, arguments) {
                case ("/sbin/ifconfig", ["-a"]):
                    return .init(
                        stdout: "en0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tether 02:42:ac:11:00:02\n",
                        stderr: "",
                        exitCode: 0
                    )
                case ("/sbin/ifconfig", ["en0"]):
                    return .init(
                        stdout: "en0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n",
                        stderr: "",
                        exitCode: 0
                    )
                default:
                    return .init(stdout: "", stderr: "", exitCode: 0)
                }
            },
            applySystemConfiguration: { interfaces, _, dns in
                Self.makeSystemConfigurationResult(interfaces: interfaces, dns: dns)
            }
        )

        #expect(throws: (any Error).self) {
            try configurator.apply(request)
        }
    }
}

extension GuestNetworkConfiguratorTests {
    private static func makeIPv6Interface(
        interfaceName: String = "en0"
    ) -> GuestSystemNetworkConfigurator.InterfaceConfiguration {
        GuestSystemNetworkConfigurator.InterfaceConfiguration(
            networkID: "default",
            interfaceName: interfaceName,
            macAddress: "02:42:ac:11:00:02",
            ipv4Address: "192.168.64.2",
            ipv4PrefixLength: 24,
            ipv4Gateway: "192.168.64.1",
            ipv6Address: "fd42:10:244:22::2",
            ipv6PrefixLength: 64,
            ipv6Gateway: "fd42:10:244:22::1"
        )
    }

    private static func makeConfiguredIPv6Properties(
        configMethod: String = "Manual",
        addresses: [String] = ["fd42:10:244:22::2"],
        prefixLengths: [Int] = [64],
        router: String? = "fd42:10:244:22::1"
    ) -> NSDictionary {
        var properties: [String: Any] = [
            "ConfigMethod": configMethod,
            "Addresses": addresses,
            "PrefixLength": prefixLengths,
        ]
        properties["Router"] = router
        return properties as NSDictionary
    }

    private static func makeEffectiveIPv6Properties(
        interfaceName: String = "en0",
        router: String? = nil
    ) -> NSDictionary {
        var properties: [String: Any] = [
            "Addresses": ["fd42:10:244:22::2"],
            "PrefixLength": [64],
            "InterfaceName": interfaceName,
        ]
        properties["Router"] = router
        return properties as NSDictionary
    }

    private static func makeGlobalIPv6Properties(
        serviceID: String = "service-en0",
        interfaceName: String = "en0",
        router: String = "fd42:10:244:22::1"
    ) -> NSDictionary {
        [
            "PrimaryService": serviceID,
            "PrimaryInterface": interfaceName,
            "Router": router,
        ]
    }

    private static func makeSystemConfigurationResult(
        interfaces: [GuestSystemNetworkConfigurator.InterfaceConfiguration],
        dns: MacOSGuestDNSConfiguration?
    ) -> GuestSystemNetworkConfigurator.Result {
        let applied = interfaces.map { interface in
            GuestSystemNetworkConfigurator.AppliedInterface(
                networkID: interface.networkID,
                interfaceName: interface.interfaceName,
                macAddress: interface.macAddress,
                ipv4Address: "\(interface.ipv4Address)/\(interface.ipv4PrefixLength)",
                ipv6Address: interface.ipv6Address.flatMap { address in
                    interface.ipv6PrefixLength.map { "\(address)/\($0)" }
                }
            )
        }
        let effectiveDNS = dns.map {
            MacOSGuestEffectiveDNSConfiguration(
                serviceID: "service-\(interfaces[0].interfaceName)",
                interfaceName: interfaces[0].interfaceName,
                nameservers: $0.nameservers,
                domain: $0.domain,
                searchDomains: $0.searchDomains,
                options: $0.options
            )
        }
        return .init(interfaces: applied, effectiveDNS: effectiveDNS)
    }

    private final class SystemConfigurationRecorder: @unchecked Sendable {
        struct Invocation: Sendable {
            let interfaces: [GuestSystemNetworkConfigurator.InterfaceConfiguration]
            let primaryIndex: Int
            let dns: MacOSGuestDNSConfiguration?
        }

        private let lock = NSLock()
        private var stored: Invocation?

        func record(
            interfaces: [GuestSystemNetworkConfigurator.InterfaceConfiguration],
            primaryIndex: Int,
            dns: MacOSGuestDNSConfiguration?
        ) {
            lock.lock()
            defer { lock.unlock() }
            stored = .init(interfaces: interfaces, primaryIndex: primaryIndex, dns: dns)
        }

        func invocation() -> Invocation? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class CommandRecorder: @unchecked Sendable {
        struct Command: Equatable {
            let executable: String
            let arguments: [String]
        }

        private let lock = NSLock()
        private var stored: [Command] = []

        func record(executable: String, arguments: [String]) {
            lock.lock()
            defer { lock.unlock() }
            stored.append(.init(executable: executable, arguments: arguments))
        }

        func commands() -> [Command] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class DNSProxyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: MacOSGuestDNSConfiguration?

        func record(_ dns: MacOSGuestDNSConfiguration) {
            lock.lock()
            defer { lock.unlock() }
            stored = dns
        }

        func configuration() -> MacOSGuestDNSConfiguration? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
#endif
