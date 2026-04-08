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

@testable import ContainerAPIClient

struct ClientImageMacOSPrewarmTests {
    @Test
    func prewarmMacOSChunkedDisksBuildsDarwinCacheWhenPlatformIsNil() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manifestDigest = "sha256:manifest-\(UUID().uuidString)"
        let cachePath = MacOSDiskRebuilder.rebuildCachePath(
            cacheDir: MacOSGuestCache.rebuildCacheDirectory(),
            manifestDigest: manifestDigest
        )
        defer { try? FileManager.default.removeItem(at: cachePath.deletingLastPathComponent()) }

        let darwinPlatform = try Platform(from: "darwin/arm64")
        let linuxPlatform = try Platform(from: "linux/amd64")

        let chunkDigest = "sha256:chunk-\(UUID().uuidString)"
        let layoutDigest = "sha256:layout-\(UUID().uuidString)"
        let indexDigest = "sha256:index-\(UUID().uuidString)"

        let chunkLength: Int64 = 12
        let expectedDiskBytes = Data([0, 97, 98, 99, 0, 0, 0, 0, 89, 90, 0, 0])
        let extents = [
            (offset: Int64(1), length: Int64(3), data: Data("abc".utf8)),
            (offset: Int64(8), length: Int64(2), data: Data("YZ".utf8)),
        ]

        let chunkURL = tempDirectory.appendingPathComponent("chunk.tar.zst")
        try Self.writeCompressedSparseChunk(
            at: chunkURL,
            chunkLength: chunkLength,
            extents: extents
        )
        let chunkSize = Int64(try Data(contentsOf: chunkURL).count)

        let layout = DiskLayout(
            logicalSize: chunkLength,
            chunkSize: chunkLength,
            chunks: [
                .init(
                    index: 0,
                    offset: 0,
                    length: chunkLength,
                    layerDigest: chunkDigest,
                    layerSize: chunkSize,
                    rawDigest: "sha256:raw-\(UUID().uuidString)",
                    rawLength: chunkLength
                )
            ]
        )

        let darwinManifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: "sha256:darwin-config-\(UUID().uuidString)",
                size: 2
            ),
            layers: [
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.hardwareModel,
                    digest: "sha256:hardware-\(UUID().uuidString)",
                    size: 1
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.auxiliaryStorage,
                    digest: "sha256:aux-\(UUID().uuidString)",
                    size: 1
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.diskLayout,
                    digest: layoutDigest,
                    size: 1
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.diskChunk,
                    digest: chunkDigest,
                    size: chunkSize,
                    annotations: ["org.apple.container.macos.chunk.index": "0"]
                ),
            ]
        )
        let linuxManifestDigest = "sha256:linux-manifest-\(UUID().uuidString)"
        let linuxManifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: "sha256:linux-config-\(UUID().uuidString)",
                size: 2
            ),
            layers: []
        )
        let index = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: 1,
                    platform: darwinPlatform
                ),
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: linuxManifestDigest,
                    size: 1,
                    platform: linuxPlatform
                ),
            ]
        )

        let store = MockContentStore(
            entries: [
                indexDigest: try Self.writeJSON(index, named: "index.json", in: tempDirectory),
                manifestDigest: try Self.writeJSON(darwinManifest, named: "darwin-manifest.json", in: tempDirectory),
                linuxManifestDigest: try Self.writeJSON(linuxManifest, named: "linux-manifest.json", in: tempDirectory),
                layoutDigest: try Self.writeJSON(layout, named: "layout.json", in: tempDirectory),
                chunkDigest: chunkURL,
            ]
        )

        let image = ClientImage(
            description: ImageDescription(
                reference: "registry.local/macos-base:latest",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: indexDigest,
                    size: 1
                )
            ),
            contentStore: store
        )

        try? FileManager.default.removeItem(at: cachePath.deletingLastPathComponent())

        try await image.prewarmMacOSChunkedDisks(platform: nil)

        #expect(FileManager.default.fileExists(atPath: cachePath.path))
        #expect(try Data(contentsOf: cachePath) == expectedDiskBytes)
    }

    @Test
    func exportMacOSImageDirectoryRebuildsChunkedSandboxImage() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manifestDigest = "sha256:manifest-\(UUID().uuidString)"
        let cachePath = MacOSDiskRebuilder.rebuildCachePath(
            cacheDir: MacOSGuestCache.rebuildCacheDirectory(),
            manifestDigest: manifestDigest
        )
        defer { try? FileManager.default.removeItem(at: cachePath.deletingLastPathComponent()) }

        let platform = try Platform(from: "darwin/arm64")
        let chunkDigest = "sha256:chunk-\(UUID().uuidString)"
        let layoutDigest = "sha256:layout-\(UUID().uuidString)"
        let indexDigest = "sha256:index-\(UUID().uuidString)"
        let hardwareDigest = "sha256:hardware-\(UUID().uuidString)"
        let auxiliaryDigest = "sha256:aux-\(UUID().uuidString)"

        let hardwareData = Data("hardware".utf8)
        let auxiliaryData = Data("aux".utf8)
        let expectedDiskBytes = Data([0, 97, 98, 99, 0, 0, 0, 0, 89, 90, 0, 0])
        let chunkLength: Int64 = Int64(expectedDiskBytes.count)

        let chunkURL = tempDirectory.appendingPathComponent("chunk.tar.zst")
        try Self.writeCompressedSparseChunk(
            at: chunkURL,
            chunkLength: chunkLength,
            extents: [
                (offset: Int64(1), length: Int64(3), data: Data("abc".utf8)),
                (offset: Int64(8), length: Int64(2), data: Data("YZ".utf8)),
            ]
        )
        let chunkSize = Int64(try Data(contentsOf: chunkURL).count)

        let layout = DiskLayout(
            logicalSize: chunkLength,
            chunkSize: chunkLength,
            chunks: [
                .init(
                    index: 0,
                    offset: 0,
                    length: chunkLength,
                    layerDigest: chunkDigest,
                    layerSize: chunkSize,
                    rawDigest: "sha256:raw-\(UUID().uuidString)",
                    rawLength: chunkLength
                )
            ]
        )
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: "sha256:config-\(UUID().uuidString)",
                size: 2
            ),
            layers: [
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.hardwareModel,
                    digest: hardwareDigest,
                    size: Int64(hardwareData.count)
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.auxiliaryStorage,
                    digest: auxiliaryDigest,
                    size: Int64(auxiliaryData.count)
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.diskLayout,
                    digest: layoutDigest,
                    size: 1
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.diskChunk,
                    digest: chunkDigest,
                    size: chunkSize,
                    annotations: [
                        "org.apple.container.macos.chunk.index": "0",
                        MacOSImageContract.roleAnnotation: MacOSImageRole.sandbox.rawValue,
                    ]
                ),
            ],
            annotations: MacOSImageContract.annotations(for: .sandbox)
        )
        let index = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: 1,
                    annotations: MacOSImageContract.annotations(for: .sandbox),
                    platform: platform
                )
            ]
        )

        let hardwareURL = tempDirectory.appendingPathComponent("HardwareModel.bin")
        let auxiliaryURL = tempDirectory.appendingPathComponent("AuxiliaryStorage")
        try hardwareData.write(to: hardwareURL)
        try auxiliaryData.write(to: auxiliaryURL)

        let store = MockContentStore(
            entries: [
                indexDigest: try Self.writeJSON(index, named: "index.json", in: tempDirectory),
                manifestDigest: try Self.writeJSON(manifest, named: "manifest.json", in: tempDirectory),
                layoutDigest: try Self.writeJSON(layout, named: "layout.json", in: tempDirectory),
                chunkDigest: chunkURL,
                hardwareDigest: hardwareURL,
                auxiliaryDigest: auxiliaryURL,
            ]
        )
        let image = ClientImage(
            description: ImageDescription(
                reference: "registry.local/macos-base:chunked",
                descriptor: Descriptor(mediaType: MediaTypes.index, digest: indexDigest, size: 1)
            ),
            contentStore: store
        )

        let outputDirectory = tempDirectory.appendingPathComponent("exported")
        try await image.exportMacOSImageDirectory(to: outputDirectory)

        let exportedLayout = MacOSSandboxLayout(root: outputDirectory)
        #expect(try Data(contentsOf: exportedLayout.diskImageURL) == expectedDiskBytes)
        #expect(try Data(contentsOf: exportedLayout.auxiliaryStorageURL) == auxiliaryData)
        #expect(try Data(contentsOf: exportedLayout.hardwareModelURL) == hardwareData)
    }

    @Test
    func exportMacOSImageDirectoryCopiesLegacySandboxImage() async throws {
        let tempDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let platform = try Platform(from: "darwin/arm64")
        let indexDigest = "sha256:index-\(UUID().uuidString)"
        let manifestDigest = "sha256:manifest-\(UUID().uuidString)"
        let hardwareDigest = "sha256:hardware-\(UUID().uuidString)"
        let auxiliaryDigest = "sha256:aux-\(UUID().uuidString)"
        let diskDigest = "sha256:disk-\(UUID().uuidString)"

        let hardwareData = Data("legacy-hardware".utf8)
        let auxiliaryData = Data("legacy-aux".utf8)
        let diskData = Data("legacy-disk".utf8)

        let hardwareURL = tempDirectory.appendingPathComponent("HardwareModel.bin")
        let auxiliaryURL = tempDirectory.appendingPathComponent("AuxiliaryStorage")
        let diskURL = tempDirectory.appendingPathComponent("Disk.img")
        try hardwareData.write(to: hardwareURL)
        try auxiliaryData.write(to: auxiliaryURL)
        try diskData.write(to: diskURL)

        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: "sha256:config-\(UUID().uuidString)",
                size: 2
            ),
            layers: [
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.hardwareModel,
                    digest: hardwareDigest,
                    size: Int64(hardwareData.count)
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.auxiliaryStorage,
                    digest: auxiliaryDigest,
                    size: Int64(auxiliaryData.count)
                ),
                Descriptor(
                    mediaType: MacOSImageOCIMediaTypes.diskImage,
                    digest: diskDigest,
                    size: Int64(diskData.count)
                ),
            ]
        )
        let index = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: 1,
                    platform: platform
                )
            ]
        )

        let store = MockContentStore(
            entries: [
                indexDigest: try Self.writeJSON(index, named: "index.json", in: tempDirectory),
                manifestDigest: try Self.writeJSON(manifest, named: "manifest.json", in: tempDirectory),
                hardwareDigest: hardwareURL,
                auxiliaryDigest: auxiliaryURL,
                diskDigest: diskURL,
            ]
        )
        let image = ClientImage(
            description: ImageDescription(
                reference: "registry.local/macos-base:legacy",
                descriptor: Descriptor(mediaType: MediaTypes.index, digest: indexDigest, size: 1)
            ),
            contentStore: store
        )

        let outputDirectory = tempDirectory.appendingPathComponent("exported")
        try await image.exportMacOSImageDirectory(to: outputDirectory)

        let exportedLayout = MacOSSandboxLayout(root: outputDirectory)
        #expect(try Data(contentsOf: exportedLayout.diskImageURL) == diskData)
        #expect(try Data(contentsOf: exportedLayout.auxiliaryStorageURL) == auxiliaryData)
        #expect(try Data(contentsOf: exportedLayout.hardwareModelURL) == hardwareData)
    }
}

extension ClientImageMacOSPrewarmTests {
    private struct MockContentStore: ContentStore {
        let entries: [String: URL]

        func get(digest: String) async throws -> Content? {
            guard let path = entries[digest] else {
                return nil
            }
            return try LocalContent(path: path)
        }

        func get<T: Decodable>(digest: String) async throws -> T? {
            guard let content = try await self.get(digest: digest) else {
                return nil
            }
            return try content.decode()
        }

        @discardableResult
        func delete(digests: [String]) async throws -> ([String], UInt64) {
            throw Unimplemented()
        }

        @discardableResult
        func delete(keeping: [String]) async throws -> ([String], UInt64) {
            throw Unimplemented()
        }

        @discardableResult
        func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String] {
            throw Unimplemented()
        }

        func newIngestSession() async throws -> (id: String, ingestDir: URL) {
            throw Unimplemented()
        }

        @discardableResult
        func completeIngestSession(_ id: String) async throws -> [String] {
            throw Unimplemented()
        }

        func cancelIngestSession(_ id: String) async throws {
            throw Unimplemented()
        }
    }

    private struct Unimplemented: Error {}

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("client-image-prewarm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeJSON<T: Encodable>(_ value: T, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url)
        return url
    }

    private static func writeCompressedSparseChunk(
        at outputURL: URL,
        chunkLength: Int64,
        extents: [(offset: Int64, length: Int64, data: Data)]
    ) throws {
        let tarURL = outputURL.deletingPathExtension()
        let tarData = try makeSparseChunkTar(chunkLength: chunkLength, extents: extents)
        try tarData.write(to: tarURL)
        try ZstdCodec.compress(input: tarURL, output: outputURL, level: 3, includeChecksum: false)
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
        fatalError("unable to build pax record")
    }

    private static func buildUstarHeader(name: String, size: Int64, typeflag: Character) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 512)
        writeField(name, into: &header, offset: 0, length: 100)
        writeOctalField(0o644, into: &header, offset: 100, length: 8)
        writeOctalField(0, into: &header, offset: 108, length: 8)
        writeOctalField(0, into: &header, offset: 116, length: 8)
        writeOctalField(size, into: &header, offset: 124, length: 12)
        writeOctalField(0, into: &header, offset: 136, length: 12)
        for index in 148..<156 {
            header[index] = 0x20
        }
        header[156] = UInt8(typeflag.asciiValue ?? 0)
        writeField("ustar", into: &header, offset: 257, length: 6)
        writeField("00", into: &header, offset: 263, length: 2)

        let checksum = header.reduce(0) { $0 + Int($1) }
        writeChecksumField(checksum, into: &header, offset: 148, length: 8)
        return header
    }

    private static func writeField(_ value: String, into header: inout [UInt8], offset: Int, length: Int) {
        let bytes = Array(value.utf8.prefix(length))
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
    }

    private static func writeOctalField(_ value: Int64, into header: inout [UInt8], offset: Int, length: Int) {
        let digits = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(length - digits.count - 1, 0)) + digits
        writeField(padded, into: &header, offset: offset, length: length - 1)
    }

    private static func writeChecksumField(_ value: Int, into header: inout [UInt8], offset: Int, length: Int) {
        let digits = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(length - digits.count - 2, 0)) + digits
        writeField(padded, into: &header, offset: offset, length: length - 2)
        header[offset + length - 2] = 0
        header[offset + length - 1] = 0x20
    }

    private static func appendPadding(to tarData: inout Data, size: Int64) {
        let remainder = Int(size % 512)
        guard remainder != 0 else {
            return
        }
        tarData.append(Data(repeating: 0, count: 512 - remainder))
    }
}
