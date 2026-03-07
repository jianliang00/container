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
import Foundation
import Logging

/// Service for calculating disk usage across all resource types
public actor DiskUsageService {
    private let appRoot: URL
    private let containersService: ContainersService
    private let volumesService: VolumesService
    private let log: Logger

    public init(
        appRoot: URL,
        containersService: ContainersService,
        volumesService: VolumesService,
        log: Logger
    ) {
        self.appRoot = appRoot
        self.containersService = containersService
        self.volumesService = volumesService
        self.log = log
    }

    /// Calculate disk usage for all resource types
    public func calculateDiskUsage() async throws -> DiskUsageStats {
        log.debug("calculating disk usage for all resources")

        // Get active image references first (needed for image calculation)
        let activeImageRefs = await containersService.getActiveImageReferences()

        // Query all services concurrently
        async let imageStats = ClientImage.calculateDiskUsage(activeReferences: activeImageRefs)
        async let cacheStats = self.calculateMacOSGuestCacheUsage()
        async let containerStats = containersService.calculateDiskUsage()
        async let volumeStats = volumesService.calculateDiskUsage()

        let (imageData, cacheData, containerData, volumeData) = try await (imageStats, cacheStats, containerStats, volumeStats)

        let stats = DiskUsageStats(
            images: ResourceUsage(
                total: imageData.totalCount,
                active: imageData.activeCount,
                sizeInBytes: imageData.totalSize,
                reclaimable: imageData.reclaimableSize
            ),
            rebuildCache: cacheData.rebuildCache,
            guestDiskCache: cacheData.guestDiskCache,
            containers: ResourceUsage(
                total: containerData.0,
                active: containerData.1,
                sizeInBytes: containerData.2,
                reclaimable: containerData.3
            ),
            volumes: ResourceUsage(
                total: volumeData.0,
                active: volumeData.1,
                sizeInBytes: volumeData.2,
                reclaimable: volumeData.3
            )
        )

        log.debug(
            "disk usage calculation complete",
            metadata: [
                "images_total": "\(imageData.totalCount)",
                "rebuild_cache_total": "\(cacheData.rebuildCache.total)",
                "guest_disk_cache_total": "\(cacheData.guestDiskCache.total)",
                "containers_total": "\(containerData.0)",
                "volumes_total": "\(volumeData.0)",
            ])

        return stats
    }
}

extension DiskUsageService {
    private struct CacheStats: Sendable {
        let rebuildCache: ResourceUsage
        let guestDiskCache: ResourceUsage
    }

    private func calculateMacOSGuestCacheUsage() async throws -> CacheStats {
        let images = try await ClientImage.list()
        let liveDarwinManifestDigests = try await self.liveDarwinManifestDigests(for: images)

        let rebuildUsage = try MacOSGuestCache.rebuildCacheUsage(
            cacheDir: MacOSGuestCache.rebuildCacheDirectory(),
            liveManifestDigests: liveDarwinManifestDigests
        )
        let guestDiskUsage = try MacOSGuestCache.guestDiskCacheUsage(
            cacheDir: MacOSGuestCache.guestDiskCacheDirectory(appRoot: self.appRoot)
        )

        return CacheStats(
            rebuildCache: ResourceUsage(
                total: rebuildUsage.entryCount,
                active: rebuildUsage.liveEntryCount,
                sizeInBytes: rebuildUsage.sizeInBytes,
                reclaimable: rebuildUsage.reclaimableBytes
            ),
            guestDiskCache: ResourceUsage(
                total: guestDiskUsage.entryCount,
                active: guestDiskUsage.liveEntryCount,
                sizeInBytes: guestDiskUsage.sizeInBytes,
                reclaimable: guestDiskUsage.reclaimableBytes
            )
        )
    }

    private func liveDarwinManifestDigests(for images: [ClientImage]) async throws -> Set<String> {
        var digests = Set<String>()

        for image in images {
            let index = try await image.index()
            for descriptor in index.manifests {
                if let refType = descriptor.annotations?["vnd.docker.reference.type"],
                    refType == "attestation-manifest"
                {
                    continue
                }

                guard descriptor.platform?.os == "darwin" else {
                    continue
                }
                digests.insert(descriptor.digest)
            }
        }

        return digests
    }
}
