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

import ContainerAPIClient
import ContainerResource
import Foundation

public extension ContainerKit {
    func createSandbox(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default
    ) async throws {
        try await containerClient.createSandbox(
            configuration: configuration,
            options: options
        )
    }

    func startSandbox(id: String) async throws {
        try await containerClient.startSandbox(id: id)
    }

    func inspectSandbox(id: String) async throws -> SandboxSnapshot {
        try await containerClient.inspectSandbox(id: id)
    }

    func stopSandbox(
        id: String,
        options: ContainerStopOptions = .default
    ) async throws {
        try await containerClient.stop(id: id, opts: options)
    }

    func removeSandbox(id: String, force: Bool = false) async throws {
        try await containerClient.delete(id: id, force: force)
    }

    func createWorkload(
        sandboxID: String,
        configuration: WorkloadConfiguration
    ) async throws {
        try await containerClient.createWorkload(
            containerId: sandboxID,
            configuration: configuration
        )
    }

    func startWorkload(sandboxID: String, workloadID: String) async throws {
        try await containerClient.startWorkload(
            containerId: sandboxID,
            workloadId: workloadID
        )
    }

    func stopWorkload(
        sandboxID: String,
        workloadID: String,
        options: ContainerStopOptions = .default
    ) async throws {
        try await containerClient.stopWorkload(
            containerId: sandboxID,
            workloadId: workloadID,
            options: options
        )
    }

    func removeWorkload(sandboxID: String, workloadID: String) async throws {
        try await containerClient.removeWorkload(
            containerId: sandboxID,
            workloadId: workloadID
        )
    }

    func inspectWorkload(sandboxID: String, workloadID: String) async throws -> WorkloadSnapshot {
        try await containerClient.inspectWorkload(
            containerId: sandboxID,
            workloadId: workloadID
        )
    }

    func sandboxLogPaths(id: String) async throws -> SandboxLogPaths {
        try await containerClient.sandboxLogPaths(id: id)
    }

    func streamPortForward(id: String, port: UInt32) async throws -> FileHandle {
        try await containerClient.dial(id: id, port: port)
    }
}
