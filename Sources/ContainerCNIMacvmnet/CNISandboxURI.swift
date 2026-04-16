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

public struct CNISandboxURI: Equatable, CustomStringConvertible {
    public var rawValue: String
    public var sandboxID: String

    public var description: String {
        rawValue
    }

    public init(_ rawValue: String) throws {
        guard let components = URLComponents(string: rawValue),
            components.scheme == "macvmnet",
            components.host == "sandbox",
            components.query == nil,
            components.fragment == nil
        else {
            throw CNIError.invalidSandboxURI(rawValue)
        }

        let sandboxID = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !sandboxID.isEmpty, !sandboxID.contains("/") else {
            throw CNIError.invalidSandboxURI(rawValue)
        }

        self.rawValue = rawValue
        self.sandboxID = sandboxID
    }
}
