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

/// A bounded, lossy output queue with a reserved terminal record. Producers never
/// wait for a reader; truncation is reported after the last retained output.
public final class BoundedOutputBuffer<Element: Sendable>: @unchecked Sendable {
    private struct Entry {
        let value: Element
        let bytes: Int
    }

    private let condition = NSCondition()
    private let capacity: Int
    private let makeTruncation: @Sendable (Int) -> Element
    private var entries: [Entry] = []
    private var bufferedBytes = 0
    private var droppedBytes = 0
    private var terminal: Element?
    private var drainDeadline: DispatchTime?
    private var finished = false
    private var cancelled = false

    public init(capacity: Int = 4 * 1024 * 1024, makeTruncation: @escaping @Sendable (Int) -> Element) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.makeTruncation = makeTruncation
    }

    public func append(_ value: Element, bytes: Int) {
        condition.lock()
        defer { condition.unlock() }
        guard !finished, !cancelled else { return }
        let cost = max(1, bytes)
        // Stop accepting output until the gap marker is consumed, preserving its
        // position relative to retained output even when the reader recovers.
        if droppedBytes > 0 || cost > capacity - bufferedBytes || entries.count >= 1024 {
            droppedBytes += cost
        } else {
            entries.append(Entry(value: value, bytes: cost))
            bufferedBytes += cost
        }
        condition.signal()
    }

    public func finish(with terminal: Element, drainTimeout: TimeInterval = 2) {
        condition.lock()
        defer { condition.unlock() }
        guard !finished, !cancelled else { return }
        finished = true
        self.terminal = terminal
        drainDeadline = .now() + max(0, drainTimeout)
        condition.broadcast()
    }

    public func cancel() {
        condition.lock()
        defer { condition.unlock() }
        cancelled = true
        entries.removeAll()
        terminal = nil
        bufferedBytes = 0
        droppedBytes = 0
        condition.broadcast()
    }

    /// Blocking consumption for a dedicated forwarding thread.
    public func next() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let value = popLocked() { return value }
            if finished || cancelled { return nil }
            condition.wait()
        }
    }

    /// Nonblocking consumption for an async event loop.
    public func pop() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        return popLocked()
    }

    private func popLocked() -> Element? {
        guard !cancelled else { return nil }
        if let drainDeadline, DispatchTime.now() >= drainDeadline {
            droppedBytes += bufferedBytes
            entries.removeAll()
            bufferedBytes = 0
        }
        if !entries.isEmpty {
            let entry = entries.removeFirst()
            bufferedBytes -= entry.bytes
            return entry.value
        }
        if droppedBytes > 0 {
            let count = droppedBytes
            droppedBytes = 0
            return makeTruncation(count)
        }
        let value = terminal
        terminal = nil
        return value
    }
}
