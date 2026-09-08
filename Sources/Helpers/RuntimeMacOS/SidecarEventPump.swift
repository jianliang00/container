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

import Foundation
import RuntimeMacOSSidecarShared

/// Only wakeups use AsyncStream's buffer. Output is bounded per process, and an
/// exit has a reserved slot so a slow runtime actor cannot lose terminal state.
final class SidecarEventPump: @unchecked Sendable {
    struct Events: AsyncSequence {
        typealias Element = MacOSSidecarEvent
        let pump: SidecarEventPump

        struct AsyncIterator: AsyncIteratorProtocol {
            let pump: SidecarEventPump
            var wakeups: AsyncStream<Void>.Iterator

            mutating func next() async -> MacOSSidecarEvent? {
                guard !Task.isCancelled else { return nil }
                if let event = pump.pop() { return event }
                while await wakeups.next() != nil {
                    if let event = pump.pop() { return event }
                }
                return pump.pop()
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(pump: pump, wakeups: pump.wakeups.makeAsyncIterator())
        }
    }

    var stream: Events { Events(pump: self) }
    private let wakeups: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private let capacity: Int
    private var buffers: [String: BoundedOutputBuffer<MacOSSidecarEvent>] = [:]
    private var order: [String] = []
    private var finished = false

    init(capacity: Int = 4 * 1024 * 1024) {
        self.capacity = capacity
        (wakeups, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func yield(_ event: MacOSSidecarEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let processID = event.processID
        let buffer: BoundedOutputBuffer<MacOSSidecarEvent>
        if let existing = buffers[processID] {
            buffer = existing
        } else {
            buffer = BoundedOutputBuffer(capacity: capacity) { count in
                .init(event: .processStderr, processID: processID, data: Data("\n[container: runtime output truncated; discarded \(count) bytes]\n".utf8))
            }
            buffers[processID] = buffer
            order.append(processID)
        }
        if event.event == .processExit {
            buffer.finish(with: event)
        } else {
            buffer.append(event, bytes: event.data?.count ?? event.message?.utf8.count ?? 1)
        }
        continuation.yield(())
    }

    func finish() {
        lock.lock()
        finished = true
        continuation.finish()
        lock.unlock()
    }

    private func pop() -> MacOSSidecarEvent? {
        lock.lock()
        defer { lock.unlock() }
        while !order.isEmpty {
            let processID = order.removeFirst()
            guard let buffer = buffers[processID], let event = buffer.pop() else {
                buffers.removeValue(forKey: processID)
                continue
            }
            if event.event == .processExit {
                buffers.removeValue(forKey: processID)
            } else {
                order.append(processID)
            }
            return event
        }
        return nil
    }
}
