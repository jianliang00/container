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
import ContainerK8sFlannelVXLANMacOS
import Darwin
@preconcurrency import Dispatch
import Foundation

@main
struct FlannelVXLANMacOS: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-flannel-vxlan-macos",
        abstract: "Connect a macOS Kubernetes PodCIDR to a Flannel IPv4 VXLAN network."
    )

    @Option(name: [.customLong("config"), .short], help: "Path to the macOS Flannel VXLAN JSON config.")
    var configPath: String

    @Flag(name: .customLong("once"), help: "Run one reconciliation cycle and exit.")
    var once = false

    @Flag(
        name: .customLong("cleanup"),
        help: "Clean up an offline Flannel dataplane. Active daemon tunnels are refused."
    )
    var cleanup = false

    @Flag(
        name: .customLong("withdraw"),
        help: "Ask the running daemon to withdraw its dataplane and wait for an acknowledgement."
    )
    var withdraw = false

    @Flag(
        name: .customLong("purge-network"),
        help: "Delete the owned host-only Pod network after Flannel, kubelet, and CRI have stopped."
    )
    var purgeNetwork = false

    @Flag(
        name: .customLong("check-purge"),
        help: "Verify that the owned Pod network can be purged without deleting it."
    )
    var checkPurge = false

    @Option(
        name: .customLong("control-socket"),
        help: "Path to the root-only daemon control socket."
    )
    var controlSocketPath = FlannelVXLANMacOSConfig.defaultControlSocketPath

    func run() async throws {
        let selectedActions = [once, cleanup, withdraw, checkPurge, purgeNetwork].filter { $0 }.count
        guard selectedActions <= 1 else {
            throw ValidationError(
                "--once, --cleanup, --withdraw, --check-purge, and --purge-network are mutually exclusive"
            )
        }
        guard controlSocketPath.hasPrefix("/") else {
            throw ValidationError("--control-socket must be an absolute path")
        }
        var initialWithdrawalError: (any Error)?
        var onlinePurgeFallbackContext: String?
        let configurationExists = FileManager.default.fileExists(atPath: configPath)
        if withdraw {
            do {
                try requestDaemonWithdrawal()
                return
            } catch {
                initialWithdrawalError = error
            }
        }
        if cleanup || withdraw || checkPurge || purgeNetwork, !configurationExists {
            let acquiredLifetimeLock: FlannelDaemonLifetimeLock?
            do {
                acquiredLifetimeLock = try FlannelDaemonLifetimeLock.tryAcquire()
            } catch {
                throw FlannelVXLANError.runtime(
                    "offline state inspection could not acquire the lifetime lock: \(error)"
                )
            }
            guard let lifetimeLock = acquiredLifetimeLock else {
                let withdrawalDetail = initialWithdrawalError.map { "; daemon withdrawal failed: \($0)" } ?? ""
                throw FlannelVXLANError.runtime(
                    "offline cleanup configuration is missing and state inspection was refused because the daemon lifetime lock is held"
                        + withdrawalDetail
                )
            }
            defer { withExtendedLifetime(lifetimeLock) {} }
            let missingConfigurationState: FlannelMissingConfigurationState
            do {
                missingConfigurationState = try FlannelStateManifestCoordinator().discoverMissingConfiguration(
                    requestedConfigPath: configPath,
                    whileHolding: lifetimeLock
                )
            } catch {
                throw FlannelVXLANError.runtime("offline state inspection failed: \(error)")
            }
            switch missingConfigurationState {
            case .managedStateRemains(_, let paths):
                throw ValidationError(
                    "offline cleanup configuration \(configPath) is missing while Flannel state remains at "
                        + paths.joined(separator: ", ")
                )
            case .noManagedState:
                print("no Flannel state requires cleanup")
                return
            case .noManifest:
                let statePaths = Self.defaultStatePaths
                guard statePaths.allSatisfy({ !FileManager.default.fileExists(atPath: $0) }) else {
                    throw ValidationError(
                        "offline cleanup configuration \(configPath) is missing while legacy Flannel state remains"
                    )
                }
            }
            print("no Flannel state requires cleanup")
            return
        }
        let config = try FlannelVXLANMacOSConfig.load(from: URL(fileURLWithPath: configPath))
        try config.validateConfigurationFilePath(configPath)
        try config.validateControlSocketPath(
            controlSocketPath,
            configurationFilePath: configPath
        )
        if checkPurge {
            let manifest = try FlannelStateManifest(configPath: configPath, config: config)
            let claim = try FlannelPurgePreflightClaim(manifest: manifest)
            switch try requestOnlinePurgePreflight(claim: claim) {
            case .completed(let message):
                print("online network purge preflight complete \(message)")
                return
            case .fallbackAllowed(let context):
                onlinePurgeFallbackContext = context
            }
        }
        switch try FlannelBootstrapContext().ensure(
            containerServiceUserID: config.containerServiceUserID,
            executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
            arguments: Array(CommandLine.arguments.dropFirst())
        ) {
        case .ready:
            break
        case .reexecuted(let exitCode):
            guard exitCode == 0 else {
                throw ExitCode(exitCode)
            }
            return
        }
        if withdraw {
            do {
                try requestDaemonWithdrawal()
                return
            } catch let controlError {
                guard let lifetimeLock = try FlannelDaemonLifetimeLock.tryAcquire() else {
                    throw FlannelVXLANError.runtime(
                        "daemon withdrawal failed: \(controlError); offline cleanup refused because the daemon lifetime lock is held"
                    )
                }
                defer { withExtendedLifetime(lifetimeLock) {} }
                let manifestCoordinator = FlannelStateManifestCoordinator()
                try manifestCoordinator.claim(
                    configPath: configPath,
                    config: config,
                    whileHolding: lifetimeLock
                )
                let forwardingRecovery = try FlannelOfflineForwardingRecovery(config: config)
                    .restoreIfForwardingOnly(whileHolding: lifetimeLock)
                if case .restored(let families) = forwardingRecovery {
                    try manifestCoordinator.removeIfUnowned(whileHolding: lifetimeLock)
                    print(
                        "offline forwarding recovery complete families="
                            + families.map(\.rawValue).sorted().joined(separator: ",")
                    )
                    return
                }
                let hasDataplaneState = config.withdrawalStatePaths.contains {
                    FileManager.default.fileExists(atPath: $0)
                }
                let hasNodeCredential = FileManager.default.fileExists(atPath: config.nodeKubeconfig)
                guard hasDataplaneState || hasNodeCredential else {
                    print("no running or owned Flannel dataplane requires withdrawal")
                    return
                }
                do {
                    let result = try await makeController(config: config).cleanup()
                    try manifestCoordinator.removeIfUnowned(whileHolding: lifetimeLock)
                    print(
                        "offline withdrawal complete routes=\(result.removedRoutes.count) "
                            + "tunnelStopped=\(result.stoppedTunnel) "
                            + "forwardingRestored=\(result.restoredForwardingFamilies.count) "
                            + "annotationsRemoved=\(result.removedNodeAnnotations)"
                    )
                    return
                } catch let cleanupError {
                    throw FlannelVXLANError.runtime(
                        "daemon withdrawal failed: \(controlError); offline cleanup failed: \(cleanupError)"
                    )
                }
            }
        }
        if purgeNetwork {
            guard let lifetimeLock = try FlannelDaemonLifetimeLock.tryAcquire() else {
                throw FlannelVXLANError.runtime(
                    "network purge refused because the Flannel daemon lifetime lock is held"
                )
            }
            defer { withExtendedLifetime(lifetimeLock) {} }
            let manifestCoordinator = FlannelStateManifestCoordinator()
            try manifestCoordinator.claim(
                configPath: configPath,
                config: config,
                whileHolding: lifetimeLock
            )
            let result = try await FlannelHostOnlyNetworkPurger(config: config).purge()
            try manifestCoordinator.removeIfUnowned(whileHolding: lifetimeLock)
            print("network purge complete present=\(result.networkWasPresent) removed=\(result.removed)")
            return
        }
        if checkPurge {
            let onlineDetail =
                onlinePurgeFallbackContext.map {
                    "online preflight fallback was allowed because \($0); "
                } ?? ""
            let acquiredLifetimeLock: FlannelDaemonLifetimeLock?
            do {
                acquiredLifetimeLock = try FlannelDaemonLifetimeLock.tryAcquire()
            } catch {
                throw FlannelVXLANError.runtime(
                    onlineDetail + "offline network purge preflight could not acquire the lifetime lock: \(error)"
                )
            }
            guard let lifetimeLock = acquiredLifetimeLock else {
                throw FlannelVXLANError.runtime(
                    onlineDetail + "offline network purge preflight refused because the Flannel daemon lifetime lock is held"
                )
            }
            defer { withExtendedLifetime(lifetimeLock) {} }
            do {
                try FlannelStateManifestCoordinator().validateClaim(
                    configPath: configPath,
                    config: config,
                    whileHolding: lifetimeLock
                )
                let result = try await FlannelHostOnlyNetworkPurger(config: config).checkPurge()
                print("offline network purge preflight complete \(Self.formatPurgePreflight(result))")
                return
            } catch {
                throw FlannelVXLANError.runtime(
                    onlineDetail + "offline network purge preflight failed: \(error)"
                )
            }
        }
        if cleanup {
            guard let lifetimeLock = try FlannelDaemonLifetimeLock.tryAcquire() else {
                throw FlannelVXLANError.runtime(
                    "cleanup refused because the Flannel daemon lifetime lock is held"
                )
            }
            defer { withExtendedLifetime(lifetimeLock) {} }
            let manifestCoordinator = FlannelStateManifestCoordinator()
            try manifestCoordinator.claim(
                configPath: configPath,
                config: config,
                whileHolding: lifetimeLock
            )
            let controller = try makeController(config: config)
            let result = try await controller.cleanup()
            try manifestCoordinator.removeIfUnowned(whileHolding: lifetimeLock)
            print(
                "cleanup complete routes=\(result.removedRoutes.count) ipv6Routes=\(result.removedIPv6Routes.count) "
                    + "tunnelStopped=\(result.stoppedTunnel) ipv6TunnelStopped=\(result.stoppedIPv6Tunnel) "
                    + "forwardingRestored=\(result.restoredForwardingFamilies.count) "
                    + "annotationsRemoved=\(result.removedNodeAnnotations) attempts=\(result.nodeAnnotationAttempts)"
            )
            return
        }

        if once {
            guard let lifetimeLock = try FlannelDaemonLifetimeLock.tryAcquire() else {
                throw FlannelVXLANError.runtime(
                    "one-shot reconciliation refused because the Flannel daemon lifetime lock is held"
                )
            }
            defer { withExtendedLifetime(lifetimeLock) {} }
            let manifestCoordinator = FlannelStateManifestCoordinator()
            try manifestCoordinator.claim(
                configPath: configPath,
                config: config,
                whileHolding: lifetimeLock
            )
            let controller = try makeController(config: config)
            let result: FlannelVXLANReconcileResult
            do {
                result = try await controller.runOnce()
            } catch {
                do {
                    try await controller.shutdown()
                } catch let cleanupError {
                    throw FlannelVXLANError.runtime("one-shot reconciliation failed: \(error); cleanup failed: \(cleanupError)")
                }
                throw error
            }
            print(
                "ready node=\(result.localNetwork.nodeName) podCIDR=\(result.localNetwork.podCIDR) "
                    + "underlay=\(result.underlay.ipv4Address) interface=\(result.interfaceName) "
                    + "mtu=\(result.mtu) peers=\(result.peers.count) ipv4Ready=\(result.ipv4Ready) "
                    + "ipv6Ready=\(result.ipv6Ready.map(String.init) ?? "disabled") "
                    + "ipv6PodCIDR=\(result.localIPv6Network?.podCIDR ?? "<none>") "
                    + "ipv6Interface=\(result.ipv6InterfaceName ?? "<none>") "
                    + "ipv6Peers=\(result.ipv6Peers.count) issues=\(result.issues.count)"
            )
            try await controller.shutdown()
            try manifestCoordinator.removeIfUnowned(whileHolding: lifetimeLock)
            return
        }

        guard geteuid() == 0 else {
            throw ValidationError("the Flannel daemon must run as root")
        }
        guard let lifetimeLock = try FlannelDaemonLifetimeLock.tryAcquire() else {
            throw FlannelVXLANError.runtime("another Flannel daemon holds the daemon lifetime lock")
        }
        defer { withExtendedLifetime(lifetimeLock) {} }
        let manifestCoordinator = FlannelStateManifestCoordinator()
        try manifestCoordinator.claim(
            configPath: configPath,
            config: config,
            whileHolding: lifetimeLock
        )
        let controller = try makeController(config: config)
        let signalStream = terminationSignals()
        let lifecycle = FlannelDaemonLifecycle(controller: controller)
        let controlServer = FlannelControlServer(socketPath: controlSocketPath)
        let daemonConfigPath = configPath
        try controlServer.start(
            withdrawalHandler: {
                await lifecycle.withdraw()
            },
            checkPurgeHandler: { requestedClaim in
                do {
                    let activeManifest = try manifestCoordinator.requireExactClaim(
                        configPath: daemonConfigPath,
                        config: config,
                        whileHolding: lifetimeLock
                    )
                    let activeClaim = try FlannelPurgePreflightClaim(manifest: activeManifest)
                    guard requestedClaim == activeClaim else {
                        throw FlannelVXLANError.invalidConfiguration(
                            "purge preflight request does not match the active Flannel state manifest"
                        )
                    }
                    let result = try await FlannelHostOnlyNetworkPurger(config: config).checkPurge()
                    return FlannelWithdrawalOutcome(
                        succeeded: true,
                        message: Self.formatPurgePreflight(result)
                    )
                } catch {
                    return FlannelWithdrawalOutcome(
                        succeeded: false,
                        message: "network purge preflight failed: \(error)"
                    )
                }
            }
        )
        await lifecycle.start()
        _ = await signalStream.first { _ in true }
        await lifecycle.terminateWhenClean()
        controlServer.stop()
        try manifestCoordinator.removeIfUnowned(whileHolding: lifetimeLock)
    }

    private static var defaultStatePaths: [String] {
        FlannelVXLANMacOSConfig.defaultPersistentStatePaths
    }

    private enum OnlinePurgePreflightAttempt {
        case completed(String)
        case fallbackAllowed(String)
    }

    private func requestOnlinePurgePreflight(
        claim: FlannelPurgePreflightClaim
    ) throws -> OnlinePurgePreflightAttempt {
        do {
            let outcome = try FlannelControlClient.requestPurgePreflight(
                claim: claim,
                socketPath: controlSocketPath
            )
            guard outcome.succeeded else {
                throw FlannelVXLANError.runtime(
                    "online network purge preflight failed: \(outcome.message)"
                )
            }
            return .completed(outcome.message)
        } catch let error as FlannelCheckPurgeControlError {
            switch error {
            case .transport, .unsupportedAction:
                return .fallbackAllowed(error.description)
            case .authentication, .protocolViolation:
                throw FlannelVXLANError.runtime(
                    "online network purge preflight refused: \(error)"
                )
            }
        }
    }

    private static func formatPurgePreflight(_ result: FlannelHostOnlyNetworkPurgeCheckResult) -> String {
        let networkName = result.ownedNetworkName ?? "<none>"
        return "owned=\(result.ownedNetworkName != nil) network=\(networkName) "
            + "present=\(result.networkWasPresent) attachments=\(result.referringObjectIDs.count)"
    }

    private func makeController(config: FlannelVXLANMacOSConfig) throws -> FlannelVXLANController {
        let kubernetes = try FlannelKubernetesClient(
            readKubeconfigPath: config.kubeconfig,
            nodeKubeconfigPath: config.nodeKubeconfig,
            nodeName: config.nodeName
        )
        return try FlannelVXLANController(config: config, kubernetes: kubernetes)
    }

    private func requestDaemonWithdrawal() throws {
        let outcome = try FlannelControlClient.requestWithdrawal(socketPath: controlSocketPath)
        guard outcome.succeeded else {
            throw FlannelVXLANError.runtime("daemon withdrawal was not acknowledged: \(outcome.message)")
        }
        print("withdrawal acknowledged: \(outcome.message)")
    }

    private func terminationSignals() -> AsyncStream<Int32> {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        return AsyncStream { continuation in
            let sources = [SIGINT, SIGTERM].map { signalNumber in
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
                source.setEventHandler {
                    continuation.yield(signalNumber)
                }
                source.resume()
                return source
            }
            continuation.onTermination = { _ in
                for source in sources {
                    source.cancel()
                }
            }
        }
    }
}
