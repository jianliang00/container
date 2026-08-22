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
        if cleanup || withdraw || checkPurge || purgeNetwork,
            !FileManager.default.fileExists(atPath: configPath)
        {
            let statePaths = Self.defaultStatePaths
            guard statePaths.allSatisfy({ !FileManager.default.fileExists(atPath: $0) }) else {
                throw ValidationError(
                    "cleanup configuration \(configPath) is missing while Flannel state remains"
                )
            }
            print("no Flannel state requires cleanup")
            return
        }
        let config = try FlannelVXLANMacOSConfig.load(from: URL(fileURLWithPath: configPath))
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
                let outcome = try FlannelControlClient.requestWithdrawal(socketPath: controlSocketPath)
                guard outcome.succeeded else {
                    throw FlannelVXLANError.runtime("daemon withdrawal was not acknowledged: \(outcome.message)")
                }
                print("withdrawal acknowledged: \(outcome.message)")
                return
            } catch let controlError {
                let hasDataplaneState = [
                    config.ownershipStatePath,
                    config.hostIPv6GatewayOwnershipStatePath,
                    config.readyStatePath,
                ]
                .contains { FileManager.default.fileExists(atPath: $0) }
                let hasNodeCredential = FileManager.default.fileExists(atPath: config.nodeKubeconfig)
                guard hasDataplaneState || hasNodeCredential else {
                    print("no running or owned Flannel dataplane requires withdrawal")
                    return
                }
                do {
                    let result = try await makeController(config: config).cleanup()
                    print(
                        "offline withdrawal complete routes=\(result.removedRoutes.count) "
                            + "tunnelStopped=\(result.stoppedTunnel) annotationsRemoved=\(result.removedNodeAnnotations)"
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
            let result = try await FlannelHostOnlyNetworkPurger(config: config).purge()
            print("network purge complete present=\(result.networkWasPresent) removed=\(result.removed)")
            return
        }
        if checkPurge {
            let result = try await FlannelHostOnlyNetworkPurger(config: config).checkPurge()
            let networkName = result.ownedNetworkName ?? "<none>"
            print(
                "network purge preflight complete owned=\(result.ownedNetworkName != nil) "
                    + "network=\(networkName) attachments=\(result.referringObjectIDs.count)"
            )
            return
        }
        let controller = try makeController(config: config)

        if cleanup {
            let result = try await controller.cleanup()
            print(
                "cleanup complete routes=\(result.removedRoutes.count) ipv6Routes=\(result.removedIPv6Routes.count) "
                    + "tunnelStopped=\(result.stoppedTunnel) ipv6TunnelStopped=\(result.stoppedIPv6Tunnel) "
                    + "annotationsRemoved=\(result.removedNodeAnnotations) attempts=\(result.nodeAnnotationAttempts)"
            )
            return
        }

        if once {
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
            return
        }

        guard geteuid() == 0 else {
            throw ValidationError("the Flannel daemon must run as root")
        }
        let signalStream = terminationSignals()
        let lifecycle = FlannelDaemonLifecycle(controller: controller)
        let controlServer = FlannelControlServer(socketPath: controlSocketPath)
        try controlServer.start {
            await lifecycle.withdraw()
        }
        await lifecycle.start()
        _ = await signalStream.first { _ in true }
        await lifecycle.terminateWhenClean()
        controlServer.stop()
    }

    private static var defaultStatePaths: [String] {
        let ownershipURL = URL(fileURLWithPath: FlannelVXLANMacOSConfig.defaultOwnershipStatePath)
        return [
            ownershipURL.path,
            ownershipURL.deletingLastPathComponent().appendingPathComponent("network-ownership.json").path,
            ownershipURL.deletingLastPathComponent().appendingPathComponent("host-ipv6-gateway-ownership.json").path,
            ownershipURL.deletingLastPathComponent().appendingPathComponent("ready.json").path,
        ]
    }

    private func makeController(config: FlannelVXLANMacOSConfig) throws -> FlannelVXLANController {
        let kubernetes = try FlannelKubernetesClient(
            readKubeconfigPath: config.kubeconfig,
            nodeKubeconfigPath: config.nodeKubeconfig,
            nodeName: config.nodeName
        )
        return try FlannelVXLANController(config: config, kubernetes: kubernetes)
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
