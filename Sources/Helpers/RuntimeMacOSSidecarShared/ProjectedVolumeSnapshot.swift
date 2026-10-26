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

/// A complete Kubernetes AtomicWriter generation. Paths are relative to its data directory.
public struct ProjectedVolumeSnapshot: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let path: String
        public let data: Data?
        public let mode: UInt32
        public let uid: UInt32
        public let gid: UInt32

        public init(path: String, data: Data?, mode: UInt32, uid: UInt32, gid: UInt32) {
            self.path = path
            self.data = data
            self.mode = mode
            self.uid = uid
            self.gid = gid
        }
    }

    public let generation: String
    public let entries: [Entry]

    public init(generation: String, entries: [Entry]) {
        self.generation = generation
        self.entries = entries
    }

    public static func generation(at source: URL) throws -> String {
        let name = try FileManager.default.destinationOfSymbolicLink(atPath: source.appendingPathComponent("..data").path)
        guard name.hasPrefix(".."), name != "..", !name.contains("/") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return name
    }

    public static func capture(at source: URL) throws -> Self {
        let generation = try generation(at: source)
        let directory = source.appendingPathComponent(generation)
        var entries: [Entry] = []
        func visit(_ url: URL, relative: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                let child = url.appendingPathComponent(name)
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeDirectory else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                entries.append(
                    .init(
                        path: path,
                        data: type == .typeRegular ? try Data(contentsOf: child) : nil,
                        mode: (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644,
                        uid: (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0,
                        gid: (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0
                    ))
                if type == .typeDirectory { try visit(child, relative: path) }
            }
        }
        try visit(directory, relative: "")
        // Kubelet may remove the old generation while it is being copied. Never publish a mixed or obsolete snapshot.
        guard try Self.generation(at: source) == generation else { throw CocoaError(.fileReadUnknown) }
        return .init(generation: generation, entries: entries)
    }
}
