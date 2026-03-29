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

import ContainerizationOCI
import Foundation

public enum MacOSImageRole: String, Sendable, Codable, Equatable {
    case sandbox
    case workload
}

public enum MacOSWorkloadImageFormat: String, Sendable, Codable, Equatable {
    case v1
}

public enum MacOSImageContractError: Error, Equatable {
    case missingRoleAnnotation
    case invalidRoleAnnotation(String)
    case sandboxImageRequired
    case workloadImageRequired
    case missingWorkloadFormatAnnotation
    case invalidWorkloadFormatAnnotation(String)
    case invalidWorkloadPlatform(os: String, architecture: String)
    case workloadImageContainsSandboxLayers
}

extension MacOSImageContractError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingRoleAnnotation:
            return "missing macOS image role annotation"
        case .invalidRoleAnnotation(let value):
            return "invalid macOS image role annotation value \(value)"
        case .sandboxImageRequired:
            return "expected a macOS sandbox image"
        case .workloadImageRequired:
            return "expected a macOS workload image"
        case .missingWorkloadFormatAnnotation:
            return "missing macOS workload format annotation"
        case .invalidWorkloadFormatAnnotation(let value):
            return "invalid macOS workload format annotation value \(value)"
        case .invalidWorkloadPlatform(let os, let architecture):
            return "expected darwin/arm64 workload image config, got \(os)/\(architecture)"
        case .workloadImageContainsSandboxLayers:
            return "macOS workload image cannot include sandbox VM artifact layers"
        }
    }
}

public enum MacOSImageContract {
    public static let roleAnnotation = "org.apple.container.macos.image.role"
    public static let workloadFormatAnnotation = "org.apple.container.macos.workload.format"

    public static func annotations(for role: MacOSImageRole) -> [String: String] {
        var annotations = [roleAnnotation: role.rawValue]
        if role == .workload {
            annotations[workloadFormatAnnotation] = MacOSWorkloadImageFormat.v1.rawValue
        }
        return annotations
    }

    public static func role(
        descriptorAnnotations: [String: String]? = nil,
        manifestAnnotations: [String: String]? = nil
    ) throws -> MacOSImageRole? {
        guard let value = annotationValue(
            key: roleAnnotation,
            descriptorAnnotations: descriptorAnnotations,
            manifestAnnotations: manifestAnnotations
        ) else {
            return nil
        }
        guard let role = MacOSImageRole(rawValue: value) else {
            throw MacOSImageContractError.invalidRoleAnnotation(value)
        }
        return role
    }

    public static func workloadFormat(
        descriptorAnnotations: [String: String]? = nil,
        manifestAnnotations: [String: String]? = nil
    ) throws -> MacOSWorkloadImageFormat? {
        guard let value = annotationValue(
            key: workloadFormatAnnotation,
            descriptorAnnotations: descriptorAnnotations,
            manifestAnnotations: manifestAnnotations
        ) else {
            return nil
        }
        guard let format = MacOSWorkloadImageFormat(rawValue: value) else {
            throw MacOSImageContractError.invalidWorkloadFormatAnnotation(value)
        }
        return format
    }

    public static func validateSandboxImage(
        descriptorAnnotations: [String: String]? = nil,
        manifest: Manifest,
        allowLegacyUnannotatedSandbox: Bool = true
    ) throws {
        let resolvedRole = try role(
            descriptorAnnotations: descriptorAnnotations,
            manifestAnnotations: manifest.annotations
        )
        if let resolvedRole {
            guard resolvedRole == .sandbox else {
                throw MacOSImageContractError.sandboxImageRequired
            }
        } else if !allowLegacyUnannotatedSandbox {
            throw MacOSImageContractError.missingRoleAnnotation
        }

        _ = try MacOSImageLayers(manifest: manifest)
    }

    public static func validateWorkloadImage(
        descriptorAnnotations: [String: String]? = nil,
        manifest: Manifest,
        imageConfig: ContainerizationOCI.Image
    ) throws {
        guard
            let resolvedRole = try role(
                descriptorAnnotations: descriptorAnnotations,
                manifestAnnotations: manifest.annotations
            )
        else {
            throw MacOSImageContractError.missingRoleAnnotation
        }
        guard resolvedRole == .workload else {
            throw MacOSImageContractError.workloadImageRequired
        }

        guard
            let resolvedFormat = try workloadFormat(
                descriptorAnnotations: descriptorAnnotations,
                manifestAnnotations: manifest.annotations
            )
        else {
            throw MacOSImageContractError.missingWorkloadFormatAnnotation
        }
        guard resolvedFormat == .v1 else {
            throw MacOSImageContractError.invalidWorkloadFormatAnnotation(resolvedFormat.rawValue)
        }

        guard imageConfig.os == "darwin", imageConfig.architecture == "arm64" else {
            throw MacOSImageContractError.invalidWorkloadPlatform(
                os: imageConfig.os,
                architecture: imageConfig.architecture
            )
        }

        let sandboxLayerMediaTypes = Set([
            MacOSImageOCIMediaTypes.hardwareModel,
            MacOSImageOCIMediaTypes.auxiliaryStorage,
            MacOSImageOCIMediaTypes.diskImage,
            MacOSImageOCIMediaTypes.diskLayout,
            MacOSImageOCIMediaTypes.diskChunk,
        ])
        if manifest.layers.contains(where: { sandboxLayerMediaTypes.contains($0.mediaType) }) {
            throw MacOSImageContractError.workloadImageContainsSandboxLayers
        }
    }

    private static func annotationValue(
        key: String,
        descriptorAnnotations: [String: String]?,
        manifestAnnotations: [String: String]?
    ) -> String? {
        descriptorAnnotations?[key] ?? manifestAnnotations?[key]
    }
}
