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
import Foundation

/// The OCI manifest lists one RAW base and its immutable overlays from oldest to newest.
public struct MacOSDiskChain: Sendable {
    public static let versionAnnotation = "org.apple.container.macos.disk-chain.version"
    public static let sizeAnnotation = "org.apple.container.macos.disk-chain.logical-size"
    public static let parentAnnotation = "org.apple.container.macos.disk-chain.parent"
    public static let mergeThreshold = 4
    public static let maximumDepth = 5
    public static let maximumLogicalSize: Int64 = 1 << 40

    public let base: Descriptor
    public let chunks: [Descriptor]
    public let overlays: [Descriptor]
    public let logicalSize: Int64

    public init(base: Descriptor, chunks: [Descriptor], overlays: [Descriptor]) throws {
        guard let sizeText = base.annotations?[Self.sizeAnnotation], let size = Int64(sizeText),
            String(size) == sizeText, size > 0, size <= Self.maximumLogicalSize, size % 512 == 0,
            Self.isBlob(base), (1...(Self.maximumDepth - 2)).contains(overlays.count)
        else { throw MacOSImageFormatError.invalidDiskChain("invalid base or overlay depth") }

        switch base.mediaType {
        case MacOSImageOCIMediaTypes.chainRawBase:
            guard chunks.isEmpty, base.size == size else {
                throw MacOSImageFormatError.invalidDiskChain("invalid RAW base size or chunks")
            }
        case MacOSImageOCIMediaTypes.chainChunkedBase:
            guard !chunks.isEmpty, chunks.count <= 1024,
                chunks.allSatisfy({ $0.mediaType == MacOSImageOCIMediaTypes.diskChunk && Self.isBlob($0) })
            else { throw MacOSImageFormatError.invalidDiskChain("invalid RAW chunk descriptors") }
        default:
            throw MacOSImageFormatError.invalidDiskChain("unknown base media type")
        }

        var parent = base.digest
        for overlay in overlays {
            guard overlay.mediaType == MacOSImageOCIMediaTypes.chainOverlay, Self.isBlob(overlay),
                overlay.annotations?[Self.parentAnnotation] == parent,
                overlay.annotations?[Self.sizeAnnotation] == sizeText
            else { throw MacOSImageFormatError.invalidDiskChain("invalid overlay parent or size") }
            parent = overlay.digest
        }
        self.base = base
        self.chunks = chunks
        self.overlays = overlays
        logicalSize = size
    }

    /// Bind the existing RAW rebuild recipe to the OCI chunk order before allocating disk space.
    public func validate(layout: DiskLayout) throws {
        guard layout.version == 1, layout.logicalSize == logicalSize,
            layout.chunkSize == DiskLayout.defaultChunkSize,
            layout.chunkCount == chunks.count, layout.chunks.count == chunks.count,
            Int((logicalSize + layout.chunkSize - 1) / layout.chunkSize) == chunks.count
        else { throw MacOSImageFormatError.invalidDiskChain("invalid RAW disk layout") }

        for (index, pair) in zip(layout.chunks, chunks).enumerated() {
            let (chunk, descriptor) = pair
            let offset = Int64(index) * layout.chunkSize
            let length = min(layout.chunkSize, logicalSize - offset)
            guard chunk.index == index, chunk.offset == offset, chunk.length == length, chunk.rawLength == length,
                chunk.layerDigest == descriptor.digest, chunk.layerSize == descriptor.size
            else { throw MacOSImageFormatError.invalidDiskChain("RAW chunk does not match disk layout") }
        }
    }

    /// Use the layout digest as the cache key so derived images share the decoded RAW disk.
    public func resolve(in store: any ContentStore) async throws -> (base: URL, overlays: [URL]) {
        let source = try await Self.verifiedContent(base, in: store)
        let baseURL: URL
        if base.mediaType == MacOSImageOCIMediaTypes.chainRawBase {
            baseURL = source.path
        } else {
            let layout: DiskLayout = try source.decode()
            try validate(layout: layout)
            baseURL = MacOSDiskRebuilder.rebuildCachePath(cacheDir: MacOSGuestCache.rebuildCacheDirectory(), manifestDigest: base.digest)
            if !MacOSDiskRebuilder.cacheExists(at: baseURL) {
                var paths = [String: URL]()
                for chunk in chunks where paths[chunk.digest] == nil {
                    paths[chunk.digest] = try await Self.verifiedContent(chunk, in: store).path
                }
                try MacOSDiskRebuilder.rebuild(layout: layout, chunkBlobPaths: paths, outputPath: baseURL)
            }
            let size = try baseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, Int64(size) == logicalSize else { throw MacOSImageFormatError.invalidDiskChain("invalid decoded RAW base size") }
        }
        var layers = [URL]()
        for overlay in overlays {
            layers.append(try await Self.verifiedContent(overlay, in: store).path)
        }
        return (baseURL, layers)
    }

    public static func verifiedContent(_ descriptor: Descriptor, in store: any ContentStore) async throws -> any Content {
        guard Self.isBlob(descriptor), let content: Content = try await store.get(digest: descriptor.digest),
            try content.size() == UInt64(descriptor.size),
            try "sha256:" + content.digest().map({ String(format: "%02x", $0) }).joined() == descriptor.digest
        else { throw MacOSImageFormatError.invalidDiskChain("invalid content for \(descriptor.digest)") }
        return content
    }

    private static func isBlob(_ descriptor: Descriptor) -> Bool {
        descriptor.size > 0 && isDigest(descriptor.digest)
    }

    package static func isDigest(_ digest: String) -> Bool {
        digest.hasPrefix("sha256:") && digest.utf8.count == 71
            && digest.utf8.dropFirst(7).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
