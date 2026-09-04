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

struct GuestClockSynchronizer {
    typealias SetTime = (_ seconds: Int64, _ nanoseconds: Int32) throws -> Void
    typealias ReadTime = () throws -> MacOSGuestClockSyncResult

    private let setTime: SetTime
    private let readTime: ReadTime

    init(
        setTime: @escaping SetTime = Self.setSystemTime,
        readTime: @escaping ReadTime = Self.readSystemTime
    ) {
        self.setTime = setTime
        self.readTime = readTime
    }

    func synchronize(_ request: MacOSGuestClockSyncRequest) throws -> MacOSGuestClockSyncResult {
        guard request.unixTimeNanoseconds >= 0, request.unixTimeNanoseconds < 1_000_000_000 else {
            throw POSIXError(.EINVAL)
        }
        guard Int(exactly: request.unixTimeSeconds) != nil else {
            throw POSIXError(.EOVERFLOW)
        }

        try setTime(request.unixTimeSeconds, request.unixTimeNanoseconds)
        return try readTime()
    }

    private static func setSystemTime(seconds: Int64, nanoseconds: Int32) throws {
        var value = timespec(
            tv_sec: Int(seconds),
            tv_nsec: Int(nanoseconds)
        )
        guard clock_settime(CLOCK_REALTIME, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func readSystemTime() throws -> MacOSGuestClockSyncResult {
        var value = timespec()
        guard clock_gettime(CLOCK_REALTIME, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return MacOSGuestClockSyncResult(
            unixTimeSeconds: Int64(value.tv_sec),
            unixTimeNanoseconds: Int32(value.tv_nsec)
        )
    }
}
