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

public enum FilesystemClone {
    public typealias CloneFunction = @Sendable (_ src: UnsafePointer<CChar>?, _ dst: UnsafePointer<CChar>?, _ flags: UInt32) -> Int32

    public enum Result: Equatable {
        case cloned
        case copied
    }

    @discardableResult
    public static func cloneOrCopyItem(
        at source: URL,
        to destination: URL,
        cloneImpl: CloneFunction = Darwin.clonefile
    ) throws -> Result {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let cloneSucceeded: Bool = source.path.withCString { src in
            destination.path.withCString { dst in
                cloneImpl(src, dst, 0) == 0
            }
        }
        if cloneSucceeded {
            return .cloned
        }

        try fm.copyItem(at: source, to: destination)
        return .copied
    }
}
