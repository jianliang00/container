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

struct GuestAgentBootstrapRetrierTests {
    @Test
    func retriesUntilOperationSucceeds() async throws {
        let counter = AttemptCounter()

        try await GuestAgentBootstrapRetrier.run(
            maxAttempts: 5,
            retryDelayNanoseconds: 0
        ) { attempt, maxAttempts in
            #expect(maxAttempts == 5)
            let current = await counter.record()
            #expect(current == attempt)
            if current < 3 {
                throw ProbeError.notReady(current)
            }
        }

        #expect(await counter.value() == 3)
    }

    @Test
    func throwsLastErrorAfterMaxAttempts() async throws {
        let counter = AttemptCounter()

        do {
            try await GuestAgentBootstrapRetrier.run(
                maxAttempts: 3,
                retryDelayNanoseconds: 0
            ) { _, _ in
                let current = await counter.record()
                throw ProbeError.notReady(current)
            }
            Issue.record("expected GuestAgentBootstrapRetrier to throw")
        } catch let error as ProbeError {
            #expect(error == .notReady(3))
        }

        #expect(await counter.value() == 3)
    }
}

extension GuestAgentBootstrapRetrierTests {
    private actor AttemptCounter {
        private var attempts = 0

        func record() -> Int {
            attempts += 1
            return attempts
        }

        func value() -> Int {
            attempts
        }
    }

    private enum ProbeError: Error, Equatable {
        case notReady(Int)
    }
}
#endif
