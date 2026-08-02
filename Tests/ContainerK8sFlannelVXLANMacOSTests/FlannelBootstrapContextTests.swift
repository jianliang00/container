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

@Suite(.serialized)
struct FlannelBootstrapContextTests {
    @Test func rootServiceContextDoesNotQueryOrReexecute() throws {
        let context = FlannelBootstrapContext(
            managerUserID: {
                Issue.record("root service context must not query launchctl manageruid")
                return 501
            },
            reexecute: { _, _, _, _ in
                Issue.record("root service context must not re-execute")
                return 1
            }
        )

        let outcome = try context.ensure(
            containerServiceUserID: 0,
            executablePath: "/usr/local/bin/container-flannel-vxlan-macos",
            arguments: ["--config", "/etc/kubernetes/flannel-vxlan-macos.conf"]
        )

        #expect(outcome == .ready)
    }

    @Test func matchingBootstrapContextContinuesCurrentProcess() throws {
        let context = FlannelBootstrapContext(
            managerUserID: { 501 },
            reexecute: { _, _, _, _ in
                Issue.record("matching bootstrap context must not re-execute")
                return 1
            }
        )

        let outcome = try context.ensure(
            containerServiceUserID: 501,
            executablePath: "/usr/local/bin/container-flannel-vxlan-macos",
            arguments: ["--config", "/etc/kubernetes/flannel-vxlan-macos.conf"]
        )

        #expect(outcome == .ready)
    }

    @Test func mismatchedBootstrapContextReexecutesWithOriginalArguments() throws {
        var recordedUserID: Int?
        var recordedExecutablePath: String?
        var recordedArguments: [String]?
        var recordedEnvironment: [String: String]?
        let context = FlannelBootstrapContext(
            managerUserID: { 0 },
            reexecute: { userID, executablePath, arguments, environment in
                recordedUserID = userID
                recordedExecutablePath = executablePath
                recordedArguments = arguments
                recordedEnvironment = environment
                return 37
            }
        )

        let outcome = try context.ensure(
            containerServiceUserID: 501,
            executablePath: "/usr/local/bin/container-flannel-vxlan-macos",
            arguments: [
                "--config", "/etc/kubernetes/flannel-vxlan-macos.conf", "--purge-network",
            ],
            environment: ["TEST_KEY": "test-value"]
        )

        #expect(outcome == .reexecuted(exitCode: 37))
        #expect(recordedUserID == 501)
        #expect(recordedExecutablePath == "/usr/local/bin/container-flannel-vxlan-macos")
        #expect(
            recordedArguments == [
                "--config", "/etc/kubernetes/flannel-vxlan-macos.conf", "--purge-network",
            ]
        )
        #expect(recordedEnvironment?["TEST_KEY"] == "test-value")
        #expect(recordedEnvironment?["_CONTAINER_FLANNEL_VXLAN_MACOS_BOOTSTRAP_UID"] == "501")
    }

    @Test func markerPreventsRecursiveReexecution() throws {
        let context = FlannelBootstrapContext(
            managerUserID: { 0 },
            reexecute: { _, _, _, _ in
                Issue.record("marked process must not re-execute again")
                return 1
            }
        )

        #expect(
            throws: FlannelVXLANError.runtime(
                "launchctl asuser did not enter bootstrap context for uid 501"
            )
        ) {
            try context.ensure(
                containerServiceUserID: 501,
                executablePath: "/usr/local/bin/container-flannel-vxlan-macos",
                arguments: ["--withdraw"],
                environment: ["_CONTAINER_FLANNEL_VXLAN_MACOS_BOOTSTRAP_UID": "501"]
            )
        }
    }

    @Test func reexecutionErrorIsPropagated() throws {
        let context = FlannelBootstrapContext(
            managerUserID: { 0 },
            reexecute: { _, _, _, _ in
                throw TestReexecutionError.failed
            }
        )

        #expect(throws: TestReexecutionError.failed) {
            try context.ensure(
                containerServiceUserID: 501,
                executablePath: "/usr/local/bin/container-flannel-vxlan-macos",
                arguments: []
            )
        }
    }

    @Test func negativeUserIDIsRejectedBeforeLaunchctl() throws {
        let context = FlannelBootstrapContext(
            managerUserID: {
                Issue.record("invalid uid must not query launchctl manageruid")
                return 0
            },
            reexecute: { _, _, _, _ in
                Issue.record("invalid uid must not re-execute")
                return 1
            }
        )

        #expect(
            throws: FlannelVXLANError.invalidConfiguration(
                "containerServiceUserID must be non-negative"
            )
        ) {
            try context.ensure(
                containerServiceUserID: -1,
                executablePath: "/usr/local/bin/container-flannel-vxlan-macos",
                arguments: []
            )
        }
    }
}

private enum TestReexecutionError: Error, Equatable {
    case failed
}
