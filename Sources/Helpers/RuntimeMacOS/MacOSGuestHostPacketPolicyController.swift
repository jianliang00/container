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

import ContainerResource
import Foundation

struct MacOSGuestHostPacketPolicyController: Sendable {
    let root: URL

    func replace(with state: SandboxNetworkPolicyState) throws -> SandboxNetworkPolicyState {
        let ruleSet = SandboxNetworkHostRuleRenderer.render(state)
        try MacOSGuestHostNetworkPolicyStore.save(ruleSet, in: root)
        return SandboxNetworkPolicyState(
            sandboxID: state.sandboxID,
            networkID: state.networkID,
            ipv4Address: state.ipv4Address,
            macAddress: state.macAddress,
            generation: state.generation,
            policy: state.policy,
            renderedHostRuleIdentifiers: ruleSet.rules.map(\.id),
            lastApplyResult: state.lastApplyResult
        )
    }

    func remove() throws {
        try MacOSGuestHostNetworkPolicyStore.remove(from: root)
    }

    func status() throws -> SandboxNetworkHostRuleSet? {
        try MacOSGuestHostNetworkPolicyStore.load(from: root)
    }
}
