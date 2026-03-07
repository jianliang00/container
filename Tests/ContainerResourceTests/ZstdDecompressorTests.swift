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
import Testing
import libzstd

@testable import ContainerResource

struct ZstdDecompressorTests {
    @Test
    func decompressesFrameWithoutExternalBinary() throws {
        let tempDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let payload = Data("builtin zstd decoder".utf8)
        let compressed = try Self.compressZstd(payload)
        let compressedURL = tempDirectory.appendingPathComponent("payload.zst")
        let outputURL = tempDirectory.appendingPathComponent("payload")
        try compressed.write(to: compressedURL)

        setenv(ZstdTool.overrideEnvironmentKey, "/missing/zstd", 1)
        defer { unsetenv(ZstdTool.overrideEnvironmentKey) }

        try ZstdDecompressor.decompress(input: compressedURL, output: outputURL)

        #expect(try Data(contentsOf: outputURL) == payload)
    }

    @Test
    func rebuildsDiskChunkWithoutExternalBinary() throws {
        let tempDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let extents = [
            (offset: Int64(1), length: Int64(3), data: Data("abc".utf8)),
            (offset: Int64(8), length: Int64(2), data: Data("YZ".utf8)),
        ]
        let chunkLength: Int64 = 12
        let tarData = try Self.makeSparseChunkTar(chunkLength: chunkLength, extents: extents)
        let compressedData = try Self.compressZstd(tarData)
        let blobDigest = "sha256:test-chunk"
        let blobURL = tempDirectory.appendingPathComponent("chunk.tar.zst")
        let outputURL = tempDirectory.appendingPathComponent("Disk.img")
        try compressedData.write(to: blobURL)

        let layout = DiskLayout(
            logicalSize: chunkLength,
            chunkSize: chunkLength,
            chunks: [
                .init(
                    index: 0,
                    offset: 0,
                    length: chunkLength,
                    layerDigest: blobDigest,
                    layerSize: Int64(compressedData.count),
                    rawDigest: "sha256:unused",
                    rawLength: chunkLength
                )
            ]
        )

        setenv(ZstdTool.overrideEnvironmentKey, "/missing/zstd", 1)
        defer { unsetenv(ZstdTool.overrideEnvironmentKey) }
        let originalPath = getenv("PATH").map { String(cString: $0) }
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
            }
        }
        setenv("PATH", "", 1)

        try MacOSDiskRebuilder.rebuild(
            layout: layout,
            chunkBlobPaths: [blobDigest: blobURL],
            outputPath: outputURL
        )

        let rebuilt = try Data(contentsOf: outputURL)
        #expect(rebuilt.count == Int(chunkLength))
        #expect(Array(rebuilt) == [0, 97, 98, 99, 0, 0, 0, 0, 89, 90, 0, 0])
    }

    private static func compressZstd(_ data: Data, level: Int32 = 3) throws -> Data {
        guard let context = ZSTD_createCCtx() else {
            throw CompressionError(message: "failed to create zstd compression context")
        }
        defer { ZSTD_freeCCtx(context) }

        let bound = ZSTD_compressBound(data.count)
        var output = [UInt8](repeating: 0, count: bound)
        let compressedSize = try data.withUnsafeBytes { bytes -> Int in
            try output.withUnsafeMutableBytes { outputBytes -> Int in
                let result = ZSTD_compressCCtx(
                    context,
                    outputBytes.baseAddress,
                    outputBytes.count,
                    bytes.baseAddress,
                    bytes.count,
                    level
                )
                guard ZSTD_isError(result) == 0 else {
                    throw CompressionError(message: String(cString: ZSTD_getErrorName(result)))
                }
                return result
            }
        }

        return Data(output.prefix(compressedSize))
    }

    private static func makeSparseChunkTar(
        chunkLength: Int64,
        extents: [(offset: Int64, length: Int64, data: Data)]
    ) throws -> Data {
        let actualDataSize = extents.reduce(Int64(0)) { $0 + $1.length }
        let paxRecords = [
            paxRecord(
                key: "GNU.sparse.map",
                value: extents.map { "\($0.offset),\($0.length)" }.joined(separator: ",")
            ),
            paxRecord(key: "GNU.sparse.name", value: "disk.chunk"),
            paxRecord(key: "GNU.sparse.realsize", value: "\(chunkLength)"),
        ]
        let paxData = Data(paxRecords.joined().utf8)

        var tarData = Data()
        tarData.append(Data(buildUstarHeader(name: "PaxHeader/disk.chunk", size: Int64(paxData.count), typeflag: "x")))
        tarData.append(paxData)
        appendPadding(to: &tarData, size: Int64(paxData.count))
        tarData.append(Data(buildUstarHeader(name: "GNUSparseFile.0/disk.chunk", size: actualDataSize, typeflag: "0")))
        for extent in extents {
            #expect(extent.data.count == Int(extent.length))
            tarData.append(extent.data)
        }
        appendPadding(to: &tarData, size: actualDataSize)
        tarData.append(Data(repeating: 0, count: 1024))
        return tarData
    }

    private static func paxRecord(key: String, value: String) -> String {
        let body = " \(key)=\(value)\n"
        for digits in 1...20 {
            let length = digits + body.utf8.count
            let prefix = "\(length)"
            if prefix.count == digits {
                return "\(prefix)\(body)"
            }
        }
        fatalError("unreachable")
    }

    private static func buildUstarHeader(name: String, size: Int64, typeflag: Character) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 512)
        writeString(&header, offset: 0, value: name, maxLength: 100)
        writeOctal(&header, offset: 100, value: 0o644, width: 8)
        writeOctal(&header, offset: 108, value: 0, width: 8)
        writeOctal(&header, offset: 116, value: 0, width: 8)
        writeOctal(&header, offset: 124, value: UInt64(size), width: 12)
        writeOctal(&header, offset: 136, value: 0, width: 12)
        header[156] = UInt8(typeflag.asciiValue!)
        writeString(&header, offset: 257, value: "ustar", maxLength: 6)
        header[263] = UInt8(Character("0").asciiValue!)
        header[264] = UInt8(Character("0").asciiValue!)
        for index in 148..<156 {
            header[index] = 0x20
        }
        let checksum = header.reduce(0) { $0 + UInt32($1) }
        writeOctal(&header, offset: 148, value: UInt64(checksum), width: 7)
        header[155] = 0x20
        return header
    }

    private static func writeString(_ header: inout [UInt8], offset: Int, value: String, maxLength: Int) {
        let bytes = [UInt8](value.utf8)
        let count = min(bytes.count, maxLength - 1)
        for index in 0..<count {
            header[offset + index] = bytes[index]
        }
    }

    private static func writeOctal(_ header: inout [UInt8], offset: Int, value: UInt64, width: Int) {
        let octal = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, width - 1 - octal.count)) + octal
        let bytes = [UInt8](padded.utf8)
        let count = min(bytes.count, width - 1)
        for index in 0..<count {
            header[offset + index] = bytes[index]
        }
        header[offset + count] = 0
    }

    private static func appendPadding(to data: inout Data, size: Int64) {
        let remainder = Int(size % 512)
        if remainder > 0 {
            data.append(Data(repeating: 0, count: 512 - remainder))
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zstd-decompressor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private struct CompressionError: Error, CustomStringConvertible {
        let message: String

        var description: String {
            message
        }
    }
}
