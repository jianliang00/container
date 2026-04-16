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

public struct ResolvedRuntimeHandler: Equatable, Sendable {
    public var name: String?
    public var sandboxImage: String
    public var workloadPlatform: WorkloadPlatform
    public var network: String
    public var guiEnabled: Bool

    public init(
        name: String?,
        sandboxImage: String,
        workloadPlatform: WorkloadPlatform,
        network: String,
        guiEnabled: Bool
    ) {
        self.name = name
        self.sandboxImage = sandboxImage
        self.workloadPlatform = workloadPlatform
        self.network = network
        self.guiEnabled = guiEnabled
    }
}

public enum RuntimeHandlerResolutionError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidConfig([String])
    case unknownRuntimeHandler(String)

    public var description: String {
        switch self {
        case .invalidConfig(let issues):
            return CRIShimValidationError(issues: issues).description
        case .unknownRuntimeHandler(let handler):
            return "unknown runtime handler: \(handler)"
        }
    }
}

extension CRIShimConfig {
    public func resolveRuntimeHandler(_ runtimeHandler: String?) throws -> ResolvedRuntimeHandler {
        if !validationIssues.isEmpty {
            throw RuntimeHandlerResolutionError.invalidConfig(validationIssues)
        }

        guard let defaults else {
            throw RuntimeHandlerResolutionError.invalidConfig(["defaults is required"])
        }

        let requested = runtimeHandler?.trimmed ?? ""
        let override: RuntimeProfile?
        let resolvedName: String?
        if requested.isEmpty {
            override = nil
            resolvedName = nil
        } else if let configured = runtimeHandlers[requested] {
            override = configured
            resolvedName = requested
        } else {
            throw RuntimeHandlerResolutionError.unknownRuntimeHandler(requested)
        }

        guard
            let sandboxImage = override?.sandboxImage ?? defaults.sandboxImage,
            let defaultPlatform = defaults.workloadPlatform,
            let network = override?.network ?? defaults.network,
            let guiEnabled = override?.guiEnabled ?? defaults.guiEnabled
        else {
            throw RuntimeHandlerResolutionError.invalidConfig(validationIssues)
        }

        let workloadPlatform = WorkloadPlatform(
            os: override?.workloadPlatform?.os ?? defaultPlatform.os,
            architecture: override?.workloadPlatform?.architecture ?? defaultPlatform.architecture
        )

        return ResolvedRuntimeHandler(
            name: resolvedName,
            sandboxImage: sandboxImage,
            workloadPlatform: workloadPlatform,
            network: network,
            guiEnabled: guiEnabled
        )
    }
}
