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
import ContainerSandboxServiceClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import TerminalProgress

/// A client for interacting with the container API server.
///
/// This client holds a reusable XPC connection and provides methods for
/// container lifecycle operations. All methods that operate on a specific
/// container take an `id` parameter.
public struct ContainerClient: Sendable {
    private static let serviceIdentifier = "com.apple.container.apiserver"

    private let xpcClient: XPCClient

    /// Creates a new container client with a connection to the API server.
    public init() {
        self.xpcClient = XPCClient(service: Self.serviceIdentifier)
    }

    @discardableResult
    private func xpcSend(
        message: XPCMessage,
        timeout: Duration? = .seconds(15)
    ) async throws -> XPCMessage {
        try await xpcClient.send(message, responseTimeout: timeout)
    }

    /// Create a new container with the given configuration.
    public func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default,
        kernel: Kernel? = nil,
        initImage: String? = nil
    ) async throws {
        do {
            let request = XPCMessage(route: .containerCreate)

            let data = try JSONEncoder().encode(configuration)
            let odata = try JSONEncoder().encode(options)
            request.set(key: .containerConfig, value: data)
            request.set(key: .containerOptions, value: odata)

            if let kernel {
                let kdata = try JSONEncoder().encode(kernel)
                request.set(key: .kernel, value: kdata)
            }

            if let initImage {
                request.set(key: .initImage, value: initImage)
            }

            try await xpcSend(message: request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create container",
                cause: error
            )
        }
    }

    /// Create a new sandbox with the given configuration.
    public func createSandbox(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default,
        kernel: Kernel? = nil,
        initImage: String? = nil
    ) async throws {
        try await create(
            configuration: configuration,
            options: options,
            kernel: kernel,
            initImage: initImage
        )
    }

    /// List containers matching the given filters.
    public func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        do {
            let request = XPCMessage(route: .containerList)
            let filterData = try JSONEncoder().encode(filters)
            request.set(key: .listFilters, value: filterData)

            let response = try await xpcSend(
                message: request,
                timeout: .seconds(10)
            )
            let data = response.dataNoCopy(key: .containers)
            guard let data else {
                return []
            }
            return try JSONDecoder().decode([ContainerSnapshot].self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to list containers",
                cause: error
            )
        }
    }

    /// Get the container for the provided id.
    public func get(id: String) async throws -> ContainerSnapshot {
        let containers = try await list(filters: ContainerListFilters(ids: [id]))
        guard let container = containers.first else {
            throw ContainerizationError(
                .notFound,
                message: "get failed: container \(id) not found"
            )
        }
        return container
    }

    /// Bootstrap the container's init process.
    public func bootstrap(
        id: String,
        stdio: [FileHandle?],
        presentGUI: Bool = true,
        progressUpdate: ProgressUpdateHandler? = nil
    ) async throws -> ClientProcess {
        let request = XPCMessage(route: .containerBootstrap)

        for (i, h) in stdio.enumerated() {
            let key: XPCKeys = try {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                }
            }()

            if let h {
                request.set(key: key, value: h)
            }
        }

        do {
            request.set(key: .id, value: id)
            request.set(key: .presentGUI, value: presentGUI)
            var progressUpdateClient: ProgressUpdateClient?
            if let progressUpdate {
                progressUpdateClient = await ProgressUpdateClient(for: progressUpdate, request: request)
            }
            try await xpcClient.send(request)
            await progressUpdateClient?.finish()
            return ClientProcessImpl(containerId: id, xpcClient: xpcClient)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to bootstrap container",
                cause: error
            )
        }
    }

    /// Start a sandbox guest without starting a workload.
    public func startSandbox(
        id: String,
        presentGUI: Bool = true,
        progressUpdate: ProgressUpdateHandler? = nil
    ) async throws {
        let request = XPCMessage(route: .containerStartSandbox)
        request.set(key: .id, value: id)
        request.set(key: .presentGUI, value: presentGUI)

        do {
            var progressUpdateClient: ProgressUpdateClient?
            if let progressUpdate {
                progressUpdateClient = await ProgressUpdateClient(for: progressUpdate, request: request)
            }
            try await xpcClient.send(request)
            await progressUpdateClient?.finish()
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to start sandbox",
                cause: error
            )
        }
    }

    /// Present the desktop window for a running macOS sandbox guest.
    public func showSandboxGUI(id: String) async throws {
        let request = XPCMessage(route: .containerShowSandboxGUI)
        request.set(key: .id, value: id)

        do {
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to show sandbox GUI",
                cause: error
            )
        }
    }

    /// Inspect the current sandbox snapshot.
    public func inspectSandbox(id: String) async throws -> SandboxSnapshot {
        let request = XPCMessage(route: .containerState)
        request.set(key: .id, value: id)

        do {
            let response = try await xpcSend(message: request)
            return try response.sandboxSnapshot()
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to inspect sandbox",
                cause: error
            )
        }
    }

    /// Send a signal to the container.
    public func kill(id: String, signal: Int32) async throws {
        do {
            let request = XPCMessage(route: .containerKill)
            request.set(key: .id, value: id)
            request.set(key: .processIdentifier, value: id)
            request.set(key: .signal, value: Int64(signal))

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to kill container",
                cause: error
            )
        }
    }

    /// Stop the container and all processes currently executing inside.
    public func stop(id: String, opts: ContainerStopOptions = ContainerStopOptions.default) async throws {
        do {
            let request = XPCMessage(route: .containerStop)
            let data = try JSONEncoder().encode(opts)
            request.set(key: .id, value: id)
            request.set(key: .stopOptions, value: data)

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container",
                cause: error
            )
        }
    }

    /// Delete the container along with any resources.
    public func delete(id: String, force: Bool = false) async throws {
        do {
            let request = XPCMessage(route: .containerDelete)
            request.set(key: .id, value: id)
            request.set(key: .forceDelete, value: force)
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to delete container",
                cause: error
            )
        }
    }

    /// Get the disk usage for a container.
    public func diskUsage(id: String) async throws -> UInt64 {
        let request = XPCMessage(route: .containerDiskUsage)
        request.set(key: .id, value: id)
        let reply = try await xpcClient.send(request)

        let size = reply.uint64(key: .containerSize)
        return size
    }

    /// Create a new process inside a running container.
    /// The process is in a created state and must still be started.
    public func createProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        do {
            let request = XPCMessage(route: .containerCreateProcess)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: processId)

            let data = try JSONEncoder().encode(configuration)
            request.set(key: .processConfig, value: data)

            for (i, h) in stdio.enumerated() {
                let key: XPCKeys = try {
                    switch i {
                    case 0: .stdin
                    case 1: .stdout
                    case 2: .stderr
                    default:
                        throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                    }
                }()

                if let h {
                    request.set(key: key, value: h)
                }
            }

            try await xpcClient.send(request)
            return ClientProcessImpl(containerId: containerId, processId: processId, xpcClient: xpcClient)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create process in container",
                cause: error
            )
        }
    }

    /// Create a streaming exec process inside a running container.
    public func streamExec(
        containerId: String,
        processId: String = UUID().uuidString.lowercased(),
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        try await createProcess(
            containerId: containerId,
            processId: processId,
            configuration: configuration,
            stdio: stdio
        )
    }

    /// Execute a process synchronously and capture stdout and stderr.
    public func execSync(
        containerId: String,
        configuration: ProcessConfiguration,
        timeout: Duration? = nil,
        standardInput: Data? = nil
    ) async throws -> ExecSyncResult {
        try await ExecSyncRunner.run(
            timeout: timeout,
            standardInput: standardInput
        ) { stdio in
            try await self.createProcess(
                containerId: containerId,
                processId: UUID().uuidString.lowercased(),
                configuration: configuration,
                stdio: stdio
            )
        }
    }

    /// Create a workload inside a started sandbox.
    public func createWorkload(
        containerId: String,
        configuration: WorkloadConfiguration,
        stdio: [FileHandle?] = [nil, nil, nil]
    ) async throws {
        do {
            let request = XPCMessage(route: .containerCreateWorkload)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: configuration.id)
            let data = try JSONEncoder().encode(configuration)
            request.set(key: .workloadConfig, value: data)

            for (i, h) in stdio.enumerated() {
                let key: XPCKeys = try {
                    switch i {
                    case 0: .stdin
                    case 1: .stdout
                    case 2: .stderr
                    default:
                        throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                    }
                }()

                if let h {
                    request.set(key: key, value: h)
                }
            }

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create workload in sandbox",
                cause: error
            )
        }
    }

    /// Start a workload that was already created inside a sandbox.
    public func startWorkload(containerId: String, workloadId: String) async throws {
        do {
            let request = XPCMessage(route: .containerStartWorkload)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: workloadId)
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to start workload in sandbox",
                cause: error
            )
        }
    }

    /// Attach to a running workload's primary session.
    public func attachWorkload(
        containerId: String,
        workloadId: String,
        options: WorkloadAttachOptions = .init(),
        stdio: [FileHandle?],
        attachmentID: String = UUID().uuidString.lowercased()
    ) async throws -> ClientWorkloadAttachment {
        do {
            let request = XPCMessage(route: .containerAttachWorkload)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: workloadId)
            request.set(key: .attachmentIdentifier, value: attachmentID)
            request.set(key: .attachOptions, value: try JSONEncoder().encode(options))

            for (i, h) in stdio.enumerated() {
                let key: XPCKeys = try {
                    switch i {
                    case 0: .stdin
                    case 1: .stdout
                    case 2: .stderr
                    default:
                        throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                    }
                }()

                if let h {
                    request.set(key: key, value: h)
                }
            }

            try await xpcClient.send(request)
            return ClientWorkloadAttachmentImpl(
                containerId: containerId,
                workloadId: workloadId,
                attachmentID: attachmentID,
                takesControl: options.takesControl,
                xpcClient: xpcClient
            )
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to attach workload in sandbox",
                cause: error
            )
        }
    }

    /// Stop a workload running inside a sandbox.
    public func stopWorkload(
        containerId: String,
        workloadId: String,
        options: ContainerStopOptions = .default
    ) async throws {
        do {
            let request = XPCMessage(route: .containerStopWorkload)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: workloadId)
            let data = try JSONEncoder().encode(options)
            request.set(key: .stopOptions, value: data)
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop workload in sandbox",
                cause: error
            )
        }
    }

    /// Remove a stopped workload from a sandbox.
    public func removeWorkload(containerId: String, workloadId: String) async throws {
        do {
            let request = XPCMessage(route: .containerRemoveWorkload)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: workloadId)
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to remove workload from sandbox",
                cause: error
            )
        }
    }

    /// Inspect a workload inside a sandbox.
    public func inspectWorkload(containerId: String, workloadId: String) async throws -> WorkloadSnapshot {
        do {
            let request = XPCMessage(route: .containerInspectWorkload)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: workloadId)
            let response = try await xpcClient.send(request)
            return try response.workloadSnapshot()
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to inspect workload in sandbox",
                cause: error
            )
        }
    }

    /// Get the log file handles for a container.
    public func logs(id: String) async throws -> [FileHandle] {
        do {
            let request = XPCMessage(route: .containerLogs)
            request.set(key: .id, value: id)

            let response = try await xpcClient.send(request)
            let fds = response.fileHandles(key: .logs)
            guard let fds else {
                throw ContainerizationError(
                    .internalError,
                    message: "no log fds returned"
                )
            }
            return fds
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get logs for container \(id)",
                cause: error
            )
        }
    }

    /// Return stable host log paths for a sandbox.
    public func sandboxLogPaths(id: String) async throws -> SandboxLogPaths {
        do {
            let request = XPCMessage(route: .containerSandboxLogPaths)
            request.set(key: .id, value: id)
            let response = try await xpcClient.send(request)
            guard let data = response.dataNoCopy(key: .sandboxLogPaths) else {
                throw ContainerizationError(.invalidState, message: "sandbox log paths were not returned")
            }
            return try JSONDecoder().decode(SandboxLogPaths.self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to inspect sandbox logs",
                cause: error
            )
        }
    }

    /// Dial a port on the container via vsock.
    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        let request = XPCMessage(route: .containerDial)
        request.set(key: .id, value: id)
        request.set(key: .port, value: UInt64(port))

        let response: XPCMessage
        do {
            response = try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to dial port \(port) on container",
                cause: error
            )
        }
        guard let fh = response.fileHandle(key: .fd) else {
            throw ContainerizationError(
                .internalError,
                message: "failed to get fd for vsock port \(port)"
            )
        }
        return fh
    }

    /// Get resource usage statistics for a container.
    public func stats(id: String) async throws -> ContainerStats {
        let request = XPCMessage(route: .containerStats)
        request.set(key: .id, value: id)

        do {
            let response = try await xpcClient.send(request)
            guard let data = response.dataNoCopy(key: .statistics) else {
                throw ContainerizationError(
                    .internalError,
                    message: "no statistics data returned"
                )
            }
            return try JSONDecoder().decode(ContainerStats.self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get statistics for container \(id)",
                cause: error
            )
        }
    }
}

extension XPCMessage {
    fileprivate func sandboxSnapshot() throws -> SandboxSnapshot {
        guard let data = dataNoCopy(key: .snapshot) else {
            throw ContainerizationError(.invalidState, message: "sandbox snapshot was not returned")
        }
        return try JSONDecoder().decode(SandboxSnapshot.self, from: data)
    }

    fileprivate func workloadSnapshot() throws -> WorkloadSnapshot {
        guard let data = dataNoCopy(key: .workloadSnapshot) else {
            throw ContainerizationError(.invalidState, message: "workload snapshot was not returned")
        }
        return try JSONDecoder().decode(WorkloadSnapshot.self, from: data)
    }
}
