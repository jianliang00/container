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

/// Persisted terminal state for one workload incarnation.
public struct WorkloadExitState: Codable, Sendable, Equatable {
    public let exitCode: Int32
    public let exitedAt: Date

    public init(exitCode: Int32, exitedAt: Date) {
        self.exitCode = exitCode
        self.exitedAt = exitedAt
    }
}

public enum WorkloadExitStateStore {
    public static func load(workloadID: String, from layout: MacOSSandboxLayout) throws -> WorkloadExitState? {
        let url = layout.workloadExitStateURL(id: workloadID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONDecoder().decode(WorkloadExitState.self, from: Data(contentsOf: url))
    }

    public static func save(
        _ state: WorkloadExitState,
        workloadID: String,
        in layout: MacOSSandboxLayout
    ) throws {
        let url = layout.workloadExitStateURL(id: workloadID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    public static func saveIfAbsent(
        _ state: WorkloadExitState,
        workloadID: String,
        in layout: MacOSSandboxLayout
    ) throws {
        let url = layout.workloadExitStateURL(id: workloadID)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".exit-\(UUID().uuidString).tmp")
        try JSONEncoder().encode(state).write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            try FileManager.default.linkItem(at: temporaryURL, to: url)
        } catch {
            if try load(workloadID: workloadID, from: layout) != nil {
                return
            }
            throw error
        }
    }

    public static func remove(workloadID: String, from layout: MacOSSandboxLayout) throws {
        let url = layout.workloadExitStateURL(id: workloadID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}
