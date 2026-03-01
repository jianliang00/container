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

struct MacOSOCIFormatTests {
    @Test
    func parseRequiredMacOSLayersFromManifest() throws {
        let manifestJSON = """
            {
              "schemaVersion": 2,
              "mediaType": "application/vnd.oci.image.manifest.v1+json",
              "config": {
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": "sha256:config",
                "size": 1
              },
              "layers": [
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.hardwareModel)",
                  "digest": "sha256:hardware",
                  "size": 10
                },
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.auxiliaryStorage)",
                  "digest": "sha256:aux",
                  "size": 20
                },
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.diskImage)",
                  "digest": "sha256:disk",
                  "size": 30
                }
              ]
            }
            """

        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(manifestJSON.utf8))
        let layers = try MacOSImageLayers(manifest: manifest)

        #expect(layers.hardwareModel.digest == "sha256:hardware")
        #expect(layers.auxiliaryStorage.digest == "sha256:aux")

        guard case .v0(_, _, let diskImage) = layers else {
            Issue.record("expected v0 format")
            return
        }
        #expect(diskImage.digest == "sha256:disk")
    }

    @Test
    func missingLayerFailsValidation() throws {
        let manifestJSON = """
            {
              "schemaVersion": 2,
              "mediaType": "application/vnd.oci.image.manifest.v1+json",
              "config": {
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": "sha256:config",
                "size": 1
              },
              "layers": [
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.hardwareModel)",
                  "digest": "sha256:hardware",
                  "size": 10
                }
              ]
            }
            """
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(manifestJSON.utf8))
        #expect(throws: MacOSImageFormatError.self) {
            _ = try MacOSImageLayers(manifest: manifest)
        }
    }

    @Test
    func parseV1ChunkedFormatFromManifest() throws {
        let manifestJSON = """
            {
              "schemaVersion": 2,
              "mediaType": "application/vnd.oci.image.manifest.v1+json",
              "config": {
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": "sha256:config",
                "size": 1
              },
              "layers": [
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.hardwareModel)",
                  "digest": "sha256:hardware",
                  "size": 10
                },
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.auxiliaryStorage)",
                  "digest": "sha256:aux",
                  "size": 20
                },
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.diskLayout)",
                  "digest": "sha256:layout",
                  "size": 500
                },
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.diskChunk)",
                  "digest": "sha256:chunk1",
                  "size": 100,
                  "annotations": {
                    "org.apple.container.macos.chunk.index": "1"
                  }
                },
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.diskChunk)",
                  "digest": "sha256:chunk0",
                  "size": 200,
                  "annotations": {
                    "org.apple.container.macos.chunk.index": "0"
                  }
                }
              ]
            }
            """

        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(manifestJSON.utf8))
        let layers = try MacOSImageLayers(manifest: manifest)

        #expect(layers.hardwareModel.digest == "sha256:hardware")
        #expect(layers.auxiliaryStorage.digest == "sha256:aux")

        guard case .v1(_, _, let diskLayout, let diskChunks) = layers else {
            Issue.record("expected v1 format")
            return
        }
        #expect(diskLayout.digest == "sha256:layout")
        #expect(diskChunks.count == 2)
        // Chunks should be sorted by index annotation
        #expect(diskChunks[0].digest == "sha256:chunk0")
        #expect(diskChunks[1].digest == "sha256:chunk1")
    }

    @Test
    func v1MissingChunksFailsValidation() throws {
        let manifestJSON = """
            {
              "schemaVersion": 2,
              "mediaType": "application/vnd.oci.image.manifest.v1+json",
              "config": {
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": "sha256:config",
                "size": 1
              },
              "layers": [
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.hardwareModel)",
                  "digest": "sha256:hardware",
                  "size": 10
                },
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.auxiliaryStorage)",
                  "digest": "sha256:aux",
                  "size": 20
                },
                {
                  "mediaType": "\(MacOSImageOCIMediaTypes.diskLayout)",
                  "digest": "sha256:layout",
                  "size": 500
                }
              ]
            }
            """
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(manifestJSON.utf8))
        #expect(throws: MacOSImageFormatError.self) {
            _ = try MacOSImageLayers(manifest: manifest)
        }
    }
}
