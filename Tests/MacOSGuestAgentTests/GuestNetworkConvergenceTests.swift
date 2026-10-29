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
import Testing

@testable import container_macos_guest_agent

struct GuestNetworkConvergenceTests {

    @Test
    func waitsForRoutingPublicationBeyondFiveSeconds() throws {
        var elapsed: TimeInterval = 0
        let result = try GuestSystemNetworkConfigurator.waitForPublishedState(
            now: { elapsed },
            sleep: { elapsed += $0 },
            observe: {
                guard elapsed >= 8.6 else {
                    throw NSError(
                        domain: "GuestNetworkTest", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "active global IPv6 state is missing"
                        ])
                }
                return "routing-ready"
            }
        )
        #expect(result == "routing-ready")
        #expect(elapsed >= 8.6 && elapsed < 9)
    }

    @Test
    func stateConvergenceTimeoutPreservesTheLastMismatch() {
        var elapsed: TimeInterval = 0
        do {
            let _: String = try GuestSystemNetworkConfigurator.waitForPublishedState(
                now: { elapsed },
                sleep: { elapsed += $0 },
                observe: {
                    throw NSError(
                        domain: "GuestNetworkTest", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "active primary IPv6 router mismatch"
                        ])
                }
            )
            Issue.record("a missing route must not become ready")
        } catch {
            #expect(elapsed == 30)
            #expect(error.localizedDescription.contains("active primary IPv6 router mismatch"))
        }
    }

    @Test
    func rejectsNetworkStateObservedAfterTheDeadline() {
        var elapsed: TimeInterval = 0
        var slept = false
        #expect(throws: (any Error).self) {
            let _: String = try GuestSystemNetworkConfigurator.waitForPublishedState(
                now: { elapsed },
                sleep: { _ in slept = true },
                observe: {
                    elapsed = 31
                    return "late-routing"
                }
            )
        }
        #expect(!slept)
    }

    @Test
    func slowFailedObservationDoesNotExtendTheDeadlineWithAnotherSleep() {
        var elapsed: TimeInterval = 0
        var slept = false
        #expect(throws: (any Error).self) {
            let _: String = try GuestSystemNetworkConfigurator.waitForPublishedState(
                now: { elapsed },
                sleep: { _ in slept = true },
                observe: {
                    elapsed = 31
                    throw NSError(domain: "GuestNetworkTest", code: 1)
                }
            )
        }
        #expect(!slept)
    }

    @Test
    func acceptsReadyNetworkStateWithoutSleeping() throws {
        let value = try GuestSystemNetworkConfigurator.waitForPublishedState(
            now: { 0 },
            sleep: { _ in Issue.record("ready state must not wait") },
            observe: { "ready" }
        )
        #expect(value == "ready")
    }
}
#endif
