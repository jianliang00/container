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
    func listContainers(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        try await containerClient.list(filters: filters)
    }

    func getContainer(id: String) async throws -> ContainerSnapshot {
        try await containerClient.get(id: id)
    }

    func createContainer(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default
    ) async throws {
        try await containerClient.create(
            configuration: configuration,
            options: options
        )
    }

    func execSync(
        id: String,
        configuration: ProcessConfiguration,
        timeout: Duration? = nil,
        standardInput: Data? = nil
    ) async throws -> ExecSyncResult {
        try await containerClient.execSync(
            containerId: id,
            configuration: configuration,
            timeout: timeout,
            standardInput: standardInput
        )
    }

    func streamExec(
        id: String,
        configuration: ProcessConfiguration,
        processId: String = UUID().uuidString.lowercased(),
        stdio: [FileHandle?]
    ) async throws -> any ClientProcess {
        try await containerClient.streamExec(
            containerId: id,
            processId: processId,
            configuration: configuration,
            stdio: stdio
        )
    }

    func stopContainer(
        id: String,
        options: ContainerStopOptions = .default
    ) async throws {
        try await containerClient.stop(id: id, opts: options)
    }

    func deleteContainer(id: String, force: Bool = false) async throws {
        try await containerClient.delete(id: id, force: force)
    }

    func containerDiskUsage(id: String) async throws -> UInt64 {
        try await containerClient.diskUsage(id: id)
    }
}
