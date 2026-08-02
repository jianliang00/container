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

struct KubeProxyEgressInterfaceResolverTests {
    @Test
    func resolvesDefaultIPv4RouteInterfaceWithoutUsingAShell() throws {
        let resolver = KubeProxyDefaultIPv4EgressInterfaceResolver { executable, arguments in
            #expect(executable == "/sbin/route")
            #expect(arguments == ["-n", "get", "default"])
            return """
                       route to: default
                    destination: default
                      interface: en8
                """
        }

        #expect(try resolver.resolveDefaultIPv4EgressInterface() == "en8")
    }

    @Test
    func refusesMissingOrAmbiguousDefaultRouteInterface() {
        let missing = KubeProxyDefaultIPv4EgressInterfaceResolver { _, _ in
            "route to: default\n"
        }
        let ambiguous = KubeProxyDefaultIPv4EgressInterfaceResolver { _, _ in
            "interface: en0\ninterface: en7\n"
        }

        #expect(throws: KubeProxyMacOSError.self) {
            try missing.resolveDefaultIPv4EgressInterface()
        }
        #expect(throws: KubeProxyMacOSError.self) {
            try ambiguous.resolveDefaultIPv4EgressInterface()
        }
    }
}
