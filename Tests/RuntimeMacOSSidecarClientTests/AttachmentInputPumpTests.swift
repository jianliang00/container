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

#if os(macOS)
import Darwin
import Foundation
import Testing

@testable import container_runtime_macos

struct AttachmentInputPumpTests {
    @Test(arguments: [false, true])
    func blockedConsumerPreservesBytesAndEOF(stopWhileBlocked: Bool) async throws {
        let input = Pipe()
        defer {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
        }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let sink = InputSink(gate: gate.stream)
        let pump = AttachmentInputPump(
            fileHandle: input.fileHandleForReading,
            forward: { _, data in await sink.receive(data) },
            onFailure: { Issue.record($0) }
        )
        defer { pump.stop() }

        let first = Data(repeating: 65, count: 4096)
        let second = Data(repeating: 66, count: 4096)
        try input.fileHandleForWriting.write(contentsOf: first)
        pump.start()
        try await waitUntil { await sink.events.count == 1 }
        try input.fileHandleForWriting.write(contentsOf: second)
        try input.fileHandleForWriting.close()

        // The first send is suspended. Neither the next chunk nor EOF may be
        // consumed yet; backpressure leaves those bytes in the kernel pipe.
        #expect(input.fileHandleForReading.readabilityHandler == nil)
        var buffered: Int32 = 0
        // Darwin's _IOR('f', 127, int) macro is not imported into Swift.
        let fionread: UInt = 0x4004_667f
        #expect(ioctl(input.fileHandleForReading.fileDescriptor, fionread, &buffered) == 0)
        #expect(buffered == second.count)
        if stopWhileBlocked { pump.stop() }
        gate.continuation.finish()

        if stopWhileBlocked {
            try await waitUntil { await sink.completed == 1 }
            #expect(await sink.events == [first])
            #expect(input.fileHandleForReading.readabilityHandler == nil)
        } else {
            try await waitUntil { await sink.events.last?.isEmpty == true }
            let events = await sink.events
            #expect(events == [first, second, Data()])
            #expect(await sink.maximumConcurrentSends == 1)
        }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw POSIXError(.ETIMEDOUT)
    }
}

private actor InputSink {
    let gate: AsyncStream<Void>
    var events: [Data] = []
    var completed = 0
    var active = 0
    var maximumConcurrentSends = 0

    init(gate: AsyncStream<Void>) { self.gate = gate }

    func receive(_ data: Data) async {
        events.append(data)
        active += 1
        maximumConcurrentSends = max(maximumConcurrentSends, active)
        if events.count == 1 {
            for await _ in gate {}
        }
        active -= 1
        completed += 1
    }
}
#endif
