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

func makeCRIShimWorkloadConfiguration(
    id: String,
    request: Runtime_V1_CreateContainerRequest
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
        workloadImageReference: image
    )
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
