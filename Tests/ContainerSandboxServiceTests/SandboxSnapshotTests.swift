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

import Containerization
import Foundation
import Testing

@testable import ContainerResource
@testable import ContainerSandboxServiceClient

struct SandboxSnapshotTests {
    @Test
    func explicitSandboxConfigurationRoundTripsWithoutContainers() throws {
        let sandboxConfiguration = SandboxConfiguration(containerConfiguration: try makeContainerConfiguration())
        let snapshot = SandboxSnapshot(
            configuration: sandboxConfiguration,
            status: .stopped,
            networks: [],
            containers: []
        )

        let decoded = try JSONDecoder().decode(SandboxSnapshot.self, from: JSONEncoder().encode(snapshot))

        #expect(decoded.configuration?.id == sandboxConfiguration.id)
        #expect(decoded.configuration?.runtimeHandler == sandboxConfiguration.runtimeHandler)
        #expect(decoded.containers.isEmpty)
    }

    @Test
    func legacySnapshotDerivesSandboxConfigurationFromContainer() throws {
        let containerConfiguration = try makeContainerConfiguration()
        let snapshot = SandboxSnapshot(
            configuration: SandboxConfiguration(containerConfiguration: containerConfiguration),
            status: .running,
            networks: [],
            containers: [
                ContainerSnapshot(
                    configuration: containerConfiguration,
                    status: .running,
                    networks: []
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var legacyObject = jsonObject
        legacyObject.removeValue(forKey: "configuration")

        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(SandboxSnapshot.self, from: legacyData)

        #expect(decoded.configuration?.id == containerConfiguration.id)
        #expect(decoded.configuration?.image.reference == containerConfiguration.image.reference)
    }

    private func makeContainerConfiguration() throws -> ContainerConfiguration {
        let imageJSON = """
            {
              "reference": "example/macos:latest",
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
        var configuration = ContainerConfiguration(id: "sandbox-1", image: image, process: process)
        configuration.runtimeHandler = "container-runtime-macos"
        return configuration
    }
}
