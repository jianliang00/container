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

import ContainerCRI

public enum CRIShimUnsupportedFieldValidator {
    public static func validate(_ request: Runtime_V1_RunPodSandboxRequest) throws {
        var fields: [String] = []
        if request.hasConfig {
            appendUnsupportedPodSandboxConfigFields(request.config, prefix: "config", fields: &fields)
        }
        try throwIfUnsupported(fields)
    }

    public static func validate(_ request: Runtime_V1_CreateContainerRequest) throws {
        var fields: [String] = []
        if request.hasConfig {
            appendUnsupportedContainerConfigFields(request.config, prefix: "config", fields: &fields)
        }
        if request.hasSandboxConfig {
            appendUnsupportedPodSandboxConfigFields(request.sandboxConfig, prefix: "sandbox_config", fields: &fields)
        }
        try throwIfUnsupported(fields)
    }

    private static func appendUnsupportedPodSandboxConfigFields(
        _ config: Runtime_V1_PodSandboxConfig,
        prefix: String,
        fields: inout [String]
    ) {
        if config.hasLinux {
            fields.append("\(prefix).linux")
        }
        if config.hasWindows {
            fields.append("\(prefix).windows")
        }
    }

    private static func appendUnsupportedContainerConfigFields(
        _ config: Runtime_V1_ContainerConfig,
        prefix: String,
        fields: inout [String]
    ) {
        if config.hasLinux {
            fields.append("\(prefix).linux")
        }
        if config.hasWindows {
            fields.append("\(prefix).windows")
        }
    }

    private static func throwIfUnsupported(_ fields: [String]) throws {
        guard !fields.isEmpty else {
            return
        }
        throw CRIShimError.invalidArgument(
            "unsupported CRI platform field(s) for macOS guest workloads: \(fields.joined(separator: ", "))"
        )
    }
}
