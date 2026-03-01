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

#if os(macOS)
import Foundation

/// Rebuilds a complete Disk.img from chunked tar+zstd blobs described by a DiskLayout.
public enum MacOSDiskRebuilder {
    public enum RebuildError: Error, CustomStringConvertible {
        case missingChunkBlob(index: Int, digest: String)
        case zstdDecompressionFailed(index: Int, message: String)
        case tarParseError(index: Int, message: String)
        case cacheDirectoryCreationFailed(path: String)

        public var description: String {
            switch self {
            case .missingChunkBlob(let i, let d):
                return "missing chunk blob \(i): \(d)"
            case .zstdDecompressionFailed(let i, let m):
                return "zstd decompression failed for chunk \(i): \(m)"
            case .tarParseError(let i, let m):
                return "tar parse error for chunk \(i): \(m)"
            case .cacheDirectoryCreationFailed(let p):
                return "failed to create cache directory: \(p)"
            }
        }
    }

    /// Rebuild a Disk.img from chunks, writing to the given output path.
    /// Uses atomic rename for safety.
    ///
    /// - Parameters:
    ///   - layout: The DiskLayout describing the chunks
    ///   - chunkBlobPaths: Map from chunk layerDigest to the local file path of the blob
    ///   - outputPath: Where to write the rebuilt Disk.img
    ///   - progressHandler: Optional callback for reporting progress (chunkIndex, totalChunks)
    public static func rebuild(
        layout: DiskLayout,
        chunkBlobPaths: [String: URL],
        outputPath: URL,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) throws {
        let fm = FileManager.default

        // Create output directory if needed
        let outputDir = outputPath.deletingLastPathComponent()
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Use a temporary file for atomic write
        let tempPath = outputDir.appendingPathComponent(".rebuild-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tempPath) }

        // Create and truncate output file to logical size
        fm.createFile(atPath: tempPath.path, contents: nil)
        let outFd = open(tempPath.path, O_RDWR)
        guard outFd >= 0 else {
            throw RebuildError.cacheDirectoryCreationFailed(path: tempPath.path)
        }
        defer { close(outFd) }

        // Truncate to logical size (creates a sparse file)
        guard ftruncate(outFd, layout.logicalSize) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }

        // Process each chunk
        for chunk in layout.chunks {
            guard let blobPath = chunkBlobPaths[chunk.layerDigest] else {
                throw RebuildError.missingChunkBlob(index: chunk.index, digest: chunk.layerDigest)
            }

            try rebuildChunk(
                chunkInfo: chunk,
                blobPath: blobPath,
                outFd: outFd
            )

            progressHandler?(chunk.index, layout.chunkCount)
        }

        // Sync to disk
        fsync(outFd)
        close(outFd)

        // Atomic rename
        if fm.fileExists(atPath: outputPath.path) {
            try fm.removeItem(at: outputPath)
        }
        try fm.moveItem(at: tempPath, to: outputPath)
    }

    /// Check if a rebuild cache entry exists and is valid.
    public static func cacheExists(at path: URL) -> Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    /// Compute the rebuild cache path for a given manifest digest.
    public static func rebuildCachePath(
        cacheDir: URL,
        manifestDigest: String
    ) -> URL {
        let safeDigest = manifestDigest.replacingOccurrences(of: ":", with: "-")
        return cacheDir
            .appendingPathComponent(safeDigest)
            .appendingPathComponent("Disk.img")
    }

    // MARK: - Private

    /// Decompress a chunk blob (tar+zstd) and write its data extents to the output file.
    private static func rebuildChunk(
        chunkInfo: DiskLayout.ChunkInfo,
        blobPath: URL,
        outFd: Int32
    ) throws {
        // Decompress zstd to a temporary tar file
        let tempTar = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebuild-chunk-\(chunkInfo.index)-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tempTar) }

        try decompressZstd(input: blobPath, output: tempTar, chunkIndex: chunkInfo.index)

        // Parse the PAX sparse tar and write data extents
        try parseSparseAndWrite(
            tarPath: tempTar,
            chunkInfo: chunkInfo,
            outFd: outFd
        )
    }

    /// Decompress a zstd file using the zstd command.
    private static func decompressZstd(input: URL, output: URL, chunkIndex: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zstd", "-d", "-f", "-o", output.path, input.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            throw RebuildError.zstdDecompressionFailed(index: chunkIndex, message: err)
        }
    }

    /// Parse a PAX sparse tar file and write data extents to the output file descriptor.
    private static func parseSparseAndWrite(
        tarPath: URL,
        chunkInfo: DiskLayout.ChunkInfo,
        outFd: Int32
    ) throws {
        let tarFd = open(tarPath.path, O_RDONLY)
        guard tarFd >= 0 else {
            throw RebuildError.tarParseError(index: chunkInfo.index, message: "cannot open tar file")
        }
        defer { close(tarFd) }

        // Read and parse the PAX extended header
        var header = [UInt8](repeating: 0, count: 512)

        // First block: PAX extended header (typeflag 'x')
        guard read(tarFd, &header, 512) == 512 else {
            throw RebuildError.tarParseError(index: chunkInfo.index, message: "short read on PAX header")
        }

        guard header[156] == UInt8(Character("x").asciiValue!) else {
            throw RebuildError.tarParseError(index: chunkInfo.index, message: "expected PAX header (typeflag 'x'), got '\(header[156])'")
        }

        let paxSize = parseOctalField(header, offset: 124, width: 12)
        guard paxSize > 0 else {
            throw RebuildError.tarParseError(index: chunkInfo.index, message: "invalid PAX header size")
        }

        // Read PAX extended header data
        let paxBlockSize = Int((paxSize + 511) / 512) * 512
        var paxData = [UInt8](repeating: 0, count: paxBlockSize)
        guard read(tarFd, &paxData, paxBlockSize) == paxBlockSize else {
            throw RebuildError.tarParseError(index: chunkInfo.index, message: "short read on PAX data")
        }

        // Parse sparse map from PAX data
        let paxString = String(bytes: paxData.prefix(Int(paxSize)), encoding: .utf8) ?? ""
        let sparseMap = parsePAXSparseMap(paxString)

        // Second block: regular file header (typeflag '0')
        guard read(tarFd, &header, 512) == 512 else {
            throw RebuildError.tarParseError(index: chunkInfo.index, message: "short read on file header")
        }

        // Read data and write extents to output
        let bufSize = 1 << 20 // 1 MiB
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        for extent in sparseMap {
            let writeOffset = chunkInfo.offset + extent.offset
            var remaining = extent.length

            while remaining > 0 {
                let toRead = min(Int(remaining), bufSize)
                let n = read(tarFd, buf, toRead)
                guard n > 0 else {
                    throw RebuildError.tarParseError(
                        index: chunkInfo.index,
                        message: "short read on data extent at offset \(extent.offset)"
                    )
                }

                // pwrite at the correct offset in the output file
                let written = pwrite(outFd, buf, n, writeOffset + (extent.length - remaining))
                guard written == n else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                remaining -= Int64(n)
            }
        }
    }

    /// Parse the GNU.sparse.map value from PAX extended header data.
    /// Returns sparse extents as (offset, length) pairs.
    private static func parsePAXSparseMap(_ paxData: String) -> [(offset: Int64, length: Int64)] {
        var sparseMap: [(offset: Int64, length: Int64)] = []

        // Parse PAX records to find GNU.sparse.map
        var remaining = paxData[paxData.startIndex...]
        while !remaining.isEmpty {
            // Each record: "<length> <key>=<value>\n"
            guard let spaceIdx = remaining.firstIndex(of: " ") else { break }
            guard let lenVal = Int(remaining[remaining.startIndex..<spaceIdx]) else { break }

            let recordStart = remaining.startIndex
            let recordEnd = remaining.index(recordStart, offsetBy: lenVal, limitedBy: remaining.endIndex) ?? remaining.endIndex
            let record = remaining[recordStart..<recordEnd]
            remaining = remaining[recordEnd...]

            // Parse key=value from after the space
            let afterSpace = record[record.index(after: spaceIdx)...]
            guard let equalsIdx = afterSpace.firstIndex(of: "=") else { continue }
            let key = String(afterSpace[afterSpace.startIndex..<equalsIdx])
            var value = String(afterSpace[afterSpace.index(after: equalsIdx)...])

            // Strip trailing newline
            if value.hasSuffix("\n") {
                value.removeLast()
            }

            if key == "GNU.sparse.map" {
                // Parse comma-separated offset,length pairs
                let parts = value.split(separator: ",")
                var i = 0
                while i + 1 < parts.count {
                    if let offset = Int64(parts[i]), let length = Int64(parts[i + 1]) {
                        sparseMap.append((offset: offset, length: length))
                    }
                    i += 2
                }
            }
        }

        return sparseMap
    }

    /// Parse an octal field from a tar header.
    private static func parseOctalField(_ header: [UInt8], offset: Int, width: Int) -> Int64 {
        var result: Int64 = 0
        for i in 0..<width {
            let byte = header[offset + i]
            if byte == 0 || byte == 0x20 { break }
            if byte >= 0x30 && byte <= 0x37 {
                result = result * 8 + Int64(byte - 0x30)
            }
        }
        return result
    }
}
#endif
