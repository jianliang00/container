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

import Containerization
import ContainerizationError
import Foundation
import Testing

@testable import ContainerRuntimeClient

struct ExitMonitorTests {
    actor Recorder {
        var waits = 0
        var exits: [Int32] = []
        var failures = 0

        func wait() throws -> Containerization.ExitStatus {
            waits += 1
            if waits == 1 {
                throw ContainerizationError(.interrupted, message: "XPC interrupted")
            }
            return Containerization.ExitStatus(exitCode: 17)
        }

        func failWait() throws -> Containerization.ExitStatus {
            waits += 1
            throw ContainerizationError(.interrupted, message: "XPC interrupted")
        }

        func exited(_ status: Containerization.ExitStatus) {
            exits.append(status.exitCode)
        }

        func failed() {
            failures += 1
        }

        func exitFailingOnce(_ status: Containerization.ExitStatus) throws {
            exits.append(status.exitCode)
            if exits.count == 1 {
                throw ContainerizationError(.timeout, message: "cleanup failed")
            }
        }
    }

    @Test
    func waitErrorIsRetriedWithoutInventingExit() async throws {
        let recorder = Recorder()
        let monitor = ExitMonitor()
        try await monitor.registerProcess(
            id: "sandbox",
            onExit: { _, status in await recorder.exited(status) }
        )
        try await monitor.track(
            id: "sandbox",
            waitingOn: { try await recorder.wait() },
            onWaitFailure: { _ in
                await recorder.failed()
                return nil
            }
        )
        for _ in 0..<100 {
            if await recorder.exits == [17] { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await recorder.exits == [17])
        #expect(await recorder.failures == 1)
        await monitor.stopTracking(id: "sandbox")
    }

    @Test
    func waitErrorWithoutRecoveryPreservesTerminalFallback() async throws {
        let recorder = Recorder()
        let monitor = ExitMonitor()
        try await monitor.registerProcess(
            id: "sandbox",
            onExit: { _, status in await recorder.exited(status) }
        )
        try await monitor.track(
            id: "sandbox",
            waitingOn: { try await recorder.failWait() }
        )
        for _ in 0..<20 {
            if await recorder.exits == [-1] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.exits == [-1])
        #expect(await recorder.waits == 1)
        await monitor.stopTracking(id: "sandbox")
    }

    @Test
    func waitRecoveryCanProvideAnIndependentlyConfirmedExit() async throws {
        let recorder = Recorder()
        let monitor = ExitMonitor()
        try await monitor.registerProcess(
            id: "sandbox",
            onExit: { _, status in await recorder.exited(status) }
        )
        try await monitor.track(
            id: "sandbox",
            waitingOn: { try await recorder.failWait() },
            onWaitFailure: { _ in
                await recorder.failed()
                return Containerization.ExitStatus(exitCode: 255)
            }
        )
        for _ in 0..<20 {
            if await recorder.exits == [255] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.exits == [255])
        #expect(await recorder.waits == 1)
        #expect(await recorder.failures == 1)
        await monitor.stopTracking(id: "sandbox")
    }

    @Test
    func cleanupFailureRetriesTheConfirmedExitStatus() async throws {
        let recorder = Recorder()
        let monitor = ExitMonitor()
        try await monitor.registerProcess(
            id: "sandbox",
            onExit: { _, status in try await recorder.exitFailingOnce(status) }
        )
        try await monitor.track(
            id: "sandbox",
            waitingOn: { Containerization.ExitStatus(exitCode: 17) }
        )
        for _ in 0..<100 {
            if await recorder.exits.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await recorder.exits == [17, 17])
        await monitor.stopTracking(id: "sandbox")
    }

    @Test
    func cancellationDoesNotTriggerExitOrRecovery() async throws {
        let recorder = Recorder()
        let monitor = ExitMonitor()
        try await monitor.registerProcess(
            id: "sandbox",
            onExit: { _, status in await recorder.exited(status) }
        )
        try await monitor.track(
            id: "sandbox",
            waitingOn: {
                try await Task.sleep(for: .seconds(30))
                return Containerization.ExitStatus(exitCode: 0)
            },
            onWaitFailure: { _ in
                await recorder.failed()
                return nil
            }
        )
        await monitor.stopTracking(id: "sandbox")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.exits.isEmpty)
        #expect(await recorder.failures == 0)
    }
}
