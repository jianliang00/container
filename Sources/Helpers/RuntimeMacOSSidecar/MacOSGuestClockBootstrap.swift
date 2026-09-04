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
