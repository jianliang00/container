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

import Darwin
import Testing

@testable import ContainerK8sKubeProxyMacOS

struct KubeProxyPodIngressInterfaceResolverTests {
    @Test
    func readsBridgeTypeFromInterfaceDataInsteadOfLinkAddress() {
        #expect(
            linkInterfaceType(
                socketType: UInt8(IFT_ETHER),
                interfaceDataType: UInt8(IFT_BRIDGE)
            ) == UInt8(IFT_BRIDGE)
        )
    }

    @Test
    func doesNotTrustBridgeTypeFromLinkAddress() {
        #expect(
            linkInterfaceType(
                socketType: UInt8(IFT_BRIDGE),
                interfaceDataType: UInt8(IFT_ETHER)
            ) == UInt8(IFT_ETHER)
        )
    }

    @Test
    func requiresInterfaceDataForLinkType() {
        #expect(linkInterfaceType(socketType: UInt8(IFT_BRIDGE), interfaceDataType: nil) == nil)
    }

    private func linkInterfaceType(socketType: UInt8, interfaceDataType: UInt8?) -> UInt8? {
        var linkAddress = sockaddr_dl()
        linkAddress.sdl_family = UInt8(AF_LINK)
        linkAddress.sdl_type = socketType
        var address = ifaddrs()

        return withUnsafeMutablePointer(to: &linkAddress) { linkAddressPointer in
            address.ifa_addr = UnsafeMutableRawPointer(linkAddressPointer)
                .assumingMemoryBound(to: sockaddr.self)
            guard let interfaceDataType else {
                address.ifa_data = nil
                return KubeProxyDefaultPodIngressInterfaceResolver.linkInterfaceType(address)
            }
            var interfaceData = if_data()
            interfaceData.ifi_type = interfaceDataType
            return withUnsafeMutablePointer(to: &interfaceData) { interfaceDataPointer in
                address.ifa_data = UnsafeMutableRawPointer(interfaceDataPointer)
                return KubeProxyDefaultPodIngressInterfaceResolver.linkInterfaceType(address)
            }
        }
    }

    @Test
    func resolvesExactDirectIPv4PodCIDRBridgeRoute() throws {
        let resolver = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { executable, arguments in
                #expect(executable == "/sbin/route")
                switch arguments {
                case ["-n", "get", "-inet", "10.250.34.2"]:
                    return """
                               route to: 10.250.34.2
                            destination: 10.250.34.2
                              interface: bridge100
                                  flags: <UP,HOST,DONE,LLINFO,WASCLONED,IFSCOPE,IFREF>
                        """
                case ["-n", "get", "-inet", "10.250.34.0/24"]:
                    return """
                               route to: 10.250.34.0
                            destination: 10.250.34.0
                                   mask: 255.255.255.0
                              interface: bridge100
                                  flags: <UP,DONE,CLONING>
                        """
                case ["-n", "get", "-inet", "10.250.34.0"]:
                    Issue.record("must query the canonical PodCIDR instead of its locally occupied lower address")
                    return """
                               route to: 10.250.34.0
                            destination: 10.250.34.0
                              interface: utun4
                                  flags: <UP,HOST,DONE,LOCAL>
                        """
                default:
                    Issue.record("unexpected route arguments: \(arguments)")
                    return ""
                }
            },
            interfaceTypeResolver: { interfaceName in
                #expect(interfaceName == "bridge100")
                return UInt8(IFT_BRIDGE)
            }
        )

        #expect(
            try resolver.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            ) == "bridge100"
        )
    }

    @Test
    func resolvesExactDirectIPv6PodCIDRBridgeRoute() throws {
        let resolver = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { executable, arguments in
                #expect(executable == "/sbin/route")
                switch arguments {
                case ["-n", "get", "-inet6", "fd42:10:244:22::2"]:
                    return """
                               route to: fd42:10:244:22::2
                            destination: fd42:10:244:22::
                                   mask: ffff:ffff:ffff:ffff::
                              interface: bridge100
                                  flags: <UP,DONE,CLONING>
                        """
                case ["-n", "get", "-inet6", "fd42:10:244:22::/64"]:
                    return """
                               route to: fd42:10:244:22::
                            destination: fd42:10:244:22::
                                   mask: ffff:ffff:ffff:ffff::
                              interface: bridge100
                                  flags: <UP,DONE,CLONING>
                        """
                case ["-n", "get", "-inet6", "fd42:10:244:22::"]:
                    Issue.record("must query the canonical PodCIDR instead of its locally occupied lower address")
                    return """
                               route to: fd42:10:244:22::
                            destination: fd42:10:244:22::
                              interface: lo0
                                  flags: <UP,HOST,DONE,LLINFO,LOCAL>
                        """
                default:
                    Issue.record("unexpected route arguments: \(arguments)")
                    return ""
                }
            },
            interfaceTypeResolver: { _ in UInt8(IFT_BRIDGE) }
        )

        #expect(
            try resolver.resolvePodIngressInterface(
                family: .ipv6,
                podCIDR: "fd42:10:244:22::/64"
            ) == "bridge100"
        )
    }

    @Test
    func reportsDefaultFallbackAsUnavailableAndRejectsBroaderDirectRoute() {
        let defaultRoute = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, _ in
                """
                destination: default
                       mask: default
                    gateway: 192.168.1.1
                  interface: en0
                      flags: <UP,GATEWAY,DONE,STATIC>
                """
            },
            interfaceTypeResolver: { _ in UInt8(IFT_ETHER) }
        )
        let broaderRoute = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, _ in
                """
                destination: 10.0.0.0
                       mask: 255.0.0.0
                  interface: bridge100
                      flags: <UP,DONE,CLONING>
                """
            },
            interfaceTypeResolver: { _ in UInt8(IFT_BRIDGE) }
        )
        let ipv6DefaultRoute = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, _ in
                """
                destination: ::
                       mask: default
                    gateway: fe80::1%en0
                  interface: en0
                      flags: <UP,GATEWAY,DONE,PRCLONING,GLOBAL>
                """
            },
            interfaceTypeResolver: { _ in UInt8(IFT_ETHER) }
        )

        #expect(throws: KubeProxyPodIngressRouteTransitionError.unavailable(.ipv4)) {
            try defaultRoute.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
        #expect(
            throws: KubeProxyMacOSError.applyFailed(
                "route to local IPv4 PodCIDR does not cover the canonical PodCIDR exactly"
            )
        ) {
            try broaderRoute.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
        #expect(throws: KubeProxyPodIngressRouteTransitionError.unavailable(.ipv6)) {
            try ipv6DefaultRoute.resolvePodIngressInterface(
                family: .ipv6,
                podCIDR: "fd42:10:244:22::/64"
            )
        }
    }

    @Test(arguments: [true, false])
    func reportsUnavailableProbeOrNetworkLookupAsPending(failProbeLookup: Bool) {
        let resolver = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, arguments in
                let isProbeLookup = arguments.last == "10.250.34.2"
                if isProbeLookup == failProbeLookup {
                    throw KubeProxyRouteLookupUnavailableError(status: 1, message: "not in table")
                }
                return """
                    destination: \(isProbeLookup ? "10.250.34.2" : "10.250.34.0")
                           mask: \(isProbeLookup ? "255.255.255.255" : "255.255.255.0")
                      interface: bridge100
                          flags: <UP,\(isProbeLookup ? "HOST," : "")DONE,CLONING>
                    """
            },
            interfaceTypeResolver: { _ in UInt8(IFT_BRIDGE) }
        )

        #expect(throws: KubeProxyPodIngressRouteTransitionError.unavailable(.ipv4)) {
            try resolver.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
    }

    @Test
    func recognizesOnlyVerifiedNotInTableCommandResultAsUnavailable() {
        let notInTable = "route: writing to routing socket: not in table\n"
        #expect(
            throws: KubeProxyRouteLookupUnavailableError(
                status: 0,
                message: "route: writing to routing socket: not in table"
            )
        ) {
            try KubeProxyDefaultPodIngressInterfaceResolver.checkedCommandOutput(
                status: 0,
                output: "",
                errorOutput: notInTable
            )
        }

        #expect(
            throws: KubeProxyMacOSError.applyFailed(
                "failed to inspect the local PodCIDR route with status 64: route: usage error"
            )
        ) {
            try KubeProxyDefaultPodIngressInterfaceResolver.checkedCommandOutput(
                status: 64,
                output: "",
                errorOutput: "route: usage error\n"
            )
        }

        #expect(
            throws: KubeProxyMacOSError.applyFailed(
                "failed to inspect the local PodCIDR route with status 64: route: writing to routing socket: not in table"
            )
        ) {
            try KubeProxyDefaultPodIngressInterfaceResolver.checkedCommandOutput(
                status: 64,
                output: "",
                errorOutput: notInTable
            )
        }

        #expect(
            throws: KubeProxyMacOSError.applyFailed(
                "failed to inspect the local PodCIDR route with status 0: route: routing socket unavailable"
            )
        ) {
            try KubeProxyDefaultPodIngressInterfaceResolver.checkedCommandOutput(
                status: 0,
                output: "",
                errorOutput: "route: routing socket unavailable\n"
            )
        }

        #expect(
            throws: KubeProxyMacOSError.applyFailed(
                "failed to inspect the local PodCIDR route with status 0: route: writing to routing socket: not in table"
            )
        ) {
            try KubeProxyDefaultPodIngressInterfaceResolver.checkedCommandOutput(
                status: 0,
                output: "unexpected route output\n",
                errorOutput: notInTable
            )
        }
    }

    @Test
    func keepsUnexpectedRouteCommandFailureHard() {
        let expected = KubeProxyMacOSError.applyFailed("route inspection failed")
        let resolver = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, _ in throw expected },
            interfaceTypeResolver: { _ in UInt8(IFT_BRIDGE) }
        )

        #expect(throws: expected) {
            try resolver.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
    }

    @Test
    func rejectsNonBridgeTypeEvenWhenInterfaceNameLooksLikeBridge() {
        let resolver = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, _ in
                """
                destination: 10.250.34.0
                       mask: 255.255.255.0
                  interface: bridge100
                      flags: <UP,DONE,CLONING>
                """
            },
            interfaceTypeResolver: { _ in UInt8(IFT_ETHER) }
        )

        #expect(
            throws: KubeProxyMacOSError.applyFailed(
                "local IPv4 PodCIDR route interface bridge100 is not a bridge"
            )
        ) {
            try resolver.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
    }

    @Test
    func rejectsProbeAndNetworkRoutesOnDifferentInterfaces() {
        let resolver = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, arguments in
                let interfaceName = arguments.last == "10.250.34.2" ? "bridge100" : "bridge101"
                return """
                    destination: 10.250.34.0
                           mask: 255.255.255.0
                      interface: \(interfaceName)
                          flags: <UP,DONE,CLONING>
                    """
            },
            interfaceTypeResolver: { _ in UInt8(IFT_BRIDGE) }
        )

        #expect(
            throws: KubeProxyMacOSError.applyFailed(
                "local IPv4 PodCIDR probe and network routes use different interfaces"
            )
        ) {
            try resolver.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
    }

    @Test
    func rejectsHostRouteWithoutExactParentPodCIDRRoute() {
        let resolver = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, arguments in
                switch arguments.last {
                case "10.250.34.2":
                    """
                    destination: 10.250.34.2
                      interface: bridge100
                          flags: <UP,HOST,DONE,LLINFO,WASCLONED,IFSCOPE,IFREF>
                    """
                case "10.250.34.0/24":
                    """
                    destination: 10.250.34.0
                      interface: bridge100
                          flags: <UP,HOST,DONE,LOCAL>
                    """
                default:
                    ""
                }
            },
            interfaceTypeResolver: { _ in UInt8(IFT_BRIDGE) }
        )

        #expect(
            throws: KubeProxyMacOSError.applyFailed(
                "route to local IPv4 PodCIDR does not cover the canonical PodCIDR exactly"
            )
        ) {
            try resolver.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
    }

    @Test
    func rejectsGatewayParentPodCIDRRoute() {
        let resolver = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, arguments in
                let isParentLookup = arguments.last == "10.250.34.0/24"
                return """
                    destination: \(isParentLookup ? "10.250.34.0" : "10.250.34.2")
                           mask: \(isParentLookup ? "255.255.255.0" : "255.255.255.255")
                      interface: bridge100
                          flags: <UP,\(isParentLookup ? "GATEWAY," : "HOST,")DONE,STATIC>
                    """
            },
            interfaceTypeResolver: { _ in UInt8(IFT_BRIDGE) }
        )

        #expect(
            throws: KubeProxyMacOSError.applyFailed(
                "local IPv4 PodCIDR route unexpectedly uses a gateway"
            )
        ) {
            try resolver.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
    }
}
