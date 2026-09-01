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
import Foundation
import Logging
import RuntimeMacOSSidecarShared

final class SidecarEventDeliveryBuffer: @unchecked Sendable {
    private struct Item: Sendable {
        let id = UUID()
        let event: MacOSSidecarEvent
        let retainedBytes: Int
        let acknowledged: (@Sendable () -> Void)?
        var deliveredSubscriptionID: String?
    }

    private final class Subscription: @unchecked Sendable {
        let fd: Int32
        let id: String?
        var highestDeliveredSequenceByProcess: [String: UInt64] = [:]

        init(fd: Int32, id: String?) {
            self.fd = fd
            self.id = id
        }
    }

    private let condition = NSCondition()
    private let controlWriterQueue = DispatchQueue(label: "container.runtime.macos.sidecar.control-writer")
    private let eventWriterQueue = DispatchQueue(label: "container.runtime.macos.sidecar.event-writer")
    private let deliveryQueue = DispatchQueue(label: "container.runtime.macos.sidecar.event-delivery")
    private let log: Logger
    private let maximumEventCount: Int
    private let maximumRetainedBytes: Int
    private let writeTimeoutMilliseconds: Int32

    private var subscription: Subscription?
    private var pending: [Item] = []
    private var retainedBytes = 0
    private var acknowledgedSequenceByProcess: [String: UInt64] = [:]
    private var deliveryScheduled = false
    private var stopped = false
    #if DEBUG
    private var afterEventWriteBeforePublication: (@Sendable () -> Void)?
    #endif

    init(
        log: Logger,
        maximumEventCount: Int = 256,
        maximumRetainedBytes: Int = 16 * 1024 * 1024,
        writeTimeoutMilliseconds: Int32 = 1_000
    ) {
        self.log = log
        self.maximumEventCount = max(1, maximumEventCount)
        self.maximumRetainedBytes = max(1, maximumRetainedBytes)
        self.writeTimeoutMilliseconds = max(1, writeTimeoutMilliseconds)
    }

    func start() {
        condition.lock()
        stopped = false
        scheduleDeliveryLocked()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        subscription = nil
        pending.removeAll()
        retainedBytes = 0
        deliveryScheduled = false
        condition.broadcast()
        condition.unlock()
    }

    func write(_ envelope: MacOSSidecarEnvelope, to fd: Int32) throws {
        let payload = try JSONEncoder().encode(envelope)
        condition.lock()
        let isEventClient = subscription?.fd == fd
        condition.unlock()
        let queue = isEventClient ? eventWriterQueue : controlWriterQueue
        try queue.sync {
            try MacOSSidecarSocketIO.writeFrame(
                payload,
                fd: fd,
                timeoutMilliseconds: writeTimeoutMilliseconds
            )
        }
    }

    func writeSubscriptionResponse(
        _ response: MacOSSidecarResponse,
        to fd: Int32,
        subscriptionID: String?
    ) throws {
        let payload = try JSONEncoder().encode(MacOSSidecarEnvelope.response(response))
        try eventWriterQueue.sync {
            try MacOSSidecarSocketIO.writeFrame(
                payload,
                fd: fd,
                timeoutMilliseconds: writeTimeoutMilliseconds
            )
        }
        setClient(fd, subscriptionID: subscriptionID)
    }

    @discardableResult
    func enqueue(
        _ event: MacOSSidecarEvent,
        acknowledged: (@Sendable () -> Void)? = nil
    ) -> Bool {
        let item = Item(
            event: event,
            retainedBytes: (event.data?.count ?? 0) + (event.message?.utf8.count ?? 0) + 256,
            acknowledged: acknowledged,
            deliveredSubscriptionID: nil
        )

        condition.lock()
        while !stopped, queueIsFull(adding: item) {
            condition.wait()
        }
        guard !stopped else {
            condition.unlock()
            return false
        }
        pending.append(item)
        retainedBytes += item.retainedBytes
        scheduleDeliveryLocked()
        condition.unlock()
        return true
    }

    func setClient(_ fd: Int32, subscriptionID: String? = nil) {
        condition.lock()
        subscription = .init(fd: fd, id: subscriptionID)
        scheduleDeliveryLocked()
        condition.unlock()
    }

    func clearClient(_ expectedFD: Int32? = nil) {
        condition.lock()
        if expectedFD == nil || subscription?.fd == expectedFD {
            subscription = nil
        }
        condition.unlock()
    }

    func closeClient(_ fd: Int32) {
        clearClient(fd)
        _ = eventWriterQueue.sync {
            Darwin.close(fd)
        }
    }

    func hasClient() -> Bool {
        condition.lock()
        let result = subscription != nil
        condition.unlock()
        return result
    }

    func pendingCount() -> Int {
        condition.lock()
        let count = pending.count
        condition.unlock()
        return count
    }

    #if DEBUG
    func _testSetAfterEventWriteBeforePublication(_ hook: (@Sendable () -> Void)?) {
        condition.lock()
        afterEventWriteBeforePublication = hook
        condition.unlock()
    }
    #endif

    func acknowledge(_ acknowledgement: MacOSSidecarEventAcknowledgement, from fd: Int32) throws {
        var callbacks: [@Sendable () -> Void] = []
        condition.lock()
        guard
            let subscription,
            subscription.fd == fd,
            subscription.id == acknowledgement.subscriptionID
        else {
            condition.unlock()
            throw SidecarRPCError(
                code: "staleEventSubscription",
                message: "event acknowledgement does not belong to the active subscriber"
            )
        }

        let lastAcknowledged = acknowledgedSequenceByProcess[acknowledgement.processID] ?? 0
        if acknowledgement.sequence <= lastAcknowledged {
            condition.unlock()
            return
        }
        guard
            let highestDelivered = subscription.highestDeliveredSequenceByProcess[acknowledgement.processID],
            acknowledgement.sequence <= highestDelivered
        else {
            condition.unlock()
            throw SidecarRPCError(
                code: "eventAcknowledgementOutOfRange",
                message:
                    "event acknowledgement sequence \(acknowledgement.sequence) was not delivered to this subscriber"
            )
        }

        var retained: [Item] = []
        retained.reserveCapacity(pending.count)
        for item in pending {
            if item.event.processID == acknowledgement.processID,
                let sequence = item.event.sequence,
                sequence <= acknowledgement.sequence
            {
                retainedBytes -= item.retainedBytes
                if let callback = item.acknowledged {
                    callbacks.append(callback)
                }
            } else {
                retained.append(item)
            }
        }
        pending = retained
        acknowledgedSequenceByProcess[acknowledgement.processID] = acknowledgement.sequence
        condition.broadcast()
        condition.unlock()

        for callback in callbacks {
            callback()
        }
    }

    private func queueIsFull(adding item: Item) -> Bool {
        if pending.count >= maximumEventCount {
            return true
        }
        if pending.isEmpty, item.retainedBytes > maximumRetainedBytes {
            return false
        }
        return retainedBytes + item.retainedBytes > maximumRetainedBytes
    }

    private func scheduleDeliveryLocked() {
        guard !stopped, subscription != nil, !pending.isEmpty, !deliveryScheduled else {
            return
        }
        deliveryScheduled = true
        deliveryQueue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while true {
            let activeSubscription: Subscription
            let item: Item
            var acknowledged: (@Sendable () -> Void)?
            condition.lock()
            guard !stopped, let subscription else {
                deliveryScheduled = false
                condition.broadcast()
                condition.unlock()
                return
            }
            guard
                let first = pending.first(where: {
                    subscription.id == nil || $0.deliveredSubscriptionID != subscription.id
                })
            else {
                deliveryScheduled = false
                condition.broadcast()
                condition.unlock()
                return
            }
            activeSubscription = subscription
            item = first

            do {
                let deliveredEvent = item.event.delivered(to: activeSubscription.id)
                let payload = try JSONEncoder().encode(MacOSSidecarEnvelope.event(deliveredEvent))
                try eventWriterQueue.sync {
                    try MacOSSidecarSocketIO.writeFrame(
                        payload,
                        fd: activeSubscription.fd,
                        timeoutMilliseconds: writeTimeoutMilliseconds
                    )
                }
                #if DEBUG
                afterEventWriteBeforePublication?()
                #endif
            } catch {
                if self.subscription === activeSubscription {
                    self.subscription = nil
                }
                deliveryScheduled = false
                condition.broadcast()
                condition.unlock()
                _ = Darwin.shutdown(activeSubscription.fd, SHUT_RDWR)
                log.error(
                    "failed to deliver buffered sidecar event",
                    metadata: [
                        "event": "\(item.event.event.rawValue)",
                        "process_id": "\(item.event.processID)",
                        "error": "\(error)",
                    ])
                return
            }

            if subscription === activeSubscription,
                let index = pending.firstIndex(where: { $0.id == item.id })
            {
                if item.event.sequence != nil, let subscriptionID = activeSubscription.id {
                    pending[index].deliveredSubscriptionID = subscriptionID
                    let processID = item.event.processID
                    let sequence = item.event.sequence ?? 0
                    activeSubscription.highestDeliveredSequenceByProcess[processID] = max(
                        activeSubscription.highestDeliveredSequenceByProcess[processID] ?? 0,
                        sequence
                    )
                } else {
                    let removed = pending.remove(at: index)
                    retainedBytes -= removed.retainedBytes
                    acknowledged = removed.acknowledged
                    condition.broadcast()
                }
            }
            condition.unlock()
            acknowledged?()
        }
    }
}
