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
        let timeout = max(timeout, 0.001)
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
        do {
            try Self.configureSendTimeout(fd: ownedFD, timeout: timeout)
        } catch {
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

    public func write<T: Encodable>(_ value: T, deadline requestedDeadline: Date? = nil) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= MacOSSidecarSocketIO.defaultMaxFrameSize else { throw POSIXError(.EMSGSIZE) }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)

        let defaultDeadline = Date().addingTimeInterval(timeout)
        let deadline = requestedDeadline.map { min($0, defaultDeadline) } ?? defaultDeadline
        guard writing.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        defer { writing.signal() }
        do {
            defer { try? Self.configureSendTimeout(fd: fd, timeout: timeout) }
            try frame.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    if stateLock.withLock({ cancelled }) { throw POSIXError(.ECANCELED) }
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
                    try Self.configureSendTimeout(fd: fd, timeout: remaining)
                    let count = Darwin.write(fd, base.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                    if count > 0 {
                        offset += count
                        continue
                    }
                    if count == 0 { throw POSIXError(.EPIPE) }
                    let code = errno
                    if code == EINTR { continue }
                    guard code == EAGAIN || code == EWOULDBLOCK else { throw Self.posixError(code) }
                    let pollRemaining = deadline.timeIntervalSinceNow
                    guard pollRemaining > 0 else { throw POSIXError(.ETIMEDOUT) }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let milliseconds = Int32(min(Double(Int32.max), max(1, ceil(pollRemaining * 1_000))))
                    let result = Darwin.poll(&descriptor, 1, milliseconds)
                    if result == 0 { throw POSIXError(.ETIMEDOUT) }
                    if result < 0 && errno != EINTR { throw Self.posixError() }
                    if result > 0, descriptor.revents & Int16(POLLOUT) == 0 {
                        throw POSIXError(.EPIPE)
                    }
                }
            }
        } catch {
            cancel()
            throw error
        }
    }

    private static func configureSendTimeout(fd: Int32, timeout: TimeInterval) throws {
        let clamped = max(timeout, 0.001)
        let wholeSeconds = floor(clamped)
        var sendTimeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((clamped - wholeSeconds) * 1_000_000)
        )
        guard
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                &sendTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0
        else {
            throw posixError()
        }
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
