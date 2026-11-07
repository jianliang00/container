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

import CryptoKit
import Darwin
import DiskImageKit
import Foundation
import Virtualization

private struct ProbeError: Error {
    let message: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError(message: message) }
}

private func emit(_ result: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}

private func checkedFile(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    try require(url.path == url.resolvingSymlinksInPath().path, "symlink paths are not supported")
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    try require(values.isRegularFile == true, "image must be a regular file")
    return url
}

@available(macOS 27, *)
private func overlay(base baseURL: URL, layer layerURL: URL, create: Bool) throws -> [String: Any] {
    let base = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
    let expectedSize = base.size
    let baseFormat = String(describing: base.format)
    let stack: any StackedImage
    if create {
        try require(!FileManager.default.fileExists(atPath: layerURL.path), "overlay already exists")
        stack = try base.appending(.asifLayer(url: layerURL, type: .overlay))
    } else {
        let layer = try DiskImage(opening: .open(url: layerURL))
        stack = try base.appending(layer)
    }
    try require(stack.layers.count == 2, "unexpected stack depth")
    try require(stack.size == expectedSize, "logical size changed")
    // Attachment construction is an API check; it does not boot a virtual machine.
    let attachment = try VZDiskImageStorageDeviceAttachment(diskImage: stack)
    let device = VZVirtioBlockDeviceConfiguration(attachment: attachment)
    let top = stack.layers[1]
    return [
        "schemaVersion": 1, "hostVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        "created": create, "layerCount": stack.layers.count, "logicalBytes": stack.size,
        "baseFormat": baseFormat, "overlayFormat": String(describing: top.format),
        "overlayType": String(describing: top.layerType),
        "overlayUUID": top.layerUUID?.uuidString ?? "", "parentUUID": top.parentUUID?.uuidString ?? "",
        "attachmentType": String(describing: type(of: device.attachment)), "vmStarted": false,
    ]
}

@available(macOS 27, *)
private func selfTest() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("native-overlay-probe-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appendingPathComponent("base.img")
    let layer = root.appendingPathComponent("overlay.asif")
    try Data("native-overlay-probe\n".utf8).write(to: base, options: .withoutOverwriting)
    let file = try FileHandle(forWritingTo: base)
    try file.truncate(atOffset: 64 << 20)
    try file.synchronize()
    try file.close()
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: base.path)
    let before = SHA256.hash(data: try Data(contentsOf: base))
    // Scope the first stack to release its file handles before reopening it.
    let created = try overlay(base: base, layer: layer, create: true)
    let reopened = try overlay(base: base, layer: layer, create: false)
    try require(SHA256.hash(data: try Data(contentsOf: base)) == before, "base image was modified")
    try require(!(created["overlayUUID"] as? String ?? "").isEmpty, "overlay UUID is missing")
    try require(created["overlayUUID"] as? String == reopened["overlayUUID"] as? String, "overlay identity changed on reopen")
    try FileManager.default.removeItem(at: root)
    try emit([
        "selfTestPassed": true, "create": created, "reopen": reopened,
        "baseUnchanged": true, "guestWritesTested": false, "performanceTested": false,
        "fixtureRemoved": !FileManager.default.fileExists(atPath: root.path),
    ])
}

do {
    guard #available(macOS 27, *) else { throw ProbeError(message: "macOS 27 or newer is required") }
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["self-test"] {
        try selfTest()
    } else if args.count == 3 && ["create-overlay", "inspect-overlay"].contains(args[0]) {
        let base = try checkedFile(args[1])
        let layer = URL(fileURLWithPath: args[2]).standardizedFileURL
        try require(layer.path == layer.resolvingSymlinksInPath().path, "symlink paths are not supported")
        if args[0] == "inspect-overlay" { _ = try checkedFile(args[2]) }
        try emit(overlay(base: base, layer: layer, create: args[0] == "create-overlay"))
    } else {
        throw ProbeError(message: "usage: native-overlay-probe self-test | create-overlay BASE NEW_OVERLAY | inspect-overlay BASE OVERLAY")
    }
} catch {
    let message = (error as? ProbeError)?.message ?? String(describing: error)
    try? emit(["passed": false, "error": message])
    exit(1)
}
