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

#if os(Linux)
import Glibc
#else
import Darwin
#endif

func readVMNetRecoveryRegularFile(
    descriptor: Int32,
    maximumSize: Int,
    description: String
) throws -> Data {
    var information = stat()
    guard fstat(descriptor, &information) == 0 else {
        throw VMNetRecoveryStateError.io("failed to inspect \(description): errno \(errno)")
    }
    guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
        throw VMNetRecoveryStateError.invalidValue("\(description) must be a regular file")
    }
    guard information.st_size > 0, information.st_size <= maximumSize else {
        throw VMNetRecoveryStateError.invalidValue("\(description) has an invalid size")
    }

    var result = Data()
    result.reserveCapacity(Int(information.st_size))
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR {
                continue
            }
            throw VMNetRecoveryStateError.io("failed to read \(description): errno \(errno)")
        }
        guard result.count + count <= maximumSize else {
            throw VMNetRecoveryStateError.invalidValue("\(description) exceeds the size limit")
        }
        result.append(contentsOf: buffer.prefix(count))
    }
    guard !result.isEmpty else {
        throw VMNetRecoveryStateError.invalidValue("\(description) is empty")
    }
    return result
}
