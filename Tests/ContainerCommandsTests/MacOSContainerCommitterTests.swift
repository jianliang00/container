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
import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerCommands

struct MacOSContainerCommitterTests {
    @Test
    func validationAcceptsStoppedDarwinGuestContainer() throws {
        let container = testContainer(status: .stopped)
        try MacOSContainerCommitter.validate(container: container)
    }

    @Test
    func validationRejectsLinuxContainer() throws {
        var container = testContainer(status: .stopped)
        container.configuration.platform = .init(arch: "arm64", os: "linux")

        do {
            try MacOSContainerCommitter.validate(container: container)
            Issue.record("expected validation to fail for a Linux container")
        } catch let error as ContainerizationError {
            #expect(error.code == .unsupported)
            #expect(error.message == "container test-commit is not a macOS guest container")
        }
    }

    @Test
    func validationRejectsStoppingContainer() throws {
        let container = testContainer(status: .stopping)

        do {
            try MacOSContainerCommitter.validate(container: container)
            Issue.record("expected validation to fail for a stopping container")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
            #expect(error.message == "container is in unsupported state stopping")
        }
    }

    @Test
    func committedImageConfigUsesEffectiveProcessMetadata() {
        let baseImageConfig = ContainerizationOCI.Image(
            created: "1970-01-01T00:00:00Z",
            author: "base-author",
            architecture: "arm64",
            os: "darwin",
            osVersion: "26.0",
            osFeatures: ["feature-a"],
            variant: "base-variant",
            config: .init(
                user: "root",
                env: ["BASE=1"],
                entrypoint: ["/usr/bin/env"],
                cmd: ["true"],
                workingDir: "/",
                labels: ["base": "label"],
                stopSignal: "15"
            ),
            rootfs: .init(type: "layers", diffIDs: ["sha256:base"]),
            history: [.init(createdBy: "base-history")]
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-lc", "echo committed"],
            environment: ["COMMIT_ENV=1"],
            workingDirectory: "/tmp/commit",
            terminal: false,
            user: .raw(userString: "nobody")
        )
        let createdAt = Date(timeIntervalSince1970: 1_704_067_200)

        let committed = MacOSContainerCommitter.committedImageConfig(
            baseImageConfig: baseImageConfig,
            process: process,
            createdAt: createdAt
        )

        #expect(committed.created == "2024-01-01T00:00:00Z")
        #expect(committed.author == "base-author")
        #expect(committed.architecture == "arm64")
        #expect(committed.os == "darwin")
        #expect(committed.osVersion == "26.0")
        #expect(committed.osFeatures == ["feature-a"])
        #expect(committed.variant == "base-variant")
        #expect(committed.history?.count == 1)
        #expect(committed.history?.first?.createdBy == "base-history")
        #expect(committed.rootfs.type == "layers")
        #expect(committed.rootfs.diffIDs.isEmpty)
        #expect(committed.config?.user == "nobody")
        #expect(committed.config?.env == ["COMMIT_ENV=1"])
        #expect(committed.config?.entrypoint == ["/bin/sh"])
        #expect(committed.config?.cmd == ["-lc", "echo committed"])
        #expect(committed.config?.workingDir == "/tmp/commit")
        #expect(committed.config?.labels == ["base": "label"])
        #expect(committed.config?.stopSignal == "15")
    }

    @Test
    func restartActionMatchesRunningSourceAndLeaveStoppedFlag() {
        #expect(MacOSContainerCommitter.restartAction(for: .stopped, leaveStopped: false) == .none)
        #expect(MacOSContainerCommitter.restartAction(for: .running, leaveStopped: false) == .restartAfterClone)
        #expect(MacOSContainerCommitter.restartAction(for: .running, leaveStopped: true) == .leaveStopped)
    }

    @Test
    func sourceFlowMatchesRunningAndStoppedStates() throws {
        #expect(try MacOSContainerCommitter.sourceFlow(for: .stopped) == .stopped)
        #expect(try MacOSContainerCommitter.sourceFlow(for: .running) == .running)
    }
}

private func testContainer(status: RuntimeStatus) -> ContainerSnapshot {
    let image = ImageDescription(
        reference: "local/macos-base:latest",
        descriptor: .init(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:test",
            size: 1
        )
    )
    let process = ProcessConfiguration(
        executable: "/bin/sh",
        arguments: ["-lc", "while true; do sleep 30; done"],
        environment: ["PATH=/usr/bin:/bin"],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
    var configuration = ContainerConfiguration(id: "test-commit", image: image, process: process)
    configuration.platform = .init(arch: "arm64", os: "darwin")
    configuration.runtimeHandler = "container-runtime-macos"
    configuration.macosGuest = .init(snapshotEnabled: true, guiEnabled: false, agentPort: 27_000)
    return ContainerSnapshot(configuration: configuration, status: status, networks: [])
}
