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
import Darwin
import Foundation
@preconcurrency import Virtualization

#if canImport(DiskImageKit)
import DiskImageKit
#endif

extension MacOSBlockDeviceBuilder {
    /// The materializer owns content verification and base-cache retention.
    /// Attachment never creates a layer or silently substitutes a RAW disk.
    static func nativeASIFPaths(
        rootURL: URL,
        device: ContainerConfiguration.MacOSGuestOptions.BlockDevice
    ) throws -> (base: URL, parents: [URL], overlay: URL) {
        guard let basePath = device.nativeBasePath, !device.readOnly,
            device.exportName == nil, device.synchronizationMode == .full
        else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF requires a base, writable overlay and full synchronization")
        }
        let parentPaths = device.nativeParentPaths ?? []
        guard device.kind == .nativeASIFChain ? (1...3).contains(parentPaths.count) : device.nativeParentPaths == nil
        else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF chain must have one to three immutable parent overlays")
        }
        let urls = try ([basePath] + parentPaths + [device.path]).map { try managedDiskURL(rootURL: rootURL, relativePath: $0) }
        struct DiskIdentity: Hashable {
            let device: dev_t
            let inode: ino_t
        }
        var identities = Set<DiskIdentity>()
        for (index, url) in urls.enumerated() {
            var value = stat()
            let writable = index == urls.count - 1
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size > 0,
                writable ? value.st_mode & 0o200 != 0 : value.st_mode & 0o222 == 0,
                identities.insert(.init(device: value.st_dev, inode: value.st_ino)).inserted
            else {
                throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF needs distinct regular files with immutable parents and a writable overlay")
            }
        }
        return (urls[0], Array(urls.dropFirst().dropLast()), urls[urls.count - 1])
    }

    static func nativeASIFAttachment(
        rootURL: URL,
        device: ContainerConfiguration.MacOSGuestOptions.BlockDevice
    ) throws -> VZDiskImageStorageDeviceAttachment {
        let paths = try nativeASIFPaths(rootURL: rootURL, device: device)
        #if canImport(DiskImageKit)
        if #available(macOS 27, *) {
            let base = try DiskImage(opening: .open(url: paths.base, mode: .readOnly))
            let overlay = try DiskImage(opening: .open(url: paths.overlay))
            guard base.format == .raw, overlay.format == .asif else {
                throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF requires a RAW base and an ASIF layer")
            }
            var disk = base
            for parent in paths.parents {
                let layer = try DiskImage(opening: .open(url: parent, mode: .readOnly))
                guard layer.format == .asif else {
                    throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF chain requires ASIF parents")
                }
                let stacked = try disk.appending(layer)
                guard stacked.layers.last?.layerType == .overlay, stacked.size == base.size else {
                    throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF parent must be a same-size overlay")
                }
                disk = stacked
            }
            let stack = try disk.appending(overlay)
            // DiskImageKit resolves layer metadata when attaching it to a stack.
            guard stack.layers.count == paths.parents.count + 2, stack.layers.last?.layerType == .overlay,
                paths.parents.isEmpty || stack.size == base.size
            else {
                throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF requires an overlay as the writable layer")
            }
            return try VZDiskImageStorageDeviceAttachment(diskImage: stack, synchronizationMode: .full)
        }
        #endif
        throw SidecarRPCError(code: "nativeStorageUnavailable", message: "native ASIF requires macOS 27 and a runtime built with the macOS 27 SDK")
    }
}
