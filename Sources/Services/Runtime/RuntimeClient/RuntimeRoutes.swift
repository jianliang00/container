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

/// XPC routes exposed by the runtime service.
public enum RuntimeRoutes: String {
    // MARK: - Service lifecycle

    /// Create an XPC endpoint for communicating with the runtime service.
    case createEndpoint = "com.apple.container.runtime/createEndpoint"
    /// Shut down the runtime service process. Requires the sandbox to be stopped first.
    case shutdown = "com.apple.container.runtime/shutdown"

    // MARK: - Sandbox lifecycle

    /// Create sandbox resources without booting the guest.
    case createSandbox = "com.apple.container.runtime/createSandbox"
    /// Start the sandbox guest without starting a workload.
    case startSandbox = "com.apple.container.runtime/startSandbox"
    /// Present the macOS guest GUI for a running sandbox.
    case showGUI = "com.apple.container.runtime/showGUI"
    /// Bootstrap the sandbox: create the VM, configure networks, and boot the guest.
    case bootstrap = "com.apple.container.runtime/bootstrap"
    /// Stop the sandbox and all processes running inside it.
    case stop = "com.apple.container.runtime/stop"
    /// Return the current state of the sandbox.
    case state = "com.apple.container.runtime/state"
    /// Get resource usage statistics for the sandbox.
    case statistics = "com.apple.container.runtime/statistics"
    /// Open a vsock connection to a port inside the sandbox.
    case dial = "com.apple.container.runtime/dial"

    // MARK: - Workload lifecycle

    /// Create a workload inside an existing sandbox.
    case createWorkload = "com.apple.container.runtime/createWorkload"
    /// Start a workload inside an existing sandbox.
    case startWorkload = "com.apple.container.runtime/startWorkload"
    /// Attach stdio to a running workload.
    case attachWorkload = "com.apple.container.runtime/attachWorkload"
    /// Detach a workload stdio attachment.
    case detachWorkloadAttachment = "com.apple.container.runtime/detachWorkloadAttachment"
    /// Stop a workload inside an existing sandbox.
    case stopWorkload = "com.apple.container.runtime/stopWorkload"
    /// Remove a stopped workload from a sandbox.
    case removeWorkload = "com.apple.container.runtime/removeWorkload"
    /// Inspect a workload inside a sandbox.
    case inspectWorkload = "com.apple.container.runtime/inspectWorkload"

    // MARK: - Process management

    /// Register a new process inside the sandbox (used by exec).
    case createProcess = "com.apple.container.runtime/createProcess"
    /// Start a registered process inside the sandbox.
    case start = "com.apple.container.runtime/start"
    /// Send a signal to a process inside the sandbox.
    case kill = "com.apple.container.runtime/kill"
    /// Resize the PTY of a process inside the sandbox.
    case resize = "com.apple.container.runtime/resize"
    /// Wait for a process inside the sandbox to exit.
    case wait = "com.apple.container.runtime/wait"
    /// Execute a new process in the sandbox.
    case exec = "com.apple.container.runtime/exec"

    // MARK: - File Management

    /// Begin a guest filesystem transaction.
    case fsBegin = "com.apple.container.runtime/fsBegin"
    /// Send a guest filesystem transaction chunk.
    case fsChunk = "com.apple.container.runtime/fsChunk"
    /// Complete a guest filesystem transaction.
    case fsEnd = "com.apple.container.runtime/fsEnd"
    /// Begin reading a path from the guest filesystem.
    case fsReadBegin = "com.apple.container.runtime/fsReadBegin"
    /// Read a chunk from the guest filesystem.
    case fsReadChunk = "com.apple.container.runtime/fsReadChunk"
    /// Complete a guest filesystem read transaction.
    case fsReadEnd = "com.apple.container.runtime/fsReadEnd"
    /// List a directory in the guest filesystem.
    case fsListDir = "com.apple.container.runtime/fsListDir"
    /// Copy a file or directory into the container.
    case copyIn = "com.apple.container.runtime/copyIn"
    /// Copy a file or directory out of the container.
    case copyOut = "com.apple.container.runtime/copyOut"

    // MARK: - Sandbox network management

    /// Prepare and persist sandbox network state.
    case prepareNetwork = "com.apple.container.runtime/prepareNetwork"
    /// Inspect persisted or live sandbox network state.
    case inspectNetwork = "com.apple.container.runtime/inspectNetwork"
    /// Release sandbox network allocations.
    case releaseNetwork = "com.apple.container.runtime/releaseNetwork"
    /// Apply sandbox network policy state.
    case applyNetworkPolicy = "com.apple.container.runtime/applyNetworkPolicy"
    /// Remove sandbox network policy state.
    case removeNetworkPolicy = "com.apple.container.runtime/removeNetworkPolicy"
    /// Inspect sandbox network policy state.
    case inspectNetworkPolicy = "com.apple.container.runtime/inspectNetworkPolicy"
}
