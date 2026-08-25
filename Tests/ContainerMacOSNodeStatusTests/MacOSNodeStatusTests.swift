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

import ContainerCRIShimMacOS
import ContainerK8sFlannelVXLANMacOS
import ContainerK8sKubeProxyMacOS
import Darwin
import Foundation
import Testing

@testable import container_macos_node_status

struct MacOSNodeStatusTests {
    @Test
    func configurationRequiresBoundedIdentityAndCurrentSchema() throws {
        let expected = MacOSNodeStatusExpectedComponents(
            kubeProxy: true,
            flannel: true,
            vmnetRecovery: true
        )
        let valid = MacOSNodeStatusConfig(
            nodeName: "node-a",
            networkName: "kubernetes-pod",
            expectedComponents: expected
        )
        #expect(try valid.validated() == valid)

        for invalid in [
            MacOSNodeStatusConfig(
                nodeName: "node a",
                networkName: "kubernetes-pod",
                expectedComponents: expected
            ),
            MacOSNodeStatusConfig(
                nodeName: "node-a",
                networkName: "../network",
                expectedComponents: expected
            ),
            MacOSNodeStatusConfig(
                nodeName: "node-a",
                networkName: "kubernetes-pod",
                expectedComponents: expected,
                schemaVersion: 2
            ),
        ] {
            #expect(throws: MacOSNodeStatusConfigError.self) {
                try invalid.validated()
            }
        }
    }

    @Test
    func rendererSortsAndEscapesPrometheusText() {
        var metrics = PrometheusMetrics()
        metrics.gauge(
            "test_second",
            help: "second\\line\nhelp",
            labels: ["value": "slash\\quote\"line\n"],
            value: 2
        )
        metrics.counter("test_first_total", help: "first", value: UInt64.max)

        #expect(
            metrics.rendered()
                == """
                # HELP test_first_total first
                # TYPE test_first_total counter
                test_first_total 18446744073709551615
                # HELP test_second second\\\\line\\nhelp
                # TYPE test_second gauge
                test_second{value="slash\\\\quote\\\"line\\n"} 2

                """
        )
    }

    @Test
    func disabledComponentsDoNotReadStatusFiles() throws {
        let loaders = MacOSNodeStatusLoaders(
            kubeProxy: { throw UnexpectedLoad.invoked },
            flannel: { throw UnexpectedLoad.invoked },
            vmnetRecovery: { throw UnexpectedLoad.invoked }
        )
        let output = try MacOSNodeStatusCollector(loaders: loaders).render(
            config: MacOSNodeStatusConfig(
                nodeName: "node-a",
                networkName: "kubernetes-pod",
                expectedComponents: MacOSNodeStatusExpectedComponents(
                    kubeProxy: false,
                    flannel: false,
                    vmnetRecovery: false
                )
            )
        )

        for component in ["flannel", "kube_proxy", "vmnet_recovery"] {
            #expect(
                output.contains(
                    "container_macos_kubernetes_component_expected{component=\"\(component)\"} 0"
                )
            )
            #expect(
                output.contains(
                    "container_macos_kubernetes_component_status_up{component=\"\(component)\"} 0"
                )
            )
        }
    }

    @Test
    func missingComponentsFailIndependentlyWithBoundedReason() throws {
        let output = try MacOSNodeStatusCollector(
            loaders: MacOSNodeStatusLoaders(
                kubeProxy: { nil },
                flannel: { nil },
                vmnetRecovery: { nil }
            )
        ).render(
            config: MacOSNodeStatusConfig(
                nodeName: "node-a",
                networkName: "kubernetes-pod",
                expectedComponents: MacOSNodeStatusExpectedComponents(
                    kubeProxy: true,
                    flannel: true,
                    vmnetRecovery: true
                )
            )
        )

        for component in ["flannel", "kube_proxy", "vmnet_recovery"] {
            #expect(
                output.contains(
                    "container_macos_kubernetes_component_status_error{component=\"\(component)\",reason=\"missing\"} 1"
                )
            )
            #expect(
                output.contains(
                    "container_macos_kubernetes_component_status_up{component=\"\(component)\"} 0"
                )
            )
        }
        #expect(!output.contains("node-a"))
        #expect(!output.contains("kubernetes-pod"))
    }

    @Test
    func freshDualStackStatusesEmitOperationalMetricsAndFullWidthCounters() throws {
        let output = try renderStatuses(
            kubeProxy: makeKubeProxyStatus(),
            flannel: makeFlannelStatus(),
            vmnetRecovery: makeVMNetRecoveryStatus()
        )

        expectSample(output, "container_macos_kubernetes_collector_up 1")

        for component in MacOSNodeStatusComponent.allCases {
            expectSample(
                output,
                "container_macos_kubernetes_component_status_up{component=\"\(component.rawValue)\"} 1"
            )
            expectSample(
                output,
                "container_macos_kubernetes_component_ready{component=\"\(component.rawValue)\"} 1"
            )
        }

        expectSample(
            output,
            "container_macos_kubernetes_kube_proxy_family_applied{family=\"ipv6\"} 1"
        )
        expectSample(
            output,
            "container_macos_kubernetes_kube_proxy_rules{family=\"ipv6\",kind=\"desired\"} 7"
        )
        expectSample(
            output,
            "container_macos_kubernetes_flannel_family_ready{family=\"ipv6\"} 1"
        )
        expectSample(
            output,
            "container_macos_kubernetes_flannel_peers{family=\"ipv6\"} 4"
        )
        expectSample(
            output,
            "container_macos_kubernetes_vmnet_recovery_phase{phase=\"healthy\"} 1"
        )
        expectSample(
            output,
            "container_macos_kubernetes_vmnet_recovery_admission_rejecting 0"
        )

        let maximum = String(UInt64.max)
        expectSample(
            output,
            "container_macos_kubernetes_flannel_generation{kind=\"runtime\"} \(maximum)"
        )
        expectSample(
            output,
            "container_macos_kubernetes_flannel_tunnel_epoch{family=\"ipv6\"} \(maximum)"
        )
        expectSample(
            output,
            "container_macos_kubernetes_flannel_wire_packets_total{direction=\"transmit\",family=\"ipv6\"} \(maximum)"
        )
        expectSample(
            output,
            "container_macos_kubernetes_vmnet_recovery_sandbox_rejected_total \(maximum)"
        )
        expectSample(
            output,
            "container_macos_kubernetes_vmnet_recovery_reconciles_total{outcome=\"success\"} \(maximum)"
        )
    }

    @Test
    func statusFileLoadersUseExplicitTrustedOwnership() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kubeProxyURL = directory.appendingPathComponent("kube-proxy/status.json")
        let flannelURL = directory.appendingPathComponent("flannel/status.json")
        let vmnetRecoveryURL = directory.appendingPathComponent("vmnet-recovery/status.json")

        try KubeProxyStatusFileStore(
            path: kubeProxyURL.path,
            requiredOwnerID: geteuid()
        ).save(makeKubeProxyStatus())
        try FlannelStatusFileStore(
            path: flannelURL.path,
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid()
        ).save(makeFlannelStatus())
        try VMNetRecoveryStatusFileStore(
            url: vmnetRecoveryURL,
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid()
        ).save(makeVMNetRecoveryStatus())

        let trustedLoaders = MacOSNodeStatusLoaders.statusFiles(
            kubeProxyPath: kubeProxyURL.path,
            flannelPath: flannelURL.path,
            vmnetRecoveryURL: vmnetRecoveryURL,
            requiredOwnerID: geteuid(),
            requiredGroupID: getegid()
        )
        let trustedOutput = try MacOSNodeStatusCollector(loaders: trustedLoaders).render(
            config: fixtureConfig,
            at: fixtureNow
        )
        for component in MacOSNodeStatusComponent.allCases {
            expectSample(
                trustedOutput,
                "container_macos_kubernetes_component_status_up{component=\"\(component.rawValue)\"} 1"
            )
        }

        let unexpectedGroupID: gid_t = getegid() == 0 ? 1 : 0
        let mismatchedOutput = try MacOSNodeStatusCollector(
            loaders: .statusFiles(
                kubeProxyPath: kubeProxyURL.path,
                flannelPath: flannelURL.path,
                vmnetRecoveryURL: vmnetRecoveryURL,
                requiredOwnerID: geteuid(),
                requiredGroupID: unexpectedGroupID
            )
        ).render(config: fixtureConfig, at: fixtureNow)
        expectSample(
            mismatchedOutput,
            "container_macos_kubernetes_component_status_up{component=\"kube_proxy\"} 1"
        )
        for component in [MacOSNodeStatusComponent.flannel, .vmnetRecovery] {
            expectSample(
                mismatchedOutput,
                "container_macos_kubernetes_component_status_error{component=\"\(component.rawValue)\",reason=\"invalid\"} 1"
            )
        }
    }

    @Test
    func thrownLoaderFailsClosedWithoutMaskingHealthyComponents() throws {
        for component in MacOSNodeStatusComponent.allCases {
            let output = try renderStatuses(
                kubeProxy: makeKubeProxyStatus(),
                flannel: makeFlannelStatus(),
                vmnetRecovery: makeVMNetRecoveryStatus(),
                throwing: component
            )
            expectOnlyFailure(output, component: component, reason: .invalid)
        }
    }

    @Test
    func missingLoaderFailsClosedWithoutMaskingHealthyComponents() throws {
        for component in MacOSNodeStatusComponent.allCases {
            let output = try renderStatuses(
                kubeProxy: makeKubeProxyStatus(),
                flannel: makeFlannelStatus(),
                vmnetRecovery: makeVMNetRecoveryStatus(),
                missing: component
            )
            expectOnlyFailure(output, component: component, reason: .missing)
        }
    }

    @Test
    func expiredAndNotYetValidStatusesFailClosedIndependently() throws {
        for window in [StatusWindow.expired, .future] {
            expectOnlyFailure(
                try renderStatuses(
                    kubeProxy: makeKubeProxyStatus(window: window),
                    flannel: makeFlannelStatus(),
                    vmnetRecovery: makeVMNetRecoveryStatus()
                ),
                component: .kubeProxy,
                reason: .expired
            )
            expectOnlyFailure(
                try renderStatuses(
                    kubeProxy: makeKubeProxyStatus(),
                    flannel: makeFlannelStatus(window: window),
                    vmnetRecovery: makeVMNetRecoveryStatus()
                ),
                component: .flannel,
                reason: .expired
            )
            expectOnlyFailure(
                try renderStatuses(
                    kubeProxy: makeKubeProxyStatus(),
                    flannel: makeFlannelStatus(),
                    vmnetRecovery: makeVMNetRecoveryStatus(window: window)
                ),
                component: .vmnetRecovery,
                reason: .expired
            )
        }
    }

    @Test
    func identityMismatchesFailClosedIndependently() throws {
        expectOnlyFailure(
            try renderStatuses(
                kubeProxy: makeKubeProxyStatus(nodeName: "other-node"),
                flannel: makeFlannelStatus(),
                vmnetRecovery: makeVMNetRecoveryStatus()
            ),
            component: .kubeProxy,
            reason: .nodeMismatch
        )
        expectOnlyFailure(
            try renderStatuses(
                kubeProxy: makeKubeProxyStatus(),
                flannel: makeFlannelStatus(nodeName: "other-node"),
                vmnetRecovery: makeVMNetRecoveryStatus()
            ),
            component: .flannel,
            reason: .nodeMismatch
        )
        expectOnlyFailure(
            try renderStatuses(
                kubeProxy: makeKubeProxyStatus(),
                flannel: makeFlannelStatus(),
                vmnetRecovery: makeVMNetRecoveryStatus(nodeName: "other-node")
            ),
            component: .vmnetRecovery,
            reason: .nodeMismatch
        )
        expectOnlyFailure(
            try renderStatuses(
                kubeProxy: makeKubeProxyStatus(),
                flannel: makeFlannelStatus(networkName: "other-network"),
                vmnetRecovery: makeVMNetRecoveryStatus()
            ),
            component: .flannel,
            reason: .networkMismatch
        )
        expectOnlyFailure(
            try renderStatuses(
                kubeProxy: makeKubeProxyStatus(),
                flannel: makeFlannelStatus(),
                vmnetRecovery: makeVMNetRecoveryStatus(networkName: "other-network")
            ),
            component: .vmnetRecovery,
            reason: .networkMismatch
        )
    }

    @Test
    func statusPayloadIdentityTopologyAndErrorsAreNeverExported() throws {
        let output = try renderStatuses(
            kubeProxy: makeFailedKubeProxyStatus(),
            flannel: makeDegradedFlannelStatus(),
            vmnetRecovery: makeDegradedVMNetRecoveryStatus()
        )

        for sensitiveValue in [
            fixtureNodeName,
            fixtureNetworkName,
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002",
            "00000000-0000-4000-8000-000000000003",
            "sensitive-network-instance",
            "sensitive-boot-session",
            "fd42:10:244:22::/64",
            "10.250.22.0/24",
            "sensitive-utun4",
            "sensitive-utun5",
            "sensitive_error_code",
            "sensitive error message",
            "sensitive failure reason",
        ] {
            #expect(!output.contains(sensitiveValue))
        }
    }

    @Test
    func freshFailedAndDegradedStatusesRemainUpButNotReady() throws {
        let output = try renderStatuses(
            kubeProxy: makeFailedKubeProxyStatus(),
            flannel: makeDegradedFlannelStatus(),
            vmnetRecovery: makeDegradedVMNetRecoveryStatus()
        )

        for component in MacOSNodeStatusComponent.allCases {
            expectSample(
                output,
                "container_macos_kubernetes_component_status_up{component=\"\(component.rawValue)\"} 1"
            )
            expectSample(
                output,
                "container_macos_kubernetes_component_ready{component=\"\(component.rawValue)\"} 0"
            )
        }
    }

    @Test
    func secureConfigurationFileRoundTripsAtMode0600() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("node-status.json")
        try writeConfiguration(fixtureConfig, to: url, permissions: 0o600)

        #expect(try MacOSNodeStatusConfigFile(path: url.path).load() == fixtureConfig)
    }

    @Test
    func configurationReaderAllowsReadOnlyDirectoryACLButRejectsMutation() throws {
        let readOnlyDirectory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: readOnlyDirectory) }
        let readOnlyURL = readOnlyDirectory.appendingPathComponent("node-status.json")
        try writeConfiguration(fixtureConfig, to: readOnlyURL, permissions: 0o600)
        try addACL("everyone allow list,search", to: readOnlyDirectory)
        #expect(try MacOSNodeStatusConfigFile(path: readOnlyURL.path).load() == fixtureConfig)

        let mutableDirectory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: mutableDirectory) }
        let mutableURL = mutableDirectory.appendingPathComponent("node-status.json")
        try writeConfiguration(fixtureConfig, to: mutableURL, permissions: 0o600)
        try addACL("everyone allow add_file", to: mutableDirectory)
        expectConfigurationRejected(at: mutableURL)
    }

    @Test
    func configurationReaderRejectsGroupOrWorldWritableDirectory() throws {
        for permissions in [0o720, 0o702] {
            let directory = try makePrivateTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("node-status.json")
            try writeConfiguration(fixtureConfig, to: url, permissions: 0o600)
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: directory.path
            )

            expectConfigurationRejected(at: url)
        }
    }

    @Test
    func configurationReaderRejectsUnsafeFilesWithoutFollowingOrBlocking() throws {
        let directory = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetURL = directory.appendingPathComponent("target.json")
        try writeConfiguration(fixtureConfig, to: targetURL, permissions: 0o600)
        let symlinkURL = directory.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: targetURL.path
        )
        expectConfigurationRejected(at: symlinkURL)

        let fifoURL = directory.appendingPathComponent("fifo.json")
        #expect(mkfifo(fifoURL.path, mode_t(0o600)) == 0)
        expectConfigurationRejected(at: fifoURL)

        let wrongModeURL = directory.appendingPathComponent("wrong-mode.json")
        try writeConfiguration(fixtureConfig, to: wrongModeURL, permissions: 0o644)
        expectConfigurationRejected(at: wrongModeURL)

        let aclURL = directory.appendingPathComponent("extended-acl.json")
        try writeConfiguration(fixtureConfig, to: aclURL, permissions: 0o600)
        try addEveryoneReadACL(to: aclURL)
        expectConfigurationRejected(at: aclURL)

        let oversizedURL = directory.appendingPathComponent("oversized.json")
        try Data(count: 16 * 1_024 + 1).write(to: oversizedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: oversizedURL.path
        )
        expectConfigurationRejected(at: oversizedURL)
    }
}

private enum UnexpectedLoad: Error {
    case invoked
}

private let fixtureNodeName = "node-a"
private let fixtureNetworkName = "kubernetes-pod"
private let fixtureNow = Date(timeIntervalSince1970: 1_700_000_030)
private let fixtureConfig = MacOSNodeStatusConfig(
    nodeName: fixtureNodeName,
    networkName: fixtureNetworkName,
    expectedComponents: MacOSNodeStatusExpectedComponents(
        kubeProxy: true,
        flannel: true,
        vmnetRecovery: true
    )
)

private struct StatusWindow: Sendable {
    var updatedAt: String
    var expiresAt: String
    var stateSince: String

    static let fresh = make(updatedOffset: 0, expiresOffset: 120)
    static let expired = make(updatedOffset: -300, expiresOffset: -180)
    static let future = make(updatedOffset: 180, expiresOffset: 300)

    private static func make(updatedOffset: TimeInterval, expiresOffset: TimeInterval) -> Self {
        Self(
            updatedAt: timestamp(offset: updatedOffset),
            expiresAt: timestamp(offset: expiresOffset),
            stateSince: timestamp(offset: updatedOffset - 10)
        )
    }
}

private func renderStatuses(
    kubeProxy: KubeProxyStatus?,
    flannel: FlannelStatus?,
    vmnetRecovery: VMNetRecoveryStatus?,
    missing missingComponent: MacOSNodeStatusComponent? = nil,
    throwing throwingComponent: MacOSNodeStatusComponent? = nil
) throws -> String {
    try MacOSNodeStatusCollector(
        loaders: MacOSNodeStatusLoaders(
            kubeProxy: {
                if throwingComponent?.rawValue == MacOSNodeStatusComponent.kubeProxy.rawValue {
                    throw UnexpectedLoad.invoked
                }
                if missingComponent?.rawValue == MacOSNodeStatusComponent.kubeProxy.rawValue {
                    return nil
                }
                return kubeProxy
            },
            flannel: {
                if throwingComponent?.rawValue == MacOSNodeStatusComponent.flannel.rawValue {
                    throw UnexpectedLoad.invoked
                }
                if missingComponent?.rawValue == MacOSNodeStatusComponent.flannel.rawValue {
                    return nil
                }
                return flannel
            },
            vmnetRecovery: {
                if throwingComponent?.rawValue == MacOSNodeStatusComponent.vmnetRecovery.rawValue {
                    throw UnexpectedLoad.invoked
                }
                if missingComponent?.rawValue == MacOSNodeStatusComponent.vmnetRecovery.rawValue {
                    return nil
                }
                return vmnetRecovery
            }
        )
    ).render(config: fixtureConfig, at: fixtureNow)
}

private func expectOnlyFailure(
    _ output: String,
    component: MacOSNodeStatusComponent,
    reason: MacOSNodeStatusFailureReason
) {
    expectSample(
        output,
        "container_macos_kubernetes_component_status_up{component=\"\(component.rawValue)\"} 0"
    )
    expectSample(
        output,
        "container_macos_kubernetes_component_ready{component=\"\(component.rawValue)\"} 0"
    )
    for candidate in MacOSNodeStatusFailureReason.allCases {
        let value = candidate.rawValue == reason.rawValue ? 1 : 0
        expectSample(
            output,
            "container_macos_kubernetes_component_status_error{component=\"\(component.rawValue)\"," + "reason=\"\(candidate.rawValue)\"} \(value)"
        )
    }
    for healthy in MacOSNodeStatusComponent.allCases where healthy.rawValue != component.rawValue {
        expectSample(
            output,
            "container_macos_kubernetes_component_status_up{component=\"\(healthy.rawValue)\"} 1"
        )
        expectSample(
            output,
            "container_macos_kubernetes_component_ready{component=\"\(healthy.rawValue)\"} 1"
        )
    }
}

private func expectSample(_ output: String, _ sample: String) {
    #expect(output.split(separator: "\n").contains(Substring(sample)))
}

private func makeKubeProxyStatus(
    nodeName: String = fixtureNodeName,
    window: StatusWindow = .fresh
) -> KubeProxyStatus {
    KubeProxyStatus(
        nodeName: nodeName,
        controllerInstanceID: "00000000-0000-4000-8000-000000000001",
        updatedAt: window.updatedAt,
        expiresAt: window.expiresAt,
        stateSince: window.stateSince,
        lastSuccessAt: window.updatedAt,
        state: .applied,
        attemptedGeneration: 17,
        lastAppliedGeneration: 17,
        consecutiveSuccesses: 3,
        ipv4: KubeProxyFamilyStatus(
            enabled: true,
            applied: true,
            desiredRuleCount: 5,
            appliedRuleCount: 5
        ),
        ipv6: KubeProxyFamilyStatus(
            enabled: true,
            applied: true,
            desiredRuleCount: 7,
            appliedRuleCount: 7
        ),
        pf: KubeProxyPFStatus(
            finalState: .applied,
            applyAttempted: true,
            applySucceeded: true,
            withdrawalAttempted: false,
            withdrawalSucceeded: nil,
            rollbackAttempted: false,
            rollbackSucceeded: nil
        )
    )
}

private func makeFailedKubeProxyStatus() -> KubeProxyStatus {
    KubeProxyStatus(
        nodeName: fixtureNodeName,
        controllerInstanceID: "00000000-0000-4000-8000-000000000001",
        updatedAt: StatusWindow.fresh.updatedAt,
        expiresAt: StatusWindow.fresh.expiresAt,
        stateSince: StatusWindow.fresh.stateSince,
        lastSuccessAt: nil,
        state: .failed,
        attemptedGeneration: 1,
        consecutiveFailures: 1,
        errorCode: "sensitive_error_code",
        errorMessage: "sensitive error message",
        ipv4: KubeProxyFamilyStatus(
            enabled: true,
            applied: nil,
            desiredRuleCount: nil,
            appliedRuleCount: nil
        ),
        ipv6: KubeProxyFamilyStatus(
            enabled: true,
            applied: nil,
            desiredRuleCount: nil,
            appliedRuleCount: nil
        ),
        pf: KubeProxyPFStatus(
            finalState: .unknown,
            applyAttempted: nil,
            applySucceeded: nil,
            withdrawalAttempted: nil,
            withdrawalSucceeded: nil,
            rollbackAttempted: nil,
            rollbackSucceeded: nil
        )
    )
}

private func makeFlannelStatus(
    nodeName: String = fixtureNodeName,
    networkName: String = fixtureNetworkName,
    window: StatusWindow = .fresh
) -> FlannelStatus {
    FlannelStatus(
        nodeName: nodeName,
        networkName: networkName,
        controllerInstanceID: "00000000-0000-4000-8000-000000000002",
        updatedAt: window.updatedAt,
        expiresAt: window.expiresAt,
        stateSince: window.stateSince,
        lastSuccessAt: window.updatedAt,
        state: .ready,
        attemptedGeneration: 19,
        lastSuccessfulGeneration: 19,
        runtimeGeneration: UInt64.max,
        mtu: 1_450,
        ipv4: makeFlannelFamily(
            podCIDR: "10.250.22.0/24",
            interfaceName: "sensitive-utun4",
            peerCount: 3,
            routeCount: 3,
            tunnelEpoch: 23,
            transmittedPackets: 29
        ),
        ipv6: makeFlannelFamily(
            podCIDR: "fd42:10:244:22::/64",
            interfaceName: "sensitive-utun5",
            peerCount: 4,
            routeCount: 5,
            tunnelEpoch: UInt64.max,
            transmittedPackets: UInt64.max
        )
    )
}

private func makeDegradedFlannelStatus() -> FlannelStatus {
    var status = makeFlannelStatus()
    status.state = .degraded
    status.errorCode = "sensitive_error_code"
    status.errorMessage = "sensitive error message"
    return status
}

private func makeFlannelFamily(
    podCIDR: String,
    interfaceName: String,
    peerCount: Int,
    routeCount: Int,
    tunnelEpoch: UInt64,
    transmittedPackets: UInt64
) -> FlannelFamilyStatus {
    FlannelFamilyStatus(
        enabled: true,
        ready: true,
        podCIDR: podCIDR,
        peerCount: peerCount,
        routeCount: routeCount,
        tunnelUp: true,
        interfaceName: interfaceName,
        tunnelEpoch: tunnelEpoch,
        wireCounters: FlannelStatusWireCounters(
            transmittedPackets: transmittedPackets,
            transmittedBytes: 31,
            receivedPackets: 37,
            receivedBytes: 41,
            unknownPeerPackets: 43,
            invalidPackets: 47,
            oversizedPackets: 53,
            sourceCIDRMismatches: 59
        )
    )
}

private func makeVMNetRecoveryStatus(
    nodeName: String = fixtureNodeName,
    networkName: String = fixtureNetworkName,
    window: StatusWindow = .fresh
) -> VMNetRecoveryStatus {
    VMNetRecoveryStatus(
        nodeName: nodeName,
        networkName: networkName,
        coordinatorInstanceID: "00000000-0000-4000-8000-000000000003",
        updatedAt: window.updatedAt,
        expiresAt: window.expiresAt,
        phaseSince: window.stateSince,
        lastSuccessAt: window.updatedAt,
        state: .ready,
        phase: .healthy,
        authorityPhase: .healthy,
        networkInstanceID: "sensitive-network-instance",
        currentBootSessionID: "sensitive-boot-session",
        stateBootSessionID: "sensitive-boot-session",
        authorityUpdatedAt: window.updatedAt,
        recoveryWindowStartedAt: nil,
        requestPending: false,
        sandboxAdmissionRejecting: false,
        sandboxRejectedTotal: UInt64.max,
        fenceActive: false,
        failureReason: nil,
        rebootAttempts: 1,
        maxRebootAttempts: 3,
        lastRebootRequestedAt: nil,
        rebootCommandResult: .recovered,
        consecutiveHealthyProbeFailures: 0,
        healthyProbeFailureThreshold: 3,
        loopProtectionBlocked: false,
        counters: VMNetRecoveryStatusCounters(
            successfulReconciles: UInt64.max,
            failedReconciles: 61,
            fencesObserved: 67,
            rebootCommandsAccepted: 71,
            rebootCommandsFailed: 73,
            rebootsObserved: 79,
            recoveriesSucceeded: 83,
            recoveriesFailed: 89,
            loopProtectionBlocks: 97
        ),
        errorCode: nil,
        errorMessage: nil
    )
}

private func makeDegradedVMNetRecoveryStatus() -> VMNetRecoveryStatus {
    var status = makeVMNetRecoveryStatus()
    status.state = .degraded
    status.phase = .probeDegraded
    status.failureReason = "sensitive failure reason"
    status.errorCode = "sensitive_error_code"
    status.errorMessage = "sensitive error message"
    return status
}

private func timestamp(offset: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 + offset))
}

private func makePrivateTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("macos-node-status-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func writeConfiguration(
    _ config: MacOSNodeStatusConfig,
    to url: URL,
    permissions: Int
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(config).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: url.path
    )
}

private func expectConfigurationRejected(at url: URL) {
    #expect(throws: MacOSNodeStatusConfigError.self) {
        try MacOSNodeStatusConfigFile(path: url.path).load()
    }
}

private func addEveryoneReadACL(to url: URL) throws {
    try addACL("everyone allow read", to: url)
}

private func addACL(_ entry: String, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", entry, url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw MacOSNodeStatusConfigError.invalid(
            "failed to add an extended ACL to the test fixture"
        )
    }
}
