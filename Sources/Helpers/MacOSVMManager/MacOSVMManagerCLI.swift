import Darwin
import Foundation

struct Options {
    let imageURL: URL
    let sharedDirectoryURL: URL
    let shareTag: String
    let cpus: Int
    let memoryMiB: UInt64
    let headless: Bool
    let headlessDisplay: Bool
    let agentREPL: Bool
    let agentProbe: Bool
    let controlSocketPath: String?
    let agentPort: UInt32
    let agentConnectRetries: Int
    let temporarySharedDirectoryURL: URL?
}

enum CLICommand {
    case start(Options)
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

enum CommandError: Error, CustomStringConvertible {
    case missingSubcommand
    case unknownSubcommand(String)

    var description: String {
        switch self {
        case .missingSubcommand:
            return "missing subcommand (supported: start)"
        case .unknownSubcommand(let value):
            return "unknown subcommand: \(value)"
        }
    }
}

func executableName() -> String {
    URL(fileURLWithPath: CommandLine.arguments.first ?? "container-macos-vm-manager").lastPathComponent
}

func printRootUsage(programName: String = executableName()) {
    let usage = """
        Usage:
          \(programName) <command> [options]

        Commands:
          start               Start a macOS guest VM from an image directory

        Help:
          \(programName) --help
          \(programName) start --help
        """
    print(usage)
}

func printStartUsage(programName: String = executableName()) {
    let usage = """
        Usage:
          \(programName) start --image <path> (--share <path> | --auto-seed) [options]

        Required:
          --image <path>        Image directory containing Disk.img/AuxiliaryStorage/HardwareModel.bin
          (--share <path> | --auto-seed)

        Optional:
          --share <path>        Host directory to mount into guest using virtiofs
          --template <path>     Alias for --image
          --share-tag <name>    virtiofs tag visible in guest (default: seed)
          --auto-seed           Create a temporary seed directory and mount it as the virtiofs share
          --guest-agent-bin <p> Guest agent binary used with --auto-seed (default: best-effort auto-detect)
          --seed-scripts-dir <p>
                               Directory containing install.sh, container-macos-guest-agent.plist, install-in-guest-from-seed.sh
          --cpus <n>            Requested vCPU count (default: 4)
          --memory-mib <n>      Requested memory in MiB (default: 8192)
          --headless            Start without graphics/keyboard/pointer devices (closer to container runtime default)
          --headless-display    Headless UI (no window) but keep a virtual display device attached
          --agent-repl          Enable interactive guest-agent debugger over vsock
          --agent-probe         Non-interactive probe: auto connect to guest-agent, print result, then exit
          --control-socket <p>  Start a Unix socket control server (commands: probe, quit, help)
          --agent-port <n>      Guest-agent vsock port (default: 27000)
          --agent-connect-retries <n>
                                Number of connect retries after VM start (default: 60)
          -h, --help            Show this help

        In guest, mount the shared directory with:
          sudo mkdir -p /Volumes/<tag>
          sudo mount -t virtiofs <tag> /Volumes/<tag>

        With --agent-repl enabled:
          connect
          connect-wait
          sh /bin/ls /
          exec /usr/bin/id
          exec-tty /bin/sh
          stdin echo hello
          close
          signal 15
          resize 120 40
          quit
        """
    print(usage)
}

func parseStartOptions(_ args: [String], programName: String = executableName()) throws -> Options {
    var imagePath: String?
    var sharePath: String?
    var shareTag = "seed"
    var cpus = 4
    var memoryMiB: UInt64 = 8192
    var headless = false
    var headlessDisplay = false
    var agentREPL = false
    var agentProbe = false
    var controlSocketPath: String?
    var agentPort: UInt32 = 27000
    var agentConnectRetries = 60
    var autoSeed = false
    var guestAgentBinPath: String?
    var seedScriptsDirPath: String?

    var index = 0

    while index < args.count {
        let flag = args[index]
        switch flag {
        case "-h", "--help":
            printStartUsage(programName: programName)
            exit(0)
        case "--image", "--template":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            imagePath = args[index]
        case "--share":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            sharePath = args[index]
        case "--share-tag":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            shareTag = args[index]
        case "--auto-seed":
            autoSeed = true
        case "--guest-agent-bin":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            guestAgentBinPath = args[index]
        case "--seed-scripts-dir":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            seedScriptsDirPath = args[index]
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
        case "--headless":
            headless = true
        case "--headless-display":
            headless = true
            headlessDisplay = true
        case "--agent-repl":
            agentREPL = true
        case "--agent-probe":
            agentProbe = true
        case "--control-socket":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            controlSocketPath = args[index]
        case "--agent-port":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            guard let value = UInt32(args[index]), value > 0 else {
                throw ArgumentError.invalidNumber(flag: flag, value: args[index])
            }
            agentPort = value
        case "--agent-connect-retries":
            index += 1
            guard index < args.count else { throw ArgumentError.missingValue(flag: flag) }
            guard let value = Int(args[index]), value > 0 else {
                throw ArgumentError.invalidNumber(flag: flag, value: args[index])
            }
            agentConnectRetries = value
        default:
            throw ArgumentError.unknownFlag(flag)
        }
        index += 1
    }

    guard let imagePath else {
        throw ArgumentError.required("missing required argument: --image")
    }
    let temporaryShareURL: URL?
    if autoSeed {
        if sharePath != nil {
            throw ArgumentError.required("use either --share or --auto-seed")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("container-macos-seed-\(UUID().uuidString)")
        try prepareSeedDirectory(
            seedDir: tempDir,
            guestAgentBinOverride: guestAgentBinPath,
            seedScriptsDirOverride: seedScriptsDirPath
        )

        sharePath = tempDir.path
        temporaryShareURL = tempDir
    } else {
        guard sharePath != nil else {
            throw ArgumentError.required("missing required argument: --share")
        }
        temporaryShareURL = nil
    }

    return Options(
        imageURL: URL(fileURLWithPath: imagePath).standardizedFileURL,
        sharedDirectoryURL: URL(fileURLWithPath: sharePath!).standardizedFileURL,
        shareTag: shareTag,
        cpus: cpus,
        memoryMiB: memoryMiB,
        headless: headless,
        headlessDisplay: headlessDisplay,
        agentREPL: agentREPL,
        agentProbe: agentProbe,
        controlSocketPath: controlSocketPath,
        agentPort: agentPort,
        agentConnectRetries: agentConnectRetries,
        temporarySharedDirectoryURL: temporaryShareURL
    )
}

func parseCommandLine() throws -> CLICommand {
    let args = CommandLine.arguments
    let programName = executableName()

    guard args.count >= 2 else {
        throw CommandError.missingSubcommand
    }

    let subcommand = args[1]
    switch subcommand {
    case "-h", "--help":
        printRootUsage(programName: programName)
        exit(0)
    case "start":
        return .start(try parseStartOptions(Array(args.dropFirst(2)), programName: programName))
    default:
        throw CommandError.unknownSubcommand(subcommand)
    }
}
