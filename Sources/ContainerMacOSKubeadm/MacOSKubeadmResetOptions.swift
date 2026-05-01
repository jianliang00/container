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

public struct MacOSKubeadmResetOptions: Sendable, Equatable {
    public var installRoot: String
    public var purgeState: Bool
    public var force: Bool
    public var dryRun: Bool
    public var debug: Bool

    public init(
        installRoot: String = "/",
        purgeState: Bool = false,
        force: Bool = false,
        dryRun: Bool = false,
        debug: Bool = false
    ) {
        self.installRoot = installRoot
        self.purgeState = purgeState
        self.force = force
        self.dryRun = dryRun
        self.debug = debug
    }
}

extension MacOSKubeadmResetOptions {
    public var rootPrefix: String {
        let trimmed = installRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return ""
        }
        return "/" + trimmed
    }

    public func rooted(_ absolutePath: String) -> String {
        precondition(absolutePath.hasPrefix("/"), "path must be absolute")
        guard !rootPrefix.isEmpty else {
            return absolutePath
        }
        return rootPrefix + absolutePath
    }
}
