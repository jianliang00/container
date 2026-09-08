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
import RuntimeMacOSSidecarShared
import Testing

@testable import container_runtime_macos

struct RuntimeOutputBackpressureTests {
    @Test
    func normalLogsDrainAfterOriginalHandleCloses() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        let writer = try ProcessLogWriter(fileHandle: handle) { error in Issue.record(error) }
        let data = Data(repeating: 65, count: 1024 * 1024)
        writer.enqueue(data)
        try handle.close()
        await ProcessLogWriter.finishAndWait([writer])
        #expect(try Data(contentsOf: url) == data)
    }

    @Test
    func slowEventConsumerRetainsExitAndReportsTruncation() async {
        let pump = SidecarEventPump(capacity: 64 * 1024)
        let data = Data(repeating: 65, count: 64 * 1024)
        for _ in 0..<256 {
            pump.yield(.init(event: .processStdout, processID: "busy", data: data))
        }
        pump.yield(.init(event: .processExit, processID: "busy", exitCode: 23))
        pump.yield(.init(event: .processExit, processID: "other", exitCode: 37))
        pump.finish()
        var events: [MacOSSidecarEvent] = []
        for await event in pump.stream { events.append(event) }
        #expect(events.filter { $0.event == .processStdout }.count == 1)
        #expect(events.contains { $0.event == .processStderr && String(data: $0.data ?? Data(), encoding: .utf8)?.contains("output truncated") == true })
        #expect(events.contains { $0.processID == "busy" && $0.exitCode == 23 })
        #expect(events.contains { $0.processID == "other" && $0.exitCode == 37 })
    }

    @Test
    func slowLogDestinationDoesNotBlockProducerOrFinish() throws {
        let pipe = Pipe()
        let writer = try ProcessLogWriter(fileHandle: pipe.fileHandleForWriting, capacity: 64 * 1024) { error in Issue.record(error) }
        let data = Data(repeating: 65, count: 64 * 1024)
        let start = DispatchTime.now()
        for _ in 0..<128 { writer.enqueue(data) }
        writer.finish()
        #expect(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds < 1_000_000_000)
        try pipe.fileHandleForWriting.close()

        var received = Data()
        let fd = pipe.fileHandleForReading.fileDescriptor
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 3000) > 0 else { throw POSIXError(.ETIMEDOUT) }
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            received.append(contentsOf: bytes.prefix(count))
        }
        #expect(received.count < data.count * 128)
        #expect(String(data: received, encoding: .utf8)?.contains("output truncated") == true)
    }
}
#endif
