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

struct OutputBackpressureTests {
    @Test
    func overflowPreservesGapPositionAndTerminalStatus() {
        let buffer = BoundedOutputBuffer<String>(capacity: 4) { "dropped:\($0)" }
        buffer.append("first", bytes: 4)
        buffer.append("lost", bytes: 3)
        #expect(buffer.pop() == "first")
        buffer.append("also lost", bytes: 2)
        #expect(buffer.pop() == "dropped:5")
        buffer.append("last", bytes: 4)
        buffer.finish(with: "exit:23")
        buffer.append("too late", bytes: 4)
        #expect(buffer.next() == "last")
        #expect(buffer.next() == "exit:23")
        #expect(buffer.next() == nil)
    }

    @Test
    func drainDeadlineDiscardsOutputButKeepsExit() {
        let buffer = BoundedOutputBuffer<String>(capacity: 8) { "dropped:\($0)" }
        buffer.append("queued", bytes: 8)
        buffer.append("overflow", bytes: 2)
        buffer.finish(with: "exit:37", drainTimeout: 0)
        #expect(buffer.next() == "dropped:10")
        #expect(buffer.next() == "exit:37")
        #expect(buffer.next() == nil)
    }

    @Test
    func cancellationWakesBlockedConsumer() {
        let buffer = BoundedOutputBuffer<String> { "dropped:\($0)" }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            #expect(buffer.next() == nil)
            done.signal()
        }
        buffer.cancel()
        #expect(done.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func writerPreservesBlockingModeForSharedDescriptor() throws {
        var pair = [Int32](repeating: -1, count: 2)
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            Darwin.close(pair[0])
            Darwin.close(pair[1])
        }
        let readerFD = pair[0]
        let writerFD = pair[1]

        let writer = try SocketFrameWriter(fd: readerFD)
        let flags = fcntl(readerFD, F_GETFL)
        #expect(flags >= 0)
        #expect(flags & O_NONBLOCK == 0)
        Thread.detachNewThread {
            usleep(50_000)
            try? MacOSSidecarSocketIO.writeJSONFrame("delayed", fd: writerFD)
        }
        #expect(try MacOSSidecarSocketIO.readJSONFrame(String.self, fd: readerFD) == "delayed")
        withExtendedLifetime(writer) {}
    }

    @Test
    func stalledSocketTimesOutAndNeverAppendsToPartialFrame() throws {
        var pair = [Int32](repeating: -1, count: 2)
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            Darwin.close(pair[0])
            Darwin.close(pair[1])
        }
        var sendBuffer: Int32 = 4096
        #expect(setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0)
        let writer = try SocketFrameWriter(fd: pair[0], timeout: 0.1)
        let start = DispatchTime.now()
        #expect(throws: POSIXError(.ETIMEDOUT)) {
            try writer.write(Data(repeating: 65, count: 1024 * 1024))
        }
        #expect(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds < 1_000_000_000)
        #expect(throws: POSIXError(.ECANCELED)) { try writer.write("another frame") }
        var data = [UInt8](repeating: 0, count: 8192)
        var received = 0
        while true {
            let count = Darwin.read(pair[1], &data, data.count)
            if count <= 0 {
                #expect(count == 0)
                break
            }
            received += count
        }
        #expect(received > 0)
        #expect(received < 1024 * 1024)
    }

    @Test
    func concurrentWritersPreserveCompleteFrames() throws {
        var pair = [Int32](repeating: -1, count: 2)
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            Darwin.close(pair[0])
            Darwin.close(pair[1])
        }
        let writer = try SocketFrameWriter(fd: pair[0])
        let done = DispatchGroup()
        for prefix in ["a", "b"] {
            done.enter()
            Thread.detachNewThread {
                defer { done.leave() }
                do {
                    for i in 0..<100 { try writer.write("\(prefix):\(i)") }
                } catch { Issue.record(error) }
            }
        }
        var values = Set<String>()
        for _ in 0..<200 {
            values.insert(try MacOSSidecarSocketIO.readJSONFrame(String.self, fd: pair[1]))
        }
        #expect(values.count == 200)
        #expect(done.wait(timeout: .now() + 2) == .success)
    }
}
