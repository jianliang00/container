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

import Testing

@testable import ContainerK8sKubeProxyMacOS

struct KubeProxyIPv6EgressResolverTests {
    @Test
    func resolvesDefaultRouteWithExactlyOneUsableIPv6Address() throws {
        let resolver = KubeProxyDefaultIPv6EgressResolver(
            commandRunner: { executable, arguments in
                #expect(executable == "/sbin/route")
                #expect(arguments == ["-n", "get", "-inet6", "default"])
                return """
                    route to: default
                    destination: default
                    interface: en0
                    flags: <UP,GATEWAY,DONE,STATIC>
                    """
            },
            interfaceAddressResolver: { interfaceName in
                #expect(interfaceName == "en0")
                return [
                    "::",
                    "::1",
                    "::ffff:192.0.2.10",
                    "fe80::1",
                    "ff02::1",
                    "2001:db8:100:c:203:0:113:208",
                ]
            }
        )

        #expect(
            try resolver.resolveIPv6Egress(
                configuredInterface: nil,
                configuredSourceAddress: nil
            )
                == KubeProxyIPv6Egress(
                    interfaceName: "en0",
                    sourceAddress: "2001:db8:100:c:203:0:113:208"
                )
        )
    }

    @Test
    func requiresExplicitSourceAddressWhenInterfaceHasMultipleUsableAddresses() throws {
        let resolver = KubeProxyDefaultIPv6EgressResolver(
            commandRunner: { _, _ in
                Issue.record("configured interface must bypass default-route lookup")
                return ""
            },
            interfaceAddressResolver: { _ in
                ["fd00::10", "2001:db8:100:c:203:0:113:208"]
            }
        )

        #expect(throws: KubeProxyMacOSError.self) {
            try resolver.resolveIPv6Egress(
                configuredInterface: "en7",
                configuredSourceAddress: nil
            )
        }
        #expect(
            try resolver.resolveIPv6Egress(
                configuredInterface: "en7",
                configuredSourceAddress: "2001:DB8:100:C:203:0:113:208"
            )
                == KubeProxyIPv6Egress(
                    interfaceName: "en7",
                    sourceAddress: "2001:db8:100:c:203:0:113:208"
                )
        )
    }

    @Test
    func rejectsUnassignedOrNonUsableExplicitSourceAddress() {
        let resolver = KubeProxyDefaultIPv6EgressResolver(
            commandRunner: { _, _ in "" },
            interfaceAddressResolver: { _ in ["2001:db8:100:c::1", "fe80::1"] }
        )

        #expect(throws: KubeProxyMacOSError.self) {
            try resolver.resolveIPv6Egress(
                configuredInterface: "en0",
                configuredSourceAddress: "2001:db8:100:c::2"
            )
        }
        #expect(throws: KubeProxyMacOSError.self) {
            try resolver.resolveIPv6Egress(
                configuredInterface: "en0",
                configuredSourceAddress: "fe80::1"
            )
        }
    }

    @Test
    func rejectsAmbiguousDefaultRouteInterface() {
        let resolver = KubeProxyDefaultIPv6EgressResolver(
            commandRunner: { _, _ in
                """
                interface: en0
                interface: en7
                """
            },
            interfaceAddressResolver: { _ in ["fd00::1"] }
        )

        #expect(throws: KubeProxyMacOSError.self) {
            try resolver.resolveIPv6Egress(
                configuredInterface: nil,
                configuredSourceAddress: nil
            )
        }
    }

    @Test
    func rejectsIPv6AddressesThatAreNotReadyForSourceNAT() {
        let resolver = KubeProxyDefaultIPv6EgressResolver(
            commandRunner: { _, _ in "" },
            interfaceAddressResolver: { _ in ["2001:db8:100:c::1"] },
            addressReadinessResolver: { interfaceName, address in
                #expect(interfaceName == "en0")
                #expect(address == "2001:db8:100:c::1")
                return false
            }
        )

        #expect(throws: KubeProxyMacOSError.self) {
            try resolver.resolveIPv6Egress(
                configuredInterface: "en0",
                configuredSourceAddress: "2001:db8:100:c::1"
            )
        }
    }
}
