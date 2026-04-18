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

import ContainerCRI
import ContainerKit
import ContainerResource
import Foundation

public protocol CRIShimRuntimeManaging: Sendable {
    func createWorkload(
        sandboxID: String,
        configuration: WorkloadConfiguration
    ) async throws

    func removeWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws

    func execSync(
        containerID: String,
        configuration: ProcessConfiguration,
        timeout: Duration?
    ) async throws -> ExecSyncResult
}

public struct ContainerKitCRIShimRuntimeManager: CRIShimRuntimeManaging {
    public var kit: ContainerKit

    public init(kit: ContainerKit = ContainerKit()) {
        self.kit = kit
    }

    public func createWorkload(
        sandboxID: String,
        configuration: WorkloadConfiguration
    ) async throws {
        try await kit.createWorkload(sandboxID: sandboxID, configuration: configuration)
    }

    public func removeWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws {
        try await kit.removeWorkload(sandboxID: sandboxID, workloadID: workloadID)
    }

    public func execSync(
        containerID: String,
        configuration: ProcessConfiguration,
        timeout: Duration?
    ) async throws -> ExecSyncResult {
        try await kit.execSync(id: containerID, configuration: configuration, timeout: timeout)
    }
}

struct CRIShimExecSyncInvocation {
    var containerID: String
    var configuration: ProcessConfiguration
    var timeout: Duration?
}

let criShimExecSyncOutputLimitBytes = 16 * 1024 * 1024

func makeCRIShimExecSyncInvocation(
    _ request: Runtime_V1_ExecSyncRequest
) throws -> CRIShimExecSyncInvocation {
    let containerID = request.containerID.trimmed
    guard !containerID.isEmpty else {
        throw CRIShimError.invalidArgument("ExecSync container_id is required")
    }

    guard let executable = request.cmd.first?.trimmed, !executable.isEmpty else {
        throw CRIShimError.invalidArgument("ExecSync cmd must include an executable")
    }

    guard request.timeout >= 0 else {
        throw CRIShimError.invalidArgument("ExecSync timeout must be greater than or equal to zero")
    }

    let timeout: Duration? =
        if request.timeout == 0 {
            nil
        } else {
            Duration.seconds(request.timeout)
        }

    return CRIShimExecSyncInvocation(
        containerID: containerID,
        configuration: ProcessConfiguration(
            executable: executable,
            arguments: Array(request.cmd.dropFirst()),
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        ),
        timeout: timeout
    )
}

func makeCRIShimExecSyncResponse(
    _ result: ExecSyncResult,
    outputLimitBytes: Int = criShimExecSyncOutputLimitBytes
) -> Runtime_V1_ExecSyncResponse {
    var response = Runtime_V1_ExecSyncResponse()
    response.stdout = cappedExecSyncOutput(result.stdout, limit: outputLimitBytes)
    response.stderr = cappedExecSyncOutput(result.stderr, limit: outputLimitBytes)
    response.exitCode = result.exitCode
    return response
}

private func cappedExecSyncOutput(_ data: Data, limit: Int) -> Data {
    guard data.count > limit else {
        return data
    }
    return Data(data.prefix(limit))
}
