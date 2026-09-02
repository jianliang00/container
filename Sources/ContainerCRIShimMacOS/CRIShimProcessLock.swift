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

final class CRIShimProcessLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    static func acquire(stateDirectory: String, effectiveUserID: uid_t = geteuid()) throws -> CRIShimProcessLock {
        let descriptor = open(stateDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CRIShimError.internalError("failed to open the CRI state directory process lock")
        }

        var value = stat()
        guard fstat(descriptor, &value) == 0,
            (value.st_mode & S_IFMT) == S_IFDIR,
            value.st_uid == effectiveUserID,
            value.st_mode & mode_t(0o022) == 0
        else {
            Darwin.close(descriptor)
            throw CRIShimError.internalError(
                "CRI state directory process lock has unsafe ownership, type, or permissions"
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK {
                throw CRIShimError.unavailable("another CRI shim process owns the state directory")
            }
            throw CRIShimError.internalError("failed to acquire the CRI state directory process lock")
        }
        return CRIShimProcessLock(descriptor: descriptor)
    }
}
