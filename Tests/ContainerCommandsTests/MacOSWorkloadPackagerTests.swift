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

@testable import ContainerCommands

struct MacOSWorkloadPackagerTests {
    @Test
    func packageProducesValidWorkloadImageArchive() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let payloadRoot = tempDirectory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(
            at: payloadRoot.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: payloadRoot.appendingPathComponent("etc"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: payloadRoot.appendingPathComponent("workspace"),
            withIntermediateDirectories: true
        )

        let helloURL = payloadRoot.appendingPathComponent("bin/hello")
        try Data("#!/bin/sh\necho hello \"$1\"\n".utf8).write(to: helloURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: helloURL.path
        )
        try Data("payload-from-packager\n".utf8).write(
            to: payloadRoot.appendingPathComponent("etc/message.txt")
        )

        let imageConfig = ContainerizationOCI.Image(
            created: "2026-03-29T00:00:00Z",
            author: "unit-test",
            architecture: "amd64",
            os: "linux",
            osVersion: "1.0",
            osFeatures: ["feature-a"],
            variant: "v8",
            config: .init(
                user: "nobody",
                env: ["PATH=/usr/bin:/bin", "GREETING=hello"],
                entrypoint: ["/bin/hello"],
                cmd: ["friend"],
                workingDir: "/workspace",
                labels: ["suite": "workload-packager"],
                stopSignal: "15"
            ),
            rootfs: .init(type: "layers", diffIDs: ["sha256:ignored"]),
            history: [.init(created: "2026-03-29T00:00:00Z", createdBy: "unit-test")]
        )

        let outputTar = tempDirectory.appendingPathComponent("workload.tar")
        try MacOSWorkloadPackager.package(
            payloadRoot: payloadRoot,
            outputTar: outputTar,
            reference: "local/workload:latest",
            imageConfig: imageConfig
        )

        let extractRoot = tempDirectory.appendingPathComponent("extracted", isDirectory: true)
        try extractTar(outputTar, to: extractRoot)

        let indexData = try Data(contentsOf: extractRoot.appendingPathComponent("index.json"))
        let index = try JSONDecoder().decode(Index.self, from: indexData)
        let descriptor = try #require(index.manifests.first)
        #expect(descriptor.annotations?[MacOSImageContract.roleAnnotation] == MacOSImageRole.workload.rawValue)
        #expect(
            descriptor.annotations?[MacOSImageContract.workloadFormatAnnotation]
                == MacOSWorkloadImageFormat.v1.rawValue
        )
        #expect(descriptor.annotations?["org.opencontainers.image.ref.name"] == "local/workload:latest")
        #expect(descriptor.platform == .init(arch: "arm64", os: "darwin"))

        let manifestDigest = try #require(blobDigestValue(descriptor.digest))
        let manifestData = try Data(
            contentsOf: extractRoot.appendingPathComponent("blobs/sha256/\(manifestDigest)")
        )
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        #expect(manifest.annotations?[MacOSImageContract.roleAnnotation] == MacOSImageRole.workload.rawValue)
        #expect(
            manifest.annotations?[MacOSImageContract.workloadFormatAnnotation]
                == MacOSWorkloadImageFormat.v1.rawValue
        )
        #expect(manifest.layers.count == 1)

        let configDigest = try #require(blobDigestValue(manifest.config.digest))
        let configData = try Data(
            contentsOf: extractRoot.appendingPathComponent("blobs/sha256/\(configDigest)")
        )
        let config = try JSONDecoder().decode(ContainerizationOCI.Image.self, from: configData)
        #expect(config.created == "2026-03-29T00:00:00Z")
        #expect(config.author == "unit-test")
        #expect(config.architecture == "arm64")
        #expect(config.os == "darwin")
        #expect(config.osVersion == "1.0")
        #expect(config.osFeatures == ["feature-a"])
        #expect(config.variant == "v8")
        #expect(config.config?.user == "nobody")
        #expect(config.config?.env == ["PATH=/usr/bin:/bin", "GREETING=hello"])
        #expect(config.config?.entrypoint == ["/bin/hello"])
        #expect(config.config?.cmd == ["friend"])
        #expect(config.config?.workingDir == "/workspace")
        #expect(config.config?.labels?["suite"] == "workload-packager")
        #expect(config.config?.stopSignal == "15")
        #expect(config.history?.first?.createdBy == "unit-test")
        #expect(config.rootfs.diffIDs == manifest.layers.map(\.digest))

        try MacOSImageContract.validateWorkloadImage(
            descriptorAnnotations: descriptor.annotations,
            manifest: manifest,
            imageConfig: config
        )

        let layerDescriptor = try #require(manifest.layers.first)
        let layerDigest = try #require(blobDigestValue(layerDescriptor.digest))
        let layerTar = extractRoot.appendingPathComponent("blobs/sha256/\(layerDigest)")
        let layerExtractRoot = tempDirectory.appendingPathComponent("layer-root", isDirectory: true)
        try extractTar(layerTar, to: layerExtractRoot)

        let extractedHello = layerExtractRoot.appendingPathComponent("bin/hello")
        let extractedMessage = layerExtractRoot.appendingPathComponent("etc/message.txt")
        #expect(FileManager.default.fileExists(atPath: extractedHello.path))
        #expect(FileManager.default.fileExists(atPath: extractedMessage.path))
        #expect(
            try String(contentsOf: extractedMessage, encoding: .utf8) == "payload-from-packager\n"
        )
        let permissions = try posixPermissions(of: extractedHello)
        #expect(permissions == 0o755)
    }

    @Test
    func packageReportsProgressAcrossLayerAndTarCreation() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let payloadRoot = tempDirectory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: payloadRoot.appendingPathComponent("hello.txt"))

        let outputTar = tempDirectory.appendingPathComponent("workload.tar")
        let recorder = LockedMessages()
        try MacOSWorkloadPackager.package(
            payloadRoot: payloadRoot,
            outputTar: outputTar,
            reference: "local/workload:latest",
            progress: { recorder.append($0) }
        )

        let messages = recorder.values()
        #expect(messages.contains("Packaging macOS workload image"))
        #expect(messages.contains("Creating workload payload layer"))
        #expect(messages.contains("Writing OCI tar metadata"))
        #expect(messages.contains(where: { $0.contains("Appending ") && $0.contains("OCI blob") }))
        #expect(messages.contains("Finished macOS workload image packaging"))
        #expect(FileManager.default.fileExists(atPath: outputTar.path))
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MacOSWorkloadPackagerTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
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
        let errorText = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "unknown tar error"
        throw NSError(
            domain: "container.macos.tests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: errorText]
        )
    }
}

private func blobDigestValue(_ digest: String) -> String? {
    guard digest.hasPrefix("sha256:") else {
        return nil
    }
    return String(digest.dropFirst("sha256:".count))
}

private func posixPermissions(of url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
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
