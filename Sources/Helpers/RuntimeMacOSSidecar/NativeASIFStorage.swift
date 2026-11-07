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
    ) throws -> (base: URL, overlay: URL) {
        guard let basePath = device.nativeBasePath, !device.readOnly,
            device.exportName == nil, device.synchronizationMode == .full
        else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF requires a base, writable overlay and full synchronization")
        }
        let base = try managedDiskURL(rootURL: rootURL, relativePath: basePath)
        let overlay = try managedDiskURL(rootURL: rootURL, relativePath: device.path)
        var baseStat = stat()
        var overlayStat = stat()
        guard lstat(base.path, &baseStat) == 0, lstat(overlay.path, &overlayStat) == 0,
            baseStat.st_mode & S_IFMT == S_IFREG, overlayStat.st_mode & S_IFMT == S_IFREG,
            baseStat.st_size > 0, overlayStat.st_size > 0,
            baseStat.st_mode & 0o222 == 0, overlayStat.st_mode & 0o200 != 0,
            baseStat.st_dev != overlayStat.st_dev || baseStat.st_ino != overlayStat.st_ino
        else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF needs distinct regular files with an immutable base and writable overlay")
        }
        return (base, overlay)
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
            guard base.format == .raw, overlay.format == .asif, overlay.layerType == .overlay else {
                throw SidecarRPCError(code: "invalidStorageConfiguration", message: "native ASIF requires a RAW base and an ASIF overlay layer")
            }
            let stack = try base.appending(overlay)
            return try VZDiskImageStorageDeviceAttachment(diskImage: stack, synchronizationMode: .full)
        }
        #endif
        throw SidecarRPCError(code: "nativeStorageUnavailable", message: "native ASIF requires macOS 27 and a runtime built with the macOS 27 SDK")
    }
}
