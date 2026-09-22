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
import Testing

@testable import container_runtime_macos_sidecar

struct MacOSGuestColdBootStageTests {
    @Test
    func guestReadinessPrecedesNetworkActivation() throws {
        let stages = MacOSGuestColdBootStage.orderedStages
        let guestReady = try #require(stages.firstIndex(of: .guestAgentReady))
        let networkActivation = try #require(stages.firstIndex(of: .networksActivated))

        #expect(guestReady < networkActivation)
        #expect(
            stages == [
                .socketDeviceAvailable,
                .guestAgentReady,
                .networksActivated,
                .guestClockSynchronized,
                .guestNetworkingConfigured,
                .networkAttachmentsValidated,
            ])
    }
}
#endif
