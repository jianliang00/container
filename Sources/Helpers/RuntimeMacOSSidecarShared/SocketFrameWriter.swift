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

/// Serializes complete frames without an unbounded socket write. A partial-frame
/// failure shuts down the stream: continuing with another frame would corrupt it.
public final class SocketFrameWriter: @unchecked Sendable {
    private let fd: Int32
    private let timeout: TimeInterval
    private let writing = DispatchSemaphore(value: 1)
    private let stateLock = NSLock()
    private var cancelled = false

    public init(fd: Int32, timeout: TimeInterval = 5) throws {
        let ownedFD = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard ownedFD >= 0 else { throw Self.posixError() }
        var noSigPipe: Int32 = 1
        guard
            setsockopt(
                ownedFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        else {
            let error = Self.posixError()
            Darwin.close(ownedFD)
            throw error
        }
        let wholeSeconds = floor(timeout)
        var sendTimeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((timeout - wholeSeconds) * 1_000_000)
        )
        guard
            setsockopt(
                ownedFD,
                SOL_SOCKET,
                SO_SNDTIMEO,
                &sendTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0
        else {
            let error = Self.posixError()
            Darwin.close(ownedFD)
            throw error
        }
        self.fd = ownedFD
        self.timeout = timeout
    }

    deinit { Darwin.close(fd) }

    public func cancel() {
        stateLock.lock()
        cancelled = true
        // The owned descriptor stays open until deinit, including while a writer
        // is unwinding. It cannot be reused by a different connection meanwhile.
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        stateLock.unlock()
    }

    public func write<T: Encodable>(_ value: T) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= MacOSSidecarSocketIO.defaultMaxFrameSize else { throw POSIXError(.EMSGSIZE) }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)

        let deadline = DispatchTime.now() + timeout
        guard writing.wait(timeout: deadline) == .success else { throw POSIXError(.ETIMEDOUT) }
        defer { writing.signal() }
        do {
            try frame.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    if stateLock.withLock({ cancelled }) { throw POSIXError(.ECANCELED) }
                    let now = DispatchTime.now()
                    guard now < deadline else { throw POSIXError(.ETIMEDOUT) }
                    let count = Darwin.write(fd, base.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                    if count > 0 {
                        offset += count
                        continue
                    }
                    if count == 0 { throw POSIXError(.EPIPE) }
                    let code = errno
                    if code == EINTR { continue }
                    guard code == EAGAIN || code == EWOULDBLOCK else { throw Self.posixError(code) }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let remaining = deadline.uptimeNanoseconds - now.uptimeNanoseconds
                    let milliseconds = Int32(min(UInt64(Int32.max), max(1, remaining / 1_000_000)))
                    let result = Darwin.poll(&descriptor, 1, milliseconds)
                    if result == 0 { throw POSIXError(.ETIMEDOUT) }
                    if result < 0 && errno != EINTR { throw Self.posixError() }
                }
            }
        } catch {
            cancel()
            throw error
        }
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
