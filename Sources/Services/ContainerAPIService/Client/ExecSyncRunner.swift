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

import ContainerResource
import ContainerizationError
import Darwin
import Dispatch
import Foundation

enum ExecSyncRunner {
    private static let blockingIOQueue = DispatchQueue(
        label: "com.apple.container.exec-sync-runner.blocking-io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func run(
        timeout: Duration? = nil,
        standardInput: Data? = nil,
        createProcess: @escaping @Sendable ([FileHandle?]) async throws -> any ClientProcess
    ) async throws -> ExecSyncResult {
        let stdinPipe = standardInput.map { _ in Pipe() }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let stdinRead = stdinPipe?.fileHandleForReading
        let stdinWrite = stdinPipe?.fileHandleForWriting
        let stdoutRead = stdoutPipe.fileHandleForReading
        let stdoutWrite = stdoutPipe.fileHandleForWriting
        let stderrRead = stderrPipe.fileHandleForReading
        let stderrWrite = stderrPipe.fileHandleForWriting

        let stdoutReader = Task<Data, Error> { try await readToEnd(stdoutRead) }
        let stderrReader = Task<Data, Error> { try await readToEnd(stderrRead) }

        let stdinWriter = standardInput.map { input in
            Task<Void, Never> {
                guard let stdinWrite else {
                    return
                }
                await write(input, to: stdinWrite)
            }
        }

        do {
            let process = try await createProcess([stdinRead, stdoutWrite, stderrWrite])

            do {
                try await process.start()
                try? stdinRead?.close()
                try stdoutWrite.close()
                try stderrWrite.close()

                let exitCode = try await waitForExit(process, timeout: timeout)
                let stdout = try await stdoutReader.value
                let stderr = try await stderrReader.value
                _ = await stdinWriter?.result

                return ExecSyncResult(
                    exitCode: exitCode,
                    stdout: stdout,
                    stderr: stderr
                )
            } catch {
                stdoutReader.cancel()
                stderrReader.cancel()
                _ = await stdinWriter?.result
                _ = try? await stdoutReader.value
                _ = try? await stderrReader.value
                throw error
            }
        } catch {
            try? stdinRead?.close()
            try? stdinWrite?.close()
            try? stdoutWrite.close()
            try? stderrWrite.close()
            stdoutReader.cancel()
            stderrReader.cancel()
            _ = await stdinWriter?.result
            _ = try? await stdoutReader.value
            _ = try? await stderrReader.value
            throw error
        }
    }

    private enum WaitOutcome {
        case exited(Int32)
        case timedOut
    }

    private static func waitForExit(
        _ process: any ClientProcess,
        timeout: Duration?
    ) async throws -> Int32 {
        guard let timeout else {
            return try await process.wait()
        }

        let outcome = try await withThrowingTaskGroup(of: WaitOutcome.self) { group in
            group.addTask {
                .exited(try await process.wait())
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            let outcome = try await group.next()!
            if case .timedOut = outcome {
                try? await process.kill(SIGKILL)
            }
            group.cancelAll()
            return outcome
        }

        switch outcome {
        case .exited(let exitCode):
            return exitCode
        case .timedOut:
            throw ContainerizationError(
                .timeout,
                message: "timed out waiting for exec process \(process.id)"
            )
        }
    }

    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        try await runBlockingIO {
            defer { try? handle.close() }
            return try handle.readToEnd() ?? Data()
        }
    }

    private static func write(_ data: Data, to handle: FileHandle) async {
        await runBlockingIOIgnoringErrors {
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        }
    }

    private static func runBlockingIO<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            blockingIOQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlockingIOIgnoringErrors(
        _ operation: @escaping @Sendable () throws -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            blockingIOQueue.async {
                defer { continuation.resume() }
                _ = try? operation()
            }
        }
    }
}
