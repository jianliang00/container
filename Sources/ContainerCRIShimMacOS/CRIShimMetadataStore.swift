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
            state.rawValue,
        ]
    }

    fileprivate func mergingMonotonically(with incoming: CRIShimSandboxMetadata) -> CRIShimSandboxMetadata {
        guard state.lifecycleRank <= incoming.state.lifecycleRank else {
            return self
        }
        var merged = incoming
        merged.createdAt = createdAt
        merged.updatedAt = max(updatedAt, incoming.updatedAt)
        return merged
    }
}

extension CRIShimSandboxMetadata.State {
    var lifecycleRank: Int {
        switch self {
        case .pending:
            0
        case .ready:
            1
        case .running:
            2
        case .stopped:
            3
        case .released:
            4
        }
    }
}

public struct CRIShimContainerMetadata: Codable, Equatable, Sendable, Identifiable, Hashable {
    public enum State: String, Codable, Sendable, Equatable {
        case created
        case running
        case exited
        case removed
    }

    public enum ExitStatusSource: String, Codable, Sendable, Equatable {
        case unknown
        case runtime
    }

    public enum ExitTimeSource: String, Codable, Sendable, Equatable {
        case observed
        case runtime
    }

    static let unknownExitCode: Int32 = 255
    static let unknownExitReason = "ContainerStatusUnknown"
    static let unknownExitMessage = "The runtime did not report complete container exit status."

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
    public var exitCode: Int32?
    public var reason: String?
    public var message: String?
    public var exitStatusSource: ExitStatusSource?
    public var exitTimeSource: ExitTimeSource?
    public var lifecycleVersion: UInt64

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
        exitedAt: Date? = nil,
        exitCode: Int32? = nil,
        reason: String? = nil,
        message: String? = nil,
        exitStatusSource: ExitStatusSource? = nil,
        exitTimeSource: ExitTimeSource? = nil,
        lifecycleVersion: UInt64 = 0
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
        self.exitCode = exitCode
        self.reason = reason
        self.message = message
        self.exitStatusSource = exitStatusSource
        self.exitTimeSource = exitTimeSource
        self.lifecycleVersion = lifecycleVersion
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
        case exitCode
        case reason
        case message
        case exitStatusSource
        case exitTimeSource
        case lifecycleVersion
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
            exitedAt: try container.decodeIfPresent(Date.self, forKey: .exitedAt),
            exitCode: try container.decodeIfPresent(Int32.self, forKey: .exitCode),
            reason: try container.decodeIfPresent(String.self, forKey: .reason),
            message: try container.decodeIfPresent(String.self, forKey: .message),
            exitStatusSource: try container.decodeIfPresent(ExitStatusSource.self, forKey: .exitStatusSource),
            exitTimeSource: try container.decodeIfPresent(ExitTimeSource.self, forKey: .exitTimeSource),
            lifecycleVersion: try container.decodeIfPresent(UInt64.self, forKey: .lifecycleVersion) ?? 0
        )
        normalizeTerminalStatus(observedAt: exitedAt ?? startedAt ?? createdAt)
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
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(exitStatusSource, forKey: .exitStatusSource)
        try container.encodeIfPresent(exitTimeSource, forKey: .exitTimeSource)
        try container.encode(lifecycleVersion, forKey: .lifecycleVersion)
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
            state.rawValue,
            startedAt.map(criShimMetadataDateString(from:)) ?? "",
            exitedAt.map(criShimMetadataDateString(from:)) ?? "",
            exitCode.map { String($0) } ?? "",
            reason ?? "",
            message ?? "",
            exitStatusSource?.rawValue ?? "",
            exitTimeSource?.rawValue ?? "",
        ]
    }

    mutating func recordUnknownExit(
        at observedAt: Date,
        message: String = CRIShimContainerMetadata.unknownExitMessage
    ) {
        state = state == .removed ? .removed : .exited
        inferExitStatusSourceIfNeeded()
        recordObservedExitTimeIfNeeded(at: observedAt)
        guard exitStatusSource != .runtime || exitCode == nil else {
            return
        }
        exitCode = Self.unknownExitCode
        reason = Self.unknownExitReason
        self.message = self.message ?? message
        exitStatusSource = .unknown
    }

    mutating func recordRuntimeExit(
        code: Int32,
        at exitedAt: Date?,
        observedAt: Date
    ) {
        state = state == .removed ? .removed : .exited
        inferExitStatusSourceIfNeeded()

        let shouldReplaceStatus =
            exitStatusSource != .runtime
            || exitCode == nil
            || (exitCode == 0 && code != 0)
        let replacesRuntimeStatus = shouldReplaceStatus && exitStatusSource == .runtime
        if replacesRuntimeStatus, (exitedAt?.timeIntervalSince1970 ?? 0) <= 0 {
            self.exitedAt = Self.validTerminalTime(nil, fallback: observedAt)
            exitTimeSource = .observed
        } else {
            recordRuntimeExitTimeIfAvailable(
                exitedAt,
                observedAt: observedAt,
                replaceRuntimeTime: replacesRuntimeStatus
            )
        }
        guard shouldReplaceStatus else {
            return
        }

        exitCode = code
        reason = code == 0 ? "Completed" : "Error"
        message = code == 0 ? "Container exited normally." : "Container exited with code \(code)."
        exitStatusSource = .runtime
    }

    func normalizedTerminalStatus(observedAt: Date? = nil) -> CRIShimContainerMetadata {
        var metadata = self
        metadata.normalizeTerminalStatus(observedAt: observedAt ?? terminalObservationFallback)
        return metadata
    }

    func mergingMonotonically(with incoming: CRIShimContainerMetadata) -> CRIShimContainerMetadata {
        var current = self
        current.normalizeTerminalStatus(observedAt: current.terminalObservationFallback)
        var merged = incoming
        merged.normalizeTerminalStatus(observedAt: merged.terminalObservationFallback)

        let lifecycleAdvanced = merged.state.lifecycleRank > current.state.lifecycleRank
        merged.createdAt = current.createdAt
        if lifecycleAdvanced || (current.state == .running && incoming.state == .running) {
            merged.startedAt = merged.startedAt ?? current.startedAt
        } else {
            merged.startedAt = current.startedAt ?? merged.startedAt
        }
        if current.state.lifecycleRank > merged.state.lifecycleRank {
            merged.state = current.state
        }
        merged.mergeExitStatus(from: current)
        merged.mergeExitTime(from: current)

        let previousVersion = max(current.lifecycleVersion, incoming.lifecycleVersion)
        merged.lifecycleVersion = previousVersion
        if merged.lifecycleFields != current.lifecycleFields {
            merged.lifecycleVersion = previousVersion == .max ? .max : previousVersion + 1
        }
        return merged
    }

    fileprivate mutating func normalizeTerminalStatus(observedAt: Date) {
        guard state.isTerminal else {
            return
        }
        if exitCode == nil {
            recordUnknownExit(at: observedAt)
            return
        }

        inferExitStatusSourceIfNeeded()
        recordObservedExitTimeIfNeeded(at: observedAt)
        if reason == nil {
            reason = exitStatusSource == .unknown ? Self.unknownExitReason : (exitCode == 0 ? "Completed" : "Error")
        }
        if message == nil {
            if exitStatusSource == .unknown {
                message = Self.unknownExitMessage
            } else if let exitCode {
                message = exitCode == 0 ? "Container exited normally." : "Container exited with code \(exitCode)."
            }
        }
    }

    private mutating func mergeExitStatus(from current: CRIShimContainerMetadata) {
        guard current.state.isTerminal || state.isTerminal else {
            return
        }

        let currentPrecedence = current.exitStatusSource.precedence
        let incomingPrecedence = exitStatusSource.precedence
        if currentPrecedence > incomingPrecedence
            || (currentPrecedence == incomingPrecedence && shouldPreserveExitCode(current.exitCode, over: exitCode))
        {
            exitCode = current.exitCode ?? exitCode
            reason = current.reason ?? reason
            message = current.message ?? message
            exitStatusSource = current.exitStatusSource ?? exitStatusSource
        }
    }

    private mutating func mergeExitTime(from current: CRIShimContainerMetadata) {
        guard current.state.isTerminal || state.isTerminal else {
            return
        }

        let currentPrecedence = current.exitTimeSource.precedence
        let incomingPrecedence = exitTimeSource.precedence
        let runtimeFailureReplacesSuccess =
            current.exitStatusSource == .runtime
            && current.exitCode == 0
            && exitStatusSource == .runtime
            && exitCode != nil
            && exitCode != 0
        if !runtimeFailureReplacesSuccess,
            currentPrecedence >= incomingPrecedence
        {
            exitedAt = current.exitedAt ?? exitedAt
            exitTimeSource = current.exitTimeSource ?? exitTimeSource
        }
    }

    fileprivate var terminalObservationFallback: Date {
        if let exitedAt, exitedAt.timeIntervalSince1970 > 0 {
            return exitedAt
        }
        if let startedAt, startedAt.timeIntervalSince1970 > 0 {
            return startedAt
        }
        if createdAt.timeIntervalSince1970 > 0 {
            return createdAt
        }
        return Date()
    }

    private static func validTerminalTime(_ date: Date?, fallback: Date) -> Date {
        if let date, date.timeIntervalSince1970 > 0 {
            return date
        }
        if fallback.timeIntervalSince1970 > 0 {
            return fallback
        }
        return Date()
    }

    private mutating func inferExitStatusSourceIfNeeded() {
        guard exitStatusSource == nil, let exitCode else {
            return
        }
        exitStatusSource = exitCode == Self.unknownExitCode && reason == Self.unknownExitReason ? .unknown : .runtime
    }

    private mutating func inferExitTimeSourceIfNeeded() {
        guard exitTimeSource == nil, let exitedAt, exitedAt.timeIntervalSince1970 > 0 else {
            return
        }
        exitTimeSource = exitStatusSource == .runtime ? .runtime : .observed
    }

    private mutating func recordObservedExitTimeIfNeeded(at observedAt: Date) {
        inferExitTimeSourceIfNeeded()
        if let exitedAt, exitedAt.timeIntervalSince1970 > 0 {
            exitTimeSource = exitTimeSource ?? .observed
            return
        }
        exitedAt = Self.validTerminalTime(nil, fallback: observedAt)
        exitTimeSource = .observed
    }

    private mutating func recordRuntimeExitTimeIfAvailable(
        _ exitedAt: Date?,
        observedAt: Date,
        replaceRuntimeTime: Bool
    ) {
        inferExitTimeSourceIfNeeded()
        if let exitedAt, exitedAt.timeIntervalSince1970 > 0 {
            if !replaceRuntimeTime,
                exitTimeSource == .runtime,
                let currentExitedAt = self.exitedAt,
                currentExitedAt.timeIntervalSince1970 > 0
            {
                return
            }
            self.exitedAt = exitedAt
            exitTimeSource = .runtime
            return
        }
        recordObservedExitTimeIfNeeded(at: observedAt)
    }

    private var lifecycleFields: LifecycleFields {
        LifecycleFields(
            state: state,
            startedAt: startedAt,
            exitedAt: exitedAt,
            exitCode: exitCode,
            reason: reason,
            message: message,
            exitStatusSource: exitStatusSource,
            exitTimeSource: exitTimeSource
        )
    }

    private struct LifecycleFields: Equatable {
        var state: State
        var startedAt: Date?
        var exitedAt: Date?
        var exitCode: Int32?
        var reason: String?
        var message: String?
        var exitStatusSource: ExitStatusSource?
        var exitTimeSource: ExitTimeSource?
    }
}

extension CRIShimContainerMetadata.State {
    fileprivate var lifecycleRank: Int {
        switch self {
        case .created:
            0
        case .running:
            1
        case .exited:
            2
        case .removed:
            3
        }
    }

    fileprivate var isTerminal: Bool {
        self == .exited || self == .removed
    }
}

extension Optional where Wrapped == CRIShimContainerMetadata.ExitStatusSource {
    fileprivate var precedence: Int {
        switch self {
        case .none:
            0
        case .some(.unknown):
            1
        case .some(.runtime):
            2
        }
    }
}

extension Optional where Wrapped == CRIShimContainerMetadata.ExitTimeSource {
    fileprivate var precedence: Int {
        switch self {
        case .none:
            0
        case .some(.observed):
            1
        case .some(.runtime):
            2
        }
    }
}

private func shouldPreserveExitCode(_ current: Int32?, over incoming: Int32?) -> Bool {
    guard let current else {
        return false
    }
    guard let incoming else {
        return true
    }
    return current != 0 || incoming == 0
}

public final class CRIShimMetadataStore {
    public let rootURL: URL
    private let lock = NSLock()
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
        try withLock {
            CRIShimMetadataSnapshot(
                sandboxes: try sandboxStore.list(),
                containers: try containerStore.list()
            )
        }
    }

    public func listSandboxes() throws -> [CRIShimSandboxMetadata] {
        try withLock {
            try sandboxStore.list()
        }
    }

    public func listContainers() throws -> [CRIShimContainerMetadata] {
        try withLock {
            try containerStore.list()
        }
    }

    public func sandbox(id: String) throws -> CRIShimSandboxMetadata? {
        try withLock {
            try sandboxStore.retrieve(id: id)
        }
    }

    public func container(id: String) throws -> CRIShimContainerMetadata? {
        try withLock {
            try containerStore.retrieve(id: id)
        }
    }

    public func upsertSandbox(_ metadata: CRIShimSandboxMetadata) throws {
        try withLock {
            let merged = try sandboxStore.retrieve(id: metadata.id)?.mergingMonotonically(with: metadata) ?? metadata
            try sandboxStore.upsert(merged)
        }
    }

    public func upsertContainer(_ metadata: CRIShimContainerMetadata) throws {
        try withLock {
            var incoming = metadata
            if incoming.state.isTerminal {
                incoming.normalizeTerminalStatus(observedAt: incoming.terminalObservationFallback)
            }
            let merged = try containerStore.retrieve(id: metadata.id)?.mergingMonotonically(with: incoming) ?? incoming
            try containerStore.upsert(merged)
        }
    }

    public func deleteSandbox(id: String) throws {
        try withLock {
            try sandboxStore.delete(id: id)
        }
    }

    public func deleteContainer(id: String) throws {
        try withLock {
            try containerStore.delete(id: id)
        }
    }

    func updateSandbox(
        id: String,
        _ update: (inout CRIShimSandboxMetadata) -> Void
    ) throws -> CRIShimSandboxMetadata? {
        try withLock {
            guard var metadata = try sandboxStore.retrieve(id: id) else {
                return nil
            }
            let previousMetadata = metadata
            update(&metadata)
            metadata = previousMetadata.mergingMonotonically(with: metadata)
            if metadata != previousMetadata {
                try sandboxStore.upsert(metadata)
            }
            return metadata
        }
    }

    func updateContainer(
        id: String,
        expectedLifecycleVersion: UInt64? = nil,
        _ update: (inout CRIShimContainerMetadata) -> Void
    ) throws -> CRIShimContainerMetadata? {
        try withLock {
            guard var metadata = try containerStore.retrieve(id: id) else {
                return nil
            }
            guard expectedLifecycleVersion == nil || expectedLifecycleVersion == metadata.lifecycleVersion else {
                return metadata
            }
            let previousMetadata = metadata
            update(&metadata)
            metadata = previousMetadata.mergingMonotonically(with: metadata)
            if metadata != previousMetadata {
                try containerStore.upsert(metadata)
            }
            return metadata
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
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
