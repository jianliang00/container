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

public enum SandboxRoutes: String {
    /// Create an xpc endpoint to the sandbox instance.
    case createEndpoint = "com.apple.container.sandbox/createEndpoint"
    /// Bootstrap the sandbox instance and create the init process.
    case bootstrap = "com.apple.container.sandbox/bootstrap"
    /// Create a process in the sandbox.
    case createProcess = "com.apple.container.sandbox/createProcess"
    /// Start a process in the sandbox.
    case start = "com.apple.container.sandbox/start"
    /// Stop the sandbox.
    case stop = "com.apple.container.sandbox/stop"
    /// Return the current state of the sandbox.
    case state = "com.apple.container.sandbox/state"
    /// Kill a process in the sandbox.
    case kill = "com.apple.container.sandbox/kill"
    /// Resize the pty of a process in the sandbox.
    case resize = "com.apple.container.sandbox/resize"
    /// Wait on a process in the sandbox.
    case wait = "com.apple.container.sandbox/wait"
    /// Execute a new process in the sandbox.
    case exec = "com.apple.container.sandbox/exec"
    /// Dial a vsock port in the sandbox.
    case dial = "com.apple.container.sandbox/dial"
    /// Begin a filesystem transaction in the sandbox guest.
    case fsBegin = "com.apple.container.sandbox/fsBegin"
    /// Send a filesystem data chunk to the sandbox guest.
    case fsChunk = "com.apple.container.sandbox/fsChunk"
    /// End a filesystem transaction in the sandbox guest.
    case fsEnd = "com.apple.container.sandbox/fsEnd"
    /// Shutdown the sandbox service process.
    case shutdown = "com.apple.container.sandbox/shutdown"
    /// Get statistics for the sandbox.
    case statistics = "com.apple.container.sandbox/statistics"
    /// Prepare sandbox networking and persist the lease-backed state.
    case prepareNetwork = "com.apple.container.sandbox/prepareNetwork"
    /// Inspect sandbox networking from persisted or live state.
    case inspectNetwork = "com.apple.container.sandbox/inspectNetwork"
    /// Release sandbox networking and remove persisted lease state.
    case releaseNetwork = "com.apple.container.sandbox/releaseNetwork"
}
