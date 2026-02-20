#!/usr/bin/swift

// Minimal manual launcher for a macOS template VM with GUI + virtiofs.
//
// Build + run:
//   xcrun swiftc scripts/macos-guest-agent/manual-template-vm.swift \
//     -framework AppKit -framework Virtualization \
//     -o /tmp/manual-template-vm
//   /tmp/manual-template-vm \
//     --template /path/to/template-dir \
//     --share /tmp/macos-agent-seed \
//     --share-tag seed

import AppKit
import Foundation
import Virtualization

struct Options {
    let templateURL: URL
    let sharedDirectoryURL: URL
    let shareTag: String
    let cpus: Int
    let memoryMiB: UInt64
}

enum ArgumentError: Error, CustomStringConvertible {
    case missingValue(flag: String)
    case unknownFlag(String)
    case invalidNumber(flag: String, value: String)
    case required(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .unknownFlag(let flag):
            return "unknown flag: \(flag)"
        case .invalidNumber(let flag, let value):
            return "invalid numeric value for \(flag): \(value)"
        case .required(let message):
            return message
        }
    }
}

func printUsage() {
    let usage = """
    Usage:
      manual-template-vm.swift --template <path> --share <path> [options]

    Required:
      --template <path>     Template directory containing Disk.img/AuxiliaryStorage/HardwareModel.bin
      --share <path>        Host directory to mount into guest using virtiofs

    Optional:
      --share-tag <name>    virtiofs tag visible in guest (default: seed)
      --cpus <n>            Requested vCPU count (default: 4)
      --memory-mib <n>      Requested memory in MiB (default: 8192)
      -h, --help            Show this help

    In guest, mount the shared directory with:
      sudo mkdir -p /Volumes/<tag>
      sudo mount -t virtiofs <tag> /Volumes/<tag>
    """
    print(usage)
}

func parseOptions() throws -> Options {
    var templatePath: String?
    var sharePath: String?
    var shareTag = "seed"
    var cpus = 4
    var memoryMiB: UInt64 = 8192

    var index = 1
    let args = CommandLine.arguments

    while index < args.count {
        let flag = args[index]
        switch flag {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "--template":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            templatePath = args[index]
        case "--share":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            sharePath = args[index]
        case "--share-tag":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            shareTag = args[index]
        case "--cpus":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            guard let value = Int(args[index]), value > 0 else {
                throw ArgumentError.invalidNumber(flag: flag, value: args[index])
            }
            cpus = value
        case "--memory-mib":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            guard let value = UInt64(args[index]), value > 0 else {
                throw ArgumentError.invalidNumber(flag: flag, value: args[index])
            }
            memoryMiB = value
        default:
            throw ArgumentError.unknownFlag(flag)
        }
        index += 1
    }

    guard let templatePath else {
        throw ArgumentError.required("missing required argument: --template")
    }
    guard let sharePath else {
        throw ArgumentError.required("missing required argument: --share")
    }

    return Options(
        templateURL: URL(fileURLWithPath: templatePath).standardizedFileURL,
        sharedDirectoryURL: URL(fileURLWithPath: sharePath).standardizedFileURL,
        shareTag: shareTag,
        cpus: cpus,
        memoryMiB: memoryMiB
    )
}

func ensureFileExists(_ path: URL, message: String) {
    guard FileManager.default.fileExists(atPath: path.path) else {
        fputs("error: \(message): \(path.path)\n", stderr)
        exit(1)
    }
}

func ensureDirectoryExists(_ path: URL, message: String) {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
    guard exists, isDirectory.boolValue else {
        fputs("error: \(message): \(path.path)\n", stderr)
        exit(1)
    }
}

func clampedCPUCount(_ requested: Int) -> Int {
    let minAllowed = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    let maxAllowed = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    return max(minAllowed, min(maxAllowed, requested))
}

func clampedMemoryBytes(_ requestedMiB: UInt64) -> UInt64 {
    let requested = requestedMiB * 1024 * 1024
    let minAllowed = VZVirtualMachineConfiguration.minimumAllowedMemorySize
    let maxAllowed = VZVirtualMachineConfiguration.maximumAllowedMemorySize
    return max(minAllowed, min(maxAllowed, requested))
}

func loadOrCreateMachineIdentifier(at path: URL) throws -> VZMacMachineIdentifier {
    if FileManager.default.fileExists(atPath: path.path) {
        let data = try Data(contentsOf: path)
        if let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: data) {
            return machineIdentifier
        }
        fputs("warning: existing MachineIdentifier.bin is invalid, generating a new one\n", stderr)
    }

    let machineIdentifier = VZMacMachineIdentifier()
    try machineIdentifier.dataRepresentation.write(to: path)
    return machineIdentifier
}

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        NSApplication.shared.terminate(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("vm stopped with error: \(error)\n", stderr)
        NSApplication.shared.terminate(nil)
    }
}

do {
    guard #available(macOS 13.0, *) else {
        fputs("error: this script requires macOS 13 or newer\n", stderr)
        exit(1)
    }

    #if !arch(arm64)
    fputs("error: macOS guest virtualization requires Apple Silicon (arm64)\n", stderr)
    exit(1)
    #else
    let options = try parseOptions()

    ensureDirectoryExists(options.templateURL, message: "template directory does not exist")
    ensureDirectoryExists(options.sharedDirectoryURL, message: "shared directory does not exist")

    let hardwareModelURL = options.templateURL.appendingPathComponent("HardwareModel.bin")
    let auxiliaryStorageURL = options.templateURL.appendingPathComponent("AuxiliaryStorage")
    let diskImageURL = options.templateURL.appendingPathComponent("Disk.img")
    let machineIdentifierURL = options.templateURL.appendingPathComponent("MachineIdentifier.bin")

    ensureFileExists(hardwareModelURL, message: "missing template file")
    ensureFileExists(auxiliaryStorageURL, message: "missing template file")
    ensureFileExists(diskImageURL, message: "missing template file")

    let hardwareModelData = try Data(contentsOf: hardwareModelURL)
    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
        fputs("error: invalid HardwareModel.bin\n", stderr)
        exit(1)
    }

    let machineIdentifier = try loadOrCreateMachineIdentifier(at: machineIdentifierURL)

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = hardwareModel
    platform.machineIdentifier = machineIdentifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStorageURL)

    let bootLoader = VZMacOSBootLoader()

    let blockAttachment = try VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false)
    let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: blockAttachment)

    let networkDevice = VZVirtioNetworkDeviceConfiguration()
    networkDevice.attachment = VZNATNetworkDeviceAttachment()

    let sharedDirectory = VZSharedDirectory(url: options.sharedDirectoryURL, readOnly: false)
    let singleDirectoryShare = VZSingleDirectoryShare(directory: sharedDirectory)
    let fileSystemDevice = VZVirtioFileSystemDeviceConfiguration(tag: options.shareTag)
    fileSystemDevice.share = singleDirectoryShare

    let graphics = VZMacGraphicsDeviceConfiguration()
    if let screen = NSScreen.main ?? NSScreen.screens.first {
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                for: screen,
                sizeInPoints: NSSize(width: 1440, height: 900)
            )
        ]
    } else {
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1440, heightInPixels: 900, pixelsPerInch: 80)
        ]
    }

    let vmConfiguration = VZVirtualMachineConfiguration()
    vmConfiguration.bootLoader = bootLoader
    vmConfiguration.platform = platform
    vmConfiguration.cpuCount = clampedCPUCount(options.cpus)
    vmConfiguration.memorySize = clampedMemoryBytes(options.memoryMiB)
    vmConfiguration.storageDevices = [blockDevice]
    vmConfiguration.networkDevices = [networkDevice]
    vmConfiguration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    vmConfiguration.directorySharingDevices = [fileSystemDevice]
    vmConfiguration.graphicsDevices = [graphics]
    vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
    vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

    try vmConfiguration.validate()

    let virtualMachine = VZVirtualMachine(configuration: vmConfiguration)
    let delegate = VMDelegate()
    virtualMachine.delegate = delegate

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Manual macOS Template VM"

    let vmView = VZVirtualMachineView(frame: frame)
    vmView.virtualMachine = virtualMachine
    vmView.capturesSystemKeys = true
    vmView.autoresizingMask = [.width, .height]
    window.contentView = vmView
    window.makeKeyAndOrderFront(nil)

    app.activate(ignoringOtherApps: true)

    print("Starting VM...")
    print("template: \(options.templateURL.path)")
    print("share: \(options.sharedDirectoryURL.path)")
    print("share tag: \(options.shareTag)")
    print("In guest:")
    print("  sudo mkdir -p /Volumes/\(options.shareTag)")
    print("  sudo mount -t virtiofs \(options.shareTag) /Volumes/\(options.shareTag)")

    virtualMachine.start { result in
        switch result {
        case .success:
            print("VM started.")
        case .failure(let error):
            fputs("failed to start VM: \(error)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    // Keep references alive for the app lifetime.
    _ = delegate
    _ = window
    _ = vmView

    app.run()
    #endif
} catch {
    fputs("error: \(error)\n", stderr)
    printUsage()
    exit(1)
}
