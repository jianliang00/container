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

import ContainerizationError
import Darwin
import Foundation
import RuntimeMacOSSidecarShared

/// Opens a ready stream without dispatching a guest operation. Only transport
/// failures before ready may be retried; the caller owns the successful fd.
enum GuestAgentHandshake {
    struct Connection: Sendable {
        let fd: Int32
        let capabilities: Set<String>
    }

    static func connect(
        timeoutSeconds: TimeInterval,
        attemptTimeoutSeconds: TimeInterval = 3,
        connect: @Sendable (TimeInterval) async throws -> Int32,
        onRetry: @Sendable (Int, Error) -> Void = { _, _ in }
    ) async throws -> Connection {
        let deadline = DispatchTime.now() + max(0, timeoutSeconds)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let remaining = try remainingSeconds(until: deadline)
            let attemptDeadline = DispatchTime.now() + min(remaining, max(0.001, attemptTimeoutSeconds))
            var fd: Int32 = -1
            attempt += 1
            do {
                fd = try await connect(try remainingSeconds(until: attemptDeadline))
                try Task.checkCancellation()
                let capabilities = try waitForReady(fd: fd, deadline: attemptDeadline)
                try Task.checkCancellation()
                return Connection(fd: fd, capabilities: capabilities)
            } catch {
                if fd >= 0 {
                    _ = Darwin.shutdown(fd, SHUT_RDWR)
                    Darwin.close(fd)
                }
                try Task.checkCancellation()
                guard isRetryable(error) else { throw error }
                let remaining = try remainingSeconds(until: deadline)
                onRetry(attempt, error)
                try await Task.sleep(for: .seconds(min(0.05, remaining)))
            }
        }
    }

    private static func remainingSeconds(until deadline: DispatchTime) throws -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else {
            throw ContainerizationError(.timeout, message: "timed out establishing guest-agent ready stream")
        }
        return Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }

    private static func waitForReady(fd: Int32, deadline: DispatchTime) throws -> Set<String> {
        while true {
            try Task.checkCancellation()
            let remaining = try remainingSeconds(until: deadline)
            let frame = try MacOSSidecarSocketIO.readJSONFrame(
                SidecarGuestAgentFrame.self, fd: fd,
                timeoutMilliseconds: Int32(min(Double(Int32.max), max(1, ceil(remaining * 1_000))))
            )
            switch frame.type {
            case .ready:
                return Set(frame.capabilities ?? [])
            case .error:
                throw ContainerizationError(.internalError, message: "guest-agent error before ready: \(frame.message ?? "unknown error")")
            case .exit:
                throw ContainerizationError(.internalError, message: "guest-agent exited before ready (code=\(frame.exitCode ?? 1))")
            default:
                continue
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? ContainerizationError { return error.code == .timeout }
        let error = error as NSError
        // The shared framing reader represents peer EOF with this legacy error.
        if error.domain == "RuntimeMacOSSidecarShared", error.code == 1, error.localizedDescription == "unexpected EOF" { return true }
        return error.domain == NSPOSIXErrorDomain
            && [ETIMEDOUT, ECONNRESET, ECONNREFUSED, ENOTCONN, EPIPE].map(Int.init).contains(error.code)
    }
}
