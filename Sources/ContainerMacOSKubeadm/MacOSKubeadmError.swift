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

public enum MacOSKubeadmError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case invalidInput(String)
    case preflightFailed(String)
    case commandFailed(command: String, status: Int32, output: String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .invalidInput(let message):
            "invalid input: \(message)"
        case .preflightFailed(let message):
            "preflight failed: \(message)"
        case .commandFailed(let command, let status, let output):
            "command failed with status \(status): \(command)\n\(output)"
        case .timedOut(let message):
            "timed out: \(message)"
        }
    }

    public var errorDescription: String? {
        description
    }
}
