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
import Testing

@testable import ContainerCNIMacvmnet

struct CNIResultTests {
    @Test func encodesSpec110ResultShape() throws {
        let result = CNIResult(
            interfaces: [
                CNIInterface(name: "eth0", mac: "02:00:00:00:00:01", sandbox: "macvmnet://sandbox/sandbox-1")
            ],
            ips: [
                CNIIPConfig(interface: 0, address: "192.168.64.2/24", gateway: "192.168.64.1"),
                CNIIPConfig(interface: 0, address: "fd00::2/64", gateway: "fd00::1"),
            ],
            routes: [
                CNIRoute(dst: "0.0.0.0/0", gw: "192.168.64.1", mtu: 1500)
            ],
            dns: CNIDNS(nameservers: ["192.168.64.1"], domain: "cluster.local", search: ["svc.cluster.local"], options: ["ndots:5"])
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CNIResult.self, from: data)

        #expect(decoded.cniVersion == "1.1.0")
        #expect(decoded.interfaces?.first?.sandbox == "macvmnet://sandbox/sandbox-1")
        #expect(decoded.ips?.count == 2)
        #expect(decoded.routes?.first?.mtu == 1500)
        #expect(decoded.dns?.options == ["ndots:5"])
    }

    @Test func encodesSupportedVersionsForVersionCommand() throws {
        let data = try JSONEncoder().encode(CNIVersionResult())
        let decoded = try JSONDecoder().decode(CNIVersionResult.self, from: data)

        #expect(decoded.cniVersion == "1.1.0")
        #expect(decoded.supportedVersions == ["1.1.0"])
    }

    @Test func encodesStableCNIErrorResponse() throws {
        let response = CNIErrorResponse(
            error: CNIError.backendUnavailable("STATUS is not ready: container network API health checks are not implemented")
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CNIErrorResponse.self, from: data)

        #expect(decoded.cniVersion == "1.1.0")
        #expect(decoded.code == 100)
        #expect(decoded.msg == "STATUS is not ready: container network API health checks are not implemented")
        #expect(decoded.details == nil)
    }
}
