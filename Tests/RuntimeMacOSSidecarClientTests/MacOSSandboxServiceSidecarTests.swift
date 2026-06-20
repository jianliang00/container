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

#if os(macOS)
import Foundation
import Logging
import Testing

@testable import container_runtime_macos

struct MacOSSandboxServiceSidecarTests {
    @Test
    func sidecarLaunchdDomainUsesRootBootstrapDomainForRoot() {
        let service = MacOSSandboxService(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-domain-test"),
            connection: nil,
            log: Logger(label: "MacOSSandboxServiceSidecarTests")
        )

        #expect(service.sidecarLaunchdDomain(uid: 0) == "user/0")
        #expect(service.sidecarLaunchdDomain(uid: 501) == "gui/501")
    }

    @Test
    func sidecarLaunchAgentSessionOptionsSupportRootBootstrap() {
        let service = MacOSSandboxService(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-session-options-test"),
            connection: nil,
            log: Logger(label: "MacOSSandboxServiceSidecarTests")
        )

        let rootOptions = service.sidecarLaunchAgentSessionOptions(uid: 0)
        #expect(rootOptions["LimitLoadToSessionType"] as? [String] == ["Aqua", "Background", "System"])
        #expect(rootOptions["ProcessType"] == nil)

        let userOptions = service.sidecarLaunchAgentSessionOptions(uid: 501)
        #expect(userOptions["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(userOptions["ProcessType"] as? String == "Interactive")
    }
}
#endif
