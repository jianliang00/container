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

        if let streaming {
            validateNonEmpty(streaming.address, name: "streaming.address", issues: &issues)
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
        } else {
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

        return issues
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
    if profile.guiEnabled == nil {
        issues.append("\(name).guiEnabled is required")
    }
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
