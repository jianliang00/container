import ArgumentParser
import ContainerAPIClient
import ContainerVersion
import ContainerizationError
import Foundation

extension Application {
    public struct MacOSStartVM: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "start-vm",
            abstract: "Start a macOS guest VM from an image directory"
        )

        private static let helperBinaryName = "container-macos-vm-manager"
        private static let helperBinaryEnvVar = "CONTAINER_MACOS_VM_MANAGER_BIN"

        @Option(
            name: .long,
            help: "Image directory containing Disk.img/AuxiliaryStorage/HardwareModel.bin",
            completion: .directory,
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
            }
        )
        var image: URL

        @Option(
            name: .long,
            help: "Host directory to mount into guest using virtiofs",
            completion: .directory,
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
            }
        )
        var share: URL?

        @Flag(name: .long, help: "Create a temporary seed directory and mount it as the virtiofs share")
        var autoSeed = false

        @Option(name: .long, help: "virtiofs tag visible in guest")
        var shareTag: String = "seed"

        @Option(name: .long, help: "Path to container-macos-guest-agent binary used with --auto-seed")
        var guestAgentBin: String?

        @Option(name: .long, help: "Directory containing install.sh, container-macos-guest-agent.plist, install-in-guest-from-seed.sh")
        var seedScriptsDir: String?

        @Option(name: .long, help: "Requested vCPU count")
        var cpus: Int = 4

        @Option(name: [.customLong("memory-mib"), .long], help: "Requested memory in MiB")
        var memoryMiB: UInt64 = 8192

        @Flag(name: .long, help: "Start without graphics/keyboard/pointer devices")
        var headless = false

        @Flag(name: .long, help: "Headless UI (no window) but keep a virtual display device attached")
        var headlessDisplay = false

        @Flag(name: .long, help: "Enable interactive guest-agent debugger over vsock")
        var agentREPL = false

        @Flag(name: .long, help: "Non-interactive probe: auto connect to guest-agent, print result, then exit")
        var agentProbe = false

        @Option(name: .long, help: "Start a Unix socket control server (commands: probe, quit, help)")
        var controlSocket: String?

        @Option(name: .long, help: "Guest-agent vsock port")
        var agentPort: UInt32 = 27000

        @Option(name: .long, help: "Number of connect retries after VM start")
        var agentConnectRetries: Int = 60

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            if autoSeed {
                if share != nil {
                    throw ValidationError("use either --share or --auto-seed")
                }
            } else {
                if share == nil {
                    throw ValidationError("missing required option: --share (or use --auto-seed)")
                }
            }

            let helperURL = try helperBinaryURL()
            let process = Process()
            process.executableURL = helperURL
            process.arguments = helperArguments()
            process.environment = ProcessInfo.processInfo.environment
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            do {
                try process.run()
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to start \(Self.helperBinaryName) at \(helperURL.path): \(error.localizedDescription)",
                    cause: error
                )
            }

            process.waitUntilExit()
            switch process.terminationReason {
            case .exit:
                if process.terminationStatus != 0 {
                    throw ExitCode(process.terminationStatus)
                }
            case .uncaughtSignal:
                throw ExitCode(process.terminationStatus + 128)
            @unknown default:
                throw ExitCode(1)
            }
        }

        private func helperArguments() -> [String] {
            var args: [String] = ["start", "--image", image.standardizedFileURL.path]

            if autoSeed {
                args.append("--auto-seed")
                if let guestAgentBin, !guestAgentBin.isEmpty {
                    args += ["--guest-agent-bin", guestAgentBin]
                }
                if let seedScriptsDir, !seedScriptsDir.isEmpty {
                    args += ["--seed-scripts-dir", seedScriptsDir]
                }
            } else if let share {
                args += ["--share", share.standardizedFileURL.path]
            }

            if shareTag != "seed" {
                args += ["--share-tag", shareTag]
            }

            args += ["--cpus", String(cpus)]
            args += ["--memory-mib", String(memoryMiB)]

            if headlessDisplay {
                args.append("--headless-display")
            } else if headless {
                args.append("--headless")
            }

            if agentREPL {
                args.append("--agent-repl")
            }
            if agentProbe {
                args.append("--agent-probe")
            }
            if let controlSocket, !controlSocket.isEmpty {
                args += ["--control-socket", controlSocket]
            }
            if agentPort != 27000 {
                args += ["--agent-port", String(agentPort)]
            }
            if agentConnectRetries != 60 {
                args += ["--agent-connect-retries", String(agentConnectRetries)]
            }

            return args
        }

        private func helperBinaryURL() throws -> URL {
            let fm = FileManager.default

            if let override = ProcessInfo.processInfo.environment[Self.helperBinaryEnvVar], !override.isEmpty {
                let url = URL(fileURLWithPath: override, relativeTo: .currentDirectory()).absoluteURL
                if fm.isExecutableFile(atPath: url.path) {
                    return url
                }
                throw ContainerizationError(
                    .notFound,
                    message: "\(Self.helperBinaryEnvVar) points to a non-executable file: \(override)"
                )
            }

            let executableURL = CommandLine.executablePathUrl.standardizedFileURL
            let executableDir = executableURL.deletingLastPathComponent()
            let installRoot = executableDir.appendingPathComponent("..").standardizedFileURL
            let candidates = [
                executableDir.appendingPathComponent(Self.helperBinaryName),
                installRoot
                    .appendingPathComponent("libexec")
                    .appendingPathComponent("container")
                    .appendingPathComponent("macos-vm-manager")
                    .appendingPathComponent("bin")
                    .appendingPathComponent(Self.helperBinaryName),
            ]

            for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }

            let candidatePaths = candidates.map { "  - \($0.path(percentEncoded: false))" }.joined(separator: "\n")
            throw ContainerizationError(
                .notFound,
                message:
                    "\(Self.helperBinaryName) not found. Install it under the macos-vm-manager helper directory or set \(Self.helperBinaryEnvVar). Checked:\n\(candidatePaths)"
            )
        }
    }
}
