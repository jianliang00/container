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
import ContainerCRI
import ContainerKit
import ContainerPlugin
import ContainerResource
import ContainerizationOS
import Foundation
import RuntimeMacOSSidecarShared

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public protocol CRIShimRuntimeManaging: Sendable {
    func createSandbox(
        configuration: ContainerConfiguration
    ) async throws

    func startSandbox(
        id: String,
        presentGUI: Bool
    ) async throws

    func stopSandbox(
        id: String,
        options: ContainerStopOptions
    ) async throws

    func removeSandbox(
        id: String,
        force: Bool
    ) async throws

    func removeSandboxRuntimeService(
        id: String
    ) async throws

    func removeSandboxRuntimeService(
        id: String,
        machineStateOwnerUID: UInt32
    ) async throws

    func removeMachineStateSidecar(
        sandboxID: String,
        persistenceID: String,
        effectiveUserID: UInt32
    ) async throws

    func stopAndQuitMachineStateSidecar(
        controlSocketPath: String
    ) async throws

    func confirmSandboxRuntimeRemoved(
        id: String,
        machineStatePersistenceID: String?,
        machineStateOwnerUID: UInt32?
    ) async throws

    func removeSandboxPolicy(
        sandboxID: String
    ) async throws

    func inspectSandbox(
        id: String
    ) async throws -> SandboxSnapshot

    func listSandboxSnapshots() async throws -> [SandboxSnapshot]

    func createWorkload(
        sandboxID: String,
        configuration: WorkloadConfiguration
    ) async throws

    func startWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws

    func stopWorkload(
        sandboxID: String,
        workloadID: String,
        options: ContainerStopOptions
    ) async throws

    func removeWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws

    func inspectWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws -> WorkloadSnapshot

    func execSync(
        containerID: String,
        workloadID: String?,
        configuration: ProcessConfiguration,
        timeout: Duration?
    ) async throws -> ExecSyncResult

    func streamExec(
        containerID: String,
        workloadID: String?,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> any CRIShimStreamingProcess

    func streamPortForward(
        sandboxID: String,
        port: UInt32
    ) async throws -> FileHandle
}

public struct CRIShimTerminalSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public protocol CRIShimStreamingProcess: Sendable {
    func start() async throws
    func resize(_ size: CRIShimTerminalSize) async throws
    func kill(_ signal: Int32) async throws
    func wait() async throws -> Int32
}

private struct ContainerKitCRIShimStreamingProcess: CRIShimStreamingProcess {
    private let process: any ClientProcess

    init(process: any ClientProcess) {
        self.process = process
    }

    func start() async throws {
        try await process.start()
    }

    func resize(_ size: CRIShimTerminalSize) async throws {
        guard size.width > 0, size.width <= Int(UInt16.max) else {
            throw CRIShimError.invalidArgument("terminal width must be between 1 and \(UInt16.max)")
        }
        guard size.height > 0, size.height <= Int(UInt16.max) else {
            throw CRIShimError.invalidArgument("terminal height must be between 1 and \(UInt16.max)")
        }
        try await process.resize(
            Terminal.Size(
                width: UInt16(size.width),
                height: UInt16(size.height)
            )
        )
    }

    func kill(_ signal: Int32) async throws {
        try await process.kill(signal)
    }

    func wait() async throws -> Int32 {
        try await process.wait()
    }
}

struct CRIShimLaunchdOperations: Sendable {
    var domainString: @Sendable () throws -> String = { try ServiceManager.getDomainString() }
    var deregister: @Sendable (String) throws -> Void = { try ServiceManager.deregister(fullServiceLabel: $0) }
    var isRegisteredStrict: @Sendable (String) throws -> Bool = { try ServiceManager.isRegisteredStrict(fullServiceLabel: $0) }
}

public struct ContainerKitCRIShimRuntimeManager: CRIShimRuntimeManaging {
    public var kit: ContainerKit
    var launchd = CRIShimLaunchdOperations()

    public init(kit: ContainerKit = ContainerKit()) {
        self.kit = kit
    }

    public func createSandbox(
        configuration: ContainerConfiguration
    ) async throws {
        try await kit.createSandbox(configuration: configuration)
    }

    public func startSandbox(
        id: String,
        presentGUI: Bool
    ) async throws {
        try await kit.startSandbox(id: id, presentGUI: presentGUI)
    }

    public func stopSandbox(
        id: String,
        options: ContainerStopOptions
    ) async throws {
        try await kit.stopSandbox(id: id, options: options)
    }

    public func removeSandbox(
        id: String,
        force: Bool
    ) async throws {
        try await kit.removeSandbox(id: id, force: force)
    }

    public func removeSandboxRuntimeService(
        id: String
    ) async throws {
        let domain = try launchd.domainString()
        let label = "\(domain)/com.apple.container.container-runtime-macos.\(id)"
        try launchd.deregister(label)
    }

    /// The owner comes from the validated machine-state binding, not the
    /// cleanup caller's uid or inherited bootstrap session.
    public func removeSandboxRuntimeService(
        id: String,
        machineStateOwnerUID: UInt32
    ) async throws {
        try launchd.deregister(machineStateRuntimeServiceLabel(id: id, ownerUID: machineStateOwnerUID))
    }

    public func removeMachineStateSidecar(
        sandboxID: String,
        persistenceID: String,
        effectiveUserID: UInt32
    ) async throws {
        _ = try requireSafeIdentifier(
            persistenceID,
            annotation: CRIShimMachineStateAnnotation.persistenceID,
            maximumLength: 64
        )
        guard effectiveUserID != UInt32.max else {
            throw CRIShimError.invalidArgument("machine-state runtime owner uid is invalid")
        }
        let sidecarLabel = MacOSSidecarLaunchIdentity.fullLaunchLabel(
            sandboxID: sandboxID,
            persistenceID: persistenceID,
            effectiveUserID: effectiveUserID
        )
        try launchd.deregister(sidecarLabel)
    }

    public func stopAndQuitMachineStateSidecar(
        controlSocketPath: String
    ) async throws {
        let descriptor: Int32
        do {
            descriptor = try MacOSSidecarSocketIO.connectUnixSocket(path: controlSocketPath)
        } catch {
            throw CRIShimError.unavailable("machine-state sidecar control socket is unavailable")
        }
        defer { Darwin.close(descriptor) }

        try sendMachineStateSidecarShutdownRequest(method: .vmStop, descriptor: descriptor)
        try sendMachineStateSidecarShutdownRequest(method: .sidecarQuit, descriptor: descriptor)
    }

    public func confirmSandboxRuntimeRemoved(
        id: String,
        machineStatePersistenceID: String?,
        machineStateOwnerUID: UInt32?
    ) async throws {
        let runtimeLabel: String
        let sidecarLabel: String?
        switch (machineStatePersistenceID, machineStateOwnerUID) {
        case (nil, nil):
            let domain = try launchd.domainString()
            runtimeLabel = "\(domain)/com.apple.container.container-runtime-macos.\(id)"
            sidecarLabel = nil
        case (.some(let persistenceID), .some(let ownerUID)):
            _ = try requireSafeIdentifier(persistenceID, annotation: CRIShimMachineStateAnnotation.persistenceID, maximumLength: 64)
            runtimeLabel = try machineStateRuntimeServiceLabel(id: id, ownerUID: ownerUID)
            sidecarLabel = MacOSSidecarLaunchIdentity.fullLaunchLabel(
                sandboxID: id, persistenceID: persistenceID, effectiveUserID: ownerUID
            )
        default:
            throw CRIShimError.invalidArgument("machine-state runtime confirmation requires both persistence id and owner uid")
        }
        guard try !launchd.isRegisteredStrict(runtimeLabel) else {
            throw CRIShimError.unavailable(
                "sandbox runtime service remains registered after deletion"
            )
        }
        if let sidecarLabel {
            guard try !launchd.isRegisteredStrict(sidecarLabel) else {
                throw CRIShimError.unavailable(
                    "machine-state sidecar service remains registered after deletion"
                )
            }
        }
    }

    private func machineStateRuntimeServiceLabel(id: String, ownerUID: UInt32) throws -> String {
        _ = try requireSafeIdentifier(id, annotation: "machine-state runtime sandbox id", maximumLength: 64)
        guard ownerUID != UInt32.max else {
            throw CRIShimError.invalidArgument("machine-state runtime owner uid is invalid")
        }
        let domain = MacOSSidecarLaunchIdentity.launchdDomain(effectiveUserID: ownerUID)
        return "\(domain)/com.apple.container.container-runtime-macos.\(id)"
    }

    public func removeSandboxPolicy(
        sandboxID: String
    ) async throws {
        try await kit.removeSandboxPolicy(sandboxID: sandboxID)
    }

    public func inspectSandbox(
        id: String
    ) async throws -> SandboxSnapshot {
        try await kit.inspectSandbox(id: id)
    }

    public func listSandboxSnapshots() async throws -> [SandboxSnapshot] {
        let containers = try await kit.listContainers()
        var snapshots: [SandboxSnapshot] = []
        snapshots.reserveCapacity(containers.count)
        for container in containers where container.configuration.macosGuest != nil {
            snapshots.append(try await kit.inspectSandbox(id: container.id))
        }
        return snapshots
    }

    public func createWorkload(
        sandboxID: String,
        configuration: WorkloadConfiguration
    ) async throws {
        try await kit.createWorkload(sandboxID: sandboxID, configuration: configuration)
    }

    public func startWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws {
        try await kit.startWorkload(sandboxID: sandboxID, workloadID: workloadID)
    }

    public func stopWorkload(
        sandboxID: String,
        workloadID: String,
        options: ContainerStopOptions
    ) async throws {
        try await kit.stopWorkload(sandboxID: sandboxID, workloadID: workloadID, options: options)
    }

    public func removeWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws {
        try await kit.removeWorkload(sandboxID: sandboxID, workloadID: workloadID)
    }

    public func inspectWorkload(
        sandboxID: String,
        workloadID: String
    ) async throws -> WorkloadSnapshot {
        try await kit.inspectWorkload(sandboxID: sandboxID, workloadID: workloadID)
    }

    public func execSync(
        containerID: String,
        workloadID: String?,
        configuration: ProcessConfiguration,
        timeout: Duration?
    ) async throws -> ExecSyncResult {
        try await kit.execSync(
            id: containerID,
            configuration: configuration,
            workloadID: workloadID,
            timeout: timeout
        )
    }

    public func streamExec(
        containerID: String,
        workloadID: String?,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> any CRIShimStreamingProcess {
        let process = try await kit.streamExec(
            id: containerID,
            configuration: configuration,
            workloadID: workloadID,
            stdio: stdio
        )
        return ContainerKitCRIShimStreamingProcess(process: process)
    }

    public func streamPortForward(
        sandboxID: String,
        port: UInt32
    ) async throws -> FileHandle {
        try await kit.streamPortForward(id: sandboxID, port: port)
    }
}

private func sendMachineStateSidecarShutdownRequest(
    method: MacOSSidecarMethod,
    descriptor: Int32
) throws {
    let request = MacOSSidecarRequest(method: method)
    do {
        try MacOSSidecarSocketIO.writeJSONFrame(
            MacOSSidecarEnvelope.request(request),
            fd: descriptor,
            timeoutMilliseconds: 60_000
        )
        let envelope = try MacOSSidecarSocketIO.readJSONFrame(
            MacOSSidecarEnvelope.self,
            fd: descriptor,
            timeoutMilliseconds: 60_000
        )
        guard envelope.kind == .response,
            let response = envelope.response,
            response.requestID == request.requestID,
            response.ok
        else {
            throw CRIShimError.unavailable(
                "machine-state sidecar did not acknowledge \(method.rawValue)"
            )
        }
    } catch let error as CRIShimError {
        throw error
    } catch {
        throw CRIShimError.unavailable(
            "machine-state sidecar did not acknowledge \(method.rawValue)"
        )
    }
}

struct CRIShimExecSyncInvocation {
    var containerID: String
    var configuration: ProcessConfiguration
    var timeout: Duration?
}

struct CRIShimExecStreamingInvocation {
    var containerID: String
    var workloadID: String?
    var configuration: ProcessConfiguration
    var stdin: Bool
    var stdout: Bool
    var stderr: Bool
    var tty: Bool
}

struct CRIShimPortForwardInvocation {
    var sandboxID: String
    var ports: [UInt32]
}

let criShimExecSyncOutputLimitBytes = 16 * 1024 * 1024

func makeCRIShimExecSyncInvocation(
    _ request: Runtime_V1_ExecSyncRequest
) throws -> CRIShimExecSyncInvocation {
    let containerID = request.containerID.trimmed
    guard !containerID.isEmpty else {
        throw CRIShimError.invalidArgument("ExecSync container_id is required")
    }

    guard let executable = request.cmd.first?.trimmed, !executable.isEmpty else {
        throw CRIShimError.invalidArgument("ExecSync cmd must include an executable")
    }

    guard request.timeout >= 0 else {
        throw CRIShimError.invalidArgument("ExecSync timeout must be greater than or equal to zero")
    }

    let timeout: Duration? =
        if request.timeout == 0 {
            nil
        } else {
            Duration.seconds(request.timeout)
        }

    return CRIShimExecSyncInvocation(
        containerID: containerID,
        configuration: ProcessConfiguration(
            executable: executable,
            arguments: Array(request.cmd.dropFirst()),
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        ),
        timeout: timeout
    )
}

func makeCRIShimExecStreamingInvocation(
    _ request: Runtime_V1_ExecRequest
) throws -> CRIShimExecStreamingInvocation {
    let containerID = request.containerID.trimmed
    guard !containerID.isEmpty else {
        throw CRIShimError.invalidArgument("Exec container_id is required")
    }

    guard let executable = request.cmd.first?.trimmed, !executable.isEmpty else {
        throw CRIShimError.invalidArgument("Exec cmd must include an executable")
    }

    if request.tty, request.stderr {
        throw CRIShimError.invalidArgument("Exec tty and stderr cannot both be true")
    }
    if !request.stdin, !request.stdout, !request.stderr {
        throw CRIShimError.invalidArgument("Exec requires stdin, stdout, or stderr")
    }

    return CRIShimExecStreamingInvocation(
        containerID: containerID,
        workloadID: nil,
        configuration: ProcessConfiguration(
            executable: executable,
            arguments: Array(request.cmd.dropFirst()),
            environment: [],
            workingDirectory: "/",
            terminal: request.tty,
            user: .id(uid: 0, gid: 0)
        ),
        stdin: request.stdin,
        stdout: request.stdout,
        stderr: request.stderr,
        tty: request.tty
    )
}

func makeCRIShimExecProcessConfiguration(
    requested: ProcessConfiguration,
    workload: WorkloadSnapshot
) -> ProcessConfiguration {
    let defaults = workload.configuration.processConfiguration
    return ProcessConfiguration(
        executable: requested.executable,
        arguments: requested.arguments,
        environment: defaults.environment,
        workingDirectory: defaults.workingDirectory,
        terminal: requested.terminal,
        user: defaults.user,
        supplementalGroups: defaults.supplementalGroups,
        rlimits: defaults.rlimits
    )
}

func makeCRIShimPortForwardInvocation(
    _ request: Runtime_V1_PortForwardRequest
) throws -> CRIShimPortForwardInvocation {
    let sandboxID = request.podSandboxID.trimmed
    guard !sandboxID.isEmpty else {
        throw CRIShimError.invalidArgument("PortForward pod_sandbox_id is required")
    }

    let ports = try request.port.map { rawPort in
        guard rawPort > 0, rawPort <= UInt32(UInt16.max) else {
            throw CRIShimError.invalidArgument("PortForward port \(rawPort) must be between 1 and 65535")
        }
        return UInt32(rawPort)
    }

    return CRIShimPortForwardInvocation(
        sandboxID: sandboxID,
        ports: ports
    )
}

func makeCRIShimExecSyncResponse(
    _ result: ExecSyncResult,
    outputLimitBytes: Int = criShimExecSyncOutputLimitBytes
) -> Runtime_V1_ExecSyncResponse {
    var response = Runtime_V1_ExecSyncResponse()
    response.stdout = cappedExecSyncOutput(result.stdout, limit: outputLimitBytes)
    response.stderr = cappedExecSyncOutput(result.stderr, limit: outputLimitBytes)
    response.exitCode = result.exitCode
    return response
}

func makeCRIShimStopOptions(
    _ request: Runtime_V1_StopContainerRequest
) throws -> ContainerStopOptions {
    guard request.timeout >= 0 else {
        throw CRIShimError.invalidArgument("StopContainer timeout must be greater than or equal to zero")
    }
    guard request.timeout <= Int64(Int32.max) else {
        throw CRIShimError.invalidArgument("StopContainer timeout exceeds supported range")
    }

    let signal = request.timeout == 0 ? SIGKILL : SIGTERM
    return ContainerStopOptions(
        timeoutInSeconds: Int32(request.timeout),
        signal: Int32(signal)
    )
}

private func cappedExecSyncOutput(_ data: Data, limit: Int) -> Data {
    guard data.count > limit else {
        return data
    }
    return Data(data.prefix(limit))
}
