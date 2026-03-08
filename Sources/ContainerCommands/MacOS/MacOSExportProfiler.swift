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

enum MacOSExportProfiler {
    static let environmentKey = "CONTAINER_MACOS_EXPORT_PROFILE"

    static var isEnabled: Bool {
        guard let value = ProcessInfo.processInfo.environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return false
        }
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    static func log(_ message: String) {
        guard isEnabled else {
            return
        }
        try? FileHandle.standardError.write(contentsOf: Data("[macos-export] \(message)\n".utf8))
    }

    static func format(_ duration: TimeInterval) -> String {
        String(format: "%.2fs", duration)
    }
}
