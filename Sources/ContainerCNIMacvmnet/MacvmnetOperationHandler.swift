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

public struct MacvmnetOperationHandler<Backend: MacvmnetBackend>: Sendable {
    public var backend: Backend

    public init(backend: Backend) {
        self.backend = backend
    }

    @discardableResult
    public func handle(_ request: CNIRequest) async throws -> CNIResult? {
        let plan = MacvmnetOperationPlan(request: request)

        switch plan.command {
        case .add:
            return try await backend.prepare(plan)
        case .check:
            try requirePreviousResult(plan)
            try await backend.inspect(plan)
            return nil
        case .delete:
            try await backend.release(plan)
            return nil
        case .status:
            try await backend.health(networkName: plan.networkName)
            return nil
        case .garbageCollect:
            try await backend.garbageCollect(plan)
            return nil
        case .version:
            return nil
        }
    }

    private func requirePreviousResult(_ plan: MacvmnetOperationPlan) throws {
        guard plan.previousResult != nil else {
            throw CNIError.invalidConfiguration("CHECK requires prevResult")
        }
    }
}
