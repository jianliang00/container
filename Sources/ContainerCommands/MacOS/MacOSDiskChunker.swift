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
import CryptoKit
import Foundation

/// A data extent (non-hole region) within a chunk.
struct SparseExtent {
    /// Offset relative to the chunk start.
    let offset: Int64
    /// Length of the data region.
    let length: Int64
}

/// Result of processing a single chunk.
struct ChunkResult {
    let index: Int
    let chunkOffset: Int64
    let chunkLength: Int64
    let blobURL: URL
    let blobDigest: String
    let blobSize: Int64
    let rawDigest: String
    let rawLength: Int64
}

enum MacOSDiskChunker {
    static let zstdLevel = 3
    static let tarEntryName = "disk.chunk"

    /// Split a disk image into 1 GiB chunks, generating sparse tar+zstd blobs.
    /// Returns chunk results and writes blobs to blobsDir.
    static func chunkDiskImage(
        diskImage: URL,
        blobsDir: URL,
        chunkSize: Int64 = DiskLayout.defaultChunkSize
    ) throws -> [ChunkResult] {
        let fm = FileManager.default
        let fileSize = try Self.logicalFileSize(diskImage)
        let chunkCount = Int((fileSize + chunkSize - 1) / chunkSize)

        let fd = open(diskImage.path, O_RDONLY)
        guard fd >= 0 else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: diskImage.path])
        }
        defer { close(fd) }

        var results: [ChunkResult] = []

        for i in 0..<chunkCount {
            let offset = Int64(i) * chunkSize
            let length = min(chunkSize, fileSize - offset)
            let result = try processChunk(
                fd: fd,
                index: i,
                chunkOffset: offset,
                chunkLength: length,
                blobsDir: blobsDir
            )
            results.append(result)
        }

        return results
    }

    /// Get the logical file size (works for sparse files).
    static func logicalFileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? Int64 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return size
    }

    /// Process a single chunk: detect sparse regions, create tar+zstd blob.
    private static func processChunk(
        fd: Int32,
        index: Int,
        chunkOffset: Int64,
        chunkLength: Int64,
        blobsDir: URL
    ) throws -> ChunkResult {
        // 1. Detect sparse extents within this chunk
        let extents = detectSparseExtents(fd: fd, regionOffset: chunkOffset, regionLength: chunkLength)

        // 2. Compute raw digest (SHA256 of full chunk bytes including holes as zeros)
        let rawDigest = try computeRawDigest(fd: fd, offset: chunkOffset, length: chunkLength)

        // 3. Generate PAX sparse tar
        let tempTar = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-\(index)-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tempTar) }
        try writePAXSparseTar(
            fd: fd,
            chunkOffset: chunkOffset,
            chunkLength: chunkLength,
            extents: extents,
            outputPath: tempTar
        )

        // 4. Compress with zstd
        let tempZst = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-\(index)-\(UUID().uuidString).tar.zst")
        defer { try? FileManager.default.removeItem(at: tempZst) }
        try compressWithZstd(input: tempTar, output: tempZst, level: zstdLevel)

        // 5. Compute blob digest and size
        let (blobDigest, blobSize) = try sha256AndSize(of: tempZst)

        // 6. Move blob to blobs directory
        let blobPath = blobsDir.appendingPathComponent(blobDigest)
        if !FileManager.default.fileExists(atPath: blobPath.path) {
            try FileManager.default.moveItem(at: tempZst, to: blobPath)
        }

        return ChunkResult(
            index: index,
            chunkOffset: chunkOffset,
            chunkLength: chunkLength,
            blobURL: blobPath,
            blobDigest: "sha256:\(blobDigest)",
            blobSize: blobSize,
            rawDigest: "sha256:\(rawDigest)",
            rawLength: chunkLength
        )
    }

    // MARK: - Sparse Detection

    /// Detect non-hole (data) extents within a region of a file using SEEK_HOLE/SEEK_DATA.
    static func detectSparseExtents(fd: Int32, regionOffset: Int64, regionLength: Int64) -> [SparseExtent] {
        let regionEnd = regionOffset + regionLength
        var extents: [SparseExtent] = []
        var pos = regionOffset

        while pos < regionEnd {
            // Find next data region
            let dataStart = lseek(fd, pos, SEEK_DATA)
            if dataStart == -1 || dataStart >= regionEnd {
                // No more data in this region
                break
            }

            // Find end of data region (start of next hole)
            var holeStart = lseek(fd, dataStart, SEEK_HOLE)
            if holeStart == -1 || holeStart > regionEnd {
                holeStart = regionEnd
            }

            let extentOffset = dataStart - regionOffset
            let extentLength = holeStart - dataStart
            if extentLength > 0 {
                extents.append(SparseExtent(offset: extentOffset, length: extentLength))
            }

            pos = holeStart
        }

        return extents
    }

    // MARK: - Raw Digest

    /// Compute SHA256 of raw chunk bytes (reading through holes as zeros).
    private static func computeRawDigest(fd: Int32, offset: Int64, length: Int64) throws -> String {
        var hasher = SHA256()
        let bufSize = 1 << 20 // 1 MiB
        var remaining = length

        lseek(fd, offset, SEEK_SET)

        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        while remaining > 0 {
            let toRead = min(Int(remaining), bufSize)
            let n = read(fd, buf, toRead)
            guard n > 0 else {
                if n == 0 {
                    // Short read near EOF - pad with zeros
                    let zeros = [UInt8](repeating: 0, count: Int(remaining))
                    hasher.update(data: zeros)
                    break
                }
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            remaining -= Int64(n)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - PAX Sparse Tar Writer

    /// Write a deterministic PAX sparse tar archive containing a single chunk entry.
    private static func writePAXSparseTar(
        fd: Int32,
        chunkOffset: Int64,
        chunkLength: Int64,
        extents: [SparseExtent],
        outputPath: URL
    ) throws {
        let outFd = open(outputPath.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFd >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: outputPath.path])
        }
        defer { close(outFd) }

        let actualDataSize = extents.reduce(Int64(0)) { $0 + $1.length }

        // Build PAX extended header data
        let paxData = buildPAXHeaderData(
            chunkLength: chunkLength,
            extents: extents,
            actualDataSize: actualDataSize
        )

        // Write PAX extended header block (typeflag 'x')
        let paxHeader = buildUstarHeader(
            name: "PaxHeader/disk.chunk",
            size: Int64(paxData.count),
            mode: 0o644,
            typeflag: Character("x")
        )
        try writeAll(outFd, data: paxHeader)
        try writeAll(outFd, data: paxData)
        try writePadding(outFd, dataSize: Int64(paxData.count))

        // Write regular file header (typeflag '0')
        let fileHeader = buildUstarHeader(
            name: "GNUSparseFile.0/disk.chunk",
            size: actualDataSize,
            mode: 0o644,
            typeflag: Character("0")
        )
        try writeAll(outFd, data: fileHeader)

        // Write data extents
        let bufSize = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        for extent in extents {
            lseek(fd, chunkOffset + extent.offset, SEEK_SET)
            var remaining = extent.length
            while remaining > 0 {
                let toRead = min(Int(remaining), bufSize)
                let n = read(fd, buf, toRead)
                guard n > 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                try writeAll(outFd, buf: buf, count: n)
                remaining -= Int64(n)
            }
        }

        // Pad data to 512-byte boundary
        try writePadding(outFd, dataSize: actualDataSize)

        // Write two zero blocks to end archive
        let zeroBlock = [UInt8](repeating: 0, count: 1024)
        try writeAll(outFd, data: zeroBlock)
    }

    /// Build PAX extended header data with sparse map.
    private static func buildPAXHeaderData(
        chunkLength: Int64,
        extents: [SparseExtent],
        actualDataSize: Int64
    ) -> [UInt8] {
        var records: [String] = []

        // GNU.sparse.map
        let mapValue = extents.map { "\($0.offset),\($0.length)" }.joined(separator: ",")
        records.append(paxRecord(key: "GNU.sparse.map", value: mapValue))

        // GNU.sparse.name
        records.append(paxRecord(key: "GNU.sparse.name", value: tarEntryName))

        // GNU.sparse.realsize
        records.append(paxRecord(key: "GNU.sparse.realsize", value: "\(chunkLength)"))

        let paxString = records.joined()
        return [UInt8](paxString.utf8)
    }

    /// Format a single PAX record: "<length> <key>=<value>\n"
    private static func paxRecord(key: String, value: String) -> String {
        // The length includes itself, the space, key, '=', value, and '\n'
        let baseContent = " \(key)=\(value)\n"
        // We need to find the correct length, which includes the decimal length prefix itself
        var lenStr = ""
        for digits in 1...20 {
            let candidate = digits + baseContent.utf8.count
            let candidateStr = "\(candidate)"
            if candidateStr.count == digits {
                lenStr = candidateStr
                break
            }
        }
        return "\(lenStr)\(baseContent)"
    }

    /// Build a 512-byte ustar header block.
    private static func buildUstarHeader(name: String, size: Int64, mode: UInt32, typeflag: Character) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 512)

        // name (0-99)
        writeString(&header, offset: 0, value: name, maxLen: 100)
        // mode (100-107)
        writeOctal(&header, offset: 100, value: UInt64(mode), width: 8)
        // uid (108-115)
        writeOctal(&header, offset: 108, value: 0, width: 8)
        // gid (116-123)
        writeOctal(&header, offset: 116, value: 0, width: 8)
        // size (124-135)
        writeOctal(&header, offset: 124, value: UInt64(size), width: 12)
        // mtime (136-147)
        writeOctal(&header, offset: 136, value: 0, width: 12)
        // typeflag (156)
        header[156] = UInt8(typeflag.asciiValue!)
        // magic (257-262) "ustar\0"
        writeString(&header, offset: 257, value: "ustar", maxLen: 6)
        // version (263-264) "00"
        header[263] = UInt8(Character("0").asciiValue!)
        header[264] = UInt8(Character("0").asciiValue!)

        // Compute checksum
        // First fill checksum field with spaces
        for i in 148..<156 {
            header[i] = 0x20 // space
        }
        var checksum: UInt32 = 0
        for byte in header {
            checksum += UInt32(byte)
        }
        writeOctal(&header, offset: 148, value: UInt64(checksum), width: 7)
        header[155] = 0x20 // trailing space

        return header
    }

    private static func writeString(_ header: inout [UInt8], offset: Int, value: String, maxLen: Int) {
        let bytes = [UInt8](value.utf8)
        let count = min(bytes.count, maxLen - 1)
        for i in 0..<count {
            header[offset + i] = bytes[i]
        }
    }

    private static func writeOctal(_ header: inout [UInt8], offset: Int, value: UInt64, width: Int) {
        let s = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, width - 1 - s.count)) + s
        let bytes = [UInt8](padded.utf8)
        let count = min(bytes.count, width - 1)
        for i in 0..<count {
            header[offset + i] = bytes[i]
        }
        header[offset + count] = 0 // null terminator
    }

    // MARK: - Zstd Compression

    /// Compress a file using zstd with deterministic parameters.
    static func compressWithZstd(input: URL, output: URL, level: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "zstd",
            "-\(level)",
            "--single-thread",
            "--no-check",
            "-f",
            "-o", output.path,
            input.path,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown zstd error"
            throw NSError(
                domain: "container.macos.zstd",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "zstd compression failed: \(err)"]
            )
        }
    }

    // MARK: - SHA256 / File Utilities

    static func sha256AndSize(of fileURL: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else {
                break
            }
            size += Int64(data.count)
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, size)
    }

    private static func writeAll(_ fd: Int32, data: [UInt8]) throws {
        try data.withUnsafeBytes { buf in
            var written = 0
            while written < buf.count {
                let n = write(fd, buf.baseAddress! + written, buf.count - written)
                guard n > 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                written += n
            }
        }
    }

    private static func writeAll(_ fd: Int32, buf: UnsafeMutableRawPointer, count: Int) throws {
        var written = 0
        while written < count {
            let n = write(fd, buf + written, count - written)
            guard n > 0 else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            written += n
        }
    }

    /// Write zero-padding to align to 512-byte boundary.
    private static func writePadding(_ fd: Int32, dataSize: Int64) throws {
        let remainder = Int(dataSize % 512)
        if remainder > 0 {
            let padding = [UInt8](repeating: 0, count: 512 - remainder)
            try writeAll(fd, data: padding)
        }
    }
}
