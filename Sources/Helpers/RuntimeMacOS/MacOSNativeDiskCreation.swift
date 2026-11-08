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

#if canImport(DiskImageKit)
import DiskImageKit
#endif

func createNativeASIFOverlay(base: URL, output: URL) throws {
    #if canImport(DiskImageKit)
    if #available(macOS 27, *) {
        var value = stat()
        guard lstat(output.path, &value) != 0, errno == ENOENT else { throw CocoaError(.fileWriteFileExists) }
        let disk = try DiskImage(opening: .open(url: base, mode: .readOnly))
        guard disk.format == .raw else { throw CocoaError(.fileReadCorruptFile) }
        let stack = try disk.appending(.asifLayer(url: output, type: .overlay))
        guard stack.layers.count == 2, stack.layers.last?.layerType == .overlay, stack.size == disk.size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return
    }
    #endif
    throw CocoaError(.featureUnsupported)
}
