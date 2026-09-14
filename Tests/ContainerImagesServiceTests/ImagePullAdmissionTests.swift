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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerImagesService

struct ImagePullAdmissionTests {
    @Test func concurrentRetriesCannotStartAnotherPull() async throws {
        let admission = ImagePullAdmission()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let first = Task {
            try await admission.withPull(reference: "registry/base:latest") {
                started.continuation.yield(())
                for await _ in release.stream { break }
                return 1
            }
        }
        for await _ in started.stream { break }
        await #expect(throws: ContainerizationError.self) {
            try await admission.withPull(reference: "registry/base:latest") { 2 }
        }
        #expect(try await admission.withPull(reference: "registry/other:latest") { 3 } == 3)
        release.continuation.yield(())
        #expect(try await first.value == 1)
        #expect(try await admission.withPull(reference: "registry/base:latest") { 4 } == 4)
    }

    @Test func cancellationKeepsReservationUntilCleanupExits() async throws {
        let admission = ImagePullAdmission()
        let started = AsyncStream<Void>.makeStream()
        let cleaning = AsyncStream<Void>.makeStream()
        let cleanup = CleanupGate()
        let first = Task {
            try await admission.withPull(reference: "registry/base:latest") {
                started.continuation.yield(())
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    cleaning.continuation.yield(())
                    await cleanup.wait()
                    throw error
                }
            }
        }
        for await _ in started.stream { break }
        first.cancel()
        for await _ in cleaning.stream { break }
        await #expect(throws: ContainerizationError.self) {
            try await admission.withPull(reference: "registry/base:latest") { () }
        }
        await cleanup.finish()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await admission.withPull(reference: "registry/base:latest") { 7 } == 7)
    }

    @Test func failedPullAllowsRetry() async throws {
        let admission = ImagePullAdmission()
        await #expect(throws: CancellationError.self) {
            try await admission.withPull(reference: "registry/base:latest") {
                throw CancellationError()
            }
        }
        #expect(try await admission.withPull(reference: "registry/base:latest") { 1 } == 1)
    }
}

private actor CleanupGate {
    private var completed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if completed { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        completed = true
        continuation?.resume()
        continuation = nil
    }
}
