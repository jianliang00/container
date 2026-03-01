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

import Foundation

/// Represents the disk-layout.v1+json metadata for a chunked macOS disk image.
public struct DiskLayout: Codable, Sendable {
    /// Layout version. Currently 1.
    public let version: Int
    /// Logical size of the complete disk image in bytes.
    public let logicalSize: Int64
    /// Size of each chunk in bytes (fixed 1 GiB = 1073741824).
    public let chunkSize: Int64
    /// Number of chunks: ceil(logicalSize / chunkSize).
    public let chunkCount: Int
    /// Compression parameters used for chunk blobs.
    public let compression: Compression
    /// Tar format parameters.
    public let tar: TarFormat
    /// Per-chunk metadata.
    public let chunks: [ChunkInfo]

    public static let defaultChunkSize: Int64 = 1_073_741_824 // 1 GiB

    public struct Compression: Codable, Sendable {
        public let type: String
        public let level: Int

        public init(type: String = "zstd", level: Int = 3) {
            self.type = type
            self.level = level
        }
    }

    public struct TarFormat: Codable, Sendable {
        public let format: String
        public let sparse: Bool

        public init(format: String = "pax", sparse: Bool = true) {
            self.format = format
            self.sparse = sparse
        }
    }

    public struct ChunkInfo: Codable, Sendable {
        /// Zero-based chunk index.
        public let index: Int
        /// Byte offset of this chunk within the disk image.
        public let offset: Int64
        /// Byte length of this chunk (may be less than chunkSize for the last chunk).
        public let length: Int64
        /// OCI layer blob digest (sha256 of the compressed tar+zstd blob).
        public let layerDigest: String
        /// OCI layer blob size (compressed size in bytes).
        public let layerSize: Int64
        /// SHA256 digest of the raw chunk bytes (including hole zeros).
        public let rawDigest: String
        /// Raw byte length of the chunk (uncompressed, equals `length`).
        public let rawLength: Int64

        public init(
            index: Int,
            offset: Int64,
            length: Int64,
            layerDigest: String,
            layerSize: Int64,
            rawDigest: String,
            rawLength: Int64
        ) {
            self.index = index
            self.offset = offset
            self.length = length
            self.layerDigest = layerDigest
            self.layerSize = layerSize
            self.rawDigest = rawDigest
            self.rawLength = rawLength
        }
    }

    public init(
        logicalSize: Int64,
        chunkSize: Int64 = DiskLayout.defaultChunkSize,
        compression: Compression = Compression(),
        tar: TarFormat = TarFormat(),
        chunks: [ChunkInfo]
    ) {
        self.version = 1
        self.logicalSize = logicalSize
        self.chunkSize = chunkSize
        self.chunkCount = Int((logicalSize + chunkSize - 1) / chunkSize)
        self.compression = compression
        self.tar = tar
        self.chunks = chunks
    }
}
