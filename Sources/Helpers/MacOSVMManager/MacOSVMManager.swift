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

import AppKit
import ContainerResource
import Darwin
import Foundation
import Virtualization

struct ProcessExitError: Error {
    let code: Int32
}

final class ExitStatusController: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = 0

    func markFailed(_ code: Int32 = 1) {
        lock.lock()
        defer { lock.unlock() }
        if status == 0 {
            status = code
        }
    }

    func currentStatus() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}

@MainActor
func stopApplicationRunLoop() {
    let app = NSApplication.shared
    app.stop(nil)
    if let event = NSEvent.otherEvent(
        with: .applicationDefined,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 0,
        data1: 0,
        data2: 0
    ) {
        app.postEvent(event, atStart: false)
    }
    CFRunLoopStop(CFRunLoopGetMain())
}

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    private let exitStatus: ExitStatusController

    init(exitStatus: ExitStatusController) {
        self.exitStatus = exitStatus
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            stopApplicationRunLoop()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("vm stopped with error: \(error)\n", stderr)
        exitStatus.markFailed()
        Task { @MainActor in
            stopApplicationRunLoop()
        }
    }
}

private final class VMStartCompletionHandler: @unchecked Sendable {
    private let exitStatus: ExitStatusController
    private let options: Options
    private let debugger: AgentDebugger?
    private let controlServer: ControlCommandServer?

    init(
        exitStatus: ExitStatusController,
        options: Options,
        debugger: AgentDebugger?,
        controlServer: ControlCommandServer?
    ) {
        self.exitStatus = exitStatus
        self.options = options
        self.debugger = debugger
        self.controlServer = controlServer
    }

    @MainActor func succeeded() {
        print("VM started.")
        if let controlServer {
            do {
                try controlServer.start()
            } catch {
                fputs("failed to start control socket server: \(error)\n", stderr)
                exitStatus.markFailed()
                stopApplicationRunLoop()
                return
            }
        }
        if options.agentProbe {
            debugger?.launchProbeAndTerminateApp()
        } else if options.agentREPL {
            debugger?.launchREPL()
        }
    }

    @MainActor func failed(errorDescription: String) {
        fputs("failed to start VM: \(errorDescription)\n", stderr)
        exitStatus.markFailed()
        stopApplicationRunLoop()
    }

    @MainActor func complete(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            succeeded()
        case .failure(let error):
            failed(errorDescription: String(describing: error))
        }
    }
}

@MainActor func runStartCommand(options: Options) throws {
    #if !arch(arm64)
    fputs("error: macOS guest virtualization requires Apple Silicon (arm64)\n", stderr)
    exit(1)
    #else

    if let tempShare = options.temporarySharedDirectoryURL {
        print("auto seed: \(tempShare.path)")
    }
    defer {
        if let tempShare = options.temporarySharedDirectoryURL {
            try? FileManager.default.removeItem(at: tempShare)
        }
    }

    try ensureDirectoryExists(options.imageURL, message: "image directory does not exist")
    if let sharedDirectoryURL = options.sharedDirectoryURL {
        try ensureDirectoryExists(sharedDirectoryURL, message: "shared directory does not exist")
    }

    let hardwareModelURL = options.imageURL.appendingPathComponent("HardwareModel.bin")
    let auxiliaryStorageURL = options.imageURL.appendingPathComponent("AuxiliaryStorage")
    let diskImageURL = options.imageURL.appendingPathComponent("Disk.img")
    let machineIdentifierURL = options.imageURL.appendingPathComponent("MachineIdentifier.bin")

    try ensureFileExists(hardwareModelURL, message: "missing image file")
    try ensureFileExists(auxiliaryStorageURL, message: "missing image file")
    try ensureFileExists(diskImageURL, message: "missing image file")

    let hardwareModelData = try Data(contentsOf: hardwareModelURL)
    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
        throw ArgumentError.required("invalid HardwareModel.bin")
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

    let fileSystemDevice: VZVirtioFileSystemDeviceConfiguration?
    if let sharedDirectoryURL = options.sharedDirectoryURL {
        let sharedDirectory = VZSharedDirectory(url: sharedDirectoryURL, readOnly: false)
        let device = VZVirtioFileSystemDeviceConfiguration(tag: options.shareTag)
        if options.shareTag == MacOSGuestMountMapping.automountTag {
            device.share = VZMultipleDirectoryShare(
                directories: [MacOSGuestMountMapping.defaultSeedShareName: sharedDirectory]
            )
        } else {
            device.share = VZSingleDirectoryShare(directory: sharedDirectory)
        }
        fileSystemDevice = device
    } else {
        fileSystemDevice = nil
    }

    let vmConfiguration = VZVirtualMachineConfiguration()
    vmConfiguration.bootLoader = bootLoader
    vmConfiguration.platform = platform
    vmConfiguration.cpuCount = clampedCPUCount(options.cpus)
    vmConfiguration.memorySize = clampedMemoryBytes(options.memoryMiB)
    vmConfiguration.storageDevices = [blockDevice]
    vmConfiguration.networkDevices = [networkDevice]
    vmConfiguration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    if let fileSystemDevice {
        vmConfiguration.directorySharingDevices = [fileSystemDevice]
    }
    if !options.headless || options.headlessDisplay {
        let graphics = VZMacGraphicsDeviceConfiguration()
        let screen = NSScreen.main ?? NSScreen.screens.first
        let onConsole = isSessionOnConsole() ?? false
        if onConsole, let screen {
            graphics.displays = [
                VZMacGraphicsDisplayConfiguration(
                    for: screen,
                    sizeInPoints: NSSize(width: 1440, height: 900)
                )
            ]
            print("graphics source: host-screen")
        } else {
            graphics.displays = [
                VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)
            ]
            print("graphics source: fixed-1920x1200 (fallback)")
        }
        vmConfiguration.graphicsDevices = [graphics]
        if !options.headless {
            vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
            vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
    }

    try vmConfiguration.validate()

    let exitStatus = ExitStatusController()
    let virtualMachine = VZVirtualMachine(configuration: vmConfiguration)
    let delegate = VMDelegate(exitStatus: exitStatus)
    virtualMachine.delegate = delegate
    let debugger =
        (options.agentREPL || options.agentProbe || options.controlSocketPath != nil)
        ? AgentDebugger(
            virtualMachine: virtualMachine,
            port: options.agentPort,
            connectRetries: options.agentConnectRetries,
            exitStatus: exitStatus
        ) : nil
    let controlServer = options.controlSocketPath.map { ControlCommandServer(socketPath: $0, debugger: debugger) }

    let app = NSApplication.shared
    app.setActivationPolicy(options.headless ? .prohibited : .regular)
    print(
        "host context: pid=\(getpid()) uid=\(getuid()) stdinTTY=\(isatty(STDIN_FILENO) == 1) session={\(currentSessionSummary())} screens=\(NSScreen.screens.count) hasMainScreen=\(NSScreen.main != nil)"
    )

    var window: NSWindow?
    var vmView: VZVirtualMachineView?
    if !options.headless {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let uiWindow = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        uiWindow.title = "macOS VM Manager"

        let uiVMView = VZVirtualMachineView(frame: frame)
        uiVMView.virtualMachine = virtualMachine
        uiVMView.capturesSystemKeys = true
        uiVMView.autoresizingMask = [.width, .height]
        uiWindow.contentView = uiVMView
        uiWindow.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        window = uiWindow
        vmView = uiVMView
    }

    print("Starting VM...")
    print("image (--image): \(options.imageURL.path)")
    if let sharedDirectoryURL = options.sharedDirectoryURL {
        print("share: \(sharedDirectoryURL.path)")
        print("share tag: \(options.shareTag)")
    } else {
        print("share: disabled")
    }
    if options.startFromRecovery {
        print("recovery: enabled")
    }
    let displayMode: String
    if options.headlessDisplay {
        displayMode = "headless-display"
    } else if options.headless {
        displayMode = "headless"
    } else {
        displayMode = "gui"
    }
    print("display mode: \(displayMode)")
    if options.headless && !options.headlessDisplay && (options.agentREPL || options.agentProbe || options.controlSocketPath != nil) {
        print("warning: pure headless is known to produce guest-agent vsock resets; retry with --headless-display if probe/repl/control fails")
    }
    if options.agentREPL {
        print("agent repl: enabled (port \(options.agentPort))")
    }
    if options.agentProbe {
        print("agent probe: enabled (port \(options.agentPort))")
    }
    if let controlSocketPath = options.controlSocketPath {
        print("control socket: \(controlSocketPath)")
    }
    if options.sharedDirectoryURL != nil {
        print("In guest:")
        if options.shareTag == MacOSGuestMountMapping.automountTag {
            print("  shared directory is available at \(MacOSGuestMountMapping.defaultSeedMountPath)")
        } else {
            print("  sudo mkdir -p /Volumes/\(options.shareTag)")
            print("  sudo mount -t virtiofs \(options.shareTag) /Volumes/\(options.shareTag)")
        }
    }

    let startHandler = VMStartCompletionHandler(
        exitStatus: exitStatus,
        options: options,
        debugger: debugger,
        controlServer: controlServer
    )

    if options.startFromRecovery {
        let startOptions = VZMacOSVirtualMachineStartOptions()
        startOptions.startUpFromMacOSRecovery = true
        virtualMachine.start(options: startOptions) { error in
            if let error {
                let errorDescription = String(describing: error)
                Task { @MainActor in
                    startHandler.failed(errorDescription: errorDescription)
                }
            } else {
                Task { @MainActor in
                    startHandler.succeeded()
                }
            }
        }
    } else {
        virtualMachine.start { result in
            startHandler.complete(result)
        }
    }

    _ = delegate
    _ = debugger
    _ = controlServer
    _ = startHandler
    _ = window
    _ = vmView

    app.run()
    let status = exitStatus.currentStatus()
    if status != 0 {
        throw ProcessExitError(code: status)
    }
    #endif
}

@main
struct MacOSVMManagerMain {
    @MainActor static func main() {
        guard #available(macOS 13.0, *) else {
            fputs("error: this tool requires macOS 13 or newer\n", stderr)
            exit(1)
        }

        do {
            switch try parseCommandLine() {
            case .start(let options):
                try runStartCommand(options: options)
            }
        } catch {
            if let exitError = error as? ProcessExitError {
                exit(exitError.code)
            }
            fputs("error: \(error)\n", stderr)
            if error is CommandError {
                printRootUsage()
            } else if error is ArgumentError {
                printStartUsage()
            }
            exit(1)
        }
    }
}
