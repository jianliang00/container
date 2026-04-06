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

import NIO

func withEventLoopGroup<R>(
    numberOfThreads: Int = System.coreCount,
    _ body: (MultiThreadedEventLoopGroup) async throws -> R
) async throws -> R {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)
    let result: Result<R, Error>

    do {
        result = .success(try await body(eventLoopGroup))
    } catch {
        result = .failure(error)
    }

    do {
        try await eventLoopGroup.shutdownGracefully()
    } catch {
        if case .success = result {
            throw error
        }
    }

    return try result.get()
}
