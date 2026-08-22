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

@testable import ContainerXPC

struct XPCClientCompletionStateTests {
    @Test func fastResponseCancelsTimeoutInstalledAfterCompletion() async {
        let state = XPCClientCompletionState()
        let cancellation = LockedBool()

        #expect(state.complete())

        let timeoutTask = cancellationProbe(cancellation)
        state.installTimeoutTask(timeoutTask)
        await timeoutTask.value

        #expect(cancellation.value)
        #expect(!state.complete())
    }

    @Test func responseCancelsInstalledTimeout() async {
        let state = XPCClientCompletionState()
        let cancellation = LockedBool()
        let timeoutTask = cancellationProbe(cancellation)

        state.installTimeoutTask(timeoutTask)
        #expect(state.complete())
        await timeoutTask.value

        #expect(cancellation.value)
        #expect(!state.complete())
    }

    @Test func timeoutCompletesOnlyOnce() async {
        let state = XPCClientCompletionState()
        let timeoutWon = LockedBool()
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return
            }
            timeoutWon.value = state.complete()
        }

        state.installTimeoutTask(timeoutTask)
        await timeoutTask.value

        #expect(timeoutWon.value)
        #expect(!state.complete())
    }
}

private func cancellationProbe(_ observation: LockedBool) -> Task<Void, Never> {
    Task {
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            observation.value = Task.isCancelled
        }
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.withLock { storage }
        }
        set {
            lock.withLock { storage = newValue }
        }
    }
}
#endif
