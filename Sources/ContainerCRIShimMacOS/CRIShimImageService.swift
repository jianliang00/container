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

import ContainerCRI
import ContainerKit
import Foundation

public struct CRIShimImageRecord: Equatable, Sendable {
    public var reference: String
    public var digest: String
    public var size: UInt64
    public var annotations: [String: String]
    public var pinned: Bool

    public init(
        reference: String,
        digest: String,
        size: UInt64,
        annotations: [String: String] = [:],
        pinned: Bool = false
    ) {
        self.reference = reference
        self.digest = digest
        self.size = size
        self.annotations = annotations
        self.pinned = pinned
    }
}

public struct CRIShimImageFilesystemUsage: Equatable, Sendable {
    public var mountpoint: String
    public var usedBytes: UInt64
    public var inodesUsed: UInt64?
    public var timestampNanoseconds: Int64

    public init(
        mountpoint: String,
        usedBytes: UInt64,
        inodesUsed: UInt64? = nil,
        timestampNanoseconds: Int64
    ) {
        self.mountpoint = mountpoint
        self.usedBytes = usedBytes
        self.inodesUsed = inodesUsed
        self.timestampNanoseconds = timestampNanoseconds
    }
}

public protocol CRIShimImageManaging: Sendable {
    func listImages() async throws -> [CRIShimImageRecord]
    func removeImage(reference: String) async throws
    func imageFilesystemUsage() async throws -> CRIShimImageFilesystemUsage
}

public struct ContainerKitCRIShimImageManager: CRIShimImageManaging {
    public var kit: ContainerKit

    public init(kit: ContainerKit = ContainerKit()) {
        self.kit = kit
    }

    public func listImages() async throws -> [CRIShimImageRecord] {
        try await kit.listImages().map(CRIShimImageRecord.init)
    }

    public func removeImage(reference: String) async throws {
        try await kit.deleteImage(reference: reference, garbageCollect: false)
    }

    public func imageFilesystemUsage() async throws -> CRIShimImageFilesystemUsage {
        async let diskUsage = kit.diskUsage()
        async let health = kit.health()
        let (usage, healthSnapshot) = try await (diskUsage, health)
        return CRIShimImageFilesystemUsage(
            mountpoint: healthSnapshot.appRoot.path,
            usedBytes: usage.images.sizeInBytes,
            timestampNanoseconds: currentUnixTimeNanoseconds()
        )
    }
}

extension CRIShimImageRecord {
    init(image: Image) {
        let descriptorSize = image.descriptor.size
        self.init(
            reference: image.reference,
            digest: image.digest,
            size: UInt64(max(0, descriptorSize)),
            annotations: image.descriptor.annotations ?? [:],
            pinned: false
        )
    }

    func matches(reference: String) -> Bool {
        self.reference == reference || digest == reference || repoDigests.contains(reference)
    }

    var repoDigests: [String] {
        guard !reference.contains("@"), !digest.isEmpty else {
            return reference.contains("@") ? [reference] : []
        }

        let tagSeparator = tagSeparator(in: reference)
        let baseReference =
            if let tagSeparator {
                String(reference[..<tagSeparator])
            } else {
                reference
            }
        return ["\(baseReference)@\(digest)"]
    }
}

private func tagSeparator(in reference: String) -> String.Index? {
    guard let colon = reference.lastIndex(of: ":") else {
        return nil
    }
    guard let slash = reference.lastIndex(of: "/") else {
        return colon
    }
    return colon > slash ? colon : nil
}

private func currentUnixTimeNanoseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded())
}

public enum CRIShimImageReference {
    public static func resolve(_ spec: Runtime_V1_ImageSpec) throws -> String {
        let image = spec.image.trimmed
        if !image.isEmpty {
            return image
        }

        let userSpecifiedImage = spec.userSpecifiedImage.trimmed
        if !userSpecifiedImage.isEmpty {
            return userSpecifiedImage
        }

        throw CRIShimError.invalidArgument("image reference is required")
    }
}
