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

enum MacOSImagePackager {
    static let diskImageFilename = "Disk.img"
    static let auxiliaryStorageFilename = "AuxiliaryStorage"
    static let hardwareModelFilename = "HardwareModel.bin"

    struct ImagePaths {
        let root: URL
        let diskImage: URL
        let auxiliaryStorage: URL
        let hardwareModel: URL
    }

    static func validateImageDirectory(_ path: URL) throws -> ImagePaths {
        let root = path.standardizedFileURL
        let diskImage = root.appendingPathComponent(diskImageFilename)
        let auxiliaryStorage = root.appendingPathComponent(auxiliaryStorageFilename)
        let hardwareModel = root.appendingPathComponent(hardwareModelFilename)

        for required in [diskImage, auxiliaryStorage, hardwareModel] {
            guard FileManager.default.fileExists(atPath: required.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: required.path])
            }
        }
        return .init(root: root, diskImage: diskImage, auxiliaryStorage: auxiliaryStorage, hardwareModel: hardwareModel)
    }

    static func package(
        imageDirectory: URL,
        outputTar: URL,
        reference: String?
    ) throws {
        let image = try validateImageDirectory(imageDirectory)
        let layoutDir = try createLayoutDirectory(from: image, reference: reference)
        defer {
            try? FileManager.default.removeItem(at: layoutDir)
        }
        try createTar(fromLayout: layoutDir, outputTar: outputTar)
    }

    private static func createLayoutDirectory(from image: ImagePaths, reference: String?) throws -> URL {
        let fm = FileManager.default
        let layoutDir = fm.temporaryDirectory.appendingPathComponent("macos-oci-layout-\(UUID().uuidString)")
        let blobsDir = layoutDir.appendingPathComponent("blobs/sha256")
        try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        // Use fixed timestamp for deterministic config digest
        let configData = try JSONEncoder().encode(
            OCIConfig(
                architecture: "arm64",
                os: "darwin",
                rootfs: .init(type: "layers", diffIDs: []),
                created: "1970-01-01T00:00:00Z"
            )
        )
        let config = try writeJSONBlob(configData, blobsDir: blobsDir, mediaType: "application/vnd.oci.image.config.v1+json")

        let hardware = try addFileBlob(
            source: image.hardwareModel,
            blobsDir: blobsDir,
            mediaType: MacOSImageOCIMediaTypes.hardwareModel
        )
        let auxiliary = try addFileBlob(
            source: image.auxiliaryStorage,
            blobsDir: blobsDir,
            mediaType: MacOSImageOCIMediaTypes.auxiliaryStorage
        )

        // v1 chunked disk format
        let logicalSize = try MacOSDiskChunker.logicalFileSize(image.diskImage)
        let chunkResults = try MacOSDiskChunker.chunkDiskImage(
            diskImage: image.diskImage,
            blobsDir: blobsDir
        )

        // Build DiskLayout
        let chunkInfos = chunkResults.map { result in
            DiskLayout.ChunkInfo(
                index: result.index,
                offset: result.chunkOffset,
                length: result.chunkLength,
                layerDigest: result.blobDigest,
                layerSize: result.blobSize,
                rawDigest: result.rawDigest,
                rawLength: result.rawLength
            )
        }
        let diskLayout = DiskLayout(
            logicalSize: logicalSize,
            chunks: chunkInfos
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let diskLayoutData = try encoder.encode(diskLayout)
        let diskLayoutDescriptor = try writeJSONBlob(
            diskLayoutData,
            blobsDir: blobsDir,
            mediaType: MacOSImageOCIMediaTypes.diskLayout
        )

        // Build chunk layer descriptors with annotations
        let chunkDescriptors: [OCIDescriptor] = chunkResults.map { result in
            OCIDescriptor(
                mediaType: MacOSImageOCIMediaTypes.diskChunk,
                digest: result.blobDigest,
                size: result.blobSize,
                platform: nil,
                annotations: [
                    "org.apple.container.macos.chunk.index": "\(result.index)",
                    "org.apple.container.macos.chunk.offset": "\(result.chunkOffset)",
                    "org.apple.container.macos.chunk.length": "\(result.chunkLength)",
                    "org.apple.container.macos.chunk.raw.digest": result.rawDigest,
                    "org.apple.container.macos.chunk.raw.length": "\(result.rawLength)",
                ]
            )
        }

        // Layers order: hardwareModel, auxiliaryStorage, diskLayout, diskChunks[0..N-1]
        var layers: [OCIDescriptor] = [hardware, auxiliary, diskLayoutDescriptor]
        layers.append(contentsOf: chunkDescriptors)

        let manifestValue = OCIManifest(
            schemaVersion: 2,
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            config: config,
            layers: layers
        )
        let manifestData = try JSONEncoder().encode(manifestValue)
        let manifest = try writeJSONBlob(manifestData, blobsDir: blobsDir, mediaType: manifestValue.mediaType)

        let index = OCIIndex(
            schemaVersion: 2,
            mediaType: "application/vnd.oci.image.index.v1+json",
            manifests: [
                .init(
                    mediaType: manifest.mediaType,
                    digest: manifest.digest,
                    size: manifest.size,
                    platform: .init(architecture: "arm64", os: "darwin"),
                    annotations: reference.map { ["org.opencontainers.image.ref.name": $0] }
                )
            ]
        )
        let indexData = try JSONEncoder().encode(index)

        try Data("{\"imageLayoutVersion\":\"1.0.0\"}\n".utf8).write(to: layoutDir.appendingPathComponent("oci-layout"))
        try indexData.write(to: layoutDir.appendingPathComponent("index.json"))

        return layoutDir
    }

    private static func createTar(fromLayout layoutDir: URL, outputTar: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputTar.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputTar.path) {
            try fm.removeItem(at: outputTar)
        }

        // Use tar with --remove-files equivalent: write each blob, then delete it
        // to avoid keeping the full layout directory and tar simultaneously.
        // BSD tar doesn't support --remove-files, so we enumerate files ourselves,
        // add them one at a time using tar -rf (append), and delete after appending.

        // First write the small metadata files (oci-layout, index.json)
        let smallFiles = ["oci-layout", "index.json"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", outputTar.path, "-C", layoutDir.path] + smallFiles
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown tar error"
            throw NSError(domain: "container.macos.package", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
        }

        // Append blob files one by one, deleting each after appending to free space
        let blobsDir = layoutDir.appendingPathComponent("blobs/sha256")
        let blobFiles = try fm.contentsOfDirectory(atPath: blobsDir.path)
        for blob in blobFiles {
            let appendProcess = Process()
            appendProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            appendProcess.arguments = ["-rf", outputTar.path, "-C", layoutDir.path, "blobs/sha256/\(blob)"]
            let appendStderr = Pipe()
            appendProcess.standardError = appendStderr
            try appendProcess.run()
            appendProcess.waitUntilExit()
            guard appendProcess.terminationStatus == 0 else {
                let err = String(data: appendStderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown tar error"
                throw NSError(domain: "container.macos.package", code: Int(appendProcess.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
            }
            // Delete the blob to free disk space immediately
            try? fm.removeItem(at: blobsDir.appendingPathComponent(blob))
        }
    }

    private static func addFileBlob(source: URL, blobsDir: URL, mediaType: String) throws -> OCIDescriptor {
        let (digest, size) = try sha256AndSize(of: source)
        let dst = blobsDir.appendingPathComponent(digest)
        if !FileManager.default.fileExists(atPath: dst.path) {
            _ = try FilesystemClone.cloneOrCopyItem(at: source, to: dst)
        }
        return OCIDescriptor(mediaType: mediaType, digest: "sha256:\(digest)", size: size, platform: nil, annotations: nil)
    }

    private static func writeJSONBlob(_ data: Data, blobsDir: URL, mediaType: String) throws -> OCIDescriptor {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let path = blobsDir.appendingPathComponent(digest)
        if !FileManager.default.fileExists(atPath: path.path) {
            try data.write(to: path)
        }
        return OCIDescriptor(mediaType: mediaType, digest: "sha256:\(digest)", size: Int64(data.count), platform: nil, annotations: nil)
    }

    private static func sha256AndSize(of fileURL: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

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
}

private struct OCIPlatform: Codable {
    let architecture: String
    let os: String
}

private struct OCIDescriptor: Codable {
    let mediaType: String
    let digest: String
    let size: Int64
    let platform: OCIPlatform?
    let annotations: [String: String]?
}

private struct OCIManifest: Codable {
    let schemaVersion: Int
    let mediaType: String
    let config: OCIDescriptor
    let layers: [OCIDescriptor]
}

private struct OCIIndex: Codable {
    let schemaVersion: Int
    let mediaType: String
    let manifests: [OCIDescriptor]
}

private struct OCIConfig: Codable {
    let architecture: String
    let os: String
    let rootfs: RootFS
    let created: String

    struct RootFS: Codable {
        let type: String
        let diffIDs: [String]

        enum CodingKeys: String, CodingKey {
            case type
            case diffIDs = "diff_ids"
        }
    }
}
