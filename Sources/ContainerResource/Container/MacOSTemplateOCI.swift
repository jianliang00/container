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

import ContainerizationOCI

public enum MacOSImageOCIMediaTypes {
    // Existing v0 media types
    public static let hardwareModel = "application/vnd.apple.container.macos.hardware-model"
    public static let auxiliaryStorage = "application/vnd.apple.container.macos.auxiliary-storage"
    public static let diskImage = "application/vnd.apple.container.macos.disk-image"

    // v1 chunked media types
    public static let diskLayout = "application/vnd.apple.container.macos.disk-layout.v1+json"
    public static let diskChunk = "application/vnd.apple.container.macos.disk-chunk.v1.tar+zstd"

    public static let chainRawBase = "application/vnd.apple.container.macos.disk-chain.v1.raw"
    public static let chainChunkedBase = "application/vnd.apple.container.macos.disk-chain.v1.layout+json"
    public static let chainOverlay = "application/vnd.apple.container.macos.disk-chain.v1.asif"

    public static let required = [
        hardwareModel,
        auxiliaryStorage,
        diskImage,
    ]
}

public enum MacOSImageFormatError: Error, Equatable {
    case missingLayer(mediaType: String)
    case duplicateLayer(mediaType: String)
    case invalidDiskChain(String)
}

/// Parsed macOS image layers, supporting both v0 (single disk image) and v1 (chunked disk) formats.
public enum MacOSImageLayers: Sendable {
    /// v0: single raw disk image blob.
    case v0(hardwareModel: Descriptor, auxiliaryStorage: Descriptor, diskImage: Descriptor)
    /// v1: disk layout JSON + N disk chunk blobs.
    case v1(hardwareModel: Descriptor, auxiliaryStorage: Descriptor, diskLayout: Descriptor, diskChunks: [Descriptor])

    case derived(hardwareModel: Descriptor, auxiliaryStorage: Descriptor, chain: MacOSDiskChain)

    public var hardwareModel: Descriptor {
        switch self {
        case .v0(let hw, _, _): return hw
        case .v1(let hw, _, _, _), .derived(let hw, _, _): return hw
        }
    }

    public var auxiliaryStorage: Descriptor {
        switch self {
        case .v0(_, let aux, _): return aux
        case .v1(_, let aux, _, _), .derived(_, let aux, _): return aux
        }
    }

    public init(manifest: Manifest) throws {
        var hardwareModel: Descriptor?
        var auxiliaryStorage: Descriptor?
        var diskImage: Descriptor?
        var diskLayout: Descriptor?
        var diskChunks: [Descriptor] = []
        var chainBase: Descriptor?
        var overlays: [Descriptor] = []

        for layer in manifest.layers {
            switch layer.mediaType {
            case MacOSImageOCIMediaTypes.hardwareModel:
                if hardwareModel != nil {
                    throw MacOSImageFormatError.duplicateLayer(mediaType: layer.mediaType)
                }
                hardwareModel = layer
            case MacOSImageOCIMediaTypes.auxiliaryStorage:
                if auxiliaryStorage != nil {
                    throw MacOSImageFormatError.duplicateLayer(mediaType: layer.mediaType)
                }
                auxiliaryStorage = layer
            case MacOSImageOCIMediaTypes.diskImage:
                if diskImage != nil {
                    throw MacOSImageFormatError.duplicateLayer(mediaType: layer.mediaType)
                }
                diskImage = layer
            case MacOSImageOCIMediaTypes.diskLayout:
                if diskLayout != nil {
                    throw MacOSImageFormatError.duplicateLayer(mediaType: layer.mediaType)
                }
                diskLayout = layer
            case MacOSImageOCIMediaTypes.chainRawBase, MacOSImageOCIMediaTypes.chainChunkedBase:
                guard chainBase == nil, overlays.isEmpty else {
                    throw MacOSImageFormatError.invalidDiskChain("base must precede all overlays")
                }
                chainBase = layer
            case MacOSImageOCIMediaTypes.chainOverlay:
                overlays.append(layer)
            case MacOSImageOCIMediaTypes.diskChunk:
                diskChunks.append(layer)
            default:
                continue
            }
        }

        guard let hardwareModel else {
            throw MacOSImageFormatError.missingLayer(mediaType: MacOSImageOCIMediaTypes.hardwareModel)
        }
        guard let auxiliaryStorage else {
            throw MacOSImageFormatError.missingLayer(mediaType: MacOSImageOCIMediaTypes.auxiliaryStorage)
        }

        if chainBase != nil || !overlays.isEmpty || manifest.annotations?[MacOSDiskChain.versionAnnotation] != nil {
            guard let chainBase, diskImage == nil, diskLayout == nil,
                manifest.annotations?[MacOSDiskChain.versionAnnotation] == "1"
            else {
                throw MacOSImageFormatError.invalidDiskChain("unsupported version or ambiguous base")
            }
            let chain = try MacOSDiskChain(base: chainBase, chunks: diskChunks, overlays: overlays)
            self = .derived(hardwareModel: hardwareModel, auxiliaryStorage: auxiliaryStorage, chain: chain)
            return
        }

        // v1 format: diskLayout present
        if let diskLayout {
            guard !diskChunks.isEmpty else {
                throw MacOSImageFormatError.missingLayer(mediaType: MacOSImageOCIMediaTypes.diskChunk)
            }
            // Sort chunks by index annotation to ensure consistent ordering
            let sorted = diskChunks.sorted { a, b in
                let ai = a.annotations?["org.apple.container.macos.chunk.index"].flatMap(Int.init) ?? 0
                let bi = b.annotations?["org.apple.container.macos.chunk.index"].flatMap(Int.init) ?? 0
                return ai < bi
            }
            self = .v1(hardwareModel: hardwareModel, auxiliaryStorage: auxiliaryStorage, diskLayout: diskLayout, diskChunks: sorted)
            return
        }

        // v0 format: single disk image
        guard let diskImage else {
            throw MacOSImageFormatError.missingLayer(mediaType: MacOSImageOCIMediaTypes.diskImage)
        }
        self = .v0(hardwareModel: hardwareModel, auxiliaryStorage: auxiliaryStorage, diskImage: diskImage)
    }
}
