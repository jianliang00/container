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
import ContainerizationOS
import Darwin
import Dispatch
import Foundation
import Testing

@testable import ContainerAPIClient

struct ExecSyncTests {
    @Test
    func capturesStdoutStderrAndStandardInput() async throws {
        let input = Data("hello from stdin".utf8)
        let state = CapturingProcessState()

        let result = try await ExecSyncRunner.run(
            standardInput: input
        ) { stdio in
            let stdin = try #require(stdio[0])
            let stdout = try #require(stdio[1])
            let stderr = try #require(stdio[2])
            let processStdin = try duplicateFileHandle(stdin)
            let processStdout = try duplicateFileHandle(stdout)
            let processStderr = try duplicateFileHandle(stderr)

            return ScriptedProcess(
                id: "exec-sync-capture",
                onStart: {
                    DispatchQueue.global().async {
                        do {
                            defer {
                                try? processStdin.close()
                                try? processStdout.close()
                                try? processStderr.close()
                            }

                            let received = try processStdin.readToEnd() ?? Data()
                            try processStdout.write(contentsOf: received)
                            try processStderr.write(contentsOf: Data("stderr bytes".utf8))
                            state.finish(.success(23))
                        } catch {
                            state.finish(.failure(error))
                        }
                    }
                },
                onWait: {
                    try await state.wait()
                }
            )
        }

        #expect(result.exitCode == 23)
        #expect(result.stdout == input)
        #expect(String(data: result.stderr, encoding: .utf8) == "stderr bytes")
    }

    @Test
    func timeoutKillsProcessWithSigkill() async throws {
        let state = HangingProcessState()
        let process = HangingProcess(id: "exec-sync-timeout", state: state)

        do {
            _ = try await ExecSyncRunner.run(timeout: .milliseconds(20)) { _ in
                process
            }
            Issue.record("expected exec sync timeout to throw")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
        }

        #expect(await state.receivedSignals == [SIGKILL])
    }
}

private final class ScriptedProcess: ClientProcess, @unchecked Sendable {
    let id: String

    private let onStart: @Sendable () throws -> Void
    private let onWait: @Sendable () async throws -> Int32

    init(
        id: String,
        onStart: @escaping @Sendable () throws -> Void,
        onWait: @escaping @Sendable () async throws -> Int32
    ) {
        self.id = id
        self.onStart = onStart
        self.onWait = onWait
    }

    func start() async throws {
        try onStart()
    }

    func resize(_: Terminal.Size) async throws {
    }

    func kill(_: Int32) async throws {
    }

    func wait() async throws -> Int32 {
        try await onWait()
    }
}

private func duplicateFileHandle(_ handle: FileHandle) throws -> FileHandle {
    let duplicatedFD = dup(handle.fileDescriptor)
    guard duplicatedFD >= 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
        )
    }
    return FileHandle(fileDescriptor: duplicatedFD, closeOnDealloc: true)
}

private final class CapturingProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Int32, Error>?
    private var waitContinuation: CheckedContinuation<Result<Int32, Error>, Never>?

    func finish(_ result: Result<Int32, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Result<Int32, Error>, Never>? in
            if let waitContinuation {
                self.waitContinuation = nil
                return waitContinuation
            }

            self.result = result
            return nil
        }

        continuation?.resume(returning: result)
    }

    func wait() async throws -> Int32 {
        if let result = lock.withLock({ self.result }) {
            return try result.get()
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Int32, Error>, Never>) in
            lock.withLock {
                if let result = self.result {
                    continuation.resume(returning: result)
                    return
                }
                waitContinuation = continuation
            }
        }
        return try result.get()
    }
}

private actor HangingProcessState {
    private var signals: [Int32] = []
    private var waitContinuation: CheckedContinuation<Int32, Never>?

    var receivedSignals: [Int32] {
        signals
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func kill(signal: Int32) {
        signals.append(signal)
        waitContinuation?.resume(returning: 137)
        waitContinuation = nil
    }
}

private final class HangingProcess: ClientProcess, @unchecked Sendable {
    let id: String
    private let state: HangingProcessState

    init(id: String, state: HangingProcessState) {
        self.id = id
        self.state = state
    }

    func start() async throws {
    }

    func resize(_: Terminal.Size) async throws {
    }

    func kill(_ signal: Int32) async throws {
        await state.kill(signal: signal)
    }

    func wait() async throws -> Int32 {
        await state.wait()
    }
}

extension NSLock {
    fileprivate func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
