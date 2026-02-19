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
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerResource

struct ContainerConfigurationMacOSTests {
    @Test
    func encodeDecodeWithMacOSGuestOptions() throws {
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
            executable: "/bin/echo",
            arguments: ["hello"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(
            id: "macos-test",
            image: image,
            process: process
        )
        config.platform = .init(arch: "arm64", os: "darwin")
        config.runtimeHandler = "container-runtime-macos"
        config.macosGuest = .init(snapshotEnabled: true, guiEnabled: false, agentPort: 27000)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)

        #expect(decoded.macosGuest == config.macosGuest)
        #expect(decoded.runtimeHandler == "container-runtime-macos")
    }

    @Test
    func decodeLegacyConfigurationWithoutMacOSGuestField() throws {
        let imageJSON = """
        {
          "reference": "example/legacy:latest",
          "descriptor": {
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "digest": "sha256:legacy",
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
        let config = ContainerConfiguration(id: "legacy", image: image, process: process)
        let encoded = try JSONEncoder().encode(config)

        var container = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        container.removeValue(forKey: "macosGuest")
        container.removeValue(forKey: "runtimeHandler")

        let legacyData = try JSONSerialization.data(withJSONObject: container)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: legacyData)
        #expect(decoded.macosGuest == nil)
        #expect(decoded.runtimeHandler == "container-runtime-linux")
    }
}
