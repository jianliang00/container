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
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import RuntimeMacOSSidecarShared

enum MacOSContainerCommitter {
    typealias ProgressHandler = @Sendable (String) -> Void

    enum SourceFlow: Equatable {
        case stopped
        case running
    }

    enum RestartAction: Equatable {
        case none
        case restartAfterClone
        case leaveStopped
    }

    private struct TemporaryPaths {
        let root: URL
        let imageDirectory: URL
        let outputTar: URL
    }

    private static let runtimeHandler = "container-runtime-macos"
    private static let commitImageDirectoryName = "commit-image"
    private static let buildPlatform = Platform(arch: "arm64", os: "darwin")

    static func commit(
        containerID: String,
        targetReference: String,
        leaveStopped: Bool,
        progress: ProgressHandler? = nil,
        detail: ProgressHandler? = nil
    ) async throws -> String? {
        let containerSystemConfig: ContainerSystemConfig = try await Application.loadContainerSystemConfig()
        let normalizedTargetReference = try normalizeTargetReference(
            targetReference,
            containerSystemConfig: containerSystemConfig
        )
        let client = ContainerClient()

        progress?("Validating container")
        let container = try await resolveContainer(id: containerID, client: client)
        try validate(container: container)

        let flow = try sourceFlow(for: container.status)
        let restartAction = restartAction(for: flow, leaveStopped: leaveStopped)
        let bundleRoot = try await resolveBundleRoot(for: container.id)
        let sourceImage = ClientImage(description: container.configuration.image)
        let baseImageConfig = try await resolveSourceImageConfig(
            image: sourceImage,
            reference: container.configuration.image.reference
        )
        let imageConfig = committedImageConfig(
            baseImageConfig: baseImageConfig,
            process: container.configuration.initProcess
        )

        let temporaryPaths = try makeTemporaryPaths()
        defer {
            try? FileManager.default.removeItem(at: temporaryPaths.root)
        }

        if let device = container.configuration.macosGuest?.blockDevices.first, device.kind.isNativeASIF {
            guard container.configuration.macosGuest?.machineState == nil else {
                throw ContainerizationError(.unsupported, message: "commit requires a CLI-managed ASIF guest")
            }
            let source = try MacOSImageLayers(manifest: await sourceImage.manifest(for: buildPlatform))
            let id = UUID()
            let sealed = MacOSNativeDisk.sealedDirectory(in: bundleRoot, id: id)
            defer { try? FileManager.default.removeItem(at: sealed) }
            let parents = try MacOSNativeDisk.effectiveParentNames(in: bundleRoot, configured: device.nativeParentPaths ?? [])
            guard parents.count + 3 <= MacOSDiskChain.maximumDepth else {
                throw ContainerizationError(.unsupported, message: "start a new instance from the compacted image before committing another ASIF layer")
            }
            progress?("Sealing native disk")
            switch flow {
            case .running:
                try sealRunningDisk(containerID: container.id, id: id)
                if leaveStopped { try await stopContainer(container.id, client: client) }
            case .stopped:
                let lease = try MacOSNativeDisk.acquireLifecycleLease(in: bundleRoot)
                defer { try? lease.close() }
                try MacOSNativeDisk.seal(in: bundleRoot, auxiliary: MacOSSandboxLayout(root: bundleRoot).auxiliaryStorageURL, parents: parents, id: id)
            }
            let size = try bundleRoot.appendingPathComponent("base.img").resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size else { throw CocoaError(.fileReadCorruptFile) }
            progress?("Packaging derived macOS OCI image")
            try MacOSImagePackager.packageDerived(
                source: source, logicalSize: Int64(size), sealed: sealed, parentNames: parents,
                imageConfig: imageConfig, reference: normalizedTargetReference, outputTar: temporaryPaths.outputTar, progress: detail)
            return try await loadCommittedImage(temporaryPaths.outputTar, containerID: container.id, target: normalizedTargetReference, progress: progress)
        }

        let bundleImageDirectory = try validateImageDirectory(at: bundleRoot)
        let packageImageDirectory: URL
        switch flow {
        case .stopped:
            packageImageDirectory = bundleImageDirectory.root

        case .running:
            progress?("Stopping running container")
            try await stopContainer(container.id, client: client)

            do {
                progress?("Cloning macOS image artifacts")
                try cloneCommitImage(from: bundleImageDirectory, to: temporaryPaths.imageDirectory)
            } catch {
                try await restartAfterCloneFailureIfNeeded(
                    action: restartAction,
                    containerID: container.id,
                    client: client
                )
                throw ContainerizationError(
                    .internalError,
                    message: "failed to clone macOS image artifacts from container \(container.id)",
                    cause: error
                )
            }

            if restartAction == .restartAfterClone {
                progress?("Restarting container")
                try await restartContainer(container.id, client: client)
            }

            packageImageDirectory = temporaryPaths.imageDirectory
        }

        let parentDiskSource = await resolveParentDiskSource(from: sourceImage)

        progress?("Packaging macOS OCI image")
        do {
            try MacOSImagePackager.package(
                imageDirectory: packageImageDirectory,
                outputTar: temporaryPaths.outputTar,
                reference: normalizedTargetReference,
                imageConfig: imageConfig,
                parentDiskSource: parentDiskSource,
                progress: detail
            )
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to package macOS container \(container.id) as an OCI image",
                cause: error
            )
        }

        _ = try await loadCommittedImage(temporaryPaths.outputTar, containerID: container.id, target: normalizedTargetReference, progress: progress)
        return nil
    }

    private static func loadCommittedImage(_ archive: URL, containerID: String, target: String, progress: ProgressHandler?) async throws -> String {
        progress?("Loading image into local store")
        let loadResult: ImageLoadResult
        do {
            loadResult = try await ClientImage.load(from: archive.path, force: false)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to load committed image archive for container \(containerID)",
                cause: error
            )
        }

        guard loadResult.rejectedMembers.isEmpty else {
            throw ContainerizationError(
                .internalError,
                message: "committed image archive contains rejected members: \(loadResult.rejectedMembers.joined(separator: ", "))"
            )
        }

        guard let loaded = loadResult.images.first else {
            throw ContainerizationError(
                .internalError,
                message: "image load did not return any images for committed container \(containerID)"
            )
        }

        progress?("Tagging committed image")
        for image in loadResult.images {
            do {
                _ = try await image.tag(new: target)
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to tag committed image as \(target)",
                    cause: error
                )
            }
        }
        return loaded.digest
    }

    private static func sealRunningDisk(containerID: String, id: UUID) throws {
        let fd = try MacOSSidecarSocketIO.connectUnixSocket(path: "/tmp/ctrm-sidecar-\(containerID).sock")
        defer { close(fd) }
        let request = MacOSSidecarRequest(
            requestID: id.uuidString, method: .vmSealNativeDisk,
            protocolVersion: MacOSSidecarProtocolVersion.durableCheckpointAdoption)
        try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.request(request), fd: fd, timeoutMilliseconds: 5000)
        let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: fd, timeoutMilliseconds: 90000)
        guard envelope.kind == .response, let response = envelope.response, response.requestID == request.requestID, response.ok else {
            throw ContainerizationError(.internalError, message: envelope.response?.error?.message ?? "invalid native disk seal response")
        }
    }

    static func validate(container: ContainerSnapshot) throws {
        let configuration = container.configuration
        guard configuration.platform.os == "darwin", configuration.platform.architecture == "arm64" else {
            throw ContainerizationError(
                .unsupported,
                message: "container \(container.id) is not a macOS guest container"
            )
        }
        guard configuration.macosGuest != nil else {
            throw ContainerizationError(
                .unsupported,
                message: "container \(container.id) is not a macOS guest container"
            )
        }
        guard configuration.runtimeHandler == runtimeHandler else {
            throw ContainerizationError(
                .unsupported,
                message: "container \(container.id) is not a macOS guest container"
            )
        }

        _ = try sourceFlow(for: container.status)
    }

    static func sourceFlow(for status: RuntimeStatus) throws -> SourceFlow {
        switch status {
        case .stopped:
            return .stopped
        case .running:
            return .running
        case .stopping, .unknown:
            throw ContainerizationError(
                .invalidState,
                message: "container is in unsupported state \(status.rawValue)"
            )
        }
    }

    static func restartAction(for flow: SourceFlow, leaveStopped: Bool) -> RestartAction {
        switch flow {
        case .stopped:
            return .none
        case .running:
            return leaveStopped ? .leaveStopped : .restartAfterClone
        }
    }

    static func committedImageConfig(
        baseImageConfig: ContainerizationOCI.Image,
        process: ProcessConfiguration,
        createdAt: Date = Date()
    ) -> ContainerizationOCI.Image {
        let entrypoint = process.executable.isEmpty ? nil : [process.executable]
        let cmd = process.arguments.isEmpty ? nil : process.arguments
        let env = process.environment.isEmpty ? nil : process.environment
        let imageConfig = ImageConfig(
            user: process.user.description,
            env: env,
            entrypoint: entrypoint,
            cmd: cmd,
            workingDir: process.workingDirectory,
            labels: baseImageConfig.config?.labels,
            stopSignal: baseImageConfig.config?.stopSignal
        )

        return .init(
            created: createdTimestamp(from: createdAt),
            author: baseImageConfig.author,
            architecture: baseImageConfig.architecture,
            os: baseImageConfig.os,
            osVersion: baseImageConfig.osVersion,
            osFeatures: baseImageConfig.osFeatures,
            variant: baseImageConfig.variant,
            config: imageConfig,
            rootfs: .init(type: "layers", diffIDs: []),
            history: baseImageConfig.history
        )
    }

    private static func normalizeTargetReference(
        _ reference: String,
        containerSystemConfig: ContainerSystemConfig
    ) throws -> String {
        do {
            return try ClientImage.normalizeReference(
                reference,
                containerSystemConfig: containerSystemConfig
            )
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid target reference \(reference)",
                cause: error
            )
        }
    }

    private static func resolveContainer(id: String, client: ContainerClient) async throws -> ContainerSnapshot {
        do {
            return try await client.get(id: id)
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            throw ContainerizationError(.notFound, message: "source container \(id) not found", cause: error)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to resolve source container \(id)",
                cause: error
            )
        }
    }

    private static func resolveBundleRoot(for containerID: String) async throws -> URL {
        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        return systemHealth.appRoot
            .appendingPathComponent("containers")
            .appendingPathComponent(containerID)
    }

    private static func validateImageDirectory(at root: URL) throws -> MacOSImagePackager.ImagePaths {
        do {
            return try MacOSImagePackager.validateImageDirectory(root)
        } catch {
            throw ContainerizationError(
                .invalidState,
                message: "container bundle \(root.path) is missing required macOS image artifacts",
                cause: error
            )
        }
    }

    private static func resolveSourceImageConfig(
        image: ClientImage,
        reference: String
    ) async throws -> ContainerizationOCI.Image {
        do {
            return try await image.config(for: buildPlatform)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to resolve darwin/arm64 image config for \(reference)",
                cause: error
            )
        }
    }

    private static func makeTemporaryPaths(fileManager: FileManager = .default) throws -> TemporaryPaths {
        let root = fileManager.temporaryDirectory.appendingPathComponent("container-commit-\(UUID().uuidString)")
        let imageDirectory = root.appendingPathComponent(commitImageDirectoryName)
        let outputTar = root.appendingPathComponent("out.tar")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        return .init(root: root, imageDirectory: imageDirectory, outputTar: outputTar)
    }

    private static func cloneCommitImage(
        from source: MacOSImagePackager.ImagePaths,
        to destinationRoot: URL
    ) throws {
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let artifacts: [(source: URL, destination: URL)] = [
            (source.diskImage, destinationRoot.appendingPathComponent(MacOSImagePackager.diskImageFilename)),
            (source.auxiliaryStorage, destinationRoot.appendingPathComponent(MacOSImagePackager.auxiliaryStorageFilename)),
            (source.hardwareModel, destinationRoot.appendingPathComponent(MacOSImagePackager.hardwareModelFilename)),
        ]

        for artifact in artifacts {
            _ = try FilesystemClone.cloneOrCopyItem(at: artifact.source, to: artifact.destination)
        }
    }

    private static func stopContainer(_ containerID: String, client: ContainerClient) async throws {
        do {
            try await client.stop(id: containerID)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container \(containerID)",
                cause: error
            )
        }
    }

    private static func restartContainer(_ containerID: String, client: ContainerClient) async throws {
        let io: ProcessIO
        do {
            io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to initialize detached I/O for container restart",
                cause: error
            )
        }
        defer {
            try? io.close()
        }

        do {
            let process = try await client.bootstrap(id: containerID, stdio: io.stdio)
            try await ProcessIO.startProcess(process: process, startupMessage: nil)
            try io.closeAfterStart()
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to restart container \(containerID)",
                cause: error
            )
        }
    }

    private static func restartAfterCloneFailureIfNeeded(
        action: RestartAction,
        containerID: String,
        client: ContainerClient
    ) async throws {
        guard action == .restartAfterClone else {
            return
        }
        try await restartContainer(containerID, client: client)
    }

    private static func resolveParentDiskSource(from sourceImage: ClientImage) async -> MacOSChunkedDiskSource? {
        try? await sourceImage.macOSChunkedDiskSource(for: buildPlatform)
    }

    private static func createdTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
