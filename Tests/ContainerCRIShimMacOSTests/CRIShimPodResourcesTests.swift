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
import ContainerResource
import Testing
import Virtualization

@testable import ContainerCRIShimMacOS

struct CRIShimPodResourcesTests {
    private let defaults = RuntimeResources(cpus: 4, memoryInBytes: 1024 * 1024 * 1024)

    @Test
    func absentResourcesPreserveHandlerDefaults() throws {
        let result = try resolveCRIShimPodResources(annotations: [:], defaults: defaults)
        #expect(result.cpus == 4)
        #expect(result.memoryInBytes == 1024 * 1024 * 1024)
        let legacy = try resolveCRIShimPodResources(annotations: [CRIShimPodResourceAnnotation.version: "v1alpha1"], defaults: defaults)
        #expect(legacy == result)

    }

    @Test
    func absentResourcesValidateRuntimeDefaultsAgainstHostCapacity() throws {
        if RuntimeResources.defaultMacOSMemoryInBytes > VZVirtualMachineConfiguration.maximumAllowedMemorySize {
            #expect(throws: CRIShimError.self) {
                try resolveCRIShimPodResources(annotations: [:], defaults: RuntimeResources())
            }
        } else {
            let result = try resolveCRIShimPodResources(annotations: [:], defaults: RuntimeResources())
            #expect(result.cpus == RuntimeResources.defaultMacOSCPUCount)
            #expect(result.memoryInBytes == RuntimeResources.defaultMacOSMemoryInBytes)
        }
    }

    @Test(arguments: ["1600000000", "1638400000", "1717986918", "16000000000", "16384000000", "17179869184"])
    func mapsPodResourcesThroughSandboxCreation(memory: String) throws {
        var request = Runtime_V1_RunPodSandboxRequest()
        request.config.annotations = [
            CRIShimPodResourceAnnotation.version: "v1alpha2",
            CRIShimPodResourceAnnotation.cpuMillis: "8000",
            CRIShimPodResourceAnnotation.memoryBytes: memory,
        ]
        let handler = ResolvedRuntimeHandler(
            name: "macos", sandboxImage: "example.com/sandbox:latest",
            workloadPlatform: .init(os: "darwin", architecture: "arm64"), network: "default",
            networkBackend: "vmnetShared", networkMTU: nil, guiEnabled: false, resources: defaults)
        let bytes = try #require(UInt64(memory))
        let aligned = (bytes + 1_048_575) / 1_048_576 * 1_048_576
        if aligned > VZVirtualMachineConfiguration.maximumAllowedMemorySize {
            #expect(throws: CRIShimError.self) {
                try makeCRIShimSandboxConfiguration(
                    id: "test", request: request, handler: handler,
                    sandboxImage: .init(reference: "example.com/sandbox:latest", digest: "sha256:test", size: 1))
            }
            return
        }
        let configuration = try makeCRIShimSandboxConfiguration(
            id: "test", request: request, handler: handler,
            sandboxImage: .init(reference: "example.com/sandbox:latest", digest: "sha256:test", size: 1))
        #expect(configuration.resources.cpus == 8)
        #expect(configuration.resources.memoryInBytes == aligned)
        let snapshot = SandboxSnapshot(configuration: .init(containerConfiguration: configuration), status: .running, networks: [], containers: [])
        let requested = try resolveCRIShimPodResources(annotations: request.config.annotations, defaults: defaults)
        try validateCRIShimReusedPodResources(requested: requested, snapshot: snapshot)
        let changed = try MacOSVirtualMachineResources(cpus: 4, memoryInBytes: requested.memoryInBytes)
        #expect(throws: CRIShimError.self) { try validateCRIShimReusedPodResources(requested: changed, snapshot: snapshot) }
    }

    @Test
    func fractionalCPUAndIndependentFallback() throws {
        let result = try resolveCRIShimPodResources(
            annotations: [
                CRIShimPodResourceAnnotation.version: "v1alpha2", CRIShimPodResourceAnnotation.cpuMillis: "1500",
            ], defaults: defaults)
        #expect(result.cpus == 2)
        #expect(result.memoryInBytes == defaults.memoryInBytes)
        let memoryOnly = try resolveCRIShimPodResources(
            annotations: [
                CRIShimPodResourceAnnotation.version: "v1alpha2", CRIShimPodResourceAnnotation.memoryBytes: "536870912",
            ], defaults: defaults)
        #expect(memoryOnly.cpus == 4)
    }

    @Test(arguments: ["", "0", "-1", "+1", "1.5", " 8000", "8Gi", "9223372036854775808", "18446744073709551616"])
    func malformedValuesRejected(value: String) {
        for key in [CRIShimPodResourceAnnotation.cpuMillis, CRIShimPodResourceAnnotation.memoryBytes] {
            #expect(throws: CRIShimError.self) {
                try resolveCRIShimPodResources(annotations: [CRIShimPodResourceAnnotation.version: "v1alpha2", key: value], defaults: defaults)
            }
        }
    }

    @Test
    func unsupportedContractAndHardwareLimitsRejected() {
        for annotations in [
            [CRIShimPodResourceAnnotation.cpuMillis: "8000"],
            [CRIShimPodResourceAnnotation.version: "v1alpha1", CRIShimPodResourceAnnotation.cpuMillis: "8000"],
            [CRIShimPodResourceAnnotation.version: "v2"],
            [CRIShimPodResourceAnnotation.version: "v1alpha2", CRIShimPodResourceAnnotation.cpuMillis: "9223372036854775807"],
            [CRIShimPodResourceAnnotation.version: "v1alpha2", CRIShimPodResourceAnnotation.memoryBytes: "1"],
        ] {
            #expect(throws: CRIShimError.self) { try resolveCRIShimPodResources(annotations: annotations, defaults: defaults) }
        }
    }

    @Test
    func cannotReuseUnknownResources() throws {
        let requested = try MacOSVirtualMachineResources(cpus: 4, memoryInBytes: 1024 * 1024 * 1024)
        #expect(throws: CRIShimError.self) {
            try validateCRIShimReusedPodResources(
                requested: requested,
                snapshot: .init(status: .running, networks: [], containers: []))
        }
    }
}
