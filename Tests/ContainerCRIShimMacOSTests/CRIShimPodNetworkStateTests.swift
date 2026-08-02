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

import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerCRIShimMacOS
@testable import ContainerKit
@testable import ContainerResource

struct CRIShimPodNetworkStateTests {
    @Test
    func runtimeConfigPodCIDRListSelectsExactlyOneIPv4CIDRInEitherOrder() throws {
        #expect(
            try canonicalIPv4PodCIDRList("10.42.1.17/24,fd00:10:244:16::/64")
                == "10.42.1.0/24"
        )
        #expect(
            try canonicalIPv4PodCIDRList("fd00:10:244:16::/64, 10.42.1.17/24")
                == "10.42.1.0/24"
        )
        #expect(
            try canonicalIPv4PodCIDRList("10.42.1.17/24,10.42.1.0/24")
                == "10.42.1.0/24"
        )
    }

    @Test
    func runtimeConfigPodCIDRListRejectsMissingAmbiguousOrMalformedIPv4CIDRs() {
        for value in [
            "fd00:10:244:16::/64",
            "10.42.1.0/24,10.42.2.0/24",
            "10.42.1.0/24,",
            "not-a-cidr,fd00:10:244:16::/64",
        ] {
            #expect(throws: PodNetworkStateError.invalidIPv4PodCIDR) {
                try canonicalIPv4PodCIDRList(value)
            }
        }
    }

    @Test
    func runtimeStateUpdatesAreIdempotentAndTrackGeneration() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let statePath = rootURL.appendingPathComponent("nested/runtime.json").path
        let store = PodNetworkStateStore()
        let firstUpdate = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try await store.updateRuntimeState(
            networkName: "kubernetes-pods",
            podCIDR: "10.42.1.17/24",
            path: statePath,
            updatedAt: firstUpdate
        )

        #expect(
            first
                == PodNetworkRuntimeState(
                    networkName: "kubernetes-pods",
                    podCIDR: "10.42.1.0/24",
                    generation: 1,
                    updatedAt: firstUpdate
                ))
        #expect(try await store.loadRuntimeState(path: statePath) == first)

        let repeated = try await store.updateRuntimeState(
            networkName: "kubernetes-pods",
            podCIDR: "10.42.1.0/24",
            path: statePath,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        #expect(repeated == first)

        let secondUpdate = Date(timeIntervalSince1970: 1_700_000_200)
        let second = try await store.updateRuntimeState(
            networkName: "kubernetes-pods",
            podCIDR: "10.42.2.0/24",
            path: statePath,
            updatedAt: secondUpdate
        )

        #expect(second.generation == 2)
        #expect(second.podCIDR == "10.42.2.0/24")
        #expect(second.updatedAt == secondUpdate)
        #expect(try await store.loadRuntimeState(path: statePath) == second)
    }

    @Test
    func runtimeStateRejectsNonIPv4CIDRWithoutEchoingIt() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = PodNetworkStateStore()
        let invalidCIDR = "fd00:42::/64"

        do {
            _ = try await store.updateRuntimeState(
                networkName: "kubernetes-pods",
                podCIDR: invalidCIDR,
                path: rootURL.appendingPathComponent("runtime.json").path
            )
            Issue.record("expected an invalid IPv4 pod CIDR error")
        } catch {
            #expect(error as? PodNetworkStateError == .invalidIPv4PodCIDR)
            #expect(!String(describing: error).contains(invalidCIDR))
        }
    }

    @Test
    func readyStateRoundTripsThroughSharedFileContract() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let path = rootURL.appendingPathComponent("ready.json").path
        let store = PodNetworkStateStore()
        let expected = PodNetworkReadyState(
            networkName: "kubernetes-pods",
            podCIDR: "10.42.1.0/24",
            runtimeGeneration: 1,
            mtu: 1_420,
            expiresAtUnixSeconds: 1_700_000_030
        )

        try await store.writeReadyState(expected, path: path)

        #expect(try await store.loadReadyState(path: path) == expected)
    }

    @Test
    func readinessRequiresMatchingHostOnlyNetworkAndReadyState() throws {
        let config = podNetworkConfig()
        let runtimeState = podNetworkRuntimeState()
        let readyState = PodNetworkReadyState(
            networkName: "kubernetes-pods",
            podCIDR: "10.42.1.0/24",
            runtimeGeneration: 1,
            mtu: 1_420,
            expiresAtUnixSeconds: 1_700_000_030
        )
        let network = try makeNetwork(
            mode: .hostOnly,
            configuredSubnet: "10.42.1.0/24",
            runningSubnet: "10.42.1.0/24"
        )

        let condition = evaluatePodNetworkReadiness(
            config: config,
            runtimeState: runtimeState,
            readyState: readyState,
            networks: [network],
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )

        #expect(condition.status)
        #expect(condition.reason == "PodNetworkReady")
    }

    @Test
    func readinessRejectsMissingNetworkWrongModeAndSubnetMismatches() throws {
        let config = podNetworkConfig()
        let runtimeState = podNetworkRuntimeState()
        let readyState = PodNetworkReadyState(
            networkName: "kubernetes-pods",
            podCIDR: "10.42.1.0/24",
            runtimeGeneration: 1,
            mtu: 1_420,
            expiresAtUnixSeconds: Int64.max
        )

        let missing = evaluatePodNetworkReadiness(
            config: config,
            runtimeState: runtimeState,
            readyState: readyState,
            networks: []
        )
        #expect(!missing.status)
        #expect(missing.reason == "PodNetworkNotFound")

        let wrongMode = evaluatePodNetworkReadiness(
            config: config,
            runtimeState: runtimeState,
            readyState: readyState,
            networks: [
                try makeNetwork(
                    mode: .nat,
                    configuredSubnet: "10.42.1.0/24",
                    runningSubnet: "10.42.1.0/24"
                )
            ]
        )
        #expect(!wrongMode.status)
        #expect(wrongMode.reason == "PodNetworkModeMismatch")

        for network in [
            try makeNetwork(
                mode: .hostOnly,
                configuredSubnet: "10.42.2.0/24",
                runningSubnet: "10.42.1.0/24"
            ),
            try makeNetwork(
                mode: .hostOnly,
                configuredSubnet: "10.42.1.0/24",
                runningSubnet: "10.42.2.0/24"
            ),
        ] {
            let mismatch = evaluatePodNetworkReadiness(
                config: config,
                runtimeState: runtimeState,
                readyState: readyState,
                networks: [network]
            )
            #expect(!mismatch.status)
            #expect(mismatch.reason == "PodNetworkSubnetMismatch")
        }
    }

    @Test
    func readinessRejectsReadyStateThatDoesNotMatchRuntimeState() throws {
        let condition = evaluatePodNetworkReadiness(
            config: podNetworkConfig(),
            runtimeState: podNetworkRuntimeState(),
            readyState: PodNetworkReadyState(
                networkName: "kubernetes-pods",
                podCIDR: "10.42.2.0/24",
                runtimeGeneration: 1,
                mtu: 1_420,
                expiresAtUnixSeconds: Int64.max
            ),
            networks: [
                try makeNetwork(
                    mode: .hostOnly,
                    configuredSubnet: "10.42.1.0/24",
                    runningSubnet: "10.42.1.0/24"
                )
            ]
        )

        #expect(!condition.status)
        #expect(condition.reason == "PodNetworkReadyStateMismatch")
    }

    @Test
    func readinessRejectsExpiredOrWrongGenerationReadyLease() throws {
        let network = try makeNetwork(
            mode: .hostOnly,
            configuredSubnet: "10.42.1.0/24",
            runningSubnet: "10.42.1.0/24"
        )
        let expired = evaluatePodNetworkReadiness(
            config: podNetworkConfig(),
            runtimeState: podNetworkRuntimeState(),
            readyState: PodNetworkReadyState(
                networkName: "kubernetes-pods",
                podCIDR: "10.42.1.0/24",
                runtimeGeneration: 1,
                mtu: 1_420,
                expiresAtUnixSeconds: 1_700_000_009
            ),
            networks: [network],
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )
        #expect(!expired.status)
        #expect(expired.reason == "PodNetworkReadyStateExpired")

        let wrongGeneration = evaluatePodNetworkReadiness(
            config: podNetworkConfig(),
            runtimeState: podNetworkRuntimeState(),
            readyState: PodNetworkReadyState(
                networkName: "kubernetes-pods",
                podCIDR: "10.42.1.0/24",
                runtimeGeneration: 2,
                mtu: 1_420,
                expiresAtUnixSeconds: Int64.max
            ),
            networks: [network]
        )
        #expect(!wrongGeneration.status)
        #expect(wrongGeneration.reason == "PodNetworkReadyStateMismatch")
    }

    @Test
    func readyLeaseExposesDynamicMTUForMatchingFreshGeneration() throws {
        let lease = try validatePodNetworkReadyLease(
            config: podNetworkConfig(),
            runtimeState: podNetworkRuntimeState(),
            readyState: PodNetworkReadyState(
                networkName: "kubernetes-pods",
                podCIDR: "10.42.1.17/24",
                runtimeGeneration: 1,
                mtu: 1_420,
                expiresAtUnixSeconds: 1_700_000_030
            ),
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )

        #expect(lease.podCIDR == "10.42.1.0/24")
        #expect(lease.mtu == 1_420)
    }

    @Test
    func readyLeaseRejectsMismatchExpiredAndOutOfRangeMTU() {
        let runtimeState = podNetworkRuntimeState()
        let now = Date(timeIntervalSince1970: 1_700_000_010)

        #expect(throws: PodNetworkReadyLeaseValidationError.readyStateMismatch) {
            try validatePodNetworkReadyLease(
                config: podNetworkConfig(),
                runtimeState: runtimeState,
                readyState: PodNetworkReadyState(
                    networkName: "kubernetes-pods",
                    podCIDR: "10.42.1.0/24",
                    runtimeGeneration: 2,
                    mtu: 1_420,
                    expiresAtUnixSeconds: Int64.max
                ),
                now: now
            )
        }

        #expect(throws: PodNetworkReadyLeaseValidationError.readyStateExpired) {
            try validatePodNetworkReadyLease(
                config: podNetworkConfig(),
                runtimeState: runtimeState,
                readyState: PodNetworkReadyState(
                    networkName: "kubernetes-pods",
                    podCIDR: "10.42.1.0/24",
                    runtimeGeneration: 1,
                    mtu: 1_420,
                    expiresAtUnixSeconds: 1_700_000_010
                ),
                now: now
            )
        }

        for mtu: UInt32 in [575, 9_001] {
            #expect(throws: PodNetworkReadyLeaseValidationError.mtuOutOfRange) {
                try validatePodNetworkReadyLease(
                    config: podNetworkConfig(),
                    runtimeState: runtimeState,
                    readyState: PodNetworkReadyState(
                        networkName: "kubernetes-pods",
                        podCIDR: "10.42.1.0/24",
                        runtimeGeneration: 1,
                        mtu: mtu,
                        expiresAtUnixSeconds: Int64.max
                    ),
                    now: now
                )
            }
        }
    }

    @Test
    func readinessRejectsOutOfRangeReadyLeaseMTU() throws {
        let condition = evaluatePodNetworkReadiness(
            config: podNetworkConfig(),
            runtimeState: podNetworkRuntimeState(),
            readyState: PodNetworkReadyState(
                networkName: "kubernetes-pods",
                podCIDR: "10.42.1.0/24",
                runtimeGeneration: 1,
                mtu: 9_001,
                expiresAtUnixSeconds: Int64.max
            ),
            networks: [
                try makeNetwork(
                    mode: .hostOnly,
                    configuredSubnet: "10.42.1.0/24",
                    runningSubnet: "10.42.1.0/24"
                )
            ]
        )

        #expect(!condition.status)
        #expect(condition.reason == "PodNetworkReadyStateMTUInvalid")
    }
}

private func podNetworkConfig() -> PodNetworkConfig {
    PodNetworkConfig(
        enabled: true,
        networkName: "kubernetes-pods",
        runtimeStatePath: "/var/lib/container/pod-network/runtime.json",
        readyStatePath: "/var/lib/container/pod-network/ready.json"
    )
}

private func podNetworkRuntimeState() -> PodNetworkRuntimeState {
    PodNetworkRuntimeState(
        networkName: "kubernetes-pods",
        podCIDR: "10.42.1.0/24",
        generation: 1,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeNetwork(
    mode: NetworkMode,
    configuredSubnet: String,
    runningSubnet: String
) throws -> NetworkState {
    NetworkState(
        configuration: try NetworkConfiguration(
            name: "kubernetes-pods",
            mode: mode,
            ipv4Subnet: try CIDRv4(configuredSubnet),
            plugin: "container-network-vmnet"
        ),
        status: NetworkStatus(
            ipv4Subnet: try CIDRv4(runningSubnet),
            ipv4Gateway: try IPv4Address("10.42.1.1"),
            ipv6Subnet: nil
        )
    )
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "CRIShimPodNetworkStateTests-\(UUID().uuidString)",
        isDirectory: true
    )
}
