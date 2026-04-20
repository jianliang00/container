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
import Testing

@testable import ContainerCRI
@testable import ContainerCRIShimMacOS

struct CRIShimCoreMappingTests {
    @Test
    func mapsSandboxRequestToMetadata() throws {
        var request = Runtime_V1_RunPodSandboxRequest()
        request.runtimeHandler = "macos"
        request.config.metadata.uid = "pod-uid"
        request.config.metadata.namespace = "default"
        request.config.metadata.name = "demo"
        request.config.metadata.attempt = 2
        request.config.labels = ["app": "demo"]
        request.config.annotations = ["annotation": "value"]

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = try makeCRIShimSandboxMetadata(
            id: "sandbox-1",
            request: request,
            handler: resolvedRuntimeHandler,
            now: now
        )

        #expect(metadata.id == "sandbox-1")
        #expect(metadata.podUID == "pod-uid")
        #expect(metadata.namespace == "default")
        #expect(metadata.name == "demo")
        #expect(metadata.attempt == 2)
        #expect(metadata.runtimeHandler == "macos")
        #expect(metadata.sandboxImage == "example.com/macos/sandbox:latest")
        #expect(metadata.network == "default")
        #expect(metadata.labels == ["app": "demo"])
        #expect(metadata.annotations == ["annotation": "value"])
        #expect(metadata.state == .pending)
        #expect(metadata.createdAt == now)
        #expect(metadata.updatedAt == now)
    }

    @Test
    func mapsContainerRequestToMetadataAndWorkloadConfiguration() throws {
        var request = Runtime_V1_CreateContainerRequest()
        request.podSandboxID = "sandbox-1"
        request.sandboxConfig.logDirectory = "/var/log/pods/default_demo_uid"
        request.config.metadata.name = "workload"
        request.config.metadata.attempt = 3
        request.config.image.image = "example.com/macos/workload:latest"
        request.config.command = ["/bin/echo"]
        request.config.args = ["hello", "world"]
        request.config.workingDir = "/workspace"
        request.config.envs = [
            keyValue("GREETING", "hello"),
            keyValue("TARGET", "world"),
        ]
        request.config.labels = ["app": "demo"]
        request.config.annotations = ["container": "annotation"]
        request.config.logPath = "workload/0.log"
        request.config.tty = true

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = try makeCRIShimContainerMetadata(
            id: "container-1",
            request: request,
            sandbox: sandboxMetadata,
            now: now
        )
        let workload = try makeCRIShimWorkloadConfiguration(id: "container-1", request: request)

        #expect(metadata.id == "container-1")
        #expect(metadata.sandboxID == "sandbox-1")
        #expect(metadata.name == "workload")
        #expect(metadata.attempt == 3)
        #expect(metadata.image == "example.com/macos/workload:latest")
        #expect(metadata.runtimeHandler == "macos")
        #expect(metadata.labels == ["app": "demo"])
        #expect(metadata.annotations == ["container": "annotation"])
        #expect(metadata.command == ["/bin/echo"])
        #expect(metadata.args == ["hello", "world"])
        #expect(metadata.workingDirectory == "/workspace")
        #expect(metadata.logPath == "/var/log/pods/default_demo_uid/workload/0.log")
        #expect(metadata.state == .created)
        #expect(metadata.createdAt == now)

        #expect(workload.id == "container-1")
        #expect(workload.workloadImageReference == "example.com/macos/workload:latest")
        #expect(workload.processConfiguration.executable == "/bin/echo")
        #expect(workload.processConfiguration.arguments == ["hello", "world"])
        #expect(workload.processConfiguration.environment == ["GREETING=hello", "TARGET=world"])
        #expect(workload.processConfiguration.workingDirectory == "/workspace")
        #expect(workload.processConfiguration.terminal)
    }

    @Test
    func embedsSandboxMetadataInCoreLabelsForStartupReconcile() throws {
        var request = Runtime_V1_RunPodSandboxRequest()
        request.config.labels = ["app": "demo"]
        let configuration = try makeCRIShimSandboxConfiguration(
            id: "sandbox-1",
            request: request,
            handler: resolvedRuntimeHandler,
            sandboxImage: CRIShimImageRecord(
                reference: "example.com/macos/sandbox:latest",
                digest: "sha256:sandbox",
                size: 1
            ),
            metadata: sandboxMetadata
        )

        #expect(configuration.labels["app"] == "demo")
        let decodedMetadata = try #require(decodeCRIShimCoreSandboxMetadataLabel(configuration.labels))
        #expect(decodedMetadata.id == "sandbox-1")
        #expect(decodedMetadata.runtimeHandler == "macos")
        #expect(removeCRIShimCoreLabels(configuration.labels) == ["app": "demo"])
    }

    @Test
    func preservesImageDefaultCommandWhenCommandIsUnset() throws {
        var request = Runtime_V1_CreateContainerRequest()
        request.config.metadata.name = "image-default"
        request.config.image.image = "example.com/macos/workload:latest"
        request.config.args = ["override-arg"]

        let workload = try makeCRIShimWorkloadConfiguration(id: "container-1", request: request)

        #expect(workload.processConfiguration.executable == "")
        #expect(workload.processConfiguration.arguments == ["override-arg"])
        #expect(workload.processConfiguration.workingDirectory == "/")
        #expect(!workload.processConfiguration.terminal)
    }

    @Test
    func mapsPrivateHostPathMountsToVirtiofs() throws {
        var writable = Runtime_V1_Mount()
        writable.hostPath = "/tmp/host-workspace"
        writable.containerPath = "/Users/demo/workspace"

        var readonly = Runtime_V1_Mount()
        readonly.hostPath = "/tmp/host-config"
        readonly.containerPath = "/opt/config"
        readonly.readonly = true

        let mounts = try makeCRIShimMounts([writable, readonly])

        #expect(mounts.count == 2)
        #expect(mounts[0].isVirtiofs)
        #expect(mounts[0].source == "/tmp/host-workspace")
        #expect(mounts[0].destination == "/Users/demo/workspace")
        #expect(mounts[0].options.isEmpty)
        #expect(mounts[1].isVirtiofs)
        #expect(mounts[1].source == "/tmp/host-config")
        #expect(mounts[1].destination == "/opt/config")
        #expect(mounts[1].options == ["ro"])
    }

    @Test
    func rejectsUnsupportedMountOptions() {
        var propagation = Runtime_V1_Mount()
        propagation.hostPath = "/tmp/host"
        propagation.containerPath = "/Users/demo/host"
        propagation.propagation = .propagationBidirectional
        #expect(throws: CRIShimError.unsupported("CRI mount propagation must be private for macOS guest workloads")) {
            try makeCRIShimMounts([propagation])
        }

        var image = Runtime_V1_Mount()
        image.containerPath = "/opt/image"
        image.image.image = "example.com/config:latest"
        #expect(throws: CRIShimError.unsupported("CRI image mounts are not supported for macOS guest workloads")) {
            try makeCRIShimMounts([image])
        }
    }
}

private let resolvedRuntimeHandler = ResolvedRuntimeHandler(
    name: "macos",
    sandboxImage: "example.com/macos/sandbox:latest",
    workloadPlatform: WorkloadPlatform(os: "darwin", architecture: "arm64"),
    network: "default",
    networkBackend: "vmnetShared",
    guiEnabled: false
)

private let sandboxMetadata = CRIShimSandboxMetadata(
    id: "sandbox-1",
    podUID: "pod-uid",
    namespace: "default",
    name: "demo",
    runtimeHandler: "macos",
    sandboxImage: "example.com/macos/sandbox:latest",
    network: "default",
    state: .running,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
)

private func keyValue(_ key: String, _ value: String) -> Runtime_V1_KeyValue {
    var pair = Runtime_V1_KeyValue()
    pair.key = key
    pair.value = value
    return pair
}
