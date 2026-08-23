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

import Foundation

public struct CRIShimValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    public var issues: [String]

    public init(issues: [String]) {
        self.issues = issues
    }

    public var description: String {
        "invalid CRI shim config:\n" + issues.map { "- \($0)" }.joined(separator: "\n")
    }
}

extension CRIShimConfig {
    public func validate() throws {
        let issues = validationIssues
        if !issues.isEmpty {
            throw CRIShimValidationError(issues: issues)
        }
    }

    public var validationIssues: [String] {
        var issues: [String] = []

        validatePath(runtimeEndpoint, name: "runtimeEndpoint", allowUnixScheme: true, issues: &issues)
        validateOptionalPath(stateDirectory, name: "stateDirectory", issues: &issues)

        if let streaming {
            validateNonEmpty(streaming.address, name: "streaming.address", issues: &issues)
            if let address = streaming.address?.trimmed,
                !address.isEmpty,
                address != "127.0.0.1",
                address != "::1",
                address.lowercased() != "localhost"
            {
                issues.append("streaming.address must be a loopback address")
            }
            if let port = streaming.port {
                if port < 0 || port > 65535 {
                    issues.append("streaming.port must be between 0 and 65535")
                }
            } else {
                issues.append("streaming.port is required")
            }
        } else {
            issues.append("streaming is required")
        }

        if let cni {
            validatePath(cni.binDir, name: "cni.binDir", issues: &issues)
            validatePath(cni.confDir, name: "cni.confDir", issues: &issues)
            validateNonEmpty(cni.plugin, name: "cni.plugin", issues: &issues)
            if let plugin = cni.plugin?.trimmed, plugin.contains("/") {
                issues.append("cni.plugin must be a plugin name, not a path")
            }
        } else if requiresCNI {
            issues.append("cni is required")
        }

        if let defaults {
            validateRequiredRuntimeProfile(defaults, name: "defaults", issues: &issues)
        } else {
            issues.append("defaults is required")
        }

        for (handlerName, handler) in runtimeHandlers.sorted(by: { $0.key < $1.key }) {
            if handlerName.trimmed.isEmpty {
                issues.append("runtimeHandlers contains an empty handler name")
            }
            validateRuntimeHandlerOverride(handler, name: "runtimeHandlers.\(handlerName)", issues: &issues)
        }

        if let networkPolicy {
            if networkPolicy.enabled == nil {
                issues.append("networkPolicy.enabled is required")
            }
            if networkPolicy.enabled == true {
                validatePath(networkPolicy.kubeconfig, name: "networkPolicy.kubeconfig", issues: &issues)
                validateNonEmpty(networkPolicy.nodeName, name: "networkPolicy.nodeName", issues: &issues)
                if let resyncSeconds = networkPolicy.resyncSeconds {
                    if resyncSeconds <= 0 {
                        issues.append("networkPolicy.resyncSeconds must be greater than zero")
                    }
                } else {
                    issues.append("networkPolicy.resyncSeconds is required when networkPolicy.enabled is true")
                }
            }
        } else {
            issues.append("networkPolicy is required")
        }

        if let kubeProxy {
            if kubeProxy.enabled == nil {
                issues.append("kubeProxy.enabled is required")
            }
            if kubeProxy.enabled == true {
                validatePath(kubeProxy.configPath, name: "kubeProxy.configPath", issues: &issues)
            }
        } else {
            issues.append("kubeProxy is required")
        }

        if let podNetwork {
            if podNetwork.enabled == nil {
                issues.append("podNetwork.enabled is required")
            }
            if podNetwork.vmnetDisconnectRecovery == .rebootNode,
                podNetwork.enabled != true
            {
                issues.append("podNetwork.vmnetDisconnectRecovery reboot-node requires podNetwork.enabled true")
            }
            if podNetwork.enabled == true {
                validateNonEmpty(podNetwork.networkName, name: "podNetwork.networkName", issues: &issues)
                validatePath(podNetwork.runtimeStatePath, name: "podNetwork.runtimeStatePath", issues: &issues)
                validatePath(podNetwork.readyStatePath, name: "podNetwork.readyStatePath", issues: &issues)
                if podNetwork.vmnetDisconnectRecovery == .rebootNode {
                    let recovery = resolvedVMNetRecoveryConfig
                    validatePath(recovery.statePath, name: "podNetwork.vmnetRecovery.statePath", issues: &issues)
                    validatePath(recovery.requestPath, name: "podNetwork.vmnetRecovery.requestPath", issues: &issues)
                    if recovery.statePath?.trimmed == recovery.requestPath?.trimmed {
                        issues.append("podNetwork.vmnetRecovery statePath and requestPath must be different")
                    }
                    if recovery.requestWriterUID < 0 || UInt32(exactly: recovery.requestWriterUID) == nil {
                        issues.append("podNetwork.vmnetRecovery.requestWriterUID must be a valid uid")
                    }
                    if recovery.maxRebootAttempts <= 0 {
                        issues.append("podNetwork.vmnetRecovery.maxRebootAttempts must be greater than zero")
                    }
                    if recovery.minimumRebootIntervalSeconds < 0 {
                        issues.append("podNetwork.vmnetRecovery.minimumRebootIntervalSeconds must not be negative")
                    }
                    if recovery.attemptWindowSeconds <= 0 {
                        issues.append("podNetwork.vmnetRecovery.attemptWindowSeconds must be greater than zero")
                    }
                    if recovery.maximumRequestAgeSeconds <= 0 {
                        issues.append("podNetwork.vmnetRecovery.maximumRequestAgeSeconds must be greater than zero")
                    }
                    if recovery.verificationTimeoutSeconds <= 0 {
                        issues.append("podNetwork.vmnetRecovery.verificationTimeoutSeconds must be greater than zero")
                    }
                    if recovery.pollIntervalSeconds <= 0 {
                        issues.append("podNetwork.vmnetRecovery.pollIntervalSeconds must be greater than zero")
                    }
                    if recovery.healthyProbeFailureThreshold <= 0 {
                        issues.append("podNetwork.vmnetRecovery.healthyProbeFailureThreshold must be greater than zero")
                    }
                }
            }
        }

        validateKubernetesIntegrationNetworkBackend(issues: &issues)

        return issues
    }
}

extension CRIShimConfig {
    public var requiresCNI: Bool {
        guard let defaults else {
            return false
        }

        let defaultBackend = defaults.networkBackend?.trimmed
        if defaultBackend == "vmnetShared" {
            return true
        }

        return runtimeHandlers.values.contains { handler in
            let backend = handler.networkBackend?.trimmed ?? defaultBackend
            return backend == "vmnetShared"
        }
    }
}

private func validateRequiredRuntimeProfile(_ profile: RuntimeProfile, name: String, issues: inout [String]) {
    validateNonEmpty(profile.sandboxImage, name: "\(name).sandboxImage", issues: &issues)
    if let workloadPlatform = profile.workloadPlatform {
        validateNonEmpty(workloadPlatform.os, name: "\(name).workloadPlatform.os", issues: &issues)
        validateNonEmpty(workloadPlatform.architecture, name: "\(name).workloadPlatform.architecture", issues: &issues)
        if let os = workloadPlatform.os?.trimmed, !os.isEmpty, os != "darwin" {
            issues.append("\(name).workloadPlatform.os must be darwin")
        }
    } else {
        issues.append("\(name).workloadPlatform is required")
    }
    validateNonEmpty(profile.network, name: "\(name).network", issues: &issues)
    validateNetworkBackend(profile.networkBackend, name: "\(name).networkBackend", required: true, issues: &issues)
    validateNetworkMTU(profile.networkMTU, name: "\(name).networkMTU", issues: &issues)
    if profile.guiEnabled == nil {
        issues.append("\(name).guiEnabled is required")
    }
    validateRuntimeResources(profile.resources, name: "\(name).resources", issues: &issues)
}

private func validateRuntimeHandlerOverride(_ profile: RuntimeProfile, name: String, issues: inout [String]) {
    validateOptionalNonEmpty(profile.sandboxImage, name: "\(name).sandboxImage", issues: &issues)
    validateOptionalNonEmpty(profile.network, name: "\(name).network", issues: &issues)
    if let workloadPlatform = profile.workloadPlatform {
        validateOptionalNonEmpty(workloadPlatform.os, name: "\(name).workloadPlatform.os", issues: &issues)
        validateOptionalNonEmpty(workloadPlatform.architecture, name: "\(name).workloadPlatform.architecture", issues: &issues)
        if let os = workloadPlatform.os?.trimmed, !os.isEmpty, os != "darwin" {
            issues.append("\(name).workloadPlatform.os must be darwin")
        }
    }
    validateNetworkBackend(profile.networkBackend, name: "\(name).networkBackend", required: false, issues: &issues)
    validateNetworkMTU(profile.networkMTU, name: "\(name).networkMTU", issues: &issues)
    validateRuntimeResources(profile.resources, name: "\(name).resources", issues: &issues)
}

private func validateNetworkMTU(_ value: UInt32?, name: String, issues: inout [String]) {
    guard let value else {
        return
    }
    if !(576...9_000).contains(value) {
        issues.append("\(name) must be between 576 and 9000")
    }
}

private func validatePath(_ value: String?, name: String, allowUnixScheme: Bool = false, issues: inout [String]) {
    guard let value = value?.trimmed, !value.isEmpty else {
        issues.append("\(name) is required")
        return
    }

    let path = allowUnixScheme ? value.removingUnixScheme : value
    if !path.hasPrefix("/") {
        issues.append("\(name) must be an absolute path")
    }
}

private func validateOptionalPath(_ value: String?, name: String, allowUnixScheme: Bool = false, issues: inout [String]) {
    guard let value else {
        return
    }
    let trimmed = value.trimmed
    guard !trimmed.isEmpty else {
        issues.append("\(name) cannot be empty")
        return
    }

    let path = allowUnixScheme ? trimmed.removingUnixScheme : trimmed
    if !path.hasPrefix("/") {
        issues.append("\(name) must be an absolute path")
    }
}

private func validateNonEmpty(_ value: String?, name: String, issues: inout [String]) {
    guard let value = value?.trimmed, !value.isEmpty else {
        issues.append("\(name) is required")
        return
    }
}

private func validateOptionalNonEmpty(_ value: String?, name: String, issues: inout [String]) {
    if let value, value.trimmed.isEmpty {
        issues.append("\(name) cannot be empty")
    }
}

private func validateNetworkBackend(_ value: String?, name: String, required: Bool, issues: inout [String]) {
    guard let value = value?.trimmed, !value.isEmpty else {
        if required {
            issues.append("\(name) is required")
        }
        return
    }

    guard value == "virtualizationNAT" || value == "vmnetShared" else {
        issues.append("\(name) must be virtualizationNAT or vmnetShared")
        return
    }
}

private func validateRuntimeResources(_ resources: RuntimeResources?, name: String, issues: inout [String]) {
    guard let resources else {
        return
    }
    if let cpus = resources.cpus, cpus <= 0 {
        issues.append("\(name).cpus must be greater than zero")
    }
    if let memoryInBytes = resources.memoryInBytes, memoryInBytes == 0 {
        issues.append("\(name).memoryInBytes must be greater than zero")
    }
}

extension CRIShimConfig {
    private var kubernetesIntegrationEnabled: Bool {
        networkPolicy?.enabled == true || kubeProxy?.enabled == true
    }

    private func validateKubernetesIntegrationNetworkBackend(issues: inout [String]) {
        guard kubernetesIntegrationEnabled else {
            return
        }

        guard let defaults else {
            return
        }

        if defaults.networkBackend?.trimmed == "virtualizationNAT" {
            issues.append("defaults.networkBackend must be vmnetShared when networkPolicy or kubeProxy is enabled")
        }

        for (handlerName, handler) in runtimeHandlers.sorted(by: { $0.key < $1.key }) {
            let effectiveBackend = handler.networkBackend?.trimmed ?? defaults.networkBackend?.trimmed
            if effectiveBackend == "virtualizationNAT" {
                issues.append(
                    "runtimeHandlers.\(handlerName).networkBackend must be vmnetShared when networkPolicy or kubeProxy is enabled"
                )
            }
        }
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var removingUnixScheme: String {
        if hasPrefix("unix://") {
            String(dropFirst("unix://".count))
        } else {
            self
        }
    }
}
