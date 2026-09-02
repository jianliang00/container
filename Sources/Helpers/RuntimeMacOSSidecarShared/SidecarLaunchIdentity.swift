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

public enum MacOSSidecarLaunchIdentity {
    public static func launchLabel(sandboxID: String, persistenceID: String?) -> String {
        if let persistenceID {
            return "com.apple.container.runtime.container-runtime-macos-sidecar.state.\(persistenceID)"
        }
        return "com.apple.container.runtime.container-runtime-macos-sidecar.\(sandboxID)"
    }

    public static func launchdDomain(effectiveUserID: UInt32) -> String {
        if effectiveUserID == 0 {
            return "user/0"
        }
        return "gui/\(effectiveUserID)"
    }

    public static func fullLaunchLabel(
        sandboxID: String,
        persistenceID: String?,
        effectiveUserID: UInt32
    ) -> String {
        "\(launchdDomain(effectiveUserID: effectiveUserID))/\(launchLabel(sandboxID: sandboxID, persistenceID: persistenceID))"
    }
}
