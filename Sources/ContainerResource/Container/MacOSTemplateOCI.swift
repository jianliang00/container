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
    public static let hardwareModel = "application/vnd.apple.container.macos.hardware-model"
    public static let auxiliaryStorage = "application/vnd.apple.container.macos.auxiliary-storage"
    public static let diskImage = "application/vnd.apple.container.macos.disk-image"

    public static let required = [
        hardwareModel,
        auxiliaryStorage,
        diskImage,
    ]
}

public enum MacOSImageFormatError: Error, Equatable {
    case missingLayer(mediaType: String)
    case duplicateLayer(mediaType: String)
}

public struct MacOSImageLayers: Sendable {
    public let hardwareModel: Descriptor
    public let auxiliaryStorage: Descriptor
    public let diskImage: Descriptor

    public init(manifest: Manifest) throws {
        var hardwareModel: Descriptor?
        var auxiliaryStorage: Descriptor?
        var diskImage: Descriptor?

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
        guard let diskImage else {
            throw MacOSImageFormatError.missingLayer(mediaType: MacOSImageOCIMediaTypes.diskImage)
        }

        self.hardwareModel = hardwareModel
        self.auxiliaryStorage = auxiliaryStorage
        self.diskImage = diskImage
    }
}
