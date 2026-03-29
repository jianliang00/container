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
import ContainerSandboxServiceClient
import Containerization
import Foundation
import Testing

extension TestCLIMacOSBuildBase {
    @Suite(.enabled(if: CLITest.isCLIServiceAvailable(), "requires running container API service"))
    class CLIMacOSBuildFailureTest: TestCLIMacOSBuildBase {
        @Test func testDarwinBuildRejectsMixedPlatforms() throws {
            let tempDir = try createTempDir()
            try createContext(tempDir: tempDir, dockerfile: "FROM scratch\n")

            let response = try run(arguments: [
                "build",
                "--platform", "linux/arm64,darwin/arm64",
                tempDir.appendingPathComponent("context").path,
            ])

            assertFailure(response, contains: "darwin builds do not support mixed or multi-target platforms")
            assertDidNotDialLinuxBuilder(response)
        }

        @Test func testDarwinBuildRejectsDarwinAMD64() throws {
            let tempDir = try createTempDir()
            try createContext(tempDir: tempDir, dockerfile: "FROM scratch\n")

            let response = try run(arguments: [
                "build",
                "--platform", "darwin/amd64",
                tempDir.appendingPathComponent("context").path,
            ])

            assertFailure(response, contains: "darwin builds require darwin/arm64")
            assertDidNotDialLinuxBuilder(response)
        }

        @Test func testDarwinBuildRejectsMalformedUSERInstruction() throws {
            let tempDir = try createTempDir()
            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM \(macOSBaseReference)
                    USER builder wheel
                    """
            )

            let response = try runDarwinBuild(tempDir: tempDir)
            assertFailure(response, contains: "USER requires exactly one user specification")
            assertDidNotDialLinuxBuilder(response)
        }

        @Test func testDarwinBuildRejectsAddURLInstruction() throws {
            let tempDir = try createTempDir()
            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM \(macOSBaseReference)
                    ADD https://example.com/file.tar /tmp/file.tar
                    """
            )

            let response = try runDarwinBuild(tempDir: tempDir)
            assertFailure(response, contains: "darwin builds do not support ADD <url> in phase 1")
            assertDidNotDialLinuxBuilder(response)
        }

        @Test func testDarwinBuildRejectsCopyFromUnknownStage() throws {
            let tempDir = try createTempDir()
            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM \(macOSBaseReference)
                    COPY --from=missing /tmp/out /tmp/out
                    """
            )

            let response = try runDarwinBuild(tempDir: tempDir)
            assertFailure(response, contains: "COPY --from stage missing not found")
            assertDidNotDialLinuxBuilder(response)
        }

        @Test func testDarwinWorkloadBuildRequiresBuildSandboxImage() throws {
            let tempDir = try createTempDir()
            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM scratch
                    COPY hello.sh /bin/hello
                    """,
                context: [
                    .file("hello.sh", content: Data("#!/bin/sh\necho hello\n".utf8))
                ]
            )

            let response = try runDarwinBuild(
                tempDir: tempDir,
                otherArgs: ["--macos-build-mode", "workload"]
            )
            assertFailure(response, contains: "macOS workload builds require --build-sandbox-image")
            assertDidNotDialLinuxBuilder(response)
        }

        @Test func testDarwinWorkloadBuildRejectsNonScratchFrom() throws {
            let tempDir = try createTempDir()
            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM \(macOSBaseReference)
                    COPY hello.sh /bin/hello
                    """,
                context: [
                    .file("hello.sh", content: Data("#!/bin/sh\necho hello\n".utf8))
                ]
            )

            let response = try runDarwinBuild(
                tempDir: tempDir,
                otherArgs: [
                    "--macos-build-mode", "workload",
                    "--build-sandbox-image", macOSBaseReference,
                ]
            )
            assertFailure(response, contains: "macOS workload builds require FROM scratch")
            assertDidNotDialLinuxBuilder(response)
        }
    }

    @Suite(.enabled(if: TestCLIMacOSBuildBase.isMacOSBuildE2EEnabled(), "requires CONTAINER_ENABLE_MACOS_BUILD_E2E=1"))
    class CLIMacOSBuildE2ETest: TestCLIMacOSBuildBase {
        @Test func testDarwinBuildSmokeAndRoute() throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let imageName = "local/macos-build-smoke:\(UUID().uuidString)"
            defer { deleteImageIfExists(imageName) }

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM --platform=darwin/arm64 \(macOSBaseReference)
                    RUN sw_vers
                    """
            )

            let response = try runDarwinBuild(tempDir: tempDir, tag: imageName)
            #expect(response.status == 0, "expected darwin build to succeed: \(response.error)")
            assertDidNotDialLinuxBuilder(response)

            let output = try runDarwinContainer(image: imageName, command: ["/usr/bin/sw_vers"])
            #expect(output.contains("macOS"))
        }

        @Test func testDarwinBuildUserInstructionAffectsRunAndImageConfig() throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let imageName = "local/macos-build-user:\(UUID().uuidString)"
            defer { deleteImageIfExists(imageName) }

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM \(macOSBaseReference)
                    USER nobody
                    RUN test "$(/usr/bin/id -un)" = "nobody"
                    ENTRYPOINT ["/usr/bin/id"]
                    CMD ["-un"]
                    """
            )

            let response = try runDarwinBuild(tempDir: tempDir, tag: imageName)
            #expect(response.status == 0, "expected darwin USER build to succeed: \(response.error)")
            assertDidNotDialLinuxBuilder(response)

            let runOutput = try runDarwinContainer(image: imageName, command: [])
            #expect(runOutput.contains("nobody"))

            let inspect = try run(arguments: ["image", "inspect", imageName])
            #expect(inspect.status == 0)
            #expect(inspect.output.contains("nobody"))
        }

        @Test func testDarwinBuildCopyDockerignoreAndSymlink() throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let imageName = "local/macos-build-copy:\(UUID().uuidString)"
            defer { deleteImageIfExists(imageName) }

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM \(macOSBaseReference)
                    WORKDIR /opt/copy-check
                    COPY payload/ /opt/copy-check/
                    RUN test -f /opt/copy-check/keep.txt
                    RUN test -L /opt/copy-check/link.txt
                    RUN test "$(/usr/bin/readlink /opt/copy-check/link.txt)" = "keep.txt"
                    RUN test ! -e /opt/copy-check/debug.log
                    RUN test ! -e /opt/copy-check/nested/app.log
                    """,
                context: [
                    .file("payload/keep.txt", content: Data("keep\n".utf8)),
                    .file("payload/debug.log", content: Data("ignore\n".utf8)),
                    .file("payload/nested/app.log", content: Data("ignore\n".utf8)),
                    .symbolicLink("payload/link.txt", target: "keep.txt"),
                    .file(".dockerignore", content: Data("*.log\n**/*.log\n".utf8)),
                ]
            )

            let response = try runDarwinBuild(tempDir: tempDir, tag: imageName)
            #expect(response.status == 0, "expected darwin COPY build to succeed: \(response.error)")
            assertDidNotDialLinuxBuilder(response)

            let output = try runDarwinContainer(image: imageName, command: ["/bin/sh", "-lc", "ls -l /opt/copy-check"])
            #expect(output.contains("keep.txt"))
            #expect(output.contains("link.txt"))
            #expect(output.contains("-> keep.txt"))
            #expect(!output.contains("debug.log"))
        }

        @Test func testDarwinBuildCopyFromPreviousStage() throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let imageName = "local/macos-build-copy-from:\(UUID().uuidString)"
            defer { deleteImageIfExists(imageName) }

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM \(macOSBaseReference) AS build
                    RUN /bin/sh -lc 'mkdir -p /tmp/out/sub && printf from-stage > /tmp/out/sub/hello.txt && ln -s sub/hello.txt /tmp/out/link.txt'

                    FROM \(macOSBaseReference)
                    COPY --from=build /tmp/out/ /opt/copied/
                    RUN test -f /opt/copied/sub/hello.txt
                    RUN test -L /opt/copied/link.txt
                    RUN test "$(/usr/bin/readlink /opt/copied/link.txt)" = "sub/hello.txt"
                    CMD ["/bin/cat", "/opt/copied/sub/hello.txt"]
                    """
            )

            let response = try runDarwinBuild(tempDir: tempDir, tag: imageName)
            #expect(response.status == 0, "expected darwin COPY --from build to succeed: \(response.error)")
            assertDidNotDialLinuxBuilder(response)

            let output = try runDarwinContainer(image: imageName, command: [])
            #expect(output.contains("from-stage"))
        }

        @Test func testDarwinBuildAddArchiveAndImageConfig() throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let imageName = "local/macos-build-add-config:\(UUID().uuidString)"
            defer { deleteImageIfExists(imageName) }

            let archiveRoot = tempDir.appendingPathComponent("context/archive-root")
            try FileManager.default.createDirectory(at: archiveRoot.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("from add\n".utf8).write(to: archiveRoot.appendingPathComponent("sub/hello.txt"))
            try createTarArchive(
                at: tempDir.appendingPathComponent("context/payload.tar"),
                sourceDirectory: archiveRoot
            )

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM \(macOSBaseReference)
                    ENV PHASE1_VALUE=from-env
                    WORKDIR /opt/app
                    LABEL com.apple.container.phase=phase1
                    ADD payload.tar /opt/app/archive/
                    RUN test -f /opt/app/archive/sub/hello.txt
                    ENTRYPOINT ["/bin/sh"]
                    CMD ["-lc", "printf '%s %s\\n' $PWD $PHASE1_VALUE"]
                    """
            )

            let response = try runDarwinBuild(tempDir: tempDir, tag: imageName)
            #expect(response.status == 0, "expected darwin ADD build to succeed: \(response.error)")
            assertDidNotDialLinuxBuilder(response)

            let runOutput = try runDarwinContainer(image: imageName, command: [])
            #expect(runOutput.contains("/opt/app from-env"))

            let inspect = try run(arguments: ["image", "inspect", imageName])
            #expect(inspect.status == 0)
            #expect(inspect.output.contains("com.apple.container.phase"))
            #expect(inspect.output.contains("phase1"))
        }

        @Test func testDarwinBuildTarExportRequiresManualLoad() throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let imageName = "local/macos-build-tar:\(UUID().uuidString)"
            let tarPath = tempDir.appendingPathComponent("phase1.tar")
            defer { deleteImageIfExists(imageName) }

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM --platform=darwin/arm64 \(macOSBaseReference)
                    RUN sw_vers
                    """
            )

            let response = try runDarwinBuild(
                tempDir: tempDir,
                tag: imageName,
                output: "type=tar,dest=\(tarPath.path)"
            )
            #expect(response.status == 0, "expected darwin tar export to succeed: \(response.error)")
            assertDidNotDialLinuxBuilder(response)
            #expect(FileManager.default.fileExists(atPath: tarPath.path))
            #expect(!(try isImagePresent(targetImage: imageName)))

            try loadImage(from: tarPath)
            let output = try runDarwinContainer(image: imageName, command: ["/usr/bin/sw_vers"])
            #expect(output.contains("macOS"))
        }

        @Test func testDarwinBuildOCIExportLoadsAndTagsImage() throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let imageName = "local/macos-build-oci:\(UUID().uuidString)"
            let ociPath = tempDir.appendingPathComponent("phase1-oci.tar")
            defer { deleteImageIfExists(imageName) }

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM --platform=darwin/arm64 \(macOSBaseReference)
                    RUN sw_vers
                    """
            )

            let response = try runDarwinBuild(
                tempDir: tempDir,
                tag: imageName,
                output: "type=oci,dest=\(ociPath.path)"
            )
            #expect(response.status == 0, "expected darwin oci export to succeed: \(response.error)")
            assertDidNotDialLinuxBuilder(response)
            #expect(FileManager.default.fileExists(atPath: ociPath.path))
            #expect(try isImagePresent(targetImage: imageName))

            let output = try runDarwinContainer(image: imageName, command: ["/usr/bin/sw_vers"])
            #expect(output.contains("macOS"))
        }

        @Test func testDarwinBuildLocalExportProducesVMImageDirectory() throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let imageName = "local/macos-build-local:\(UUID().uuidString)"
            let outputDir = tempDir.appendingPathComponent("phase1-local")
            let packagedTar = tempDir.appendingPathComponent("phase1-local-packaged.tar")
            let repackedImageName = "local/macos-build-local-repacked:\(UUID().uuidString)"
            defer {
                deleteImageIfExists(imageName)
                deleteImageIfExists(repackedImageName)
            }

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM --platform=darwin/arm64 \(macOSBaseReference)
                    RUN /bin/sh -lc 'printf local-export > /tmp/local-export.txt && sync'
                    """
            )

            let response = try runDarwinBuild(
                tempDir: tempDir,
                tag: imageName,
                output: "type=local,dest=\(outputDir.path)"
            )
            #expect(response.status == 0, "expected darwin local export to succeed: \(response.error)")
            assertDidNotDialLinuxBuilder(response)
            #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("Disk.img").path))
            #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("AuxiliaryStorage").path))
            #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("HardwareModel.bin").path))

            let packageResponse = try run(arguments: [
                "macos",
                "package",
                "--input", outputDir.path,
                "--output", packagedTar.path,
                "--reference", repackedImageName,
            ])
            #expect(packageResponse.status == 0, "expected macos package to succeed: \(packageResponse.error)")
            #expect(FileManager.default.fileExists(atPath: packagedTar.path))

            try loadImage(from: packagedTar)
            let output = try runDarwinContainer(image: repackedImageName, command: ["/bin/cat", "/tmp/local-export.txt"])
            #expect(output.contains("local-export"))
        }

        @Test func testDarwinBuildFailureCleansStageArtifacts() throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let appRoot = applicationDataRoot()
            let containersRoot = appRoot.appendingPathComponent("containers")
            let builderRoot = appRoot.appendingPathComponent("builder")
            let containersBefore = try directoryEntryNames(at: containersRoot)
            let builderBefore = try directoryEntryNames(at: builderRoot)

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM --platform=darwin/arm64 \(macOSBaseReference)
                    COPY payload.txt /opt/payload.txt
                    RUN /bin/sh -lc 'exit 17'
                    """,
                context: [
                    .file("payload.txt", content: Data("cleanup\n".utf8))
                ]
            )

            let response = try runDarwinBuild(tempDir: tempDir)
            assertFailure(response, contains: "build step failed with exit code 17")

            try waitForNoNewDirectoryEntries(at: containersRoot, baseline: containersBefore)
            try waitForNoNewDirectoryEntries(at: builderRoot, baseline: builderBefore)
        }

        @Test func testDarwinWorkloadBuildProducesRunnableWorkloadImage() async throws {
            let tempDir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let imageName = "local/macos-workload-build:\(UUID().uuidString)"
            let containerID = "macos-workload-build-\(UUID().uuidString.lowercased())"
            let containerClient = ContainerClient()
            defer { deleteImageIfExists(imageName) }

            try createContext(
                tempDir: tempDir,
                dockerfile: """
                    FROM scratch
                    COPY hello.sh /bin/hello
                    WORKDIR /workspace
                    RUN /bin/sh -lc 'mkdir -p ../etc && /bin/chmod 755 ../bin/hello && printf payload-from-workload-build\\\\n > ../etc/message.txt'
                    ENV GREETING=from-build
                    USER nobody
                    ENTRYPOINT ["/bin/hello"]
                    CMD ["default-cmd"]
                    """,
                context: [
                    .file(
                        "hello.sh",
                        content: Data(
                            """
                            #!/bin/sh
                            printf 'arg=%s\\n' "$1"
                            pwd
                            cat ../etc/message.txt
                            printf 'env=%s\\n' "$GREETING"
                            /usr/bin/id -un
                            """.utf8
                        )
                    )
                ]
            )

            let response = try runDarwinBuild(
                tempDir: tempDir,
                tag: imageName,
                otherArgs: [
                    "--macos-build-mode", "workload",
                    "--build-sandbox-image", macOSBaseReference,
                ]
            )
            #expect(response.status == 0, "expected darwin workload build to succeed: \(response.error)")
            assertDidNotDialLinuxBuilder(response)

            do {
                let workloadImage = try await ClientImage.get(reference: imageName)
                try await validateCLIWorkloadImageContract(workloadImage)

                let baseImage = try await ClientImage.get(reference: macOSBaseReference)
                let configuration = makeCLIWorkloadContainerConfiguration(
                    id: containerID,
                    image: baseImage.description
                )
                try await containerClient.create(configuration: configuration, options: .default)
                _ = try await containerClient.bootstrap(id: containerID, stdio: [nil, nil, nil])
                try await waitForCLIContainerStatus(client: containerClient, id: containerID, status: .running, timeoutSeconds: 180)

                let sandboxClient = try await SandboxClient.create(id: containerID, runtime: configuration.runtimeHandler)
                try await waitForCLISandboxStatus(client: sandboxClient, status: .running, timeoutSeconds: 180)

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                try await sandboxClient.createWorkload(
                    WorkloadConfiguration(
                        id: "hello",
                        processConfiguration: ProcessConfiguration(
                            executable: "",
                            arguments: ["cli-built-arg"],
                            environment: [],
                            workingDirectory: "/",
                            terminal: false,
                            user: .id(uid: 0, gid: 0)
                        ),
                        workloadImageReference: "\(imageName)@\(workloadImage.digest)",
                        workloadImageDigest: workloadImage.digest
                    ),
                    stdio: [nil, stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting]
                )
                try stdoutPipe.fileHandleForWriting.close()
                try stderrPipe.fileHandleForWriting.close()

                try await sandboxClient.startWorkload("hello")
                let exitStatus = try await sandboxClient.wait("hello")
                #expect(exitStatus.exitCode == 0)

                let snapshot = try await sandboxClient.inspectWorkload("hello")
                #expect(snapshot.configuration.processConfiguration.executable == "/bin/hello")
                #expect(snapshot.configuration.processConfiguration.workingDirectory == "/workspace")
                #expect(snapshot.configuration.processConfiguration.environment.contains("GREETING=from-build"))
                if case .raw(let userString) = snapshot.configuration.processConfiguration.user {
                    #expect(userString == "nobody")
                } else {
                    Issue.record("expected workload user to resolve to nobody")
                }

                let stdout = try readCLIText(from: stdoutPipe.fileHandleForReading)
                let stderr = try readCLIText(from: stderrPipe.fileHandleForReading)
                #expect(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(stdout.contains("arg=cli-built-arg"))
                #expect(stdout.contains("workloads/hello/rootfs/workspace"))
                #expect(stdout.contains("payload-from-workload-build"))
                #expect(stdout.contains("env=from-build"))
                #expect(stdout.contains("nobody"))
            } catch {
                try? await cleanupCLIWorkloadContainer(client: containerClient, id: containerID)
                throw error
            }

            try await cleanupCLIWorkloadContainer(client: containerClient, id: containerID)
        }
    }
}

private func makeCLIWorkloadContainerConfiguration(
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

private func waitForCLIContainerStatus(
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
        domain: "CLIMacOSBuildTest",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "container \(id) did not reach \(status.rawValue); last status=\(snapshot.status.rawValue)"]
    )
}

private func waitForCLISandboxStatus(
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
        domain: "CLIMacOSBuildTest",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "sandbox did not reach \(status.rawValue); last status=\(snapshot.status.rawValue)"]
    )
}

private func cleanupCLIWorkloadContainer(client: ContainerClient, id: String) async throws {
    try? await client.stop(id: id)
    try? await client.delete(id: id, force: true)
}

private func readCLIText(from handle: FileHandle) throws -> String {
    let data = try handle.readToEnd() ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func validateCLIWorkloadImageContract(_ image: ClientImage) async throws {
    let index = try await image.index()
    guard let descriptor = index.manifests.first(where: { $0.platform == .init(arch: "arm64", os: "darwin") }) else {
        throw NSError(
            domain: "CLIMacOSBuildTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "missing darwin/arm64 manifest in built workload image"]
        )
    }
    guard let resolvedPlatform = descriptor.platform else {
        throw NSError(
            domain: "CLIMacOSBuildTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "missing platform metadata in built workload image"]
        )
    }
    let manifest = try await image.manifest(for: resolvedPlatform)
    let config = try await image.config(for: resolvedPlatform)
    try MacOSImageContract.validateWorkloadImage(
        descriptorAnnotations: descriptor.annotations,
        manifest: manifest,
        imageConfig: config
    )
}
