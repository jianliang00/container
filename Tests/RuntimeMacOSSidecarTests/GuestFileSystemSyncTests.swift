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

@testable import container_runtime_macos_sidecar

struct GuestFileSystemSyncTests {
    @Test(arguments: ["success", "old-guest", "wrong-id", "wrong-payload-id", "busy", "silent", "malformed"])
    func validatesRepliesAndNeverReplaysDispatchedSync(mode: String) async throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let client = pair[0]
        let peer = pair[1]
        let done = DispatchSemaphore(value: 0)
        let count = ConnectionCounter()
        Thread.detachNewThread {
            defer {
                Darwin.close(peer)
                done.signal()
            }
            do {
                let capabilities = mode == "old-guest" ? [] : [MacOSGuestFileSystemSyncRequest.capability]
                try MacOSSidecarSocketIO.writeJSONFrame(SidecarGuestAgentFrame(type: .ready, capabilities: capabilities), fd: peer)
                if mode == "old-guest" {
                    var byte: UInt8 = 0
                    #expect(Darwin.read(peer, &byte, 1) == 0)
                    return
                }
                let request = try MacOSSidecarSocketIO.readJSONFrame(SidecarGuestAgentFrame.self, fd: peer, timeoutMilliseconds: 1000)
                #expect(request.type == .filesystemSync)
                #expect(request.id == "test-sync")
                if mode == "silent" {
                    var byte: UInt8 = 0
                    #expect(Darwin.read(peer, &byte, 1) == 0)
                    return
                }
                let result = MacOSGuestFileSystemSyncResult(requestID: mode == "wrong-payload-id" ? "stale" : "test-sync")
                let response = SidecarGuestAgentFrame(
                    type: mode == "busy" ? .error : .filesystemSyncResult,
                    id: mode == "wrong-id" ? "stale" : "test-sync",
                    data: mode == "malformed" ? Data("{}".utf8) : try JSONEncoder().encode(result),
                    errorCode: mode == "busy" ? EBUSY : nil
                )
                try MacOSSidecarSocketIO.writeJSONFrame(response, fd: peer)
            } catch { Issue.record(error) }
        }
        do {
            let result = try await MacOSGuestFileSystemSync.synchronize(.init(requestID: "test-sync", timeoutSeconds: 0.5)) { _ in
                #expect(count.increment() == 1)
                return client
            }
            #expect(mode == "success")
            #expect(result.requestID == "test-sync")
        } catch {
            #expect(mode != "success")
            if mode == "busy" { #expect((error as? SidecarRPCError)?.code == "operationInProgress") }
            if mode == "old-guest" { #expect((error as? SidecarRPCError)?.code == "unsupportedGuestCapability") }
        }
        let peerFinished = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: done.wait(timeout: .now() + 1) == .success)
            }
        }
        #expect(peerFinished)
        #expect(count.value == 1)
    }
}

private final class ConnectionCounter: @unchecked Sendable {
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
