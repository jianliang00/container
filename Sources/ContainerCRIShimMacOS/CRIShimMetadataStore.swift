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

public struct CRIShimMetadataSnapshot: Codable, Equatable, Sendable {
    public var sandboxes: [CRIShimSandboxMetadata]
    public var containers: [CRIShimContainerMetadata]

    public init(sandboxes: [CRIShimSandboxMetadata] = [], containers: [CRIShimContainerMetadata] = []) {
        self.sandboxes = sandboxes
        self.containers = containers
    }
}

public struct CRIShimSandboxMetadata: Codable, Equatable, Sendable, Identifiable, Hashable {
    public enum State: String, Codable, Sendable, Equatable {
        case pending
        case ready
        case running
        case stopped
        case released
    }

    public var id: String
    public var podUID: String?
    public var namespace: String?
    public var name: String?
    public var attempt: UInt32
    public var runtimeHandler: String
    public var sandboxImage: String
    public var network: String?
    public var labels: [String: String]
    public var annotations: [String: String]
    public var networkLeaseID: String?
    public var networkAttachments: [String]
    public var state: State
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        podUID: String? = nil,
        namespace: String? = nil,
        name: String? = nil,
        attempt: UInt32 = 0,
        runtimeHandler: String,
        sandboxImage: String,
        network: String? = nil,
        labels: [String: String] = [:],
        annotations: [String: String] = [:],
        networkLeaseID: String? = nil,
        networkAttachments: [String] = [],
        state: State,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.podUID = podUID
        self.namespace = namespace
        self.name = name
        self.attempt = attempt
        self.runtimeHandler = runtimeHandler
        self.sandboxImage = sandboxImage
        self.network = network
        self.labels = labels
        self.annotations = annotations
        self.networkLeaseID = networkLeaseID
        self.networkAttachments = networkAttachments
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case podUID
        case namespace
        case name
        case attempt
        case runtimeHandler
        case sandboxImage
        case network
        case labels
        case annotations
        case networkLeaseID
        case networkAttachments
        case state
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            podUID: try container.decodeIfPresent(String.self, forKey: .podUID),
            namespace: try container.decodeIfPresent(String.self, forKey: .namespace),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            attempt: try container.decodeIfPresent(UInt32.self, forKey: .attempt) ?? 0,
            runtimeHandler: try container.decode(String.self, forKey: .runtimeHandler),
            sandboxImage: try container.decode(String.self, forKey: .sandboxImage),
            network: try container.decodeIfPresent(String.self, forKey: .network),
            labels: try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:],
            annotations: try container.decodeIfPresent([String: String].self, forKey: .annotations) ?? [:],
            networkLeaseID: try container.decodeIfPresent(String.self, forKey: .networkLeaseID),
            networkAttachments: try container.decodeIfPresent([String].self, forKey: .networkAttachments) ?? [],
            state: try container.decode(State.self, forKey: .state),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(podUID, forKey: .podUID)
        try container.encodeIfPresent(namespace, forKey: .namespace)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(attempt, forKey: .attempt)
        try container.encode(runtimeHandler, forKey: .runtimeHandler)
        try container.encode(sandboxImage, forKey: .sandboxImage)
        try container.encodeIfPresent(network, forKey: .network)
        try container.encode(labels, forKey: .labels)
        try container.encode(annotations, forKey: .annotations)
        try container.encodeIfPresent(networkLeaseID, forKey: .networkLeaseID)
        try container.encode(networkAttachments, forKey: .networkAttachments)
        try container.encode(state, forKey: .state)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public var reconcileFingerprint: String {
        fingerprintSegments.joined(separator: "\u{1f}")
    }

    private var fingerprintSegments: [String] {
        [
            id,
            podUID ?? "",
            namespace ?? "",
            name ?? "",
            String(attempt),
            runtimeHandler,
            sandboxImage,
            network ?? "",
            canonicalDictionaryString(labels),
            canonicalDictionaryString(annotations),
            networkLeaseID ?? "",
            networkAttachments.sorted().joined(separator: ","),
        ]
    }
}

public struct CRIShimContainerMetadata: Codable, Equatable, Sendable, Identifiable, Hashable {
    public enum State: String, Codable, Sendable, Equatable {
        case created
        case running
        case exited
        case removed
    }

    public var id: String
    public var sandboxID: String
    public var name: String
    public var attempt: UInt32
    public var image: String
    public var runtimeHandler: String
    public var labels: [String: String]
    public var annotations: [String: String]
    public var command: [String]
    public var args: [String]
    public var workingDirectory: String?
    public var logPath: String?
    public var state: State
    public var createdAt: Date
    public var startedAt: Date?
    public var exitedAt: Date?

    public init(
        id: String,
        sandboxID: String,
        name: String,
        attempt: UInt32 = 0,
        image: String,
        runtimeHandler: String,
        labels: [String: String] = [:],
        annotations: [String: String] = [:],
        command: [String] = [],
        args: [String] = [],
        workingDirectory: String? = nil,
        logPath: String? = nil,
        state: State,
        createdAt: Date,
        startedAt: Date? = nil,
        exitedAt: Date? = nil
    ) {
        self.id = id
        self.sandboxID = sandboxID
        self.name = name
        self.attempt = attempt
        self.image = image
        self.runtimeHandler = runtimeHandler
        self.labels = labels
        self.annotations = annotations
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.logPath = logPath
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.exitedAt = exitedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sandboxID
        case name
        case attempt
        case image
        case runtimeHandler
        case labels
        case annotations
        case command
        case args
        case workingDirectory
        case logPath
        case state
        case createdAt
        case startedAt
        case exitedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            sandboxID: try container.decode(String.self, forKey: .sandboxID),
            name: try container.decode(String.self, forKey: .name),
            attempt: try container.decodeIfPresent(UInt32.self, forKey: .attempt) ?? 0,
            image: try container.decode(String.self, forKey: .image),
            runtimeHandler: try container.decode(String.self, forKey: .runtimeHandler),
            labels: try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:],
            annotations: try container.decodeIfPresent([String: String].self, forKey: .annotations) ?? [:],
            command: try container.decodeIfPresent([String].self, forKey: .command) ?? [],
            args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
            workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
            logPath: try container.decodeIfPresent(String.self, forKey: .logPath),
            state: try container.decode(State.self, forKey: .state),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt),
            exitedAt: try container.decodeIfPresent(Date.self, forKey: .exitedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sandboxID, forKey: .sandboxID)
        try container.encode(name, forKey: .name)
        try container.encode(attempt, forKey: .attempt)
        try container.encode(image, forKey: .image)
        try container.encode(runtimeHandler, forKey: .runtimeHandler)
        try container.encode(labels, forKey: .labels)
        try container.encode(annotations, forKey: .annotations)
        try container.encode(command, forKey: .command)
        try container.encode(args, forKey: .args)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encodeIfPresent(logPath, forKey: .logPath)
        try container.encode(state, forKey: .state)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(exitedAt, forKey: .exitedAt)
    }

    public var reconcileFingerprint: String {
        fingerprintSegments.joined(separator: "\u{1f}")
    }

    private var fingerprintSegments: [String] {
        [
            id,
            sandboxID,
            name,
            String(attempt),
            image,
            runtimeHandler,
            canonicalDictionaryString(labels),
            canonicalDictionaryString(annotations),
            command.joined(separator: ","),
            args.joined(separator: ","),
            workingDirectory ?? "",
            logPath ?? "",
        ]
    }
}

public final class CRIShimMetadataStore {
    public let rootURL: URL
    private let sandboxStore: CRIShimEntityStore<CRIShimSandboxMetadata>
    private let containerStore: CRIShimEntityStore<CRIShimContainerMetadata>

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        let encoder = JSONEncoder.criShimMetadataEncoder
        let decoder = JSONDecoder.criShimMetadataDecoder
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let sandboxesURL = rootURL.appendingPathComponent("sandboxes", isDirectory: true)
        let containersURL = rootURL.appendingPathComponent("containers", isDirectory: true)
        try fileManager.createDirectory(at: sandboxesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: containersURL, withIntermediateDirectories: true)
        self.sandboxStore = CRIShimEntityStore(
            rootURL: sandboxesURL,
            kind: .sandbox,
            fileManager: fileManager,
            encoder: encoder,
            decoder: decoder
        )
        self.containerStore = CRIShimEntityStore(
            rootURL: containersURL,
            kind: .container,
            fileManager: fileManager,
            encoder: encoder,
            decoder: decoder
        )
    }

    public func snapshot() throws -> CRIShimMetadataSnapshot {
        CRIShimMetadataSnapshot(
            sandboxes: try sandboxStore.list(),
            containers: try containerStore.list()
        )
    }

    public func listSandboxes() throws -> [CRIShimSandboxMetadata] {
        try sandboxStore.list()
    }

    public func listContainers() throws -> [CRIShimContainerMetadata] {
        try containerStore.list()
    }

    public func sandbox(id: String) throws -> CRIShimSandboxMetadata? {
        try sandboxStore.retrieve(id: id)
    }

    public func container(id: String) throws -> CRIShimContainerMetadata? {
        try containerStore.retrieve(id: id)
    }

    public func upsertSandbox(_ metadata: CRIShimSandboxMetadata) throws {
        try sandboxStore.upsert(metadata)
    }

    public func upsertContainer(_ metadata: CRIShimContainerMetadata) throws {
        try containerStore.upsert(metadata)
    }

    public func deleteSandbox(id: String) throws {
        try sandboxStore.delete(id: id)
    }

    public func deleteContainer(id: String) throws {
        try containerStore.delete(id: id)
    }
}

private struct CRIShimEntityStore<T: Codable & Identifiable<String> & Sendable> where T.ID == String {
    let rootURL: URL
    let kind: CRIShimMetadataKind
    let fileManager: FileManager
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    func list() throws -> [T] {
        let entries = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var entities: [T] = []
        for entryURL in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let metadataURL = entityMetadataURL(id: entryURL.lastPathComponent)
            guard fileManager.fileExists(atPath: metadataURL.path) else {
                continue
            }
            do {
                let data = try Data(contentsOf: metadataURL)
                let entity = try decoder.decode(T.self, from: data)
                entities.append(entity)
            } catch {
                throw CRIShimMetadataStoreError.corruptedEntry(
                    kind: kind,
                    id: entryURL.lastPathComponent,
                    reason: String(describing: error)
                )
            }
        }
        return entities
    }

    func retrieve(id: String) throws -> T? {
        let metadataURL = entityMetadataURL(id: id)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: metadataURL)
        return try decoder.decode(T.self, from: data)
    }

    func upsert(_ entity: T) throws {
        let entityURL = entityURL(id: entity.id)
        try fileManager.createDirectory(at: entityURL, withIntermediateDirectories: true)
        let data = try encoder.encode(entity)
        try data.write(to: entityMetadataURL(id: entity.id), options: .atomic)
    }

    func delete(id: String) throws {
        let entityURL = entityURL(id: id)
        guard fileManager.fileExists(atPath: entityURL.path) else {
            throw CRIShimMetadataStoreError.notFound(kind: kind, id: id)
        }
        try fileManager.removeItem(at: entityURL)
    }

    private func entityURL(id: String) -> URL {
        rootURL.appendingPathComponent(id, isDirectory: true)
    }

    private func entityMetadataURL(id: String) -> URL {
        entityURL(id: id).appendingPathComponent("metadata.json", isDirectory: false)
    }
}

extension JSONEncoder {
    static var criShimMetadataEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(criShimMetadataDateString(from: date))
        }
        return encoder
    }
}

extension JSONDecoder {
    static var criShimMetadataDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = criShimMetadataDate(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO-8601 date: \(value)")
            }
            return date
        }
        return decoder
    }
}

private func canonicalDictionaryString(_ dictionary: [String: String]) -> String {
    dictionary.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
}

private func criShimMetadataDateString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func criShimMetadataDate(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: value)
}
