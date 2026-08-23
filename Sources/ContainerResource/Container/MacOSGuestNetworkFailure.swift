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

public struct MacOSGuestNetworkFailure: Codable, Sendable, Equatable {
    public let reason: SandboxFailureReason
    public let network: String
    public let hostname: String
    public let observedAt: Date

    public init(
        reason: SandboxFailureReason,
        network: String,
        hostname: String,
        observedAt: Date = Date()
    ) {
        self.reason = reason
        self.network = network
        self.hostname = hostname
        self.observedAt = observedAt
    }
}

public enum MacOSGuestNetworkFailureStore {
    public static let filename = "macos-guest-network-failure.json"

    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(filename)
    }

    public static func load(from root: URL) throws -> MacOSGuestNetworkFailure? {
        let url = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONDecoder().decode(MacOSGuestNetworkFailure.self, from: Data(contentsOf: url))
    }

    public static func save(_ failure: MacOSGuestNetworkFailure, in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(failure).write(to: fileURL(root: root), options: .atomic)
    }

    public static func remove(from root: URL) throws {
        let url = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}
