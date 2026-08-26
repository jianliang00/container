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
import Testing

@testable import ContainerCRIShimMacOS

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite
struct FileHandleByteWriterTests {
    @Test
    func partialWritesPreserveBytesAndOrder() async throws {
        let (writerHandle, readerHandle) = try makeWriterSocketPair()
        try setWriterSendBuffer(writerHandle.fileDescriptor, size: 4 * 1024)
        let writer = try FileHandleByteWriter(handle: writerHandle)
        let input = try fileHandleStream(readerHandle)
        defer {
            writer.cancel()
            input.cancel()
            try? writerHandle.close()
            try? readerHandle.close()
        }

        let first = makeWriterTestData(count: 512 * 1024, seed: 17)
        let second = makeWriterTestData(count: 512 * 1024, seed: 83)
        let expected = first + second
        let reader = Task {
            var received = Data()
            for await data in input.bytes {
                received.append(data)
                if received.count >= expected.count {
                    break
                }
            }
            return received
        }

        try await writer.write(first)
        try await writer.write(second)
        let received = await reader.value

        #expect(received == expected)
    }

    @Test
    func blockedWriteCancellationDoesNotStarveCooperativeTasks() async throws {
        let (writerHandle, readerHandle) = try makeWriterSocketPair()
        try setWriterSendBuffer(writerHandle.fileDescriptor, size: 4 * 1024)
        let writer = try FileHandleByteWriter(handle: writerHandle)
        defer {
            writer.cancel()
            try? writerHandle.close()
            try? readerHandle.close()
        }

        let writeTask = Task {
            try await writer.write(Data(repeating: 0xA5, count: 8 * 1024 * 1024))
        }
        try await waitForWriterData(readerHandle.fileDescriptor)

        writeTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await writeTask.value
        }
    }

    @Test
    func concurrentWriteFailsWithoutCorruptingTheFirstWrite() async throws {
        let (writerHandle, readerHandle) = try makeWriterSocketPair()
        try setWriterSendBuffer(writerHandle.fileDescriptor, size: 4 * 1024)
        let writer = try FileHandleByteWriter(handle: writerHandle)
        defer {
            writer.cancel()
            try? writerHandle.close()
            try? readerHandle.close()
        }

        let firstWrite = Task {
            try await writer.write(Data(repeating: 0x5A, count: 8 * 1024 * 1024))
        }
        try await waitForWriterData(readerHandle.fileDescriptor)
        await #expect(throws: (any Error).self) {
            try await writer.write(Data([0xFF]))
        }

        firstWrite.cancel()
        await #expect(throws: CancellationError.self) {
            try await firstWrite.value
        }
    }

    @Test
    func repeatedBlockedWriteCancellationIsExactOnce() async throws {
        for _ in 0..<128 {
            let (writerHandle, readerHandle) = try makeWriterSocketPair()
            try setWriterSendBuffer(writerHandle.fileDescriptor, size: 4 * 1024)
            let writer = try FileHandleByteWriter(handle: writerHandle)
            let writeTask = Task {
                try await writer.write(Data(repeating: 0xC3, count: 256 * 1024))
            }

            await Task.yield()
            writeTask.cancel()
            writer.cancel()
            writer.cancel()
            await #expect(throws: (any Error).self) {
                try await writeTask.value
            }

            try? writerHandle.close()
            try? readerHandle.close()
        }
    }

    @Test
    func peerCloseFailsWriteWithoutRaisingSIGPIPE() async throws {
        let (writerHandle, readerHandle) = try makeWriterSocketPair()
        let writer = try FileHandleByteWriter(handle: writerHandle)
        defer {
            writer.cancel()
            try? writerHandle.close()
            try? readerHandle.close()
        }

        _ = Darwin.shutdown(readerHandle.fileDescriptor, SHUT_RDWR)
        try readerHandle.close()

        await #expect(throws: (any Error).self) {
            try await writer.write(Data([1, 2, 3, 4]))
        }
    }

    @Test
    func duplicateRemainsUsableAfterOriginalHandleCloses() async throws {
        let (writerHandle, readerHandle) = try makeWriterSocketPair()
        let writer = try FileHandleByteWriter(handle: writerHandle)
        defer {
            writer.cancel()
            try? writerHandle.close()
            try? readerHandle.close()
        }

        try writerHandle.close()
        let expected = Data("writer-owned-duplicate".utf8)
        try await writer.write(expected)
        let received = try readerHandle.read(upToCount: expected.count)

        #expect(received == expected)
        writer.cancel()
        writer.cancel()
        await #expect(throws: (any Error).self) {
            try await writer.write(Data([0]))
        }
    }
}

private func makeWriterSocketPair() throws -> (FileHandle, FileHandle) {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (
        FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
        FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    )
}

private func setWriterSendBuffer(_ fileDescriptor: Int32, size: Int32) throws {
    var size = size
    guard
        Darwin.setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDBUF,
            &size,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
    else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func waitForWriterData(_ fileDescriptor: Int32) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while true {
        var byte: UInt8 = 0
        let result = Darwin.recv(fileDescriptor, &byte, 1, MSG_DONTWAIT | MSG_PEEK)
        if result == 1 {
            return
        }
        let code = errno
        guard result < 0, code == EAGAIN || code == EWOULDBLOCK else {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard clock.now < deadline else {
            throw POSIXError(.ETIMEDOUT)
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func makeWriterTestData(count: Int, seed: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        let bytes = buffer.bindMemory(to: UInt8.self)
        for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: (index &* 31) ^ (index >> 8) ^ seed)
        }
    }
    return data
}
