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

public protocol FlannelVTEPMACStoring: Sendable {
    func load() throws -> String?
    func loadOrCreate() throws -> String
}

public struct FlannelVTEPMACStore: FlannelVTEPMACStoring, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(path: String) {
        self.init(url: URL(fileURLWithPath: path))
    }

    public func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let value = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let normalized = FlannelVTEPMAC.normalize(value),
                FlannelVTEPMAC.isLocallyAdministeredUnicast(normalized)
            else {
                throw FlannelVXLANError.persistence("stored VTEP MAC at \(url.path) is invalid")
            }
            return normalized
        } catch let error as FlannelVXLANError {
            throw error
        } catch {
            throw FlannelVXLANError.persistence("failed to read VTEP MAC at \(url.path): \(error)")
        }
    }

    public func loadOrCreate() throws -> String {
        if let existing = try load() {
            return existing
        }

        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<6).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        bytes[0] = bytes[0] & 0xfe | 0x02
        let value = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")

        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("\(value)\n".utf8).write(to: temporaryURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            // A hard link publishes the complete file atomically while still
            // failing if another launchd instance created the destination.
            try FileManager.default.linkItem(at: temporaryURL, to: url)
            return value
        } catch {
            // Another launchd instance may have won the create race. Never
            // replace its MAC because peers can already have observed it.
            if let existing = try load() {
                return existing
            }
            throw FlannelVXLANError.persistence("failed to persist VTEP MAC at \(url.path): \(error)")
        }
    }
}
