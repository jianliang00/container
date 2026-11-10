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
import Containerization
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerCommands

@Suite(.serialized)
struct MacOSImagePackagerTests {
    @Test
    func packageCleansUpTemporaryLayoutDirectoryWhenLayoutCreationFails() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let imageDirectory = tempDirectory.appendingPathComponent("image")
        let layoutRoot = tempDirectory.appendingPathComponent("layout-root")
        let seedBlobsDir = tempDirectory.appendingPathComponent("seed-blobs")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layoutRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: seedBlobsDir, withIntermediateDirectories: true)

        let logicalSize: Int64 = 4096
        let diskImage = imageDirectory.appendingPathComponent(MacOSImagePackager.diskImageFilename)
        try createSparseDisk(
            at: diskImage,
            logicalSize: logicalSize,
            writes: [(offset: 0, data: Data("seed".utf8))]
        )
        try Data("aux".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.auxiliaryStorageFilename)
        )
        try Data("hardware".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.hardwareModelFilename)
        )

        let seededChunks = try MacOSDiskChunker.chunkDiskImage(
            diskImage: diskImage,
            blobsDir: seedBlobsDir,
            chunkSize: DiskLayout.defaultChunkSize
        )
        let seededChunk = try #require(seededChunks.first)
        let parentLayout = DiskLayout(
            logicalSize: logicalSize,
            chunks: [
                .init(
                    index: seededChunk.index,
                    offset: seededChunk.chunkOffset,
                    length: seededChunk.chunkLength,
                    layerDigest: seededChunk.blobDigest,
                    layerSize: seededChunk.blobSize,
                    rawDigest: seededChunk.rawDigest,
                    rawLength: seededChunk.rawLength
                )
            ]
        )
        let missingBlobURL = tempDirectory.appendingPathComponent("missing-parent-blob")
        let parentDiskSource = MacOSChunkedDiskSource(
            layout: parentLayout,
            chunkBlobPaths: [seededChunk.blobDigest: missingBlobURL]
        )

        let outputTar = tempDirectory.appendingPathComponent("out.tar")
        #expect(throws: Error.self) {
            try MacOSImagePackager.package(
                imageDirectory: imageDirectory,
                outputTar: outputTar,
                reference: nil,
                parentDiskSource: parentDiskSource,
                temporaryRootDirectory: layoutRoot
            )
        }

        let leftoverLayouts = try FileManager.default.contentsOfDirectory(
            at: layoutRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("macos-oci-layout-") }

        #expect(leftoverLayouts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: outputTar.path))
    }

    @Test
    func packageReportsProgressAcrossChunkingAndTarCreation() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let imageDirectory = tempDirectory.appendingPathComponent("image")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        try createSparseDisk(
            at: imageDirectory.appendingPathComponent(MacOSImagePackager.diskImageFilename),
            logicalSize: 4096,
            writes: [(offset: 0, data: Data("seed".utf8))]
        )
        try Data("aux".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.auxiliaryStorageFilename)
        )
        try Data("hardware".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.hardwareModelFilename)
        )

        let outputTar = tempDirectory.appendingPathComponent("out.tar")
        let recorder = LockedMessages()
        try MacOSImagePackager.package(
            imageDirectory: imageDirectory,
            outputTar: outputTar,
            reference: "local/test:latest",
            progress: { recorder.append($0) }
        )

        let messages = recorder.values()
        #expect(messages.contains("Packaging macOS image bundle"))
        #expect(messages.contains(where: { $0.contains("Chunking macOS disk image") }))
        #expect(messages.contains(where: { $0.contains("Chunked 1/1 disk chunk") }))
        #expect(messages.contains("Writing OCI tar metadata"))
        #expect(messages.contains(where: { $0.contains("Appending ") && $0.contains("OCI blob") }))
        #expect(messages.contains("Finished macOS image packaging"))
        #expect(FileManager.default.fileExists(atPath: outputTar.path))
    }

    @Test
    func packageAnnotatesSandboxRoleOnManifestAndIndexDescriptor() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let imageDirectory = tempDirectory.appendingPathComponent("image")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        try createSparseDisk(
            at: imageDirectory.appendingPathComponent(MacOSImagePackager.diskImageFilename),
            logicalSize: 4096,
            writes: [(offset: 0, data: Data("seed".utf8))]
        )
        try Data("aux".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.auxiliaryStorageFilename)
        )
        try Data("hardware".utf8).write(
            to: imageDirectory.appendingPathComponent(MacOSImagePackager.hardwareModelFilename)
        )

        let outputTar = tempDirectory.appendingPathComponent("out.tar")
        try MacOSImagePackager.package(
            imageDirectory: imageDirectory,
            outputTar: outputTar,
            reference: "local/test:latest"
        )

        let extractRoot = tempDirectory.appendingPathComponent("extracted")
        try extractTar(outputTar, to: extractRoot)

        let indexData = try Data(contentsOf: extractRoot.appendingPathComponent("index.json"))
        let index = try JSONDecoder().decode(Index.self, from: indexData)
        let descriptor = try #require(index.manifests.first)
        #expect(descriptor.annotations?[MacOSImageContract.roleAnnotation] == MacOSImageRole.sandbox.rawValue)
        #expect(descriptor.annotations?[MacOSImageContract.workloadFormatAnnotation] == nil)
        #expect(descriptor.annotations?["org.opencontainers.image.ref.name"] == "local/test:latest")

        let manifestDigest = descriptor.digest.replacingOccurrences(of: "sha256:", with: "")
        let manifestURL = extractRoot.appendingPathComponent("blobs/sha256/\(manifestDigest)")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        #expect(manifest.annotations?[MacOSImageContract.roleAnnotation] == MacOSImageRole.sandbox.rawValue)
        #expect(manifest.annotations?[MacOSImageContract.workloadFormatAnnotation] == nil)
    }

    @Test
    func derivedArchiveReusesParentBlobsAndRetainsThemAfterParentRemoval() async throws {
        let root = try makeTemporaryDirectory()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }

        let input = root.appendingPathComponent("source")
        try fm.createDirectory(at: input, withIntermediateDirectories: false)
        try createSparseDisk(at: input.appendingPathComponent("Disk.img"), logicalSize: 4096, writes: [(0, Data("seed".utf8))])
        try Data("hardware".utf8).write(to: input.appendingPathComponent("HardwareModel.bin"))
        try Data("auxiliary".utf8).write(to: input.appendingPathComponent("AuxiliaryStorage"))
        let baseArchive = root.appendingPathComponent("base.tar")
        let baseRef = "local/test-base:latest"
        try MacOSImagePackager.package(imageDirectory: input, outputTar: baseArchive, reference: baseRef)

        let store = try LocalContentStore(path: root.appendingPathComponent("content"))
        let images = try ImageStore(path: root.appendingPathComponent("images"), contentStore: store)
        let sourceLayout = root.appendingPathComponent("source-layout")
        try extractTar(baseArchive, to: sourceLayout)
        let baseImages = try await images.load(from: sourceLayout)
        let baseImage = try #require(baseImages.first)
        let baseIndex = try await baseImage.index()
        let baseDescriptor = try #require(baseIndex.manifests.first)
        let baseManifest: Manifest = try #require(try await store.get(digest: baseDescriptor.digest))
        let source = try MacOSImageLayers(manifest: baseManifest)

        let sealed = root.appendingPathComponent("sealed")
        try fm.createDirectory(at: sealed, withIntermediateDirectories: false)
        try Data("sealed auxiliary".utf8).write(to: sealed.appendingPathComponent("AuxiliaryStorage"))
        try Data("overlay bytes".utf8).write(to: sealed.appendingPathComponent("active.asif"))
        let archive = root.appendingPathComponent("derived.tar")
        let imageConfig = ContainerizationOCI.Image(architecture: "arm64", os: "darwin", rootfs: .init(type: "layers", diffIDs: []))
        try MacOSImagePackager.packageDerived(
            source: source, logicalSize: 4096, sealed: sealed, parentNames: [],
            imageConfig: imageConfig, reference: "local/test-derived:latest", outputTar: archive, progress: nil)

        let derivedLayout = root.appendingPathComponent("derived-unpacked")
        try extractTar(archive, to: derivedLayout)
        let children = try await images.load(from: derivedLayout)
        let child = try #require(children.first)
        let childIndex = try await child.index()
        let descriptor = try #require(childIndex.manifests.first)
        let manifest: Manifest = try #require(try await store.get(digest: descriptor.digest))
        let layers = try MacOSImageLayers(manifest: manifest)
        guard case .derived(_, _, let chain) = layers,
            case .v1(_, _, let rawLayout, let chunks) = source
        else {
            Issue.record("derived OCI archive lost its RAW ancestry")
            return
        }
        #expect(chain.base.digest == rawLayout.digest)
        #expect(chain.chunks == chunks)
        #expect(chain.overlays.count == 1)
        #expect(!fm.fileExists(atPath: derivedLayout.appendingPathComponent("blobs/sha256/\(rawLayout.digest.dropFirst(7))").path))
        #expect(baseImage.digest != child.digest)
        let nextSealed = root.appendingPathComponent("next-sealed")
        try fm.createDirectory(at: nextSealed, withIntermediateDirectories: false)
        try fm.copyItem(at: sealed.appendingPathComponent("AuxiliaryStorage"), to: nextSealed.appendingPathComponent("AuxiliaryStorage"))
        try fm.copyItem(at: sealed.appendingPathComponent("active.asif"), to: nextSealed.appendingPathComponent("parent-01.asif"))
        try Data("second overlay".utf8).write(to: nextSealed.appendingPathComponent("active.asif"))
        let nextArchive = root.appendingPathComponent("next.tar")
        try MacOSImagePackager.packageDerived(
            source: layers, logicalSize: 4096, sealed: nextSealed, parentNames: ["parent-01.asif"],
            imageConfig: imageConfig, reference: "local/test-descendant:latest", outputTar: nextArchive, progress: nil)
        let nextLayout = root.appendingPathComponent("next-unpacked")
        try extractTar(nextArchive, to: nextLayout)
        let parentDigest = try #require(chain.overlays.first?.digest)
        #expect(!fm.fileExists(atPath: nextLayout.appendingPathComponent("blobs/sha256/\(parentDigest.dropFirst(7))").path))
        _ = try await images.load(from: nextLayout)
        try await images.delete(reference: "local/test-derived:latest", performCleanup: true)

        try await images.delete(reference: baseRef, performCleanup: true)
        for member in [chain.base] + chain.chunks + chain.overlays {
            _ = try await MacOSDiskChain.verifiedContent(member, in: store)
        }
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacOSImagePackagerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func createSparseDisk(
    at url: URL,
    logicalSize: Int64,
    writes: [(offset: Int64, data: Data)]
) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fd = open(url.path, O_RDWR)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }

    guard ftruncate(fd, logicalSize) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    for writeOp in writes {
        try writeOp.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            let written = pwrite(fd, baseAddress, bytes.count, writeOp.offset)
            guard written == bytes.count else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}

private func extractTar(_ tarURL: URL, to destinationURL: URL) throws {
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-xf", tarURL.path, "-C", destinationURL.path]
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let errorText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown tar error"
        throw NSError(domain: "container.macos.tests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
    }
}

private final class LockedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
