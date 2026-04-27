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
import RuntimeMacOSSidecarShared

extension MacOSSandboxService {
    func prepareReadOnlyInjectionsIfNeeded() async throws {
        guard !readOnlyInjectionsPrepared else {
            return
        }

        let entries = try MacOSReadOnlyFileInjectionStore.load(from: MacOSSandboxLayout(root: root))
        try await prepareReadOnlyInjections(
            entries,
            description: "macOS guest read-only injections"
        )
        readOnlyInjectionsPrepared = true
    }

    func prepareWorkloadReadOnlyInjectionsIfNeeded(workloadID: String) async throws {
        let layout = MacOSSandboxLayout(root: root)
        let entries = try MacOSReadOnlyFileInjectionStore.load(
            from: layout.workloadReadonlyInjectionDirectoryURL(id: workloadID)
        )
        try await prepareReadOnlyInjections(
            entries,
            description: "macOS guest workload \(workloadID) read-only injections"
        )
    }

    private func prepareReadOnlyInjections(
        _ entries: [MacOSReadOnlyFileInjectionStore.PreparedEntry],
        description: String
    ) async throws {
        guard !entries.isEmpty else {
            return
        }

        writeContainerLog(
            Data(
                ("preparing \(description): " + entries.map { "\($0.sourceURL.lastPathComponent)->\($0.destination)" }.joined(separator: ", ") + "\n").utf8
            )
        )

        for entry in entries {
            try await MacOSSidecarFileTransfer.writeFile(
                from: entry.sourceURL,
                to: entry.destination,
                options: .init(mode: entry.mode, overwrite: entry.overwrite),
                begin: { payload in
                    try await self.sendFSBegin(payload)
                },
                chunk: { payload in
                    try await self.sendFSChunk(payload)
                },
                end: { payload in
                    try await self.sendFSEnd(payload)
                }
            )
        }
    }
}
