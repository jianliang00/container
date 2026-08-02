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
    private let networkOwnershipStore: any FlannelHostOnlyNetworkOwnershipStoring

    public init(
        config: FlannelVXLANMacOSConfig,
        networkManager: any FlannelNetworkManaging = ContainerKitFlannelNetworkManager(),
        attachmentInspector: any FlannelNetworkAttachmentInspecting = ContainerKitFlannelNetworkAttachmentInspector()
    ) {
        self.init(
            networkManager: networkManager,
            attachmentInspector: attachmentInspector,
            dataplaneOwnershipStore: FlannelOwnershipStateStore(path: config.ownershipStatePath),
            networkOwnershipStore: FlannelHostOnlyNetworkOwnershipStore(path: config.networkOwnershipStatePath)
        )
    }

    public init(
        networkManager: any FlannelNetworkManaging,
        attachmentInspector: any FlannelNetworkAttachmentInspecting = ContainerKitFlannelNetworkAttachmentInspector(),
        dataplaneOwnershipStore: any FlannelOwnershipStateStoring,
        networkOwnershipStore: any FlannelHostOnlyNetworkOwnershipStoring
    ) {
        self.networkManager = networkManager
        self.attachmentInspector = attachmentInspector
        self.dataplaneOwnershipStore = dataplaneOwnershipStore
        self.networkOwnershipStore = networkOwnershipStore
    }

    public func checkPurge() async throws -> FlannelHostOnlyNetworkPurgeCheckResult {
        let (_, result) = try await preflight(requireDataplaneWithdrawal: false)
        return result
    }

    @discardableResult
    public func purge() async throws -> FlannelHostOnlyNetworkPurgeResult {
        let (ownership, _) = try await preflight(requireDataplaneWithdrawal: true)
        guard let ownership else {
            return FlannelHostOnlyNetworkPurgeResult(networkWasPresent: false, removed: false)
        }

        let result = try await networkManager.purgeHostOnlyNetwork(ownership: ownership)
        try networkOwnershipStore.remove()
        return result
    }

    private func preflight(requireDataplaneWithdrawal: Bool) async throws -> (
        ownership: FlannelHostOnlyNetworkOwnership?,
        result: FlannelHostOnlyNetworkPurgeCheckResult
    ) {
        let dataplaneOwnership = try dataplaneOwnershipStore.load()
        if requireDataplaneWithdrawal {
            guard dataplaneOwnership == nil else {
                throw FlannelVXLANError.runtime(
                    "refusing to purge the Pod network before Flannel withdrawal has removed dataplane ownership"
                )
            }
        }
        guard let ownership = try networkOwnershipStore.load() else {
            guard dataplaneOwnership == nil else {
                throw FlannelVXLANError.runtime(
                    "refusing to check Pod network purge because dataplane ownership remains but network ownership is missing"
                )
            }
            return (
                nil,
                FlannelHostOnlyNetworkPurgeCheckResult(
                    ownedNetworkName: nil,
                    networkWasPresent: false,
                    referringObjectIDs: []
                )
            )
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
            FlannelHostOnlyNetworkPurgeCheckResult(
                ownedNetworkName: ownership.name,
                networkWasPresent: networkWasPresent,
                referringObjectIDs: stableObjectIDs
            )
        )
    }
}
