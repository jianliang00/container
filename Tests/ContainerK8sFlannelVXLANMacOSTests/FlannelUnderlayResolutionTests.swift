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

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelUnderlayResolutionTests {
    @Test
    func resolvesInterfaceByExactNodeInternalIP() throws {
        let manager = FlannelSystemManager { executable, arguments in
            #expect(executable == "/sbin/ifconfig")
            switch arguments {
            case ["-l"]:
                return "en0 en7"
            case ["en0"]:
                return Self.ifconfig(name: "en0", address: "192.168.1.20", mtu: 1500)
            case ["en7"]:
                return Self.ifconfig(name: "en7", address: "10.31.252.24", mtu: 9000)
            default:
                throw FlannelVXLANError.runtime("unexpected command arguments")
            }
        }

        let underlay = try manager.resolveUnderlayInterface(nodeInternalIP: "10.31.252.24")

        #expect(underlay == FlannelUnderlayInterface(name: "en7", ipv4Address: "10.31.252.24", mtu: 9000))
    }

    @Test
    func fallsBackToDefaultIPv4RouteWhenNodeHasNoInternalIP() throws {
        let manager = FlannelSystemManager { executable, arguments in
            switch (executable, arguments) {
            case ("/sbin/route", ["-n", "get", "default"]):
                "route to: default\n  interface: en9\n"
            case ("/sbin/ifconfig", ["en9"]):
                Self.ifconfig(name: "en9", address: "172.20.10.2", mtu: 1500)
            default:
                throw FlannelVXLANError.runtime("unexpected command")
            }
        }

        let underlay = try manager.resolveUnderlayInterface(nodeInternalIP: nil)

        #expect(underlay == FlannelUnderlayInterface(name: "en9", ipv4Address: "172.20.10.2", mtu: 1500))
    }

    @Test
    func refusesAmbiguousNodeInternalIPMatches() {
        let manager = FlannelSystemManager { executable, arguments in
            guard executable == "/sbin/ifconfig" else {
                throw FlannelVXLANError.runtime("default route fallback must not be used")
            }
            switch arguments {
            case ["-l"]:
                return "en4 en5"
            case ["en4"], ["en5"]:
                return Self.ifconfig(name: arguments[0], address: "10.31.252.24", mtu: 1500)
            default:
                throw FlannelVXLANError.runtime("unexpected command arguments")
            }
        }

        #expect(throws: FlannelVXLANError.self) {
            try manager.resolveUnderlayInterface(nodeInternalIP: "10.31.252.24")
        }
    }

    @Test
    func validatesPeerRouteOnSelectedUnderlayInterface() throws {
        let manager = FlannelSystemManager { executable, arguments in
            #expect(executable == "/sbin/route")
            #expect(arguments == ["-n", "get", "10.185.55.8"])
            return "route to: 10.185.55.8\n  gateway: 10.31.252.1\n  interface: en7\n"
        }

        try manager.validateUnderlayRoute(destination: "10.185.55.8", interface: "en7")
    }

    @Test
    func rejectsPeerRouteWithoutAnEgressInterface() {
        let manager = FlannelSystemManager { executable, arguments in
            #expect(executable == "/sbin/route")
            #expect(arguments == ["-n", "get", "10.185.55.8"])
            // macOS route(8) can exit successfully while reporting a missing
            // route only on stderr, leaving stdout empty.
            return ""
        }

        #expect(throws: FlannelVXLANError.self) {
            try manager.validateUnderlayRoute(destination: "10.185.55.8", interface: "en7")
        }
    }

    @Test
    func rejectsPeerRouteOnAnotherInterface() {
        let manager = FlannelSystemManager { _, _ in
            "route to: 10.185.55.8\n  interface: utun0\n"
        }

        #expect(throws: FlannelVXLANError.self) {
            try manager.validateUnderlayRoute(destination: "10.185.55.8", interface: "en7")
        }
    }

    private static func ifconfig(name: String, address: String, mtu: Int) -> String {
        """
        \(name): flags=8863<UP,BROADCAST,RUNNING> mtu \(mtu)
        \tinet \(address) netmask 0xffffff00 broadcast 10.31.252.255
        """
    }
}
