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
import Testing

@testable import container_macos_guest_agent

struct GuestProcessResourceStatsTests {
    @Test func convertsAppleSiliconMachTicksToNanoseconds() throws {
        let timebase = mach_timebase_info_data_t(numer: 125, denom: 3)
        #expect(try GuestProcessTreeSampler.cpuNanoseconds(24_000_000, timebase: timebase) == 1_000_000_000)
        #expect(try GuestProcessTreeSampler.cpuNanoseconds(1, timebase: timebase) == 41)
        #expect(try GuestProcessTreeSampler.cpuNanoseconds(123, timebase: .init(numer: 1, denom: 1)) == 123)
    }

    @Test func conversionRejectsInvalidTimebaseAndOverflow() {
        #expect(throws: POSIXError.self) { try GuestProcessTreeSampler.cpuNanoseconds(1, timebase: .init(numer: 1, denom: 0)) }
        #expect(throws: POSIXError.self) { try GuestProcessTreeSampler.cpuNanoseconds(.max, timebase: .init(numer: 125, denom: 3)) }
    }

    @Test func measuredCPUAgreesWithBSDProcessTime() throws {
        func bsdNanoseconds() throws -> UInt64 {
            var value = rusage()
            guard getrusage(RUSAGE_SELF, &value) == 0 else { throw POSIXError(.EIO) }
            return UInt64(value.ru_utime.tv_sec + value.ru_stime.tv_sec) * 1_000_000_000
                + UInt64(value.ru_utime.tv_usec + value.ru_stime.tv_usec) * 1000
        }
        func machTicks() throws -> UInt64 {
            var value = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &value) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
            }
            guard result == 0 else { throw POSIXError(.EIO) }
            return value.ri_user_time + value.ri_system_time
        }
        var timebase = mach_timebase_info_data_t()
        #expect(mach_timebase_info(&timebase) == KERN_SUCCESS)
        let bsdBefore = try bsdNanoseconds()
        let machBefore = try machTicks()
        let start = Date()
        while Date().timeIntervalSince(start) < 0.05 {}
        let measured = try GuestProcessTreeSampler.cpuNanoseconds(machTicks() - machBefore, timebase: timebase)
        let expected = try bsdNanoseconds() - bsdBefore
        #expect(measured > 0)
        #expect(abs(Double(measured) - Double(expected)) < Double(expected) * 0.1 + 5_000_000)
    }
}
#endif
