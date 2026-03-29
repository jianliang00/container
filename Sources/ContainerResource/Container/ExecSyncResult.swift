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

/// Captured result of a synchronous exec operation.
public struct ExecSyncResult: Sendable, Codable, Equatable {
    /// Exit code returned by the process.
    public var exitCode: Int32
    /// Captured stdout bytes.
    public var stdout: Data
    /// Captured stderr bytes.
    public var stderr: Data

    public init(
        exitCode: Int32,
        stdout: Data = Data(),
        stderr: Data = Data()
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}
