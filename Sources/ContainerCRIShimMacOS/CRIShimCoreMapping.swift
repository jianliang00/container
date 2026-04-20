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

import ContainerCRI
import ContainerResource
import ContainerizationOCI
import Foundation

func makeCRIShimSandboxMetadata(
    id: String,
    request: Runtime_V1_RunPodSandboxRequest,
    handler: ResolvedRuntimeHandler,
    now: Date = Date()
) throws -> CRIShimSandboxMetadata {
    let sandboxID = id.trimmed
    guard !sandboxID.isEmpty else {
        throw CRIShimError.invalidArgument("sandbox id is required")
    }

    let config = request.config
    return CRIShimSandboxMetadata(
        id: sandboxID,
        podUID: emptyStringAsNil(config.metadata.uid),
        namespace: emptyStringAsNil(config.metadata.namespace),
        name: emptyStringAsNil(config.metadata.name),
        attempt: config.metadata.attempt,
        runtimeHandler: handler.name ?? "",
        sandboxImage: handler.sandboxImage,
        network: handler.network,
        labels: config.labels,
        annotations: config.annotations,
        state: .pending,
        createdAt: now,
        updatedAt: now
    )
}

func makeCRIShimSandboxConfiguration(
    id: String,
    request: Runtime_V1_RunPodSandboxRequest,
    handler: ResolvedRuntimeHandler,
    sandboxImage: CRIShimImageRecord,
    metadata: CRIShimSandboxMetadata? = nil
) throws -> ContainerConfiguration {
    let sandboxID = id.trimmed
    guard !sandboxID.isEmpty else {
        throw CRIShimError.invalidArgument("sandbox id is required")
    }

    var configuration = ContainerConfiguration(
        id: sandboxID,
        image: try makeCRIShimImageDescription(sandboxImage, requestedReference: handler.sandboxImage),
        process: ProcessConfiguration(
            executable: "/usr/bin/true",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
    )
    configuration.platform = Platform(
        arch: handler.workloadPlatform.architecture ?? "arm64",
        os: handler.workloadPlatform.os ?? "darwin"
    )
    configuration.runtimeHandler = "container-runtime-macos"
    configuration.labels = request.config.labels
    if let metadata {
        configuration.labels[CRIShimCoreLabel.sandboxMetadata] = try makeCRIShimCoreMetadataLabel(metadata)
    }
    configuration.macosGuest = ContainerConfiguration.MacOSGuestOptions(
        snapshotEnabled: false,
        guiEnabled: handler.guiEnabled,
        agentPort: 27_000,
        networkBackend: try makeCRIShimMacOSNetworkBackend(handler.networkBackend)
    )
    return configuration
}

enum CRIShimCoreLabel {
    static let sandboxMetadata = "org.apple.container.cri.macos.sandbox-metadata"
}

func makeCRIShimCoreMetadataLabel(_ metadata: CRIShimSandboxMetadata) throws -> String {
    let data = try JSONEncoder.criShimMetadataEncoder.encode(metadata)
    return String(decoding: data, as: UTF8.self)
}

func decodeCRIShimCoreSandboxMetadataLabel(_ labels: [String: String]) -> CRIShimSandboxMetadata? {
    guard let value = labels[CRIShimCoreLabel.sandboxMetadata] else {
        return nil
    }
    return try? JSONDecoder.criShimMetadataDecoder.decode(CRIShimSandboxMetadata.self, from: Data(value.utf8))
}

func removeCRIShimCoreLabels(_ labels: [String: String]) -> [String: String] {
    labels.filter { key, _ in key != CRIShimCoreLabel.sandboxMetadata }
}

func makeCRIShimContainerMetadata(
    id: String,
    request: Runtime_V1_CreateContainerRequest,
    sandbox: CRIShimSandboxMetadata,
    now: Date = Date()
) throws -> CRIShimContainerMetadata {
    let containerID = id.trimmed
    guard !containerID.isEmpty else {
        throw CRIShimError.invalidArgument("container id is required")
    }

    let config = request.config
    let image = try CRIShimImageReference.resolve(config.image)
    return CRIShimContainerMetadata(
        id: containerID,
        sandboxID: sandbox.id,
        name: containerName(from: config),
        attempt: config.metadata.attempt,
        image: image,
        runtimeHandler: sandbox.runtimeHandler,
        labels: config.labels,
        annotations: config.annotations,
        command: config.command,
        args: config.args,
        workingDirectory: emptyStringAsNil(config.workingDir),
        logPath: makeCRIShimLogPath(
            logDirectory: request.sandboxConfig.logDirectory,
            logPath: config.logPath
        ),
        state: .created,
        createdAt: now
    )
}

func makeCRIShimImageDescription(
    _ image: CRIShimImageRecord,
    requestedReference: String
) throws -> ImageDescription {
    let digest = image.digest.trimmed
    guard !digest.isEmpty else {
        throw CRIShimError.invalidArgument("image \(requestedReference) is missing a resolved digest")
    }

    let mediaType = image.mediaType.trimmed
    guard !mediaType.isEmpty else {
        throw CRIShimError.invalidArgument("image \(requestedReference) is missing a descriptor media type")
    }

    return ImageDescription(
        reference: image.reference.trimmed.isEmpty ? requestedReference : image.reference,
        descriptor: Descriptor(
            mediaType: mediaType,
            digest: digest,
            size: Int64(min(image.size, UInt64(Int64.max))),
            annotations: image.annotations.isEmpty ? nil : image.annotations
        )
    )
}

func makeCRIShimWorkloadConfiguration(
    id: String,
    request: Runtime_V1_CreateContainerRequest,
    workloadImageDigest: String? = nil
) throws -> WorkloadConfiguration {
    let containerID = id.trimmed
    guard !containerID.isEmpty else {
        throw CRIShimError.invalidArgument("container id is required")
    }

    let config = request.config
    let image = try CRIShimImageReference.resolve(config.image)
    return WorkloadConfiguration(
        id: containerID,
        processConfiguration: makeProcessConfiguration(config),
        workloadImageReference: image,
        workloadImageDigest: emptyStringAsNil(workloadImageDigest ?? "")
    )
}

private func makeCRIShimMacOSNetworkBackend(
    _ value: String
) throws -> ContainerConfiguration.MacOSGuestOptions.NetworkBackend {
    switch value.trimmed {
    case "virtualizationNAT":
        return .virtualizationNAT
    case "vmnetShared":
        return .vmnetShared
    default:
        throw CRIShimError.invalidArgument("unsupported macOS network backend: \(value)")
    }
}

func makeCRIShimMounts(_ mounts: [Runtime_V1_Mount]) throws -> [Filesystem] {
    try mounts.map(makeCRIShimMount)
}

private func makeCRIShimMount(_ mount: Runtime_V1_Mount) throws -> Filesystem {
    guard !mount.hasImage else {
        throw CRIShimError.unsupported("CRI image mounts are not supported for macOS guest workloads")
    }
    guard mount.propagation == .propagationPrivate else {
        throw CRIShimError.unsupported("CRI mount propagation must be private for macOS guest workloads")
    }
    guard !mount.selinuxRelabel else {
        throw CRIShimError.unsupported("SELinux relabeling is not supported for macOS guest workloads")
    }
    guard mount.uidMappings.isEmpty, mount.gidMappings.isEmpty else {
        throw CRIShimError.unsupported("ID-mapped mounts are not supported for macOS guest workloads")
    }
    guard !mount.recursiveReadOnly else {
        throw CRIShimError.unsupported("recursive read-only mounts are not supported for macOS guest workloads")
    }

    let hostPath = mount.hostPath.trimmed
    guard !hostPath.isEmpty else {
        throw CRIShimError.invalidArgument("CRI mount host_path is required")
    }
    guard hostPath.hasPrefix("/") else {
        throw CRIShimError.invalidArgument("CRI mount host_path must be absolute")
    }

    let containerPath = mount.containerPath.trimmed
    guard !containerPath.isEmpty else {
        throw CRIShimError.invalidArgument("CRI mount container_path is required")
    }
    guard containerPath.hasPrefix("/") else {
        throw CRIShimError.invalidArgument("CRI mount container_path must be absolute")
    }

    var options: MountOptions = []
    if mount.readonly {
        options.append("ro")
    }
    return .virtiofs(source: hostPath, destination: containerPath, options: options)
}

private func makeProcessConfiguration(_ config: Runtime_V1_ContainerConfig) -> ProcessConfiguration {
    let command = config.command
    let executable = command.first ?? ""
    let arguments =
        if command.isEmpty {
            config.args
        } else {
            Array(command.dropFirst()) + config.args
        }

    return ProcessConfiguration(
        executable: executable,
        arguments: arguments,
        environment: config.envs.map { "\($0.key)=\($0.value)" },
        workingDirectory: config.workingDir.isEmpty ? "/" : config.workingDir,
        terminal: config.tty,
        user: .id(uid: 0, gid: 0)
    )
}

private func makeCRIShimLogPath(logDirectory: String, logPath: String) -> String? {
    let normalizedLogPath = logPath.trimmed
    guard !normalizedLogPath.isEmpty else {
        return nil
    }

    if normalizedLogPath.hasPrefix("/") {
        return URL(fileURLWithPath: normalizedLogPath).standardizedFileURL.path
    }

    let normalizedLogDirectory = logDirectory.trimmed
    guard !normalizedLogDirectory.isEmpty else {
        return normalizedLogPath
    }

    return URL(fileURLWithPath: normalizedLogDirectory)
        .appendingPathComponent(normalizedLogPath)
        .standardizedFileURL
        .path
}

private func containerName(from config: Runtime_V1_ContainerConfig) -> String {
    let name = config.metadata.name.trimmed
    guard !name.isEmpty else {
        return config.image.image.trimmed
    }
    return name
}

private func emptyStringAsNil(_ value: String) -> String? {
    let trimmed = value.trimmed
    return trimmed.isEmpty ? nil : trimmed
}
