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
import RuntimeMacOSSidecarShared
import Testing

struct ProcessStartTraceTests {
    @Test
    func fixedFormatAndMonotonicElapsedTime() {
        let trace = MacOSProcessStartTrace(processID: "secret\nrequest", startNanoseconds: 100) { line in
            #expect(line.hasPrefix("process_start_timing process_hash="))
            #expect(!line.contains("secret"))
            #expect(!line.contains("\n"))
            #expect(line.hasSuffix("stage=received elapsed_ns=25"))
        }
        trace.record(.received, nowNanoseconds: 125)
        let clamped = MacOSProcessStartTrace(processID: nil, startNanoseconds: 100) { line in
            #expect(line.hasSuffix("elapsed_ns=0"))
        }
        clamped.record(.failed, nowNanoseconds: 99)
    }
}
