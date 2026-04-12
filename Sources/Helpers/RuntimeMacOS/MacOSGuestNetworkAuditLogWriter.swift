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

final class MacOSGuestNetworkAuditLogWriter: @unchecked Sendable {
    private let logURL: URL
    private let lock = NSLock()

    init(logURL: URL) {
        self.logURL = logURL
    }

    func append(_ event: SandboxNetworkAuditEvent, auditMode: SandboxNetworkAuditMode) {
        guard shouldAppend(event, auditMode: auditMode) else {
            return
        }

        lock.withLock {
            do {
                try FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                var data = try encoder.encode(event)
                data.append(contentsOf: "\n".utf8)

                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                return
            }
        }
    }

    private func shouldAppend(_ event: SandboxNetworkAuditEvent, auditMode: SandboxNetworkAuditMode) -> Bool {
        switch auditMode {
        case .disabled:
            return false
        case .denied:
            return event.action == .deny
        case .all:
            return true
        }
    }
}
