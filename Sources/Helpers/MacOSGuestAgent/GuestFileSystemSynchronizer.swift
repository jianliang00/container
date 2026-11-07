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

/// At most one kernel sync is in flight across all guest-agent connections.
/// A disconnected caller cannot cancel sync(); a retry is busy until it returns.
final class GuestFileSystemSynchronizer: @unchecked Sendable {
    static let shared = GuestFileSystemSynchronizer()
    private let lock = NSLock()
    private let performSync: @Sendable () throws -> Void

    init(performSync: @escaping @Sendable () throws -> Void = { Darwin.sync() }) {
        self.performSync = performSync
    }

    func synchronize(_ request: MacOSGuestFileSystemSyncRequest) throws -> MacOSGuestFileSystemSyncResult {
        guard request.isValid else { throw POSIXError(.EINVAL) }
        guard lock.try() else { throw POSIXError(.EBUSY) }
        defer { lock.unlock() }
        // Do not cache completed IDs: a second call must flush intervening writes.
        try performSync()
        return .init(requestID: request.requestID)
    }
}
