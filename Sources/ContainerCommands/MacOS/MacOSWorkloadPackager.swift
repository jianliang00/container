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

import ContainerAPIClient
import ContainerResource
import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation

enum MacOSWorkloadPackager {
    typealias ProgressHandler = @Sendable (String) -> Void

    private static let defaultCreatedAt = "1970-01-01T00:00:00Z"

    static func package(
        payloadRoot: URL,
        outputTar: URL,
        reference: String?,
        imageConfig: ContainerizationOCI.Image? = nil,
        temporaryRootDirectory: URL? = nil,
        progress: ProgressHandler? = nil
    ) throws {
        progress?("Packaging macOS workload image")
        let validatedPayloadRoot = try validatePayloadRoot(payloadRoot)
        let layoutDirectory = try createLayoutDirectory(
            payloadRoot: validatedPayloadRoot,
            reference: reference,
            imageConfig: imageConfig,
            temporaryRootDirectory: temporaryRootDirectory,
            progress: progress
        )
        defer {
            try? FileManager.default.removeItem(at: layoutDirectory)
        }
        try createTar(fromLayout: layoutDirectory, outputTar: outputTar, progress: progress)
        progress?("Finished macOS workload image packaging")
    }

    private static func validatePayloadRoot(_ payloadRoot: URL) throws -> URL {
        let standardized = payloadRoot.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: standardized.path])
        }
        guard isDirectory.boolValue else {
            throw CocoaError(
                .fileReadUnsupportedScheme,
                userInfo: [NSLocalizedDescriptionKey: "workload payload root must be a directory: \(standardized.path)"]
            )
        }
        return standardized
    }

    private static func createLayoutDirectory(
        payloadRoot: URL,
        reference: String?,
        imageConfig: ContainerizationOCI.Image?,
        temporaryRootDirectory: URL?,
        progress: ProgressHandler?
    ) throws -> URL {
        let fileManager = FileManager.default
        let layoutRoot = temporaryRootDirectory ?? fileManager.temporaryDirectory
        let layoutDirectory = layoutRoot.appendingPathComponent("macos-workload-oci-layout-\(UUID().uuidString)")
        let blobsDirectory = layoutDirectory.appendingPathComponent("blobs/sha256", isDirectory: true)
        try fileManager.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

        progress?("Creating workload payload layer")
        let layerArchive = layoutDirectory.appendingPathComponent("layer.tar")
        let writerConfiguration = ArchiveWriterConfiguration(format: .paxRestricted, filter: .none)
        _ = try Archiver.compress(
            source: payloadRoot,
            destination: layerArchive,
            writerConfiguration: writerConfiguration
        ) { url in
            guard let relativePath = relativeChildPath(of: url, under: payloadRoot) else {
                return nil
            }
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relativePath)
            )
        }

        let layerDescriptor = try addFileBlob(
            source: layerArchive,
            blobsDir: blobsDirectory,
            mediaType: MediaTypes.imageLayer
        )

        let configValue = ContainerizationOCI.Image(
            created: imageConfig?.created ?? defaultCreatedAt,
            author: imageConfig?.author,
            architecture: "arm64",
            os: "darwin",
            osVersion: imageConfig?.osVersion,
            osFeatures: imageConfig?.osFeatures,
            variant: imageConfig?.variant,
            config: imageConfig?.config,
            rootfs: .init(type: "layers", diffIDs: [layerDescriptor.digest]),
            history: imageConfig?.history
        )
        let configData = try makeSortedJSONEncoder().encode(configValue)
        let configDescriptor = try writeJSONBlob(
            configData,
            blobsDir: blobsDirectory,
            mediaType: MediaTypes.imageConfig
        )

        let workloadAnnotations = MacOSImageContract.annotations(for: .workload)
        let manifest = MacOSWorkloadOCIManifest(
            schemaVersion: 2,
            mediaType: MediaTypes.imageManifest,
            config: configDescriptor,
            layers: [layerDescriptor],
            annotations: workloadAnnotations
        )
        let manifestData = try makeSortedJSONEncoder().encode(manifest)
        let manifestDescriptor = try writeJSONBlob(
            manifestData,
            blobsDir: blobsDirectory,
            mediaType: MediaTypes.imageManifest
        )

        var descriptorAnnotations = workloadAnnotations
        if let reference {
            descriptorAnnotations["org.opencontainers.image.ref.name"] = reference
        }

        let index = MacOSWorkloadOCIIndex(
            schemaVersion: 2,
            mediaType: MediaTypes.index,
            manifests: [
                .init(
                    mediaType: manifestDescriptor.mediaType,
                    digest: manifestDescriptor.digest,
                    size: manifestDescriptor.size,
                    platform: .init(architecture: "arm64", os: "darwin"),
                    annotations: descriptorAnnotations
                )
            ]
        )

        try Data("{\"imageLayoutVersion\":\"1.0.0\"}\n".utf8).write(
            to: layoutDirectory.appendingPathComponent("oci-layout")
        )
        try makeSortedJSONEncoder().encode(index).write(
            to: layoutDirectory.appendingPathComponent("index.json")
        )

        return layoutDirectory
    }

    private static func createTar(fromLayout layoutDir: URL, outputTar: URL, progress: ProgressHandler?) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputTar.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: outputTar.path) {
            try fileManager.removeItem(at: outputTar)
        }

        progress?("Writing OCI tar metadata")
        try runTar(arguments: ["-cf", outputTar.path, "-C", layoutDir.path, "oci-layout", "index.json"])

        let blobsDirectory = layoutDir.appendingPathComponent("blobs/sha256")
        let blobFiles = try fileManager.contentsOfDirectory(atPath: blobsDirectory.path).sorted()
        progress?("Appending \(blobFiles.count) OCI blob(s) to tar")
        for (index, blobFile) in blobFiles.enumerated() {
            try runTar(arguments: ["-rf", outputTar.path, "-C", layoutDir.path, "blobs/sha256/\(blobFile)"])
            try? fileManager.removeItem(at: blobsDirectory.appendingPathComponent(blobFile))
            if shouldReportProgressStep(completed: index + 1, total: blobFiles.count) {
                progress?("Appended \(index + 1)/\(blobFiles.count) OCI blob(s) to tar")
            }
        }
        progress?("Finished OCI tar export")
    }

    private static func runTar(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorText =
                String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? "unknown tar error"
            throw NSError(
                domain: "container.macos.workload.package",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorText]
            )
        }
    }

    private static func addFileBlob(source: URL, blobsDir: URL, mediaType: String) throws -> MacOSWorkloadOCIDescriptor {
        let (digest, size) = try sha256AndSize(of: source)
        let destination = blobsDir.appendingPathComponent(digest)
        if !FileManager.default.fileExists(atPath: destination.path) {
            _ = try FilesystemClone.cloneOrCopyItem(at: source, to: destination)
        }
        return MacOSWorkloadOCIDescriptor(
            mediaType: mediaType,
            digest: "sha256:\(digest)",
            size: size,
            platform: nil,
            annotations: nil
        )
    }

    private static func writeJSONBlob(_ data: Data, blobsDir: URL, mediaType: String) throws -> MacOSWorkloadOCIDescriptor {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let path = blobsDir.appendingPathComponent(digest)
        if !FileManager.default.fileExists(atPath: path.path) {
            try data.write(to: path)
        }
        return MacOSWorkloadOCIDescriptor(
            mediaType: mediaType,
            digest: "sha256:\(digest)",
            size: Int64(data.count),
            platform: nil,
            annotations: nil
        )
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

    private static func relativeChildPath(of url: URL, under root: URL) -> String? {
        let standardizedURL = url.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        let rootPath = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : standardizedRoot.path + "/"
        guard standardizedURL.path.hasPrefix(rootPath) else {
            return nil
        }
        let relativePath = String(standardizedURL.path.dropFirst(rootPath.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    private static func shouldReportProgressStep(completed: Int, total: Int) -> Bool {
        guard total > 0 else {
            return false
        }
        if total <= 8 {
            return true
        }
        if completed == 1 || completed == total {
            return true
        }
        let interval = max(1, total / 8)
        return completed % interval == 0
    }

    private static func makeSortedJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct MacOSWorkloadOCIPlatform: Codable {
    let architecture: String
    let os: String
}

private struct MacOSWorkloadOCIDescriptor: Codable {
    let mediaType: String
    let digest: String
    let size: Int64
    let platform: MacOSWorkloadOCIPlatform?
    let annotations: [String: String]?
}

private struct MacOSWorkloadOCIManifest: Codable {
    let schemaVersion: Int
    let mediaType: String
    let config: MacOSWorkloadOCIDescriptor
    let layers: [MacOSWorkloadOCIDescriptor]
    let annotations: [String: String]?
}

private struct MacOSWorkloadOCIIndex: Codable {
    let schemaVersion: Int
    let mediaType: String
    let manifests: [MacOSWorkloadOCIDescriptor]
}
