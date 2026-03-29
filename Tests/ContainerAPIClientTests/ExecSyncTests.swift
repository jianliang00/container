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
import Foundation
import Testing

@testable import ContainerAPIClient

struct ExecSyncTests {
    @Test
    func capturesStdoutStderrAndStandardInput() async throws {
        let input = Data("hello from stdin".utf8)

        let result = try await ExecSyncRunner.run(
            standardInput: input
        ) { stdio in
            let stdin = try #require(stdio[0])
            let stdout = try #require(stdio[1])
            let stderr = try #require(stdio[2])

            return ScriptedProcess(
                id: "exec-sync-capture",
                onStart: {
                    let received = try stdin.readToEnd() ?? Data()
                    try stdout.write(contentsOf: received)
                    try stderr.write(contentsOf: Data("stderr bytes".utf8))
                },
                onWait: {
                    23
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
