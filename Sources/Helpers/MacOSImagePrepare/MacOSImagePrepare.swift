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

import ArgumentParser
import ContainerVersion
import ContainerizationError
import Foundation

#if arch(arm64)
import Virtualization
#endif

@main
struct MacOSImagePrepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-macos-image-prepare",
        abstract: "Create a macOS guest template directory from an IPSW restore image",
        version: ReleaseVersion.singleLine(appName: "container-macos-image-prepare")
    )

    private enum TemplateFilenames {
        static let diskImage = "Disk.img"
        static let auxiliaryStorage = "AuxiliaryStorage"
        static let hardwareModel = "HardwareModel.bin"
    }

    @Option(
        name: .long,
        help: "Path to an IPSW file",
        completion: .file(),
        transform: { str in
            URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
        }
    )
    var ipsw: URL

    @Option(
        name: .shortAndLong,
        help: "Output template directory",
        completion: .directory,
        transform: { str in
            URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
        }
    )
    var output: URL

    @Option(name: [.customLong("disk-size-gib"), .long], help: "Disk image size in GiB")
    var diskSizeGiB: UInt64 = 64

    @Option(name: [.customLong("memory-mib"), .long], help: "Memory size in MiB")
    var memoryMiB: UInt64 = 8192

    @Option(name: .long, help: "vCPU count")
    var cpus: Int?

    @Flag(name: .long, help: "Overwrite output files if present")
    var overwrite = false

    func run() async throws {
        #if arch(arm64)
        guard FileManager.default.fileExists(atPath: ipsw.path) else {
            throw ContainerizationError(.notFound, message: "IPSW file not found at \(ipsw.path)")
        }

        let output = output.standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let auxiliaryURL = output.appendingPathComponent(TemplateFilenames.auxiliaryStorage)
        let diskURL = output.appendingPathComponent(TemplateFilenames.diskImage)
        let hardwareURL = output.appendingPathComponent(TemplateFilenames.hardwareModel)

        try createDiskImage(path: diskURL, sizeBytes: diskSizeGiB * 1024 * 1024 * 1024, overwrite: overwrite)
        let hardwareModelData = try await Self.installAndCaptureHardwareModelData(
            ipsw: ipsw,
            auxiliaryURL: auxiliaryURL,
            diskURL: diskURL,
            overwrite: overwrite,
            requestedCPUs: cpus,
            requestedMemoryMiB: memoryMiB
        )

        if FileManager.default.fileExists(atPath: hardwareURL.path) {
            if overwrite {
                try FileManager.default.removeItem(at: hardwareURL)
            } else {
                throw ContainerizationError(.exists, message: "\(hardwareURL.path) already exists")
            }
        }
        try hardwareModelData.write(to: hardwareURL)

        print(output.path)
        print("Template prepared. Before packaging, boot once and pre-install container-macos-guest-agent in the guest image.")
        #else
        throw ContainerizationError(.unsupported, message: "macOS guest preparation requires an arm64 host")
        #endif
    }

    #if arch(arm64)
    private static func resolveCPUCount(requestedCPUs: Int?, minimum: Int) -> Int {
        let minAllowed = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let maxAllowed = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let requested = requestedCPUs ?? max(minimum, minAllowed)
        return max(minAllowed, min(maxAllowed, max(requested, minimum)))
    }

    private static func resolveMemorySize(requestedMemoryMiB: UInt64, minimum: UInt64) -> UInt64 {
        let requested = requestedMemoryMiB * 1024 * 1024
        let minAllowed = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxAllowed = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        let clamped = max(minAllowed, min(maxAllowed, requested))
        return max(clamped, minimum)
    }

    @MainActor
    private static func installAndCaptureHardwareModelData(
        ipsw: URL,
        auxiliaryURL: URL,
        diskURL: URL,
        overwrite: Bool,
        requestedCPUs: Int?,
        requestedMemoryMiB: UInt64
    ) async throws -> Data {
        let restoreImage = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw ContainerizationError(.unsupported, message: "the restore image is not supported on this host")
        }

        let hardwareModel = requirements.hardwareModel
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = VZMacMachineIdentifier()
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: auxiliaryURL,
            hardwareModel: hardwareModel,
            options: overwrite ? [.allowOverwrite] : []
        )

        let vmConfiguration = VZVirtualMachineConfiguration()
        vmConfiguration.bootLoader = VZMacOSBootLoader()
        vmConfiguration.platform = platform
        vmConfiguration.cpuCount = resolveCPUCount(requestedCPUs: requestedCPUs, minimum: requirements.minimumSupportedCPUCount)
        vmConfiguration.memorySize = resolveMemorySize(requestedMemoryMiB: requestedMemoryMiB, minimum: requirements.minimumSupportedMemorySize)
        vmConfiguration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false))]
        vmConfiguration.networkDevices = [createNATNetworkDevice()]
        // Keep installer device config aligned with OpenBox's successful install path.
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)]
        vmConfiguration.graphicsDevices = [graphics]
        vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
        vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        try validateVirtualMachineConfiguration(vmConfiguration)

        let vm = VZVirtualMachine(configuration: vmConfiguration)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        do {
            try await installer.install()
        } catch {
            throw formatInstallError(error)
        }

        return hardwareModel.dataRepresentation
    }

    private static func createNATNetworkDevice() -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return device
    }

    private static func validateVirtualMachineConfiguration(_ configuration: VZVirtualMachineConfiguration) throws {
        try configuration.validate()
    }

    private static func formatInstallError(_ error: any Error) -> ContainerizationError {
        let nsError = error as NSError
        var details = ["\(nsError.domain) code \(nsError.code)"]

        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            details.append(reason)
        }

        var remediationHint = ""
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("underlying: \(underlying.domain) code \(underlying.code) \(underlying.localizedDescription)")
            if let reason = underlying.localizedFailureReason, !reason.isEmpty {
                details.append(reason)
            }
            if underlying.domain == "com.apple.MobileDevice.MobileRestore", underlying.code == 4014 {
                remediationHint = " This usually indicates a restore state mismatch (DFU vs RestoreOS). It can also be caused by VPN/proxy/TLS interception blocking Apple restore services."
            }
        }

        let suffix = details.joined(separator: "; ")
        return ContainerizationError(
            .internalError,
            message: "macOS guest installation failed (\(suffix)).\(remediationHint)",
            cause: error
        )
    }
    #endif

    private func createDiskImage(path: URL, sizeBytes: UInt64, overwrite: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            if overwrite {
                try fm.removeItem(at: path)
            } else {
                throw ContainerizationError(.exists, message: "\(path.path) already exists")
            }
        }

        guard fm.createFile(atPath: path.path, contents: nil) else {
            throw ContainerizationError(.internalError, message: "failed to create disk image at \(path.path)")
        }
        let handle = try FileHandle(forWritingTo: path)
        defer {
            try? handle.close()
        }
        try handle.truncate(atOffset: sizeBytes)
    }
}
