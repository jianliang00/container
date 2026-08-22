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
    func rejectsDefaultOrBroaderRouteForPodCIDR() {
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

        #expect(throws: KubeProxyMacOSError.self) {
            try defaultRoute.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
        #expect(throws: KubeProxyMacOSError.self) {
            try broaderRoute.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
    }

    @Test
    func rejectsNonBridgePodCIDRInterface() {
        let resolver = KubeProxyDefaultPodIngressInterfaceResolver(
            commandRunner: { _, _ in
                """
                destination: 10.250.34.0
                       mask: 255.255.255.0
                  interface: en0
                      flags: <UP,DONE,CLONING>
                """
            },
            interfaceTypeResolver: { _ in UInt8(IFT_ETHER) }
        )

        #expect(throws: KubeProxyMacOSError.self) {
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

        #expect(throws: KubeProxyMacOSError.self) {
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

        #expect(throws: KubeProxyMacOSError.self) {
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

        #expect(throws: KubeProxyMacOSError.self) {
            try resolver.resolvePodIngressInterface(
                family: .ipv4,
                podCIDR: "10.250.34.0/24"
            )
        }
    }
}
