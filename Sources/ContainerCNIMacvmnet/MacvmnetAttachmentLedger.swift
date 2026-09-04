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

public enum MacvmnetAttachmentLedgerDefaults {
    public static let defaultRootURL = URL(fileURLWithPath: "/var/lib/container/cni/macvmnet")
}

public struct MacvmnetAttachmentRecord: Codable, Equatable, Sendable {
    public var identity: MacvmnetAttachmentIdentity
    public var owner: MacvmnetAttachmentOwner?
    public var networkName: String
    public var result: CNIResult

    public init(
        identity: MacvmnetAttachmentIdentity,
        owner: MacvmnetAttachmentOwner? = nil,
        networkName: String,
        result: CNIResult
    ) {
        self.identity = identity
        self.owner = owner
        self.networkName = networkName
        self.result = result
    }
}

public protocol MacvmnetAttachmentOperationLock: Sendable {
    func unlock()
}

public protocol MacvmnetAttachmentLedger: Sendable {
    func acquireOperationLock(
        identity: MacvmnetAttachmentIdentity,
        networkName: String
    ) throws -> any MacvmnetAttachmentOperationLock
    func upsert(_ record: MacvmnetAttachmentRecord) throws
    func record(identity: MacvmnetAttachmentIdentity, networkName: String) throws -> MacvmnetAttachmentRecord?
    @discardableResult
    func remove(
        identity: MacvmnetAttachmentIdentity,
        networkName: String,
        owner: MacvmnetAttachmentOwner?
    ) throws -> Bool
    func records(networkName: String) throws -> [MacvmnetAttachmentRecord]
}

public final class FileMacvmnetAttachmentLedger: MacvmnetAttachmentLedger, @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

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

    public func acquireOperationLock(
        identity: MacvmnetAttachmentIdentity,
        networkName: String
    ) throws -> any MacvmnetAttachmentOperationLock {
        let directory = networkDirectory(networkName: networkName)
            .appendingPathComponent(".locks", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(
            "\(escapedPathComponent(identity.containerID))--\(escapedPathComponent(identity.ifName)).lock",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CNIError.backendUnavailable(
                "failed to open attachment lock \(lockURL.path): \(Self.posixErrorDescription())"
            )
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            let message = Self.posixErrorDescription()
            Darwin.close(descriptor)
            throw CNIError.backendUnavailable(
                "failed to secure attachment lock \(lockURL.path): \(message)"
            )
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                let message = Self.posixErrorDescription()
                Darwin.close(descriptor)
                throw CNIError.backendUnavailable(
                    "failed to acquire attachment lock \(lockURL.path): \(message)"
                )
            }
        }
        return FileMacvmnetAttachmentOperationLock(descriptor: descriptor)
    }

    public func upsert(_ record: MacvmnetAttachmentRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        let directory = networkDirectory(networkName: record.networkName)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: recordURL(identity: record.identity, networkName: record.networkName), options: .atomic)
    }

    public func record(
        identity: MacvmnetAttachmentIdentity,
        networkName: String
    ) throws -> MacvmnetAttachmentRecord? {
        lock.lock()
        defer { lock.unlock() }
        let url = recordURL(identity: identity, networkName: networkName)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try decoder.decode(MacvmnetAttachmentRecord.self, from: Data(contentsOf: url))
    }

    @discardableResult
    public func remove(
        identity: MacvmnetAttachmentIdentity,
        networkName: String,
        owner: MacvmnetAttachmentOwner?
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let url = recordURL(identity: identity, networkName: networkName)
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        let record = try decoder.decode(MacvmnetAttachmentRecord.self, from: Data(contentsOf: url))
        guard record.owner == owner else {
            return false
        }
        try fileManager.removeItem(at: url)
        return true
    }

    public func records(networkName: String) throws -> [MacvmnetAttachmentRecord] {
        lock.lock()
        defer { lock.unlock() }
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

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}

private final class FileMacvmnetAttachmentOperationLock:
    MacvmnetAttachmentOperationLock,
    @unchecked Sendable
{
    private let stateLock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        unlock()
    }

    func unlock() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else {
            return
        }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}

private func escapedPathComponent(_ value: String) -> String {
    var allowedCharacters = CharacterSet.alphanumerics
    allowedCharacters.insert(charactersIn: "._-")
    return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
}
