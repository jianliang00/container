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
import DiskImageKit
import Foundation
import Virtualization

private struct ProbeFailure: Error { let message: String }

private func report(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

private func readBytes(_ fd: Int32, count: Int, deadline: Date) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(count, 65536))
    while result.count < count {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw ProbeFailure(message: "guest frame timeout") }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
        if ready < 0 && errno == EINTR { continue }
        guard ready >= 0 else { throw ProbeFailure(message: "guest poll failed") }
        if ready == 0 { continue }
        let n = Darwin.read(fd, &buffer, min(buffer.count, count - result.count))
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw ProbeFailure(message: "guest socket closed") }
        result.append(contentsOf: buffer.prefix(n))
    }
    return result
}

private func readFrame(_ fd: Int32, deadline: Date) throws -> [String: Any] {
    let header = try readBytes(fd, count: 4, deadline: deadline)
    let count = header.reduce(0) { ($0 << 8) | Int($1) }
    guard count > 0, count <= 65536 else { throw ProbeFailure(message: "invalid guest frame size") }
    let data = try readBytes(fd, count: count, deadline: deadline)
    guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeFailure(message: "invalid guest frame")
    }
    return frame
}

private func executeMarker(_ fd: Int32, write: Bool, marker: String) throws -> String {
    let deadline = Date().addingTimeInterval(30)
    guard try readFrame(fd, deadline: deadline)["type"] as? String == "ready" else {
        throw ProbeFailure(message: "guest did not send ready frame")
    }
    let path = "/private/var/tmp/native-overlay-probe-" + marker
    let script =
        write
        ? "umask 077; printf '%s' '" + marker + "' > '" + path + "'; sync; cat '" + path + "'"
        : "cat '" + path + "'"
    let frame: [String: Any] = [
        "type": "exec", "id": UUID().uuidString, "executable": "/bin/sh",
        "arguments": ["-c", script], "environment": ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"],
        "workingDirectory": "/private/var/tmp", "terminal": false,
    ]
    let payload = try JSONSerialization.data(withJSONObject: frame)
    var length = UInt32(payload.count).bigEndian
    var bytes = withUnsafeBytes(of: &length) { Data($0) }
    bytes.append(payload)
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ProbeFailure(message: "guest request write failed") }
            offset += n
        }
    }
    var output = Data()
    while true {
        let response = try readFrame(fd, deadline: deadline)
        switch response["type"] as? String {
        case "stdout":
            guard let encoded = response["data"] as? String, let data = Data(base64Encoded: encoded), output.count + data.count <= 65536 else {
                throw ProbeFailure(message: "invalid guest output")
            }
            output.append(data)
        case "error": throw ProbeFailure(message: "guest rejected fixed marker command")
        case "exit":
            guard response["exitCode"] as? Int == 0, String(data: output, encoding: .utf8) == marker else {
                throw ProbeFailure(message: "guest marker verification failed")
            }
            return marker
        default: continue
        }
    }
}

@available(macOS 27, *)
@MainActor
private func runVM(root: URL, write: Bool, marker: String) async throws {
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
    guard let freeBytes = attributes[.systemFreeSize] as? NSNumber, freeBytes.uint64Value >= 20 << 30 else {
        throw ProbeFailure(message: "test VM requires at least 20 GiB of free disk space")
    }
    let base = try DiskImage(opening: .open(url: root.appendingPathComponent("base.img"), mode: .readOnly))
    let layer = try DiskImage(opening: .open(url: root.appendingPathComponent("overlay.asif")))
    let stacked = try base.appending(layer)
    let platform = VZMacPlatformConfiguration()
    guard let hardware = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: root.appendingPathComponent("HardwareModel.bin"))),
        let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: root.appendingPathComponent("MachineIdentifier.bin")))
    else { throw ProbeFailure(message: "invalid test VM identity") }
    platform.hardwareModel = hardware
    platform.machineIdentifier = identifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: root.appendingPathComponent("AuxiliaryStorage"))
    let configuration = VZVirtualMachineConfiguration()
    configuration.bootLoader = VZMacOSBootLoader()
    configuration.platform = platform
    configuration.cpuCount = 2
    configuration.memorySize = 4 << 30
    configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(diskImage: stacked))]
    configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1440, heightInPixels: 900, pixelsPerInch: 80)]
    configuration.graphicsDevices = [graphics]
    configuration.keyboards = [VZUSBKeyboardConfiguration()]
    configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    try configuration.validate()
    let vm = VZVirtualMachine(configuration: configuration)
    // Bound the standalone diagnostic even if a framework callback never arrives.
    let watchdog = Task { @MainActor in
        try await Task.sleep(nanoseconds: 240_000_000_000)
        report(["passed": false, "error": "VM probe deadline exceeded; verify owned VM cleanup"])
        // Exiting releases this process's VZ instance, never another runtime's VM.
        exit(1)
    }
    defer { watchdog.cancel() }
    var result: Error?
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { continuation.resume(with: $0) }
        }
        report(["stage": "vmStarted", "cpuCount": 2, "memoryBytes": 4 << 30, "networkDevices": 0])
        guard let socket = vm.socketDevices.first as? VZVirtioSocketDevice else { throw ProbeFailure(message: "missing socket device") }
        let deadline = Date().addingTimeInterval(180)
        var connection: VZVirtioSocketConnection?
        while connection == nil && Date() < deadline {
            do {
                connection = try await withCheckedThrowingContinuation { continuation in
                    socket.connect(toPort: 27000) { continuation.resume(with: $0) }
                }
            } catch { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        guard let connection else { throw ProbeFailure(message: "guest agent connection timeout") }
        defer { withExtendedLifetime(connection) {} }
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { throw ProbeFailure(message: "cannot duplicate guest connection") }
        let verified = try await Task.detached {
            defer { Darwin.close(fd) }
            var enabled: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            return try executeMarker(fd, write: write, marker: marker)
        }.value
        report(["stage": "guestMarkerVerified", "write": write, "marker": verified])
    } catch { result = error }
    if vm.state != .stopped {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.stop { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    report(["stage": "vmStopped", "stopped": vm.state == .stopped])
    if let result { throw result }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, ["write", "read"].contains(arguments[1]), UUID(uuidString: arguments[2]) != nil else {
    report(["error": "usage: native-overlay-vm-probe PRIVATE_FIXTURE_DIR write|read UUID"])
    exit(1)
}
let fixture = URL(fileURLWithPath: arguments[0]).standardizedFileURL
guard fixture.path == fixture.resolvingSymlinksInPath().path else {
    report(["error": "fixture path must be canonical"])
    exit(1)
}
for name in ["base.img", "overlay.asif", "HardwareModel.bin", "MachineIdentifier.bin", "AuxiliaryStorage"] {
    let file = fixture.appendingPathComponent(name)
    guard file.path == file.resolvingSymlinksInPath().path,
        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else {
        report(["error": "fixture requires regular non-symlink image and identity files"])
        exit(1)
    }
}
Task { @MainActor in
    do {
        if #available(macOS 27, *) {
            try await runVM(root: fixture, write: arguments[1] == "write", marker: arguments[2])
            exit(0)
        }
        throw ProbeFailure(message: "macOS 27 or newer is required")
    } catch {
        report(["passed": false, "error": (error as? ProbeFailure)?.message ?? String(describing: error)])
        exit(1)
    }
}
dispatchMain()
