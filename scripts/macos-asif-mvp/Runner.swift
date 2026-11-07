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

private func executeScript(_ fd: Int32, script: String, timeout: TimeInterval) throws -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    guard try readFrame(fd, deadline: Date().addingTimeInterval(15))["type"] as? String == "ready" else {
        throw ProbeFailure(message: "guest did not send ready frame")
    }
    report(["stage": "guestReady", "time": Date().timeIntervalSince1970])
    let id = UUID().uuidString
    let delimiter = "MVP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let wrapped = "/bin/sh <<'" + delimiter + "'\n" + script + "\n" + delimiter + "\nstatus=$?\n/bin/sync || exit 125\nexit \"$status\""
    let frame: [String: Any] = [
        "type": "exec", "id": id, "executable": "/bin/sh", "arguments": ["-c", wrapped],
        "environment": ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
        "workingDirectory": "/private/var/tmp", "terminal": false,
    ]
    let payload = try JSONSerialization.data(withJSONObject: frame)
    guard payload.count <= 32768 else { throw ProbeFailure(message: "script request exceeds 32 KiB") }
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
    var outputBytes = 0
    while true {
        let response = try readFrame(fd, deadline: deadline)
        // Legacy exec streams omit IDs. This connection owns exactly one exec;
        // accept absent IDs, but never a response attributed to another request.
        if let responseID = response["id"] as? String, responseID != id {
            throw ProbeFailure(message: "guest response ID mismatch")
        }
        switch response["type"] as? String {
        case "stdout", "stderr":
            guard let encoded = response["data"] as? String, let data = Data(base64Encoded: encoded) else {
                throw ProbeFailure(message: "invalid guest output")
            }
            outputBytes += data.count
            guard outputBytes <= 8 << 20 else { throw ProbeFailure(message: "guest output exceeds 8 MiB") }
            report(["stage": response["type"]!, "data": encoded, "time": Date().timeIntervalSince1970])
        case "error": throw ProbeFailure(message: "guest rejected command: \(response["message"] ?? "unknown error")")
        case "exit":
            guard let code = response["exitCode"] as? Int else { throw ProbeFailure(message: "missing exit status") }
            return code
        default: continue
        }
    }
}

private struct Configuration: Decodable {
    let backend: String
    let readOnly: [String]
    let writable: String
}

@available(macOS 27, *)
private func attachment(root: URL, config: Configuration, create: Bool) throws -> VZDiskImageStorageDeviceAttachment {
    if config.backend == "raw" {
        return try VZDiskImageStorageDeviceAttachment(url: root.appendingPathComponent(config.writable), readOnly: false)
    }
    guard config.backend == "asif", (1...2).contains(config.readOnly.count) else {
        throw ProbeFailure(message: "ASIF MVP requires one or two read-only layers")
    }
    let base = try DiskImage(opening: .open(url: root.appendingPathComponent(config.readOnly[0]), mode: .readOnly))
    let top = root.appendingPathComponent(config.writable)
    if config.readOnly.count == 1 {
        if create {
            return try VZDiskImageStorageDeviceAttachment(diskImage: base.appending(.asifLayer(url: top, type: .overlay)))
        }
        return try VZDiskImageStorageDeviceAttachment(diskImage: base.appending(DiskImage(opening: .open(url: top))))
    }
    let middle = try DiskImage(opening: .open(url: root.appendingPathComponent(config.readOnly[1]), mode: .readOnly))
    let parent = try base.appending(middle)
    if create {
        return try VZDiskImageStorageDeviceAttachment(diskImage: parent.appending(.asifLayer(url: top, type: .overlay)))
    }
    return try VZDiskImageStorageDeviceAttachment(diskImage: parent.appending(DiskImage(opening: .open(url: top))))
}

@available(macOS 27, *)
@MainActor
private func runVM(root: URL, config: Configuration, script: String) async throws {
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
    guard let freeBytes = attributes[.systemFreeSize] as? NSNumber, freeBytes.uint64Value >= 20 << 30 else {
        throw ProbeFailure(message: "test VM requires at least 20 GiB of free disk space")
    }
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
    configuration.cpuCount = 4
    configuration.memorySize = 8 << 30
    configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try attachment(root: root, config: config, create: false))]
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
        try await Task.sleep(nanoseconds: 1_500_000_000_000)
        report(["passed": false, "error": "VM command deadline exceeded; verify owned VM cleanup"])
        // Exiting releases this process's VZ instance, never another runtime's VM.
        exit(1)
    }
    defer { watchdog.cancel() }
    var result: Error?
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { continuation.resume(with: $0) }
        }
        report(["stage": "vmStarted", "cpuCount": 4, "memoryBytes": 8 << 30, "networkDevices": 0, "time": Date().timeIntervalSince1970])
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
            return try executeScript(fd, script: script, timeout: 1200)
        }.value
        report(["stage": "guestExit", "exitCode": verified])
        if verified != 0 { throw ProbeFailure(message: "guest command failed with exit code \(verified)") }
        // The wrapper waits for guest sync before stopping this owned VM.
    } catch { result = error }
    if vm.canStop {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vm.stop { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            report(["stage": "stopFailed", "error": String(describing: error)])
            if result == nil { result = error }
        }
    }
    report(["stage": "vmStopped", "stopped": vm.state == .stopped])
    if let result { throw result }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, ["create-overlay", "run", "new-identity"].contains(arguments[0]) else {
    report(["error": "usage: macos-asif-runner create-overlay|new-identity INSTANCE | run INSTANCE SCRIPT"])
    exit(1)
}
let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL
Task { @MainActor in
    do {
        guard #available(macOS 27, *) else { throw ProbeFailure(message: "macOS 27 or newer is required") }
        if arguments[0] == "new-identity" {
            try VZMacMachineIdentifier().dataRepresentation.write(to: root.appendingPathComponent("MachineIdentifier.bin"), options: .atomic)
        } else {
            let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: root.appendingPathComponent("runtime.json")))
            if arguments[0] == "create-overlay" {
                guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(config.writable).path) else {
                    throw ProbeFailure(message: "writable image already exists")
                }
                _ = try attachment(root: root, config: config, create: true)
                report(["stage": "overlayCreated"])
            } else {
                guard arguments.count == 3 else { throw ProbeFailure(message: "run requires a script") }
                let script = try String(contentsOfFile: arguments[2], encoding: .utf8)
                report(["stage": "starting", "time": Date().timeIntervalSince1970])
                try await runVM(root: root, config: config, script: script)
            }
        }
        exit(0)
    } catch {
        report(["passed": false, "error": (error as? ProbeFailure)?.message ?? String(describing: error)])
        exit(1)
    }
}
dispatchMain()
