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

@testable import ContainerAPIService
@testable import ContainerResource

struct MacOSCreateValidationTests {
    @Test
    func macOSRuntimeAllowsMissingKernel() throws {
        var config = try baseConfiguration()
        config.runtimeHandler = "container-runtime-macos"
        config.platform = .init(arch: "arm64", os: "darwin")

        try ContainersService.validateCreateInput(configuration: config, kernel: nil)
    }

    @Test
    func linuxRuntimeRejectsMissingKernel() throws {
        var config = try baseConfiguration()
        config.runtimeHandler = "container-runtime-linux"
        config.platform = .init(arch: "arm64", os: "linux")

        #expect(throws: Error.self) {
            try ContainersService.validateCreateInput(configuration: config, kernel: nil)
        }
    }

    @Test
    func linuxRuntimeAcceptsKernel() throws {
        var config = try baseConfiguration()
        config.runtimeHandler = "container-runtime-linux"
        config.platform = .init(arch: "arm64", os: "linux")

        let kernel = Kernel(path: URL(fileURLWithPath: "/tmp/kernel"), platform: .linuxArm)
        try ContainersService.validateCreateInput(configuration: config, kernel: kernel)
    }

    private func baseConfiguration() throws -> ContainerConfiguration {
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
        return ContainerConfiguration(id: "test-container", image: image, process: process)
    }
}
