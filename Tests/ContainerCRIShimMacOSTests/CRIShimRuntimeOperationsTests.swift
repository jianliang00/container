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

@testable import ContainerCRI
@testable import ContainerCRIShimMacOS
@testable import ContainerResource

#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct CRIShimRuntimeOperationsTests {
    @Test
    func mapsExecSyncRequestToProcessConfiguration() throws {
        var request = Runtime_V1_ExecSyncRequest()
        request.containerID = " container-1 "
        request.cmd = ["/bin/echo", "hello", "world"]
        request.timeout = 5

        let invocation = try makeCRIShimExecSyncInvocation(request)

        #expect(invocation.containerID == "container-1")
        #expect(invocation.configuration.executable == "/bin/echo")
        #expect(invocation.configuration.arguments == ["hello", "world"])
        #expect(invocation.configuration.environment.isEmpty)
        #expect(invocation.configuration.workingDirectory == "/")
        #expect(!invocation.configuration.terminal)
        #expect(invocation.timeout == .seconds(5))
    }

    @Test
    func execProcessConfigurationInheritsWorkloadDefaults() {
        let requested = ProcessConfiguration(
            executable: "/bin/bash",
            arguments: ["-l"],
            environment: [],
            workingDirectory: "/",
            terminal: true,
            user: .id(uid: 0, gid: 0)
        )
        let workload = WorkloadSnapshot(
            configuration: WorkloadConfiguration(
                id: "workload-1",
                processConfiguration: ProcessConfiguration(
                    executable: "/opt/kross/bootstrap/entry.sh",
                    arguments: [],
                    environment: ["USER=admin", "HOME=/Users/admin"],
                    workingDirectory: "/app",
                    terminal: false,
                    user: .raw(userString: "admin"),
                    supplementalGroups: [20],
                    rlimits: [.init(limit: "RLIMIT_NOFILE", soft: 1024, hard: 2048)]
                )
            ),
            status: .running
        )

        let configuration = makeCRIShimExecProcessConfiguration(
            requested: requested,
            workload: workload
        )

        #expect(configuration.executable == "/bin/bash")
        #expect(configuration.arguments == ["-l"])
        #expect(configuration.environment == ["USER=admin", "HOME=/Users/admin"])
        #expect(configuration.workingDirectory == "/app")
        #expect(configuration.terminal)
        #expect(configuration.user == .raw(userString: "admin"))
        #expect(configuration.supplementalGroups == [20])
        #expect(configuration.rlimits.count == 1)
        #expect(configuration.rlimits[0].limit == "RLIMIT_NOFILE")
    }

    @Test
    func rejectsInvalidExecSyncRequests() {
        var missingContainer = Runtime_V1_ExecSyncRequest()
        missingContainer.cmd = ["/bin/true"]
        #expect(throws: CRIShimError.invalidArgument("ExecSync container_id is required")) {
            try makeCRIShimExecSyncInvocation(missingContainer)
        }

        var missingCommand = Runtime_V1_ExecSyncRequest()
        missingCommand.containerID = "container-1"
        #expect(throws: CRIShimError.invalidArgument("ExecSync cmd must include an executable")) {
            try makeCRIShimExecSyncInvocation(missingCommand)
        }

        var negativeTimeout = Runtime_V1_ExecSyncRequest()
        negativeTimeout.containerID = "container-1"
        negativeTimeout.cmd = ["/bin/true"]
        negativeTimeout.timeout = -1
        #expect(throws: CRIShimError.invalidArgument("ExecSync timeout must be greater than or equal to zero")) {
            try makeCRIShimExecSyncInvocation(negativeTimeout)
        }
    }

    @Test
    func capsExecSyncOutputAtCRILimit() {
        let result = ExecSyncResult(
            exitCode: 7,
            stdout: Data(repeating: 0x41, count: 8),
            stderr: Data(repeating: 0x42, count: 9)
        )

        let response = makeCRIShimExecSyncResponse(result, outputLimitBytes: 4)

        #expect(response.exitCode == 7)
        #expect(response.stdout == Data(repeating: 0x41, count: 4))
        #expect(response.stderr == Data(repeating: 0x42, count: 4))
    }

    @Test
    func mapsStopContainerTimeoutToStopOptions() throws {
        var graceful = Runtime_V1_StopContainerRequest()
        graceful.timeout = 3
        let gracefulOptions = try makeCRIShimStopOptions(graceful)
        #expect(gracefulOptions.timeoutInSeconds == 3)
        #expect(gracefulOptions.signal == String(SIGTERM))

        let immediateOptions = try makeCRIShimStopOptions(Runtime_V1_StopContainerRequest())
        #expect(immediateOptions.timeoutInSeconds == 0)
        #expect(immediateOptions.signal == String(SIGKILL))

        var negative = Runtime_V1_StopContainerRequest()
        negative.timeout = -1
        #expect(throws: CRIShimError.invalidArgument("StopContainer timeout must be greater than or equal to zero")) {
            try makeCRIShimStopOptions(negative)
        }
    }
}
