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

import ContainerKit
import Foundation
import Testing

struct ContainerKitAPITests {
    @Test
    func aliasesCompile() {
        let _: ContainerConfiguration.Type = ContainerConfiguration.self
        let _: ContainerCreateOptions.Type = ContainerCreateOptions.self
        let _: ContainerListFilters.Type = ContainerListFilters.self
        let _: ContainerSnapshot.Type = ContainerSnapshot.self
        let _: ContainerStopOptions.Type = ContainerStopOptions.self
        let _: ClientProcess.Protocol = ClientProcess.self
        let _: DiskUsageStats.Type = DiskUsageStats.self
        let _: ExecSyncResult.Type = ExecSyncResult.self
        let _: Image.Type = Image.self
        let _: NetworkConfiguration.Type = NetworkConfiguration.self
        let _: NetworkState.Type = NetworkState.self
        let _: ProcessConfiguration.Type = ProcessConfiguration.self
        let _: SandboxConfiguration.Type = SandboxConfiguration.self
        let _: SandboxLogPaths.Type = SandboxLogPaths.self
        let _: SandboxSnapshot.Type = SandboxSnapshot.self
        let _: SystemHealth.Type = SystemHealth.self
        let _: Volume.Type = Volume.self
        let _: WorkloadConfiguration.Type = WorkloadConfiguration.self
        let _: WorkloadSnapshot.Type = WorkloadSnapshot.self

        #expect(Bool(true))
    }

    @Test
    func facadeSignaturesCompile() {
        let kit = ContainerKit()

        let _: (Duration?) async throws -> SystemHealth = { timeout in
            try await kit.health(timeout: timeout)
        }
        let _: () async throws -> DiskUsageStats = {
            try await kit.diskUsage()
        }
        let _: (ContainerListFilters) async throws -> [ContainerSnapshot] = { filters in
            try await kit.listContainers(filters: filters)
        }
        let _: (String) async throws -> ContainerSnapshot = { id in
            try await kit.getContainer(id: id)
        }
        let _: (ContainerConfiguration, ContainerCreateOptions) async throws -> Void = { configuration, options in
            try await kit.createContainer(configuration: configuration, options: options)
        }
        let _: (String, ProcessConfiguration, Duration?, Data?) async throws -> ExecSyncResult = { id, configuration, timeout, standardInput in
            try await kit.execSync(id: id, configuration: configuration, timeout: timeout, standardInput: standardInput)
        }
        let _: (String, ProcessConfiguration, String, [FileHandle?]) async throws -> any ClientProcess = { id, configuration, processId, stdio in
            try await kit.streamExec(id: id, configuration: configuration, processId: processId, stdio: stdio)
        }
        let _: (ContainerConfiguration, ContainerCreateOptions) async throws -> Void = { configuration, options in
            try await kit.createSandbox(configuration: configuration, options: options)
        }
        let _: (String) async throws -> Void = { id in
            try await kit.startSandbox(id: id)
        }
        let _: (String) async throws -> SandboxSnapshot = { id in
            try await kit.inspectSandbox(id: id)
        }
        let _: (String, ContainerStopOptions) async throws -> Void = { id, options in
            try await kit.stopContainer(id: id, options: options)
        }
        let _: (String, ContainerStopOptions) async throws -> Void = { id, options in
            try await kit.stopSandbox(id: id, options: options)
        }
        let _: (String, Bool) async throws -> Void = { id, force in
            try await kit.deleteContainer(id: id, force: force)
        }
        let _: (String, Bool) async throws -> Void = { id, force in
            try await kit.removeSandbox(id: id, force: force)
        }
        let _: (String) async throws -> UInt64 = { id in
            try await kit.containerDiskUsage(id: id)
        }
        let _: (String, WorkloadConfiguration) async throws -> Void = { sandboxID, configuration in
            try await kit.createWorkload(sandboxID: sandboxID, configuration: configuration)
        }
        let _: (String, String) async throws -> Void = { sandboxID, workloadID in
            try await kit.startWorkload(sandboxID: sandboxID, workloadID: workloadID)
        }
        let _: (String, String, ContainerStopOptions) async throws -> Void = { sandboxID, workloadID, options in
            try await kit.stopWorkload(sandboxID: sandboxID, workloadID: workloadID, options: options)
        }
        let _: (String, String) async throws -> Void = { sandboxID, workloadID in
            try await kit.removeWorkload(sandboxID: sandboxID, workloadID: workloadID)
        }
        let _: (String, String) async throws -> WorkloadSnapshot = { sandboxID, workloadID in
            try await kit.inspectWorkload(sandboxID: sandboxID, workloadID: workloadID)
        }
        let _: (String) async throws -> SandboxLogPaths = { id in
            try await kit.sandboxLogPaths(id: id)
        }
        let _: (String, UInt32) async throws -> FileHandle = { id, port in
            try await kit.streamPortForward(id: id, port: port)
        }
        let _: () async throws -> [Image] = {
            try await kit.listImages()
        }
        let _: (String) async throws -> Image = { reference in
            try await kit.getImage(reference: reference)
        }
        let _: (String) async throws -> Image = { reference in
            try await kit.pullImage(reference: reference)
        }
        let _: (String, Bool) async throws -> Void = { reference, garbageCollect in
            try await kit.deleteImage(reference: reference, garbageCollect: garbageCollect)
        }
        let _: () async throws -> [Volume] = {
            try await kit.listVolumes()
        }
        let _: (String, String, [String: String], [String: String]) async throws -> Volume = { name, driver, driverOptions, labels in
            try await kit.createVolume(
                name: name,
                driver: driver,
                driverOptions: driverOptions,
                labels: labels
            )
        }
        let _: (String) async throws -> Volume = { name in
            try await kit.inspectVolume(name)
        }
        let _: (String) async throws -> Void = { name in
            try await kit.deleteVolume(name: name)
        }
        let _: (String) async throws -> UInt64 = { name in
            try await kit.volumeDiskUsage(name: name)
        }
        let _: () async throws -> [NetworkState] = {
            try await kit.listNetworks()
        }
        let _: (String) async throws -> NetworkState = { id in
            try await kit.getNetwork(id: id)
        }
        let _: (NetworkConfiguration) async throws -> NetworkState = { configuration in
            try await kit.createNetwork(configuration: configuration)
        }
        let _: (String) async throws -> Void = { id in
            try await kit.deleteNetwork(id: id)
        }

        #expect(Bool(true))
    }
}
