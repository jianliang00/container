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

import ContainerizationOS
import Foundation
import Testing

@testable import ContainerAPIClient

struct ProcessIOStartupNoticeTests {
    @Test("Slow process start emits a delayed startup notice")
    func slowProcessStartEmitsStartupNotice() async throws {
        let process = DelayedStartProcess(startDelayNanoseconds: 500_000_000)
        let recorder = StartupNoticeRecorder()

        try await ProcessIO.startProcess(
            process: process,
            startupMessage: "Waiting for macOS guest...",
            startupDelayNanoseconds: 50_000_000,
            startupWriter: { recorder.record($0) }
        )

        #expect(recorder.messages == ["Waiting for macOS guest..."])
    }

    @Test("Fast process start does not emit a delayed startup notice")
    func fastProcessStartDoesNotEmitStartupNotice() async throws {
        let process = DelayedStartProcess(startDelayNanoseconds: 5_000_000)
        let recorder = StartupNoticeRecorder()

        try await ProcessIO.startProcess(
            process: process,
            startupMessage: "Waiting for macOS guest...",
            startupDelayNanoseconds: 2_000_000_000,
            startupWriter: { recorder.record($0) }
        )

        #expect(recorder.messages.isEmpty)
    }

    @Test("Missing startup notice text skips delayed notice")
    func nilStartupMessageSkipsNotice() async throws {
        let process = DelayedStartProcess(startDelayNanoseconds: 150_000_000)
        let recorder = StartupNoticeRecorder()

        try await ProcessIO.startProcess(
            process: process,
            startupMessage: nil,
            startupDelayNanoseconds: 20_000_000,
            startupWriter: { recorder.record($0) }
        )

        #expect(recorder.messages.isEmpty)
    }
}

extension ProcessIOStartupNoticeTests {
    private struct DelayedStartProcess: ClientProcess {
        let id = UUID().uuidString
        let startDelayNanoseconds: UInt64

        func start() async throws {
            try await Task.sleep(nanoseconds: startDelayNanoseconds)
        }

        func resize(_ size: Terminal.Size) async throws {
        }

        func kill(_ signal: Int32) async throws {
        }

        func wait() async throws -> Int32 {
            0
        }
    }

    private final class StartupNoticeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var messages: [String] {
            lock.withLock {
                storage
            }
        }

        func record(_ message: String) {
            lock.withLock {
                storage.append(message)
            }
        }
    }
}
