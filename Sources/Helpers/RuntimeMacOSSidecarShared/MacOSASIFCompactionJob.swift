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

/// Private detached compaction. The host storage owner prepares immutable clones
/// of base.img and parent-NN.asif. This job never opens an active VM for writing.
public enum MacOSASIFCompactionJob {
    public static let outputName = "merged.asif"
    private static let reserve = UInt64(40 << 30)

    private struct Stamp: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int

        init(_ url: URL) throws {
            var statValue = stat()
            guard lstat(url.path, &statValue) == 0, statValue.st_mode & S_IFMT == S_IFREG,
                statValue.st_mode & 0o222 == 0, statValue.st_uid == geteuid(), statValue.st_size > 0
            else { throw CocoaError(.fileReadCorruptFile) }
            device = statValue.st_dev
            inode = statValue.st_ino
            size = statValue.st_size
            modifiedSeconds = statValue.st_mtimespec.tv_sec
            modifiedNanos = statValue.st_mtimespec.tv_nsec
        }
    }

    private struct Journal: Codable {
        let inputs: [Stamp]
        let plan: String
        var completed: [String]
        var targetBase: Stamp?
        var verified: Stamp?
    }

    public static func run(directory: URL, parentCount: Int) throws {
        guard #available(macOS 27, *), (2...4).contains(parentCount) else { throw CocoaError(.featureUnsupported) }
        try MacOSLocalDiskBundle.validateDirectory(directory)
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        let lock = try file(directory.appendingPathComponent("compaction.lock"), O_RDWR | O_CREAT)
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        let base = directory.appendingPathComponent("base.img")
        let layers = (1...parentCount).map { directory.appendingPathComponent(String(format: "parent-%02d.asif", $0)) }
        let targetBase = directory.appendingPathComponent("target-base.img")
        let partial = directory.appendingPathComponent(".working.asif")
        let ready = directory.appendingPathComponent(outputName)
        let receipt = directory.appendingPathComponent("compaction.json")
        let inputs = try ([base] + layers).map(Stamp.init)
        let size = UInt64(inputs[0].size)
        try recover(base: base, size: size)
        try recover(base: targetBase, size: size)
        let plan = try MacOSASIFCompaction(layers: layers, logicalBytes: size, sparseBase: base)
        var journal = Journal(inputs: inputs, plan: plan.planDigest, completed: [], targetBase: nil, verified: nil)
        let fm = FileManager.default
        if fm.fileExists(atPath: receipt.path) {
            journal = try JSONDecoder().decode(Journal.self, from: MacOSLocalDiskBundle.readRegular(receipt, limit: 4 << 20))
            guard journal.inputs == inputs, journal.plan == plan.planDigest else { throw MacOSASIFCompaction.Failure.invalidCheckpoint }
        } else {
            guard !fm.fileExists(atPath: partial.path), !fm.fileExists(atPath: targetBase.path) else { throw CocoaError(.fileWriteFileExists) }
            try persist(journal, to: receipt)
        }
        if let verified = journal.verified {
            let published = fm.fileExists(atPath: ready.path)
            guard try Stamp(published ? ready : partial) == verified else { throw CocoaError(.fileReadCorruptFile) }
            if !published { try publish(partial, as: ready) }
            return
        }
        guard !fm.fileExists(atPath: ready.path) else { throw CocoaError(.fileWriteFileExists) }
        try checkCapacity(directory)
        if !fm.fileExists(atPath: targetBase.path) {
            guard journal.completed.isEmpty else { throw MacOSASIFCompaction.Failure.invalidCheckpoint }
            try MacOSLocalDiskBundle.cloneMember(base, to: targetBase)
            try MacOSLocalDiskBundle.synchronize(directory, directory: true)
        }
        let targetStamp = try Stamp(targetBase)
        guard targetStamp.size == inputs[0].size, targetStamp.inode != inputs[0].inode else { throw CocoaError(.fileReadCorruptFile) }
        if let recorded = journal.targetBase {
            guard recorded == targetStamp else { throw MacOSASIFCompaction.Failure.invalidCheckpoint }
        } else {
            guard journal.completed.isEmpty else { throw MacOSASIFCompaction.Failure.invalidCheckpoint }
            journal.targetBase = targetStamp
            try persist(journal, to: receipt)
        }
        if fm.fileExists(atPath: partial.path) {
            try MacOSLocalDiskBundle.validateNonemptyFile(partial)
            guard chmod(partial.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        } else if !journal.completed.isEmpty {
            throw MacOSASIFCompaction.Failure.invalidCheckpoint
        }
        let raw = try file(base, O_RDONLY)
        defer { close(raw) }
        _ = fcntl(raw, F_NOCACHE, 1)
        let completed = try withDevice(base: base, layers: layers, size: size, readOnly: true) { source in
            try withDevice(base: targetBase, layers: [partial], size: size, readOnly: false) { output in
                try plan.copy(base: raw, source: source, target: output, completed: journal.completed) { progress in
                    try checkCapacity(directory)
                    try fullSync(partial)
                    journal.completed = progress
                    try persist(journal, to: receipt)
                }
            }
        }
        try MacOSLocalDiskBundle.validateNonemptyFile(partial)
        guard chmod(partial.path, 0o400) == 0 else { throw POSIXError(.EIO) }
        try fullSync(partial)
        try plan.validateOutputRanges(partial)
        try withDevice(base: targetBase, layers: [partial], size: size, readOnly: true) { target in
            try plan.verify(target: target, expected: completed)
        }
        guard try ([base] + layers).map(Stamp.init) == inputs, try Stamp(targetBase) == targetStamp else {
            throw CocoaError(.fileReadCorruptFile)
        }
        journal.verified = try Stamp(partial)
        try persist(journal, to: receipt)
        try publish(partial, as: ready)
    }

    private static func file(_ url: URL, _ flags: Int32) throws -> Int32 {
        let fd = open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }

    private static func fullSync(_ url: URL) throws {
        let fd = try file(url, O_RDONLY)
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func checkCapacity(_ directory: URL) throws {
        let values = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let free = values[.systemFreeSize] as? NSNumber, free.uint64Value >= reserve else { throw POSIXError(.ENOSPC) }
    }

    private static func persist(_ journal: Journal, to url: URL) throws {
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        try MacOSLocalDiskBundle.synchronize(url)
        try MacOSLocalDiskBundle.synchronize(url.deletingLastPathComponent(), directory: true)
    }

    private static func publish(_ source: URL, as destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(.EIO) }
        try MacOSLocalDiskBundle.synchronize(destination.deletingLastPathComponent(), directory: true)
    }

    private static func withDevice<T>(base: URL, layers: [URL], size: UInt64, readOnly: Bool, _ body: (Int32) throws -> T) throws -> T {
        var arguments = ["image", "attach", "--noMount", "--plist"]
        if readOnly { arguments.append("--readOnly") }
        arguments.append(base.path)
        for layer in layers { arguments += ["--shadow", layer.path] }
        do {
            _ = try command("/usr/sbin/diskutil", arguments)
            guard let disk = try attachedDisk(base: base, size: size) else { throw CocoaError(.fileReadCorruptFile) }
            let device = URL(fileURLWithPath: "/dev/r" + disk.dropFirst("/dev/".count))
            let fd = try file(device, readOnly ? O_RDONLY : O_RDWR)
            let result: T
            do {
                defer { close(fd) }
                result = try body(fd)
            }
            try recover(base: base, size: size)
            return result
        } catch {
            try? recover(base: base, size: size)
            throw error
        }
    }

    private static func recover(base: URL, size: UInt64) throws {
        if let disk = try attachedDisk(base: base, size: size) {
            _ = try command("/usr/sbin/diskutil", ["eject", disk])
        }
    }

    private static func attachedDisk(base: URL, size: UInt64) throws -> String? {
        let state = try plist(command("/usr/bin/hdiutil", ["info", "-plist"]))
        guard let images = state["images"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        let owned = images.filter { $0["image-path"] as? String == base.path }
        guard !owned.isEmpty else { return nil }
        guard owned.count == 1, let entities = owned[0]["system-entities"] as? [[String: Any]],
            entities.allSatisfy({ ($0["mount-point"] as? String ?? "").isEmpty })
        else { throw CocoaError(.fileReadNoPermission) }
        var matches: [String] = []
        for entity in entities {
            guard let path = entity["dev-entry"] as? String, path.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil else {
                continue
            }
            let info = try plist(command("/usr/sbin/diskutil", ["info", "-plist", path]))
            if info["BusProtocol"] as? String == "Disk Image", info["Internal"] as? Bool == false,
                info["VirtualOrPhysical"] as? String == "Virtual", info["WholeDisk"] as? Bool == true,
                (info["Size"] as? NSNumber)?.uint64Value == size, (info["MountPoint"] as? String ?? "").isEmpty
            {
                matches.append(path)
            }
        }
        guard matches.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return matches[0]
    }

    private static func plist(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private static func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
        return data
    }
}
