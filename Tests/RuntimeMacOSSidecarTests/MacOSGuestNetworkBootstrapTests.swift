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
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing

@testable import container_runtime_macos_sidecar

struct MacOSGuestNetworkBootstrapTests {
    @Test
    func vmnetSharedBuildsGuestNetworkRequest() throws {
        var config = makeConfiguration(backend: .vmnetShared)
        config.dns = .init(
            nameservers: ["9.9.9.9"],
            domain: "cluster.local",
            searchDomains: ["svc.cluster.local"],
            options: ["ndots:5"]
        )
        let lease = try makeLease(
            backend: .vmnetShared,
            hostname: "guest-1",
            mtu: 1_450,
            dns: .init(
                nameservers: ["9.9.9.9"],
                domain: "cluster.local",
                searchDomains: ["svc.cluster.local"],
                options: ["ndots:5"]
            )
        )

        let builtRequest = try MacOSGuestNetworkBootstrap.makeRequest(
            containerConfig: config,
            lease: lease
        )
        let request = try #require(builtRequest)

        #expect(request.primaryInterfaceIndex == 0)
        #expect(request.interfaces.count == 1)
        #expect(request.interfaces[0].networkID == "default")
        #expect(request.interfaces[0].hostname == "guest-1")
        #expect(request.interfaces[0].macAddress == "02:42:ac:11:00:02")
        #expect(request.interfaces[0].ipv4Address == "192.168.64.2")
        #expect(request.interfaces[0].ipv4PrefixLength == 24)
        #expect(request.interfaces[0].ipv4Gateway == "192.168.64.1")
        #expect(request.interfaces[0].mtu == 1_450)
        #expect(request.dns?.nameservers == ["9.9.9.9"])
        #expect(request.dns?.domain == "cluster.local")
        #expect(request.dns?.searchDomains == ["svc.cluster.local"])
        #expect(request.dns?.options == [])
    }

    @Test
    func acceptsGuestResultWithRequestedEffectiveMTU() throws {
        let request = makeGuestNetworkRequest(mtu: 1_450)
        let result = makeGuestNetworkResult(effectiveMTU: 1_450)

        try MacOSGuestNetworkBootstrap.validateResult(result, for: request)
    }

    @Test
    func acceptsLegacyGuestResultWhenMTUIsNotRequested() throws {
        let request = makeGuestNetworkRequest(mtu: nil)
        let result = makeGuestNetworkResult(effectiveMTU: nil)

        try MacOSGuestNetworkBootstrap.validateResult(result, for: request)
    }

    @Test
    func rejectsLegacyGuestResultWithoutEffectiveMTU() throws {
        let request = makeGuestNetworkRequest(mtu: 1_450)
        let legacyResult = makeGuestNetworkResult(effectiveMTU: nil)

        #expect(throws: (any Error).self) {
            try MacOSGuestNetworkBootstrap.validateResult(legacyResult, for: request)
        }
    }

    @Test
    func rejectsGuestResultWithDifferentEffectiveMTU() throws {
        let request = makeGuestNetworkRequest(mtu: 1_450)
        let result = makeGuestNetworkResult(effectiveMTU: 1_500)

        #expect(throws: (any Error).self) {
            try MacOSGuestNetworkBootstrap.validateResult(result, for: request)
        }
    }

    @Test
    func validatesReorderedGuestResultsByInterfaceIdentity() throws {
        let request = MacOSGuestNetworkConfigurationRequest(
            interfaces: [
                makeGuestNetworkInterface(
                    networkID: "primary",
                    macAddress: "02:42:ac:11:00:02",
                    mtu: 1_450
                ),
                makeGuestNetworkInterface(
                    networkID: "secondary",
                    macAddress: "02:42:ac:11:00:03",
                    mtu: 1_400
                ),
            ],
            dns: nil
        )
        let result = MacOSGuestNetworkConfigurationResult(
            interfaces: [
                makeAppliedGuestNetworkInterface(
                    networkID: "secondary",
                    macAddress: "02:42:ac:11:00:03",
                    effectiveMTU: 1_400
                ),
                makeAppliedGuestNetworkInterface(
                    networkID: "primary",
                    macAddress: "02:42:ac:11:00:02",
                    effectiveMTU: 1_450
                ),
            ],
            dnsApplied: false
        )

        try MacOSGuestNetworkBootstrap.validateResult(result, for: request)
    }

    @Test
    func vmnetSharedUsesGatewayAsDefaultNameserverWhenDNSNameserversAreEmpty() throws {
        var config = makeConfiguration(backend: .vmnetShared)
        config.dns = .init(nameservers: [], domain: nil, searchDomains: [], options: [])
        let lease = try makeLease(
            backend: .vmnetShared,
            hostname: "guest-1",
            dns: .init(
                nameservers: ["192.168.64.1"],
                domain: nil,
                searchDomains: [],
                options: []
            )
        )

        let builtRequest = try MacOSGuestNetworkBootstrap.makeRequest(
            containerConfig: config,
            lease: lease
        )
        let request = try #require(builtRequest)

        #expect(request.dns?.nameservers == ["192.168.64.1"])
    }

    @Test
    func virtualizationNATSkipsGuestNetworkBootstrap() throws {
        let config = makeConfiguration(backend: .virtualizationNAT)
        let lease = try makeLease(backend: .vmnetShared, hostname: "guest-1")

        let request = try MacOSGuestNetworkBootstrap.makeRequest(
            containerConfig: config,
            lease: lease
        )

        #expect(request == nil)
    }
}

private func makeConfiguration(
    backend: ContainerConfiguration.MacOSGuestOptions.NetworkBackend
) -> ContainerConfiguration {
    let image = ImageDescription(
        reference: "example/macos:latest",
        descriptor: .init(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:test",
            size: 1
        )
    )
    let process = ProcessConfiguration(
        executable: "/usr/bin/true",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )

    var config = ContainerConfiguration(id: "guest-bootstrap-test", image: image, process: process)
    config.runtimeHandler = "container-runtime-macos"
    config.macosGuest = .init(
        snapshotEnabled: false,
        guiEnabled: false,
        agentPort: 27000,
        networkBackend: backend
    )
    return config
}

private func makeGuestNetworkRequest(mtu: UInt32?) -> MacOSGuestNetworkConfigurationRequest {
    MacOSGuestNetworkConfigurationRequest(
        interfaces: [makeGuestNetworkInterface(networkID: "default", macAddress: "02:42:ac:11:00:02", mtu: mtu)],
        dns: nil
    )
}

private func makeGuestNetworkInterface(
    networkID: String,
    macAddress: String,
    mtu: UInt32?
) -> MacOSGuestNetworkInterfaceConfiguration {
    .init(
        networkID: networkID,
        hostname: "guest-1",
        macAddress: macAddress,
        ipv4Address: "192.168.64.2",
        ipv4PrefixLength: 24,
        ipv4Gateway: "192.168.64.1",
        mtu: mtu
    )
}

private func makeGuestNetworkResult(effectiveMTU: UInt32?) -> MacOSGuestNetworkConfigurationResult {
    .init(
        interfaces: [
            makeAppliedGuestNetworkInterface(
                networkID: "default",
                macAddress: "02:42:ac:11:00:02",
                effectiveMTU: effectiveMTU
            )
        ],
        dnsApplied: false
    )
}

private func makeAppliedGuestNetworkInterface(
    networkID: String,
    macAddress: String,
    effectiveMTU: UInt32?
) -> MacOSGuestAppliedNetworkInterface {
    .init(
        networkID: networkID,
        interfaceName: "en0",
        macAddress: macAddress,
        ipv4Address: "192.168.64.2/24",
        effectiveMTU: effectiveMTU
    )
}

private func makeLease(
    backend: ContainerConfiguration.MacOSGuestOptions.NetworkBackend,
    hostname: String,
    mtu: UInt32? = nil,
    dns: ContainerResource.Attachment.DNSConfiguration? = nil
) throws -> MacOSGuestNetworkLease {
    let attachment = ContainerResource.Attachment(
        network: "default",
        hostname: hostname,
        ipv4Address: try CIDRv4("192.168.64.2/24"),
        ipv4Gateway: try IPv4Address("192.168.64.1"),
        ipv6Address: nil,
        macAddress: try MACAddress("02:42:ac:11:00:02"),
        mtu: mtu,
        dns: dns
    )
    return MacOSGuestNetworkLease(
        interfaces: [
            .init(
                backend: backend,
                attachment: attachment
            )
        ]
    )
}
#endif
