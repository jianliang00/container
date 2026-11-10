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

import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

struct MacOSDiskChainTests {
    private let hardware = Descriptor(mediaType: MacOSImageOCIMediaTypes.hardwareModel, digest: "sha256:hardware", size: 1)
    private let auxiliary = Descriptor(mediaType: MacOSImageOCIMediaTypes.auxiliaryStorage, digest: "sha256:aux", size: 1)
    private let base = Descriptor(
        mediaType: MacOSImageOCIMediaTypes.chainRawBase, digest: "sha256:" + String(repeating: "0", count: 64),
        size: 4096, annotations: [MacOSDiskChain.sizeAnnotation: "4096"]
    )

    private func overlay(_ index: Int, parent: String, size: String = "4096") -> Descriptor {
        Descriptor(
            mediaType: MacOSImageOCIMediaTypes.chainOverlay,
            digest: "sha256:" + String(repeating: String(index), count: 64),
            size: 1024, annotations: [MacOSDiskChain.sizeAnnotation: size, MacOSDiskChain.parentAnnotation: parent])
    }

    private func manifest(_ disks: [Descriptor], version: String = "1") -> Manifest {
        Manifest(
            schemaVersion: 2, mediaType: MediaTypes.imageManifest,
            config: .init(mediaType: MediaTypes.imageConfig, digest: "sha256:config", size: 1),
            layers: [hardware, auxiliary] + disks,
            annotations: [MacOSDiskChain.versionAnnotation: version]
        )
    }

    @Test func bindsVersionOrderParentAndSize() throws {
        let first = overlay(1, parent: base.digest)
        let second = overlay(2, parent: first.digest)
        let third = overlay(3, parent: second.digest)
        let fourth = overlay(4, parent: third.digest)
        let layers = try MacOSImageLayers(manifest: manifest([base, first, second, third]))
        guard case .derived(_, _, let chain) = layers else {
            Issue.record("derived disk chain was ignored")
            return
        }
        #expect(chain.base == base)
        #expect(chain.overlays == [first, second, third])
        #expect(chain.logicalSize == 4096)

        for disks in [
            [base], [base, second, first], [first, base], [base, first, third], [base, first, second, third, fourth],
            [base, overlay(1, parent: base.digest, size: "8192")],
            [base, first, Descriptor(mediaType: MacOSImageOCIMediaTypes.diskImage, digest: base.digest, size: base.size)],
        ] {
            #expect(throws: MacOSImageFormatError.self) { try MacOSImageLayers(manifest: manifest(disks)) }
        }
        #expect(throws: MacOSImageFormatError.self) { try MacOSImageLayers(manifest: manifest([base, first], version: "2")) }
    }
}
