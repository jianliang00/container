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

struct CNIMacvmnetCommandRunnerTests {
    @Test func statusSuccessDispatchesHealthCheckWithoutOutput() async throws {
        let backend = RecordingRunnerBackend()
        let runner = CNIMacvmnetCommandRunner(backend: backend)

        let result = await runner.execute(
            environment: [
                "CNI_COMMAND": "STATUS"
            ],
            stdin: runnerMinimalConfigData()
        )

        #expect(result.exitCode == EXIT_SUCCESS)
        #expect(result.stdout.isEmpty)
        #expect(backend.healthChecks == ["default"])
    }

    @Test func statusFailureReturnsStructuredErrorAndNonZeroExit() async throws {
        let backend = RecordingRunnerBackend(
            healthError: CNIError.backendUnavailable("STATUS is not ready: network backend health check failed")
        )
        let runner = CNIMacvmnetCommandRunner(backend: backend)

        let result = await runner.execute(
            environment: [
                "CNI_COMMAND": "STATUS"
            ],
            stdin: runnerMinimalConfigData()
        )

        #expect(result.exitCode == EXIT_FAILURE)
        let response = try JSONDecoder().decode(CNIErrorResponse.self, from: result.stdout)
        #expect(response.code == 100)
        #expect(response.msg == "STATUS is not ready: network backend health check failed")
        #expect(response.details == nil)
    }

    @Test func invalidCNIVersionReturnsStructuredErrorAndSkipsBackendCalls() async throws {
        let backend = RecordingRunnerBackend()
        let runner = CNIMacvmnetCommandRunner(backend: backend)

        let result = await runner.execute(
            environment: [
                "CNI_COMMAND": "ADD",
                "CNI_CONTAINERID": "sandbox-1",
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

        #expect(result.exitCode == EXIT_FAILURE)
        let response = try JSONDecoder().decode(CNIErrorResponse.self, from: result.stdout)
        #expect(response.code == 1)
        #expect(response.msg.contains("incompatible CNI version 0.4.0"))
        #expect(backend.healthChecks.isEmpty)
        #expect(backend.preparePlans.isEmpty)
    }

    @Test func invalidPluginTypeReturnsStructuredErrorAndSkipsBackendCalls() async throws {
        let backend = RecordingRunnerBackend()
        let runner = CNIMacvmnetCommandRunner(backend: backend)

        let result = await runner.execute(
            environment: [
                "CNI_COMMAND": "ADD",
                "CNI_CONTAINERID": "sandbox-1",
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

        #expect(result.exitCode == EXIT_FAILURE)
        let response = try JSONDecoder().decode(CNIErrorResponse.self, from: result.stdout)
        #expect(response.code == 7)
        #expect(response.msg.contains("unsupported CNI plugin type bridge"))
        #expect(backend.healthChecks.isEmpty)
        #expect(backend.preparePlans.isEmpty)
    }
}

private final class RecordingRunnerBackend: MacvmnetBackend, @unchecked Sendable {
    var healthError: Error?
    private(set) var healthChecks: [String] = []
    private(set) var preparePlans: [MacvmnetOperationPlan] = []

    init(healthError: Error? = nil) {
        self.healthError = healthError
    }

    func health(networkName: String) async throws {
        healthChecks.append(networkName)
        if let healthError {
            throw healthError
        }
    }

    func prepare(_ plan: MacvmnetOperationPlan) async throws -> CNIResult {
        preparePlans.append(plan)
        throw CNIError.backendUnavailable("prepare should not be called in this test")
    }

    func inspect(_ plan: MacvmnetOperationPlan) async throws {
        throw CNIError.backendUnavailable("inspect should not be called in this test")
    }

    func release(_ plan: MacvmnetOperationPlan) async throws {
        throw CNIError.backendUnavailable("release should not be called in this test")
    }

    func garbageCollect(_ plan: MacvmnetOperationPlan) async throws {
        throw CNIError.backendUnavailable("garbageCollect should not be called in this test")
    }
}

private func runnerMinimalConfigData() -> Data {
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
