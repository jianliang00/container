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

import Containerization
import Foundation
import Testing

@testable import ContainerAPIClient
@testable import ContainerCRI
@testable import ContainerCRIShimMacOS
@testable import ContainerResource
@testable import ContainerizationOCI

struct CRIShimImageServiceTests {
    @Test
    func mapsUsernamePasswordAuthConfigToBasicAuthentication() throws {
        var auth = Runtime_V1_AuthConfig()
        auth.username = "user"
        auth.password = "password"

        #expect(try CRIShimImagePullAuthentication.resolve(auth) == .basic(username: "user", password: "password"))
    }

    @Test
    func mapsDockerAuthFieldToBasicAuthentication() throws {
        var auth = Runtime_V1_AuthConfig()
        auth.auth = Data("docker-user:docker-password".utf8).base64EncodedString()

        #expect(try CRIShimImagePullAuthentication.resolve(auth) == .basic(username: "docker-user", password: "docker-password"))
    }

    @Test
    func mapsRegistryTokensToBearerAuthentication() throws {
        var registryTokenAuth = Runtime_V1_AuthConfig()
        registryTokenAuth.registryToken = "registry-token"
        #expect(try CRIShimImagePullAuthentication.resolve(registryTokenAuth) == .bearer(token: "registry-token"))

        var identityTokenAuth = Runtime_V1_AuthConfig()
        identityTokenAuth.identityToken = "identity-token"
        #expect(try CRIShimImagePullAuthentication.resolve(identityTokenAuth) == .bearer(token: "identity-token"))
    }

    @Test
    func rejectsMalformedAuthField() {
        var invalidBase64 = Runtime_V1_AuthConfig()
        invalidBase64.auth = "not base64"
        #expect {
            _ = try CRIShimImagePullAuthentication.resolve(invalidBase64)
        } throws: { error in
            error as? CRIShimError == .invalidArgument("image auth field is not valid base64")
        }

        var missingSeparator = Runtime_V1_AuthConfig()
        missingSeparator.auth = Data("missing-separator".utf8).base64EncodedString()
        #expect {
            _ = try CRIShimImagePullAuthentication.resolve(missingSeparator)
        } throws: { error in
            error as? CRIShimError == .invalidArgument("image auth field must decode to username:password")
        }
    }

    @Test
    func validatesMacOSImageRolesAndLegacySandboxImages() throws {
        let sandboxImage = CRIShimImageRecord(
            reference: "localhost/macos-sandbox:latest",
            digest: "sha256:sandbox",
            size: 1024,
            annotations: MacOSImageContract.annotations(for: .sandbox)
        )
        try validateCRIShimImage(
            sandboxImage,
            expectedRole: .sandbox,
            requestedReference: sandboxImage.reference
        )

        let workloadImage = CRIShimImageRecord(
            reference: "localhost/macos-workload:latest",
            digest: "sha256:workload",
            size: 2048,
            annotations: MacOSImageContract.annotations(for: .workload)
        )
        try validateCRIShimImage(
            workloadImage,
            expectedRole: .workload,
            requestedReference: workloadImage.reference
        )

        #expect {
            try validateCRIShimImage(
                sandboxImage,
                expectedRole: .workload,
                requestedReference: sandboxImage.reference
            )
        } throws: { error in
            guard case .invalidArgument(let message) = error as? CRIShimError else {
                return false
            }
            return message.contains("expected a macOS workload image")
        }

        let unannotated = CRIShimImageRecord(
            reference: "localhost/unannotated:latest",
            digest: "sha256:unannotated",
            size: 1024
        )
        try validateCRIShimImage(
            unannotated,
            expectedRole: .sandbox,
            requestedReference: unannotated.reference
        )

        #expect {
            try validateCRIShimImage(
                unannotated,
                expectedRole: .workload,
                requestedReference: unannotated.reference
            )
        } throws: { error in
            guard case .invalidArgument(let message) = error as? CRIShimError else {
                return false
            }
            return message.contains("missing macOS image role annotation")
        }
    }

    @Test
    func imageRecordUsesResolvedDetailAnnotations() throws {
        let image = ClientImage(
            description: ImageDescription(
                reference: "localhost/macos-sandbox:latest",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: "sha256:sandbox-index",
                    size: 1234,
                    annotations: MacOSImageContract.annotations(for: .sandbox)
                )
            )
        )

        let record = CRIShimImageRecord(image: image)

        #expect(record.reference == image.reference)
        #expect(record.digest == image.digest)
        #expect(record.size == 1234)
        #expect(record.annotations == MacOSImageContract.annotations(for: .sandbox))
        try validateCRIShimImage(
            record,
            expectedRole: .sandbox,
            requestedReference: record.reference
        )
    }

    @Test
    func imageRecordResolvesWorkloadAnnotationsFromDarwinManifest() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cri-shim-image-record-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let platform = Platform(arch: "arm64", os: "darwin")
        let indexDigest = "sha256:index-\(UUID().uuidString)"
        let manifestDigest = "sha256:manifest-\(UUID().uuidString)"
        let workloadAnnotations = MacOSImageContract.annotations(for: .workload)
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: "sha256:config-\(UUID().uuidString)",
                size: 1
            ),
            layers: [],
            annotations: workloadAnnotations
        )
        let index = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: 1,
                    annotations: workloadAnnotations,
                    platform: platform
                )
            ]
        )
        let store = MockContentStore(
            entries: [
                indexDigest: try Self.writeJSON(index, named: "index.json", in: tempDirectory),
                manifestDigest: try Self.writeJSON(manifest, named: "manifest.json", in: tempDirectory),
            ]
        )
        let image = ClientImage(
            description: ImageDescription(
                reference: "localhost/macos-workload:nested-annotations",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: indexDigest,
                    size: 1234,
                    annotations: ["org.opencontainers.image.ref.name": "macos-workload:nested-annotations"]
                )
            ),
            contentStore: store
        )

        let record = try await CRIShimImageRecord.resolve(image: image)

        #expect(record.annotations[MacOSImageContract.roleAnnotation] == MacOSImageRole.workload.rawValue)
        #expect(
            record.annotations[MacOSImageContract.workloadFormatAnnotation]
                == MacOSWorkloadImageFormat.v1.rawValue
        )
        try validateCRIShimImage(
            record,
            expectedRole: .workload,
            requestedReference: record.reference
        )
    }

    private static func writeJSON<T: Encodable>(
        _ value: T,
        named name: String,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: url)
        return url
    }

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

        func totalAllocatedSize() async throws -> UInt64 {
            throw Unimplemented()
        }
    }

    private struct Unimplemented: Error {}
}
