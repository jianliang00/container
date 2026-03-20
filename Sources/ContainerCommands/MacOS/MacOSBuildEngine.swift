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
import ContainerBuild
import ContainerResource
import ContainerSandboxServiceClient
import Containerization
import ContainerizationError
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging
import RuntimeMacOSSidecarShared

struct MacOSBuildEngine {
    static let buildPlatform = Platform(arch: "arm64", os: "darwin")
    static let runtimeName = "container-runtime-macos"
    static let defaultAgentPort: UInt32 = 27000
    static let inlineDataLimit = 256 * 1024
    static let chunkSize = 256 * 1024
    static let stageStopTimeoutSeconds: Int32 = 20
    static let machineIdentifierFilename = "MachineIdentifier.bin"

    struct Input {
        let appRoot: URL
        let buildID: String
        let contextDirectory: URL
        let dockerfile: Data
        let buildArgs: [String]
        let labelArgs: [String]
        let cpus: Int64
        let memory: String
        let noCache: Bool
        let pull: Bool
        let quiet: Bool
        let target: String
        let tags: [String]
        let exports: [Builder.BuildExport]
        let log: Logger
    }

    struct Output {
        let archiveURL: URL
    }

    struct Plan {
        let stages: [Stage]
        let targetStage: Stage

        var executionStages: [Stage] {
            guard let targetPosition = stages.firstIndex(where: { $0.index == targetStage.index }) else {
                return [targetStage]
            }
            return Array(stages.prefix(through: targetPosition))
        }
    }

    struct Stage {
        let index: Int
        let name: String?
        let baseImage: String
        let instructions: [Instruction]
    }

    enum Instruction {
        case arg(ArgumentInstruction)
        case env([KeyValuePair])
        case workdir(String)
        case user(String)
        case run(CommandForm)
        case copy(FileTransferInstruction)
        case add(FileTransferInstruction)
        case label([KeyValuePair])
        case cmd(CommandForm)
        case entrypoint(CommandForm)
    }

    struct ArgumentInstruction {
        let name: String
        let defaultValue: String?
    }

    struct KeyValuePair {
        let key: String
        let value: String
    }

    struct FileTransferInstruction {
        let sources: [String]
        let destination: String
        let fromStage: String?
    }

    enum CommandForm {
        case shell(String)
        case exec([String])
    }

    enum EntryKind {
        case file
        case directory
        case symlink
    }

    enum GuestPathKind {
        case missing
        case directory
        case nonDirectory
    }

    struct ContextEntry {
        let url: URL
        let relativePath: String
        let kind: EntryKind
    }

    struct StageCopySourceEntry {
        let originalPath: String
        let path: String
        let archiveName: String
        let kind: EntryKind
    }

    struct CachedStageSourceEntry {
        let path: String
        let archiveName: String
        let kind: EntryKind
        let url: URL
    }

    struct DockerIgnoreRule {
        let include: Bool
        let regex: NSRegularExpression
    }

    struct StageState {
        let baseConfig: ContainerizationOCI.Image
        var buildArguments: [String: String]
        var environment: [String: String]
        var labels: [String: String]
        var workingDirectory: String
        var user: String?
        var cmd: [String]?
        var entrypoint: [String]?

        init(baseConfig: ContainerizationOCI.Image, initialBuildArguments: [String: String]) {
            self.baseConfig = baseConfig
            self.buildArguments = initialBuildArguments
            self.environment = Self.environmentDictionary(from: baseConfig.config?.env ?? [])
            self.labels = baseConfig.config?.labels ?? [:]
            self.workingDirectory = baseConfig.config?.workingDir ?? "/"
            self.user = baseConfig.config?.user
            self.cmd = baseConfig.config?.cmd
            self.entrypoint = baseConfig.config?.entrypoint
        }

        var variables: [String: String] {
            var merged = buildArguments
            for (key, value) in environment {
                merged[key] = value
            }
            return merged
        }

        func resolvedPath(for value: String, preserveTrailingSlash: Bool = false) -> String {
            guard !value.hasPrefix("/") else {
                return normalizeAbsolutePath(value, preserveTrailingSlash: preserveTrailingSlash)
            }
            return normalizeAbsolutePath(workingDirectory + "/" + value, preserveTrailingSlash: preserveTrailingSlash)
        }

        func finalImage(labelOverrides: [String: String]) -> ContainerizationOCI.Image {
            var mergedLabels = labels
            for (key, value) in labelOverrides {
                mergedLabels[key] = value
            }
            let env = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
            let config = ImageConfig(
                user: user,
                env: env.isEmpty ? nil : env,
                entrypoint: entrypoint,
                cmd: cmd,
                workingDir: workingDirectory,
                labels: mergedLabels.isEmpty ? nil : mergedLabels,
                stopSignal: baseConfig.config?.stopSignal
            )
            return .init(
                created: Self.createdTimestamp(),
                author: baseConfig.author,
                architecture: baseConfig.architecture,
                os: baseConfig.os,
                osVersion: baseConfig.osVersion,
                osFeatures: baseConfig.osFeatures,
                variant: baseConfig.variant,
                config: config,
                rootfs: .init(type: "layers", diffIDs: []),
                history: baseConfig.history
            )
        }

        private static func environmentDictionary(from env: [String]) -> [String: String] {
            var result: [String: String] = [:]
            for entry in env {
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = parts.first, !key.isEmpty else {
                    continue
                }
                result[key] = parts.count == 2 ? parts[1] : ""
            }
            return result
        }

        private static func createdTimestamp() -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: Date())
        }
    }

    static func run(_ input: Input) async throws -> Output {
        guard input.exports.count == 1, let export = input.exports.first else {
            throw ContainerizationError(.unsupported, message: "darwin builds currently support a single --output entry")
        }

        switch export.type {
        case "oci", "tar", "local":
            break
        default:
            throw ContainerizationError(.unsupported, message: "unsupported darwin build output type \(export.type)")
        }

        let cliBuildArgs = Utility.parseKeyValuePairs(input.buildArgs)
        let cliLabels = Utility.parseKeyValuePairs(input.labelArgs)
        let planner = Planner(
            dockerfile: input.dockerfile,
            buildArgs: cliBuildArgs,
            target: input.target
        )
        let plan = try planner.makePlan()
        let contextProvider = try BuildContextProvider(contextRoot: input.contextDirectory)
        let targetStage = plan.targetStage
        let exportRoot = input.appRoot
            .appendingPathComponent("builder")
            .appendingPathComponent(input.buildID)
            .appendingPathComponent("copy-from-cache")

        var stageBaseImages: [Int: ClientImage] = [:]
        var stageBaseConfigs: [Int: ContainerizationOCI.Image] = [:]
        for stage in plan.executionStages {
            let baseImage = try await resolveBaseImage(reference: stage.baseImage, pull: input.pull)
            stageBaseImages[stage.index] = baseImage
            stageBaseConfigs[stage.index] = try await baseImage.config(for: buildPlatform)
        }

        let plannedExports = try plannedCopySourceExports(
            plan: plan,
            baseConfigs: stageBaseConfigs,
            initialBuildArguments: cliBuildArgs
        )
        var exportedStageSources: [Int: [String: CachedStageSourceEntry]] = [:]

        for stage in plan.executionStages {
            guard let baseImage = stageBaseImages[stage.index], let baseConfig = stageBaseConfigs[stage.index] else {
                throw ContainerizationError(.internalError, message: "missing cached base image/config for stage \(stage.index)")
            }
            if !input.quiet {
                writeStderrLine("Building macOS stage \(stage.name ?? "#\(stage.index)")")
            }
            let runtime = try await StageRuntime.start(
                appRoot: input.appRoot,
                buildID: input.buildID,
                baseImage: baseImage,
                stageIndex: stage.index,
                cpus: input.cpus,
                memory: input.memory
            )

            do {
                let transport = FileTransport(
                    sandboxClient: runtime.sandboxClient,
                    contextProvider: contextProvider,
                    pathInspector: { path in
                        try await runtime.inspectPath(path, log: input.log)
                    }
                )
                let state = try await execute(
                    stage: stage,
                    baseConfig: baseConfig,
                    runtime: runtime,
                    transport: transport,
                    stages: plan.stages,
                    exportedStageSources: exportedStageSources,
                    initialBuildArguments: cliBuildArgs,
                    quiet: input.quiet,
                    log: input.log
                )
                try await flushGuestFileSystem(runtime: runtime, log: input.log)

                if stage.index != targetStage.index {
                    if let requestedSources = plannedExports[stage.index], !requestedSources.isEmpty {
                        exportedStageSources[stage.index] = try await exportStageSources(
                            requestedSources,
                            from: runtime,
                            cacheRoot: exportRoot.appendingPathComponent("stage-\(stage.index)")
                        )
                    }
                    let runtimeStopStartedAt = Date()
                    try await runtime.stop()
                    MacOSExportProfiler.log(
                        "runtime.stop.stage[\(stage.index)]: \(MacOSExportProfiler.format(Date().timeIntervalSince(runtimeStopStartedAt)))"
                    )
                    await runtime.delete()
                    continue
                }

                let runtimeStopStartedAt = Date()
                try await runtime.stop()
                MacOSExportProfiler.log(
                    "runtime.stop.stage[\(stage.index)]: \(MacOSExportProfiler.format(Date().timeIntervalSince(runtimeStopStartedAt)))"
                )
                let bundleURL = input.appRoot
                    .appendingPathComponent("containers")
                    .appendingPathComponent(runtime.containerID)
                let archiveURL = outputArchiveURL(for: export, appRoot: input.appRoot, buildID: input.buildID)
                if export.type == "local" {
                    let exportStartedAt = Date()
                    try exportLocalImageDirectory(from: bundleURL, to: archiveURL)
                    MacOSExportProfiler.log(
                        "build.localExport: \(MacOSExportProfiler.format(Date().timeIntervalSince(exportStartedAt)))"
                    )
                } else {
                    let parentDiskSource = try await baseImage.macOSChunkedDiskSource(for: buildPlatform)
                    let packageStartedAt = Date()
                    try MacOSImagePackager.package(
                        imageDirectory: bundleURL,
                        outputTar: archiveURL,
                        reference: input.tags.first,
                        imageConfig: state.finalImage(labelOverrides: cliLabels),
                        parentDiskSource: parentDiskSource
                    )
                    MacOSExportProfiler.log(
                        "build.packageCall: \(MacOSExportProfiler.format(Date().timeIntervalSince(packageStartedAt)))"
                    )
                }

                await runtime.delete()
                return .init(archiveURL: archiveURL)
            } catch {
                await runtime.cleanup()
                throw error
            }
        }

        throw ContainerizationError(.internalError, message: "missing target stage execution result")
    }

    private static func exportStageSources(
        _ requestedSources: [String],
        from runtime: StageRuntime,
        cacheRoot: URL
    ) async throws -> [String: CachedStageSourceEntry] {
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        var exported: [String: CachedStageSourceEntry] = [:]
        let sourceEntries = try await runtime.resolveCopySources(requestedSources)
        for sourceEntry in sourceEntries {
            let exportDirectory = cacheRoot.appendingPathComponent(sourceEntry.archiveName + "-" + sourceEntry.path.sha256Prefix)
            if FileManager.default.fileExists(atPath: exportDirectory.path) {
                try FileManager.default.removeItem(at: exportDirectory)
            }
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            try await runtime.export(source: sourceEntry, to: exportDirectory)

            exported[sourceEntry.path] = .init(
                path: sourceEntry.path,
                archiveName: sourceEntry.archiveName,
                kind: sourceEntry.kind,
                url: exportDirectory.appendingPathComponent(sourceEntry.archiveName)
            )
        }

        return exported
    }

    private static func resolveBaseImage(reference: String, pull: Bool) async throws -> ClientImage {
        if reference == "scratch" {
            throw ContainerizationError(.unsupported, message: "darwin builds do not support FROM scratch")
        }
        if pull {
            return try await ClientImage.pull(reference: reference, platform: buildPlatform)
        }
        return try await ClientImage.fetch(reference: reference, platform: buildPlatform)
    }

    private static func stageContainerID(buildID: String, stageIndex: Int) -> String {
        "macos-build-\(buildID)-stage-\(stageIndex)"
    }

    private static func outputArchiveURL(for export: Builder.BuildExport, appRoot: URL, buildID: String) -> URL {
        switch export.type {
        case "oci":
            return export.destination
                ?? appRoot
                .appendingPathComponent("builder")
                .appendingPathComponent(buildID)
                .appendingPathComponent("out.tar")
        case "tar":
            return
                appRoot
                .appendingPathComponent("builder")
                .appendingPathComponent(buildID)
                .appendingPathComponent("out.tar")
        case "local":
            return
                appRoot
                .appendingPathComponent("builder")
                .appendingPathComponent(buildID)
                .appendingPathComponent("local")
        default:
            return
                appRoot
                .appendingPathComponent("builder")
                .appendingPathComponent(buildID)
                .appendingPathComponent("out.tar")
        }
    }

    static func exportLocalImageDirectory(from imageDirectory: URL, to outputDirectory: URL) throws {
        let image = try MacOSImagePackager.validateImageDirectory(imageDirectory)
        let fm = FileManager.default
        let destination = outputDirectory.standardizedFileURL

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let requiredFiles = [image.diskImage, image.auxiliaryStorage, image.hardwareModel]
        for source in requiredFiles {
            try fm.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
        }

        let machineIdentifier = image.root.appendingPathComponent(machineIdentifierFilename)
        if fm.fileExists(atPath: machineIdentifier.path) {
            try fm.copyItem(
                at: machineIdentifier,
                to: destination.appendingPathComponent(machineIdentifierFilename)
            )
        }
    }

    private static func commandToOCIArguments(_ command: CommandForm) -> [String] {
        switch command {
        case .exec(let arguments):
            return arguments
        case .shell(let value):
            return ["/bin/sh", "-c", value]
        }
    }

    private static func description(for command: CommandForm) -> String {
        switch command {
        case .exec(let args):
            return "RUN \(args.joined(separator: " "))"
        case .shell(let value):
            return "RUN \(value)"
        }
    }

    private static func normalizedStageReference(_ value: String) -> String {
        if Int(value) != nil {
            return value
        }
        return value.lowercased()
    }

    private static func resolveCopySourceStageIndex(
        reference: String,
        currentStageIndex: Int,
        stages: [Stage]
    ) throws -> Int {
        if let stageIndex = Int(reference) {
            guard stages.indices.contains(stageIndex) else {
                throw ContainerizationError(.notFound, message: "COPY --from stage \(reference) not found")
            }
            guard stageIndex < currentStageIndex else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "COPY --from stage \(reference) must refer to an earlier build stage"
                )
            }
            return stageIndex
        }

        let normalized = normalizedStageReference(reference)
        guard let stage = stages.first(where: { $0.name == normalized }) else {
            throw ContainerizationError(.notFound, message: "COPY --from stage \(reference) not found")
        }
        guard stage.index < currentStageIndex else {
            throw ContainerizationError(
                .invalidArgument,
                message: "COPY --from stage \(reference) must refer to an earlier build stage"
            )
        }
        return stage.index
    }

    private static func normalizedCopySourcePath(_ rawSource: String) throws -> String {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "COPY --from source path may not be empty")
        }
        guard !pathContainsGlobPattern(trimmed) else {
            throw ContainerizationError(
                .unsupported,
                message: "darwin builds do not yet support wildcard COPY --from source paths"
            )
        }

        let normalized = normalizeAbsolutePath(trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        guard normalized != "/" else {
            throw ContainerizationError(
                .unsupported,
                message: "darwin builds do not yet support COPY --from /"
            )
        }
        return normalized
    }

    private static func plannedCopySourceExports(
        plan: Plan,
        baseConfigs: [Int: ContainerizationOCI.Image],
        initialBuildArguments: [String: String]
    ) throws -> [Int: [String]] {
        var exports: [Int: Set<String>] = [:]

        for stage in plan.executionStages {
            guard let baseConfig = baseConfigs[stage.index] else {
                throw ContainerizationError(.internalError, message: "missing base config for stage \(stage.index)")
            }

            var state = StageState(baseConfig: baseConfig, initialBuildArguments: initialBuildArguments)
            for instruction in stage.instructions {
                switch instruction {
                case .arg(let argument):
                    let value = initialBuildArguments[argument.name] ?? argument.defaultValue ?? ""
                    state.buildArguments[argument.name] = value

                case .env(let pairs):
                    var variables = state.variables
                    for pair in pairs {
                        let expanded = try VariableExpander.expand(pair.value, variables: variables)
                        state.environment[pair.key] = expanded
                        variables[pair.key] = expanded
                    }

                case .label(let pairs):
                    var variables = state.variables
                    for pair in pairs {
                        let expanded = try VariableExpander.expand(pair.value, variables: variables)
                        state.labels[pair.key] = expanded
                        variables[pair.key] = expanded
                    }

                case .workdir(let path):
                    let expanded = try VariableExpander.expand(path, variables: state.variables)
                    state.workingDirectory = state.resolvedPath(for: expanded)

                case .user(let rawValue):
                    let expanded = try VariableExpander.expand(rawValue, variables: state.variables)
                    state.user = expanded

                case .copy(let fileInstruction):
                    let expandedSources = try fileInstruction.sources.map {
                        try VariableExpander.expand($0, variables: state.variables)
                    }
                    if let fromStage = fileInstruction.fromStage {
                        let sourceStageIndex = try resolveCopySourceStageIndex(
                            reference: fromStage,
                            currentStageIndex: stage.index,
                            stages: plan.stages
                        )
                        for source in expandedSources {
                            exports[sourceStageIndex, default: []].insert(try normalizedCopySourcePath(source))
                        }
                    }

                case .run, .add:
                    break

                case .cmd(let command):
                    state.cmd = commandToOCIArguments(command)

                case .entrypoint(let command):
                    state.entrypoint = commandToOCIArguments(command)
                }
            }
        }

        return exports.mapValues { $0.sorted() }
    }

    private static func execute(
        stage: Stage,
        baseConfig: ContainerizationOCI.Image,
        runtime: StageRuntime,
        transport: FileTransport,
        stages: [Stage],
        exportedStageSources: [Int: [String: CachedStageSourceEntry]],
        initialBuildArguments: [String: String],
        quiet: Bool,
        log: Logger
    ) async throws -> StageState {
        var state = StageState(baseConfig: baseConfig, initialBuildArguments: initialBuildArguments)

        for instruction in stage.instructions {
            switch instruction {
            case .arg(let argument):
                let value = initialBuildArguments[argument.name] ?? argument.defaultValue ?? ""
                state.buildArguments[argument.name] = value

            case .env(let pairs):
                var variables = state.variables
                for pair in pairs {
                    let expanded = try VariableExpander.expand(pair.value, variables: variables)
                    state.environment[pair.key] = expanded
                    variables[pair.key] = expanded
                }

            case .label(let pairs):
                var variables = state.variables
                for pair in pairs {
                    let expanded = try VariableExpander.expand(pair.value, variables: variables)
                    state.labels[pair.key] = expanded
                    variables[pair.key] = expanded
                }

            case .workdir(let path):
                let expanded = try VariableExpander.expand(path, variables: state.variables)
                let resolved = state.resolvedPath(for: expanded)
                try await transport.createDirectory(at: resolved)
                state.workingDirectory = resolved

            case .user(let rawValue):
                let expanded = try VariableExpander.expand(rawValue, variables: state.variables)
                state.user = expanded

            case .copy(let fileInstruction):
                let expandedSources = try fileInstruction.sources.map {
                    try VariableExpander.expand($0, variables: state.variables)
                }
                let expandedDestination = try VariableExpander.expand(fileInstruction.destination, variables: state.variables)
                let resolvedDestination = state.resolvedPath(
                    for: expandedDestination,
                    preserveTrailingSlash: expandedDestination.hasSuffix("/")
                )
                if let fromStage = fileInstruction.fromStage {
                    let sourceStageIndex = try resolveCopySourceStageIndex(
                        reference: fromStage,
                        currentStageIndex: stage.index,
                        stages: stages
                    )
                    guard let cachedSources = exportedStageSources[sourceStageIndex] else {
                        throw ContainerizationError(
                            .internalError,
                            message: "missing cached stage sources for COPY --from=\(fromStage)"
                        )
                    }
                    try await transport.copyFromCache(
                        sources: expandedSources,
                        destination: resolvedDestination,
                        cachedSources: cachedSources
                    )
                } else {
                    try await transport.copy(
                        sources: expandedSources,
                        destination: resolvedDestination,
                        kind: .copy
                    )
                }

            case .add(let fileInstruction):
                let expandedSources = try fileInstruction.sources.map {
                    try VariableExpander.expand($0, variables: state.variables)
                }
                let expandedDestination = try VariableExpander.expand(fileInstruction.destination, variables: state.variables)
                try await transport.copy(
                    sources: expandedSources,
                    destination: state.resolvedPath(for: expandedDestination, preserveTrailingSlash: expandedDestination.hasSuffix("/")),
                    kind: .add
                )

            case .run(let command):
                if !quiet {
                    writeStderrLine(description(for: command))
                }
                try await runtime.run(
                    command: command,
                    environment: state.environment,
                    workingDirectory: state.workingDirectory,
                    user: state.user.map { .raw(userString: $0) } ?? .id(uid: 0, gid: 0),
                    quiet: quiet,
                    log: log
                )

            case .cmd(let command):
                state.cmd = commandToOCIArguments(command)

            case .entrypoint(let command):
                state.entrypoint = commandToOCIArguments(command)
            }
        }

        return state
    }

    private static func flushGuestFileSystem(runtime: StageRuntime, log: Logger) async throws {
        // Flush guest filesystem buffers before stopping the VM so recent
        // COPY/ADD/WORKDIR changes are durably reflected in the packaged disk.
        try await runtime.run(
            command: .exec(["/bin/sync"]),
            environment: [:],
            workingDirectory: "/",
            user: .id(uid: 0, gid: 0),
            quiet: true,
            log: log
        )
    }
}

extension MacOSBuildEngine {
    final class Planner {
        private let dockerfile: Data
        private let buildArgs: [String: String]
        private let target: String

        init(dockerfile: Data, buildArgs: [String: String], target: String) {
            self.dockerfile = dockerfile
            self.buildArgs = buildArgs
            self.target = target
        }

        func makePlan() throws -> Plan {
            let text = String(decoding: dockerfile, as: UTF8.self)
            let logicalLines = try LogicalLineParser.parse(text)

            var globalArgs = buildArgs
            var stages: [Stage] = []
            var aliases: Set<String> = []
            var currentName: String?
            var currentBaseImage: String?
            var currentInstructions: [Instruction] = []

            for logicalLine in logicalLines {
                let parsed = try parseInstruction(logicalLine)
                switch parsed {
                case .arg(let argument):
                    if currentBaseImage == nil {
                        globalArgs[argument.name] = buildArgs[argument.name] ?? argument.defaultValue ?? ""
                    } else {
                        currentInstructions.append(.arg(argument))
                    }

                case .from(let from):
                    if let baseImage = currentBaseImage {
                        stages.append(
                            .init(
                                index: stages.count,
                                name: currentName,
                                baseImage: baseImage,
                                instructions: currentInstructions
                            )
                        )
                    }

                    let variables = globalArgs
                    let expandedPlatform = try from.platform.map {
                        try VariableExpander.expand($0, variables: variables)
                    }
                    if let expandedPlatform, expandedPlatform != buildPlatform.description {
                        throw ContainerizationError(
                            .unsupported,
                            message: "darwin builds require FROM --platform=darwin/arm64, got \(expandedPlatform)"
                        )
                    }

                    let baseImage = try VariableExpander.expand(from.image, variables: variables)
                    if aliases.contains(baseImage.lowercased()) {
                        throw ContainerizationError(
                            .unsupported,
                            message: "darwin builds do not support FROM <previous-stage> in phase 1"
                        )
                    }
                    let alias = from.alias?.lowercased()
                    if let alias {
                        guard aliases.insert(alias).inserted else {
                            throw ContainerizationError(.invalidArgument, message: "duplicate stage alias \(alias)")
                        }
                    }
                    currentName = alias
                    currentBaseImage = baseImage
                    currentInstructions = []

                case .instruction(let instruction):
                    guard currentBaseImage != nil else {
                        throw ContainerizationError(.invalidArgument, message: "Dockerfile must start with FROM before \(logicalLine.keyword)")
                    }
                    currentInstructions.append(instruction)
                }
            }

            if let baseImage = currentBaseImage {
                stages.append(
                    .init(
                        index: stages.count,
                        name: currentName,
                        baseImage: baseImage,
                        instructions: currentInstructions
                    )
                )
            }

            guard !stages.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "Dockerfile does not define a build stage")
            }

            let selected: Stage
            if target.isEmpty {
                guard let last = stages.last else {
                    throw ContainerizationError(.internalError, message: "missing target stage")
                }
                selected = last
            } else if let byName = stages.first(where: { $0.name == target.lowercased() }) {
                selected = byName
            } else if let byIndex = Int(target), stages.indices.contains(byIndex) {
                selected = stages[byIndex]
            } else {
                throw ContainerizationError(.notFound, message: "target stage \(target) not found")
            }

            try validateCopySourceReferences(in: stages)
            return .init(stages: stages, targetStage: selected)
        }

        struct LogicalLine {
            let lineNumber: Int
            let keyword: String
            let arguments: String
        }

        private enum ParsedInstruction {
            case from(FromInstruction)
            case arg(ArgumentInstruction)
            case instruction(Instruction)
        }

        private struct FromInstruction {
            let image: String
            let platform: String?
            let alias: String?
        }

        private func parseInstruction(_ logicalLine: LogicalLine) throws -> ParsedInstruction {
            switch logicalLine.keyword {
            case "FROM":
                return .from(try parseFrom(logicalLine.arguments))
            case "ARG":
                return .arg(try parseArg(logicalLine.arguments))
            case "ENV":
                return .instruction(.env(try parseAssignments(logicalLine.arguments, instruction: "ENV")))
            case "WORKDIR":
                return .instruction(.workdir(try requireNonEmpty(logicalLine.arguments, instruction: "WORKDIR")))
            case "USER":
                return .instruction(.user(try parseUser(logicalLine.arguments)))
            case "RUN":
                return .instruction(.run(try parseCommand(logicalLine.arguments, instruction: "RUN")))
            case "COPY":
                return .instruction(.copy(try parseFileTransfer(logicalLine.arguments, instruction: "COPY")))
            case "ADD":
                return .instruction(.add(try parseFileTransfer(logicalLine.arguments, instruction: "ADD")))
            case "LABEL":
                return .instruction(.label(try parseAssignments(logicalLine.arguments, instruction: "LABEL")))
            case "CMD":
                return .instruction(.cmd(try parseCommand(logicalLine.arguments, instruction: "CMD")))
            case "ENTRYPOINT":
                return .instruction(.entrypoint(try parseCommand(logicalLine.arguments, instruction: "ENTRYPOINT")))
            default:
                throw ContainerizationError(.unsupported, message: "darwin builds do not support \(logicalLine.keyword) in phase 1")
            }
        }

        private func parseFrom(_ value: String) throws -> FromInstruction {
            let tokens = try ShellTokenizer.tokenize(value)
            guard !tokens.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "FROM requires a base image")
            }

            var index = 0
            var platform: String?
            while index < tokens.count, tokens[index].hasPrefix("--") {
                let option = tokens[index]
                if option == "--platform" {
                    let nextIndex = index + 1
                    guard nextIndex < tokens.count else {
                        throw ContainerizationError(.invalidArgument, message: "FROM --platform requires a value")
                    }
                    platform = tokens[nextIndex]
                    index += 2
                    continue
                }
                if option.hasPrefix("--platform=") {
                    platform = String(option.dropFirst("--platform=".count))
                    index += 1
                    continue
                }
                throw ContainerizationError(.unsupported, message: "darwin builds do not support FROM option \(option)")
            }

            guard index < tokens.count else {
                throw ContainerizationError(.invalidArgument, message: "FROM requires a base image")
            }
            let image = tokens[index]
            index += 1

            var alias: String?
            if index < tokens.count {
                guard tokens.count == index + 2, tokens[index].uppercased() == "AS" else {
                    throw ContainerizationError(.invalidArgument, message: "invalid FROM syntax")
                }
                alias = tokens[index + 1]
            }

            return .init(image: image, platform: platform, alias: alias)
        }

        private func parseArg(_ value: String) throws -> ArgumentInstruction {
            let trimmed = try requireNonEmpty(value, instruction: "ARG")
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard Self.isValidVariableName(name) else {
                throw ContainerizationError(.invalidArgument, message: "invalid ARG name \(name)")
            }
            return .init(name: name, defaultValue: parts.count == 2 ? parts[1] : nil)
        }

        private func parseAssignments(_ value: String, instruction: String) throws -> [KeyValuePair] {
            let tokens = try ShellTokenizer.tokenize(value)
            guard !tokens.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "\(instruction) requires at least one key/value pair")
            }

            if tokens.count == 2, !tokens[0].contains("=") {
                return [.init(key: tokens[0], value: tokens[1])]
            }

            return try tokens.map { token in
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw ContainerizationError(.invalidArgument, message: "invalid \(instruction) assignment \(token)")
                }
                return .init(key: parts[0], value: parts[1])
            }
        }

        private func parseCommand(_ value: String, instruction: String) throws -> CommandForm {
            let trimmed = try requireNonEmpty(value, instruction: instruction)
            if trimmed.hasPrefix("[") {
                let payload = try JSONDecoder().decode([String].self, from: Data(trimmed.utf8))
                guard !payload.isEmpty else {
                    throw ContainerizationError(.invalidArgument, message: "\(instruction) exec form may not be empty")
                }
                return .exec(payload)
            }
            return .shell(trimmed)
        }

        private func parseUser(_ value: String) throws -> String {
            let trimmed = try requireNonEmpty(value, instruction: "USER")
            let tokens = try ShellTokenizer.tokenize(trimmed)
            guard tokens.count == 1, let user = tokens.first, !user.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "USER requires exactly one user specification")
            }
            return user
        }

        private func parseFileTransfer(_ value: String, instruction: String) throws -> FileTransferInstruction {
            let trimmed = try requireNonEmpty(value, instruction: instruction)
            if trimmed.hasPrefix("[") {
                let payload = try JSONDecoder().decode([String].self, from: Data(trimmed.utf8))
                guard payload.count >= 2 else {
                    throw ContainerizationError(.invalidArgument, message: "\(instruction) requires at least one source and one destination")
                }
                let destination = payload.last ?? ""
                let sources = Array(payload.dropLast())
                try validateFileTransferSources(sources, instruction: instruction)
                return .init(sources: sources, destination: destination, fromStage: nil)
            }

            if trimmed.hasPrefix("--"), let jsonStart = trimmed.firstIndex(of: "[") {
                let optionPart = String(trimmed[..<jsonStart]).trimmingCharacters(in: .whitespaces)
                let payloadPart = String(trimmed[jsonStart...]).trimmingCharacters(in: .whitespaces)
                let optionTokens = optionPart.isEmpty ? [] : try ShellTokenizer.tokenize(optionPart)
                var optionIndex = 0
                let fromStage = try parseFileTransferOptions(optionTokens, instruction: instruction, index: &optionIndex)
                if optionIndex == optionTokens.count {
                    let payload = try JSONDecoder().decode([String].self, from: Data(payloadPart.utf8))
                    guard payload.count >= 2 else {
                        throw ContainerizationError(.invalidArgument, message: "\(instruction) requires at least one source and one destination")
                    }
                    let destination = payload.last ?? ""
                    let sources = Array(payload.dropLast())
                    try validateFileTransferSources(sources, instruction: instruction)
                    return .init(sources: sources, destination: destination, fromStage: fromStage)
                }
            }

            let tokens = try ShellTokenizer.tokenize(trimmed)
            guard tokens.count >= 2 else {
                throw ContainerizationError(.invalidArgument, message: "\(instruction) requires at least one source and one destination")
            }

            var index = 0
            let fromStage = try parseFileTransferOptions(tokens, instruction: instruction, index: &index)
            let remaining = Array(tokens[index...])
            guard remaining.count >= 2 else {
                throw ContainerizationError(.invalidArgument, message: "\(instruction) requires at least one source and one destination")
            }

            let destination = remaining.last ?? ""
            let sources = Array(remaining.dropLast())
            try validateFileTransferSources(sources, instruction: instruction)
            return .init(sources: sources, destination: destination, fromStage: fromStage)
        }

        private func parseFileTransferOptions(
            _ tokens: [String],
            instruction: String,
            index: inout Int
        ) throws -> String? {
            var fromStage: String?
            while index < tokens.count, tokens[index].hasPrefix("--") {
                let option = tokens[index]
                if option == "--from" {
                    guard instruction == "COPY" else {
                        throw ContainerizationError(.unsupported, message: "darwin builds do not support \(instruction) option --from")
                    }
                    let nextIndex = index + 1
                    guard nextIndex < tokens.count else {
                        throw ContainerizationError(.invalidArgument, message: "\(instruction) --from requires a value")
                    }
                    guard fromStage == nil else {
                        throw ContainerizationError(.invalidArgument, message: "\(instruction) specifies --from more than once")
                    }
                    fromStage = normalizedStageReference(tokens[nextIndex])
                    index += 2
                    continue
                }
                if option.hasPrefix("--from=") {
                    guard instruction == "COPY" else {
                        throw ContainerizationError(.unsupported, message: "darwin builds do not support \(instruction) option --from")
                    }
                    let value = String(option.dropFirst("--from=".count))
                    guard !value.isEmpty else {
                        throw ContainerizationError(.invalidArgument, message: "\(instruction) --from requires a value")
                    }
                    guard fromStage == nil else {
                        throw ContainerizationError(.invalidArgument, message: "\(instruction) specifies --from more than once")
                    }
                    fromStage = normalizedStageReference(value)
                    index += 1
                    continue
                }
                throw ContainerizationError(.unsupported, message: "darwin builds do not support \(instruction) option \(option)")
            }
            return fromStage
        }

        private func validateFileTransferSources(_ sources: [String], instruction: String) throws {
            if instruction == "ADD", sources.contains(where: Self.looksLikeRemoteURL) {
                throw ContainerizationError(.unsupported, message: "darwin builds do not support ADD <url> in phase 1")
            }
        }

        private func validateCopySourceReferences(in stages: [Stage]) throws {
            for stage in stages {
                for instruction in stage.instructions {
                    guard case .copy(let fileTransfer) = instruction, let fromStage = fileTransfer.fromStage else {
                        continue
                    }
                    _ = try resolveCopySourceStageIndex(
                        reference: fromStage,
                        currentStageIndex: stage.index,
                        stages: stages
                    )
                }
            }
        }

        private func requireNonEmpty(_ value: String, instruction: String) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "\(instruction) requires a value")
            }
            return trimmed
        }

        private static func isValidVariableName(_ value: String) -> Bool {
            guard let first = value.first, first.isLetter || first == "_" else {
                return false
            }
            return value.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }

        private static func looksLikeRemoteURL(_ value: String) -> Bool {
            let lowercased = value.lowercased()
            return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
        }
    }
}

extension MacOSBuildEngine.Planner {
    enum LogicalLineParser {
        static func parse(_ text: String) throws -> [MacOSBuildEngine.Planner.LogicalLine] {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var result: [MacOSBuildEngine.Planner.LogicalLine] = []
            var buffer = ""
            var bufferLineNumber = 1

            for (offset, rawLine) in lines.enumerated() {
                let lineNumber = offset + 1
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

                if buffer.isEmpty, trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                }

                let hasContinuation = trailingBackslashCount(in: rawLine) % 2 == 1
                let segment = hasContinuation ? String(rawLine.dropLast()) : rawLine
                if buffer.isEmpty {
                    bufferLineNumber = lineNumber
                    buffer = segment
                } else {
                    buffer += " " + segment.trimmingCharacters(in: .whitespaces)
                }

                if hasContinuation {
                    continue
                }

                let cleaned = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = ""
                guard !cleaned.isEmpty, !cleaned.hasPrefix("#") else {
                    continue
                }

                let parts = cleaned.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
                let keyword = parts[0].uppercased()
                let arguments = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                result.append(
                    MacOSBuildEngine.Planner.LogicalLine(
                        lineNumber: bufferLineNumber,
                        keyword: keyword,
                        arguments: arguments
                    )
                )
            }

            guard buffer.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "unterminated line continuation in Dockerfile")
            }
            return result
        }

        private static func trailingBackslashCount(in line: String) -> Int {
            var count = 0
            for character in line.reversed() {
                if character.isWhitespace {
                    if count == 0 {
                        continue
                    }
                    break
                }
                if character == "\\" {
                    count += 1
                    continue
                }
                break
            }
            return count
        }
    }
}

extension MacOSBuildEngine {
    struct VariableExpander {
        static func expand(_ value: String, variables: [String: String]) throws -> String {
            var result = ""
            var index = value.startIndex

            while index < value.endIndex {
                let character = value[index]
                guard character == "$" else {
                    result.append(character)
                    index = value.index(after: index)
                    continue
                }

                let next = value.index(after: index)
                guard next < value.endIndex else {
                    result.append(character)
                    index = next
                    continue
                }

                if value[next] == "{" {
                    guard let closing = value[next...].firstIndex(of: "}") else {
                        throw ContainerizationError(.invalidArgument, message: "unterminated variable expression in \(value)")
                    }
                    let expression = String(value[value.index(after: next)..<closing])
                    result.append(resolve(expression: expression, variables: variables))
                    index = value.index(after: closing)
                    continue
                }

                let nameStart = next
                var cursor = nameStart
                while cursor < value.endIndex {
                    let candidate = value[cursor]
                    if candidate.isLetter || candidate.isNumber || candidate == "_" {
                        cursor = value.index(after: cursor)
                        continue
                    }
                    break
                }

                if cursor == nameStart {
                    result.append(character)
                    index = next
                    continue
                }

                let name = String(value[nameStart..<cursor])
                result.append(variables[name] ?? "")
                index = cursor
            }

            return result
        }

        private static func resolve(expression: String, variables: [String: String]) -> String {
            if let range = expression.range(of: ":-") {
                let name = String(expression[..<range.lowerBound])
                let fallback = String(expression[range.upperBound...])
                let value = variables[name] ?? ""
                return value.isEmpty ? fallback : value
            }
            if let range = expression.range(of: "-") {
                let name = String(expression[..<range.lowerBound])
                let fallback = String(expression[range.upperBound...])
                return variables[name] ?? fallback
            }
            return variables[expression] ?? ""
        }
    }

    enum ShellTokenizer {
        static func tokenize(_ value: String) throws -> [String] {
            var result: [String] = []
            var current = ""
            var quote: Character?
            var escaping = false

            for character in value {
                if escaping {
                    current.append(character)
                    escaping = false
                    continue
                }

                if character == "\\" && quote != "'" {
                    escaping = true
                    continue
                }

                if let activeQuote = quote {
                    if character == activeQuote {
                        quote = nil
                    } else {
                        current.append(character)
                    }
                    continue
                }

                if character == "\"" || character == "'" {
                    quote = character
                    continue
                }

                if character.isWhitespace {
                    if !current.isEmpty {
                        result.append(current)
                        current.removeAll(keepingCapacity: true)
                    }
                    continue
                }

                current.append(character)
            }

            if escaping || quote != nil {
                throw ContainerizationError(.invalidArgument, message: "unterminated quoted or escaped string in \(value)")
            }

            if !current.isEmpty {
                result.append(current)
            }
            return result
        }
    }
}

extension MacOSBuildEngine {
    final class BuildContextProvider {
        let contextRoot: URL
        private let rules: [DockerIgnoreRule]
        private let allEntries: [ContextEntry]
        private let includedEntries: [ContextEntry]
        private let includedEntryMap: [String: ContextEntry]

        init(contextRoot: URL) throws {
            let root = contextRoot.standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ContainerizationError(.notFound, message: "build context not found at \(root.path)")
            }
            let loadedRules = try Self.loadRules(from: root)
            let walkedEntries = try Self.walk(root: root)
            let included = walkedEntries.filter { !Self.isIgnored(relativePath: $0.relativePath, kind: $0.kind, rules: loadedRules) }

            self.contextRoot = root
            self.rules = loadedRules
            self.allEntries = walkedEntries
            self.includedEntries = included
            self.includedEntryMap = Dictionary(uniqueKeysWithValues: included.map { ($0.relativePath, $0) })
        }

        func resolveSources(_ rawSources: [String]) throws -> [ContextEntry] {
            var resolved: [String: ContextEntry] = [:]
            for rawSource in rawSources {
                let source = Self.normalizeInputPath(rawSource)
                if source == "." || source.isEmpty {
                    resolved[""] = .init(url: contextRoot, relativePath: "", kind: .directory)
                    continue
                }

                if Self.containsGlobPattern(source) {
                    let matches = includedEntries.filter { entry in
                        Self.matches(path: entry.relativePath, pattern: source, directory: entry.kind == .directory)
                    }
                    guard !matches.isEmpty else {
                        throw ContainerizationError(.notFound, message: "COPY/ADD source \(rawSource) did not match any files in the build context")
                    }
                    for match in matches {
                        resolved[match.relativePath] = match
                    }
                    continue
                }

                let candidateURL = contextRoot.appendingPathComponent(source)
                let resolvedParentURL = candidateURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                guard Self.isDescendant(resolvedParentURL, of: contextRoot) else {
                    throw ContainerizationError(.invalidArgument, message: "build source \(rawSource) escapes the build context")
                }

                let url = resolvedParentURL.appendingPathComponent(candidateURL.lastPathComponent).standardizedFileURL
                guard Self.isDescendant(url, of: contextRoot) else {
                    throw ContainerizationError(.invalidArgument, message: "build source \(rawSource) escapes the build context")
                }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ContainerizationError(.notFound, message: "build source \(rawSource) not found in the build context")
                }

                let kind = try Self.entryKind(at: url)
                let relativePath = try Self.relativePath(of: url, from: contextRoot)
                if kind == .directory {
                    let hasIncludedDescendants = includedEntries.contains { entry in
                        entry.relativePath.hasPrefix(relativePath + "/")
                    }
                    let ignored = Self.isIgnored(relativePath: relativePath, kind: kind, rules: rules)
                    guard !ignored || hasIncludedDescendants else {
                        throw ContainerizationError(.notFound, message: "build source \(rawSource) is excluded by .dockerignore")
                    }
                } else {
                    guard !Self.isIgnored(relativePath: relativePath, kind: kind, rules: rules) else {
                        throw ContainerizationError(.notFound, message: "build source \(rawSource) is excluded by .dockerignore")
                    }
                }
                resolved[relativePath] = .init(url: url, relativePath: relativePath, kind: kind)
            }

            return resolved.values.sorted { $0.relativePath < $1.relativePath }
        }

        func descendants(of source: ContextEntry) -> [ContextEntry] {
            guard source.kind == .directory else {
                return []
            }
            if source.relativePath.isEmpty {
                return includedEntries
            }
            let prefix = source.relativePath + "/"
            return includedEntries.filter { $0.relativePath.hasPrefix(prefix) }
        }

        private static func loadRules(from root: URL) throws -> [DockerIgnoreRule] {
            let ignoreURL = root.appendingPathComponent(".dockerignore")
            guard FileManager.default.fileExists(atPath: ignoreURL.path) else {
                return []
            }

            let content = try String(contentsOf: ignoreURL, encoding: .utf8)
            var rules: [DockerIgnoreRule] = []
            for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                    continue
                }
                let include = trimmed.hasPrefix("!")
                let pattern = normalizePattern(include ? String(trimmed.dropFirst()) : trimmed)
                guard !pattern.isEmpty else {
                    continue
                }
                let regex = try NSRegularExpression(pattern: regexPattern(for: pattern), options: [])
                rules.append(.init(include: include, regex: regex))
            }
            return rules
        }

        private static func walk(root: URL) throws -> [ContextEntry] {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [],
                    errorHandler: nil
                )
            else {
                return []
            }

            var entries: [ContextEntry] = []
            while let url = enumerator.nextObject() as? URL {
                let relativePath = try relativePath(of: url, from: root)
                guard !relativePath.isEmpty else {
                    continue
                }
                let kind = try entryKind(at: url)
                entries.append(.init(url: url, relativePath: relativePath, kind: kind))
                if kind == .symlink {
                    enumerator.skipDescendants()
                }
            }
            return entries.sorted { $0.relativePath < $1.relativePath }
        }

        private static func isIgnored(relativePath: String, kind: EntryKind, rules: [DockerIgnoreRule]) -> Bool {
            guard !relativePath.isEmpty else {
                return false
            }

            var excluded = false
            let fullRange = NSRange(relativePath.startIndex..<relativePath.endIndex, in: relativePath)
            for rule in rules {
                if rule.regex.firstMatch(in: relativePath, options: [], range: fullRange) != nil {
                    excluded = !rule.include
                } else if kind == .directory {
                    let directoryPath = relativePath + "/"
                    let range = NSRange(directoryPath.startIndex..<directoryPath.endIndex, in: directoryPath)
                    if rule.regex.firstMatch(in: directoryPath, options: [], range: range) != nil {
                        excluded = !rule.include
                    }
                }
            }
            return excluded
        }

        private static func normalizeInputPath(_ value: String) -> String {
            var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while path.hasPrefix("./") {
                path.removeFirst(2)
            }
            while path.hasPrefix("/") {
                path.removeFirst()
            }
            if path == "." {
                return "."
            }
            while path.contains("//") {
                path = path.replacingOccurrences(of: "//", with: "/")
            }
            return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        private static func normalizePattern(_ value: String) -> String {
            let preserveTrailingSlash = value.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
            var path = normalizeInputPath(value)
            if preserveTrailingSlash, !path.isEmpty, path != "." {
                path += "/"
            }
            return path
        }

        private static func containsGlobPattern(_ value: String) -> Bool {
            value.contains("*") || value.contains("?") || value.contains("[")
        }

        private static func matches(path: String, pattern: String, directory: Bool) -> Bool {
            let regex = try? NSRegularExpression(pattern: regexPattern(for: pattern), options: [])
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            if regex?.firstMatch(in: path, options: [], range: range) != nil {
                return true
            }
            if directory {
                let withSlash = path + "/"
                let slashRange = NSRange(withSlash.startIndex..<withSlash.endIndex, in: withSlash)
                return regex?.firstMatch(in: withSlash, options: [], range: slashRange) != nil
            }
            return false
        }

        private static func regexPattern(for pattern: String) -> String {
            let directoryOnly = pattern.hasSuffix("/")
            let normalized = directoryOnly ? String(pattern.dropLast()) : pattern
            var result = "^"
            var index = normalized.startIndex

            while index < normalized.endIndex {
                let character = normalized[index]
                if character == "*" {
                    let next = normalized.index(after: index)
                    if next < normalized.endIndex, normalized[next] == "*" {
                        let afterNext = normalized.index(after: next)
                        if afterNext < normalized.endIndex, normalized[afterNext] == "/" {
                            result += "(?:.*/)?"
                            index = normalized.index(after: afterNext)
                        } else {
                            result += ".*"
                            index = afterNext
                        }
                        continue
                    }
                    result += "[^/]*"
                    index = next
                    continue
                }

                if character == "?" {
                    result += "[^/]"
                    index = normalized.index(after: index)
                    continue
                }

                if ".+()|^$[]{}".contains(character) {
                    result += "\\\(character)"
                } else {
                    result.append(character)
                }
                index = normalized.index(after: index)
            }

            if directoryOnly {
                result += "(?:/.*)?$"
            } else {
                result += "$"
            }
            return result
        }

        private static func entryKind(at url: URL) throws -> EntryKind {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            if values.isSymbolicLink == true {
                return .symlink
            }
            if values.isDirectory == true {
                return .directory
            }
            return .file
        }

        private static func relativePath(of url: URL, from root: URL) throws -> String {
            let rootComponents = root.standardizedFileURL.pathComponents
            let urlComponents = url.standardizedFileURL.pathComponents
            guard urlComponents.starts(with: rootComponents) else {
                throw ContainerizationError(.invalidArgument, message: "\(url.path) escapes the build context")
            }
            return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }

        private static func isDescendant(_ url: URL, of root: URL) -> Bool {
            let rootComponents = root.standardizedFileURL.pathComponents
            let urlComponents = url.standardizedFileURL.pathComponents
            guard rootComponents.count <= urlComponents.count else {
                return false
            }
            return zip(rootComponents, urlComponents).allSatisfy(==)
        }
    }
}

extension MacOSBuildEngine {
    final class FileTransport {
        enum CopyKind {
            case copy
            case add
        }

        struct DestinationResolution {
            let path: String
            let treatAsDirectory: Bool
            let createDirectoryIfMissing: Bool
        }

        let sandboxClient: SandboxClient
        let contextProvider: BuildContextProvider
        let pathInspector: (String) async throws -> GuestPathKind

        init(
            sandboxClient: SandboxClient,
            contextProvider: BuildContextProvider,
            pathInspector: @escaping (String) async throws -> GuestPathKind
        ) {
            self.sandboxClient = sandboxClient
            self.contextProvider = contextProvider
            self.pathInspector = pathInspector
        }

        func createDirectory(at path: String, mode: UInt32? = nil) async throws {
            let normalized = normalizeAbsolutePath(path)
            let request = MacOSSidecarFSBeginRequestPayload(
                txID: UUID().uuidString,
                op: .mkdir,
                path: normalized,
                mode: mode,
                mtime: currentUnixTimestamp(),
                autoCommit: true
            )
            try await sandboxClient.fsBegin(request)
        }

        func copy(sources rawSources: [String], destination rawDestination: String, kind: CopyKind) async throws {
            let sources = try contextProvider.resolveSources(rawSources)
            let destination = normalizeDestination(rawDestination)
            let extractsArchive = kind == .add && sources.count == 1 && sources[0].kind == .file && Self.isArchiveFile(sources[0].url)

            guard !sources.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "COPY/ADD requires at least one source")
            }

            if kind == .add, sources.contains(where: { $0.kind == .file && Self.isArchiveFile($0.url) }), !extractsArchive {
                throw ContainerizationError(
                    .unsupported,
                    message: "darwin builds support ADD archive extraction only for a single local archive source in phase 1"
                )
            }

            let existingKind = try await pathInspector(destination.path)
            let resolution = try Self.resolveDestination(
                sources: sources,
                destination: destination,
                existingKind: existingKind,
                treatSingleSourceAsDirectoryTree: extractsArchive
            )

            if resolution.treatAsDirectory, resolution.createDirectoryIfMissing {
                try await createDirectory(at: resolution.path)
            }

            if extractsArchive {
                let tempRoot = try makeTemporaryDirectory(prefix: "macos-build-add")
                defer { try? FileManager.default.removeItem(at: tempRoot) }
                try Self.extractArchive(at: sources[0].url, into: tempRoot)
                try await copyDirectoryTree(
                    root: tempRoot,
                    destinationRoot: resolution.path,
                    includeTopLevelDirectory: nil
                )
                return
            }

            for source in sources {
                switch source.kind {
                case .file:
                    let targetPath = targetPath(for: source, destinationPath: resolution.path, treatAsDirectory: resolution.treatAsDirectory)
                    try await sendFile(at: source.url, to: targetPath)

                case .symlink:
                    let targetPath = targetPath(for: source, destinationPath: resolution.path, treatAsDirectory: resolution.treatAsDirectory)
                    try await sendSymlink(at: source.url, sourceDescription: source.relativePath, to: targetPath)

                case .directory:
                    if sources.count == 1 {
                        try await copyContextDirectory(source, destinationRoot: resolution.path, includeTopLevelDirectory: nil)
                    } else {
                        try await copyContextDirectory(
                            source,
                            destinationRoot: resolution.path,
                            includeTopLevelDirectory: source.url.lastPathComponent
                        )
                    }
                }
            }
        }

        func copyFromCache(
            sources rawSources: [String],
            destination rawDestination: String,
            cachedSources: [String: CachedStageSourceEntry]
        ) async throws {
            let sources = try rawSources.map { rawSource in
                let path = try MacOSBuildEngine.normalizedCopySourcePath(rawSource)
                guard let cached = cachedSources[path] else {
                    throw ContainerizationError(.notFound, message: "COPY --from source \(rawSource) not found in exported stage cache")
                }
                return cached
            }
            let destination = normalizeDestination(rawDestination)
            let existingKind = try await pathInspector(destination.path)
            let resolution = try Self.resolveDestination(
                sources: stageSourceResolutionEntries(for: sources),
                destination: destination,
                existingKind: existingKind
            )

            if resolution.treatAsDirectory, resolution.createDirectoryIfMissing {
                try await createDirectory(at: resolution.path)
            }

            for source in sources {
                switch source.kind {
                case .file:
                    let targetPath = targetPath(
                        forBasename: source.archiveName,
                        destinationPath: resolution.path,
                        treatAsDirectory: resolution.treatAsDirectory
                    )
                    try await sendFile(at: source.url, to: targetPath)

                case .symlink:
                    let targetPath = targetPath(
                        forBasename: source.archiveName,
                        destinationPath: resolution.path,
                        treatAsDirectory: resolution.treatAsDirectory
                    )
                    try await sendSymlink(
                        at: source.url,
                        sourceDescription: source.path,
                        to: targetPath
                    )

                case .directory:
                    if sources.count == 1 {
                        try await copyDirectoryTree(
                            root: source.url,
                            destinationRoot: resolution.path,
                            includeTopLevelDirectory: nil
                        )
                    } else {
                        try await copyDirectoryTree(
                            root: source.url,
                            destinationRoot: resolution.path,
                            includeTopLevelDirectory: source.archiveName
                        )
                    }
                }
            }
        }

        static func resolveDestination(
            sources: [ContextEntry],
            destination: DestinationPath,
            existingKind: GuestPathKind,
            treatSingleSourceAsDirectoryTree: Bool = false
        ) throws -> DestinationResolution {
            guard !sources.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "COPY/ADD requires at least one source")
            }

            let requiresDirectoryDestination =
                sources.count > 1
                || sources.contains(where: { $0.kind == .directory })
                || treatSingleSourceAsDirectoryTree

            if sources.count > 1 {
                guard destination.isDirectoryHint || existingKind == .directory else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "COPY/ADD with multiple sources requires the destination to be an existing directory or end with /"
                    )
                }
            }

            if requiresDirectoryDestination {
                guard existingKind != .nonDirectory else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "COPY/ADD cannot copy a directory tree to non-directory destination \(destination.rawValue)"
                    )
                }
                return .init(
                    path: destination.path,
                    treatAsDirectory: true,
                    createDirectoryIfMissing: existingKind == .missing
                )
            }

            if destination.isDirectoryHint || existingKind == .directory {
                return .init(
                    path: destination.path,
                    treatAsDirectory: true,
                    createDirectoryIfMissing: existingKind == .missing
                )
            }

            return .init(
                path: destination.path,
                treatAsDirectory: false,
                createDirectoryIfMissing: false
            )
        }

        private func copyContextDirectory(
            _ source: ContextEntry,
            destinationRoot: String,
            includeTopLevelDirectory: String?
        ) async throws {
            if let includeTopLevelDirectory {
                try await createDirectory(at: joinPaths(destinationRoot, includeTopLevelDirectory))
            }

            for entry in contextProvider.descendants(of: source) {
                let relativePath =
                    source.relativePath.isEmpty
                    ? entry.relativePath
                    : String(entry.relativePath.dropFirst(source.relativePath.count + 1))
                let basePath = includeTopLevelDirectory.map { joinPaths(destinationRoot, $0) } ?? destinationRoot
                let finalPath = joinPaths(basePath, relativePath)
                try await sendEntry(entry, to: finalPath)
            }
        }

        private func copyDirectoryTree(
            root: URL,
            destinationRoot: String,
            includeTopLevelDirectory: String?
        ) async throws {
            if let includeTopLevelDirectory {
                try await createDirectory(at: joinPaths(destinationRoot, includeTopLevelDirectory))
            }

            let entries = try Self.walkDirectoryTree(root: root)
            for entry in entries {
                let basePath = includeTopLevelDirectory.map { joinPaths(destinationRoot, $0) } ?? destinationRoot
                let finalPath = joinPaths(basePath, entry.relativePath)
                switch entry.kind {
                case .directory:
                    try await createDirectory(at: finalPath, mode: metadata(for: entry.url).mode)
                case .file:
                    try await sendFile(at: entry.url, to: finalPath)
                case .symlink:
                    try await sendSymlink(at: entry.url, sourceDescription: entry.relativePath, to: finalPath)
                }
            }
        }

        private func sendEntry(_ entry: ContextEntry, to path: String) async throws {
            switch entry.kind {
            case .directory:
                try await createDirectory(at: path, mode: metadata(for: entry.url).mode)
            case .file:
                try await sendFile(at: entry.url, to: path)
            case .symlink:
                try await sendSymlink(at: entry.url, sourceDescription: entry.relativePath, to: path)
            }
        }

        private func sendFile(at url: URL, to path: String) async throws {
            let attributes = metadata(for: url)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            let normalizedPath = normalizeAbsolutePath(path)

            if fileSize <= UInt64(MacOSBuildEngine.inlineDataLimit) {
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let request = MacOSSidecarFSBeginRequestPayload(
                    txID: UUID().uuidString,
                    op: .writeFile,
                    path: normalizedPath,
                    digest: "sha256:\(digest)",
                    mode: attributes.mode,
                    mtime: attributes.mtime,
                    overwrite: true,
                    inlineData: data,
                    autoCommit: true
                )
                try await sandboxClient.fsBegin(request)
                return
            }

            let txID = UUID().uuidString
            let beginRequest = MacOSSidecarFSBeginRequestPayload(
                txID: txID,
                op: .writeFile,
                path: normalizedPath,
                mode: attributes.mode,
                mtime: attributes.mtime,
                overwrite: true,
                autoCommit: false
            )
            do {
                try await sandboxClient.fsBegin(beginRequest)

                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                var hasher = SHA256()
                var offset: UInt64 = 0
                while let data = try handle.read(upToCount: MacOSBuildEngine.chunkSize), !data.isEmpty {
                    hasher.update(data: data)
                    try await sandboxClient.fsChunk(.init(txID: txID, offset: offset, data: data))
                    offset += UInt64(data.count)
                }

                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                try await sandboxClient.fsEnd(.init(txID: txID, action: .commit, digest: "sha256:\(digest)"))
            } catch {
                try? await sandboxClient.fsEnd(.init(txID: txID, action: .abort))
                throw error
            }
        }

        static func symlinkTarget(at url: URL, sourceDescription: String) throws -> String {
            do {
                return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            } catch {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "build source \(sourceDescription) is an invalid symlink",
                    cause: error
                )
            }
        }

        private func sendSymlink(at url: URL, sourceDescription: String, to path: String) async throws {
            let target = try Self.symlinkTarget(at: url, sourceDescription: sourceDescription)
            let attributes = metadata(for: url)
            let request = MacOSSidecarFSBeginRequestPayload(
                txID: UUID().uuidString,
                op: .symlink,
                path: normalizeAbsolutePath(path),
                mtime: attributes.mtime,
                linkTarget: target,
                overwrite: true,
                autoCommit: true
            )
            try await sandboxClient.fsBegin(request)
        }

        private func stageSourceResolutionEntries(for sources: [CachedStageSourceEntry]) -> [ContextEntry] {
            sources.map {
                .init(
                    url: $0.url,
                    relativePath: $0.archiveName,
                    kind: $0.kind
                )
            }
        }

        struct DestinationPath {
            let path: String
            let rawValue: String
            let isDirectoryHint: Bool
        }

        private func targetPath(for source: ContextEntry, destinationPath: String, treatAsDirectory: Bool) -> String {
            if treatAsDirectory {
                return joinPaths(destinationPath, source.url.lastPathComponent)
            }
            return destinationPath
        }

        private func targetPath(forBasename basename: String, destinationPath: String, treatAsDirectory: Bool) -> String {
            if treatAsDirectory {
                return joinPaths(destinationPath, basename)
            }
            return destinationPath
        }

        private func normalizeDestination(_ value: String) -> DestinationPath {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                path: normalizeAbsolutePath(trimmed, preserveTrailingSlash: false),
                rawValue: trimmed,
                isDirectoryHint: trimmed.hasSuffix("/")
            )
        }

        private func metadata(for url: URL) -> (mode: UInt32?, mtime: Int64?) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modeValue = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value
            let date = attributes?[.modificationDate] as? Date
            return (modeValue, date.map { Int64($0.timeIntervalSince1970) })
        }

        private static func isArchiveFile(_ url: URL) -> Bool {
            let name = url.lastPathComponent.lowercased()
            return
                name.hasSuffix(".tar")
                || name.hasSuffix(".tar.gz")
                || name.hasSuffix(".tgz")
                || name.hasSuffix(".tar.bz2")
                || name.hasSuffix(".tbz")
                || name.hasSuffix(".tar.xz")
                || name.hasSuffix(".txz")
        }

        fileprivate static func extractArchive(at source: URL, into destination: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", source.path, "-C", destination.path]
            let stderr = Pipe()
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "failed to extract archive"
                throw ContainerizationError(.internalError, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        static func walkDirectoryTree(root: URL) throws -> [ContextEntry] {
            let resolvedRoot = root.resolvingSymlinksInPath()
            var entries: [ContextEntry] = []
            try collectDirectoryTreeEntries(at: resolvedRoot, root: resolvedRoot, into: &entries)
            return entries
        }

        private static func collectDirectoryTreeEntries(
            at directory: URL,
            root: URL,
            into entries: inout [ContextEntry]
        ) throws {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for child in children {
                let relativePath = try relativePath(of: child, from: root)
                guard !relativePath.isEmpty else {
                    continue
                }

                let kind = try entryKind(at: child)
                entries.append(.init(url: child, relativePath: relativePath, kind: kind))

                if kind == .directory {
                    try collectDirectoryTreeEntries(at: child, root: root, into: &entries)
                }
            }
        }

        private static func entryKind(at url: URL) throws -> EntryKind {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                return .symlink
            }
            if values.isDirectory == true {
                return .directory
            }
            return .file
        }

        private static func relativePath(of url: URL, from root: URL) throws -> String {
            let rootComponents = lexicalPathComponents(for: root.path)
            let urlComponents = lexicalPathComponents(for: url.path)
            guard urlComponents.starts(with: rootComponents) else {
                throw ContainerizationError(.invalidArgument, message: "\(url.path) escapes \(root.path)")
            }
            return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }

        private static func lexicalPathComponents(for path: String) -> [String] {
            URL(fileURLWithPath: (path as NSString).standardizingPath).pathComponents
        }

        private func makeTemporaryDirectory(prefix: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }
}

extension MacOSBuildEngine {
    final class StageRuntime {
        let containerClient: ContainerClient
        let containerID: String
        let sandboxClient: SandboxClient

        private init(containerClient: ContainerClient, containerID: String, sandboxClient: SandboxClient) {
            self.containerClient = containerClient
            self.containerID = containerID
            self.sandboxClient = sandboxClient
        }

        static func start(
            appRoot: URL,
            buildID: String,
            baseImage: ClientImage,
            stageIndex: Int,
            cpus: Int64,
            memory: String
        ) async throws -> StageRuntime {
            let containerClient = ContainerClient()
            let containerID = MacOSBuildEngine.stageContainerID(buildID: buildID, stageIndex: stageIndex)
            let initProcess = ProcessConfiguration(
                executable: "/usr/bin/tail",
                arguments: ["-f", "/dev/null"],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            )

            var configuration = ContainerConfiguration(id: containerID, image: baseImage.description, process: initProcess)
            configuration.platform = MacOSBuildEngine.buildPlatform
            configuration.runtimeHandler = MacOSBuildEngine.runtimeName
            configuration.macosGuest = .init(snapshotEnabled: false, guiEnabled: false, agentPort: MacOSBuildEngine.defaultAgentPort)
            configuration.resources = try Parser.resources(cpus: cpus, memory: memory)
            configuration.resources.memoryInBytes = max(configuration.resources.memoryInBytes, 8192.mib())

            try await containerClient.create(
                configuration: configuration,
                options: .init(autoRemove: false)
            )

            do {
                let process = try await containerClient.bootstrap(id: containerID, stdio: [nil, nil, nil])
                try await ProcessIO.startProcess(
                    process: process,
                    startupMessage: "Waiting for macOS build guest..."
                )
                let sandboxClient = try await SandboxClient.create(id: containerID, runtime: MacOSBuildEngine.runtimeName)
                _ = appRoot
                return .init(containerClient: containerClient, containerID: containerID, sandboxClient: sandboxClient)
            } catch {
                try? await containerClient.delete(id: containerID, force: true)
                throw error
            }
        }

        func run(
            command: CommandForm,
            environment: [String: String],
            workingDirectory: String,
            user: ProcessConfiguration.User,
            quiet: Bool,
            log: Logger
        ) async throws {
            let io = try ProcessIO.create(tty: false, interactive: false, detach: quiet)
            defer { try? io.close() }

            let process = try await createProcess(
                command: command,
                environment: environment,
                workingDirectory: workingDirectory,
                user: user,
                stdio: io.stdio
            )
            let exitCode = try await io.handleProcess(
                process: process,
                log: log,
                startupMessage: quiet ? nil : "Waiting for macOS build guest..."
            )
            guard exitCode == 0 else {
                throw ContainerizationError(.internalError, message: "build step failed with exit code \(exitCode)")
            }
        }

        func inspectPath(_ path: String, log: Logger) async throws -> GuestPathKind {
            let directoryExitCode = try await runForStatus(
                command: .exec(["/bin/sh", "-c", "test -d \"$1\"", "sh", path]),
                environment: [:],
                workingDirectory: "/"
            )
            switch directoryExitCode {
            case 0:
                return .directory
            case 1:
                break
            default:
                throw ContainerizationError(.internalError, message: "failed to inspect destination path \(path)")
            }

            let existsExitCode = try await runForStatus(
                command: .exec(["/bin/sh", "-c", "test -e \"$1\"", "sh", path]),
                environment: [:],
                workingDirectory: "/"
            )
            switch existsExitCode {
            case 0:
                return .nonDirectory
            case 1:
                return .missing
            default:
                throw ContainerizationError(.internalError, message: "failed to inspect destination path \(path)")
            }
        }

        func resolveCopySources(_ rawSources: [String]) async throws -> [StageCopySourceEntry] {
            guard !rawSources.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "COPY --from requires at least one source")
            }

            var resolved: [StageCopySourceEntry] = []
            resolved.reserveCapacity(rawSources.count)
            for rawSource in rawSources {
                let normalized = try MacOSBuildEngine.normalizedCopySourcePath(rawSource)

                guard let kind = try await inspectEntryKind(at: normalized) else {
                    throw ContainerizationError(
                        .notFound,
                        message: "COPY --from source \(rawSource) not found in stage"
                    )
                }

                resolved.append(
                    .init(
                        originalPath: rawSource,
                        path: normalized,
                        archiveName: URL(fileURLWithPath: normalized).lastPathComponent,
                        kind: kind
                    ))
            }
            return resolved
        }

        func export(source: StageCopySourceEntry, to destinationRoot: URL) async throws {
            let tarURL = destinationRoot.appendingPathComponent("stage-source.tar")
            _ = FileManager.default.createFile(atPath: tarURL.path, contents: nil)

            let outputHandle = try FileHandle(forWritingTo: tarURL)
            let stdout = Pipe()
            let stderr = Pipe()
            defer {
                try? outputHandle.close()
                try? stdout.fileHandleForReading.close()
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                try? stderr.fileHandleForReading.close()
                try? FileManager.default.removeItem(at: tarURL)
            }

            let arguments = try Self.tarExportArguments(for: [source.path])
            let process = try await createProcess(
                command: .exec(["/usr/bin/tar", "-cf", "-"] + arguments),
                environment: [:],
                workingDirectory: "/",
                user: .id(uid: 0, gid: 0),
                stdio: [nil, stdout.fileHandleForWriting, stderr.fileHandleForWriting]
            )

            try await process.start()
            try stdout.fileHandleForWriting.close()
            try stderr.fileHandleForWriting.close()

            async let stdoutDrain: Void = Self.streamPipe(stdout.fileHandleForReading, into: outputHandle)
            async let stderrDrain: Data = Self.readAll(from: stderr.fileHandleForReading)
            let exitCode = try await process.wait()
            try await stdoutDrain
            let errorOutput = String(decoding: try await stderrDrain, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard exitCode == 0 else {
                let message = errorOutput.isEmpty ? "failed to export stage source \(source.originalPath)" : errorOutput
                throw ContainerizationError(.internalError, message: message)
            }

            try outputHandle.close()
            try FileTransport.extractArchive(at: tarURL, into: destinationRoot)
        }

        func stop() async throws {
            try await containerClient.stop(
                id: containerID,
                opts: .init(timeoutInSeconds: MacOSBuildEngine.stageStopTimeoutSeconds, signal: SIGTERM)
            )
        }

        func delete() async {
            await deleteWithRetries()
        }

        func cleanup() async {
            try? await containerClient.stop(
                id: containerID,
                opts: .init(timeoutInSeconds: MacOSBuildEngine.stageStopTimeoutSeconds, signal: SIGTERM)
            )
            await deleteWithRetries()
        }

        private func createProcess(
            command: CommandForm,
            environment: [String: String],
            workingDirectory: String,
            user: ProcessConfiguration.User,
            stdio: [FileHandle?]
        ) async throws -> ClientProcess {
            let processID = UUID().uuidString
            let config: ProcessConfiguration
            switch command {
            case .shell(let value):
                config = .init(
                    executable: "/bin/sh",
                    arguments: ["-c", value],
                    environment: environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" },
                    workingDirectory: workingDirectory,
                    terminal: false,
                    user: user
                )
            case .exec(let payload):
                guard let executable = payload.first else {
                    throw ContainerizationError(.invalidArgument, message: "RUN exec form requires an executable")
                }
                config = .init(
                    executable: executable,
                    arguments: Array(payload.dropFirst()),
                    environment: environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" },
                    workingDirectory: workingDirectory,
                    terminal: false,
                    user: user
                )
            }

            return try await containerClient.createProcess(
                containerId: containerID,
                processId: processID,
                configuration: config,
                stdio: stdio
            )
        }

        private func runForStatus(
            command: CommandForm,
            environment: [String: String],
            workingDirectory: String
        ) async throws -> Int32 {
            let process = try await createProcess(
                command: command,
                environment: environment,
                workingDirectory: workingDirectory,
                user: .id(uid: 0, gid: 0),
                stdio: [nil, nil, nil]
            )
            try await process.start()
            return try await process.wait()
        }

        private func inspectEntryKind(at path: String) async throws -> EntryKind? {
            let symlinkExitCode = try await runForStatus(
                command: .exec(["/bin/sh", "-c", "test -L \"$1\"", "sh", path]),
                environment: [:],
                workingDirectory: "/"
            )
            switch symlinkExitCode {
            case 0:
                return .symlink
            case 1:
                break
            default:
                throw ContainerizationError(.internalError, message: "failed to inspect stage source path \(path)")
            }

            let directoryExitCode = try await runForStatus(
                command: .exec(["/bin/sh", "-c", "test -d \"$1\"", "sh", path]),
                environment: [:],
                workingDirectory: "/"
            )
            switch directoryExitCode {
            case 0:
                return .directory
            case 1:
                break
            default:
                throw ContainerizationError(.internalError, message: "failed to inspect stage source path \(path)")
            }

            let existsExitCode = try await runForStatus(
                command: .exec(["/bin/sh", "-c", "test -e \"$1\"", "sh", path]),
                environment: [:],
                workingDirectory: "/"
            )
            switch existsExitCode {
            case 0:
                return .file
            case 1:
                return nil
            default:
                throw ContainerizationError(.internalError, message: "failed to inspect stage source path \(path)")
            }
        }

        private static func tarExportArguments(for paths: [String]) throws -> [String] {
            try paths.reduce(into: [String]()) { arguments, path in
                let normalized = normalizeAbsolutePath(path)
                guard normalized != "/" else {
                    throw ContainerizationError(.unsupported, message: "COPY --from / is not supported")
                }
                let url = URL(fileURLWithPath: normalized)
                let basename = url.lastPathComponent
                let parent = url.deletingLastPathComponent().path.isEmpty ? "/" : url.deletingLastPathComponent().path
                arguments += ["-C", parent, basename]
            }
        }

        private static func streamPipe(_ source: FileHandle, into destination: FileHandle) async throws {
            while let data = try source.read(upToCount: MacOSBuildEngine.chunkSize), !data.isEmpty {
                try destination.write(contentsOf: data)
            }
        }

        private static func readAll(from handle: FileHandle) async throws -> Data {
            var output = Data()
            while let data = try handle.read(upToCount: MacOSBuildEngine.chunkSize), !data.isEmpty {
                output.append(data)
            }
            return output
        }

        private func deleteWithRetries(maxAttempts: Int = 20, retryDelayNanoseconds: UInt64 = 250_000_000) async {
            for attempt in 1...maxAttempts {
                do {
                    try await containerClient.delete(id: containerID, force: true)
                    return
                } catch {
                    guard attempt < maxAttempts else {
                        return
                    }
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                }
            }
        }
    }
}

private func normalizeAbsolutePath(_ value: String, preserveTrailingSlash: Bool = false) -> String {
    let components = value.split(separator: "/", omittingEmptySubsequences: true).reduce(into: [String]()) { partial, component in
        switch component {
        case ".":
            break
        case "..":
            if !partial.isEmpty {
                partial.removeLast()
            }
        default:
            partial.append(String(component))
        }
    }
    let path = "/" + components.joined(separator: "/")
    if preserveTrailingSlash, value.hasSuffix("/"), path != "/" {
        return path + "/"
    }
    return path
}

private func pathContainsGlobPattern(_ value: String) -> Bool {
    value.contains("*") || value.contains("?") || value.contains("[")
}

private func joinPaths(_ lhs: String, _ rhs: String) -> String {
    let combined = lhs.hasSuffix("/") ? lhs + rhs : lhs + "/" + rhs
    return normalizeAbsolutePath(combined)
}

private func currentUnixTimestamp() -> Int64 {
    Int64(Date().timeIntervalSince1970)
}

extension String {
    fileprivate var sha256Prefix: String {
        let digest = SHA256.hash(data: Data(utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private struct FileHandleTextOutputStream: TextOutputStream {
    let fileHandle: FileHandle

    mutating func write(_ string: String) {
        try? fileHandle.write(contentsOf: Data(string.utf8))
    }
}

private func writeStderrLine(_ line: String) {
    var stream = FileHandleTextOutputStream(fileHandle: .standardError)
    print(line, to: &stream)
}
