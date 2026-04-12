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

import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerResource

struct SandboxNetworkPolicyTests {
    @Test
    func policyStateRoundTripsThroughCodable() throws {
        let policy = makePolicy()
        let state = try makeState(policy: policy)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SandboxNetworkPolicyState.self, from: data)

        #expect(decoded == state)
    }

    @Test
    func policyStoreRoundTripsState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let policy = makePolicy()
        let state = try makeState(policy: policy)

        try MacOSGuestNetworkPolicyStore.save(state, in: root)
        #expect(try MacOSGuestNetworkPolicyStore.load(from: root) == state)

        try MacOSGuestNetworkPolicyStore.remove(from: root)
        #expect(try MacOSGuestNetworkPolicyStore.load(from: root) == nil)
    }

    @Test
    func endpointIPv4ValidationDistinguishesIPv6Host() throws {
        #expect(SandboxNetworkPolicyEndpoint.ipv4CIDR(try CIDRv4("192.168.64.0/24")).isIPv4)
        #expect(SandboxNetworkPolicyEndpoint.ipv4Host(try IPAddress("192.168.64.2")).isIPv4)
        #expect(!SandboxNetworkPolicyEndpoint.ipv4Host(try IPAddress("fe80::1")).isIPv4)
    }

    @Test
    func policyEvaluationMatchesFirstApplicableRule() throws {
        let policy = makePolicy()

        let allowed = policy.evaluate(
            direction: .ingress,
            proto: .tcp,
            endpoint: try IPAddress("10.0.0.25"),
            port: 443
        )
        #expect(allowed.action == .allow)
        #expect(allowed.ruleID == "ingress-web")

        let denied = policy.evaluate(
            direction: .ingress,
            proto: .tcp,
            endpoint: try IPAddress("10.0.1.25"),
            port: 443
        )
        #expect(denied.action == .deny)
        #expect(denied.ruleID == nil)
    }

    @Test
    func policyEvaluationUsesGuestPortForPublishedIngress() throws {
        let policy = makePolicy()

        let hostPortOnly = policy.evaluate(
            direction: .ingress,
            proto: .tcp,
            endpoint: try IPAddress("10.0.0.25"),
            port: 8443
        )
        #expect(hostPortOnly.action == .deny)

        let guestPort = policy.evaluate(
            direction: .ingress,
            proto: .tcp,
            endpoint: try IPAddress("10.0.0.25"),
            port: 443
        )
        #expect(guestPort.action == .allow)
    }

    @Test
    func auditEventRoundTripsThroughCodable() throws {
        let event = SandboxNetworkAuditEvent(
            timestamp: Date(timeIntervalSince1970: 1_776_000_000),
            sandboxID: "sandbox-1",
            networkID: "default",
            policyGeneration: 7,
            direction: .ingress,
            proto: .tcp,
            sourceIP: try IPAddress("10.0.0.25"),
            sourcePort: 50000,
            destinationIP: try IPAddress("192.168.64.2"),
            destinationPort: 443,
            action: .deny,
            ruleID: "block-web",
            enforcementSource: .publishedPort
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SandboxNetworkAuditEvent.self, from: data)

        #expect(decoded == event)
    }

    private func makePolicy() -> SandboxNetworkPolicy {
        SandboxNetworkPolicy(
            sandboxID: "sandbox-1",
            generation: 1,
            ingressACL: [
                SandboxNetworkPolicyRule(
                    id: "ingress-web",
                    action: .allow,
                    protocols: [.tcp],
                    endpoints: [
                        .ipv4CIDR(try! CIDRv4("10.0.0.0/24"))
                    ],
                    ports: [
                        .single(443)
                    ]
                )
            ],
            egressACL: [
                SandboxNetworkPolicyRule(
                    id: "egress-dns",
                    action: .allow,
                    protocols: [.udp],
                    endpoints: [
                        .ipv4Host(try! IPAddress("9.9.9.9"))
                    ],
                    ports: [
                        .single(53)
                    ]
                )
            ],
            defaultAction: .deny,
            auditMode: .all
        )
    }

    private func makeState(policy: SandboxNetworkPolicy) throws -> SandboxNetworkPolicyState {
        SandboxNetworkPolicyState(
            sandboxID: policy.sandboxID,
            networkID: "default",
            ipv4Address: try IPAddress("192.168.64.2"),
            macAddress: try MACAddress("02:42:ac:11:00:02"),
            generation: policy.generation,
            policy: policy,
            renderedHostRuleIdentifiers: [],
            lastApplyResult: .stored
        )
    }
}
