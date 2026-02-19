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

enum MacOSTemplatePackager {
    static let diskImageFilename = "Disk.img"
    static let auxiliaryStorageFilename = "AuxiliaryStorage"
    static let hardwareModelFilename = "HardwareModel.bin"

    struct TemplatePaths {
        let root: URL
        let diskImage: URL
        let auxiliaryStorage: URL
        let hardwareModel: URL
    }

    static func validateTemplateDirectory(_ path: URL) throws -> TemplatePaths {
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
        templateDirectory: URL,
        outputTar: URL,
        reference: String?
    ) throws {
        let template = try validateTemplateDirectory(templateDirectory)
        let layoutDir = try createLayoutDirectory(from: template, reference: reference)
        defer {
            try? FileManager.default.removeItem(at: layoutDir)
        }
        try createTar(fromLayout: layoutDir, outputTar: outputTar)
    }

    private static func createLayoutDirectory(from template: TemplatePaths, reference: String?) throws -> URL {
        let fm = FileManager.default
        let layoutDir = fm.temporaryDirectory.appendingPathComponent("macos-oci-layout-\(UUID().uuidString)")
        let blobsDir = layoutDir.appendingPathComponent("blobs/sha256")
        try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let configData = try JSONEncoder().encode(
            OCIConfig(
                architecture: "arm64",
                os: "darwin",
                rootfs: .init(type: "layers", diffIDs: []),
                created: ISO8601DateFormatter().string(from: Date())
            )
        )
        let config = try writeJSONBlob(configData, blobsDir: blobsDir, mediaType: "application/vnd.oci.image.config.v1+json")

        let hardware = try addFileBlob(
            source: template.hardwareModel,
            blobsDir: blobsDir,
            mediaType: MacOSTemplateOCIMediaTypes.hardwareModel
        )
        let auxiliary = try addFileBlob(
            source: template.auxiliaryStorage,
            blobsDir: blobsDir,
            mediaType: MacOSTemplateOCIMediaTypes.auxiliaryStorage
        )
        let disk = try addFileBlob(
            source: template.diskImage,
            blobsDir: blobsDir,
            mediaType: MacOSTemplateOCIMediaTypes.diskImage
        )

        let manifestValue = OCIManifest(
            schemaVersion: 2,
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            config: config,
            layers: [hardware, auxiliary, disk]
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", outputTar.path, "-C", layoutDir.path, "."]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown tar error"
            throw NSError(domain: "container.macos.package", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
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
