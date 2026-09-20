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

import CryptoKit
import Dispatch
import Foundation

/// Local monotonic timings only: host and guest clocks must not be subtracted.
/// The hash correlates process IDs without logging caller-controlled strings.
public struct MacOSProcessStartTrace: Sendable {
    public enum Stage: String, Sendable {
        case received, identityBegin, identityResolved, spawnBegin, spawnCompleted
        case processReused, ackSendBegin, ackSent, sendBegin, sent, ackReceived, failed
    }

    private let processHash: String
    private let attempt = UUID().uuidString
    private let start: UInt64
    private let emit: @Sendable (String) -> Void

    public init(
        processID: String?,
        startNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        emit: @escaping @Sendable (String) -> Void
    ) {
        processHash = SHA256.hash(data: Data((processID ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        start = startNanoseconds
        self.emit = emit
    }

    public func record(_ stage: Stage, nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let elapsed = nowNanoseconds >= start ? nowNanoseconds - start : 0
        emit("process_start_timing process_hash=\(processHash) attempt=\(attempt) stage=\(stage.rawValue) elapsed_ns=\(elapsed)")
    }
}
