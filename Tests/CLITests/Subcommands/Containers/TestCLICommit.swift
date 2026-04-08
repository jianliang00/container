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

import ContainerResource
import Foundation
import Testing

extension TestCLIMacOSBuildBase {
    @Suite(.enabled(if: CLITest.isCLIServiceAvailable(), "requires running container API service"))
    class CLICommitFailureTest: TestCLIMacOSBuildBase {
        @Test
        func testCommitRejectsMissingContainer() throws {
            let target = "local/macos-commit-missing:\(UUID().uuidString)"
            defer { deleteImageIfExists(target) }

            let response = try run(arguments: ["commit", "missing-container", target])
            assertFailure(response, contains: "source container missing-container not found")
        }

        @Test
        func testCommitRejectsLinuxContainer() throws {
            let name = "linux-commit-\(UUID().uuidString)"
            let target = "local/linux-commit:\(UUID().uuidString)"
            defer {
                try? doRemove(name: name, force: true)
                deleteImageIfExists(target)
            }

            try doCreate(name: name, args: ["sleep", "infinity"])

            let response = try run(arguments: ["commit", name, target])
            assertFailure(response, contains: "is not a macOS guest container")
        }
    }

    @Suite(.enabled(if: TestCLIMacOSBuildBase.isMacOSBuildE2EEnabled(), "requires CONTAINER_ENABLE_MACOS_BUILD_E2E=1"))
    class CLICommitE2ETest: TestCLIMacOSBuildBase {
        @Test
        func testCommitFromStoppedDarwinContainer() throws {
            let name = "macos-commit-stopped-\(UUID().uuidString)"
            let target = "local/macos-commit-stopped:\(UUID().uuidString)"
            defer {
                try? doRemove(name: name, force: true)
                deleteImageIfExists(target)
            }

            try createDarwinContainer(
                name: name,
                env: ["COMMIT_MODE=stopped"],
                workdir: "/tmp/stopped-workdir",
                user: "nobody",
                entrypoint: "/bin/sh",
                command: ["-lc", "while true; do sleep 30; done"]
            )
            try doStart(name: name)
            _ = try doExec(name: name, cmd: ["/bin/sh", "-lc", "printf stopped-commit > /tmp/commit-state.txt"])
            try doStop(name: name)

            let response = try run(arguments: ["commit", name, target])
            #expect(response.status == 0, "expected commit to succeed: \(response.error)")
            #expect(response.output.contains(target))
            #expect(try getContainerStatus(name) == "stopped")

            let output = try runDarwinContainer(image: target, command: ["/bin/cat", "/tmp/commit-state.txt"])
            #expect(output.contains("stopped-commit"))

            let imageDetail = try inspectImageDetail(target)
            let variant = try #require(imageDetail.variants.first { $0.platform.os == "darwin" && $0.platform.architecture == "arm64" })
            #expect(variant.config.config?.user == "nobody")
            #expect(variant.config.config?.workingDir == "/tmp/stopped-workdir")
            #expect(variant.config.config?.entrypoint == ["/bin/sh"])
            #expect(variant.config.config?.cmd == ["-lc", "while true; do sleep 30; done"])
            #expect(variant.config.config?.env?.contains("COMMIT_MODE=stopped") == true)
        }

        @Test
        func testCommitFromRunningDarwinContainerRestartsByDefault() throws {
            let name = "macos-commit-running-\(UUID().uuidString)"
            let target = "local/macos-commit-running:\(UUID().uuidString)"
            defer {
                try? doStop(name: name)
                try? doRemove(name: name, force: true)
                deleteImageIfExists(target)
            }

            try runDetachedDarwinContainer(name: name)
            _ = try doExec(name: name, cmd: ["/bin/sh", "-lc", "printf running-commit > /tmp/commit-state.txt"])

            let response = try run(arguments: ["commit", name, target])
            #expect(response.status == 0, "expected commit to succeed: \(response.error)")
            #expect(try getContainerStatus(name) == "running")

            let output = try runDarwinContainer(image: target, command: ["/bin/cat", "/tmp/commit-state.txt"])
            #expect(output.contains("running-commit"))
        }

        @Test
        func testCommitLeaveStoppedKeepsRunningSourceStopped() throws {
            let name = "macos-commit-leave-stopped-\(UUID().uuidString)"
            let target = "local/macos-commit-leave-stopped:\(UUID().uuidString)"
            defer {
                try? doRemove(name: name, force: true)
                deleteImageIfExists(target)
            }

            try runDetachedDarwinContainer(name: name)
            _ = try doExec(name: name, cmd: ["/bin/sh", "-lc", "printf leave-stopped > /tmp/commit-state.txt"])

            let response = try run(arguments: ["commit", "--leave-stopped", name, target])
            #expect(response.status == 0, "expected commit to succeed: \(response.error)")
            #expect(try getContainerStatus(name) == "stopped")

            let output = try runDarwinContainer(image: target, command: ["/bin/cat", "/tmp/commit-state.txt"])
            #expect(output.contains("leave-stopped"))
        }

        @Test
        func testCommitRejectsInvalidTargetReference() throws {
            let name = "macos-commit-invalid-ref-\(UUID().uuidString)"
            defer {
                try? doRemove(name: name, force: true)
            }

            try createDarwinContainer(
                name: name,
                entrypoint: "/bin/sh",
                command: ["-lc", "while true; do sleep 30; done"]
            )

            let response = try run(arguments: ["commit", name, "invalid target ref"])
            assertFailure(response, contains: "invalid target reference")
        }

        private func createDarwinContainer(
            name: String,
            env: [String] = [],
            workdir: String? = nil,
            user: String? = nil,
            entrypoint: String? = nil,
            command: [String]
        ) throws {
            var arguments = ["create", "--os", "darwin", "--name", name]
            for value in env {
                arguments += ["-e", value]
            }
            if let workdir {
                arguments += ["-w", workdir]
            }
            if let user {
                arguments += ["-u", user]
            }
            if let entrypoint {
                arguments += ["--entrypoint", entrypoint]
            }
            arguments.append(macOSBaseReference)
            arguments.append(contentsOf: command)

            let response = try run(arguments: arguments)
            guard response.status == 0 else {
                throw CLIError.executionFailed("darwin create failed: \(response.error)")
            }
        }

        private func runDetachedDarwinContainer(name: String) throws {
            let response = try run(arguments: [
                "run",
                "--os", "darwin",
                "--name", name,
                "-d",
                macOSBaseReference,
                "/bin/sh",
                "-lc",
                "while true; do sleep 30; done",
            ])
            guard response.status == 0 else {
                throw CLIError.executionFailed("darwin detached run failed: \(response.error)")
            }
            try waitForContainerRunning(name)
        }

        private func inspectImageDetail(_ name: String) throws -> ImageDetail {
            let response = try run(arguments: ["image", "inspect", name])
            guard response.status == 0 else {
                throw CLIError.executionFailed("image inspect failed: \(response.error)")
            }
            guard let data = response.output.data(using: .utf8) else {
                throw CLIError.invalidOutput("image inspect output invalid")
            }
            let details = try JSONDecoder().decode([ImageDetail].self, from: data)
            return try #require(details.first)
        }
    }
}
