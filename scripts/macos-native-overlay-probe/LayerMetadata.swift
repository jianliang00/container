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

func describe(_ image: DiskImage) -> [String: Any] {
    [
        "format": String(describing: image.format),
        "layerType": String(describing: image.layerType),
        "isRaw": image.format == .raw,
        "isASIF": image.format == .asif,
        "isOverlay": image.layerType == .overlay,
        "isCache": image.layerType == .cache,
    ]
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("asif-layer-metadata-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: root) }
let baseURL = root.appendingPathComponent("base.img")
FileManager.default.createFile(atPath: baseURL.path, contents: nil)
let file = try FileHandle(forWritingTo: baseURL)
try file.truncate(atOffset: 64 << 20)
try file.synchronize()
try file.close()
try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: baseURL.path)
var results: [String: Any] = [:]
for (name, type) in [("overlay", DiskImage.LayerType.overlay), ("cache", DiskImage.LayerType.cache)] {
    let layerURL = root.appendingPathComponent(name + ".asif")
    do {
        let base = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
        let stack = try base.appending(.asifLayer(url: layerURL, type: type))
        results[name + "-created"] = describe(stack.layers[1])
    }
    let base = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
    let layer = try DiskImage(opening: .open(url: layerURL))
    results[name + "-base"] = describe(base)
    results[name + "-opened"] = describe(layer)
    let stack = try base.appending(layer)
    results[name + "-appended"] = describe(stack.layers[1])
    results[name + "-original-after-append"] = describe(layer)
}
let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data + Data([10]))
