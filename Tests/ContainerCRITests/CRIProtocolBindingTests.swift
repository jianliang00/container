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

struct CRIProtocolBindingTests {
    @Test func generatedRuntimeServiceMatchesPinnedRuntimeAPI() {
        let descriptor = Runtime_V1_RuntimeServiceServerMetadata.serviceDescriptor

        #expect(descriptor.fullName == "\(CRIProtocol.runtimeAPIVersion).RuntimeService")
        #expect(Runtime_V1_RuntimeServiceClientMetadata.Methods.version.path == "/runtime.v1.RuntimeService/Version")
        #expect(Runtime_V1_RuntimeServiceClientMetadata.Methods.status.path == "/runtime.v1.RuntimeService/Status")
        #expect(Runtime_V1_RuntimeServiceClientMetadata.Methods.runtimeConfig.path == "/runtime.v1.RuntimeService/RuntimeConfig")
        #expect(Runtime_V1_RuntimeServiceClientMetadata.Methods.runPodSandbox.path == "/runtime.v1.RuntimeService/RunPodSandbox")
        #expect(Runtime_V1_RuntimeServiceClientMetadata.Methods.portForward.path == "/runtime.v1.RuntimeService/PortForward")
    }

    @Test func generatedImageServiceMatchesPinnedRuntimeAPI() {
        let descriptor = Runtime_V1_ImageServiceServerMetadata.serviceDescriptor

        #expect(descriptor.fullName == "\(CRIProtocol.runtimeAPIVersion).ImageService")
        #expect(Runtime_V1_ImageServiceClientMetadata.Methods.listImages.path == "/runtime.v1.ImageService/ListImages")
        #expect(Runtime_V1_ImageServiceClientMetadata.Methods.imageStatus.path == "/runtime.v1.ImageService/ImageStatus")
        #expect(Runtime_V1_ImageServiceClientMetadata.Methods.pullImage.path == "/runtime.v1.ImageService/PullImage")
        #expect(Runtime_V1_ImageServiceClientMetadata.Methods.removeImage.path == "/runtime.v1.ImageService/RemoveImage")
        #expect(Runtime_V1_ImageServiceClientMetadata.Methods.imageFsInfo.path == "/runtime.v1.ImageService/ImageFsInfo")
    }
}
