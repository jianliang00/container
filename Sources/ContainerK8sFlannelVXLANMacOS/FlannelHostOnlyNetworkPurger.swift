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

import Darwin
import Foundation

public struct FlannelHostOnlyNetworkPurgeCheckResult: Sendable, Equatable {
    public var ownedNetworkName: String?
    public var networkWasPresent: Bool
    public var referringObjectIDs: [String]

    public init(
        ownedNetworkName: String?,
        networkWasPresent: Bool,
        referringObjectIDs: [String]
    ) {
        self.ownedNetworkName = ownedNetworkName
        self.networkWasPresent = networkWasPresent
        self.referringObjectIDs = referringObjectIDs
    }
}

public struct FlannelHostOnlyNetworkPurger: Sendable {
    private let networkManager: any FlannelNetworkManaging
    private let attachmentInspector: any FlannelNetworkAttachmentInspecting
    private let dataplaneOwnershipStore: any FlannelOwnershipStateStoring
    private let forwardingOwnershipStore: any FlannelForwardingOwnershipStoring
    private let networkOwnershipStore: any FlannelHostOnlyNetworkOwnershipStoring
    private let hostIPv6GatewayManager: any FlannelHostIPv6GatewayManaging
    private let hostIPv6GatewayOwnershipStore: any FlannelHostIPv6GatewayOwnershipStoring

    public init(
        config: FlannelVXLANMacOSConfig,
        networkManager: any FlannelNetworkManaging = ContainerKitFlannelNetworkManager(),
        attachmentInspector: any FlannelNetworkAttachmentInspecting = ContainerKitFlannelNetworkAttachmentInspector()
    ) {
        let gatewayStore = FlannelHostIPv6GatewayOwnershipStore(
            path: config.hostIPv6GatewayOwnershipStatePath
        )
        self.init(
            networkManager: networkManager,
            attachmentInspector: attachmentInspector,
            dataplaneOwnershipStore: FlannelOwnershipStateStore(path: config.ownershipStatePath),
            forwardingOwnershipStore: FlannelForwardingOwnershipStore(
                path: config.forwardingOwnershipStatePath
            ),
            networkOwnershipStore: FlannelHostOnlyNetworkOwnershipStore(path: config.networkOwnershipStatePath),
            hostIPv6GatewayManager: SystemFlannelHostIPv6GatewayManager(ownershipStore: gatewayStore),
            hostIPv6GatewayOwnershipStore: gatewayStore
        )
    }

    public init(
        networkManager: any FlannelNetworkManaging,
        attachmentInspector: any FlannelNetworkAttachmentInspecting = ContainerKitFlannelNetworkAttachmentInspector(),
        dataplaneOwnershipStore: any FlannelOwnershipStateStoring,
        forwardingOwnershipStore: any FlannelForwardingOwnershipStoring,
        networkOwnershipStore: any FlannelHostOnlyNetworkOwnershipStoring,
        hostIPv6GatewayManager: (any FlannelHostIPv6GatewayManaging)? = nil,
        hostIPv6GatewayOwnershipStore: (any FlannelHostIPv6GatewayOwnershipStoring)? = nil
    ) {
        self.networkManager = networkManager
        self.attachmentInspector = attachmentInspector
        self.dataplaneOwnershipStore = dataplaneOwnershipStore
        self.forwardingOwnershipStore = forwardingOwnershipStore
        self.networkOwnershipStore = networkOwnershipStore
        let resolvedGatewayStore =
            hostIPv6GatewayOwnershipStore
            ?? EmptyFlannelHostIPv6GatewayOwnershipStore()
        self.hostIPv6GatewayOwnershipStore = resolvedGatewayStore
        self.hostIPv6GatewayManager =
            hostIPv6GatewayManager
            ?? SystemFlannelHostIPv6GatewayManager(ownershipStore: resolvedGatewayStore)
    }

    @available(
        *,
        deprecated,
        message: "Pass forwardingOwnershipStore so network purge can verify host forwarding restoration."
    )
    public init(
        networkManager: any FlannelNetworkManaging,
        attachmentInspector: any FlannelNetworkAttachmentInspecting = ContainerKitFlannelNetworkAttachmentInspector(),
        dataplaneOwnershipStore: any FlannelOwnershipStateStoring,
        networkOwnershipStore: any FlannelHostOnlyNetworkOwnershipStoring,
        hostIPv6GatewayManager: (any FlannelHostIPv6GatewayManaging)? = nil,
        hostIPv6GatewayOwnershipStore: (any FlannelHostIPv6GatewayOwnershipStoring)? = nil
    ) {
        self.init(
            networkManager: networkManager,
            attachmentInspector: attachmentInspector,
            dataplaneOwnershipStore: dataplaneOwnershipStore,
            forwardingOwnershipStore: UnavailableFlannelForwardingOwnershipStore(),
            networkOwnershipStore: networkOwnershipStore,
            hostIPv6GatewayManager: hostIPv6GatewayManager,
            hostIPv6GatewayOwnershipStore: hostIPv6GatewayOwnershipStore
        )
    }

    public func checkPurge() async throws -> FlannelHostOnlyNetworkPurgeCheckResult {
        let (_, _, result) = try await preflight(requireDataplaneWithdrawal: false)
        return result
    }

    @discardableResult
    public func purge() async throws -> FlannelHostOnlyNetworkPurgeResult {
        let (ownership, gatewayOwnership, _) = try await preflight(requireDataplaneWithdrawal: true)
        guard let ownership else {
            return FlannelHostOnlyNetworkPurgeResult(networkWasPresent: false, removed: false)
        }

        try validateMutationState(expectedGatewayOwnership: gatewayOwnership)
        if let gatewayOwnership {
            try hostIPv6GatewayManager.remove(ownership: gatewayOwnership)
            try hostIPv6GatewayOwnershipStore.remove()
        }
        try validateMutationState(expectedGatewayOwnership: nil)
        let result = try await networkManager.purgeHostOnlyNetwork(ownership: ownership)
        try networkOwnershipStore.remove()
        return result
    }

    private func preflight(requireDataplaneWithdrawal: Bool) async throws -> (
        ownership: FlannelHostOnlyNetworkOwnership?,
        gatewayOwnership: FlannelHostIPv6GatewayOwnership?,
        result: FlannelHostOnlyNetworkPurgeCheckResult
    ) {
        let dataplaneOwnership = try dataplaneOwnershipStore.load()
        let forwardingOwnership = try forwardingOwnershipStore.load()
        let gatewayOwnership = try hostIPv6GatewayOwnershipStore.load()
        if requireDataplaneWithdrawal {
            guard dataplaneOwnership == nil else {
                throw FlannelVXLANError.runtime(
                    "refusing to purge the Pod network before Flannel withdrawal has removed dataplane ownership"
                )
            }
            guard forwardingOwnership == nil else {
                throw FlannelVXLANError.runtime(
                    "refusing to purge the Pod network before Flannel withdrawal has restored host forwarding"
                )
            }
        }
        guard let ownership = try networkOwnershipStore.load() else {
            guard dataplaneOwnership == nil else {
                throw FlannelVXLANError.runtime(
                    "refusing to check Pod network purge because dataplane ownership remains but network ownership is missing"
                )
            }
            guard gatewayOwnership == nil else {
                throw FlannelVXLANError.runtime(
                    "refusing to check Pod network purge because host IPv6 gateway ownership remains but network ownership is missing"
                )
            }
            guard forwardingOwnership == nil else {
                throw FlannelVXLANError.runtime(
                    "refusing to check Pod network purge because host forwarding ownership remains but network ownership is missing"
                )
            }
            return (
                nil,
                nil,
                FlannelHostOnlyNetworkPurgeCheckResult(
                    ownedNetworkName: nil,
                    networkWasPresent: false,
                    referringObjectIDs: []
                )
            )
        }
        if let gatewayOwnership {
            guard Self.gatewayOwnership(gatewayOwnership, matches: ownership) else {
                throw FlannelVXLANError.runtime(
                    "refusing to check Pod network purge because host IPv6 gateway ownership does not match the Pod network"
                )
            }
        }

        let networkWasPresent: Bool
        do {
            networkWasPresent = try await networkManager.validateOwnedHostOnlyNetwork(ownership: ownership)
        } catch {
            throw FlannelVXLANError.runtime(
                "refusing to purge network \(ownership.name) because its ownership could not be verified: \(error)"
            )
        }

        let referringObjectIDs: [String]
        do {
            referringObjectIDs = try await attachmentInspector.referringObjectIDs(networkName: ownership.name)
        } catch {
            throw FlannelVXLANError.runtime(
                "refusing to purge network \(ownership.name) because container and sandbox attachments could not be verified: \(error)"
            )
        }
        let stableObjectIDs = Array(Set(referringObjectIDs)).sorted()
        guard stableObjectIDs.isEmpty else {
            throw FlannelVXLANError.runtime(
                "refusing to purge network \(ownership.name) because it is still referenced by containers or sandboxes: "
                    + stableObjectIDs.joined(separator: ", ")
            )
        }

        return (
            ownership,
            gatewayOwnership,
            FlannelHostOnlyNetworkPurgeCheckResult(
                ownedNetworkName: ownership.name,
                networkWasPresent: networkWasPresent,
                referringObjectIDs: stableObjectIDs
            )
        )
    }

    private func validateMutationState(
        expectedGatewayOwnership: FlannelHostIPv6GatewayOwnership?
    ) throws {
        guard try dataplaneOwnershipStore.load() == nil else {
            throw FlannelVXLANError.runtime(
                "refusing to purge the Pod network because dataplane ownership appeared after preflight"
            )
        }
        guard try forwardingOwnershipStore.load() == nil else {
            throw FlannelVXLANError.runtime(
                "refusing to purge the Pod network because host forwarding ownership appeared after preflight"
            )
        }
        guard try hostIPv6GatewayOwnershipStore.load() == expectedGatewayOwnership else {
            throw FlannelVXLANError.runtime(
                "refusing to purge the Pod network because host IPv6 gateway ownership changed after preflight"
            )
        }
    }

    private static func gatewayOwnership(
        _ gatewayOwnership: FlannelHostIPv6GatewayOwnership,
        matches networkOwnership: FlannelHostOnlyNetworkOwnership
    ) -> Bool {
        gatewayOwnership.networkName == networkOwnership.name
            && gatewayOwnership.networkOwnershipID == networkOwnership.ownershipID.lowercased()
            && gatewayOwnership.ipv4PodCIDR == networkOwnership.podCIDR
            && gatewayOwnership.ipv6PodCIDR == networkOwnership.ipv6PodCIDR
    }
}

public enum FlannelOfflineForwardingRecoveryResult: Sendable, Equatable {
    case noForwardingOwnership
    case blockedByDataplaneState
    case restored([FlannelForwardingFamily])
}

public final class FlannelDaemonLifetimeLock: @unchecked Sendable {
    public static let defaultPath = FlannelVXLANMacOSConfig.defaultDaemonLifetimeLockPath

    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    public static func tryAcquire(path: String = defaultPath) throws -> FlannelDaemonLifetimeLock? {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw FlannelVXLANError.runtime(
                "failed to open daemon lifetime lock at \(path): \(posixErrorDescription())"
            )
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            let description = posixErrorDescription()
            close(descriptor)
            throw FlannelVXLANError.runtime(
                "failed to protect daemon lifetime lock at \(path): \(description)"
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return nil
            }
            throw FlannelVXLANError.runtime(
                "failed to acquire daemon lifetime lock at \(path): \(String(cString: strerror(lockError)))"
            )
        }
        return FlannelDaemonLifetimeLock(descriptor: descriptor)
    }

    public func release() {
        stateLock.withLock {
            guard descriptor >= 0 else {
                return
            }
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    func requireHeld() throws {
        guard stateLock.withLock({ descriptor >= 0 }) else {
            throw FlannelVXLANError.runtime("daemon lifetime lock was released before offline recovery")
        }
    }

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}

public struct FlannelOfflineForwardingRecovery: Sendable {
    private let dataplaneOwnershipStore: any FlannelOwnershipStateStoring
    private let forwardingOwnershipStore: any FlannelForwardingOwnershipStoring
    private let hostIPv6GatewayOwnershipStore: any FlannelHostIPv6GatewayOwnershipStoring
    private let forwardingManager: any FlannelForwardingManaging
    private let readyStateExists: @Sendable () throws -> Bool

    public init(config: FlannelVXLANMacOSConfig) {
        let forwardingOwnershipStore = FlannelForwardingOwnershipStore(
            path: config.forwardingOwnershipStatePath
        )
        self.init(
            dataplaneOwnershipStore: FlannelOwnershipStateStore(path: config.ownershipStatePath),
            forwardingOwnershipStore: forwardingOwnershipStore,
            hostIPv6GatewayOwnershipStore: FlannelHostIPv6GatewayOwnershipStore(
                path: config.hostIPv6GatewayOwnershipStatePath
            ),
            forwardingManager: SystemFlannelForwardingManager(
                ownershipStore: forwardingOwnershipStore
            ),
            readyStateExists: {
                try Self.statePathExists(config.readyStatePath)
            }
        )
    }

    init(
        dataplaneOwnershipStore: any FlannelOwnershipStateStoring,
        forwardingOwnershipStore: any FlannelForwardingOwnershipStoring,
        hostIPv6GatewayOwnershipStore: any FlannelHostIPv6GatewayOwnershipStoring,
        forwardingManager: any FlannelForwardingManaging,
        readyStateExists: @escaping @Sendable () throws -> Bool
    ) {
        self.dataplaneOwnershipStore = dataplaneOwnershipStore
        self.forwardingOwnershipStore = forwardingOwnershipStore
        self.hostIPv6GatewayOwnershipStore = hostIPv6GatewayOwnershipStore
        self.forwardingManager = forwardingManager
        self.readyStateExists = readyStateExists
    }

    public func restoreIfForwardingOnly(
        whileHolding lifetimeLock: FlannelDaemonLifetimeLock
    ) throws -> FlannelOfflineForwardingRecoveryResult {
        try lifetimeLock.requireHeld()
        guard let expectedForwardingOwnership = try forwardingOwnershipStore.load() else {
            return .noForwardingOwnership
        }
        guard try dataplaneOwnershipStore.load() == nil,
            try hostIPv6GatewayOwnershipStore.load() == nil,
            try !readyStateExists()
        else {
            return .blockedByDataplaneState
        }

        guard try forwardingOwnershipStore.load() == expectedForwardingOwnership,
            try dataplaneOwnershipStore.load() == nil,
            try hostIPv6GatewayOwnershipStore.load() == nil,
            try !readyStateExists()
        else {
            return .blockedByDataplaneState
        }
        return .restored(try forwardingManager.restoreAll())
    }

    private static func statePathExists(_ path: String) throws -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw FlannelVXLANError.runtime(
                "failed to inspect Flannel state at \(path): \(String(cString: strerror(errno)))"
            )
        }
        return true
    }
}

private struct EmptyFlannelHostIPv6GatewayOwnershipStore: FlannelHostIPv6GatewayOwnershipStoring {
    func load() throws -> FlannelHostIPv6GatewayOwnership? { nil }
    func save(_: FlannelHostIPv6GatewayOwnership) throws {}
    func remove() throws {}
}

private struct UnavailableFlannelForwardingOwnershipStore: FlannelForwardingOwnershipStoring {
    func load() throws -> FlannelForwardingOwnership? {
        throw FlannelVXLANError.runtime(
            "network purge requires an explicit forwarding ownership store"
        )
    }

    func save(_: FlannelForwardingOwnership) throws {
        throw FlannelVXLANError.runtime(
            "network purge requires an explicit forwarding ownership store"
        )
    }

    func remove() throws {
        throw FlannelVXLANError.runtime(
            "network purge requires an explicit forwarding ownership store"
        )
    }
}
