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

import RuntimeMacOSSidecarShared

enum MacOSSandboxStopSequence {
    static func run(
        lifecycleState: MacOSVMRuntimeState?,
        isolation: isolated (any Actor)? = #isolation,
        stopGuest: () async -> Void,
        stopVirtualMachine: () async throws -> Void
    ) async rethrows {
        // A paused guest cannot process signals or filesystem requests. Do not
        // resume it just to stop it: that would execute guest work after a checkpoint.
        if lifecycleState != .paused && lifecycleState != .stopped {
            await stopGuest()
        }
        // Callers may release runtime resources only after this verifies VM exit.
        try await stopVirtualMachine()
    }
}
