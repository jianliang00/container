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

import ContainerXPC
import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerAPIService
@testable import ContainerResource
@testable import ContainerSandboxServiceClient

struct ContainersServiceBootRecoveryTests {
    @Test
    func bootRecoveryKeepsRecoveredClientForStoppedSandbox() throws {
        let existing = try makeContainerState(status: .stopped, networks: [], startedDate: Date())
        let networks = try [makeAttachment()]
        let recoveredClient = makeSandboxClient(id: existing.snapshot.id)
        let sandboxSnapshot = SandboxSnapshot(
            status: .stopped,
            networks: networks,
            containers: []
        )

        let recovered = ContainersService.makeBootRecoveredState(
            existing: existing,
            sandboxSnapshot: sandboxSnapshot,
            client: recoveredClient
        )

        #expect(recovered.client != nil)
        #expect(recovered.snapshot.status == .stopped)
        #expect(recovered.snapshot.networks == networks)
        #expect(recovered.snapshot.startedDate == nil)
    }

    @Test
    func bootRecoveryPreservesStartedDateForRunningSandbox() throws {
        let startedDate = Date(timeIntervalSince1970: 1_711_111_111)
        let existing = try makeContainerState(status: .stopped, networks: [], startedDate: startedDate)
        let networks = try [makeAttachment()]
        let recoveredClient = makeSandboxClient(id: existing.snapshot.id)
        let sandboxSnapshot = SandboxSnapshot(
            status: .running,
            networks: networks,
            containers: []
        )

        let recovered = ContainersService.makeBootRecoveredState(
            existing: existing,
            sandboxSnapshot: sandboxSnapshot,
            client: recoveredClient
        )

        #expect(recovered.client != nil)
        #expect(recovered.snapshot.status == .running)
        #expect(recovered.snapshot.networks == networks)
        #expect(recovered.snapshot.startedDate == startedDate)
    }

    @Test
    func bootRecoveryTreatsBootedSandboxAsRunningWhenInitWorkloadIsStopped() throws {
        let configuration = try makeContainerConfiguration(id: "boot-recovery")
        let existing = ContainersService.ContainerState(
            snapshot: ContainerSnapshot(
                configuration: configuration,
                status: .stopped,
                networks: [],
                startedDate: nil
            )
        )
        let sandboxSnapshot = SandboxSnapshot(
            configuration: SandboxConfiguration(containerConfiguration: configuration),
            status: .running,
            networks: [],
            containers: [
                ContainerSnapshot(
                    configuration: configuration,
                    status: .running,
                    networks: [],
                    startedDate: nil
                )
            ],
            workloads: [
                WorkloadSnapshot(
                    configuration: WorkloadConfiguration(
                        id: configuration.id,
                        processConfiguration: configuration.initProcess
                    ),
                    status: .stopped
                )
            ]
        )

        let recovered = ContainersService.makeBootRecoveredState(
            existing: existing,
            sandboxSnapshot: sandboxSnapshot,
            client: makeSandboxClient(id: configuration.id)
        )

        #expect(recovered.snapshot.status == .running)
    }

    private func makeContainerState(
        status: RuntimeStatus,
        networks: [ContainerResource.Attachment],
        startedDate: Date?
    ) throws -> ContainersService.ContainerState {
        let config = try makeContainerConfiguration(id: "boot-recovery")
        let snapshot = ContainerSnapshot(
            configuration: config,
            status: status,
            networks: networks,
            startedDate: startedDate
        )
        return ContainersService.ContainerState(snapshot: snapshot)
    }

    private func makeContainerConfiguration(id: String) throws -> ContainerConfiguration {
        let imageJSON = """
            {
              "reference": "example/test:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:test",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        return ContainerConfiguration(id: id, image: image, process: process)
    }

    private func makeAttachment() throws -> ContainerResource.Attachment {
        ContainerResource.Attachment(
            network: "default",
            hostname: "boot-recovery",
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: try MACAddress("02:42:ac:11:00:52"),
            dns: .init(
                nameservers: ["192.168.64.1"],
                domain: nil,
                searchDomains: [],
                options: []
            )
        )
    }

    private func makeSandboxClient(id: String) -> SandboxClient {
        SandboxClient(
            id: id,
            runtime: "container-runtime-macos",
            client: XPCClient(service: "com.apple.container.tests.boot-recovery")
        )
    }
}
