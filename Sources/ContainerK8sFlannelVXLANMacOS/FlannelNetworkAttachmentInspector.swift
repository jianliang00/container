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

import ContainerKit
import ContainerResource

public protocol FlannelNetworkAttachmentInspecting: Sendable {
    func referringObjectIDs(networkName: String) async throws -> [String]
}

public struct ContainerKitFlannelNetworkAttachmentInspector: FlannelNetworkAttachmentInspecting, Sendable {
    private let listContainers: @Sendable () async throws -> [ContainerSnapshot]

    public init(kit: ContainerKit = ContainerKit()) {
        self.listContainers = {
            try await kit.listContainers()
        }
    }

    init(listContainers: @escaping @Sendable () async throws -> [ContainerSnapshot]) {
        self.listContainers = listContainers
    }

    public func referringObjectIDs(networkName: String) async throws -> [String] {
        let containers = try await listContainers()
        return Self.referringObjectIDs(in: containers, networkName: networkName)
    }

    static func referringObjectIDs(
        in containers: [ContainerSnapshot],
        networkName: String
    ) -> [String] {
        let objectIDs = containers.compactMap { container -> String? in
            let configured = container.configuration.networks.contains { $0.network == networkName }
            let attached = container.networks.contains { $0.network == networkName }
            return configured || attached ? container.id : nil
        }
        return Array(Set(objectIDs)).sorted()
    }
}
