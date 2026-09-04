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

@testable import RuntimeMacOSSidecarShared

struct SidecarGuestClockProtocolTests {
    @Test
    func clockSyncPayloadsRoundTrip() throws {
        let request = MacOSGuestClockSyncRequest(
            unixTimeSeconds: 1_788_428_800,
            unixTimeNanoseconds: 123_456_789
        )
        let requestData = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(MacOSGuestClockSyncRequest.self, from: requestData) == request)

        let result = MacOSGuestClockSyncResult(
            unixTimeSeconds: request.unixTimeSeconds,
            unixTimeNanoseconds: request.unixTimeNanoseconds + 1_000
        )
        let resultData = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(MacOSGuestClockSyncResult.self, from: resultData) == result)
    }
}
