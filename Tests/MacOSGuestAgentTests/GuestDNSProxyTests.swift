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

#if os(macOS)
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import container_macos_guest_agent

struct GuestDNSProxyTests {
    @Test
    func buildsKubernetesSearchCandidatesUsingNDots() throws {
        let configuration = try GuestDNSProxy.ResolutionConfiguration(
            MacOSGuestDNSConfiguration(
                nameservers: ["10.96.0.10"],
                domain: "cluster.local",
                searchDomains: [
                    "workload.svc.cluster.local",
                    "svc.cluster.local",
                    "cluster.local",
                ],
                options: ["ndots:5", "timeout:2"]
            )
        )

        #expect(configuration.ndots == 5)
        #expect(configuration.timeoutSeconds == 2)
        #expect(
            configuration.candidates(for: try DNSWireName("kubernetes.default")).map(\.description) == [
                "kubernetes.default.workload.svc.cluster.local.",
                "kubernetes.default.svc.cluster.local.",
                "kubernetes.default.cluster.local.",
                "kubernetes.default.",
            ]
        )
    }

    @Test
    func doesNotExpandNamesAlreadyWithinSearchDomains() throws {
        let configuration = try GuestDNSProxy.ResolutionConfiguration(
            MacOSGuestDNSConfiguration(
                nameservers: ["10.96.0.10"],
                domain: nil,
                searchDomains: ["svc.cluster.local", "cluster.local"],
                options: ["ndots:5"]
            )
        )

        let name = try DNSWireName("kubernetes.default.svc.cluster.local")
        #expect(configuration.candidates(for: name).map(\.description) == [name.description])
    }

    @Test
    func triesSufficientlyQualifiedNamesBeforeSearchDomains() throws {
        let configuration = try GuestDNSProxy.ResolutionConfiguration(
            MacOSGuestDNSConfiguration(
                nameservers: ["10.96.0.10"],
                domain: nil,
                searchDomains: ["svc.cluster.local", "cluster.local"],
                options: ["ndots:2"]
            )
        )

        #expect(
            configuration.candidates(for: try DNSWireName("api.example.com")).map(\.description) == [
                "api.example.com.",
                "api.example.com.svc.cluster.local.",
                "api.example.com.cluster.local.",
            ]
        )
    }

    @Test
    func rewritesExpandedAResponseBackToOriginalQuestion() throws {
        let expanded = try DNSWireName("kubernetes.default.svc.cluster.local")
        let original = try DNSWireName("kubernetes.default")
        let query = makeAQuery(id: 0x1234, name: expanded)
        let response = makeAResponse(query: query, address: [10, 96, 0, 1])

        let rewritten = try DNSWireMessage.rewritingResponse(
            response,
            expandedName: expanded,
            originalName: original
        )
        let parsed = try DNSWireMessage(response: rewritten)

        #expect(parsed.questions.count == 1)
        #expect(parsed.questions[0].name.description == "kubernetes.default.")
        #expect(parsed.answers.count == 1)
        #expect(parsed.answers[0].name.description == "kubernetes.default.")
        guard case .bytes(let address) = parsed.answers[0].rdata[0] else {
            Issue.record("expected raw IPv4 response data")
            return
        }
        #expect(address == [10, 96, 0, 1])
    }

    @Test
    func replacesOnlyTheQuestionInQueriesWithAdditionalData() throws {
        let original = try DNSWireName("kubernetes.default")
        let expanded = try DNSWireName("kubernetes.default.svc.cluster.local")
        var query = makeAQuery(id: 0x4321, name: original)
        query[10] = 0
        query[11] = 1
        query.append(contentsOf: [0, 0, 41, 4, 208, 0, 0, 0, 0, 0, 0])

        let rewritten = try DNSWireMessage.replacingQuestionName(in: query, with: expanded)

        #expect(try DNSWireMessage.questionName(in: rewritten).description == expanded.description)
        #expect(Array(rewritten.suffix(11)) == [0, 0, 41, 4, 208, 0, 0, 0, 0, 0, 0])
    }

    @Test
    func readsEDNSPayloadSizeAndBuildsTruncatedResponse() throws {
        let name = try DNSWireName("large.default")
        var query = makeAQuery(id: 0x9876, name: name)
        query[10] = 0
        query[11] = 1
        query.append(contentsOf: [0, 0, 41, 4, 208, 0, 0, 0, 0, 0, 0])

        #expect(DNSWireMessage.udpPayloadSize(in: query) == 1_232)

        let response = DNSWireMessage.truncatedResponse(for: query)
        let parsed = try DNSWireMessage(response: response)
        #expect(parsed.id == 0x9876)
        #expect(parsed.flags & 0x8000 != 0)
        #expect(parsed.flags & 0x0200 != 0)
        #expect(parsed.flags & 0x0080 != 0)
        #expect(DNSWireMessage.isTruncated(response))
        #expect(parsed.questions.count == 1)
        #expect(parsed.questions[0].name == name)
        #expect(parsed.answers.isEmpty)
        #expect(parsed.additional.isEmpty)
    }

    @Test
    func usesClassicUDPPayloadSizeWithoutEDNS() throws {
        let query = makeAQuery(id: 1, name: try DNSWireName("kubernetes.default"))
        #expect(DNSWireMessage.udpPayloadSize(in: query) == 512)
    }
}

private func makeAQuery(id: UInt16, name: DNSWireName) -> [UInt8] {
    [
        UInt8((id >> 8) & 0xff), UInt8(id & 0xff),
        0x01, 0x00,
        0x00, 0x01,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    ] + name.encoded + [0x00, 0x01, 0x00, 0x01]
}

private func makeAResponse(query: [UInt8], address: [UInt8]) -> [UInt8] {
    var response = query
    response[2] = 0x81
    response[3] = 0x80
    response[6] = 0
    response[7] = 1
    response.append(contentsOf: [
        0xc0, 0x0c,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00, 0x00, 0x1e,
        0x00, 0x04,
    ])
    response.append(contentsOf: address)
    return response
}
#endif
