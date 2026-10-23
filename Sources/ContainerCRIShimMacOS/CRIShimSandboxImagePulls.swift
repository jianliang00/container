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

/// A sandbox image download belongs to the node, not an individual CRI request.
/// Keep one pull per reference across kubelet deadlines, but let each caller stop
/// waiting promptly. Completed pulls are not cached here; the image store owns them.
actor CRIShimSandboxImagePulls {
    private typealias Waiter = CheckedContinuation<CRIShimImageRecord, any Error>
    private var pulls: [String: [UUID: Waiter]] = [:]
    private let timeout: Duration

    var waitingRequestCount: Int { pulls.values.reduce(0) { $0 + $1.count } }

    init(timeout: Duration = .seconds(30 * 60)) {
        self.timeout = timeout
    }

    func pull(
        reference: String,
        operation: @escaping @Sendable () async throws -> CRIShimImageRecord
    ) async throws -> CRIShimImageRecord {
        let waiterID = UUID()
        let image = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if pulls[reference] != nil {
                    pulls[reference]?[waiterID] = continuation
                    return
                }
                pulls[reference] = [waiterID: continuation]
                // This unstructured task deliberately outlives cancelled callers.
                Task {
                    let result: Result<CRIShimImageRecord, any Error>
                    do {
                        let image = try await Self.download(timeout: timeout, operation: operation)
                        result = .success(image)
                    } catch {
                        result = .failure(error)
                    }
                    let waiters = pulls.removeValue(forKey: reference) ?? [:]
                    for waiter in waiters.values { waiter.resume(with: result) }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(reference: reference, id: waiterID) }
        }
        // Completion and request cancellation can race. Never provision a VM for
        // a request that was cancelled while its image finished downloading.
        try Task.checkCancellation()
        return image
    }

    private func cancelWaiter(reference: String, id: UUID) {
        pulls[reference]?.removeValue(forKey: id)?.resume(throwing: CancellationError())
        // Keep the empty entry until download and cleanup finish so a retry joins it.
    }

    private static func download(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> CRIShimImageRecord
    ) async throws -> CRIShimImageRecord {
        try await withThrowingTaskGroup(of: CRIShimImageRecord.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CRIShimError.unavailable("sandbox image download exceeded the node pull timeout")
            }
            defer { group.cancelAll() }
            // Structured cleanup retains ownership until the cancelled download exits.
            return try await group.next()!
        }
    }
}
