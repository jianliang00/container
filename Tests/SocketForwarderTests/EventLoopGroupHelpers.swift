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

import Darwin
import NIO

@testable import SocketForwarder

struct SocketTaskResult<T: Sendable>: @unchecked Sendable {
    let result: Result<T, Error>
}

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

func withForwarderCleanup<R>(
    serverChannel: any Channel,
    forwarderResult: SocketForwarderResult,
    _ body: () async throws -> R
) async throws -> R {
    let result: Result<R, Error>

    do {
        result = .success(try await body())
    } catch {
        result = .failure(error)
    }

    do {
        try await closeForwarder(serverChannel: serverChannel, forwarderResult: forwarderResult)
    } catch {
        if case .success = result {
            throw error
        }
    }

    return try result.get()
}

func collectThrowingTasks<T: Sendable>(
    count: Int,
    maxConcurrentTasks: Int,
    _ operation: @escaping @Sendable (Int) async throws -> T
) async throws -> [T] {
    precondition(maxConcurrentTasks > 0)

    return try await withThrowingTaskGroup(of: T.self) { group in
        var nextIndex = 0
        let initialTaskCount = min(count, maxConcurrentTasks)

        for _ in 0..<initialTaskCount {
            let index = nextIndex
            nextIndex += 1
            group.addTask {
                try await operation(index)
            }
        }

        var results: [T] = []
        while let result = try await group.next() {
            results.append(result)

            if nextIndex < count {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    try await operation(index)
                }
            }
        }

        return results
    }
}

func collectTaskResults<T: Sendable>(
    count: Int,
    maxConcurrentTasks: Int,
    _ operation: @escaping @Sendable (Int) async throws -> T
) async -> [SocketTaskResult<T>] {
    precondition(maxConcurrentTasks > 0)

    return await withTaskGroup(of: SocketTaskResult<T>.self) { group in
        var nextIndex = 0
        let initialTaskCount = min(count, maxConcurrentTasks)

        for _ in 0..<initialTaskCount {
            let index = nextIndex
            nextIndex += 1
            group.addTask {
                do {
                    return SocketTaskResult(result: .success(try await operation(index)))
                } catch {
                    return SocketTaskResult(result: .failure(error))
                }
            }
        }

        var results: [SocketTaskResult<T>] = []
        while let result = await group.next() {
            results.append(result)

            if nextIndex < count {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    do {
                        return SocketTaskResult(result: .success(try await operation(index)))
                    } catch {
                        return SocketTaskResult(result: .failure(error))
                    }
                }
            }
        }

        return results
    }
}

func runThrowingTasks(
    count: Int,
    maxConcurrentTasks: Int,
    _ operation: @escaping @Sendable (Int) async throws -> Void
) async throws {
    _ = try await collectThrowingTasks(count: count, maxConcurrentTasks: maxConcurrentTasks) { index in
        try await operation(index)
        return ()
    }
}

func retryTransientSocketError<T>(
    maxAttempts: Int = 5,
    baseDelayNanoseconds: UInt64 = 50_000_000,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    precondition(maxAttempts > 0)

    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch {
            attempt += 1
            guard attempt < maxAttempts, isTransientSocketError(error) else {
                throw error
            }

            try await Task.sleep(nanoseconds: baseDelayNanoseconds * UInt64(attempt))
        }
    }
}

private func closeForwarder(
    serverChannel: any Channel,
    forwarderResult: SocketForwarderResult
) async throws {
    serverChannel.eventLoop.execute {
        _ = serverChannel.close(mode: .all)
    }
    try await serverChannel.closeFuture.get()
    try await waitForEventLoopQuiescence(on: serverChannel.eventLoop)

    forwarderResult.close()
    try await forwarderResult.wait()
}

private func waitForEventLoopQuiescence(on eventLoop: any EventLoop) async throws {
    try await eventLoop.submit {}.get()
}

private func isTransientSocketError(_ error: Error) -> Bool {
    guard let ioError = error as? IOError else {
        return false
    }

    switch ioError.errnoCode {
    case EADDRNOTAVAIL, ECONNRESET:
        return true
    default:
        return false
    }
}
