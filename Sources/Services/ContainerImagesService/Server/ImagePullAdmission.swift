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

/// Keep a cancelled pull's reservation until its download and ingest cleanup exit.
/// A retry must not create another download while that work is still active.
actor ImagePullAdmission {
    private var activeReferences: Set<String> = []

    func withPull<Value: Sendable>(
        reference: String,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard activeReferences.insert(reference).inserted else {
            throw ContainerizationError(
                .exists,
                message: "image pull already in progress for \(reference); retry after it completes"
            )
        }
        defer { activeReferences.remove(reference) }
        return try await operation()
    }
}
