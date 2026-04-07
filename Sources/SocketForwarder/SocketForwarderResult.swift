//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import NIO

final class ForwarderChannelTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: any Channel] = [:]
    private var pendingOperations = 0
    private var waiters: [EventLoopPromise<Void>] = []
    private var isClosing = false

    func register(_ channel: any Channel) {
        let identifier = ObjectIdentifier(channel)
        let shouldClose: Bool

        lock.lock()
        channels[identifier] = channel
        shouldClose = isClosing
        lock.unlock()

        channel.closeFuture.whenComplete { [weak self] _ in
            self?.remove(identifier)
        }

        if shouldClose {
            channel.eventLoop.execute {
                _ = channel.close(mode: .all)
            }
        }
    }

    func beginPendingOperation() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosing else {
            return false
        }

        pendingOperations += 1
        return true
    }

    func endPendingOperation() {
        let waitersToWake: [EventLoopPromise<Void>]

        lock.lock()
        if pendingOperations > 0 {
            pendingOperations -= 1
        }
        if isClosing && channels.isEmpty && pendingOperations == 0 {
            waitersToWake = waiters
            waiters.removeAll()
        } else {
            waitersToWake = []
        }
        lock.unlock()

        for waiter in waitersToWake {
            waiter.succeed(())
        }
    }

    func closeAll() {
        let channelsToClose: [any Channel]
        let waitersToWake: [EventLoopPromise<Void>]

        lock.lock()
        isClosing = true
        channelsToClose = Array(channels.values)
        if channelsToClose.isEmpty && pendingOperations == 0 {
            waitersToWake = waiters
            waiters.removeAll()
        } else {
            waitersToWake = []
        }
        lock.unlock()

        for channel in channelsToClose {
            channel.eventLoop.execute {
                _ = channel.close(mode: .all)
            }
        }
        for waiter in waitersToWake {
            waiter.succeed(())
        }
    }

    func waitForDrain(on eventLoop: any EventLoop) -> EventLoopFuture<Void> {
        lock.lock()
        if channels.isEmpty && pendingOperations == 0 {
            lock.unlock()
            return eventLoop.makeSucceededFuture(())
        }

        let promise = eventLoop.makePromise(of: Void.self)
        waiters.append(promise)
        lock.unlock()
        return promise.futureResult
    }

    private func remove(_ identifier: ObjectIdentifier) {
        let waitersToWake: [EventLoopPromise<Void>]

        lock.lock()
        channels.removeValue(forKey: identifier)
        if isClosing && channels.isEmpty && pendingOperations == 0 {
            waitersToWake = waiters
            waiters.removeAll()
        } else {
            waitersToWake = []
        }
        lock.unlock()

        for waiter in waitersToWake {
            waiter.succeed(())
        }
    }
}

public struct SocketForwarderResult: Sendable {
    private let channel: any Channel
    private let tracker: ForwarderChannelTracker?

    public init(channel: Channel) {
        self.init(channel: channel, tracker: nil)
    }

    init(channel: Channel, tracker: ForwarderChannelTracker?) {
        self.channel = channel
        self.tracker = tracker
    }

    public var proxyAddress: SocketAddress? { self.channel.localAddress }

    public func close() {
        self.channel.eventLoop.execute {
            _ = self.channel.close(mode: .all)
        }
        self.tracker?.closeAll()
    }

    public func wait() async throws {
        try await self.channel.closeFuture.get()
        try await waitForEventLoopQuiescence(on: self.channel.eventLoop)
        if let tracker = self.tracker {
            try await tracker.waitForDrain(on: self.channel.eventLoop).get()
        }
        try await waitForEventLoopQuiescence(on: self.channel.eventLoop)
    }
}

private func waitForEventLoopQuiescence(on eventLoop: any EventLoop) async throws {
    try await eventLoop.submit {}.get()
}
