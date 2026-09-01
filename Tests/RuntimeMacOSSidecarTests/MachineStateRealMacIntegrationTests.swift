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

#if os(macOS)
import Foundation
import Logging
import Testing

@testable import container_runtime_macos_sidecar

@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CONTAINER_MACOS_MACHINE_STATE_INTEGRATION_ROOT"] != nil,
        "requires a provisioned macOS VM runtime root"
    )
)
struct MachineStateRealMacIntegrationTests {
    @Test
    func saveRecreateSidecarRestoreAndResumeOnSameHost() async throws {
        let rootPath = try #require(ProcessInfo.processInfo.environment["CONTAINER_MACOS_MACHINE_STATE_INTEGRATION_ROOT"])
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let stateID = "integration-\(UUID().uuidString)"
        let stateDirectory = rootURL.appendingPathComponent("MachineStates/\(stateID)")
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let log = Logger(label: "MachineStateRealMacIntegrationTests")

        let firstSidecar = MacOSSidecarService(rootURL: rootURL, log: log)
        let capabilities = await firstSidecar.capabilities()
        guard capabilities.machineState.supported else {
            Issue.record("VM configuration does not support machine state: \(String(describing: capabilities.machineState.unsupportedReason))")
            return
        }
        try await firstSidecar.bootstrapStart(presentGUI: false)
        #expect(try await firstSidecar.pauseVM().lifecycleState == .paused)
        #expect(
            try await firstSidecar.saveMachineState(stateID: stateID, timeoutSeconds: 600).lifecycleState
                == .paused
        )
        try await firstSidecar.stopVM()

        // A fresh service instance exercises sidecar or workload recreation while
        // retaining the same runtime directory and physical host.
        let recreatedSidecar = MacOSSidecarService(rootURL: rootURL, log: log)
        #expect(
            try await recreatedSidecar.restoreMachineState(stateID: stateID, timeoutSeconds: 600).lifecycleState
                == .paused
        )
        #expect(try await recreatedSidecar.resumeVM().lifecycleState == .running)
        try await recreatedSidecar.stopVM()
    }
}
#endif
