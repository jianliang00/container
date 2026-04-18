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

    public init(kit: ContainerKit = ContainerKit(), timeout: Duration = .seconds(2)) {
        self.kit = kit
        self.timeout = timeout
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
            guard let network = networks.first(where: { $0.id == networkName }) else {
                return CRIShimRuntimeConditionSnapshot(
                    type: CRIShimRuntimeConditionType.networkReady,
                    status: false,
                    reason: "NetworkNotFound",
                    message: "configured network '\(networkName)' was not found"
                )
            }

            info["network"] = jsonString([
                "defaultNetwork": networkName,
                "state": network.state,
            ])

            guard case .running = network else {
                return CRIShimRuntimeConditionSnapshot(
                    type: CRIShimRuntimeConditionType.networkReady,
                    status: false,
                    reason: "NetworkNotRunning",
                    message: "configured network '\(networkName)' is \(network.state)"
                )
            }

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
