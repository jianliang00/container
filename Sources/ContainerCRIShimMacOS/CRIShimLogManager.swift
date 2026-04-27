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

import ContainerResource
import Foundation

public protocol CRIShimLogManaging: Sendable {
    func start(
        container: CRIShimContainerMetadata,
        workloadSnapshot: WorkloadSnapshot?
    ) async throws

    func reopen(
        container: CRIShimContainerMetadata
    ) async throws

    func stop(
        containerID: String,
        removeState: Bool
    ) async
}

public final actor CRIShimLogManager: CRIShimLogManaging {
    private struct Session {
        var controller: CRIShimLogSessionController
        var stdoutSourcePath: String?
        var stderrSourcePath: String?
        var tasks: [Task<Void, Never>]
    }

    private let rootURL: URL
    private let store: CRIShimLogStateStore
    private var sessions: [String: Session] = [:]

    public init(stateDirectoryURL: URL) {
        let rootURL = stateDirectoryURL.appendingPathComponent("log-mux", isDirectory: true)
        self.rootURL = rootURL
        self.store = CRIShimLogStateStore(rootURL: rootURL)
    }

    public func start(
        container: CRIShimContainerMetadata,
        workloadSnapshot: WorkloadSnapshot?
    ) async throws {
        let containerID = container.id.trimmed
        guard !containerID.isEmpty else {
            throw CRIShimError.invalidArgument("container id is required for log mux")
        }
        guard let destinationPath = normalizedDestinationPath(for: container) else {
            return
        }
        guard let workloadSnapshot else {
            throw CRIShimError.internalError("workload snapshot is required to start log mux for \(containerID)")
        }
        let stdoutSourcePath = normalizedSourcePath(workloadSnapshot.stdoutLogPath)
        let stderrSourcePath = normalizedSourcePath(workloadSnapshot.stderrLogPath)
        guard stdoutSourcePath != nil || stderrSourcePath != nil else {
            throw CRIShimError.internalError("workload log paths are required to start log mux for \(containerID)")
        }

        if sessions[containerID] != nil {
            await stop(containerID: containerID, removeState: false)
        }

        let persistedState = try store.load(containerID: containerID)
        let state = CRIShimContainerLogState(
            containerID: containerID,
            destinationPath: destinationPath,
            stdoutOffset: persistedState?.stdoutOffset ?? 0,
            stderrOffset: persistedState?.stderrOffset ?? 0,
            stdoutPartialOpen: persistedState?.stdoutPartialOpen ?? false,
            stderrPartialOpen: persistedState?.stderrPartialOpen ?? false
        )
        let controller = try CRIShimLogSessionController(
            containerID: containerID,
            destinationURL: URL(fileURLWithPath: destinationPath),
            store: store,
            state: state
        )

        let session = Session(
            controller: controller,
            stdoutSourcePath: stdoutSourcePath,
            stderrSourcePath: stderrSourcePath,
            tasks: [
                makePumpTask(
                    controller: controller,
                    stream: .stdout,
                    sourcePath: stdoutSourcePath
                ),
                makePumpTask(
                    controller: controller,
                    stream: .stderr,
                    sourcePath: stderrSourcePath
                ),
            ]
        )
        sessions[containerID] = session
    }

    public func reopen(
        container: CRIShimContainerMetadata
    ) async throws {
        let containerID = container.id.trimmed
        guard !containerID.isEmpty else {
            throw CRIShimError.invalidArgument("ReopenContainerLog container_id is required")
        }
        guard let destinationPath = normalizedDestinationPath(for: container) else {
            throw CRIShimError.invalidArgument("container \(containerID) does not have a configured CRI log path")
        }

        if let session = sessions[containerID] {
            try await session.controller.reopen(destinationURL: URL(fileURLWithPath: destinationPath))
            return
        }

        let persistedState = try store.load(containerID: containerID)
        let controller = try CRIShimLogSessionController(
            containerID: containerID,
            destinationURL: URL(fileURLWithPath: destinationPath),
            store: store,
            state: CRIShimContainerLogState(
                containerID: containerID,
                destinationPath: destinationPath,
                stdoutOffset: persistedState?.stdoutOffset ?? 0,
                stderrOffset: persistedState?.stderrOffset ?? 0,
                stdoutPartialOpen: persistedState?.stdoutPartialOpen ?? false,
                stderrPartialOpen: persistedState?.stderrPartialOpen ?? false
            )
        )
        try await controller.close(removeState: false)
    }

    public func stop(
        containerID: String,
        removeState: Bool
    ) async {
        guard let session = sessions.removeValue(forKey: containerID.trimmed) else {
            if removeState {
                try? store.delete(containerID: containerID)
            }
            return
        }

        for task in session.tasks {
            task.cancel()
        }
        for task in session.tasks {
            _ = await task.result
        }
        try? await drainRemainingBytes(
            controller: session.controller,
            stream: .stdout,
            sourcePath: session.stdoutSourcePath
        )
        try? await drainRemainingBytes(
            controller: session.controller,
            stream: .stderr,
            sourcePath: session.stderrSourcePath
        )
        try? await session.controller.close(removeState: removeState)
    }

    private func makePumpTask(
        controller: CRIShimLogSessionController,
        stream: CRIShimLogStream,
        sourcePath: String?
    ) -> Task<Void, Never> {
        Task {
            do {
                try await self.pump(
                    controller: controller,
                    stream: stream,
                    sourcePath: sourcePath
                )
            } catch {}
        }
    }

    private func pump(
        controller: CRIShimLogSessionController,
        stream: CRIShimLogStream,
        sourcePath: String?
    ) async throws {
        guard let sourcePath = normalizedSourcePath(sourcePath) else {
            return
        }
        while !Task.isCancelled {
            try await drainAvailableBytes(
                controller: controller,
                stream: stream,
                sourcePath: sourcePath
            )
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func drainRemainingBytes(
        controller: CRIShimLogSessionController,
        stream: CRIShimLogStream,
        sourcePath: String?
    ) async throws {
        guard let sourcePath = normalizedSourcePath(sourcePath) else {
            try await controller.finish(stream: stream)
            return
        }
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            try await controller.finish(stream: stream)
            return
        }

        try await drainAvailableBytes(
            controller: controller,
            stream: stream,
            sourcePath: sourcePath
        )
        try await controller.finish(stream: stream)
    }

    private func drainAvailableBytes(
        controller: CRIShimLogSessionController,
        stream: CRIShimLogStream,
        sourcePath: String
    ) async throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }

        let desiredOffset = await controller.offset(for: stream)
        let fileSize = try fileSize(of: sourceURL)
        let offset = desiredOffset > fileSize ? 0 : desiredOffset
        if offset != desiredOffset {
            try await controller.resetOffset(offset, for: stream)
        }
        guard offset < fileSize else {
            return
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var remainingBytes = fileSize - offset
        while remainingBytes > 0 {
            let readSize = min(Int(remainingBytes), 64 * 1024)
            guard let data = try handle.read(upToCount: readSize), !data.isEmpty else {
                return
            }
            try await controller.consume(data, stream: stream)
            remainingBytes -= UInt64(data.count)
        }
    }

    private func normalizedDestinationPath(
        for container: CRIShimContainerMetadata
    ) -> String? {
        normalizedSourcePath(container.logPath)
    }

    private func normalizedSourcePath(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}

struct CRIShimLogReconcileStartupTask: CRIShimServerStartupTask {
    let metadataStore: CRIShimMetadataStore
    let runtimeManager: any CRIShimRuntimeManaging
    let logManager: any CRIShimLogManaging

    func run() async throws {
        for container in try metadataStore.listContainers() where container.state == .running {
            let snapshot = try? await runtimeManager.inspectWorkload(
                sandboxID: container.sandboxID,
                workloadID: container.id
            )
            try? await logManager.start(container: container, workloadSnapshot: snapshot)
        }
    }
}

private enum CRIShimLogStream: String, Sendable {
    case stdout
    case stderr
}

private enum CRIShimLogTag: String, Sendable {
    case full = "F"
    case partial = "P"
}

private struct CRIShimContainerLogState: Codable, Equatable, Sendable {
    var containerID: String
    var destinationPath: String
    var stdoutOffset: UInt64
    var stderrOffset: UInt64
    var stdoutPartialOpen: Bool
    var stderrPartialOpen: Bool
}

private struct CRIShimLogStateStore: Sendable {
    let rootURL: URL

    func load(containerID: String) throws -> CRIShimContainerLogState? {
        let url = stateURL(for: containerID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CRIShimContainerLogState.self, from: data)
    }

    func upsert(_ state: CRIShimContainerLogState) throws {
        try ensureRootDirectory()
        let directoryURL = rootURL.appendingPathComponent(state.containerID, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL(for: state.containerID), options: .atomic)
    }

    func delete(containerID: String) throws {
        let directoryURL = rootURL.appendingPathComponent(containerID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: directoryURL)
    }

    private func ensureRootDirectory() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func stateURL(for containerID: String) -> URL {
        rootURL
            .appendingPathComponent(containerID, isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }
}

private actor CRIShimLogSessionController {
    private let containerID: String
    private let store: CRIShimLogStateStore
    private var state: CRIShimContainerLogState
    private var destinationURL: URL
    private var handle: FileHandle

    init(
        containerID: String,
        destinationURL: URL,
        store: CRIShimLogStateStore,
        state: CRIShimContainerLogState
    ) throws {
        self.containerID = containerID
        self.store = store
        self.state = state
        self.destinationURL = destinationURL
        self.handle = try Self.openAppendHandle(at: destinationURL)
        try store.upsert(state)
    }

    func offset(for stream: CRIShimLogStream) -> UInt64 {
        switch stream {
        case .stdout:
            state.stdoutOffset
        case .stderr:
            state.stderrOffset
        }
    }

    func resetOffset(
        _ offset: UInt64,
        for stream: CRIShimLogStream
    ) throws {
        switch stream {
        case .stdout:
            state.stdoutOffset = offset
        case .stderr:
            state.stderrOffset = offset
        }
        try store.upsert(state)
    }

    func consume(
        _ data: Data,
        stream: CRIShimLogStream
    ) throws {
        guard !data.isEmpty else {
            return
        }

        var segmentStartIndex = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            let segment = data[segmentStartIndex..<index]
            try writeSegment(Data(segment), stream: stream, trailingNewline: true)
            segmentStartIndex = data.index(after: index)
        }
        if segmentStartIndex < data.endIndex {
            let trailingSegment = data[segmentStartIndex..<data.endIndex]
            try writeSegment(Data(trailingSegment), stream: stream, trailingNewline: false)
        }

        switch stream {
        case .stdout:
            state.stdoutOffset += UInt64(data.count)
        case .stderr:
            state.stderrOffset += UInt64(data.count)
        }
        try store.upsert(state)
    }

    func finish(
        stream: CRIShimLogStream
    ) throws {
        guard partialOpen(for: stream) else {
            return
        }
        try writeRecord(
            stream: stream,
            tag: .full,
            payload: Data()
        )
        setPartialOpen(false, for: stream)
        try store.upsert(state)
    }

    func reopen(
        destinationURL: URL
    ) throws {
        try handle.close()
        self.destinationURL = destinationURL
        state.destinationPath = destinationURL.path
        handle = try Self.openAppendHandle(at: destinationURL)
        try store.upsert(state)
    }

    func close(
        removeState: Bool
    ) throws {
        try handle.close()
        if removeState {
            try store.delete(containerID: containerID)
        } else {
            try store.upsert(state)
        }
    }

    private func writeSegment(
        _ segment: Data,
        stream: CRIShimLogStream,
        trailingNewline: Bool
    ) throws {
        if trailingNewline {
            try writeRecord(stream: stream, tag: .full, payload: segment)
            setPartialOpen(false, for: stream)
            return
        }

        guard !segment.isEmpty else {
            return
        }
        try writeRecord(stream: stream, tag: .partial, payload: segment)
        setPartialOpen(true, for: stream)
    }

    private func writeRecord(
        stream: CRIShimLogStream,
        tag: CRIShimLogTag,
        payload: Data
    ) throws {
        var record = Data()
        record.append(Data(criShimLogTimestamp().utf8))
        record.append(Data(" ".utf8))
        record.append(Data(stream.rawValue.utf8))
        record.append(Data(" ".utf8))
        record.append(Data(tag.rawValue.utf8))
        record.append(Data(" ".utf8))
        record.append(payload)
        record.append(0x0A)
        try handle.write(contentsOf: record)
    }

    private func partialOpen(
        for stream: CRIShimLogStream
    ) -> Bool {
        switch stream {
        case .stdout:
            state.stdoutPartialOpen
        case .stderr:
            state.stderrPartialOpen
        }
    }

    private func setPartialOpen(
        _ value: Bool,
        for stream: CRIShimLogStream
    ) {
        switch stream {
        case .stdout:
            state.stdoutPartialOpen = value
        case .stderr:
            state.stderrPartialOpen = value
        }
    }

    private static func openAppendHandle(
        at url: URL
    ) throws -> FileHandle {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

private func fileSize(
    of url: URL
) throws -> UInt64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return UInt64(values.fileSize ?? 0)
}

private func criShimLogTimestamp(
    date: Date = Date()
) -> String {
    let timeInterval = date.timeIntervalSince1970
    let seconds = floor(timeInterval)
    let nanoseconds = Int((timeInterval - seconds) * 1_000_000_000)
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    let secondsDate = Date(timeIntervalSince1970: seconds)
    return "\(formatter.string(from: secondsDate)).\(String(format: "%09d", nanoseconds))Z"
}
