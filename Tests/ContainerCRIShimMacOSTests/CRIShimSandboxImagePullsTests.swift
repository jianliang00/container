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

import Foundation
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimSandboxImagePullsTests {
    private let image = CRIShimImageRecord(reference: "registry/base:large", digest: "sha256:large", size: 52_000_000_000)

    @Test func requestDeadlineDoesNotCancelDownloadOrDropGCProtection() async throws {
        let pulls = CRIShimSandboxImagePulls()
        let protection = CRIShimImageGCProtection()
        let started = PullTestGate()
        let finish = PullTestGate()
        let image = image
        let first = Task {
            try await pulls.pull(reference: image.reference) {
                try await protection.withProtectedImage(image.reference) {
                    await started.open()
                    await finish.wait()
                    try Task.checkCancellation()
                    return image
                }
            }
        }
        await started.wait()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await protection.references().contains(image.reference))

        let retry = Task {
            try await pulls.pull(reference: image.reference) {
                Issue.record("retry started a duplicate download")
                throw CancellationError()
            }
        }
        try await waitForRequests(1, in: pulls)
        await finish.open()
        #expect(try await retry.value == image)
        #expect(try await protection.references().isEmpty)
    }

    @Test func concurrentRequestsShareDownloadAndCancelIndependently() async throws {
        let pulls = CRIShimSandboxImagePulls()
        let started = PullTestGate()
        let finish = PullTestGate()
        let image = image
        let first = Task {
            try await pulls.pull(reference: image.reference) {
                await started.open()
                await finish.wait()
                return image
            }
        }
        await started.wait()
        let second = Task {
            try await pulls.pull(reference: image.reference) {
                Issue.record("concurrent request started a duplicate download")
                throw CancellationError()
            }
        }
        try await waitForRequests(2, in: pulls)
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await pulls.waitingRequestCount == 1)
        let other = try await pulls.pull(reference: "registry/other:latest") { image }
        #expect(other == image)
        await finish.open()
        #expect(try await first.value == image)
    }

    @Test func failedDownloadCanBeRetried() async throws {
        let pulls = CRIShimSandboxImagePulls()
        await #expect(throws: CRIShimError.self) {
            try await pulls.pull(reference: image.reference) {
                throw CRIShimError.unavailable("registry failed")
            }
        }
        #expect(try await pulls.pull(reference: image.reference) { image } == image)
    }

    @Test func nodeTimeoutCancelsDownloadAndRetainsOwnershipDuringCleanup() async throws {
        let pulls = CRIShimSandboxImagePulls(timeout: .milliseconds(30))
        let cleaning = PullTestGate()
        let cleanup = PullTestGate()
        let image = image
        let first = Task {
            try await pulls.pull(reference: image.reference) {
                do {
                    try await Task.sleep(for: .seconds(60))
                    return image
                } catch {
                    await cleaning.open()
                    await cleanup.wait()
                    throw error
                }
            }
        }
        await cleaning.wait()
        let retry = Task {
            try await pulls.pull(reference: image.reference) {
                Issue.record("retry overlapped download cleanup")
                return image
            }
        }
        try await waitForRequests(2, in: pulls)
        await cleanup.open()
        await #expect(throws: CRIShimError.self) { try await first.value }
        await #expect(throws: CRIShimError.self) { try await retry.value }
        #expect(try await pulls.pull(reference: image.reference) { image } == image)
    }

    private func waitForRequests(_ count: Int, in pulls: CRIShimSandboxImagePulls) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await pulls.waitingRequestCount != count {
            try #require(ContinuousClock.now < deadline, "requests did not join the shared pull")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor PullTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
