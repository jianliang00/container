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

struct CNIRequestTests {
    @Test func parsesAddRequestEnvironmentAndStdinConfig() throws {
        let request = try CNIRequest.parse(
            environment: [
                "CNI_COMMAND": "ADD",
                "CNI_CONTAINERID": "container-1",
                "CNI_NETNS": "macvmnet://sandbox/sandbox-1",
                "CNI_IFNAME": "eth0",
                "CNI_ARGS": "K8S_POD_NAMESPACE=default;K8S_POD_NAME=pod-a",
                "CNI_PATH": "/opt/cni/bin:/usr/local/libexec/cni",
            ],
            stdin: Data(
                """
                {
                  "cniVersion": "1.1.0",
                  "name": "kind",
                  "type": "macvmnet",
                  "macvmnetMode": "shared",
                  "ipam": { "type": "host-local" }
                }
                """.utf8
            )
        )

        #expect(request.environment.command == .add)
        #expect(request.environment.containerID == "container-1")
        #expect(request.environment.ifName == "eth0")
        #expect(request.environment.arguments["K8S_POD_NAMESPACE"] == "default")
        #expect(request.environment.path == ["/opt/cni/bin", "/usr/local/libexec/cni"])
        #expect(request.config.cniVersion == "1.1.0")
        #expect(request.config.name == "kind")
        #expect(request.config.type == "macvmnet")
        #expect(request.config.extra["macvmnetMode"] == .string("shared"))
        #expect(request.sandbox?.sandboxID == "sandbox-1")
    }

    @Test func rejectsFilesystemNetnsPathForMacOSGuestSandbox() throws {
        #expect {
            _ = try CNIRequest.parse(
                environment: [
                    "CNI_COMMAND": "ADD",
                    "CNI_CONTAINERID": "container-1",
                    "CNI_NETNS": "/var/run/netns/container-1",
                    "CNI_IFNAME": "eth0",
                ],
                stdin: minimalConfigData()
            )
        } throws: { error in
            error as? CNIError == .invalidSandboxURI("/var/run/netns/container-1")
        }
    }

    @Test func decodesPreviousResultFromConfig() throws {
        let request = try CNIRequest.parse(
            environment: [
                "CNI_COMMAND": "CHECK",
                "CNI_CONTAINERID": "container-1",
                "CNI_NETNS": "macvmnet://sandbox/sandbox-1",
                "CNI_IFNAME": "eth0",
            ],
            stdin: Data(
                """
                {
                  "cniVersion": "1.1.0",
                  "name": "kind",
                  "type": "macvmnet",
                  "prevResult": {
                    "cniVersion": "1.1.0",
                    "interfaces": [{ "name": "eth0", "mac": "02:00:00:00:00:01", "sandbox": "macvmnet://sandbox/sandbox-1" }],
                    "ips": [{ "interface": 0, "address": "192.168.64.2/24", "gateway": "192.168.64.1" }],
                    "routes": [{ "dst": "0.0.0.0/0", "gw": "192.168.64.1" }],
                    "dns": { "nameservers": ["192.168.64.1"], "search": ["default.svc.cluster.local"] }
                  }
                }
                """.utf8
            )
        )

        #expect(request.config.prevResult?.interfaces?.first?.name == "eth0")
        #expect(request.config.prevResult?.ips?.first?.address == "192.168.64.2/24")
        #expect(request.config.prevResult?.routes?.first?.dst == "0.0.0.0/0")
        #expect(request.config.prevResult?.dns?.nameservers == ["192.168.64.1"])
    }

    @Test func rejectsUnsupportedCNIVersion() throws {
        #expect {
            _ = try CNIRequest.parse(
                environment: [
                    "CNI_COMMAND": "ADD",
                    "CNI_CONTAINERID": "container-1",
                    "CNI_NETNS": "macvmnet://sandbox/sandbox-1",
                    "CNI_IFNAME": "eth0",
                ],
                stdin: Data(
                    """
                    {
                      "cniVersion": "0.4.0",
                      "name": "kind",
                      "type": "macvmnet"
                    }
                    """.utf8
                )
            )
        } throws: { error in
            error as? CNIError == .incompatibleCNIVersion("0.4.0")
        }
    }

    @Test func rejectsUnsupportedPluginType() throws {
        #expect {
            _ = try CNIRequest.parse(
                environment: [
                    "CNI_COMMAND": "ADD",
                    "CNI_CONTAINERID": "container-1",
                    "CNI_NETNS": "macvmnet://sandbox/sandbox-1",
                    "CNI_IFNAME": "eth0",
                ],
                stdin: Data(
                    """
                    {
                      "cniVersion": "1.1.0",
                      "name": "kind",
                      "type": "bridge"
                    }
                    """.utf8
                )
            )
        } throws: { error in
            error as? CNIError == .unsupportedPluginType("bridge")
        }
    }

    @Test func makesOperationPlanWithoutCallingNetworking() throws {
        let request = try CNIRequest.parse(
            environment: [
                "CNI_COMMAND": "DEL",
                "CNI_CONTAINERID": "container-1",
                "CNI_NETNS": "macvmnet://sandbox/sandbox-1",
                "CNI_IFNAME": "eth0",
            ],
            stdin: minimalConfigData()
        )

        let plan = MacvmnetOperationPlan(request: request)

        #expect(plan.command == .delete)
        #expect(plan.networkName == "kind")
        #expect(plan.interfaceName == "eth0")
        #expect(plan.sandbox?.rawValue == "macvmnet://sandbox/sandbox-1")
    }

    @Test func allowsDeleteWithoutNetns() throws {
        let request = try CNIRequest.parse(
            environment: [
                "CNI_COMMAND": "DEL",
                "CNI_CONTAINERID": "container-1",
                "CNI_IFNAME": "eth0",
            ],
            stdin: minimalConfigData()
        )

        #expect(request.environment.command == .delete)
        #expect(request.sandbox == nil)
    }
}

private func minimalConfigData() -> Data {
    Data(
        """
        {
          "cniVersion": "1.1.0",
          "name": "kind",
          "type": "macvmnet"
        }
        """.utf8
    )
}
