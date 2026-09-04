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
import RuntimeMacOSSidecarShared
import Testing

@testable import container_macos_guest_agent

struct GuestClockSynchronizerTests {
    @Test
    func appliesRequestedTimeAndReturnsObservedTime() throws {
        let recorder = ClockRecorder()
        let expected = MacOSGuestClockSyncResult(
            unixTimeSeconds: 1_788_428_800,
            unixTimeNanoseconds: 123_456_999
        )
        let synchronizer = GuestClockSynchronizer(
            setTime: { seconds, nanoseconds in
                recorder.record(seconds: seconds, nanoseconds: nanoseconds)
            },
            readTime: {
                expected
            }
        )

        let result = try synchronizer.synchronize(
            MacOSGuestClockSyncRequest(
                unixTimeSeconds: 1_788_428_800,
                unixTimeNanoseconds: 123_456_789
            )
        )

        #expect(recorder.value() == .init(seconds: 1_788_428_800, nanoseconds: 123_456_789))
        #expect(result == expected)
    }

    @Test(arguments: [-1, 1_000_000_000])
    func rejectsInvalidNanoseconds(_ nanoseconds: Int32) {
        let synchronizer = GuestClockSynchronizer(
            setTime: { _, _ in
                Issue.record("setTime must not be called for an invalid request")
            },
            readTime: {
                Issue.record("readTime must not be called for an invalid request")
                return .init(unixTimeSeconds: 0, unixTimeNanoseconds: 0)
            }
        )

        #expect(throws: (any Error).self) {
            try synchronizer.synchronize(
                MacOSGuestClockSyncRequest(
                    unixTimeSeconds: 1_788_428_800,
                    unixTimeNanoseconds: nanoseconds
                )
            )
        }
    }
}

private final class ClockRecorder {
    struct Value: Equatable {
        let seconds: Int64
        let nanoseconds: Int32
    }

    private var stored: Value?

    func record(seconds: Int64, nanoseconds: Int32) {
        stored = .init(seconds: seconds, nanoseconds: nanoseconds)
    }

    func value() -> Value? {
        stored
    }
}
#endif
