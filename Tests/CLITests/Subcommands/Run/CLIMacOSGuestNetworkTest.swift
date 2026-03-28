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
import Testing

private func isMacOSGuestNetworkE2EEnabled() -> Bool {
    guard CLITest.isCLIServiceAvailable() else {
        return false
    }
    guard ProcessInfo.processInfo.environment["CONTAINER_ENABLE_MACOS_GUEST_NETWORK_E2E"] == "1" else {
        return false
    }
    guard #available(macOS 26, *) else {
        return false
    }
    return true
}

@Suite(.serialized, .enabled(if: isMacOSGuestNetworkE2EEnabled(), "requires CONTAINER_ENABLE_MACOS_GUEST_NETWORK_E2E=1 on macOS 26+"))
final class TestCLIMacOSGuestNetwork: CLITest {
    private let sameNodePort = "18080"

    private var macOSBaseReference: String {
        ProcessInfo.processInfo.environment["CONTAINER_MACOS_BASE_REF"] ?? "local/macos-base:latest"
    }

    private var externalConnectivityURL: String {
        ProcessInfo.processInfo.environment["CONTAINER_MACOS_GUEST_EXTERNAL_URL"] ?? "https://example.com"
    }

    @Test
    func macOSGuestSameNodeConnectivityUsesReportedPeerAddress() throws {
        let networkName = uniqueEntityName(prefix: "macos-net")
        let peerName = uniqueEntityName(prefix: "linux-peer")
        let guestName = uniqueEntityName(prefix: "macos-guest")

        try doNetworkCreate(name: networkName)
        defer { try? deleteNetworkEventually(name: networkName) }

        try doLongRun(
            name: peerName,
            image: "docker.io/library/python:alpine",
            args: ["--network", networkName],
            containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", sameNodePort]
        )
        defer { try? doStop(name: peerName) }

        let peerInspect = try waitForContainerNetworks(peerName)
        #expect(peerInspect.networks.count == 1)
        #expect(peerInspect.networks[0].network == networkName)

        let guestInspect = try runDarwinGuest(name: guestName, network: networkName)
        defer { try? doStop(name: guestName) }

        #expect(guestInspect.configuration.macosGuest?.networkBackend == .vmnetShared)
        #expect(guestInspect.networks.count == 1)
        #expect(guestInspect.networks[0].network == networkName)

        let peerAddress = peerInspect.networks[0].ipv4Address.address.description
        let output = try waitForGuestCommand(
            name: guestName,
            command: [
                "/usr/bin/curl",
                "--fail",
                "--silent",
                "--show-error",
                "--max-time",
                "10",
                "http://\(peerAddress):\(sameNodePort)/",
            ]
        )

        #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test
    func macOSGuestExternalConnectivityWorksWithReportedNetworkState() throws {
        let networkName = uniqueEntityName(prefix: "macos-net")
        let guestName = uniqueEntityName(prefix: "macos-guest")

        try doNetworkCreate(name: networkName)
        defer { try? deleteNetworkEventually(name: networkName) }

        let guestInspect = try runDarwinGuest(name: guestName, network: networkName)
        defer { try? doStop(name: guestName) }

        #expect(guestInspect.configuration.macosGuest?.networkBackend == .vmnetShared)
        #expect(guestInspect.networks.count == 1)
        #expect(guestInspect.networks[0].network == networkName)
        #expect(!(guestInspect.networks[0].dns?.nameservers.isEmpty ?? true))

        let output = try waitForGuestCommand(
            name: guestName,
            command: [
                "/usr/bin/curl",
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--max-time",
                "20",
                externalConnectivityURL,
            ]
        )

        #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func runDarwinGuest(name: String, network: String) throws -> CLITest.inspectOutput {
        try doLongRun(
            name: name,
            image: macOSBaseReference,
            args: ["--os", "darwin", "--network", network],
            containerArgs: ["/usr/bin/tail", "-f", "/dev/null"],
            waitForRunning: false
        )
        try waitForContainerRunning(name, 300)
        return try waitForContainerNetworks(name, totalAttempts: 180)
    }

    private func waitForGuestCommand(
        name: String,
        command: [String],
        attempts: Int = 10,
        retryDelaySeconds: UInt32 = 3
    ) throws -> String {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try doExec(name: name, cmd: command)
            } catch {
                lastError = error
                guard attempt < attempts - 1 else {
                    break
                }
                sleep(retryDelaySeconds)
            }
        }

        throw lastError ?? CLITest.CLIError.executionFailed("guest command failed without an error")
    }

    private func deleteNetworkEventually(name: String, attempts: Int = 10, retryDelaySeconds: UInt32 = 2) throws {
        var lastError = ""
        for attempt in 0..<attempts {
            let (_, _, error, status) = try run(arguments: ["network", "rm", name])
            if status == 0 {
                return
            }
            lastError = error
            guard attempt < attempts - 1 else {
                break
            }
            sleep(retryDelaySeconds)
        }

        throw CLITest.CLIError.executionFailed("network delete failed: \(lastError)")
    }

    private func uniqueEntityName(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }
}
