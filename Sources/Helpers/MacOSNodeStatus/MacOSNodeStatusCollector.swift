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

private let trustedStatusOwnerID: uid_t = 0
private let trustedStatusGroupID: gid_t = 0

enum MacOSNodeStatusComponent: String, CaseIterable, Sendable {
    case flannel
    case kubeProxy = "kube_proxy"
    case vmnetRecovery = "vmnet_recovery"
}

enum MacOSNodeStatusFailureReason: String, CaseIterable, Sendable {
    case expired
    case invalid
    case missing
    case networkMismatch = "network_mismatch"
    case nodeMismatch = "node_mismatch"
}

struct MacOSNodeStatusLoaders: Sendable {
    var kubeProxy: @Sendable () throws -> KubeProxyStatus?
    var flannel: @Sendable () throws -> FlannelStatus?
    var vmnetRecovery: @Sendable () throws -> VMNetRecoveryStatus?

    static var production: Self {
        statusFiles(
            kubeProxyPath: KubeProxyMacOSConfig.defaultStatusPath,
            flannelPath: FlannelVXLANMacOSConfig.defaultStatusPath,
            vmnetRecoveryURL: CRIShimConfigDefaults.vmnetRecoveryStatusURL,
            requiredOwnerID: trustedStatusOwnerID,
            requiredGroupID: trustedStatusGroupID
        )
    }

    static func statusFiles(
        kubeProxyPath: String,
        flannelPath: String,
        vmnetRecoveryURL: URL,
        requiredOwnerID: uid_t,
        requiredGroupID: gid_t
    ) -> Self {
        Self(
            kubeProxy: {
                try KubeProxyStatusFileStore(
                    path: kubeProxyPath,
                    requiredOwnerID: requiredOwnerID
                ).load()
            },
            flannel: {
                try FlannelStatusFileStore(
                    path: flannelPath,
                    requiredOwnerID: requiredOwnerID,
                    requiredGroupID: requiredGroupID
                ).load()
            },
            vmnetRecovery: {
                try VMNetRecoveryStatusFileStore(
                    url: vmnetRecoveryURL,
                    requiredOwnerID: requiredOwnerID,
                    requiredGroupID: requiredGroupID
                ).load()
            }
        )
    }
}

struct MacOSNodeStatusCollector: Sendable {
    private let loaders: MacOSNodeStatusLoaders

    init(loaders: MacOSNodeStatusLoaders = .production) {
        self.loaders = loaders
    }

    func render(config: MacOSNodeStatusConfig, at now: Date = Date()) throws -> String {
        let config = try config.validated()
        var metrics = PrometheusMetrics()
        metrics.gauge(
            "container_macos_kubernetes_collector_up",
            help: "Whether the macOS Kubernetes node status collection completed.",
            value: true
        )
        collectKubeProxy(config: config, at: now, into: &metrics)
        collectFlannel(config: config, at: now, into: &metrics)
        collectVMNetRecovery(config: config, at: now, into: &metrics)
        return metrics.rendered()
    }

    private func collectKubeProxy(
        config: MacOSNodeStatusConfig,
        at now: Date,
        into metrics: inout PrometheusMetrics
    ) {
        let expected = config.expectedComponents.kubeProxy
        let inspection: Inspection<KubeProxyStatus>
        if expected {
            do {
                guard let status = try loaders.kubeProxy() else {
                    inspection = .failed(.missing)
                    emitCommon(.kubeProxy, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                guard status.nodeName == config.nodeName else {
                    inspection = .failed(.nodeMismatch)
                    emitCommon(.kubeProxy, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                guard try status.freshness(at: now) == .fresh else {
                    inspection = .failed(.expired)
                    emitCommon(.kubeProxy, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                inspection = .valid(status)
            } catch {
                inspection = .failed(.invalid)
            }
        } else {
            inspection = .disabled
        }
        emitCommon(.kubeProxy, expected: expected, inspection: inspection, into: &metrics)
        guard case .valid(let status) = inspection else {
            return
        }

        emitState(
            component: .kubeProxy,
            current: status.state.rawValue,
            all: ["starting", "applied", "waitingForPodIngressRoute", "failed"],
            into: &metrics
        )
        emitKubeProxyFamily(status.ipv4, family: "ipv4", into: &metrics)
        emitKubeProxyFamily(status.ipv6, family: "ipv6", into: &metrics)
        metrics.gauge(
            "container_macos_kubernetes_kube_proxy_generation",
            help: "Kube-proxy reconcile generation by kind.",
            labels: ["kind": "attempted"],
            value: status.attemptedGeneration
        )
        emitOptionalGauge(
            status.lastAppliedGeneration,
            name: "container_macos_kubernetes_kube_proxy_generation",
            help: "Kube-proxy reconcile generation by kind.",
            labels: ["kind": "last_applied"],
            into: &metrics
        )
        for (kind, value) in [
            ("pending", status.consecutivePendingCycles),
            ("success", status.consecutiveSuccesses),
            ("failure", status.consecutiveFailures),
        ] {
            metrics.gauge(
                "container_macos_kubernetes_kube_proxy_consecutive_cycles",
                help: "Consecutive kube-proxy reconcile cycles by outcome.",
                labels: ["outcome": kind],
                value: value
            )
        }
        emitOneHot(
            name: "container_macos_kubernetes_kube_proxy_pf_state",
            help: "Final kube-proxy PF state.",
            label: "state",
            current: status.pf.finalState.rawValue,
            values: ["applied", "withdrawn", "unknown"],
            baseLabels: [:],
            into: &metrics
        )
    }

    private func collectFlannel(
        config: MacOSNodeStatusConfig,
        at now: Date,
        into metrics: inout PrometheusMetrics
    ) {
        let expected = config.expectedComponents.flannel
        let inspection: Inspection<FlannelStatus>
        if expected {
            do {
                guard let status = try loaders.flannel() else {
                    inspection = .failed(.missing)
                    emitCommon(.flannel, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                guard status.nodeName == config.nodeName else {
                    inspection = .failed(.nodeMismatch)
                    emitCommon(.flannel, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                guard status.networkName == config.networkName else {
                    inspection = .failed(.networkMismatch)
                    emitCommon(.flannel, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                guard try status.freshness(at: now) == .fresh else {
                    inspection = .failed(.expired)
                    emitCommon(.flannel, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                inspection = .valid(status)
            } catch {
                inspection = .failed(.invalid)
            }
        } else {
            inspection = .disabled
        }
        emitCommon(.flannel, expected: expected, inspection: inspection, into: &metrics)
        guard case .valid(let status) = inspection else {
            return
        }

        emitState(
            component: .flannel,
            current: status.state.rawValue,
            all: ["starting", "ready", "degraded", "failed"],
            into: &metrics
        )
        emitFlannelFamily(status.ipv4, family: "ipv4", into: &metrics)
        emitFlannelFamily(status.ipv6, family: "ipv6", into: &metrics)
        metrics.gauge(
            "container_macos_kubernetes_flannel_generation",
            help: "Flannel generation by kind.",
            labels: ["kind": "attempted"],
            value: status.attemptedGeneration
        )
        emitOptionalGauge(
            status.lastSuccessfulGeneration,
            name: "container_macos_kubernetes_flannel_generation",
            help: "Flannel generation by kind.",
            labels: ["kind": "last_successful"],
            into: &metrics
        )
        emitOptionalGauge(
            status.runtimeGeneration,
            name: "container_macos_kubernetes_flannel_generation",
            help: "Flannel generation by kind.",
            labels: ["kind": "runtime"],
            into: &metrics
        )
        emitOptionalGauge(
            status.mtu,
            name: "container_macos_kubernetes_flannel_mtu_bytes",
            help: "Flannel inner MTU in bytes.",
            into: &metrics
        )
    }

    private func collectVMNetRecovery(
        config: MacOSNodeStatusConfig,
        at now: Date,
        into metrics: inout PrometheusMetrics
    ) {
        let expected = config.expectedComponents.vmnetRecovery
        let inspection: Inspection<VMNetRecoveryStatus>
        if expected {
            do {
                guard let status = try loaders.vmnetRecovery() else {
                    inspection = .failed(.missing)
                    emitCommon(.vmnetRecovery, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                guard status.nodeName == config.nodeName else {
                    inspection = .failed(.nodeMismatch)
                    emitCommon(.vmnetRecovery, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                guard status.networkName == config.networkName else {
                    inspection = .failed(.networkMismatch)
                    emitCommon(.vmnetRecovery, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                guard try status.freshness(at: now) == .fresh else {
                    inspection = .failed(.expired)
                    emitCommon(.vmnetRecovery, expected: true, inspection: inspection, into: &metrics)
                    return
                }
                inspection = .valid(status)
            } catch {
                inspection = .failed(.invalid)
            }
        } else {
            inspection = .disabled
        }
        emitCommon(.vmnetRecovery, expected: expected, inspection: inspection, into: &metrics)
        guard case .valid(let status) = inspection else {
            return
        }

        emitState(
            component: .vmnetRecovery,
            current: status.state.rawValue,
            all: ["starting", "ready", "degraded", "failed"],
            into: &metrics
        )
        emitOneHot(
            name: "container_macos_kubernetes_vmnet_recovery_phase",
            help: "Current VMNet recovery phase.",
            label: "phase",
            current: status.phase.rawValue,
            values: [
                "starting", "initializing", "healthy", "probeDegraded", "fenced",
                "rebootRequested", "waitingForReboot", "verifying", "blocked", "failed",
            ],
            baseLabels: [:],
            into: &metrics
        )
        for (name, help, value) in [
            (
                "container_macos_kubernetes_vmnet_recovery_admission_rejecting",
                "Whether VMNet recovery authority rejects new sandbox admission.",
                status.sandboxAdmissionRejecting
            ),
            (
                "container_macos_kubernetes_vmnet_recovery_fence_active",
                "Whether the VMNet recovery fence is active.",
                status.fenceActive
            ),
            (
                "container_macos_kubernetes_vmnet_recovery_loop_protection_blocked",
                "Whether VMNet recovery loop protection is blocking another reboot.",
                status.loopProtectionBlocked
            ),
        ] {
            metrics.gauge(name, help: help, value: value)
        }
        emitOptionalBoolGauge(
            status.requestPending,
            name: "container_macos_kubernetes_vmnet_recovery_request_pending",
            help: "Whether a VMNet recovery request is pending.",
            into: &metrics
        )
        for (kind, value) in [
            ("current", status.rebootAttempts),
            ("maximum", status.maxRebootAttempts),
        ] {
            metrics.gauge(
                "container_macos_kubernetes_vmnet_recovery_reboot_attempts",
                help: "VMNet recovery reboot attempt count and configured maximum.",
                labels: ["kind": kind],
                value: value
            )
        }
        for (kind, value) in [
            ("consecutive_failures", status.consecutiveHealthyProbeFailures),
            ("failure_threshold", status.healthyProbeFailureThreshold),
        ] {
            metrics.gauge(
                "container_macos_kubernetes_vmnet_recovery_probe_cycles",
                help: "VMNet recovery healthy-probe failure count and threshold.",
                labels: ["kind": kind],
                value: value
            )
        }
        emitOptionalCounter(
            status.sandboxRejectedTotal,
            name: "container_macos_kubernetes_vmnet_recovery_sandbox_rejected_total",
            help: "Persisted and verified sandbox admission rejection events in the current boot.",
            into: &metrics
        )
        emitVMNetCounters(status.counters, into: &metrics)
    }

    private func emitCommon<T: Sendable>(
        _ component: MacOSNodeStatusComponent,
        expected: Bool,
        inspection: Inspection<T>,
        into metrics: inout PrometheusMetrics
    ) {
        let labels = ["component": component.rawValue]
        metrics.gauge(
            "container_macos_kubernetes_component_expected",
            help: "Whether a macOS Kubernetes node component is expected by configuration.",
            labels: labels,
            value: expected
        )
        metrics.gauge(
            "container_macos_kubernetes_component_status_up",
            help: "Whether a component status is safe, valid, identity-matched, and fresh.",
            labels: labels,
            value: inspection.isValid
        )
        metrics.gauge(
            "container_macos_kubernetes_component_ready",
            help: "Whether a component reports its ready operational state.",
            labels: labels,
            value: ready(component: component, inspection: inspection)
        )
        for reason in MacOSNodeStatusFailureReason.allCases {
            metrics.gauge(
                "container_macos_kubernetes_component_status_error",
                help: "Status collection failure by bounded reason.",
                labels: ["component": component.rawValue, "reason": reason.rawValue],
                value: inspection.failureReason == reason
            )
        }
    }

    private func ready<T: Sendable>(component: MacOSNodeStatusComponent, inspection: Inspection<T>) -> Bool {
        guard case .valid(let value) = inspection else {
            return false
        }
        switch component {
        case .kubeProxy:
            return (value as? KubeProxyStatus)?.state == .applied
        case .flannel:
            return (value as? FlannelStatus)?.state == .ready
        case .vmnetRecovery:
            return (value as? VMNetRecoveryStatus)?.state == .ready
        }
    }

    private func emitState(
        component: MacOSNodeStatusComponent,
        current: String,
        all: [String],
        into metrics: inout PrometheusMetrics
    ) {
        emitOneHot(
            name: "container_macos_kubernetes_component_state",
            help: "Current validated component state.",
            label: "state",
            current: current,
            values: all,
            baseLabels: ["component": component.rawValue],
            into: &metrics
        )
    }

    private func emitKubeProxyFamily(
        _ familyStatus: KubeProxyFamilyStatus,
        family: String,
        into metrics: inout PrometheusMetrics
    ) {
        let labels = ["family": family]
        metrics.gauge(
            "container_macos_kubernetes_kube_proxy_family_enabled",
            help: "Whether kube-proxy enables an IP family.",
            labels: labels,
            value: familyStatus.enabled
        )
        emitOptionalBoolGauge(
            familyStatus.applied,
            name: "container_macos_kubernetes_kube_proxy_family_applied",
            help: "Whether kube-proxy applied an IP family.",
            labels: labels,
            into: &metrics
        )
        emitOptionalGauge(
            familyStatus.desiredRuleCount,
            name: "container_macos_kubernetes_kube_proxy_rules",
            help: "Kube-proxy PF rule count by family and kind.",
            labels: ["family": family, "kind": "desired"],
            into: &metrics
        )
        emitOptionalGauge(
            familyStatus.appliedRuleCount,
            name: "container_macos_kubernetes_kube_proxy_rules",
            help: "Kube-proxy PF rule count by family and kind.",
            labels: ["family": family, "kind": "applied"],
            into: &metrics
        )
    }

    private func emitFlannelFamily(
        _ familyStatus: FlannelFamilyStatus,
        family: String,
        into metrics: inout PrometheusMetrics
    ) {
        let labels = ["family": family]
        metrics.gauge(
            "container_macos_kubernetes_flannel_family_enabled",
            help: "Whether Flannel enables an IP family.",
            labels: labels,
            value: familyStatus.enabled
        )
        emitOptionalBoolGauge(
            familyStatus.ready,
            name: "container_macos_kubernetes_flannel_family_ready",
            help: "Whether a Flannel family is ready.",
            labels: labels,
            into: &metrics
        )
        emitOptionalBoolGauge(
            familyStatus.tunnelUp,
            name: "container_macos_kubernetes_flannel_tunnel_up",
            help: "Whether a Flannel family tunnel is running.",
            labels: labels,
            into: &metrics
        )
        emitOptionalGauge(
            familyStatus.peerCount,
            name: "container_macos_kubernetes_flannel_peers",
            help: "Flannel peer count by family.",
            labels: labels,
            into: &metrics
        )
        emitOptionalGauge(
            familyStatus.routeCount,
            name: "container_macos_kubernetes_flannel_routes",
            help: "Flannel route count by family.",
            labels: labels,
            into: &metrics
        )
        emitOptionalGauge(
            familyStatus.tunnelEpoch,
            name: "container_macos_kubernetes_flannel_tunnel_epoch",
            help: "Flannel tunnel epoch by family.",
            labels: labels,
            into: &metrics
        )
        guard let counters = familyStatus.wireCounters else {
            return
        }
        for (direction, packets, bytes) in [
            ("transmit", counters.transmittedPackets, counters.transmittedBytes),
            ("receive", counters.receivedPackets, counters.receivedBytes),
        ] {
            metrics.counter(
                "container_macos_kubernetes_flannel_wire_packets_total",
                help: "Flannel wire packets by family and direction.",
                labels: ["direction": direction, "family": family],
                value: packets
            )
            metrics.counter(
                "container_macos_kubernetes_flannel_wire_bytes_total",
                help: "Flannel wire bytes by family and direction.",
                labels: ["direction": direction, "family": family],
                value: bytes
            )
        }
        for (reason, value) in [
            ("unknown_peer", counters.unknownPeerPackets),
            ("invalid", counters.invalidPackets),
            ("oversized", counters.oversizedPackets),
            ("source_cidr_mismatch", counters.sourceCIDRMismatches),
        ] {
            metrics.counter(
                "container_macos_kubernetes_flannel_wire_discarded_packets_total",
                help: "Flannel discarded wire packets by bounded reason.",
                labels: ["family": family, "reason": reason],
                value: value
            )
        }
    }

    private func emitVMNetCounters(
        _ counters: VMNetRecoveryStatusCounters,
        into metrics: inout PrometheusMetrics
    ) {
        for (outcome, value) in [
            ("success", counters.successfulReconciles),
            ("failure", counters.failedReconciles),
        ] {
            metrics.counter(
                "container_macos_kubernetes_vmnet_recovery_reconciles_total",
                help: "VMNet recovery reconcile results.",
                labels: ["outcome": outcome],
                value: value
            )
        }
        for (event, value) in [
            ("fence_observed", counters.fencesObserved),
            ("reboot_command_accepted", counters.rebootCommandsAccepted),
            ("reboot_command_failed", counters.rebootCommandsFailed),
            ("reboot_observed", counters.rebootsObserved),
            ("recovery_succeeded", counters.recoveriesSucceeded),
            ("recovery_failed", counters.recoveriesFailed),
            ("loop_protection_blocked", counters.loopProtectionBlocks),
        ] {
            metrics.counter(
                "container_macos_kubernetes_vmnet_recovery_events_total",
                help: "VMNet recovery lifecycle events by bounded type.",
                labels: ["event": event],
                value: value
            )
        }
    }

    private func emitOneHot(
        name: String,
        help: String,
        label: String,
        current: String,
        values: [String],
        baseLabels: [String: String],
        into metrics: inout PrometheusMetrics
    ) {
        precondition(values.contains(current), "current value must be bounded")
        for value in values {
            var labels = baseLabels
            labels[label] = value
            metrics.gauge(name, help: help, labels: labels, value: value == current)
        }
    }

    private func emitOptionalBoolGauge(
        _ value: Bool?,
        name: String,
        help: String,
        labels: [String: String] = [:],
        into metrics: inout PrometheusMetrics
    ) {
        metrics.gauge(
            "\(name)_known",
            help: "Whether the optional metric value is known.",
            labels: labels,
            value: value != nil
        )
        if let value {
            metrics.gauge(name, help: help, labels: labels, value: value)
        }
    }

    private func emitOptionalGauge<T: BinaryInteger>(
        _ value: T?,
        name: String,
        help: String,
        labels: [String: String] = [:],
        into metrics: inout PrometheusMetrics
    ) {
        metrics.gauge(
            "\(name)_known",
            help: "Whether the optional metric value is known.",
            labels: labels,
            value: value != nil
        )
        if let value {
            metrics.gauge(name, help: help, labels: labels, value: value)
        }
    }

    private func emitOptionalCounter<T: BinaryInteger>(
        _ value: T?,
        name: String,
        help: String,
        labels: [String: String] = [:],
        into metrics: inout PrometheusMetrics
    ) {
        let knownName = String(name.dropLast("_total".count)) + "_known"
        metrics.gauge(
            knownName,
            help: "Whether the optional metric value is known.",
            labels: labels,
            value: value != nil
        )
        if let value {
            metrics.counter(name, help: help, labels: labels, value: value)
        }
    }
}

private enum Inspection<Value: Sendable>: Sendable {
    case disabled
    case failed(MacOSNodeStatusFailureReason)
    case valid(Value)

    var isValid: Bool {
        if case .valid = self {
            return true
        }
        return false
    }

    var failureReason: MacOSNodeStatusFailureReason? {
        if case .failed(let reason) = self {
            return reason
        }
        return nil
    }
}
