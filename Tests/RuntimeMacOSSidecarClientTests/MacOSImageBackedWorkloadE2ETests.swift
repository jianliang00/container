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

            let workloadID = "hello"
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let workloadConfiguration = WorkloadConfiguration(
                id: workloadID,
                processConfiguration: ProcessConfiguration(
                    executable: "",
                    arguments: ["e2e-ok"],
                    environment: [],
                    workingDirectory: "/",
                    terminal: false,
                    user: .id(uid: 0, gid: 0)
                ),
                workloadImageReference: "\(workloadReference)@\(workloadImage.digest)",
                workloadImageDigest: workloadImage.digest
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

            let stdout = try readAllText(from: stdoutPipe.fileHandleForReading)
            let stderr = try readAllText(from: stderrPipe.fileHandleForReading)
            #expect(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(stdout.contains("arg=e2e-ok"))
            #expect(stdout.contains("/var/lib/container/workloads/\(workloadID)/rootfs/workspace"))
            #expect(stdout.contains("payload-from-image"))
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

private func readAllText(from handle: FileHandle) throws -> String {
    let data = try handle.readToEnd() ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func createWorkloadImageArchive(reference: String, in temporaryRoot: URL) throws -> URL {
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
    try Data("payload-from-image\n".utf8).write(to: payloadRoot.appendingPathComponent("etc/message.txt"))

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
