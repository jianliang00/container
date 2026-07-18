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

public enum RuntimeKeys: String {
    /// ID key.
    case id
    case attachmentIdentifier
    /// Vsock port number key.
    case port
    /// Exit code for a process
    case exitCode
    /// Exit timestamp for a process
    case exitedAt
    /// FD to a container resource key.
    case fd
    /// Options for stopping a container key.
    case stopOptions
    /// Whether a macOS guest GUI window should be presented during startup.
    case presentGUI
    /// Legacy endpoint key used by the macOS runtime before runtime service unification.
    case sandboxServiceEndpoint
    /// An endpoint for sending progress updates back to a client.
    case progressUpdateEndpoint
    /// An endpoint to talk to the runtime service.
    case runtimeServiceEndpoint

    /// Process request keys.
    case signal
    case snapshot
    case stdin
    case stdout
    case stderr
    case width
    case height
    case processConfig
    case workloadConfig
    case attachOptions

    /// Filesystem request payload.
    case fsPayload

    /// Container statistics
    case statistics

    /// Sandbox network state payload.
    case networkState
    /// Sandbox network policy request payload.
    case networkPolicy
    /// Sandbox network policy state payload.
    case networkPolicyState
    /// Workload snapshot payload.
    case workloadSnapshot

    /// Copy parameters
    case sourcePath
    case destinationPath
    case fileMode
    case createParents

    /// Special-case environment variables recomputed on each container start
    case dynamicEnv

    /// Per-network connection info passed to the runtime so it can allocate directly.
    case networkBootstrapInfos
}
