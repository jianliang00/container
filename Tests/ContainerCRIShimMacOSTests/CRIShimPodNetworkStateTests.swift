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
            try canonicalIPv4PodCIDRList("10.42.1.17/24,fd42:10:244:16::/64")
                == "10.42.1.0/24"
        )
        #expect(
            try canonicalIPv4PodCIDRList("fd42:10:244:16::/64, 10.42.1.17/24")
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
            "fd42:10:244:16::/64",
            "10.42.1.0/24,10.42.2.0/24",
            "10.42.1.0/24,",
            "not-a-cidr,fd42:10:244:16::/64",
        ] {
            #expect(throws: PodNetworkStateError.invalidIPv4PodCIDR) {
                try canonicalIPv4PodCIDRList(value)
            }
        }
    }

    @Test
    func dualStackPodCIDRListRequiresAndCanonicalizesExactlyOneCIDRPerFamily() throws {
        #expect(
            try canonicalPodNetworkCIDRs(
                "fd42:10:244:16::1234/64, 10.42.1.17/24",
                dualStackEnabled: true
            )
                == PodNetworkCIDRs(
                    ipv4: "10.42.1.0/24",
                    ipv6: "fd42:10:244:16::/64"
                )
        )
        #expect(
            try canonicalPodNetworkCIDRs(
                "10.42.1.17/24,fd42:10:244:16::1234/64",
                dualStackEnabled: true
            )
                == PodNetworkCIDRs(
                    ipv4: "10.42.1.0/24",
                    ipv6: "fd42:10:244:16::/64"
                )
        )

        for value in [
            "",
            ",",
            "10.42.1.0/24",
            "fd42:10:244:16::/64",
            "10.42.1.0/24,10.42.1.0/24,fd42:10:244:16::/64",
            "10.42.1.0/24,fd42:10:244:16::/64,fd42:10:244:16::/64",
            "10.42.1.999/24,fd42:10:244:16::/64",
            "10.42.1.0/24,fd42:10:244:16::/129",
        ] {
            #expect(throws: PodNetworkStateError.invalidPodCIDRList) {
                try canonicalPodNetworkCIDRs(value, dualStackEnabled: true)
            }
        }
    }

    @Test
    func disabledDualStackGatePreservesIPv4OnlySelectionBehavior() throws {
        #expect(
            try canonicalPodNetworkCIDRs(
                "fd42:10:244:16::/64,10.42.1.17/24,fd42:10:244:17::/64",
                dualStackEnabled: false
            )
                == PodNetworkCIDRs(ipv4: "10.42.1.0/24")
        )
    }

    @Test
    func disabledDualStackGateIgnoresIPv6State() throws {
        let lease = try validatePodNetworkReadyLease(
            config: podNetworkConfig(),
            runtimeState: podNetworkRuntimeState(ipv6: "fd42:10:244:16::/64"),
            readyState: PodNetworkReadyState(
                networkName: "kubernetes-pods",
                podCIDRs: PodNetworkCIDRs(
                    ipv4: "10.42.1.0/24",
                    ipv6: "fd42:10:244:99::/64"
                ),
                runtimeGeneration: 1,
                mtu: 1_420,
                expiresAtUnixSeconds: Int64.max,
                ipv4Ready: true,
                ipv6Ready: false
            )
        )

        #expect(lease.podCIDRs == PodNetworkCIDRs(ipv4: "10.42.1.0/24"))
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
    func dualStackStateRoundTripsAndTracksIPv6GenerationChanges() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtimeStatePath = rootURL.appendingPathComponent("runtime.json").path
        let readyStatePath = rootURL.appendingPathComponent("ready.json").path
        let store = PodNetworkStateStore()

        let first = try await store.updateRuntimeState(
            networkName: "kubernetes-pods",
            podCIDRs: PodNetworkCIDRs(
                ipv4: "10.42.1.17/24",
                ipv6: "fd42:10:244:16::1234/64"
            ),
            path: runtimeStatePath
        )
        #expect(
            first.podCIDRs
                == PodNetworkCIDRs(
                    ipv4: "10.42.1.0/24",
                    ipv6: "fd42:10:244:16::/64"
                )
        )
        #expect(try await store.loadRuntimeState(path: runtimeStatePath) == first)

        let second = try await store.updateRuntimeState(
            networkName: "kubernetes-pods",
            podCIDRs: PodNetworkCIDRs(
                ipv4: "10.42.1.0/24",
                ipv6: "fd42:10:244:17::/64"
            ),
            path: runtimeStatePath
        )
        #expect(second.generation == first.generation + 1)

        let ready = PodNetworkReadyState(
            networkName: "kubernetes-pods",
            podCIDRs: second.podCIDRs,
            runtimeGeneration: second.generation,
            mtu: 1_420,
            expiresAtUnixSeconds: Int64.max,
            ipv4Ready: true,
            ipv6Ready: true
        )
        try await store.writeReadyState(ready, path: readyStatePath)
        #expect(try await store.loadReadyState(path: readyStatePath) == ready)
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
    func versionOneStatesDecodeAndVersionTwoStatesKeepLegacyIPv4Alias() throws {
        let runtimeV1 = try JSONDecoder().decode(
            PodNetworkRuntimeState.self,
            from: Data(
                #"{"networkName":"kubernetes-pods","podCIDR":"10.42.1.17/24","generation":1,"updatedAt":0}"#.utf8
            )
        )
        #expect(runtimeV1.schemaVersion == 1)
        #expect(runtimeV1.podCIDRs == PodNetworkCIDRs(ipv4: "10.42.1.17/24"))

        let readyV1 = try JSONDecoder().decode(
            PodNetworkReadyState.self,
            from: Data(
                #"{"networkName":"kubernetes-pods","podCIDR":"10.42.1.0/24","runtimeGeneration":1,"mtu":1420,"expiresAtUnixSeconds":1700000030}"#.utf8
            )
        )
        #expect(readyV1.schemaVersion == 1)
        #expect(readyV1.ipv4Ready)
        #expect(readyV1.ipv6Ready == nil)

        let runtimeV2 = PodNetworkRuntimeState(
            networkName: "kubernetes-pods",
            podCIDRs: PodNetworkCIDRs(
                ipv4: "10.42.1.0/24",
                ipv6: "fd42:10:244:16::/64"
            ),
            generation: 2,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(runtimeV2)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["podCIDR"] as? String == "10.42.1.0/24")
        #expect((object["podCIDRs"] as? [String: Any])?["ipv6"] as? String == "fd42:10:244:16::/64")
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
    func dualStackReadinessRequiresBothFamiliesAndMatchingSubnets() throws {
        let config = podNetworkConfig(dualStackEnabled: true)
        let runtimeState = podNetworkRuntimeState(ipv6: "fd42:10:244:16::/64")
        let readyState = PodNetworkReadyState(
            networkName: "kubernetes-pods",
            podCIDRs: PodNetworkCIDRs(
                ipv4: "10.42.1.0/24",
                ipv6: "fd42:10:244:16::/64"
            ),
            runtimeGeneration: 1,
            mtu: 1_420,
            expiresAtUnixSeconds: Int64.max,
            ipv4Ready: true,
            ipv6Ready: true
        )
        let matching = evaluatePodNetworkReadiness(
            config: config,
            runtimeState: runtimeState,
            readyState: readyState,
            networks: [
                try makeNetwork(
                    mode: .hostOnly,
                    configuredSubnet: "10.42.1.0/24",
                    runningSubnet: "10.42.1.0/24",
                    configuredIPv6Subnet: "fd42:10:244:16::/64",
                    runningIPv6Subnet: "fd42:10:244:16::/64"
                )
            ]
        )
        #expect(matching.status)

        var ipv4NotReady = readyState
        ipv4NotReady.ipv4Ready = false
        let ipv4FamilyFailure = evaluatePodNetworkReadiness(
            config: config,
            runtimeState: runtimeState,
            readyState: ipv4NotReady,
            networks: []
        )
        #expect(!ipv4FamilyFailure.status)
        #expect(ipv4FamilyFailure.reason == "PodNetworkIPv4NotReady")

        var ipv6NotReady = readyState
        ipv6NotReady.ipv6Ready = false
        let ipv6FamilyFailure = evaluatePodNetworkReadiness(
            config: config,
            runtimeState: runtimeState,
            readyState: ipv6NotReady,
            networks: []
        )
        #expect(!ipv6FamilyFailure.status)
        #expect(ipv6FamilyFailure.reason == "PodNetworkIPv6NotReady")

        let subnetFailure = evaluatePodNetworkReadiness(
            config: config,
            runtimeState: runtimeState,
            readyState: readyState,
            networks: [
                try makeNetwork(
                    mode: .hostOnly,
                    configuredSubnet: "10.42.1.0/24",
                    runningSubnet: "10.42.1.0/24",
                    configuredIPv6Subnet: "fd42:10:244:17::/64",
                    runningIPv6Subnet: "fd42:10:244:16::/64"
                )
            ]
        )
        #expect(!subnetFailure.status)
        #expect(subnetFailure.reason == "PodNetworkIPv6SubnetMismatch")
    }

    @Test
    func dualStackReadinessRequiresExpectedIPv6Gateway() throws {
        let config = podNetworkConfig(dualStackEnabled: true)
        let runtimeState = podNetworkRuntimeState(ipv6: "fd42:10:244:16::/64")
        let readyState = PodNetworkReadyState(
            networkName: "kubernetes-pods",
            podCIDRs: PodNetworkCIDRs(
                ipv4: "10.42.1.0/24",
                ipv6: "fd42:10:244:16::/64"
            ),
            runtimeGeneration: 1,
            mtu: 1_420,
            expiresAtUnixSeconds: Int64.max,
            ipv4Ready: true,
            ipv6Ready: true
        )
        let invalidGateways: [(included: Bool, value: String?)] = [
            (false, nil),
            (true, "fd42:10:244:17::1"),
            (true, "fd42:10:244:16::"),
            (true, "fd42:10:244:16::2"),
        ]

        for invalidGateway in invalidGateways {
            let condition = evaluatePodNetworkReadiness(
                config: config,
                runtimeState: runtimeState,
                readyState: readyState,
                networks: [
                    try makeNetwork(
                        mode: .hostOnly,
                        configuredSubnet: "10.42.1.0/24",
                        runningSubnet: "10.42.1.0/24",
                        configuredIPv6Subnet: "fd42:10:244:16::/64",
                        runningIPv6Subnet: "fd42:10:244:16::/64",
                        includeIPv6Gateway: invalidGateway.included,
                        runningIPv6Gateway: invalidGateway.value
                    )
                ]
            )

            #expect(!condition.status)
            #expect(condition.reason == "PodNetworkIPv6GatewayMismatch")
        }
    }

    @Test
    func ipv4OnlyReadinessIgnoresAutomaticIPv6StatusWithoutGateway() throws {
        let condition = evaluatePodNetworkReadiness(
            config: podNetworkConfig(),
            runtimeState: podNetworkRuntimeState(),
            readyState: PodNetworkReadyState(
                networkName: "kubernetes-pods",
                podCIDR: "10.42.1.0/24",
                runtimeGeneration: 1,
                mtu: 1_420,
                expiresAtUnixSeconds: Int64.max
            ),
            networks: [
                try makeNetwork(
                    mode: .hostOnly,
                    configuredSubnet: "10.42.1.0/24",
                    runningSubnet: "10.42.1.0/24",
                    runningIPv6Subnet: "fd42:25e3:5eb4:24a4::/64",
                    includeIPv6Gateway: false
                )
            ]
        )

        #expect(condition.status)
        #expect(condition.reason == "PodNetworkReady")
    }

    @Test
    func dualStackReadinessRejectsLegacySingleFamilyRuntimeOrReadyState() throws {
        let config = podNetworkConfig(dualStackEnabled: true)
        let dualRuntime = podNetworkRuntimeState(ipv6: "fd42:10:244:16::/64")
        let legacyReady = PodNetworkReadyState(
            networkName: "kubernetes-pods",
            podCIDR: "10.42.1.0/24",
            runtimeGeneration: 1,
            mtu: 1_420,
            expiresAtUnixSeconds: Int64.max
        )
        #expect(throws: PodNetworkReadyLeaseValidationError.readyStateMismatch) {
            try validatePodNetworkReadyLease(
                config: config,
                runtimeState: dualRuntime,
                readyState: legacyReady
            )
        }

        let dualReady = PodNetworkReadyState(
            networkName: "kubernetes-pods",
            podCIDRs: PodNetworkCIDRs(
                ipv4: "10.42.1.0/24",
                ipv6: "fd42:10:244:16::/64"
            ),
            runtimeGeneration: 1,
            mtu: 1_420,
            expiresAtUnixSeconds: Int64.max,
            ipv4Ready: true,
            ipv6Ready: true
        )
        #expect(throws: PodNetworkReadyLeaseValidationError.runtimeStateMismatch) {
            try validatePodNetworkReadyLease(
                config: config,
                runtimeState: podNetworkRuntimeState(),
                readyState: dualReady
            )
        }
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

private func podNetworkConfig(dualStackEnabled: Bool = false) -> PodNetworkConfig {
    PodNetworkConfig(
        enabled: true,
        dualStackEnabled: dualStackEnabled,
        networkName: "kubernetes-pods",
        runtimeStatePath: "/var/lib/container/pod-network/runtime.json",
        readyStatePath: "/var/lib/container/pod-network/ready.json"
    )
}

private func podNetworkRuntimeState(ipv6: String? = nil) -> PodNetworkRuntimeState {
    PodNetworkRuntimeState(
        networkName: "kubernetes-pods",
        podCIDRs: PodNetworkCIDRs(ipv4: "10.42.1.0/24", ipv6: ipv6),
        generation: 1,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeNetwork(
    mode: NetworkMode,
    configuredSubnet: String,
    runningSubnet: String,
    configuredIPv6Subnet: String? = nil,
    runningIPv6Subnet: String? = nil,
    includeIPv6Gateway: Bool = true,
    runningIPv6Gateway: String? = nil
) throws -> NetworkState {
    let runningIPv6Subnet = try runningIPv6Subnet.map { try CIDRv6($0) }
    let ipv6Gateway: IPv6Address?
    if let runningIPv6Gateway {
        ipv6Gateway = try IPv6Address(runningIPv6Gateway)
    } else if includeIPv6Gateway, let runningIPv6Subnet {
        ipv6Gateway = IPv6Address(runningIPv6Subnet.lower.value + 1)
    } else {
        ipv6Gateway = nil
    }
    return NetworkState(
        configuration: try NetworkConfiguration(
            name: "kubernetes-pods",
            mode: mode,
            ipv4Subnet: try CIDRv4(configuredSubnet),
            ipv6Subnet: try configuredIPv6Subnet.map { try CIDRv6($0) },
            plugin: "container-network-vmnet"
        ),
        status: NetworkStatus(
            ipv4Subnet: try CIDRv4(runningSubnet),
            ipv4Gateway: try IPv4Address("10.42.1.1"),
            ipv6Subnet: runningIPv6Subnet,
            ipv6Gateway: ipv6Gateway
        )
    )
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "CRIShimPodNetworkStateTests-\(UUID().uuidString)",
        isDirectory: true
    )
}
