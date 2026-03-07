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

import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerCommands

struct MacOSBuildEngineTests {
    @Test
    func darwinRouteRejectsMixedPlatforms() throws {
        let platforms: Set<Platform> = [
            .init(arch: "arm64", os: "darwin"),
            .init(arch: "arm64", os: "linux"),
        ]

        #expect(throws: Error.self) {
            _ = try Application.BuildCommand.buildRoute(for: platforms)
        }
    }

    @Test
    func darwinRouteRequiresArm64() throws {
        let platforms: Set<Platform> = [
            .init(arch: "amd64", os: "darwin")
        ]

        #expect(throws: Error.self) {
            _ = try Application.BuildCommand.buildRoute(for: platforms)
        }
    }

    @Test
    func darwinRouteAcceptsSingleDarwinArm64Platform() throws {
        let platforms: Set<Platform> = [
            .init(arch: "arm64", os: "darwin")
        ]

        let route = try Application.BuildCommand.buildRoute(for: platforms)
        switch route {
        case .macOS:
            #expect(Bool(true))
        case .linux:
            Issue.record("expected darwin/arm64 to route to the macOS build engine")
        }
    }

    @Test
    func plannerSelectsNamedTargetStage() throws {
        let dockerfile = Data(
            """
            ARG BASE=registry.local/macos-base:latest
            FROM ${BASE} AS build
            ENV FOO=bar

            FROM registry.local/macos-final:latest AS final
            WORKDIR /opt/app
            CMD ["/bin/zsh"]
            """.utf8
        )

        let plan = try MacOSBuildEngine.Planner(
            dockerfile: dockerfile,
            buildArgs: [:],
            target: "final"
        ).makePlan()

        #expect(plan.stages.count == 2)
        #expect(plan.targetStage.name == "final")
        #expect(plan.targetStage.baseImage == "registry.local/macos-final:latest")
    }

    @Test
    func plannerRejectsCopyFromInPhaseOne() throws {
        let dockerfile = Data(
            """
            FROM registry.local/macos-base:latest AS build
            RUN sw_vers

            FROM registry.local/macos-base:latest
            COPY --from=build /tmp/out /tmp/out
            """.utf8
        )

        #expect(throws: Error.self) {
            _ = try MacOSBuildEngine.Planner(
                dockerfile: dockerfile,
                buildArgs: [:],
                target: ""
            ).makePlan()
        }
    }

    @Test
    func contextProviderAppliesDockerIgnoreRules() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("secret\n", to: root.appendingPathComponent("secret.txt"))
        try write("debug\n", to: root.appendingPathComponent("debug.log"))
        try write("keep\n", to: root.appendingPathComponent("important.log"))
        try write("package main\n", to: root.appendingPathComponent("main.go"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("temp"), withIntermediateDirectories: true)
        try write("cache\n", to: root.appendingPathComponent("temp/cache.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try write("nested\n", to: root.appendingPathComponent("nested/app.log"))
        try write(
            """
            secret.txt
            *.log
            **/*.log
            !important.log
            temp/
            """,
            to: root.appendingPathComponent(".dockerignore")
        )

        let provider = try MacOSBuildEngine.BuildContextProvider(contextRoot: root)
        let sources = try provider.resolveSources(["."])
        #expect(sources.count == 1)
        #expect(sources[0].kind == .directory)

        let descendants = provider.descendants(of: sources[0]).map(\.relativePath)
        #expect(descendants.contains("main.go"))
        #expect(descendants.contains("important.log"))
        #expect(!descendants.contains("secret.txt"))
        #expect(!descendants.contains("debug.log"))
        #expect(!descendants.contains("nested/app.log"))
        #expect(!descendants.contains("temp"))
        #expect(!descendants.contains("temp/cache.txt"))
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacOSBuildEngineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ value: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = value.data(using: .utf8) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}
