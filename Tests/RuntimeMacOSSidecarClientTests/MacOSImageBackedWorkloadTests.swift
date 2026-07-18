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

#if os(macOS)
import ContainerResource
import Containerization
import ContainerizationArchive
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import Testing

@testable import RuntimeMacOSSidecarShared
@testable import container_runtime_macos

@Suite(.serialized)
struct MacOSImageBackedWorkloadTests {
    @Test
    func createWorkloadBeforeBootPersistsMountsForBootTimeSharePlanning() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-mount-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let hostDirectory = tempDirectory.appendingPathComponent("host-data", isDirectory: true)
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests")
        )
        try await service.testingPrepareSandbox(
            try Self.baseContainerConfiguration(indexDigest: "sha256:test"),
            state: "created"
        )

        let workload = WorkloadConfiguration(
            id: "mounted-workload",
            processConfiguration: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: []),
            mounts: [
                .virtiofs(source: hostDirectory.path, destination: "/Users/demo/data", options: ["ro"])
            ]
        )

        try await service.testingCreateWorkload(workload)

        let stored = try #require(await service.testingWorkloadConfiguration("mounted-workload"))
        #expect(stored.mounts.count == 1)
        #expect(stored.mounts[0].source == Self.normalizedDirectoryPath(hostDirectory))
        #expect(stored.mounts[0].destination == "/Users/demo/data")
        #expect(stored.mounts[0].options == ["ro"])
    }

    @Test
    func createWorkloadAfterBootRejectsNewMountShares() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-late-mount-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let hostDirectory = tempDirectory.appendingPathComponent("late-host-data", isDirectory: true)
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests")
        )
        try await service.testingPrepareSandbox(
            try Self.baseContainerConfiguration(indexDigest: "sha256:test"),
            state: "booted"
        )

        let workload = WorkloadConfiguration(
            id: "late-mounted-workload",
            processConfiguration: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: []),
            mounts: [
                .virtiofs(source: hostDirectory.path, destination: "/Users/demo/data", options: [])
            ]
        )

        await #expect(throws: Error.self) {
            try await service.testingCreateWorkload(workload)
        }
    }

    @Test
    func prepareBundleRestoresMissingTemplateArtifactsWhenConfigurationAlreadyExists() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-sandbox-template-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeSandboxImage(in: tempDirectory.appendingPathComponent("sandbox-image", isDirectory: true))
        let sandboxRoot = tempDirectory.appendingPathComponent("sandbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)

        let layout = MacOSSandboxLayout(root: sandboxRoot)
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: image.indexDigest)
        try JSONEncoder().encode(containerConfiguration).write(to: layout.containerConfigurationURL)

        let service = MacOSSandboxService(
            root: sandboxRoot,
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        let prepared = try await service.testingPrepareBundle()

        #expect(prepared.id == containerConfiguration.id)
        #expect(try Data(contentsOf: layout.hardwareModelURL) == image.hardwareModelData)
        #expect(try Data(contentsOf: layout.auxiliaryStorageURL) == image.auxiliaryStorageData)
        #expect(try Data(contentsOf: layout.diskImageURL) == image.diskImageData)
    }

    @Test
    func startImageBackedWorkloadInjectsPayloadMetadataAndMapsPayloadPathsWithoutChroot() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-image-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeWorkloadImage(in: tempDirectory)
        let socketPath = "/tmp/sidecar-image-backed-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingSidecarServer(socketPath: socketPath)
        defer { server.stop() }

        server.start()

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: image.indexDigest)
        try await service.testingPrepareSandbox(containerConfiguration)
        await service.testingInstallSidecarClient(socketPath: socketPath)

        let workloadID = "image-backed-workload"
        let workloadConfiguration = WorkloadConfiguration(
            id: workloadID,
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["override-arg"],
                environment: ["GREETING=override"],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )

        try await service.testingCreateWorkload(workloadConfiguration)
        try await service.testingStartWorkload(workloadID)

        server.stop()
        try server.waitForCompletion()

        let snapshot = try await service.testingInspectWorkload(workloadID)
        #expect(snapshot.configuration.injectionState == WorkloadInjectionState.injected)
        #expect(snapshot.configuration.processConfiguration.executable == "/bin/hello")
        #expect(snapshot.configuration.processConfiguration.arguments == ["override-arg"])
        #expect(snapshot.configuration.processConfiguration.workingDirectory == "/workspace")
        #expect(snapshot.configuration.processConfiguration.environment.contains("GREETING=override"))
        #expect(snapshot.configuration.processConfiguration.environment.contains("PATH=/usr/bin:/bin"))

        let requests = server.recordedRequests()
        let guestRoot = "/var/lib/container/workloads/\(workloadID)/rootfs"
        let injectedPaths = requests.compactMap { $0.fsBegin?.path }

        #expect(injectedPaths.contains("\(guestRoot)/bin"))
        #expect(injectedPaths.contains("\(guestRoot)/bin/hello"))
        #expect(injectedPaths.contains("\(guestRoot)/etc"))
        #expect(injectedPaths.contains("\(guestRoot)/etc/config.txt"))
        #expect(!injectedPaths.contains("\(guestRoot)/tmp/stale.txt"))

        let workspaceBegin = try #require(requests.first(where: { $0.fsBegin?.path == "\(guestRoot)/workspace" })?.fsBegin)
        #expect(workspaceBegin.uid == 501)
        #expect(workspaceBegin.gid == 20)

        let helloBegin = try #require(requests.first(where: { $0.fsBegin?.path == "\(guestRoot)/bin/hello" })?.fsBegin)
        #expect(helloBegin.uid == 501)
        #expect(helloBegin.gid == 20)

        let metadataPayload = try #require(
            requests.first(where: { $0.fsBegin?.path == "/var/lib/container/workloads/\(workloadID)/meta.json" })?.fsBegin?.inlineData
        )
        let metadata = try JSONDecoder().decode(MacOSWorkloadGuestMetadata.self, from: metadataPayload)
        #expect(metadata.workloadImageDigest == image.indexDigest)
        #expect(metadata.processConfiguration.executable == "/bin/hello")
        #expect(metadata.processConfiguration.arguments == ["override-arg"])

        let prepareRequest = try #require(
            requests.first(where: { $0.method == .processStart && ($0.processID?.hasPrefix("workload-prepare-") ?? false) })
        )
        #expect(prepareRequest.exec?.rootDirectory == nil)

        let workloadStartRequest = try #require(
            requests.first(where: { $0.method == .processStart && $0.processID?.hasPrefix("__workload__") == true })
        )
        #expect(workloadStartRequest.exec?.rootDirectory == nil)
        #expect(workloadStartRequest.exec?.executable == "\(guestRoot)/bin/hello")
        #expect(workloadStartRequest.exec?.arguments == ["override-arg"])
        #expect(workloadStartRequest.exec?.workingDirectory == "\(guestRoot)/workspace")
        #expect(workloadStartRequest.exec?.user == "nobody")
    }

    @Test
    func startImageBackedWorkloadAcceptsEmptyNoOpLayer() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-empty-layer-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeWorkloadImage(in: tempDirectory, includeEmptyLayer: true)
        let socketPath = "/tmp/sidecar-empty-layer-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingSidecarServer(socketPath: socketPath)
        defer { server.stop() }
        server.start()

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        try await service.testingPrepareSandbox(Self.baseContainerConfiguration(indexDigest: image.indexDigest))
        await service.testingInstallSidecarClient(socketPath: socketPath)

        let workloadID = "image-backed-empty-layer"
        try await service.testingCreateWorkload(
            WorkloadConfiguration(
                id: workloadID,
                processConfiguration: ProcessConfiguration(
                    executable: "",
                    arguments: [],
                    environment: [],
                    workingDirectory: "/",
                    terminal: false,
                    user: .id(uid: 0, gid: 0)
                ),
                workloadImageReference: "registry.local/example/workload:empty@\(image.indexDigest)",
                workloadImageDigest: image.indexDigest
            )
        )
        try await service.testingStartWorkload(workloadID)

        server.stop()
        try server.waitForCompletion()

        let snapshot = try await service.testingInspectWorkload(workloadID)
        #expect(snapshot.configuration.injectionState == .injected)
    }

    @Test
    func imageBackedWorkloadMergesSandboxWorkloadAndRequestEnvironment() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-environment-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeWorkloadImage(in: tempDirectory)
        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: image.indexDigest)
        let sandboxImageConfig = Self.makeSandboxImageConfig(
            env: [
                "HOME=/var/root",
                "PATH=/sandbox/bin:/usr/bin",
                "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer",
                "GREETING=sandbox",
                "SANDBOX_ONLY=1",
            ]
        )
        try await service.testingPrepareSandbox(
            containerConfiguration,
            sandboxImageConfig: sandboxImageConfig
        )

        let workloadID = "image-backed-environment"
        let workloadConfiguration = WorkloadConfiguration(
            id: workloadID,
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: [],
                environment: [
                    "GREETING=request",
                    "HOME=/request-home",
                    "REQUEST_ONLY=1",
                ],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )

        try await service.testingCreateWorkload(workloadConfiguration)

        let stored = try #require(await service.testingWorkloadConfiguration(workloadID))
        let environment = stored.processConfiguration.environment
        #expect(
            environment == [
                "HOME=/request-home",
                "PATH=/usr/bin:/bin",
                "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer",
                "GREETING=request",
                "SANDBOX_ONLY=1",
                "USER=nobody",
                "REQUEST_ONLY=1",
            ]
        )
        let environmentKeys = environment.map { entry in
            entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? entry
        }
        #expect(environmentKeys.count == Set(environmentKeys).count)
        #expect(!environment.contains { $0.hasPrefix("KUBERNETES_SERVICE_HOST=") })
    }

    @Test
    func stopSandboxCleansGuestWorkloadDirectoriesButKeepsHostRootfsCache() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-stop-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeWorkloadImage(in: tempDirectory)
        let cacheEntry = MacOSGuestCache.workloadRootfsCacheDirectory()
            .appendingPathComponent(MacOSGuestCache.safeDigest(image.indexDigest), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheEntry) }

        let socketPath = "/tmp/sidecar-workload-stop-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingSidecarServer(
            socketPath: socketPath,
            exitOnSignalPrefixes: ["__workload__"]
        )
        defer { server.stop() }

        server.start()

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: image.indexDigest)
        try await service.testingPrepareSandbox(containerConfiguration, state: "running")
        await service.testingInstallSidecarClient(socketPath: socketPath)

        let workloadID = "image-backed-cleanup"
        let workloadConfiguration = WorkloadConfiguration(
            id: workloadID,
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["override-arg"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )

        try await service.testingCreateWorkload(workloadConfiguration)
        try await service.testingStartWorkload(workloadID)

        let cachedRootfs = cacheEntry.appendingPathComponent("rootfs", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: cachedRootfs.path))

        try await service.testingStop(.init(timeoutInSeconds: 1, signal: SIGTERM))

        server.stop()
        try server.waitForCompletion()

        let updatedConfiguration = await service.testingWorkloadConfiguration(workloadID)
        let configurationAfterStop = try #require(updatedConfiguration)
        #expect(configurationAfterStop.injectionState == .pending)
        #expect(FileManager.default.fileExists(atPath: cachedRootfs.path))

        let cleanupRequest = try #require(
            server.recordedRequests().first(where: {
                $0.method == .processStart && ($0.processID?.hasPrefix("workload-cleanup-all-") ?? false)
            })
        )
        let cleanupScript = cleanupRequest.exec?.arguments.last ?? ""
        #expect(cleanupScript.contains("rm -rf '/var/lib/container/workloads'"))
        #expect(cleanupScript.contains("mkdir -p '/var/lib/container/workloads'"))
    }

    @Test
    func stopSandboxStopsAttachedWorkloadsBeforeCleaningGuestDirectories() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-stop-order-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeWorkloadImage(in: tempDirectory)
        let socketPath = "/tmp/sidecar-workload-stop-order-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingSidecarServer(
            socketPath: socketPath,
            exitOnSignalPrefixes: ["__workload__"]
        )
        defer { server.stop() }

        server.start()

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: image.indexDigest)
        try await service.testingPrepareSandbox(containerConfiguration, state: "running")
        await service.testingInstallSidecarClient(socketPath: socketPath)

        let workloadA = WorkloadConfiguration(
            id: "image-stop-order-a",
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["arg-a"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload-a:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )
        let workloadB = WorkloadConfiguration(
            id: "image-stop-order-b",
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["arg-b"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload-b:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )

        try await service.testingCreateWorkload(workloadA)
        try await service.testingCreateWorkload(workloadB)
        try await service.testingStartWorkload(workloadA.id)
        try await service.testingStartWorkload(workloadB.id)

        try await service.testingStop(.init(timeoutInSeconds: 1, signal: SIGTERM))

        server.stop()
        try server.waitForCompletion()

        let snapshotA = try await service.testingInspectWorkload(workloadA.id)
        let snapshotB = try await service.testingInspectWorkload(workloadB.id)
        let configurationA = await service.testingWorkloadConfiguration(workloadA.id)
        let configurationB = await service.testingWorkloadConfiguration(workloadB.id)
        #expect(snapshotA.status == .stopped)
        #expect(snapshotA.exitCode == 0)
        #expect(snapshotB.status == .stopped)
        #expect(snapshotB.exitCode == 0)
        #expect(configurationA?.injectionState == .pending)
        #expect(configurationB?.injectionState == .pending)

        let requests = server.recordedRequests()
        let cleanupIndex = try #require(
            requests.firstIndex(where: {
                $0.method == .processStart && ($0.processID?.hasPrefix("workload-cleanup-all-") ?? false)
            })
        )
        let signalIndices: [Int] = requests.enumerated().compactMap { entry -> Int? in
            let (index, request) = entry
            guard request.method == .processSignal, request.processID?.hasPrefix("__workload__") == true else {
                return nil
            }
            return index
        }

        #expect(signalIndices.count == 2)
        #expect(signalIndices.allSatisfy { $0 < cleanupIndex })
    }

    @Test
    func startingAndStoppingWorkloadAreIdempotent() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-idempotent-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeWorkloadImage(in: tempDirectory)
        let socketPath = "/tmp/sidecar-workload-idempotent-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingSidecarServer(
            socketPath: socketPath,
            exitOnSignalPrefixes: ["__workload__"]
        )
        defer { server.stop() }

        server.start()

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: image.indexDigest)
        try await service.testingPrepareSandbox(containerConfiguration, state: "running")
        await service.testingInstallSidecarClient(socketPath: socketPath)

        let workloadID = "image-idempotent"
        let workloadConfiguration = WorkloadConfiguration(
            id: workloadID,
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["override-arg"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )

        try await service.testingCreateWorkload(workloadConfiguration)
        try await service.testingStartWorkload(workloadID)
        let sessionID = await service.testingSessionID(for: workloadID)
        try await service.testingStartWorkload(workloadID)
        try await service.testingStopWorkload(
            workloadID,
            options: .init(timeoutInSeconds: 1, signal: SIGTERM)
        )
        try await service.testingStopWorkload(
            workloadID,
            options: .init(timeoutInSeconds: 1, signal: SIGTERM)
        )

        let snapshot = try await service.testingInspectWorkload(workloadID)
        let updatedSessionID = await service.testingSessionID(for: workloadID)
        #expect(snapshot.status == .stopped)
        #expect(snapshot.exitCode == 0)
        #expect(updatedSessionID == sessionID)

        server.stop()
        try server.waitForCompletion()

        let requests = server.recordedRequests()
        let workloadStarts = requests.filter {
            $0.method == .processStart && ($0.processID?.hasPrefix("__workload__") ?? false)
        }
        let workloadSignals = requests.filter {
            $0.method == .processSignal && ($0.processID?.hasPrefix("__workload__") ?? false)
        }

        #expect(workloadStarts.count == 1)
        #expect(workloadSignals.count == 1)
    }

    @Test
    func stopRunningImageBackedWorkloadSignalsSidecarAndMarksWorkloadStopped() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-stop-one-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeWorkloadImage(in: tempDirectory)
        let socketPath = "/tmp/sidecar-workload-stop-one-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingSidecarServer(
            socketPath: socketPath,
            exitOnSignalPrefixes: ["__workload__"]
        )
        defer { server.stop() }

        server.start()

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: image.indexDigest)
        try await service.testingPrepareSandbox(containerConfiguration, state: "running")
        await service.testingInstallSidecarClient(socketPath: socketPath)

        let workloadID = "image-backed-stop-one"
        let workloadConfiguration = WorkloadConfiguration(
            id: workloadID,
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["override-arg"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )

        try await service.testingCreateWorkload(workloadConfiguration)
        try await service.testingStartWorkload(workloadID)
        try await service.testingStopWorkload(
            workloadID,
            options: .init(timeoutInSeconds: 1, signal: SIGTERM)
        )

        server.stop()
        try server.waitForCompletion()

        let snapshot = try await service.testingInspectWorkload(workloadID)
        #expect(snapshot.status == .stopped)
        #expect(snapshot.exitCode == 0)

        let signalRequest = try #require(
            server.recordedRequests().first(where: {
                $0.method == .processSignal && ($0.processID?.hasPrefix("__workload__") ?? false)
            })
        )
        #expect(signalRequest.signal == SIGTERM)
    }

    @Test
    func stopSandboxSignalsAllRunningWorkloadsBeforeCleanup() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-stop-all-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeWorkloadImage(in: tempDirectory)
        let socketPath = "/tmp/sidecar-workload-stop-all-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingSidecarServer(
            socketPath: socketPath,
            exitOnSignalPrefixes: ["__workload__"]
        )
        defer { server.stop() }

        server.start()

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: image.indexDigest)
        try await service.testingPrepareSandbox(containerConfiguration, state: "running")
        await service.testingInstallSidecarClient(socketPath: socketPath)

        let workloadA = WorkloadConfiguration(
            id: "image-backed-stop-all-a",
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["arg-a"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )
        let workloadB = WorkloadConfiguration(
            id: "image-backed-stop-all-b",
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["arg-b"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )

        try await service.testingCreateWorkload(workloadA)
        try await service.testingCreateWorkload(workloadB)
        try await service.testingStartWorkload(workloadA.id)
        try await service.testingStartWorkload(workloadB.id)

        let beforeStopA = try await service.testingInspectWorkload(workloadA.id)
        let beforeStopB = try await service.testingInspectWorkload(workloadB.id)
        #expect(beforeStopA.status == .running)
        #expect(beforeStopB.status == .running)

        let sessionIDA = try #require(await service.testingSessionID(for: workloadA.id))
        let sessionIDB = try #require(await service.testingSessionID(for: workloadB.id))

        try await service.testingStop(.init(timeoutInSeconds: 1, signal: SIGTERM))

        server.stop()
        try server.waitForCompletion()

        let requests = server.recordedRequests()
        let signalRequests = requests.enumerated().filter {
            $0.element.method == .processSignal && ($0.element.processID?.hasPrefix("__workload__") ?? false)
        }
        #expect(signalRequests.count == 2)
        #expect(Set(signalRequests.compactMap { $0.element.processID }) == Set([sessionIDA, sessionIDB]))
        #expect(signalRequests.allSatisfy { $0.element.signal == SIGTERM })

        let cleanupIndex = try #require(
            requests.firstIndex(where: {
                $0.method == .processStart && ($0.processID?.hasPrefix("workload-cleanup-all-") ?? false)
            })
        )
        #expect(signalRequests.map { $0.offset }.allSatisfy { $0 < cleanupIndex })

        let snapshotA = try await service.testingInspectWorkload(workloadA.id)
        let snapshotB = try await service.testingInspectWorkload(workloadB.id)
        #expect(snapshotA.status == .stopped)
        #expect(snapshotB.status == .stopped)
        #expect(snapshotA.exitCode == 0)
        #expect(snapshotB.exitCode == 0)
    }

    @Test
    func removeStoppedImageBackedWorkloadCleansGuestInstanceDirectoryAndKeepsHostCache() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-remove-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let image = try Self.makeWorkloadImage(in: tempDirectory)
        let cacheEntry = MacOSGuestCache.workloadRootfsCacheDirectory()
            .appendingPathComponent(MacOSGuestCache.safeDigest(image.indexDigest), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheEntry) }

        let socketPath = "/tmp/sidecar-workload-remove-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingSidecarServer(
            socketPath: socketPath,
            immediateExitPrefixes: ["workload-prepare-", "workload-cleanup-", "__workload__"]
        )
        defer { server.stop() }

        server.start()

        let root = tempDirectory.appendingPathComponent("sandbox")
        let service = MacOSSandboxService(
            root: root,
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: image.store
        )
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: image.indexDigest)
        try await service.testingPrepareSandbox(containerConfiguration, state: "running")
        await service.testingInstallSidecarClient(socketPath: socketPath)

        let workloadID = "image-backed-removed"
        let workloadConfiguration = WorkloadConfiguration(
            id: workloadID,
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["override-arg"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload:latest@\(image.indexDigest)",
            workloadImageDigest: image.indexDigest
        )

        try await service.testingCreateWorkload(workloadConfiguration)
        try await service.testingStartWorkload(workloadID)
        let exitStatus = try await service.testingWaitForProcess(workloadID)
        #expect(exitStatus.exitCode == 0)

        let cachedRootfs = cacheEntry.appendingPathComponent("rootfs", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: cachedRootfs.path))

        let layout = MacOSSandboxLayout(root: root)
        let workloadStateDirectory = layout.workloadDirectoryURL(id: workloadID)
        #expect(FileManager.default.fileExists(atPath: workloadStateDirectory.path))

        try await service.testingRemoveWorkload(workloadID)

        server.stop()
        try server.waitForCompletion()

        await #expect(throws: Error.self) {
            try await service.testingInspectWorkload(workloadID)
        }
        #expect(!FileManager.default.fileExists(atPath: workloadStateDirectory.path))
        #expect(FileManager.default.fileExists(atPath: cachedRootfs.path))

        let cleanupRequest = try #require(
            server.recordedRequests().first(where: {
                $0.method == .processStart && ($0.processID?.hasPrefix("workload-cleanup-") ?? false)
            })
        )
        let cleanupScript = cleanupRequest.exec?.arguments.last ?? ""
        #expect(cleanupScript.contains("root='/var/lib/container/workloads/\(workloadID)'"))
        #expect(cleanupScript.contains("rm -rf \"$root\""))
    }

    @Test
    func oneSandboxCanHostMultipleWorkloadImages() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(prefix: "macos-workload-multi-tests")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let imageA = try Self.makeWorkloadImage(in: tempDirectory.appendingPathComponent("image-a", isDirectory: true))
        let imageB = try Self.makeWorkloadImage(in: tempDirectory.appendingPathComponent("image-b", isDirectory: true))
        let combinedStore = Self.combineWorkloadStores([imageA, imageB])

        let socketPath = "/tmp/sidecar-workload-multi-\(UUID().uuidString.prefix(8)).sock"
        let server = try RecordingSidecarServer(
            socketPath: socketPath,
            immediateExitPrefixes: ["workload-prepare-", "workload-cleanup-", "__workload__"]
        )
        defer { server.stop() }

        server.start()

        let service = MacOSSandboxService(
            root: tempDirectory.appendingPathComponent("sandbox"),
            connection: nil,
            log: Logger(label: "MacOSImageBackedWorkloadTests"),
            contentStore: combinedStore
        )
        let containerConfiguration = try Self.baseContainerConfiguration(indexDigest: imageA.indexDigest)
        try await service.testingPrepareSandbox(containerConfiguration, state: "running")
        await service.testingInstallSidecarClient(socketPath: socketPath)

        let workloadA = WorkloadConfiguration(
            id: "workload-a",
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["arg-a"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload-a:latest@\(imageA.indexDigest)",
            workloadImageDigest: imageA.indexDigest
        )
        let workloadB = WorkloadConfiguration(
            id: "workload-b",
            processConfiguration: ProcessConfiguration(
                executable: "",
                arguments: ["arg-b"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            workloadImageReference: "registry.local/example/workload-b:latest@\(imageB.indexDigest)",
            workloadImageDigest: imageB.indexDigest
        )

        try await service.testingCreateWorkload(workloadA)
        try await service.testingCreateWorkload(workloadB)
        try await service.testingStartWorkload(workloadA.id)
        try await service.testingStartWorkload(workloadB.id)

        let statusA = try await service.testingWaitForProcess(workloadA.id)
        let statusB = try await service.testingWaitForProcess(workloadB.id)
        #expect(statusA.exitCode == 0)
        #expect(statusB.exitCode == 0)

        server.stop()
        try server.waitForCompletion()

        let snapshotA = try await service.testingInspectWorkload(workloadA.id)
        let snapshotB = try await service.testingInspectWorkload(workloadB.id)
        #expect(snapshotA.configuration.injectionState == .injected)
        #expect(snapshotB.configuration.injectionState == .injected)
        #expect(snapshotA.configuration.workloadImageDigest == imageA.indexDigest)
        #expect(snapshotB.configuration.workloadImageDigest == imageB.indexDigest)

        let requests = server.recordedRequests()
        let metadataAData = try #require(
            requests.first(where: { $0.fsBegin?.path == "/var/lib/container/workloads/\(workloadA.id)/meta.json" })?.fsBegin?.inlineData
        )
        let metadataBData = try #require(
            requests.first(where: { $0.fsBegin?.path == "/var/lib/container/workloads/\(workloadB.id)/meta.json" })?.fsBegin?.inlineData
        )
        let metadataA = try JSONDecoder().decode(MacOSWorkloadGuestMetadata.self, from: metadataAData)
        let metadataB = try JSONDecoder().decode(MacOSWorkloadGuestMetadata.self, from: metadataBData)
        #expect(metadataA.workloadImageDigest == imageA.indexDigest)
        #expect(metadataB.workloadImageDigest == imageB.indexDigest)

        let injectedPaths = Set(requests.compactMap { $0.fsBegin?.path })
        #expect(injectedPaths.contains("/var/lib/container/workloads/\(workloadA.id)/rootfs/bin/hello"))
        #expect(injectedPaths.contains("/var/lib/container/workloads/\(workloadB.id)/rootfs/bin/hello"))
    }
}

extension MacOSImageBackedWorkloadTests {
    private struct CreatedWorkloadImage {
        let indexDigest: String
        let store: MockContentStore
    }

    private struct CreatedSandboxImage {
        let indexDigest: String
        let store: MockContentStore
        let hardwareModelData: Data
        let auxiliaryStorageData: Data
        let diskImageData: Data
    }

    private struct MockContentStore: ContentStore {
        let entries: [String: URL]

        func get(digest: String) async throws -> Content? {
            guard let path = entries[digest] else {
                return nil
            }
            return try LocalContent(path: path)
        }

        func get<T: Decodable>(digest: String) async throws -> T? {
            guard let content = try await get(digest: digest) else {
                return nil
            }
            return try content.decode()
        }

        @discardableResult
        func delete(digests: [String]) async throws -> ([String], UInt64) {
            throw Unimplemented()
        }

        @discardableResult
        func delete(keeping: [String]) async throws -> ([String], UInt64) {
            throw Unimplemented()
        }

        @discardableResult
        func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String] {
            throw Unimplemented()
        }

        func newIngestSession() async throws -> (id: String, ingestDir: URL) {
            throw Unimplemented()
        }

        @discardableResult
        func completeIngestSession(_ id: String) async throws -> [String] {
            throw Unimplemented()
        }

        func cancelIngestSession(_ id: String) async throws {
            throw Unimplemented()
        }

        func totalAllocatedSize() async throws -> UInt64 {
            throw Unimplemented()
        }
    }

    private struct Unimplemented: Error {}

    private static func makeSandboxImage(in directory: URL) throws -> CreatedSandboxImage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let hardwareModelData = Data("hardware-model".utf8)
        let auxiliaryStorageData = Data("auxiliary-storage".utf8)
        let diskImageData = Data("disk-image".utf8)

        let hardwareModelURL = directory.appendingPathComponent("HardwareModel.bin")
        let auxiliaryStorageURL = directory.appendingPathComponent("AuxiliaryStorage")
        let diskImageURL = directory.appendingPathComponent("Disk.img")
        try hardwareModelData.write(to: hardwareModelURL)
        try auxiliaryStorageData.write(to: auxiliaryStorageURL)
        try diskImageData.write(to: diskImageURL)

        let hardwareModelDigest = "sha256:hardware-\(UUID().uuidString)"
        let auxiliaryStorageDigest = "sha256:auxiliary-\(UUID().uuidString)"
        let diskImageDigest = "sha256:disk-\(UUID().uuidString)"
        let configDigest = "sha256:config-\(UUID().uuidString)"
        let manifestDigest = "sha256:manifest-\(UUID().uuidString)"
        let indexDigest = "sha256:index-\(UUID().uuidString)"

        let imageConfig = makeSandboxImageConfig()
        let configURL = try writeJSON(imageConfig, named: "sandbox-config.json", in: directory)
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: configDigest,
                size: Int64(try Data(contentsOf: configURL).count)
            ),
            layers: [
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.hardwareModel,
                    digest: hardwareModelDigest,
                    size: Int64(hardwareModelData.count)
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.auxiliaryStorage,
                    digest: auxiliaryStorageDigest,
                    size: Int64(auxiliaryStorageData.count)
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.diskImage,
                    digest: diskImageDigest,
                    size: Int64(diskImageData.count)
                ),
            ],
            annotations: MacOSImageContract.annotations(for: .sandbox)
        )
        let manifestURL = try writeJSON(manifest, named: "sandbox-manifest.json", in: directory)
        let index = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: Int64(try Data(contentsOf: manifestURL).count),
                    annotations: MacOSImageContract.annotations(for: .sandbox),
                    platform: .init(arch: "arm64", os: "darwin")
                )
            ]
        )
        let indexURL = try writeJSON(index, named: "sandbox-index.json", in: directory)

        return CreatedSandboxImage(
            indexDigest: indexDigest,
            store: MockContentStore(
                entries: [
                    indexDigest: indexURL,
                    manifestDigest: manifestURL,
                    configDigest: configURL,
                    hardwareModelDigest: hardwareModelURL,
                    auxiliaryStorageDigest: auxiliaryStorageURL,
                    diskImageDigest: diskImageURL,
                ]
            ),
            hardwareModelData: hardwareModelData,
            auxiliaryStorageData: auxiliaryStorageData,
            diskImageData: diskImageData
        )
    }

    private static func makeSandboxImageConfig(
        env: [String] = [
            "HOME=/var/root",
            "USER=root",
            "PATH=/usr/bin:/bin",
        ]
    ) -> ContainerizationOCI.Image {
        ContainerizationOCI.Image(
            architecture: "arm64",
            os: "darwin",
            config: .init(
                user: "root",
                env: env,
                entrypoint: nil,
                cmd: nil,
                workingDir: "/var/root",
                labels: nil,
                stopSignal: nil
            ),
            rootfs: .init(type: "layers", diffIDs: [])
        )
    }

    private static func makeWorkloadImage(
        in directory: URL,
        includeEmptyLayer: Bool = false
    ) throws -> CreatedWorkloadImage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layer1Root = directory.appendingPathComponent("layer1-root")
        let layer2Root = directory.appendingPathComponent("layer2-root")
        try FileManager.default.createDirectory(at: layer1Root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layer1Root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layer1Root.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layer2Root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layer2Root.appendingPathComponent("etc"), withIntermediateDirectories: true)

        let helloURL = layer1Root.appendingPathComponent("bin/hello")
        try Data("#!/bin/sh\necho hello\n".utf8).write(to: helloURL)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: helloURL.path)

        let staleURL = layer1Root.appendingPathComponent("tmp/stale.txt")
        try Data("stale\n".utf8).write(to: staleURL)
        try Data().write(to: layer2Root.appendingPathComponent("tmp/.wh.stale.txt"))
        try Data("from-layer-2\n".utf8).write(to: layer2Root.appendingPathComponent("etc/config.txt"))

        let layer1Tar = directory.appendingPathComponent("layer1.tar")
        let layer2Tar = directory.appendingPathComponent("layer2.tar")
        try createTarArchive(
            from: layer1Root,
            to: layer1Tar,
            ownerOverrides: [
                "bin/hello": (uid: 501, gid: 20),
                "workspace": (uid: 501, gid: 20),
            ]
        )
        try createTarArchive(from: layer2Root, to: layer2Tar)

        let emptyLayerTar = directory.appendingPathComponent("empty-layer.tar")
        if includeEmptyLayer {
            let writer = try ArchiveWriter(format: .pax, filter: .none, file: emptyLayerTar)
            try writer.finishEncoding()
        }

        let emptyLayerDigest = "sha256:empty-layer-\(UUID().uuidString)"
        let layer1Digest = "sha256:layer1-\(UUID().uuidString)"
        let layer2Digest = "sha256:layer2-\(UUID().uuidString)"
        let configDigest = "sha256:config-\(UUID().uuidString)"
        let manifestDigest = "sha256:manifest-\(UUID().uuidString)"
        let indexDigest = "sha256:index-\(UUID().uuidString)"

        let imageConfig = ContainerizationOCI.Image(
            architecture: "arm64",
            os: "darwin",
            config: .init(
                user: "nobody",
                env: ["PATH=/usr/bin:/bin", "GREETING=hello"],
                entrypoint: ["/bin/hello"],
                cmd: ["default-arg"],
                workingDir: "/workspace",
                labels: nil,
                stopSignal: nil
            ),
            rootfs: .init(type: "layers", diffIDs: [])
        )
        let configURL = try writeJSON(imageConfig, named: "config.json", in: directory)
        var layers = [Descriptor]()
        if includeEmptyLayer {
            layers.append(
                Descriptor(
                    mediaType: MediaTypes.imageLayer,
                    digest: emptyLayerDigest,
                    size: Int64(try Data(contentsOf: emptyLayerTar).count)
                )
            )
        }
        layers.append(contentsOf: [
            Descriptor(mediaType: MediaTypes.imageLayer, digest: layer1Digest, size: Int64(try Data(contentsOf: layer1Tar).count)),
            Descriptor(mediaType: MediaTypes.imageLayer, digest: layer2Digest, size: Int64(try Data(contentsOf: layer2Tar).count)),
        ])
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: configDigest, size: Int64(try Data(contentsOf: configURL).count)),
            layers: layers,
            annotations: MacOSImageContract.annotations(for: .workload)
        )
        let manifestURL = try writeJSON(manifest, named: "manifest.json", in: directory)
        let index = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: Int64(try Data(contentsOf: manifestURL).count),
                    annotations: MacOSImageContract.annotations(for: .workload),
                    platform: .init(arch: "arm64", os: "darwin")
                )
            ]
        )

        let indexURL = try writeJSON(index, named: "index.json", in: directory)

        var entries = [
            indexDigest: indexURL,
            manifestDigest: manifestURL,
            configDigest: configURL,
            layer1Digest: layer1Tar,
            layer2Digest: layer2Tar,
        ]
        if includeEmptyLayer {
            entries[emptyLayerDigest] = emptyLayerTar
        }

        return CreatedWorkloadImage(
            indexDigest: indexDigest,
            store: MockContentStore(entries: entries)
        )
    }

    private static func combineWorkloadStores(_ images: [CreatedWorkloadImage]) -> MockContentStore {
        let entries = images.reduce(into: [String: URL]()) { partialResult, image in
            partialResult.merge(image.store.entries, uniquingKeysWith: { _, new in new })
        }
        return MockContentStore(entries: entries)
    }

    private static func writeJSON<T: Encodable>(_ value: T, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url)
        return url
    }

    private static func createTarArchive(
        from sourceRoot: URL,
        to outputURL: URL,
        ownerOverrides: [String: (uid: UInt32, gid: UInt32)] = [:]
    ) throws {
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: outputURL)
        guard
            let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.fileResourceTypeKey],
                options: .producesRelativePathURLs
            )
        else {
            throw POSIXError(.ENOTDIR)
        }

        for case let relativeURL as URL in enumerator {
            let relativePath = relativeURL.relativePath
            let sourceURL = sourceRoot.appendingPathComponent(relativePath)
            let values = try sourceURL.resourceValues(forKeys: [.fileResourceTypeKey])
            guard let fileType = values.fileResourceType else {
                continue
            }
            guard [.directory, .regular, .symbolicLink].contains(fileType) else {
                continue
            }

            var statInfo = stat()
            guard lstat(sourceURL.path, &statInfo) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let entry = WriteEntry()
            entry.path = relativePath
            entry.fileType = fileType
            entry.permissions = statInfo.st_mode & 0o7777
            entry.modificationDate = Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec))
            if let owner = ownerOverrides[relativePath] {
                entry.owner = uid_t(owner.uid)
                entry.group = gid_t(owner.gid)
            } else {
                entry.owner = statInfo.st_uid
                entry.group = statInfo.st_gid
            }

            switch fileType {
            case .regular:
                let data = try Data(contentsOf: sourceURL)
                entry.size = Int64(data.count)
                try writer.writeEntry(entry: entry, data: data)
            case .symbolicLink:
                entry.symlinkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: sourceURL.path)
                try writer.writeEntry(entry: entry, data: nil as UnsafeRawBufferPointer?)
            default:
                entry.size = 0
                try writer.writeEntry(entry: entry, data: nil as UnsafeRawBufferPointer?)
            }
        }
        try writer.finishEncoding()
    }

    private static func baseContainerConfiguration(indexDigest: String) throws -> ContainerConfiguration {
        let imageJSON = """
            {
              "reference": "example/macos:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "\(indexDigest)",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        var configuration = ContainerConfiguration(
            id: "sandbox-under-test",
            image: image,
            process: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: [],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            )
        )
        configuration.runtimeHandler = "container-runtime-macos"
        configuration.platform = .init(arch: "arm64", os: "darwin")
        return configuration
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func normalizedDirectoryPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

private final class RecordingSidecarServer: @unchecked Sendable {
    private let socketPath: String
    private let immediateExitPrefixes: [String]
    private let exitOnSignalPrefixes: [String]
    private let requests = LockedBox<[MacOSSidecarRequest]>([])
    private let done = DispatchSemaphore(value: 0)
    private let errorBox = LockedBox<Error?>(nil)
    private let listenFD = LockedBox<Int32?>(nil)
    private let clientFD = LockedBox<Int32?>(nil)

    init(
        socketPath: String,
        immediateExitPrefixes: [String] = ["workload-prepare-", "workload-cleanup-"],
        exitOnSignalPrefixes: [String] = []
    ) throws {
        self.socketPath = socketPath
        self.immediateExitPrefixes = immediateExitPrefixes
        self.exitOnSignalPrefixes = exitOnSignalPrefixes
        let listeningFD = try makeUnixListener(path: socketPath)
        self.listenFD.withLock { fd in
            fd = listeningFD
        }
    }

    func start() {
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            do {
                guard let listeningFD = listenFD.withLock({ $0 }) else {
                    return
                }
                let accepted = Darwin.accept(listeningFD, nil, nil)
                guard accepted >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                clientFD.withLock { $0 = accepted }
                defer {
                    let ownedClientFD = clientFD.withLock { fd -> Int32? in
                        guard fd == accepted else {
                            return nil
                        }
                        fd = nil
                        return accepted
                    }
                    closeIfValid(ownedClientFD)
                }

                while true {
                    let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: accepted)
                    guard envelope.kind == .request, let request = envelope.request else {
                        continue
                    }
                    requests.withLock { $0.append(request) }

                    switch request.method {
                    case .fsBegin, .fsChunk, .fsEnd:
                        try writeResponse(.success(requestID: request.requestID), to: accepted)

                    case .processStart:
                        try writeResponse(.success(requestID: request.requestID), to: accepted)
                        if let processID = request.processID, shouldEmitImmediateExit(for: processID, prefixes: immediateExitPrefixes) {
                            try writeEvent(.init(event: .processExit, processID: processID, exitCode: 0), to: accepted)
                        }

                    case .processSignal:
                        try writeResponse(.success(requestID: request.requestID), to: accepted)
                        if let processID = request.processID, shouldEmitImmediateExit(for: processID, prefixes: exitOnSignalPrefixes) {
                            try writeEvent(.init(event: .processExit, processID: processID, exitCode: 0), to: accepted)
                        }

                    default:
                        try writeResponse(.success(requestID: request.requestID), to: accepted)
                    }
                }
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(ECONNABORTED) || nsError.code == Int(EBADF)) {
                    return
                }
                if nsError.localizedDescription.contains("unexpected EOF") {
                    return
                }
                errorBox.withLock { $0 = error }
            }
        }
    }

    func stop() {
        let listeningFD = listenFD.withLock { fd -> Int32? in
            let current = fd
            fd = nil
            return current
        }
        let clientFDToClose = clientFD.withLock { fd -> Int32? in
            let current = fd
            fd = nil
            return current
        }
        if let clientFDToClose, clientFDToClose >= 0 {
            _ = Darwin.shutdown(clientFDToClose, SHUT_RDWR)
            Darwin.close(clientFDToClose)
        }
        if let listeningFD {
            _ = Darwin.shutdown(listeningFD, SHUT_RDWR)
            Darwin.close(listeningFD)
        }
        _ = unlink(socketPath)
    }

    func waitForCompletion(timeout: TimeInterval = 2.0) throws {
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = errorBox.withLock({ $0 }) {
            throw error
        }
    }

    func recordedRequests() -> [MacOSSidecarRequest] {
        requests.withLock { $0 }
    }
}

private func shouldEmitImmediateExit(for processID: String, prefixes: [String]) -> Bool {
    prefixes.contains { processID.hasPrefix($0) }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func makeUnixListener(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    _ = unlink(path)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let maxPathCount = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < maxPathCount else {
        Darwin.close(fd)
        throw POSIXError(.ENAMETOOLONG)
    }

    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
        rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
        for (index, byte) in pathBytes.enumerated() {
            rawBuffer[index] = byte
        }
    }

    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.bind(fd, sockaddrPtr, addrLen)
        }
    }
    guard bindResult == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        throw error
    }
    guard Darwin.listen(fd, 8) == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        throw error
    }
    return fd
}

private func writeResponse(_ response: MacOSSidecarResponse, to fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.response(response), fd: fd)
}

private func writeEvent(_ event: MacOSSidecarEvent, to fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.event(event), fd: fd)
}

private func closeIfValid(_ fd: Int32?) {
    guard let fd, fd >= 0 else {
        return
    }
    Darwin.close(fd)
}
#endif
