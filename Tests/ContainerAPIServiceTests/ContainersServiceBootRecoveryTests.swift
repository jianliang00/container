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

import ContainerPlugin
import ContainerXPC
import ContainerizationExtras
import Foundation
import Logging
import Testing

@testable import ContainerAPIService
@testable import ContainerResource
@testable import ContainerRuntimeClient

struct ContainersServiceBootRecoveryTests {
    @Test
    func pendingCleanupRejectsStatelessMacOSStartAdmission() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        var configuration = try makeContainerConfiguration(id: root.lastPathComponent)
        configuration.runtimeHandler = "container-runtime-macos"
        try MacOSRuntimeCleanup.markPending(root: root)

        #expect(throws: (any Error).self) {
            try ContainersService.requireNoPendingStatelessMacOSCleanup(
                root: root,
                configuration: configuration
            )
        }
    }

    @Test
    func bootLoadRetainsPendingAutoRemoveAndUnreadableBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let containers = root.appendingPathComponent("containers")
        let path = containers.appendingPathComponent("boot-recovery")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        var configuration = try makeContainerConfiguration(id: "boot-recovery")
        configuration.runtimeHandler = "container-runtime-macos"
        let bundle = ContainerResource.Bundle(path: path)
        try bundle.write(filename: "config.json", value: configuration)
        try bundle.write(
            filename: "options.json",
            value: ContainerCreateOptions(autoRemove: true)
        )

        let unreadable = containers.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(
            at: unreadable,
            withIntermediateDirectories: false
        )
        try Data("retained VM disk".utf8).write(
            to: unreadable.appendingPathComponent("Disk.img")
        )

        let loader = try PluginLoader(
            appRoot: root,
            installRoot: root,
            logRoot: nil,
            pluginDirectories: [],
            pluginFactories: []
        )
        let states = try ContainersService.loadAtBoot(
            root: containers,
            loader: loader,
            log: Logger(label: "boot-recovery-test")
        )

        #expect(states[configuration.id]?.snapshot.status == .stopping)
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(
            FileManager.default.fileExists(
                atPath: unreadable.appendingPathComponent("Disk.img").path
            )
        )
    }

    @Test
    func bootRecoveryRetriesOnlyPendingSandboxes() async {
        let recorder = BootRecoveryAttemptRecorder(
            failuresRemaining: [
                "already-clean": 0,
                "retry-once": 1,
            ]
        )

        await ContainersService.retrySandboxRecoveriesAtBoot(
            containerIDs: ["retry-once", "already-clean"],
            retryDelay: .milliseconds(1)
        ) { id in
            await recorder.recover(id: id)
        }

        let completedAttempts = await recorder.attempts(for: "already-clean")
        let retriedAttempts = await recorder.attempts(for: "retry-once")
        #expect(completedAttempts == 1)
        #expect(retriedAttempts == 2)
    }

    @Test
    func bootRecoveryKeepsRecoveredClientForStoppedSandbox() throws {
        let existing = try makeContainerState(status: .stopped, networks: [], startedDate: Date())
        let networks = try [makeAttachment()]
        let recoveredClient = makeRuntimeClient(id: existing.snapshot.id)
        let sandboxSnapshot = SandboxSnapshot(
            status: .stopped,
            networks: networks,
            containers: []
        )

        let recovered = ContainersService.makeBootRecoveredState(
            existing: existing,
            sandboxSnapshot: sandboxSnapshot,
            client: recoveredClient
        )

        #expect(recovered.client != nil)
        #expect(recovered.snapshot.status == .stopped)
        #expect(recovered.snapshot.networks == networks)
        #expect(recovered.snapshot.startedDate == nil)
    }

    @Test
    func bootRecoveryPreservesStartedDateForRunningSandbox() throws {
        let startedDate = Date(timeIntervalSince1970: 1_711_111_111)
        let existing = try makeContainerState(status: .stopped, networks: [], startedDate: startedDate)
        let networks = try [makeAttachment()]
        let recoveredClient = makeRuntimeClient(id: existing.snapshot.id)
        let sandboxSnapshot = SandboxSnapshot(
            status: .running,
            networks: networks,
            containers: []
        )

        let recovered = ContainersService.makeBootRecoveredState(
            existing: existing,
            sandboxSnapshot: sandboxSnapshot,
            client: recoveredClient
        )

        #expect(recovered.client != nil)
        #expect(recovered.snapshot.status == .running)
        #expect(recovered.snapshot.networks == networks)
        #expect(recovered.snapshot.startedDate == startedDate)
    }

    @Test
    func bootRecoveryTreatsBootedSandboxAsRunningWhenInitWorkloadIsStopped() throws {
        let configuration = try makeContainerConfiguration(id: "boot-recovery")
        let existing = ContainersService.ContainerState(
            snapshot: ContainerSnapshot(
                configuration: configuration,
                status: .stopped,
                networks: [],
                startedDate: nil
            )
        )
        let sandboxSnapshot = SandboxSnapshot(
            configuration: SandboxConfiguration(containerConfiguration: configuration),
            status: .running,
            networks: [],
            containers: [
                ContainerSnapshot(
                    configuration: configuration,
                    status: .running,
                    networks: [],
                    startedDate: nil
                )
            ],
            workloads: [
                WorkloadSnapshot(
                    configuration: WorkloadConfiguration(
                        id: configuration.id,
                        processConfiguration: configuration.initProcess
                    ),
                    status: .stopped
                )
            ]
        )

        let recovered = ContainersService.makeBootRecoveredState(
            existing: existing,
            sandboxSnapshot: sandboxSnapshot,
            client: makeRuntimeClient(id: configuration.id)
        )

        #expect(recovered.snapshot.status == .running)
    }

    @Test
    func persistedWorkloadSnapshotRestoresActualExitState() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configuration = try makeContainerConfiguration(id: "persisted-exit")
        let exitedAt = Date(timeIntervalSince1970: 1_711_111_111)
        try WorkloadExitStateStore.saveIfAbsent(
            WorkloadExitState(exitCode: 255, exitedAt: exitedAt.addingTimeInterval(-1)),
            workloadID: configuration.id,
            in: MacOSSandboxLayout(root: tempRoot)
        )
        try WorkloadExitStateStore.save(
            WorkloadExitState(exitCode: 137, exitedAt: exitedAt),
            workloadID: configuration.id,
            in: MacOSSandboxLayout(root: tempRoot)
        )
        try WorkloadExitStateStore.saveIfAbsent(
            WorkloadExitState(exitCode: 255, exitedAt: exitedAt.addingTimeInterval(1)),
            workloadID: configuration.id,
            in: MacOSSandboxLayout(root: tempRoot)
        )

        let workloads = try ContainersService.loadPersistedWorkloadSnapshots(
            root: tempRoot,
            configuration: configuration
        )
        let workload = try #require(workloads.first(where: { $0.id == configuration.id }))

        #expect(workload.status == .stopped)
        #expect(workload.exitCode == 137)
        #expect(workload.exitedAt == exitedAt)
    }

    @Test
    func persistedWorkloadSnapshotWithoutExitStateUsesUnknownExitFacts() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configuration = try makeContainerConfiguration(id: "legacy-workload")
        let workloads = try ContainersService.loadPersistedWorkloadSnapshots(
            root: tempRoot,
            configuration: configuration
        )
        let workload = try #require(workloads.first(where: { $0.id == configuration.id }))

        #expect(workload.status == .stopped)
        #expect(workload.exitCode == nil)
        #expect(workload.exitedAt == nil)
    }

    private func makeContainerState(
        status: RuntimeStatus,
        networks: [ContainerResource.Attachment],
        startedDate: Date?
    ) throws -> ContainersService.ContainerState {
        let config = try makeContainerConfiguration(id: "boot-recovery")
        let snapshot = ContainerSnapshot(
            configuration: config,
            status: status,
            networks: networks,
            startedDate: startedDate
        )
        return ContainersService.ContainerState(snapshot: snapshot)
    }

    private func makeContainerConfiguration(id: String) throws -> ContainerConfiguration {
        let imageJSON = """
            {
              "reference": "example/test:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:test",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        return ContainerConfiguration(id: id, image: image, process: process)
    }

    private func makeAttachment() throws -> ContainerResource.Attachment {
        ContainerResource.Attachment(
            network: "default",
            hostname: "boot-recovery",
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: try MACAddress("02:42:ac:11:00:52"),
            dns: .init(
                nameservers: ["192.168.64.1"],
                domain: nil,
                searchDomains: [],
                options: []
            )
        )
    }

    private func makeRuntimeClient(id: String) -> RuntimeClient {
        RuntimeClient(
            id: id,
            runtime: "container-runtime-macos",
            client: XPCClient(service: "com.apple.container.tests.boot-recovery")
        )
    }
}

private actor BootRecoveryAttemptRecorder {
    private var attemptsByID: [String: Int] = [:]
    private var failuresRemaining: [String: Int]

    init(failuresRemaining: [String: Int]) {
        self.failuresRemaining = failuresRemaining
    }

    func recover(id: String) -> Bool {
        attemptsByID[id, default: 0] += 1
        guard let remaining = failuresRemaining[id], remaining > 0 else {
            return false
        }
        failuresRemaining[id] = remaining - 1
        return true
    }

    func attempts(for id: String) -> Int {
        attemptsByID[id, default: 0]
    }
}
