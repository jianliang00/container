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

/// Keeps filesystem latency off the runtime actor and the sidecar reader. Owns
/// a duplicate descriptor so session cleanup cannot close an in-flight write.
final class ProcessLogWriter: @unchecked Sendable {
    private enum Record: Sendable {
        case data(Data)
        case end
    }

    private let output: BoundedOutputBuffer<Record>
    private let completed = DispatchGroup()

    init(fileHandle: FileHandle, capacity: Int = 4 * 1024 * 1024, onFailure: @escaping @Sendable (Error) -> Void) throws {
        let fd = fcntl(fileHandle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = BoundedOutputBuffer<Record>(capacity: capacity) { count in
            .data(Data("\n[container: log output truncated; discarded \(count) bytes]\n".utf8))
        }
        self.output = output
        let completed = self.completed
        completed.enter()
        Thread.detachNewThread {
            defer {
                try? handle.close()
                completed.leave()
            }
            do {
                while let record = output.next() {
                    switch record {
                    case .data(let data): try Self.write(data, fd: fd)
                    case .end: return
                    }
                }
            } catch {
                output.cancel()
                onFailure(error)
            }
        }
    }

    deinit { finish() }

    func enqueue(_ data: Data) {
        output.append(.data(data), bytes: data.count)
    }

    func finish() {
        output.finish(with: .end)
    }

    static func finishAndWait(_ writers: [ProcessLogWriter?]) async {
        let writers = writers.compactMap { $0 }
        for writer in writers { writer.finish() }
        // Preserve ordinary log-before-exit ordering, but release the runtime
        // actor and cap the total wait when a filesystem is unresponsive.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let deadline = DispatchTime.now() + 2
                for writer in writers { _ = writer.completed.wait(timeout: deadline) }
                continuation.resume()
            }
        }
    }

    private static func write(_ data: Data, fd: Int32) throws {
        let deadline = DispatchTime.now() + 2
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                guard DispatchTime.now() < deadline else { throw POSIXError(.ETIMEDOUT) }
                let count = Darwin.write(fd, base.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                if count > 0 {
                    offset += count
                    continue
                }
                if count == 0 { throw POSIXError(.EIO) }
                let code = errno
                if code == EINTR { continue }
                guard code == EAGAIN || code == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                // Short bounded waits also cover non-regular destinations used
                // for redirected logs. Regular file I/O runs only on this thread.
                let result = Darwin.poll(&descriptor, 1, 50)
                if result < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
    }
}
