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

public enum MacvmnetAttachmentLedgerDefaults {
    public static let defaultRootURL = URL(fileURLWithPath: "/var/lib/container/cni/macvmnet")
}

public struct MacvmnetAttachmentRecord: Codable, Equatable, Sendable {
    public var identity: MacvmnetAttachmentIdentity
    public var networkName: String
    public var result: CNIResult

    public init(identity: MacvmnetAttachmentIdentity, networkName: String, result: CNIResult) {
        self.identity = identity
        self.networkName = networkName
        self.result = result
    }
}

public protocol MacvmnetAttachmentLedger: Sendable {
    func upsert(_ record: MacvmnetAttachmentRecord) throws
    func remove(identity: MacvmnetAttachmentIdentity, networkName: String) throws
    func records(networkName: String) throws -> [MacvmnetAttachmentRecord]
}

public final class FileMacvmnetAttachmentLedger: MacvmnetAttachmentLedger, @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootURL: URL = MacvmnetAttachmentLedgerDefaults.defaultRootURL,
        fileManager: FileManager = .default,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.encoder = encoder
        self.decoder = decoder
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    public func upsert(_ record: MacvmnetAttachmentRecord) throws {
        let directory = networkDirectory(networkName: record.networkName)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: recordURL(identity: record.identity, networkName: record.networkName), options: .atomic)
    }

    public func remove(identity: MacvmnetAttachmentIdentity, networkName: String) throws {
        let url = recordURL(identity: identity, networkName: networkName)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    public func records(networkName: String) throws -> [MacvmnetAttachmentRecord] {
        let directory = networkDirectory(networkName: networkName)
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var records: [MacvmnetAttachmentRecord] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
                continue
            }
            let data = try Data(contentsOf: entry)
            records.append(try decoder.decode(MacvmnetAttachmentRecord.self, from: data))
        }
        return records
    }

    private func networkDirectory(networkName: String) -> URL {
        rootURL.appendingPathComponent(escapedPathComponent(networkName), isDirectory: true)
    }

    private func recordURL(identity: MacvmnetAttachmentIdentity, networkName: String) -> URL {
        networkDirectory(networkName: networkName)
            .appendingPathComponent(
                "\(escapedPathComponent(identity.containerID))--\(escapedPathComponent(identity.ifName)).json",
                isDirectory: false
            )
    }
}

private func escapedPathComponent(_ value: String) -> String {
    var allowedCharacters = CharacterSet.alphanumerics
    allowedCharacters.insert(charactersIn: "._-")
    return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
}
