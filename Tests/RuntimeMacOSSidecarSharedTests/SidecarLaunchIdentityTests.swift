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
import Testing

@Suite
struct SidecarLaunchIdentityTests {
    @Test
    func machineStateIdentityIsStableAcrossSandboxRecreation() {
        #expect(
            MacOSSidecarLaunchIdentity.fullLaunchLabel(
                sandboxID: "sandbox-a",
                persistenceID: "workload-42",
                effectiveUserID: 0
            ) == "user/0/com.apple.container.runtime.container-runtime-macos-sidecar.state.workload-42"
        )
        #expect(
            MacOSSidecarLaunchIdentity.fullLaunchLabel(
                sandboxID: "sandbox-b",
                persistenceID: "workload-42",
                effectiveUserID: 501
            ) == "gui/501/com.apple.container.runtime.container-runtime-macos-sidecar.state.workload-42"
        )
    }

    @Test
    func ordinaryIdentityRemainsSandboxScoped() {
        #expect(
            MacOSSidecarLaunchIdentity.launchLabel(
                sandboxID: "sandbox-a",
                persistenceID: nil
            ) == "com.apple.container.runtime.container-runtime-macos-sidecar.sandbox-a"
        )
    }
}
