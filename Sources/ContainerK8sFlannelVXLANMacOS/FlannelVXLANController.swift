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
    public var runtimeGeneration: UInt64
    public var localNetwork: FlannelLocalNodeNetwork
    public var underlay: FlannelUnderlayInterface
    public var interfaceName: String
    public var mtu: Int
    public var peers: [FlannelPeer]
    public var routeCount: Int
    public var tunnelUp: Bool
    public var tunnelEpoch: UInt64
    public var localIPv6Network: FlannelLocalNodeIPv6Network?
    public var ipv6InterfaceName: String?
    public var ipv6Peers: [FlannelIPv6Peer]
    public var ipv6RouteCount: Int?
    public var ipv6TunnelUp: Bool?
    public var ipv6TunnelEpoch: UInt64?
    public var ipv4Ready: Bool
    public var ipv6Ready: Bool?
    public var issues: [FlannelCompileIssue]
    public var statistics: FlannelTunnelStatistics
    public var ipv6Statistics: FlannelTunnelStatistics?

    public init(
        runtimeGeneration: UInt64 = 0,
        localNetwork: FlannelLocalNodeNetwork,
        underlay: FlannelUnderlayInterface,
        interfaceName: String,
        mtu: Int,
        peers: [FlannelPeer],
        routeCount: Int = 0,
        tunnelUp: Bool = false,
        tunnelEpoch: UInt64 = 0,
        localIPv6Network: FlannelLocalNodeIPv6Network? = nil,
        ipv6InterfaceName: String? = nil,
        ipv6Peers: [FlannelIPv6Peer] = [],
        ipv6RouteCount: Int? = nil,
        ipv6TunnelUp: Bool? = nil,
        ipv6TunnelEpoch: UInt64? = nil,
        ipv4Ready: Bool = true,
        ipv6Ready: Bool? = nil,
        issues: [FlannelCompileIssue],
        statistics: FlannelTunnelStatistics,
        ipv6Statistics: FlannelTunnelStatistics? = nil
    ) {
        self.runtimeGeneration = runtimeGeneration
        self.localNetwork = localNetwork
        self.underlay = underlay
        self.interfaceName = interfaceName
        self.mtu = mtu
        self.peers = peers
        self.routeCount = routeCount
        self.tunnelUp = tunnelUp
        self.tunnelEpoch = tunnelEpoch
        self.localIPv6Network = localIPv6Network
        self.ipv6InterfaceName = ipv6InterfaceName
        self.ipv6Peers = ipv6Peers
        self.ipv6RouteCount = ipv6RouteCount
        self.ipv6TunnelUp = ipv6TunnelUp
        self.ipv6TunnelEpoch = ipv6TunnelEpoch
        self.ipv4Ready = ipv4Ready
        self.ipv6Ready = ipv6Ready
        self.issues = issues
        self.statistics = statistics
        self.ipv6Statistics = ipv6Statistics
    }
}

public struct FlannelCleanupResult: Sendable, Equatable {
    public var removedRoutes: [String]
    public var removedIPv6Routes: [String]
    public var restoredForwardingFamilies: [FlannelForwardingFamily]
    public var stoppedTunnel: Bool
    public var stoppedIPv6Tunnel: Bool
    public var removedNodeAnnotations: Bool
    public var nodeAnnotationAttempts: Int

    public init(
        removedRoutes: [String],
        removedIPv6Routes: [String] = [],
        restoredForwardingFamilies: [FlannelForwardingFamily] = [],
        stoppedTunnel: Bool,
        stoppedIPv6Tunnel: Bool = false,
        removedNodeAnnotations: Bool,
        nodeAnnotationAttempts: Int
    ) {
        self.removedRoutes = removedRoutes
        self.removedIPv6Routes = removedIPv6Routes
        self.restoredForwardingFamilies = restoredForwardingFamilies
        self.stoppedTunnel = stoppedTunnel
        self.stoppedIPv6Tunnel = stoppedIPv6Tunnel
        self.removedNodeAnnotations = removedNodeAnnotations
        self.nodeAnnotationAttempts = nodeAnnotationAttempts
    }
}

public actor FlannelVXLANController {
    public typealias TunnelFactory = @Sendable (FlannelTunnelConfiguration) throws -> any FlannelTunnelControlling
    public typealias IPv6TunnelFactory =
        @Sendable (FlannelIPv6TunnelConfiguration) throws -> any FlannelIPv6TunnelControlling

    private let config: FlannelVXLANMacOSConfig
    private let kubernetes: any FlannelKubernetesReading & FlannelKubernetesWriting
    private let networkManager: any FlannelNetworkManaging
    private let system: any FlannelSystemManaging
    private let forwardingManager: any FlannelForwardingManaging
    private let podNetworkStateStore: PodNetworkStateStore
    private let vtepMACStore: any FlannelVTEPMACStoring
    private let vtepMACIPv6Store: any FlannelVTEPMACStoring
    private let ownershipStateStore: any FlannelOwnershipStateStoring
    private let networkOwnershipStateStore: any FlannelHostOnlyNetworkOwnershipStoring
    private let hostIPv6GatewayManager: any FlannelHostIPv6GatewayManaging
    private let hostIPv6GatewayOwnershipStore: any FlannelHostIPv6GatewayOwnershipStoring
    private let makeTunnel: TunnelFactory
    private let makeIPv6Tunnel: IPv6TunnelFactory
    private let now: @Sendable () -> Date
    private let cleanupRetryDelay: Duration

    private var tunnel: (any FlannelTunnelControlling)?
    private var tunnelConfiguration: FlannelTunnelConfiguration?
    private var tunnelEpoch: UInt64 = 0
    private var installedRoutes: Set<String> = []
    private var ipv6Tunnel: (any FlannelIPv6TunnelControlling)?
    private var ipv6TunnelConfiguration: FlannelIPv6TunnelConfiguration?
    private var ipv6TunnelEpoch: UInt64 = 0
    private var installedIPv6Routes: Set<String> = []

    private struct IPv6ReconcileContext {
        var localNetwork: FlannelLocalNodeIPv6Network
        var localCIDR: FlannelIPv6.CIDR
    }

    private struct IPv6DataplaneResult {
        var publicIPv6: String
        var vtepMAC: String
    }

    private struct IPv6FamilyWithdrawalResult {
        var dataplaneDeactivated: Bool
        var dataplaneFailure: String?
        var failures: [String]
    }

    public init(
        config: FlannelVXLANMacOSConfig,
        kubernetes: any FlannelKubernetesReading & FlannelKubernetesWriting,
        networkManager: any FlannelNetworkManaging = ContainerKitFlannelNetworkManager(),
        system: any FlannelSystemManaging = FlannelSystemManager(),
        forwardingManager: (any FlannelForwardingManaging)? = nil,
        podNetworkStateStore: PodNetworkStateStore = PodNetworkStateStore(),
        vtepMACStore: (any FlannelVTEPMACStoring)? = nil,
        vtepMACIPv6Store: (any FlannelVTEPMACStoring)? = nil,
        ownershipStateStore: (any FlannelOwnershipStateStoring)? = nil,
        networkOwnershipStateStore: (any FlannelHostOnlyNetworkOwnershipStoring)? = nil,
        hostIPv6GatewayManager: (any FlannelHostIPv6GatewayManaging)? = nil,
        hostIPv6GatewayOwnershipStore: (any FlannelHostIPv6GatewayOwnershipStoring)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        cleanupRetryDelay: Duration = .milliseconds(250),
        makeTunnel: @escaping TunnelFactory = { try FlannelVXLANTunnel(configuration: $0) },
        makeIPv6Tunnel: @escaping IPv6TunnelFactory = { try FlannelIPv6VXLANTunnel(configuration: $0) }
    ) throws {
        try config.validate()
        self.config = config
        self.kubernetes = kubernetes
        self.networkManager = networkManager
        self.system = system
        self.forwardingManager =
            forwardingManager
            ?? SystemFlannelForwardingManager(
                ownershipStore: FlannelForwardingOwnershipStore(
                    path: config.forwardingOwnershipStatePath
                )
            )
        self.podNetworkStateStore = podNetworkStateStore
        self.vtepMACStore = vtepMACStore ?? FlannelVTEPMACStore(path: config.vtepMACPath)
        self.vtepMACIPv6Store = vtepMACIPv6Store ?? FlannelVTEPMACStore(path: config.vtepMACIPv6Path)
        self.ownershipStateStore = ownershipStateStore ?? FlannelOwnershipStateStore(path: config.ownershipStatePath)
        self.networkOwnershipStateStore =
            networkOwnershipStateStore
            ?? FlannelHostOnlyNetworkOwnershipStore(path: config.networkOwnershipStatePath)
        let resolvedHostIPv6GatewayOwnershipStore =
            hostIPv6GatewayOwnershipStore
            ?? FlannelHostIPv6GatewayOwnershipStore(path: config.hostIPv6GatewayOwnershipStatePath)
        self.hostIPv6GatewayOwnershipStore = resolvedHostIPv6GatewayOwnershipStore
        self.hostIPv6GatewayManager =
            hostIPv6GatewayManager
            ?? SystemFlannelHostIPv6GatewayManager(ownershipStore: resolvedHostIPv6GatewayOwnershipStore)
        self.now = now
        self.cleanupRetryDelay = cleanupRetryDelay
        self.makeTunnel = makeTunnel
        self.makeIPv6Tunnel = makeIPv6Tunnel
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
        try await runForeverReportingResults(
            onResult: { _, _ in },
            onFailure: { _, _ in },
            onError: onError
        )
    }

    public func runForeverReportingResults(
        onResult: @escaping @Sendable (_ generation: Int, _ result: FlannelVXLANReconcileResult) -> Void,
        onFailure: @escaping @Sendable (_ generation: Int, _ error: Error) -> Void,
        onError: @escaping @Sendable (Error) -> Void = { error in
            fputs("container-flannel-vxlan-macos: \(error)\n", stderr)
        }
    ) async throws -> Never {
        var generation = 1
        while true {
            try Task.checkCancellation()
            do {
                let result = try await runOnce()
                onResult(generation, result)
                generation += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onFailure(generation, error)
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
        let persistedHostIPv6GatewayOwnership: FlannelHostIPv6GatewayOwnership?
        do {
            persistedHostIPv6GatewayOwnership = try hostIPv6GatewayOwnershipStore.load()
        } catch {
            throw FlannelVXLANError.runtime(
                "cleanup refused because host IPv6 gateway ownership cannot be read: \(error)"
            )
        }
        do {
            _ = try forwardingManager.ownedFamilies()
        } catch {
            throw FlannelVXLANError.runtime(
                "cleanup refused because forwarding ownership cannot be read: \(error)"
            )
        }
        if tunnel == nil, let persistedState,
            try system.interfaceExists(persistedState.interfaceName)
        {
            throw FlannelVXLANError.runtime(
                "cleanup refused because tunnel interface \(persistedState.interfaceName) is still active; stop the launchd job and retry"
            )
        }
        if ipv6Tunnel == nil, let interface = persistedState?.ipv6InterfaceName,
            try system.interfaceExists(interface)
        {
            throw FlannelVXLANError.runtime(
                "cleanup refused because IPv6 tunnel interface \(interface) is still active; stop the launchd job and retry"
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
        let ipv6Interface = ipv6Tunnel?.interfaceName ?? persistedState?.ipv6InterfaceName
        let routes = installedRoutes.union(persistedState?.routePodCIDRs ?? [])
        let ipv6Routes = installedIPv6Routes.union(persistedState?.ipv6RoutePodCIDRs ?? [])
        var removedRoutes: [String] = []
        var removedIPv6Routes: [String] = []
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
        if let ipv6Interface {
            for podCIDR in ipv6Routes.sorted() {
                do {
                    try system.removeIPv6Route(podCIDR: podCIDR, interface: ipv6Interface)
                    installedIPv6Routes.remove(podCIDR)
                    removedIPv6Routes.append(podCIDR)
                } catch {
                    failures.append("remove IPv6 route \(podCIDR) from \(ipv6Interface): \(error)")
                }
            }
        } else if !ipv6Routes.isEmpty {
            failures.append("remove IPv6 routes: cleanup state does not identify their tunnel interface")
        }
        guard failures.isEmpty else {
            throw FlannelVXLANError.runtime("cleanup incomplete: \(failures.joined(separator: "; "))")
        }

        let stoppedTunnel = tunnel != nil
        let stoppedIPv6Tunnel = ipv6Tunnel != nil
        let stoppingTunnel = tunnel
        let stoppingIPv6Tunnel = ipv6Tunnel
        stoppingTunnel?.stop()
        stoppingIPv6Tunnel?.stop()
        if stoppingTunnel?.isRunning == true {
            failures.append("stop tunnel \(stoppingTunnel?.interfaceName ?? "<unknown>"): tunnel is still running")
        }
        if stoppingIPv6Tunnel?.isRunning == true {
            failures.append(
                "stop IPv6 tunnel \(stoppingIPv6Tunnel?.interfaceName ?? "<unknown>"): tunnel is still running"
            )
        }

        guard failures.isEmpty else {
            throw FlannelVXLANError.runtime("cleanup incomplete: \(failures.joined(separator: "; "))")
        }
        stoppingTunnel?.destroy()
        stoppingIPv6Tunnel?.destroy()

        if let interface {
            do {
                if try system.interfaceExists(interface) {
                    failures.append("remove tunnel \(interface): interface still exists after stop")
                }
            } catch {
                failures.append("inspect tunnel \(interface) after stop: \(error)")
            }
        }
        if let ipv6Interface {
            do {
                if try system.interfaceExists(ipv6Interface) {
                    failures.append("remove IPv6 tunnel \(ipv6Interface): interface still exists after stop")
                }
            } catch {
                failures.append("inspect IPv6 tunnel \(ipv6Interface) after stop: \(error)")
            }
        }

        guard failures.isEmpty else {
            throw FlannelVXLANError.runtime("cleanup incomplete: \(failures.joined(separator: "; "))")
        }

        tunnel = nil
        tunnelConfiguration = nil
        ipv6Tunnel = nil
        ipv6TunnelConfiguration = nil

        if let persistedHostIPv6GatewayOwnership {
            do {
                try hostIPv6GatewayManager.remove(ownership: persistedHostIPv6GatewayOwnership)
                try hostIPv6GatewayOwnershipStore.remove()
            } catch {
                failures.append("remove host IPv6 gateway: \(error)")
            }
        }

        var restoredForwardingFamilies: [FlannelForwardingFamily] = []
        do {
            restoredForwardingFamilies = try forwardingManager.restoreAll()
        } catch {
            failures.append("restore host forwarding: \(error)")
        }

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
            removedIPv6Routes: removedIPv6Routes,
            restoredForwardingFamilies: restoredForwardingFamilies,
            stoppedTunnel: stoppedTunnel,
            stoppedIPv6Tunnel: stoppedIPv6Tunnel,
            removedNodeAnnotations: removedNodeAnnotations,
            nodeAnnotationAttempts: nodeAnnotationAttempts
        )
    }

    private func reconcile() async throws -> FlannelVXLANReconcileResult {
        let persistedOwnership = try ownershipStateStore.load()
        let persistedHostIPv6GatewayOwnership = try hostIPv6GatewayOwnershipStore.load()
        if !config.dualStackEnabled, persistedOwnership?.ipv6InterfaceName != nil {
            throw FlannelVXLANError.runtime(
                "dual-stack is disabled but persisted IPv6 tunnel ownership exists; run cleanup before migrating to IPv4-only mode"
            )
        }
        if !config.dualStackEnabled, persistedHostIPv6GatewayOwnership != nil {
            throw FlannelVXLANError.runtime(
                "dual-stack is disabled but persisted host IPv6 gateway ownership exists; run cleanup before migrating to IPv4-only mode"
            )
        }
        if !config.dualStackEnabled,
            try forwardingManager.ownedFamilies().contains(.ipv6)
        {
            _ = try forwardingManager.restore(.ipv6)
        }
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

        let networkConfig: FlannelNetworkConfig
        do {
            networkConfig = try FlannelConfigParser.parse(configMap: configMap, key: config.networkConfigKey)
        } catch {
            let validationError = error
            if config.dualStackEnabled {
                try await withdrawIPv6ForInvalidIntent(
                    validationError: validationError,
                    persistedOwnership: persistedOwnership
                )
            }
            throw validationError
        }
        try networkConfig.backend.validateWindowsCompatibility()
        var compilationConfig = networkConfig
        if !config.dualStackEnabled {
            compilationConfig.enableIPv6 = false
        }
        let compilation = try FlannelPeerCompiler.compile(
            nodes: nodes,
            localNodeName: config.nodeName,
            networkConfig: compilationConfig,
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
        let ipv6Context: IPv6ReconcileContext?
        do {
            ipv6Context = try validatedIPv6Context(
                runtimeState: runtimeState,
                networkConfig: networkConfig,
                compilation: compilation
            )
        } catch {
            let validationError = error
            try await withdrawIPv6ForInvalidIntent(
                validationError: validationError,
                persistedOwnership: persistedOwnership
            )
            throw validationError
        }
        let persistedIPv6Ownership =
            ipv6Context != nil && persistedOwnership?.ipv6InterfaceName != nil
            ? persistedOwnership
            : nil
        var unresolvedPersistedIPv6Ownership = persistedIPv6Ownership
        if let persistedIPv6Ownership,
            let ipv6Tunnel,
            let ipv6TunnelConfiguration,
            ipv6Tunnel.interfaceName == persistedIPv6Ownership.ipv6InterfaceName,
            ipv6TunnelConfiguration.localPodCIDR == persistedIPv6Ownership.localIPv6PodCIDR
        {
            installedIPv6Routes.formUnion(persistedIPv6Ownership.ipv6RoutePodCIDRs ?? [])
            unresolvedPersistedIPv6Ownership = nil
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
        let networkResult: FlannelHostOnlyNetworkReconcileResult
        if let ipv6Context {
            networkResult = try await networkManager.ensureHostOnlyNetwork(
                name: config.networkName,
                podCIDR: localNetwork.podCIDR,
                ipv6PodCIDR: ipv6Context.localNetwork.podCIDR,
                plugin: config.networkPlugin,
                variant: config.networkVariant,
                knownOwnership: knownNetworkOwnership
            )
        } else {
            networkResult = try await networkManager.ensureHostOnlyNetwork(
                name: config.networkName,
                podCIDR: localNetwork.podCIDR,
                plugin: config.networkPlugin,
                variant: config.networkVariant,
                knownOwnership: knownNetworkOwnership
            )
        }
        if let ownership = networkResult.ownership {
            try networkOwnershipStateStore.save(ownership)
        } else if knownNetworkOwnership != nil {
            try networkOwnershipStateStore.remove()
        }
        var hostIPv6GatewayIssues: [FlannelCompileIssue] = []
        var hostIPv6GatewayHardFailure = false
        if ipv6Context != nil {
            if let networkOwnership = networkResult.ownership {
                do {
                    let gatewayResult = try hostIPv6GatewayManager.reconcile(
                        networkOwnership: networkOwnership,
                        knownOwnership: persistedHostIPv6GatewayOwnership
                    )
                    switch gatewayResult {
                    case .bridgePending:
                        hostIPv6GatewayIssues.append(
                            FlannelCompileIssue(
                                id: "local/host-ipv6-gateway",
                                severity: .warning,
                                message: "host IPv6 gateway is waiting for the first vmnet bridge attachment"
                            ))
                    case .dadPending(let ownership):
                        try hostIPv6GatewayOwnershipStore.save(ownership)
                        hostIPv6GatewayIssues.append(
                            FlannelCompileIssue(
                                id: "local/host-ipv6-gateway",
                                severity: .warning,
                                message: "host IPv6 gateway is waiting for duplicate address detection"
                            ))
                    case .ready(let ownership):
                        try hostIPv6GatewayOwnershipStore.save(ownership)
                    }
                } catch {
                    hostIPv6GatewayHardFailure = true
                    hostIPv6GatewayIssues.append(
                        FlannelCompileIssue(
                            id: "local/host-ipv6-gateway",
                            severity: .error,
                            message: "host IPv6 gateway reconciliation failed: \(error)"
                        ))
                }
            } else {
                hostIPv6GatewayHardFailure = true
                hostIPv6GatewayIssues.append(
                    FlannelCompileIssue(
                        id: "local/host-ipv6-gateway",
                        severity: .error,
                        message: "host IPv6 gateway requires an owned host-only Pod network"
                    ))
            }
        }
        try forwardingManager.ensureEnabled(.ipv4)

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
        try saveOwnershipState(
            localNetwork: localNetwork,
            preservingIPv6Ownership: persistedIPv6Ownership
        )

        var issues = compilation.issues + hostIPv6GatewayIssues
        var ipv6Ready: Bool? = config.dualStackEnabled ? false : nil
        var ipv6Dataplane: IPv6DataplaneResult?
        if let ipv6Context {
            var ipv6FamilyHardFailure = hostIPv6GatewayHardFailure
            var priorDataplaneWithdrawalFailure: String?
            if ipv6Context.localNetwork.internalIPv6 == nil {
                issues.append(
                    FlannelCompileIssue(
                        id: "local/internal-ipv6",
                        severity: .warning,
                        message: "Node has no usable InternalIPv6; using IPv6 address from underlay interface \(underlay.name)"
                    ))
            }
            if !ipv6FamilyHardFailure, let unresolvedOwnership = unresolvedPersistedIPv6Ownership {
                do {
                    try deactivateIPv6Dataplane(persistedOwnership: unresolvedOwnership)
                    unresolvedPersistedIPv6Ownership = nil
                } catch {
                    ipv6FamilyHardFailure = true
                    let cleanupError = error
                    priorDataplaneWithdrawalFailure = "withdraw IPv6 routes and tunnel: \(cleanupError)"
                    issues.append(
                        FlannelCompileIssue(
                            id: "local/ipv6-dataplane",
                            severity: .error,
                            message: "IPv6 dataplane is degraded while recovering persisted ownership: \(cleanupError)"
                        ))
                }
            }
            if !ipv6FamilyHardFailure, unresolvedPersistedIPv6Ownership == nil {
                do {
                    ipv6Dataplane = try reconcileIPv6Dataplane(
                        context: ipv6Context,
                        underlay: underlay,
                        networkConfig: networkConfig,
                        peers: compilation.ipv6Peers,
                        mtu: mtu
                    )
                    ipv6Ready = true
                } catch {
                    ipv6FamilyHardFailure = true
                    let dataplaneError = error
                    issues.append(
                        FlannelCompileIssue(
                            id: "local/ipv6-dataplane",
                            severity: .error,
                            message: "IPv6 dataplane is degraded: \(dataplaneError)"
                        ))
                }
            }
            if ipv6FamilyHardFailure {
                var cleanupOwnership = unresolvedPersistedIPv6Ownership ?? persistedIPv6Ownership
                do {
                    cleanupOwnership =
                        try snapshotActiveIPv6Ownership(localNetwork: localNetwork)
                        ?? cleanupOwnership
                } catch {
                    issues.append(
                        FlannelCompileIssue(
                            id: "local/ipv6-dataplane-cleanup",
                            severity: .error,
                            message: "IPv6 dataplane ownership snapshot failed before family withdrawal: \(error)"
                        ))
                }
                let withdrawal = withdrawIPv6FamilyResources(
                    persistedOwnership: cleanupOwnership,
                    priorDataplaneFailure: priorDataplaneWithdrawalFailure
                )
                unresolvedPersistedIPv6Ownership = withdrawal.dataplaneDeactivated ? nil : cleanupOwnership
                ipv6Dataplane = nil
                ipv6Ready = false
                if !withdrawal.failures.isEmpty {
                    if let dataplaneFailure = withdrawal.dataplaneFailure {
                        issues.append(
                            FlannelCompileIssue(
                                id: "local/ipv6-dataplane-cleanup",
                                severity: .error,
                                message: "IPv6 dataplane cleanup is incomplete: \(dataplaneFailure)"
                            ))
                    }
                    issues.append(
                        FlannelCompileIssue(
                            id: "local/ipv6-family-withdrawal",
                            severity: .error,
                            message: "IPv6 family withdrawal is incomplete: "
                                + withdrawal.failures.joined(separator: "; ")
                                + "; IPv4 dataplane was retained"
                        ))
                }
            }
            try saveOwnershipState(
                localNetwork: localNetwork,
                preservingIPv6Ownership: unresolvedPersistedIPv6Ownership
            )
        }

        let ipv4TunnelUp = tunnel.isRunning
        if !ipv4TunnelUp {
            var withdrawalFailures: [String] = []
            do {
                try clearReadyState()
            } catch {
                withdrawalFailures.append("clear ready lease: \(error)")
            }
            do {
                _ = try await removeNodeAnnotationsWithRetry()
            } catch {
                withdrawalFailures.append("remove Node annotations: \(error)")
            }
            let suffix =
                withdrawalFailures.isEmpty
                ? ""
                : "; readiness withdrawal incomplete: \(withdrawalFailures.joined(separator: "; "))"
            throw FlannelVXLANError.runtime(
                "IPv4 tunnel stopped before readiness publication\(suffix)"
            )
        }
        let ipv6TunnelUp: Bool?
        if config.dualStackEnabled {
            let running = ipv6Tunnel?.isRunning ?? false
            if ipv6Ready == true, !running {
                do {
                    try clearReadyState()
                } catch {
                    issues.append(
                        FlannelCompileIssue(
                            id: "local/ipv6-ready-withdrawal",
                            severity: .error,
                            message: "IPv6 readiness lease withdrawal failed before degraded publication: \(error)"
                        ))
                }
                ipv6Ready = false
                ipv6Dataplane = nil
                issues.append(
                    FlannelCompileIssue(
                        id: "local/ipv6-tunnel-stopped",
                        severity: .error,
                        message: "IPv6 tunnel stopped before readiness publication; IPv4 dataplane was retained"
                    ))
            }
            ipv6TunnelUp = running
        } else {
            ipv6TunnelUp = nil
        }

        var annotationPatch = try FlannelKubernetesClient.leaseAnnotationPatch(
            annotationPrefix: config.annotationPrefix,
            publicIP: underlay.ipv4Address,
            vni: networkConfig.backend.vni,
            vtepMAC: vtepMAC,
            publicIPv6: ipv6Ready == true ? ipv6Dataplane?.publicIPv6 : nil,
            vtepMACIPv6: ipv6Ready == true ? ipv6Dataplane?.vtepMAC : nil
        )
        if ipv6Ready != true {
            let keys = try FlannelAnnotationKeys(prefix: config.annotationPrefix)
            annotationPatch.removals.formUnion([keys.publicIPv6, keys.backendV6Data])
        }
        _ = try await kubernetes.patchOwnNodeAnnotations(annotationPatch)

        let readyAtUnixSeconds = Int64(now().timeIntervalSince1970.rounded(.down))
        let leaseDurationSeconds = Int64(max(15, config.syncPeriodSeconds * 4))
        let readyState: PodNetworkReadyState
        if let ipv6Context {
            readyState = PodNetworkReadyState(
                networkName: config.networkName,
                podCIDRs: PodNetworkCIDRs(
                    ipv4: localNetwork.podCIDR,
                    ipv6: ipv6Context.localNetwork.podCIDR
                ),
                runtimeGeneration: runtimeState.generation,
                mtu: UInt32(mtu),
                expiresAtUnixSeconds: readyAtUnixSeconds + leaseDurationSeconds,
                ipv4Ready: true,
                ipv6Ready: ipv6Ready
            )
        } else {
            readyState = PodNetworkReadyState(
                networkName: config.networkName,
                podCIDR: localNetwork.podCIDR,
                runtimeGeneration: runtimeState.generation,
                mtu: UInt32(mtu),
                expiresAtUnixSeconds: readyAtUnixSeconds + leaseDurationSeconds
            )
        }
        try await podNetworkStateStore.writeReadyState(
            readyState,
            path: config.readyStatePath
        )
        return FlannelVXLANReconcileResult(
            runtimeGeneration: runtimeState.generation,
            localNetwork: localNetwork,
            underlay: underlay,
            interfaceName: tunnel.interfaceName,
            mtu: mtu,
            peers: compilation.peers,
            routeCount: installedRoutes.count,
            tunnelUp: ipv4TunnelUp,
            tunnelEpoch: tunnelEpoch,
            localIPv6Network: ipv6Context?.localNetwork,
            ipv6InterfaceName: ipv6Tunnel?.interfaceName,
            ipv6Peers: compilation.ipv6Peers,
            ipv6RouteCount: config.dualStackEnabled ? installedIPv6Routes.count : nil,
            ipv6TunnelUp: ipv6TunnelUp,
            ipv6TunnelEpoch: config.dualStackEnabled ? ipv6TunnelEpoch : nil,
            ipv4Ready: true,
            ipv6Ready: ipv6Ready,
            issues: issues.sorted(),
            statistics: tunnel.statistics(),
            ipv6Statistics: ipv6Tunnel?.statistics()
        )
    }

    private func validatedIPv6Context(
        runtimeState: PodNetworkRuntimeState,
        networkConfig: FlannelNetworkConfig,
        compilation: FlannelPeerCompilation
    ) throws -> IPv6ReconcileContext? {
        guard config.dualStackEnabled else {
            return nil
        }
        guard networkConfig.enableIPv6 else {
            throw FlannelVXLANError.invalidNetworkConfig(
                "dual-stack is enabled locally but Flannel EnableIPv6 is false"
            )
        }
        guard let runtimeValue = runtimeState.podCIDRs.ipv6,
            let runtimeCIDR = FlannelIPv6.parseCIDR(runtimeValue),
            runtimeCIDR.prefixLength > 0,
            runtimeCIDR.network.isUsableUnderlayAddress
        else {
            throw FlannelVXLANError.runtime("waiting for kubelet to publish a valid local IPv6 PodCIDR")
        }
        guard let localNetwork = compilation.localIPv6Network,
            let localCIDR = FlannelIPv6.parseCIDR(localNetwork.podCIDR),
            localCIDR.prefixLength > 0,
            localCIDR.network.isUsableUnderlayAddress
        else {
            throw FlannelVXLANError.runtime("waiting for Node \(config.nodeName) to publish its IPv6 PodCIDR")
        }
        guard runtimeCIDR == localCIDR else {
            throw FlannelVXLANError.runtime(
                "kubelet IPv6 PodCIDR \(runtimeValue) does not match Node IPv6 PodCIDR \(localNetwork.podCIDR)"
            )
        }
        return IPv6ReconcileContext(localNetwork: localNetwork, localCIDR: localCIDR)
    }

    private func reconcileIPv6Dataplane(
        context: IPv6ReconcileContext,
        underlay: FlannelUnderlayInterface,
        networkConfig: FlannelNetworkConfig,
        peers: [FlannelIPv6Peer],
        mtu: Int
    ) throws -> IPv6DataplaneResult {
        guard let rawUnderlayIPv6 = underlay.ipv6Address,
            let underlayIPv6 = FlannelIPv6.parseAddress(rawUnderlayIPv6),
            underlayIPv6.isUsableUnderlayAddress
        else {
            throw FlannelVXLANError.runtime("underlay interface \(underlay.name) has no usable IPv6 address")
        }
        if let rawNodeIPv6 = context.localNetwork.internalIPv6 {
            guard let nodeIPv6 = FlannelIPv6.parseAddress(rawNodeIPv6),
                nodeIPv6.isUsableUnderlayAddress,
                nodeIPv6 == underlayIPv6
            else {
                throw FlannelVXLANError.runtime(
                    "Node InternalIPv6 \(rawNodeIPv6) does not match \(underlay.name) address \(underlayIPv6.string)"
                )
            }
        }
        guard (1_280...9_000).contains(mtu) else {
            throw FlannelVXLANError.invalidNetworkConfig(
                "calculated IPv6 inner MTU \(mtu) is outside 1280...9000"
            )
        }
        let maximumIPv6InnerMTU = underlay.mtu - 70
        guard mtu <= maximumIPv6InnerMTU else {
            let maximumBackendMTU = underlay.mtu - 20
            throw FlannelVXLANError.invalidNetworkConfig(
                "calculated inner MTU \(mtu) exceeds the IPv6 VXLAN limit \(maximumIPv6InnerMTU) for underlay MTU \(underlay.mtu); set Backend.MTU to \(maximumBackendMTU) or lower so the shared inner MTU accounts for 70-byte IPv6 VXLAN overhead"
            )
        }
        for publicIPv6 in Set(peers.map(\.publicIPv6)).sorted() {
            try system.validateIPv6UnderlayRoute(destination: publicIPv6, interface: underlay.name)
        }

        try forwardingManager.ensureEnabled(.ipv6)
        let vtepMAC = try vtepMACIPv6Store.loadOrCreate()
        let desiredConfiguration = FlannelIPv6TunnelConfiguration(
            vni: networkConfig.backend.vni,
            port: networkConfig.backend.port,
            mtu: mtu,
            bindIPv6: underlayIPv6.string,
            localPodCIDR: context.localCIDR.string,
            localVTEPMAC: vtepMAC
        )
        try replaceIPv6TunnelIfNeeded(configuration: desiredConfiguration)
        guard let ipv6Tunnel else {
            throw FlannelVXLANError.runtime("IPv6 tunnel was not created")
        }
        try ipv6Tunnel.setPeers(peers)
        try reconcileIPv6Routes(
            desired: Set(peers.map(\.podCIDR)),
            interface: ipv6Tunnel.interfaceName
        )
        return IPv6DataplaneResult(publicIPv6: underlayIPv6.string, vtepMAC: vtepMAC)
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
        tunnelEpoch += 1
    }

    private func replaceIPv6TunnelIfNeeded(configuration: FlannelIPv6TunnelConfiguration) throws {
        guard
            ipv6Tunnel == nil || ipv6TunnelConfiguration != configuration || ipv6Tunnel?.isRunning == false
        else {
            return
        }
        try removeAllIPv6Routes()
        ipv6Tunnel?.stop()
        guard ipv6Tunnel?.isRunning != true else {
            throw FlannelVXLANError.runtime("failed to stop the existing IPv6 tunnel")
        }
        ipv6Tunnel?.destroy()
        ipv6Tunnel = nil
        ipv6TunnelConfiguration = nil

        let created = try makeIPv6Tunnel(configuration)
        do {
            guard let localCIDR = FlannelIPv6.parseCIDR(configuration.localPodCIDR) else {
                throw FlannelVXLANError.invalidConfiguration("local PodCIDR is not valid IPv6")
            }
            try system.configureIPv6TunnelInterface(
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
        ipv6Tunnel = created
        ipv6TunnelConfiguration = configuration
        ipv6TunnelEpoch += 1
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

    private func reconcileIPv6Routes(desired: Set<String>, interface: String) throws {
        for podCIDR in installedIPv6Routes.subtracting(desired).sorted() {
            try system.removeIPv6Route(podCIDR: podCIDR, interface: interface)
            installedIPv6Routes.remove(podCIDR)
        }
        for podCIDR in desired.sorted() {
            try system.ensureIPv6Route(podCIDR: podCIDR, interface: interface)
            installedIPv6Routes.insert(podCIDR)
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

    private func removeAllIPv6Routes(interface explicitInterface: String? = nil) throws {
        guard let interface = explicitInterface ?? ipv6Tunnel?.interfaceName else {
            guard installedIPv6Routes.isEmpty else {
                throw FlannelVXLANError.runtime("cannot remove IPv6 routes without a tunnel interface")
            }
            return
        }
        for podCIDR in installedIPv6Routes.sorted() {
            try system.removeIPv6Route(podCIDR: podCIDR, interface: interface)
            installedIPv6Routes.remove(podCIDR)
        }
    }

    private func deactivateIPv6Dataplane(
        persistedOwnership: FlannelOwnershipState? = nil
    ) throws {
        let activeInterface = ipv6Tunnel?.interfaceName
        let persistedInterface = persistedOwnership?.ipv6InterfaceName
        if let activeInterface, let persistedInterface, activeInterface != persistedInterface {
            throw FlannelVXLANError.runtime(
                "active IPv6 tunnel \(activeInterface) does not match persisted ownership \(persistedInterface)"
            )
        }
        installedIPv6Routes.formUnion(persistedOwnership?.ipv6RoutePodCIDRs ?? [])
        let ownedInterface = activeInterface ?? persistedInterface
        try removeAllIPv6Routes(interface: ownedInterface)

        guard let stoppingTunnel = ipv6Tunnel else {
            if let ownedInterface, ownedInterface == tunnel?.interfaceName {
                ipv6TunnelConfiguration = nil
                return
            }
            if let ownedInterface, try system.interfaceExists(ownedInterface) {
                throw FlannelVXLANError.runtime(
                    "persisted IPv6 tunnel interface \(ownedInterface) is active but is not controlled by this process"
                )
            }
            ipv6TunnelConfiguration = nil
            return
        }
        stoppingTunnel.stop()
        guard !stoppingTunnel.isRunning else {
            throw FlannelVXLANError.runtime(
                "IPv6 tunnel \(stoppingTunnel.interfaceName) is still running after stop"
            )
        }
        let stoppedInterface = stoppingTunnel.interfaceName
        stoppingTunnel.destroy()
        ipv6Tunnel = nil
        ipv6TunnelConfiguration = nil
        if try system.interfaceExists(stoppedInterface) {
            throw FlannelVXLANError.runtime(
                "IPv6 tunnel interface \(stoppedInterface) still exists after destroy"
            )
        }
    }

    private func withdrawIPv6FamilyResources(
        persistedOwnership: FlannelOwnershipState?,
        priorDataplaneFailure: String? = nil
    ) -> IPv6FamilyWithdrawalResult {
        var failures: [String] = []
        var dataplaneDeactivated = false
        var dataplaneFailure = priorDataplaneFailure

        if let priorDataplaneFailure {
            failures.append(priorDataplaneFailure)
        } else {
            do {
                try deactivateIPv6Dataplane(persistedOwnership: persistedOwnership)
                dataplaneDeactivated = true
            } catch {
                let message = "withdraw IPv6 routes and tunnel: \(error)"
                dataplaneFailure = message
                failures.append(message)
            }
        }

        do {
            // Re-read after dataplane reconciliation because gateway reconciliation may have
            // persisted write-ahead ownership after this controller's initial snapshot.
            if let currentGatewayOwnership = try hostIPv6GatewayOwnershipStore.load() {
                try hostIPv6GatewayManager.remove(ownership: currentGatewayOwnership)
                try hostIPv6GatewayOwnershipStore.remove()
            }
        } catch {
            failures.append("remove owned host IPv6 gateway: \(error)")
        }

        do {
            _ = try forwardingManager.restore(.ipv6)
        } catch {
            failures.append("restore IPv6 forwarding: \(error)")
        }

        return IPv6FamilyWithdrawalResult(
            dataplaneDeactivated: dataplaneDeactivated,
            dataplaneFailure: dataplaneFailure,
            failures: failures
        )
    }

    private func withdrawIPv6ForInvalidIntent(
        validationError: Error,
        persistedOwnership: FlannelOwnershipState?
    ) async throws {
        var failures: [String] = []
        var annotationsRemoved = false
        let withdrawal = withdrawIPv6FamilyResources(persistedOwnership: persistedOwnership)
        failures.append(contentsOf: withdrawal.failures)

        do {
            let keys = try FlannelAnnotationKeys(prefix: config.annotationPrefix)
            _ = try await kubernetes.patchOwnNodeAnnotations(
                FlannelNodeAnnotationPatch(removals: [keys.publicIPv6, keys.backendV6Data])
            )
            annotationsRemoved = true
        } catch {
            failures.append("remove IPv6 Node annotations: \(error)")
        }

        do {
            try persistOwnershipAfterIPv6Withdrawal(
                persistedOwnership: persistedOwnership,
                withdrawalCompleted: withdrawal.dataplaneDeactivated && annotationsRemoved
            )
        } catch {
            failures.append("persist IPv6 withdrawal ownership: \(error)")
        }

        guard failures.isEmpty else {
            throw FlannelVXLANError.runtime(
                "IPv6 intent validation failed: \(validationError); IPv6 family withdrawal incomplete: "
                    + failures.joined(separator: "; ")
                    + "; IPv4 dataplane was retained"
            )
        }
    }

    private func persistOwnershipAfterIPv6Withdrawal(
        persistedOwnership: FlannelOwnershipState?,
        withdrawalCompleted: Bool
    ) throws {
        guard let interfaceName = tunnel?.interfaceName ?? persistedOwnership?.interfaceName,
            let localPodCIDR = tunnelConfiguration?.localPodCIDR ?? persistedOwnership?.localPodCIDR
        else {
            return
        }

        let routePodCIDRs = installedRoutes.union(persistedOwnership?.routePodCIDRs ?? []).sorted()
        let ipv6InterfaceName: String?
        let localIPv6PodCIDR: String?
        let ipv6RoutePodCIDRs: [String]?
        if withdrawalCompleted {
            ipv6InterfaceName = nil
            localIPv6PodCIDR = nil
            ipv6RoutePodCIDRs = nil
        } else {
            ipv6InterfaceName = ipv6Tunnel?.interfaceName ?? persistedOwnership?.ipv6InterfaceName
            localIPv6PodCIDR = ipv6TunnelConfiguration?.localPodCIDR ?? persistedOwnership?.localIPv6PodCIDR
            if ipv6InterfaceName != nil, localIPv6PodCIDR != nil {
                ipv6RoutePodCIDRs =
                    installedIPv6Routes
                    .union(persistedOwnership?.ipv6RoutePodCIDRs ?? [])
                    .sorted()
            } else {
                ipv6RoutePodCIDRs = nil
            }
        }

        try ownershipStateStore.save(
            FlannelOwnershipState(
                interfaceName: interfaceName,
                localPodCIDR: localPodCIDR,
                routePodCIDRs: routePodCIDRs,
                ipv6InterfaceName: ipv6InterfaceName,
                localIPv6PodCIDR: localIPv6PodCIDR,
                ipv6RoutePodCIDRs: ipv6RoutePodCIDRs
            ))
    }

    private func saveOwnershipState(
        localNetwork: FlannelLocalNodeNetwork,
        preservingIPv6Ownership persistedOwnership: FlannelOwnershipState? = nil
    ) throws {
        guard let tunnel else {
            throw FlannelVXLANError.runtime("cannot persist ownership without an IPv4 tunnel")
        }
        var ipv6InterfaceName: String?
        var localIPv6PodCIDR: String?
        var ipv6RoutePodCIDRs: [String]?
        switch (ipv6Tunnel, ipv6TunnelConfiguration) {
        case (nil, nil):
            ipv6InterfaceName = nil
            localIPv6PodCIDR = nil
            ipv6RoutePodCIDRs = nil
        case (.some(let ipv6Tunnel), .some(let configuration)):
            ipv6InterfaceName = ipv6Tunnel.interfaceName
            localIPv6PodCIDR = configuration.localPodCIDR
            ipv6RoutePodCIDRs = installedIPv6Routes.sorted()
        default:
            throw FlannelVXLANError.runtime("IPv6 tunnel ownership state is incomplete")
        }
        if let persistedInterface = persistedOwnership?.ipv6InterfaceName,
            let persistedLocalPodCIDR = persistedOwnership?.localIPv6PodCIDR,
            let persistedRoutes = persistedOwnership?.ipv6RoutePodCIDRs
        {
            ipv6InterfaceName = persistedInterface
            localIPv6PodCIDR = persistedLocalPodCIDR
            ipv6RoutePodCIDRs = persistedRoutes
        }
        try ownershipStateStore.save(
            FlannelOwnershipState(
                interfaceName: tunnel.interfaceName,
                localPodCIDR: localNetwork.podCIDR,
                routePodCIDRs: installedRoutes.sorted(),
                ipv6InterfaceName: ipv6InterfaceName,
                localIPv6PodCIDR: localIPv6PodCIDR,
                ipv6RoutePodCIDRs: ipv6RoutePodCIDRs
            ))
    }

    private func snapshotActiveIPv6Ownership(
        localNetwork: FlannelLocalNodeNetwork
    ) throws -> FlannelOwnershipState? {
        switch (ipv6Tunnel, ipv6TunnelConfiguration) {
        case (nil, nil):
            return nil
        case (.some(let ipv6Tunnel), .some(let configuration)):
            guard let tunnel else {
                throw FlannelVXLANError.runtime("cannot snapshot IPv6 ownership without an IPv4 tunnel")
            }
            return FlannelOwnershipState(
                interfaceName: tunnel.interfaceName,
                localPodCIDR: localNetwork.podCIDR,
                routePodCIDRs: installedRoutes.sorted(),
                ipv6InterfaceName: ipv6Tunnel.interfaceName,
                localIPv6PodCIDR: configuration.localPodCIDR,
                ipv6RoutePodCIDRs: installedIPv6Routes.sorted()
            )
        default:
            throw FlannelVXLANError.runtime("IPv6 tunnel ownership state is incomplete")
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
            keys.publicIPv6,
            keys.backendV6Data,
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
