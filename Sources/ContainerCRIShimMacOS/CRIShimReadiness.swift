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

import ContainerKit
import Foundation

public struct CRIShimRuntimeConditionSnapshot: Equatable, Sendable {
    public var type: String
    public var status: Bool
    public var reason: String
    public var message: String

    public init(type: String, status: Bool, reason: String, message: String) {
        self.type = type
        self.status = status
        self.reason = reason
        self.message = message
    }
}

public struct CRIShimReadinessSnapshot: Equatable, Sendable {
    public var runtime: CRIShimRuntimeConditionSnapshot
    public var network: CRIShimRuntimeConditionSnapshot
    public var info: [String: String]

    public init(
        runtime: CRIShimRuntimeConditionSnapshot,
        network: CRIShimRuntimeConditionSnapshot,
        info: [String: String] = [:]
    ) {
        self.runtime = runtime
        self.network = network
        self.info = info
    }
}

public protocol CRIShimReadinessChecking: Sendable {
    func snapshot(config: CRIShimConfig) async -> CRIShimReadinessSnapshot
}

public struct ContainerKitCRIShimReadinessChecker: CRIShimReadinessChecking {
    public var kit: ContainerKit
    public var timeout: Duration
    public var podNetworkStateStore: PodNetworkStateStore

    public init(
        kit: ContainerKit = ContainerKit(),
        timeout: Duration = .seconds(2),
        podNetworkStateStore: PodNetworkStateStore = PodNetworkStateStore()
    ) {
        self.kit = kit
        self.timeout = timeout
        self.podNetworkStateStore = podNetworkStateStore
    }

    public func snapshot(config: CRIShimConfig) async -> CRIShimReadinessSnapshot {
        var info: [String: String] = [:]

        let runtimeCondition: CRIShimRuntimeConditionSnapshot
        do {
            let health = try await kit.health(timeout: timeout)
            runtimeCondition = CRIShimRuntimeConditionSnapshot(
                type: CRIShimRuntimeConditionType.runtimeReady,
                status: true,
                reason: "RuntimeHealthOK",
                message: "container services are reachable"
            )
            info["runtime"] = jsonString([
                "apiServerAppName": health.apiServerAppName,
                "apiServerBuild": health.apiServerBuild,
                "apiServerCommit": health.apiServerCommit,
                "apiServerVersion": health.apiServerVersion,
                "appRoot": health.appRoot.path(percentEncoded: false),
                "installRoot": health.installRoot.path(percentEncoded: false),
            ])
        } catch {
            runtimeCondition = CRIShimRuntimeConditionSnapshot(
                type: CRIShimRuntimeConditionType.runtimeReady,
                status: false,
                reason: "RuntimeHealthCheckFailed",
                message: String(describing: error)
            )
            return CRIShimReadinessSnapshot(
                runtime: runtimeCondition,
                network: CRIShimRuntimeConditionSnapshot(
                    type: CRIShimRuntimeConditionType.networkReady,
                    status: false,
                    reason: "RuntimeNotReady",
                    message: "network readiness requires reachable container services"
                ),
                info: info
            )
        }

        let networkCondition = await networkReadiness(config: config, info: &info)
        return CRIShimReadinessSnapshot(
            runtime: runtimeCondition,
            network: networkCondition,
            info: info
        )
    }

    private func networkReadiness(
        config: CRIShimConfig,
        info: inout [String: String]
    ) async -> CRIShimRuntimeConditionSnapshot {
        if let podNetwork = config.podNetwork, podNetwork.enabled == true {
            return await podNetworkReadiness(config: podNetwork, info: &info)
        }

        if !config.requiresCNI && config.defaults?.networkBackend?.trimmed == "virtualizationNAT" {
            info["network"] = jsonString([
                "backend": "virtualizationNAT",
                "state": "ready",
            ])
            return CRIShimRuntimeConditionSnapshot(
                type: CRIShimRuntimeConditionType.networkReady,
                status: true,
                reason: "NATReady",
                message: "virtualizationNAT does not require a container network"
            )
        }

        guard let networkName = config.defaults?.network?.trimmed, !networkName.isEmpty else {
            return CRIShimRuntimeConditionSnapshot(
                type: CRIShimRuntimeConditionType.networkReady,
                status: false,
                reason: "NetworkNotConfigured",
                message: "defaults.network is required for macOS guest pod networking"
            )
        }

        do {
            let networks = try await kit.listNetworks()
            guard networks.contains(where: { $0.id == networkName }) else {
                return CRIShimRuntimeConditionSnapshot(
                    type: CRIShimRuntimeConditionType.networkReady,
                    status: false,
                    reason: "NetworkNotFound",
                    message: "configured network '\(networkName)' was not found"
                )
            }

            info["network"] = jsonString([
                "defaultNetwork": networkName,
                "state": "running",
            ])

            return CRIShimRuntimeConditionSnapshot(
                type: CRIShimRuntimeConditionType.networkReady,
                status: true,
                reason: "NetworkRunning",
                message: "configured network '\(networkName)' is running"
            )
        } catch {
            return CRIShimRuntimeConditionSnapshot(
                type: CRIShimRuntimeConditionType.networkReady,
                status: false,
                reason: "NetworkHealthCheckFailed",
                message: String(describing: error)
            )
        }
    }

    private func podNetworkReadiness(
        config: PodNetworkConfig,
        info: inout [String: String]
    ) async -> CRIShimRuntimeConditionSnapshot {
        guard let runtimeStatePath = config.runtimeStatePath?.trimmed,
            !runtimeStatePath.isEmpty,
            let readyStatePath = config.readyStatePath?.trimmed,
            !readyStatePath.isEmpty
        else {
            return podNetworkFailure(
                reason: "PodNetworkNotConfigured",
                message: "pod network state paths are not configured"
            )
        }

        let runtimeState: PodNetworkRuntimeState
        do {
            guard let state = try await podNetworkStateStore.loadRuntimeState(path: runtimeStatePath) else {
                return podNetworkFailure(
                    reason: "PodNetworkRuntimeStateMissing",
                    message: "pod network runtime state has not been published"
                )
            }
            runtimeState = state
        } catch {
            return podNetworkFailure(
                reason: "PodNetworkRuntimeStateInvalid",
                message: "pod network runtime state could not be read"
            )
        }

        let readyState: PodNetworkReadyState
        do {
            guard let state = try await podNetworkStateStore.loadReadyState(path: readyStatePath) else {
                return podNetworkFailure(
                    reason: "PodNetworkReadyStateMissing",
                    message: "pod network ready state has not been published"
                )
            }
            readyState = state
        } catch {
            return podNetworkFailure(
                reason: "PodNetworkReadyStateInvalid",
                message: "pod network ready state could not be read"
            )
        }

        do {
            let networks = try await kit.listNetworks()
            let condition = evaluatePodNetworkReadiness(
                config: config,
                runtimeState: runtimeState,
                readyState: readyState,
                networks: networks
            )
            if condition.status {
                info["network"] = jsonString([
                    "backend": "hostOnly",
                    "state": "ready",
                ])
            }
            return condition
        } catch {
            return podNetworkFailure(
                reason: "PodNetworkHealthCheckFailed",
                message: "dedicated pod network health could not be inspected"
            )
        }
    }
}

func evaluatePodNetworkReadiness(
    config: PodNetworkConfig,
    runtimeState: PodNetworkRuntimeState,
    readyState: PodNetworkReadyState,
    networks: [NetworkState],
    now: Date = Date()
) -> CRIShimRuntimeConditionSnapshot {
    let readyLease: PodNetworkReadyLease
    do {
        readyLease = try validatePodNetworkReadyLease(
            config: config,
            runtimeState: runtimeState,
            readyState: readyState,
            now: now
        )
    } catch let error as PodNetworkReadyLeaseValidationError {
        switch error {
        case .statePathsNotConfigured, .runtimeStateMissing, .runtimeStateMismatch:
            return podNetworkFailure(reason: "PodNetworkRuntimeStateMismatch", message: error.description)
        case .readyStateMissing, .readyStateMismatch:
            return podNetworkFailure(reason: "PodNetworkReadyStateMismatch", message: error.description)
        case .ipv4NotReady:
            return podNetworkFailure(reason: "PodNetworkIPv4NotReady", message: error.description)
        case .ipv6NotReady:
            return podNetworkFailure(reason: "PodNetworkIPv6NotReady", message: error.description)
        case .readyStateExpired:
            return podNetworkFailure(reason: "PodNetworkReadyStateExpired", message: error.description)
        case .mtuOutOfRange:
            return podNetworkFailure(reason: "PodNetworkReadyStateMTUInvalid", message: error.description)
        }
    } catch {
        return podNetworkFailure(
            reason: "PodNetworkReadyStateInvalid",
            message: "pod network ready state could not be validated"
        )
    }

    let networkName = runtimeState.networkName
    guard let network = networks.first(where: { $0.id == networkName }) else {
        return podNetworkFailure(
            reason: "PodNetworkNotFound",
            message: "dedicated pod network was not found"
        )
    }

    guard case .hostOnly = network.configuration.mode else {
        return podNetworkFailure(
            reason: "PodNetworkModeMismatch",
            message: "dedicated pod network is not host-only"
        )
    }

    guard let configuredSubnet = network.configuration.ipv4Subnet,
        let configuredPodCIDR = try? canonicalIPv4PodCIDR(configuredSubnet.description),
        let runningPodCIDR = try? canonicalIPv4PodCIDR(network.status.ipv4Subnet.description),
        configuredPodCIDR == readyLease.podCIDRs.ipv4,
        runningPodCIDR == readyLease.podCIDRs.ipv4
    else {
        return podNetworkFailure(
            reason: "PodNetworkSubnetMismatch",
            message: "dedicated pod network subnet does not match the runtime pod CIDR"
        )
    }

    if config.dualStackEnabled {
        guard let expectedIPv6PodCIDR = readyLease.podCIDRs.ipv6,
            let configuredSubnet = network.configuration.ipv6Subnet,
            let runningSubnet = network.status.ipv6Subnet,
            configuredSubnet.prefix.length == 64,
            runningSubnet.prefix.length == 64,
            configuredSubnet.address == configuredSubnet.lower,
            runningSubnet.address == runningSubnet.lower,
            !configuredSubnet.lower.isUnspecified,
            !configuredSubnet.lower.isLoopback,
            !configuredSubnet.lower.isMulticast,
            !configuredSubnet.lower.isLinkLocal,
            !runningSubnet.lower.isUnspecified,
            !runningSubnet.lower.isLoopback,
            !runningSubnet.lower.isMulticast,
            !runningSubnet.lower.isLinkLocal,
            configuredSubnet.description == expectedIPv6PodCIDR,
            runningSubnet.description == expectedIPv6PodCIDR
        else {
            return podNetworkFailure(
                reason: "PodNetworkIPv6SubnetMismatch",
                message: "dedicated pod network IPv6 subnet does not match the runtime pod CIDR"
            )
        }

        guard let gateway = network.status.ipv6Gateway,
            configuredSubnet.contains(gateway),
            runningSubnet.contains(gateway),
            !gateway.isUnspecified,
            !gateway.isLoopback,
            !gateway.isMulticast,
            !gateway.isLinkLocal,
            gateway != runningSubnet.lower,
            gateway.value == runningSubnet.lower.value + 1
        else {
            return podNetworkFailure(
                reason: "PodNetworkIPv6GatewayMismatch",
                message: "dedicated pod network IPv6 gateway does not match subnet.lower + 1"
            )
        }
    }

    return CRIShimRuntimeConditionSnapshot(
        type: CRIShimRuntimeConditionType.networkReady,
        status: true,
        reason: "PodNetworkReady",
        message: "dedicated pod network is ready"
    )
}

private func podNetworkFailure(reason: String, message: String) -> CRIShimRuntimeConditionSnapshot {
    CRIShimRuntimeConditionSnapshot(
        type: CRIShimRuntimeConditionType.networkReady,
        status: false,
        reason: reason,
        message: message
    )
}

public enum CRIShimRuntimeConditionType {
    public static let runtimeReady = "RuntimeReady"
    public static let networkReady = "NetworkReady"
}

private func jsonString(_ value: [String: String]) -> String {
    guard let data = try? JSONEncoder.sorted.encode(value) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

extension JSONEncoder {
    fileprivate static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
