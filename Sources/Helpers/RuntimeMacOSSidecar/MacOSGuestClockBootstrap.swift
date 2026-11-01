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

enum MacOSGuestClockBootstrap {
    static let defaultToleranceNanoseconds: Int64 = 2_000_000_000

    static func synchronize(
        timeoutSeconds: TimeInterval = 10,
        handshakeAttemptTimeoutSeconds: TimeInterval = 3,
        connect: @Sendable (TimeInterval) async throws -> Int32,
        onHandshakeRetry: @Sendable (Int, Error) -> Void = { _, _ in }
    ) async throws -> Int64 {
        // Connect, ready, write and result share one budget. Only opening the
        // ready stream can retry; an uncertain clockSync result is not replayed.
        let deadline = sidecarReadDeadline(timeoutSeconds: timeoutSeconds)
        let connection = try await GuestAgentHandshake.connect(
            timeoutSeconds: Double(try sidecarRemainingReadMilliseconds(until: deadline)) / 1_000,
            attemptTimeoutSeconds: handshakeAttemptTimeoutSeconds,
            connect: connect, onRetry: onHandshakeRetry
        )
        let fd = connection.fd
        defer {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        try Task.checkCancellation()
        let hostBefore = try sampleHostTime()
        do {
            try MacOSSidecarSocketIO.writeJSONFrame(
                SidecarGuestAgentFrame.clockSync(hostBefore), fd: fd,
                timeoutMilliseconds: try sidecarRemainingReadMilliseconds(until: deadline)
            )
            while true {
                try Task.checkCancellation()
                let frame = try MacOSSidecarSocketIO.readJSONFrame(
                    SidecarGuestAgentFrame.self, fd: fd,
                    timeoutMilliseconds: try sidecarRemainingReadMilliseconds(until: deadline)
                )
                try Task.checkCancellation()
                switch frame.type {
                case .clockResult:
                    guard let data = frame.data else {
                        throw ContainerizationError(.internalError, message: "guest clock synchronization result is missing data")
                    }
                    let result = try JSONDecoder().decode(MacOSGuestClockSyncResult.self, from: data)
                    return try validate(result: result, hostBefore: hostBefore, hostAfter: sampleHostTime())
                case .error:
                    throw ContainerizationError(.internalError, message: "guest clock synchronization failed: \(frame.message ?? "unknown error")")
                case .exit:
                    throw ContainerizationError(.internalError, message: "guest agent exited during clock synchronization (code=\(frame.exitCode ?? 1))")
                default:
                    continue
                }
            }
        } catch let error as POSIXError where error.code == .ETIMEDOUT {
            try Task.checkCancellation()
            throw ContainerizationError(.timeout, message: "timed out during guest clock synchronization")
        }
    }

    static func sampleHostTime() throws -> MacOSGuestClockSyncRequest {
        var value = timespec()
        guard clock_gettime(CLOCK_REALTIME, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return MacOSGuestClockSyncRequest(
            unixTimeSeconds: Int64(value.tv_sec),
            unixTimeNanoseconds: Int32(value.tv_nsec)
        )
    }

    static func validate(
        result: MacOSGuestClockSyncResult,
        hostBefore: MacOSGuestClockSyncRequest,
        hostAfter: MacOSGuestClockSyncRequest,
        toleranceNanoseconds: Int64 = defaultToleranceNanoseconds
    ) throws -> Int64 {
        guard toleranceNanoseconds >= 0 else {
            throw ContainerizationError(.invalidArgument, message: "clock synchronization tolerance must not be negative")
        }

        let before = try totalNanoseconds(
            seconds: hostBefore.unixTimeSeconds,
            nanoseconds: hostBefore.unixTimeNanoseconds
        )
        let after = try totalNanoseconds(
            seconds: hostAfter.unixTimeSeconds,
            nanoseconds: hostAfter.unixTimeNanoseconds
        )
        let observed = try totalNanoseconds(
            seconds: result.unixTimeSeconds,
            nanoseconds: result.unixTimeNanoseconds
        )
        guard after >= before else {
            throw ContainerizationError(.internalError, message: "host realtime clock moved backwards during guest synchronization")
        }

        let lowerBound = before.subtractingReportingOverflow(toleranceNanoseconds)
        let upperBound = after.addingReportingOverflow(toleranceNanoseconds)
        guard !lowerBound.overflow, !upperBound.overflow else {
            throw ContainerizationError(.internalError, message: "clock synchronization range overflow")
        }
        guard observed >= lowerBound.partialValue, observed <= upperBound.partialValue else {
            throw ContainerizationError(
                .invalidState,
                message: "guest realtime clock remained outside the allowed range after synchronization"
            )
        }

        let offset = observed.subtractingReportingOverflow(after)
        guard !offset.overflow else {
            throw ContainerizationError(.internalError, message: "clock synchronization offset overflow")
        }
        return offset.partialValue
    }

    private static func totalNanoseconds(seconds: Int64, nanoseconds: Int32) throws -> Int64 {
        guard nanoseconds >= 0, nanoseconds < 1_000_000_000 else {
            throw ContainerizationError(.invalidArgument, message: "clock nanoseconds must be between 0 and 999999999")
        }
        let scaled = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let combined = scaled.partialValue.addingReportingOverflow(Int64(nanoseconds))
        guard !scaled.overflow, !combined.overflow else {
            throw ContainerizationError(.invalidArgument, message: "clock value is outside the supported range")
        }
        return combined.partialValue
    }
}
