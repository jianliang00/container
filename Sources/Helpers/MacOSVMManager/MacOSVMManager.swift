import AppKit
import Darwin
import Foundation
import Virtualization

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("vm stopped with error: \(error)\n", stderr)
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor func runStartCommand(options: Options) throws {
    #if !arch(arm64)
    fputs("error: macOS guest virtualization requires Apple Silicon (arm64)\n", stderr)
    exit(1)
    #else

    if let tempShare = options.temporarySharedDirectoryURL {
        defer {
            try? FileManager.default.removeItem(at: tempShare)
        }
        print("auto seed: \(tempShare.path)")
    }

    try ensureDirectoryExists(options.imageURL, message: "image directory does not exist")
    try ensureDirectoryExists(options.sharedDirectoryURL, message: "shared directory does not exist")

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

    let sharedDirectory = VZSharedDirectory(url: options.sharedDirectoryURL, readOnly: false)
    let singleDirectoryShare = VZSingleDirectoryShare(directory: sharedDirectory)
    let fileSystemDevice = VZVirtioFileSystemDeviceConfiguration(tag: options.shareTag)
    fileSystemDevice.share = singleDirectoryShare

    let vmConfiguration = VZVirtualMachineConfiguration()
    vmConfiguration.bootLoader = bootLoader
    vmConfiguration.platform = platform
    vmConfiguration.cpuCount = clampedCPUCount(options.cpus)
    vmConfiguration.memorySize = clampedMemoryBytes(options.memoryMiB)
    vmConfiguration.storageDevices = [blockDevice]
    vmConfiguration.networkDevices = [networkDevice]
    vmConfiguration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    vmConfiguration.directorySharingDevices = [fileSystemDevice]
    if !options.headless || options.headlessDisplay {
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
        vmConfiguration.graphicsDevices = [graphics]
        if !options.headless {
            vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
            vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
    }

    try vmConfiguration.validate()

    let virtualMachine = VZVirtualMachine(configuration: vmConfiguration)
    let delegate = VMDelegate()
    virtualMachine.delegate = delegate
    let debugger =
        (options.agentREPL || options.agentProbe || options.controlSocketPath != nil)
        ? AgentDebugger(
            virtualMachine: virtualMachine,
            port: options.agentPort,
            connectRetries: options.agentConnectRetries
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
    print("share: \(options.sharedDirectoryURL.path)")
    print("share tag: \(options.shareTag)")
    let displayMode: String
    if options.headlessDisplay {
        displayMode = "headless-display"
    } else if options.headless {
        displayMode = "headless"
    } else {
        displayMode = "gui"
    }
    print("display mode: \(displayMode)")
    if options.agentREPL {
        print("agent repl: enabled (port \(options.agentPort))")
    }
    if options.agentProbe {
        print("agent probe: enabled (port \(options.agentPort))")
    }
    if let controlSocketPath = options.controlSocketPath {
        print("control socket: \(controlSocketPath)")
    }
    print("In guest:")
    print("  sudo mkdir -p /Volumes/\(options.shareTag)")
    print("  sudo mount -t virtiofs \(options.shareTag) /Volumes/\(options.shareTag)")

    virtualMachine.start { result in
        switch result {
        case .success:
            print("VM started.")
            if let controlServer {
                do {
                    try controlServer.start()
                } catch {
                    fputs("failed to start control socket server: \(error)\n", stderr)
                    Task { @MainActor in
                        NSApplication.shared.terminate(nil)
                    }
                    return
                }
            }
            if options.agentProbe {
                debugger?.launchProbeAndTerminateApp()
            } else if options.agentREPL {
                debugger?.launchREPL()
            }
        case .failure(let error):
            fputs("failed to start VM: \(error)\n", stderr)
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }

    _ = delegate
    _ = debugger
    _ = controlServer
    _ = window
    _ = vmView

    app.run()
    #endif
}

@main
struct MacOSVMManagerMain {
    static func main() async {
        guard #available(macOS 13.0, *) else {
            fputs("error: this tool requires macOS 13 or newer\n", stderr)
            exit(1)
        }

        do {
            switch try parseCommandLine() {
            case .start(let options):
                try await MainActor.run {
                    try runStartCommand(options: options)
                }
            }
        } catch {
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
