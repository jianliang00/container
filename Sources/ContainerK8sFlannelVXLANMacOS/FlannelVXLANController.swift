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

import ContainerCRIShimMacOS
import Foundation

public struct FlannelVXLANReconcileResult: Sendable, Equatable {
    public var localNetwork: FlannelLocalNodeNetwork
    public var underlay: FlannelUnderlayInterface
    public var interfaceName: String
    public var mtu: Int
    public var peers: [FlannelPeer]
    public var issues: [FlannelCompileIssue]
    public var statistics: FlannelTunnelStatistics

    public init(
        localNetwork: FlannelLocalNodeNetwork,
        underlay: FlannelUnderlayInterface,
        interfaceName: String,
        mtu: Int,
        peers: [FlannelPeer],
        issues: [FlannelCompileIssue],
        statistics: FlannelTunnelStatistics
    ) {
        self.localNetwork = localNetwork
        self.underlay = underlay
        self.interfaceName = interfaceName
        self.mtu = mtu
        self.peers = peers
        self.issues = issues
        self.statistics = statistics
    }
}

public struct FlannelCleanupResult: Sendable, Equatable {
    public var removedRoutes: [String]
    public var stoppedTunnel: Bool
    public var removedNodeAnnotations: Bool
    public var nodeAnnotationAttempts: Int

    public init(
        removedRoutes: [String],
        stoppedTunnel: Bool,
        removedNodeAnnotations: Bool,
        nodeAnnotationAttempts: Int
    ) {
        self.removedRoutes = removedRoutes
        self.stoppedTunnel = stoppedTunnel
        self.removedNodeAnnotations = removedNodeAnnotations
        self.nodeAnnotationAttempts = nodeAnnotationAttempts
    }
}

public actor FlannelVXLANController {
    public typealias TunnelFactory = @Sendable (FlannelTunnelConfiguration) throws -> any FlannelTunnelControlling

    private let config: FlannelVXLANMacOSConfig
    private let kubernetes: any FlannelKubernetesReading & FlannelKubernetesWriting
    private let networkManager: any FlannelNetworkManaging
    private let system: any FlannelSystemManaging
    private let podNetworkStateStore: PodNetworkStateStore
    private let vtepMACStore: any FlannelVTEPMACStoring
    private let ownershipStateStore: any FlannelOwnershipStateStoring
    private let networkOwnershipStateStore: any FlannelHostOnlyNetworkOwnershipStoring
    private let makeTunnel: TunnelFactory
    private let now: @Sendable () -> Date
    private let cleanupRetryDelay: Duration

    private var tunnel: (any FlannelTunnelControlling)?
    private var tunnelConfiguration: FlannelTunnelConfiguration?
    private var installedRoutes: Set<String> = []

    public init(
        config: FlannelVXLANMacOSConfig,
        kubernetes: any FlannelKubernetesReading & FlannelKubernetesWriting,
        networkManager: any FlannelNetworkManaging = ContainerKitFlannelNetworkManager(),
        system: any FlannelSystemManaging = FlannelSystemManager(),
        podNetworkStateStore: PodNetworkStateStore = PodNetworkStateStore(),
        vtepMACStore: (any FlannelVTEPMACStoring)? = nil,
        ownershipStateStore: (any FlannelOwnershipStateStoring)? = nil,
        networkOwnershipStateStore: (any FlannelHostOnlyNetworkOwnershipStoring)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        cleanupRetryDelay: Duration = .milliseconds(250),
        makeTunnel: @escaping TunnelFactory = { try FlannelVXLANTunnel(configuration: $0) }
    ) throws {
        try config.validate()
        self.config = config
        self.kubernetes = kubernetes
        self.networkManager = networkManager
        self.system = system
        self.podNetworkStateStore = podNetworkStateStore
        self.vtepMACStore = vtepMACStore ?? FlannelVTEPMACStore(path: config.vtepMACPath)
        self.ownershipStateStore = ownershipStateStore ?? FlannelOwnershipStateStore(path: config.ownershipStatePath)
        self.networkOwnershipStateStore =
            networkOwnershipStateStore
            ?? FlannelHostOnlyNetworkOwnershipStore(path: config.networkOwnershipStatePath)
        self.now = now
        self.cleanupRetryDelay = cleanupRetryDelay
        self.makeTunnel = makeTunnel
    }

    @discardableResult
    public func runOnce() async throws -> FlannelVXLANReconcileResult {
        do {
            return try await reconcile()
        } catch {
            let reconcileError = error
            do {
                try clearReadyState()
            } catch {
                throw FlannelVXLANError.runtime(
                    "reconcile failed: \(reconcileError); failed to clear ready lease: \(error)"
                )
            }
            throw reconcileError
        }
    }

    public func runForever(
        onError: @escaping @Sendable (Error) -> Void = { error in
            fputs("container-flannel-vxlan-macos: \(error)\n", stderr)
        }
    ) async throws -> Never {
        while true {
            try Task.checkCancellation()
            do {
                _ = try await runOnce()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onError(error)
            }
            try await Task.sleep(for: .seconds(config.syncPeriodSeconds))
        }
    }

    @discardableResult
    public func shutdown(removeNodeAnnotations: Bool = true) async throws -> FlannelCleanupResult {
        try await cleanup(removeNodeAnnotations: removeNodeAnnotations)
    }

    @discardableResult
    public func cleanup(removeNodeAnnotations: Bool = true) async throws -> FlannelCleanupResult {
        var failures: [String] = []
        let persistedState: FlannelOwnershipState?
        do {
            persistedState = try ownershipStateStore.load()
        } catch {
            throw FlannelVXLANError.runtime("cleanup refused because dataplane ownership cannot be read: \(error)")
        }
        if tunnel == nil, let persistedState,
            try system.interfaceExists(persistedState.interfaceName)
        {
            throw FlannelVXLANError.runtime(
                "cleanup refused because tunnel interface \(persistedState.interfaceName) is still active; stop the launchd job and retry"
            )
        }

        do {
            try clearReadyState()
        } catch {
            throw FlannelVXLANError.runtime("cleanup incomplete: remove ready lease: \(error)")
        }

        var removedNodeAnnotations = false
        var nodeAnnotationAttempts = 0
        if removeNodeAnnotations {
            do {
                nodeAnnotationAttempts = try await removeNodeAnnotationsWithRetry()
                removedNodeAnnotations = true
            } catch {
                nodeAnnotationAttempts = Self.nodeAnnotationCleanupAttempts
                throw FlannelVXLANError.runtime(
                    "cleanup incomplete: remove Node annotations after \(nodeAnnotationAttempts) attempts: \(error)"
                )
            }
        }

        let interface = tunnel?.interfaceName ?? persistedState?.interfaceName
        let routes = installedRoutes.union(persistedState?.routePodCIDRs ?? [])
        var removedRoutes: [String] = []
        if let interface {
            for podCIDR in routes.sorted() {
                do {
                    try system.removeRoute(podCIDR: podCIDR, interface: interface)
                    installedRoutes.remove(podCIDR)
                    removedRoutes.append(podCIDR)
                } catch {
                    failures.append("remove route \(podCIDR) from \(interface): \(error)")
                }
            }
        } else if !routes.isEmpty {
            failures.append("remove routes: cleanup state does not identify their tunnel interface")
        }
        guard failures.isEmpty else {
            throw FlannelVXLANError.runtime("cleanup incomplete: \(failures.joined(separator: "; "))")
        }

        let stoppedTunnel = tunnel != nil
        let stoppingTunnel = tunnel
        stoppingTunnel?.stop()
        if stoppingTunnel?.isRunning == true {
            failures.append("stop tunnel \(stoppingTunnel?.interfaceName ?? "<unknown>"): tunnel is still running")
        }

        guard failures.isEmpty else {
            throw FlannelVXLANError.runtime("cleanup incomplete: \(failures.joined(separator: "; "))")
        }
        stoppingTunnel?.destroy()

        if let interface {
            do {
                if try system.interfaceExists(interface) {
                    failures.append("remove tunnel \(interface): interface still exists after stop")
                }
            } catch {
                failures.append("inspect tunnel \(interface) after stop: \(error)")
            }
        }

        guard failures.isEmpty else {
            throw FlannelVXLANError.runtime("cleanup incomplete: \(failures.joined(separator: "; "))")
        }

        tunnel = nil
        tunnelConfiguration = nil

        do {
            try ownershipStateStore.remove()
        } catch {
            failures.append("remove cleanup state: \(error)")
        }
        guard failures.isEmpty else {
            throw FlannelVXLANError.runtime("cleanup incomplete: \(failures.joined(separator: "; "))")
        }

        return FlannelCleanupResult(
            removedRoutes: removedRoutes,
            stoppedTunnel: stoppedTunnel,
            removedNodeAnnotations: removedNodeAnnotations,
            nodeAnnotationAttempts: nodeAnnotationAttempts
        )
    }

    private func reconcile() async throws -> FlannelVXLANReconcileResult {
        guard let runtimeState = try await podNetworkStateStore.loadRuntimeState(path: config.runtimeStatePath) else {
            throw FlannelVXLANError.runtime("waiting for kubelet to publish the local PodCIDR")
        }
        guard runtimeState.networkName == config.networkName,
            let runtimeCIDR = FlannelIPv4.parseCIDR(runtimeState.podCIDR)
        else {
            throw FlannelVXLANError.runtime("runtime Pod network state does not match \(config.networkName)")
        }

        async let configMapRequest = kubernetes.configMap(
            namespace: config.configMapNamespace,
            name: config.configMapName
        )
        async let nodesRequest = kubernetes.nodes()
        let (configMap, nodes) = try await (configMapRequest, nodesRequest)

        let networkConfig = try FlannelConfigParser.parse(configMap: configMap, key: config.networkConfigKey)
        try networkConfig.backend.validateWindowsCompatibility()
        let compilation = try FlannelPeerCompiler.compile(
            nodes: nodes,
            localNodeName: config.nodeName,
            networkConfig: networkConfig,
            annotationPrefix: config.annotationPrefix
        )
        guard let localNetwork = compilation.localNetwork,
            let localCIDR = FlannelIPv4.parseCIDR(localNetwork.podCIDR)
        else {
            throw FlannelVXLANError.runtime("waiting for Node \(config.nodeName) to publish its PodCIDR")
        }
        guard runtimeCIDR == localCIDR else {
            throw FlannelVXLANError.runtime(
                "kubelet PodCIDR \(runtimeState.podCIDR) does not match Node PodCIDR \(localNetwork.podCIDR)"
            )
        }

        let underlay: FlannelUnderlayInterface
        if let underlayInterface = config.underlayInterface {
            underlay = try system.inspectUnderlayInterface(underlayInterface)
        } else {
            underlay = try system.resolveUnderlayInterface(nodeInternalIP: localNetwork.internalIP)
        }
        if let nodeIP = localNetwork.internalIP, nodeIP != underlay.ipv4Address {
            throw FlannelVXLANError.runtime(
                "Node InternalIP \(nodeIP) does not match \(underlay.name) address \(underlay.ipv4Address)"
            )
        }
        for publicIP in Set(compilation.peers.map(\.publicIP)).sorted() {
            try system.validateUnderlayRoute(destination: publicIP, interface: underlay.name)
        }
        let mtu = try networkConfig.backend.innerMTU(underlayMTU: underlay.mtu)
        guard (576...9_000).contains(mtu) else {
            throw FlannelVXLANError.invalidNetworkConfig("calculated inner MTU \(mtu) is outside 576...9000")
        }

        let knownNetworkOwnership = try networkOwnershipStateStore.load()
        let networkResult = try await networkManager.ensureHostOnlyNetwork(
            name: config.networkName,
            podCIDR: localNetwork.podCIDR,
            plugin: config.networkPlugin,
            variant: config.networkVariant,
            knownOwnership: knownNetworkOwnership
        )
        if let ownership = networkResult.ownership {
            try networkOwnershipStateStore.save(ownership)
        } else if knownNetworkOwnership != nil {
            try networkOwnershipStateStore.remove()
        }
        try system.enableIPv4Forwarding()

        let vtepMAC = try vtepMACStore.loadOrCreate()
        let desiredTunnelConfiguration = FlannelTunnelConfiguration(
            vni: networkConfig.backend.vni,
            port: networkConfig.backend.port,
            mtu: mtu,
            bindIP: underlay.ipv4Address,
            localPodCIDR: localNetwork.podCIDR,
            localVTEPMAC: vtepMAC
        )
        try replaceTunnelIfNeeded(configuration: desiredTunnelConfiguration)
        guard let tunnel else {
            throw FlannelVXLANError.runtime("tunnel was not created")
        }

        try tunnel.setPeers(compilation.peers)
        try reconcileRoutes(desired: Set(compilation.peers.map(\.podCIDR)), interface: tunnel.interfaceName)
        try ownershipStateStore.save(
            FlannelOwnershipState(
                interfaceName: tunnel.interfaceName,
                localPodCIDR: localNetwork.podCIDR,
                routePodCIDRs: installedRoutes.sorted()
            ))

        let annotationPatch = try FlannelKubernetesClient.leaseAnnotationPatch(
            annotationPrefix: config.annotationPrefix,
            publicIP: underlay.ipv4Address,
            vni: networkConfig.backend.vni,
            vtepMAC: vtepMAC
        )
        _ = try await kubernetes.patchOwnNodeAnnotations(annotationPatch)

        let readyAtUnixSeconds = Int64(now().timeIntervalSince1970.rounded(.down))
        let leaseDurationSeconds = Int64(max(15, config.syncPeriodSeconds * 4))
        try await podNetworkStateStore.writeReadyState(
            PodNetworkReadyState(
                networkName: config.networkName,
                podCIDR: localNetwork.podCIDR,
                runtimeGeneration: runtimeState.generation,
                mtu: UInt32(mtu),
                expiresAtUnixSeconds: readyAtUnixSeconds + leaseDurationSeconds
            ),
            path: config.readyStatePath
        )
        return FlannelVXLANReconcileResult(
            localNetwork: localNetwork,
            underlay: underlay,
            interfaceName: tunnel.interfaceName,
            mtu: mtu,
            peers: compilation.peers,
            issues: compilation.issues,
            statistics: tunnel.statistics()
        )
    }

    private func replaceTunnelIfNeeded(configuration: FlannelTunnelConfiguration) throws {
        guard tunnel == nil || tunnelConfiguration != configuration || tunnel?.isRunning == false else {
            return
        }
        removeAllRoutes()
        tunnel?.stop()
        tunnel?.destroy()
        tunnel = nil
        tunnelConfiguration = nil

        let created = try makeTunnel(configuration)
        do {
            guard let localCIDR = FlannelIPv4.parseCIDR(configuration.localPodCIDR) else {
                throw FlannelVXLANError.invalidConfiguration("local PodCIDR is not valid IPv4")
            }
            try system.configureTunnelInterface(
                created.interfaceName,
                localAddress: localCIDR.baseAddress,
                mtu: configuration.mtu
            )
            try created.start()
        } catch {
            created.stop()
            created.destroy()
            throw error
        }
        tunnel = created
        tunnelConfiguration = configuration
    }

    private func reconcileRoutes(desired: Set<String>, interface: String) throws {
        for podCIDR in installedRoutes.subtracting(desired).sorted() {
            try system.removeRoute(podCIDR: podCIDR, interface: interface)
            installedRoutes.remove(podCIDR)
        }
        for podCIDR in desired.sorted() {
            try system.ensureRoute(podCIDR: podCIDR, interface: interface)
            installedRoutes.insert(podCIDR)
        }
    }

    private func removeAllRoutes() {
        guard let interface = tunnel?.interfaceName else {
            installedRoutes.removeAll()
            return
        }
        for podCIDR in installedRoutes.sorted() {
            if (try? system.removeRoute(podCIDR: podCIDR, interface: interface)) != nil {
                installedRoutes.remove(podCIDR)
            }
        }
    }

    private static let nodeAnnotationCleanupAttempts = 3

    private func removeNodeAnnotationsWithRetry() async throws -> Int {
        let keys = try FlannelAnnotationKeys(prefix: config.annotationPrefix)
        let patch = FlannelNodeAnnotationPatch(removals: [
            keys.kubeSubnetManager,
            keys.backendType,
            keys.publicIP,
            keys.backendData,
        ])
        var lastError: Error?
        for attempt in 1...Self.nodeAnnotationCleanupAttempts {
            do {
                _ = try await kubernetes.patchOwnNodeAnnotations(patch)
                return attempt
            } catch let error as FlannelVXLANError where error.isKubernetesNotFound {
                return attempt
            } catch {
                lastError = error
                guard attempt < Self.nodeAnnotationCleanupAttempts else {
                    break
                }
                try await Task.sleep(for: cleanupRetryDelay)
            }
        }
        throw lastError ?? FlannelVXLANError.kubernetesAPI("Node annotation cleanup failed")
    }

    private func clearReadyState() throws {
        let url = URL(fileURLWithPath: config.readyStatePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FlannelVXLANError.persistence("failed to remove ready lease at \(url.path): \(error)")
        }
    }
}
