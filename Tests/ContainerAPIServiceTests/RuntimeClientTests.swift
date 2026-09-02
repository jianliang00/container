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
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIService
@testable import ContainerRuntimeClient
@testable import ContainerXPC

struct RuntimeClientTests {
    @Test
    func stopWorkloadResponseTimeoutCoversGracefulAndForcedWaits() {
        #expect(
            RuntimeClient.stopWorkloadResponseTimeout(
                options: ContainerStopOptions(timeoutInSeconds: 30, signal: "SIGTERM")
            ) == .seconds(65)
        )
        #expect(
            RuntimeClient.stopWorkloadResponseTimeout(
                options: ContainerStopOptions(timeoutInSeconds: 0, signal: "SIGKILL")
            ) == .seconds(7)
        )
        #expect(
            RuntimeClient.stopWorkloadResponseTimeout(
                options: ContainerStopOptions(timeoutInSeconds: .max, signal: "SIGTERM")
            ) == .seconds(4_294_967_299)
        )
    }

    @Test
    func xpcWaitReturnsWhenReplyNeverArrives() async {
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await XPCClient.awaitReply(
                responseTimeout: .milliseconds(20),
                service: "test.runtime",
                route: "wait"
            ) { _ in
                // Intentionally leave the request unanswered.
            }
            Issue.record("expected the unanswered request to time out")
        } catch {
            // The timeout callback can be delayed by the test runner's shared
            // cooperative executor when the full suite runs concurrently.
            #expect(clock.now - startedAt < .seconds(30))
        }
    }

    @Test
    func killedInitWaitUsesBoundedTimeout() {
        #expect(ContainersService.killedInitExitWaitTimeout == .seconds(5))
    }

    @Test
    func stopPreservesInterruptedTransportError() {
        let transportError = ContainerizationError(
            .interrupted,
            message: "runtime exited before replying"
        )

        let mapped = RuntimeClient.mapStopError(transportError, id: "test-container")

        #expect(mapped.code == .interrupted)
        #expect(mapped.message == transportError.message)
        #expect(mapped.cause == nil)
    }

    @Test
    func stopWrapsNonInterruptedErrorWithContainerContext() throws {
        let transportError = ContainerizationError(
            .timeout,
            message: "runtime did not reply"
        )

        let mapped = RuntimeClient.mapStopError(transportError, id: "test-container")

        #expect(mapped.code == .internalError)
        #expect(mapped.message == "failed to stop container test-container")
        let cause = try #require(mapped.cause as? ContainerizationError)
        #expect(cause.code == .timeout)
        #expect(cause.message == transportError.message)
    }
}
