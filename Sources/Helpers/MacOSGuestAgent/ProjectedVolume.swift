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
import Foundation
import RuntimeMacOSSidecarShared

/// Builds generations off-path and publishes one directory link, so key additions and deletions switch together.
enum GuestAgentProjectedVolume {
    static func publish(_ snapshot: ProjectedVolumeSnapshot, at destination: URL, storeRoot: URL = URL(fileURLWithPath: "/private/var/run/container-projected-volumes")) throws {
        let fm = FileManager.default
        let key = SHA256.hash(data: Data(destination.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let store = storeRoot.appendingPathComponent(key)
        let current = store.appendingPathComponent("current")
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.path)
        let generation = store.appendingPathComponent("generation-" + UUID().uuidString)
        try fm.createDirectory(at: generation, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? removeGeneration(generation) } }

        var paths: Set<String> = []
        for entry in snapshot.entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                !entry.path.contains("\0"), paths.insert(entry.path).inserted
            else { throw POSIXError(.EINVAL) }
            let url = generation.appendingPathComponent(entry.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = entry.data {
                try data.write(to: url)
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            }
        }
        // Apply metadata before publication and make entries immutable to enforce read-only access, including root writes.
        for entry in snapshot.entries.reversed() {
            let path = generation.appendingPathComponent(entry.path).path
            guard chown(path, entry.uid, entry.gid) == 0, chmod(path, mode_t(entry.mode & 0o777)) == 0, chflags(path, UInt32(UF_IMMUTABLE)) == 0 else {
                throw POSIXError.fromErrno()
            }
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: generation.path)
        guard chflags(generation.path, UInt32(UF_IMMUTABLE)) == 0 else { throw POSIXError.fromErrno() }

        let existingTarget = try? fm.destinationOfSymbolicLink(atPath: destination.path)
        if let existingTarget {
            guard existingTarget == current.path else { throw POSIXError(.EEXIST) }
        } else if fm.fileExists(atPath: destination.path) {
            // Initial mount points may be empty directories from the workload image.
            guard (try fm.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType) == .typeDirectory,
                try fm.contentsOfDirectory(atPath: destination.path).isEmpty
            else { throw POSIXError(.EEXIST) }
            try fm.removeItem(at: destination)
        }

        let previous = try? fm.destinationOfSymbolicLink(atPath: current.path)
        let next = store.appendingPathComponent("next-" + UUID().uuidString)
        defer { try? fm.removeItem(at: next) }
        try fm.createSymbolicLink(atPath: next.path, withDestinationPath: generation.lastPathComponent)
        guard rename(next.path, current.path) == 0 else { throw POSIXError.fromErrno() }
        published = true
        if existingTarget == nil {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: current.path)
        }
        // Keep the previous generation for readers already resolving it. Open file descriptors remain valid after unlink.
        for name in try fm.contentsOfDirectory(atPath: store.path) where name.hasPrefix("generation-") && name != generation.lastPathComponent && name != previous {
            try removeGeneration(store.appendingPathComponent(name))
        }
    }

    static func removeGeneration(_ directory: URL) throws {
        // Only runtime-owned generation directories reach this cleanup path.
        func unlock(_ url: URL) throws {
            guard chflags(url.path, 0) == 0 else { throw POSIXError.fromErrno() }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                guard chmod(url.path, 0o700) == 0 else { throw POSIXError.fromErrno() }
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try unlock(child) }
            }
        }
        try unlock(directory)
        try FileManager.default.removeItem(at: directory)
    }

}
