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

import Testing

@testable import ContainerCRI
@testable import ContainerCRIShimMacOS

struct CRIShimUnsupportedFieldValidationTests {
    @Test
    func acceptsMacOSOnlySandboxAndContainerRequests() throws {
        var sandbox = Runtime_V1_RunPodSandboxRequest()
        sandbox.config.metadata.name = "pod"
        try CRIShimUnsupportedFieldValidator.validate(sandbox)

        var container = Runtime_V1_CreateContainerRequest()
        container.podSandboxID = "sandbox-1"
        container.config.metadata.name = "workload"
        container.config.image.image = "example.com/macos/workload:latest"
        try CRIShimUnsupportedFieldValidator.validate(container)
    }

    @Test
    func rejectsLinuxAndWindowsPodSandboxPlatformFields() {
        var request = Runtime_V1_RunPodSandboxRequest()
        request.config.linux.cgroupParent = "kubepods"
        request.config.windows.securityContext.runAsUsername = "ContainerUser"

        #expect(
            throws: CRIShimError.invalidArgument(
                "unsupported CRI platform field(s) for macOS guest workloads: config.linux, config.windows"
            )
        ) {
            try CRIShimUnsupportedFieldValidator.validate(request)
        }
    }

    @Test
    func rejectsLinuxAndWindowsContainerPlatformFields() {
        var request = Runtime_V1_CreateContainerRequest()
        request.config.linux.securityContext.privileged = true
        request.config.windows.securityContext.runAsUsername = "ContainerUser"
        request.sandboxConfig.linux.sysctls = ["net.ipv4.ip_forward": "1"]

        #expect(
            throws: CRIShimError.invalidArgument(
                "unsupported CRI platform field(s) for macOS guest workloads: config.linux, config.windows, sandbox_config.linux"
            )
        ) {
            try CRIShimUnsupportedFieldValidator.validate(request)
        }
    }
}
