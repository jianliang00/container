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

import DiskImageKit
import Foundation

func checkImage(_ path: String) throws -> Bool {
    if #available(macOS 27, *) {
        let image = try DiskImage(opening: .open(url: URL(fileURLWithPath: path), mode: .readOnly))
        return image.format == .raw
    }
    return false
}

if CommandLine.arguments.count == 2 {
    print(try checkImage(CommandLine.arguments[1]))
} else {
    print("Load check")
}
