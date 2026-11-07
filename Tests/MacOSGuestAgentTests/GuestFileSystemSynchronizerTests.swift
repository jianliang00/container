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
import RuntimeMacOSSidecarShared
import Testing

@testable import container_macos_guest_agent

struct GuestFileSystemSynchronizerTests {
    @Test
    func wireRequestsAdvertiseCapabilityAndRepeatFreshSync() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let peer = pair[1]
        defer { Darwin.close(peer) }
        let count = SyncCounter()
        let worker = GuestFileSystemSynchronizer { _ = count.increment() }
        let connection = try AgentConnection(fd: pair[0], filesystemSynchronizer: worker)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { done.signal() }
            do { try connection.run() } catch { Issue.record(error) }
        }
        defer { _ = Darwin.shutdown(peer, SHUT_RDWR) }
        let ready = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: peer, timeoutMilliseconds: 1000)
        #expect(ready.capabilities?.contains(MacOSGuestFileSystemSyncRequest.capability) == true)
        let request = MacOSGuestFileSystemSyncRequest(requestID: "repeated")
        for _ in 0..<2 {
            try MacOSSidecarSocketIO.writeJSONFrame(GuestAgentFrame(type: .filesystemSync, id: request.requestID, data: JSONEncoder().encode(request)), fd: peer)
            let frame = try MacOSSidecarSocketIO.readJSONFrame(GuestAgentFrame.self, fd: peer, timeoutMilliseconds: 1000)
            #expect(frame.type == .filesystemSyncResult)
            #expect(frame.id == request.requestID)
            #expect(try JSONDecoder().decode(MacOSGuestFileSystemSyncResult.self, from: #require(frame.data)).requestID == request.requestID)
        }
        #expect(count.value == 2)
        _ = Darwin.shutdown(peer, SHUT_RDWR)
        #expect(done.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func overlappingRequestsAreRejectedAndCompletedIDsAreNotCached() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let count = SyncCounter()
        let worker = GuestFileSystemSynchronizer {
            if count.increment() == 1 {
                entered.signal()
                guard release.wait(timeout: .now() + 2) == .success else { throw POSIXError(.ETIMEDOUT) }
            }
        }
        let request = MacOSGuestFileSystemSyncRequest(requestID: "same-operation")
        Thread.detachNewThread {
            defer { done.signal() }
            do { #expect(try worker.synchronize(request).requestID == request.requestID) } catch { Issue.record(error) }
        }
        defer { release.signal() }
        #expect(entered.wait(timeout: .now() + 1) == .success)
        #expect(throws: POSIXError(.EBUSY)) { try worker.synchronize(request) }
        release.signal()
        #expect(done.wait(timeout: .now() + 1) == .success)
        #expect(try worker.synchronize(request).requestID == request.requestID)
        #expect(count.value == 2)
    }

    @Test
    func rejectsInvalidRequestAndReleasesAdmissionAfterFailure() throws {
        let count = SyncCounter()
        let worker = GuestFileSystemSynchronizer {
            if count.increment() == 1 { throw POSIXError(.EIO) }
        }
        #expect(throws: POSIXError(.EINVAL)) { try worker.synchronize(.init(requestID: "")) }
        #expect(count.value == 0)
        #expect(throws: POSIXError(.EIO)) { try worker.synchronize(.init(requestID: "one")) }
        #expect(try worker.synchronize(.init(requestID: "two")).requestID == "two")
    }
}

private final class SyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
