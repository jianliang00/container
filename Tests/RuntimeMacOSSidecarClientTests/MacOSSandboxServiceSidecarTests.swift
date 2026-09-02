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
import ContainerResource
import Foundation
import Logging
import Testing

@testable import container_runtime_macos

struct MacOSSandboxServiceSidecarTests {
    @Test
    func machineStateLaunchPlistCarriesExactLifecycleBarrierArguments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-plist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = MacOSSandboxService(
            root: root,
            connection: nil,
            log: Logger(label: "MacOSSandboxServiceSidecarTests")
        )
        let plistURL = root.appendingPathComponent("sidecar.plist")
        let nonce = UUID().uuidString.lowercased()
        let machineState = ContainerConfiguration.MacOSGuestOptions.MachineState(
            persistenceID: "workload-42",
            storageDirectory: "/private/tmp/machine-state/workload-42",
            controlSocketPath: "/private/tmp/machine-state-control/workload-42.sock",
            storageGeneration: 1,
            sidecarLifecycleBarrier: .init(protocolVersion: 1, bootNonce: nonce)
        )
        try await service.writeSidecarLaunchAgentPlist(
            plistURL: plistURL,
            launchLabel: "test.sidecar",
            sandboxID: "sandbox-42",
            binaryURL: URL(fileURLWithPath: "/bin/true"),
            socketURL: URL(fileURLWithPath: machineState.controlSocketPath),
            stdoutURL: root.appendingPathComponent("stdout.log"),
            stderrURL: root.appendingPathComponent("stderr.log"),
            machineState: machineState
        )
        let plist = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: plistURL),
                format: nil
            ) as? [String: Any]
        )
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
        #expect(value(after: "--lifecycle-barrier-protocol") == "1")
        #expect(value(after: "--lifecycle-barrier-nonce") == nonce)
        #expect(value(after: "--lifecycle-persistence-id") == "workload-42")
        #expect(value(after: "--lifecycle-storage-directory") == "/private/tmp/machine-state/workload-42")
    }

    @Test
    func sidecarLaunchdDomainUsesRootBootstrapDomainForRoot() {
        let service = MacOSSandboxService(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-domain-test"),
            connection: nil,
            log: Logger(label: "MacOSSandboxServiceSidecarTests")
        )

        #expect(service.sidecarLaunchdDomain(uid: 0) == "user/0")
        #expect(service.sidecarLaunchdDomain(uid: 501) == "gui/501")
    }

    @Test
    func sidecarLaunchAgentSessionOptionsSupportRootBootstrap() {
        let service = MacOSSandboxService(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-session-options-test"),
            connection: nil,
            log: Logger(label: "MacOSSandboxServiceSidecarTests")
        )

        let rootOptions = service.sidecarLaunchAgentSessionOptions(uid: 0)
        #expect(rootOptions["LimitLoadToSessionType"] as? [String] == ["Aqua", "Background", "System"])
        #expect(rootOptions["ProcessType"] == nil)

        let userOptions = service.sidecarLaunchAgentSessionOptions(uid: 501)
        #expect(userOptions["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(userOptions["ProcessType"] as? String == "Interactive")
    }
}
#endif
