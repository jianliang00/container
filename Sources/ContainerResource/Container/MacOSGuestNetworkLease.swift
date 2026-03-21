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

public struct MacOSGuestNetworkLease: Codable, Sendable, Equatable {
    public struct Interface: Codable, Sendable, Equatable {
        public let backend: ContainerConfiguration.MacOSGuestOptions.NetworkBackend
        public let attachment: Attachment

        public init(
            backend: ContainerConfiguration.MacOSGuestOptions.NetworkBackend,
            attachment: Attachment
        ) {
            self.backend = backend
            self.attachment = attachment
        }
    }

    public let interfaces: [Interface]

    public init(interfaces: [Interface]) {
        self.interfaces = interfaces
    }

    public var attachments: [Attachment] {
        interfaces.map(\.attachment)
    }
}

public enum MacOSGuestNetworkLeaseStore {
    public static let filename = "macos-guest-network-lease.json"

    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(filename)
    }

    public static func load(from root: URL) throws -> MacOSGuestNetworkLease? {
        let leaseURL = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: leaseURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: leaseURL)
        return try JSONDecoder().decode(MacOSGuestNetworkLease.self, from: data)
    }

    public static func save(_ lease: MacOSGuestNetworkLease, in root: URL) throws {
        let data = try JSONEncoder().encode(lease)
        try data.write(to: fileURL(root: root))
    }

    public static func remove(from root: URL) throws {
        let leaseURL = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: leaseURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: leaseURL)
    }
}
