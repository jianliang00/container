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

        @Test func testDarwinBuildRejectsLocalOutputInPhaseOne() throws {
            let tempDir = try createTempDir()
            try createContext(tempDir: tempDir, dockerfile: "FROM \(macOSBaseReference)\n")

            let response = try runDarwinBuild(
                tempDir: tempDir,
                tag: "local/macos-build-local-output:\(UUID().uuidString)",
                output: "type=local,dest=\(tempDir.appendingPathComponent("out").path)"
            )

            assertFailure(response, contains: "darwin builds do not support --output type=local in phase 1")
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

        @Test func testDarwinBuildRejectsCopyFromInstruction() throws {
            let tempDir = try createTempDir()
            try createContext(
                tempDir: tempDir,
                dockerfile: """
                FROM \(macOSBaseReference) AS build
                RUN sw_vers

                FROM \(macOSBaseReference)
                COPY --from=build /tmp/out /tmp/out
                """
            )

            let response = try runDarwinBuild(tempDir: tempDir)
            assertFailure(response, contains: "darwin builds do not support COPY --from in phase 1")
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
    }
}
