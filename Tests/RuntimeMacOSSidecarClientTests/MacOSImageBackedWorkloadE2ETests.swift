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
import ContainerAPIClient
@testable import ContainerCommands
import ContainerResource
import ContainerSandboxServiceClient
import Containerization
import ContainerizationOCI
import Foundation
import Testing

@Suite(.serialized, .enabled(if: isMacOSImageBackedWorkloadE2EEnabled(), "requires CONTAINER_ENABLE_MACOS_WORKLOAD_E2E=1 on macOS 26+"))
struct MacOSImageBackedWorkloadE2ETests {
    @Test
    func imageBackedWorkloadRunsInsideRealGuest() async throws {
        let baseReference = ProcessInfo.processInfo.environment["CONTAINER_MACOS_BASE_REF"] ?? "ghcr.io/jianliang00/macos-base:26.3"
        let tempDirectory = try makeTemporaryDirectory(prefix: "macos-workload-e2e")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let workloadReference = "local/macos-workload-e2e:\(UUID().uuidString.lowercased())"
        let archiveURL = try createWorkloadImageArchive(reference: workloadReference, in: tempDirectory)

        let containerClient = ContainerClient()
        let containerID = "macos-workload-e2e-\(UUID().uuidString.lowercased())"

        do {
            _ = try await ClientImage.load(from: archiveURL.path)
            let workloadImage = try await ClientImage.get(reference: workloadReference)
            try await runImageBackedWorkloadLifecycle(
                containerClient: containerClient,
                baseReference: baseReference,
                containerID: containerID,
                workloadReference: workloadReference,
                workloadDigest: workloadImage.digest
            )
        } catch {
            try? await cleanupContainer(client: containerClient, id: containerID)
            try? await ClientImage.delete(reference: workloadReference, garbageCollect: true)
            throw error
        }

        try await cleanupContainer(client: containerClient, id: containerID)
        try? await ClientImage.delete(reference: workloadReference, garbageCollect: true)
    }

    @Test
    func oneSandboxRunsMultipleImageBackedWorkloadsInsideRealGuest() async throws {
        let baseReference = ProcessInfo.processInfo.environment["CONTAINER_MACOS_BASE_REF"] ?? "ghcr.io/jianliang00/macos-base:26.3"
        let tempDirectory = try makeTemporaryDirectory(prefix: "macos-workload-multi-e2e")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let workloadReferenceA = "local/macos-workload-multi-a:\(UUID().uuidString.lowercased())"
        let workloadReferenceB = "local/macos-workload-multi-b:\(UUID().uuidString.lowercased())"
        let archiveA = try createWorkloadImageArchive(
            reference: workloadReferenceA,
            in: tempDirectory.appendingPathComponent("workload-a", isDirectory: true),
            payloadMessage: "payload-a"
        )
        let archiveB = try createWorkloadImageArchive(
            reference: workloadReferenceB,
            in: tempDirectory.appendingPathComponent("workload-b", isDirectory: true),
            payloadMessage: "payload-b"
        )

        let containerClient = ContainerClient()
        let containerID = "macos-workload-multi-e2e-\(UUID().uuidString.lowercased())"

        do {
            _ = try await ClientImage.load(from: archiveA.path)
            _ = try await ClientImage.load(from: archiveB.path)
            let workloadImageA = try await ClientImage.get(reference: workloadReferenceA)
            let workloadImageB = try await ClientImage.get(reference: workloadReferenceB)

            let (_, sandboxClient) = try await bootstrapWorkloadSandbox(
                containerClient: containerClient,
                baseReference: baseReference,
                containerID: containerID
            )

            let stdoutPipeA = Pipe()
            let stderrPipeA = Pipe()
            let stdoutPipeB = Pipe()
            let stderrPipeB = Pipe()

            let workloadA = makeWorkloadConfiguration(
                id: "hello-a",
                argument: "arg-a",
                workloadReference: workloadReferenceA,
                workloadDigest: workloadImageA.digest
            )
            let workloadB = makeWorkloadConfiguration(
                id: "hello-b",
                argument: "arg-b",
                workloadReference: workloadReferenceB,
                workloadDigest: workloadImageB.digest
            )

            try await sandboxClient.createWorkload(
                workloadA,
                stdio: [nil, stdoutPipeA.fileHandleForWriting, stderrPipeA.fileHandleForWriting]
            )
            try await sandboxClient.createWorkload(
                workloadB,
                stdio: [nil, stdoutPipeB.fileHandleForWriting, stderrPipeB.fileHandleForWriting]
            )
            try stdoutPipeA.fileHandleForWriting.close()
            try stderrPipeA.fileHandleForWriting.close()
            try stdoutPipeB.fileHandleForWriting.close()
            try stderrPipeB.fileHandleForWriting.close()

            try await sandboxClient.startWorkload(workloadA.id)
            try await sandboxClient.startWorkload(workloadB.id)

            let exitStatusA = try await sandboxClient.wait(workloadA.id)
            let exitStatusB = try await sandboxClient.wait(workloadB.id)
            #expect(exitStatusA.exitCode == 0)
            #expect(exitStatusB.exitCode == 0)

            let snapshotA = try await sandboxClient.inspectWorkload(workloadA.id)
            let snapshotB = try await sandboxClient.inspectWorkload(workloadB.id)
            #expect(snapshotA.configuration.injectionState == .injected)
            #expect(snapshotB.configuration.injectionState == .injected)
            #expect(snapshotA.configuration.workloadImageDigest == workloadImageA.digest)
            #expect(snapshotB.configuration.workloadImageDigest == workloadImageB.digest)

            let cacheRoot = MacOSGuestCache.workloadRootfsCacheDirectory()
            let cachedRootfsA =
                cacheRoot
                .appendingPathComponent(MacOSGuestCache.safeDigest(workloadImageA.digest), isDirectory: true)
                .appendingPathComponent("rootfs", isDirectory: true)
            let cachedRootfsB =
                cacheRoot
                .appendingPathComponent(MacOSGuestCache.safeDigest(workloadImageB.digest), isDirectory: true)
                .appendingPathComponent("rootfs", isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: cachedRootfsA.path))
            #expect(FileManager.default.fileExists(atPath: cachedRootfsB.path))

            let stdoutA = try readAllText(from: stdoutPipeA.fileHandleForReading)
            let stderrA = try readAllText(from: stderrPipeA.fileHandleForReading)
            let stdoutB = try readAllText(from: stdoutPipeB.fileHandleForReading)
            let stderrB = try readAllText(from: stderrPipeB.fileHandleForReading)
            #expect(stderrA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(stderrB.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(stdoutA.contains("arg=arg-a"))
            #expect(stdoutB.contains("arg=arg-b"))
            #expect(stdoutA.contains("/var/lib/container/workloads/\(workloadA.id)/rootfs/workspace"))
            #expect(stdoutB.contains("/var/lib/container/workloads/\(workloadB.id)/rootfs/workspace"))
            #expect(stdoutA.contains("payload-a"))
            #expect(stdoutB.contains("payload-b"))
        } catch {
            try? await cleanupContainer(client: containerClient, id: containerID)
            try? await ClientImage.delete(reference: workloadReferenceA, garbageCollect: true)
            try? await ClientImage.delete(reference: workloadReferenceB, garbageCollect: true)
            throw error
        }

        try await cleanupContainer(client: containerClient, id: containerID)
        try? await ClientImage.delete(reference: workloadReferenceA, garbageCollect: true)
        try? await ClientImage.delete(reference: workloadReferenceB, garbageCollect: true)
    }
}

@Suite(.serialized, .enabled(if: isMacOSImageBackedWorkloadRegistryE2EEnabled(), "requires CONTAINER_ENABLE_MACOS_WORKLOAD_REGISTRY_E2E=1 and macOS 26+"))
struct MacOSImageBackedWorkloadRegistryE2ETests {
    @Test
    func pushedAndPulledWorkloadImageRunsInsideRealGuest() async throws {
        let baseReference = ProcessInfo.processInfo.environment["CONTAINER_MACOS_BASE_REF"] ?? "ghcr.io/jianliang00/macos-base:26.3"
        let workloadReference = remoteWorkloadReference()
        let tempDirectory = try makeTemporaryDirectory(prefix: "macos-workload-registry-e2e")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let archiveURL = try createWorkloadImageArchive(reference: workloadReference, in: tempDirectory)
        let containerClient = ContainerClient()
        let containerID = "macos-workload-registry-e2e-\(UUID().uuidString.lowercased())"

        do {
            _ = try await ClientImage.load(from: archiveURL.path)
            let loadedImage = try await ClientImage.get(reference: workloadReference)
            try await loadedImage.push(scheme: .https, progressUpdate: nil)
            try await ClientImage.delete(reference: workloadReference, garbageCollect: true)

            let pulledImage = try await ClientImage.pull(
                reference: workloadReference,
                platform: .init(arch: "arm64", os: "darwin"),
                scheme: .https
            )
            try await validatePulledWorkloadImageContract(pulledImage)

            try await runImageBackedWorkloadLifecycle(
                containerClient: containerClient,
                baseReference: baseReference,
                containerID: containerID,
                workloadReference: workloadReference,
                workloadDigest: pulledImage.digest
            )
        } catch {
            try? await cleanupContainer(client: containerClient, id: containerID)
            try? await ClientImage.delete(reference: workloadReference, garbageCollect: true)
            throw error
        }

        try await cleanupContainer(client: containerClient, id: containerID)
        try? await ClientImage.delete(reference: workloadReference, garbageCollect: true)
    }
}

private func isMacOSImageBackedWorkloadE2EEnabled() -> Bool {
    guard ProcessInfo.processInfo.environment["CONTAINER_ENABLE_MACOS_WORKLOAD_E2E"] == "1" else {
        return false
    }
    guard #available(macOS 26, *) else {
        return false
    }
    return true
}

private func isMacOSImageBackedWorkloadRegistryE2EEnabled() -> Bool {
    guard ProcessInfo.processInfo.environment["CONTAINER_ENABLE_MACOS_WORKLOAD_REGISTRY_E2E"] == "1" else {
        return false
    }
    return isMacOSImageBackedWorkloadE2EEnabled()
}

private func makeContainerConfiguration(
    id: String,
    image: ImageDescription
) -> ContainerConfiguration {
    var configuration = ContainerConfiguration(
        id: id,
        image: image,
        process: ProcessConfiguration(
            executable: "/usr/bin/tail",
            arguments: ["-f", "/dev/null"],
            environment: ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
    )
    configuration.platform = .init(arch: "arm64", os: "darwin")
    configuration.runtimeHandler = "container-runtime-macos"
    configuration.resources = .init()
    configuration.resources.cpus = 4
    configuration.resources.memoryInBytes = 8 * 1024 * 1024 * 1024
    configuration.macosGuest = .init(
        snapshotEnabled: false,
        guiEnabled: false,
        agentPort: 27_000,
        networkBackend: .virtualizationNAT
    )
    return configuration
}

private func waitForSandboxStatus(
    client: SandboxClient,
    status: RuntimeStatus,
    timeoutSeconds: TimeInterval
) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let snapshot = try await client.state()
        if snapshot.status == status {
            return
        }
        try await Task.sleep(for: .seconds(2))
    }

    let snapshot = try await client.state()
    throw NSError(
        domain: "MacOSImageBackedWorkloadE2ETests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "sandbox did not reach \(status.rawValue); last status=\(snapshot.status.rawValue)"]
    )
}

private func waitForContainerStatus(
    client: ContainerClient,
    id: String,
    status: RuntimeStatus,
    timeoutSeconds: TimeInterval
) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let snapshot = try await client.get(id: id)
        if snapshot.status == status {
            return
        }
        try await Task.sleep(for: .seconds(2))
    }

    let snapshot = try await client.get(id: id)
    throw NSError(
        domain: "MacOSImageBackedWorkloadE2ETests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "container \(id) did not reach \(status.rawValue); last status=\(snapshot.status.rawValue)"]
    )
}

private func cleanupContainer(client: ContainerClient, id: String) async throws {
    try? await client.stop(id: id)
    try? await client.delete(id: id, force: true)
}

private func runImageBackedWorkloadLifecycle(
    containerClient: ContainerClient,
    baseReference: String,
    containerID: String,
    workloadReference: String,
    workloadDigest: String
) async throws {
    let (_, sandboxClient) = try await bootstrapWorkloadSandbox(
        containerClient: containerClient,
        baseReference: baseReference,
        containerID: containerID
    )

    let workloadID = "hello"
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let workloadConfiguration = makeWorkloadConfiguration(
        id: workloadID,
        argument: "e2e-ok",
        workloadReference: workloadReference,
        workloadDigest: workloadDigest
    )

    try await sandboxClient.createWorkload(
        workloadConfiguration,
        stdio: [nil, stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting]
    )
    try stdoutPipe.fileHandleForWriting.close()
    try stderrPipe.fileHandleForWriting.close()

    try await sandboxClient.startWorkload(workloadID)
    let exitStatus = try await sandboxClient.wait(workloadID)
    #expect(exitStatus.exitCode == 0)

    let snapshot = try await sandboxClient.inspectWorkload(workloadID)
    #expect(snapshot.configuration.injectionState == .injected)
    #expect(snapshot.configuration.processConfiguration.executable == "/bin/hello")
    #expect(snapshot.configuration.processConfiguration.workingDirectory == "/workspace")

    let cachedRootfs = MacOSGuestCache.workloadRootfsCacheDirectory()
        .appendingPathComponent(MacOSGuestCache.safeDigest(workloadDigest), isDirectory: true)
        .appendingPathComponent("rootfs", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: cachedRootfs.path))

    let stdout = try readAllText(from: stdoutPipe.fileHandleForReading)
    let stderr = try readAllText(from: stderrPipe.fileHandleForReading)
    #expect(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(stdout.contains("arg=e2e-ok"))
    #expect(stdout.contains("/var/lib/container/workloads/\(workloadID)/rootfs/workspace"))
    #expect(stdout.contains("payload-from-image"))
}

private func bootstrapWorkloadSandbox(
    containerClient: ContainerClient,
    baseReference: String,
    containerID: String
) async throws -> (ContainerConfiguration, SandboxClient) {
    let baseImage = try await ClientImage.get(reference: baseReference)
    let configuration = makeContainerConfiguration(
        id: containerID,
        image: baseImage.description
    )
    try await containerClient.create(configuration: configuration, options: .default)
    _ = try await containerClient.bootstrap(id: containerID, stdio: [nil, nil, nil])
    try await waitForContainerStatus(client: containerClient, id: containerID, status: .running, timeoutSeconds: 180)

    let sandboxClient = try await SandboxClient.create(id: containerID, runtime: configuration.runtimeHandler)
    try await waitForSandboxStatus(client: sandboxClient, status: .running, timeoutSeconds: 180)
    return (configuration, sandboxClient)
}

private func makeWorkloadConfiguration(
    id: String,
    argument: String,
    workloadReference: String,
    workloadDigest: String
) -> WorkloadConfiguration {
    WorkloadConfiguration(
        id: id,
        processConfiguration: ProcessConfiguration(
            executable: "",
            arguments: [argument],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        ),
        workloadImageReference: "\(workloadReference)@\(workloadDigest)",
        workloadImageDigest: workloadDigest
    )
}

private func readAllText(from handle: FileHandle) throws -> String {
    let data = try handle.readToEnd() ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func validatePulledWorkloadImageContract(_ image: ClientImage) async throws {
    let platform = try Platform(from: "darwin/arm64")
    let index = try await image.index()
    guard let descriptor = index.manifests.first(where: { $0.platform == platform }) else {
        throw NSError(
            domain: "MacOSImageBackedWorkloadRegistryE2ETests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "missing darwin/arm64 manifest in pulled workload image"]
        )
    }
    let manifest = try await image.manifest(for: platform)
    let config = try await image.config(for: platform)
    try MacOSImageContract.validateWorkloadImage(
        descriptorAnnotations: descriptor.annotations,
        manifest: manifest,
        imageConfig: config
    )
}

private func remoteWorkloadReference() -> String {
    if let explicitReference = ProcessInfo.processInfo.environment["CONTAINER_MACOS_WORKLOAD_REGISTRY_REF"],
        !explicitReference.isEmpty
    {
        return explicitReference
    }
    return "ttl.sh/macos-workload-\(UUID().uuidString.lowercased()):1h"
}

private func createWorkloadImageArchive(
    reference: String,
    in temporaryRoot: URL,
    payloadMessage: String = "payload-from-image"
) throws -> URL {
    let fileManager = FileManager.default
    let payloadRoot = temporaryRoot.appendingPathComponent("payload", isDirectory: true)
    try fileManager.createDirectory(at: payloadRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: payloadRoot.appendingPathComponent("workspace"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: payloadRoot.appendingPathComponent("etc"), withIntermediateDirectories: true)

    let executableURL = payloadRoot.appendingPathComponent("bin/hello")
    try Data(
        """
        #!/bin/sh
        printf 'arg=%s\n' "$1"
        pwd
        cat ../etc/message.txt
        """.utf8
    ).write(to: executableURL)
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: executableURL.path)
    try Data("\(payloadMessage)\n".utf8).write(to: payloadRoot.appendingPathComponent("etc/message.txt"))

    let archiveURL = temporaryRoot.appendingPathComponent("workload-image.tar")
    try MacOSWorkloadPackager.package(
        payloadRoot: payloadRoot,
        outputTar: archiveURL,
        reference: reference,
        imageConfig: ContainerizationOCI.Image(
            created: "1970-01-01T00:00:00Z",
            architecture: "arm64",
            os: "darwin",
            config: .init(
                env: ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"],
                entrypoint: ["/bin/hello"],
                cmd: ["default-arg"],
                workingDir: "/workspace"
            ),
            rootfs: .init(type: "layers", diffIDs: [])
        )
    )
    return archiveURL
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
#endif
