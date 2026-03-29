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
import Testing

@testable import ContainerResource

struct MacOSImageContractTests {
    @Test
    func sandboxAndWorkloadAnnotationsUseExpectedKeys() {
        let sandboxAnnotations = MacOSImageContract.annotations(for: .sandbox)
        let workloadAnnotations = MacOSImageContract.annotations(for: .workload)

        #expect(sandboxAnnotations[MacOSImageContract.roleAnnotation] == MacOSImageRole.sandbox.rawValue)
        #expect(sandboxAnnotations[MacOSImageContract.workloadFormatAnnotation] == nil)
        #expect(workloadAnnotations[MacOSImageContract.roleAnnotation] == MacOSImageRole.workload.rawValue)
        #expect(workloadAnnotations[MacOSImageContract.workloadFormatAnnotation] == MacOSWorkloadImageFormat.v1.rawValue)
    }

    @Test
    func sandboxValidationAllowsLegacyUnannotatedSandboxManifest() throws {
        try MacOSImageContract.validateSandboxImage(manifest: sandboxManifest())
    }

    @Test
    func sandboxValidationRejectsWorkloadRole() throws {
        #expect(throws: MacOSImageContractError.sandboxImageRequired) {
            try MacOSImageContract.validateSandboxImage(
                descriptorAnnotations: MacOSImageContract.annotations(for: .workload),
                manifest: sandboxManifest()
            )
        }
    }

    @Test
    func workloadValidationAcceptsFilesystemLayersWithOCIConfig() throws {
        try MacOSImageContract.validateWorkloadImage(
            descriptorAnnotations: MacOSImageContract.annotations(for: .workload),
            manifest: workloadManifest(),
            imageConfig: workloadImageConfig()
        )
    }

    @Test
    func workloadValidationRejectsSandboxLayers() throws {
        #expect(throws: MacOSImageContractError.workloadImageContainsSandboxLayers) {
            try MacOSImageContract.validateWorkloadImage(
                descriptorAnnotations: MacOSImageContract.annotations(for: .workload),
                manifest: sandboxManifest(),
                imageConfig: workloadImageConfig()
            )
        }
    }

    @Test
    func workloadValidationRejectsNonDarwinConfig() throws {
        #expect(throws: MacOSImageContractError.invalidWorkloadPlatform(os: "linux", architecture: "arm64")) {
            try MacOSImageContract.validateWorkloadImage(
                descriptorAnnotations: MacOSImageContract.annotations(for: .workload),
                manifest: workloadManifest(),
                imageConfig: .init(
                    created: "1970-01-01T00:00:00Z",
                    architecture: "arm64",
                    os: "linux",
                    config: .init(user: nil, env: nil, entrypoint: nil, cmd: nil, workingDir: "/", labels: nil, stopSignal: nil),
                    rootfs: .init(type: "layers", diffIDs: [])
                )
            )
        }
    }
}

private func sandboxManifest() -> Manifest {
    Manifest(
        config: .init(
            mediaType: "application/vnd.oci.image.config.v1+json",
            digest: "sha256:config",
            size: 1
        ),
        layers: [
            .init(mediaType: MacOSImageOCIMediaTypes.hardwareModel, digest: "sha256:hardware", size: 10),
            .init(mediaType: MacOSImageOCIMediaTypes.auxiliaryStorage, digest: "sha256:aux", size: 20),
            .init(mediaType: MacOSImageOCIMediaTypes.diskImage, digest: "sha256:disk", size: 30),
        ]
    )
}

private func workloadManifest() -> Manifest {
    Manifest(
        config: .init(
            mediaType: "application/vnd.oci.image.config.v1+json",
            digest: "sha256:config",
            size: 1
        ),
        layers: [
            .init(
                mediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
                digest: "sha256:layer",
                size: 128
            )
        ]
    )
}

private func workloadImageConfig() -> ContainerizationOCI.Image {
    .init(
        created: "1970-01-01T00:00:00Z",
        architecture: "arm64",
        os: "darwin",
        config: .init(
            user: "root",
            env: ["FOO=bar"],
            entrypoint: ["/bin/sh"],
            cmd: ["-c", "echo hello"],
            workingDir: "/workspace",
            labels: nil,
            stopSignal: nil
        ),
        rootfs: .init(type: "layers", diffIDs: [])
    )
}
