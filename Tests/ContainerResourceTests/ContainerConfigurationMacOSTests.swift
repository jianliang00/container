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

import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerResource

struct ContainerConfigurationMacOSTests {
    @Test
    func encodeDecodeWithMacOSGuestOptions() throws {
        let imageJSON = """
            {
              "reference": "example/macos:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:test",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/echo",
            arguments: ["hello"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(
            id: "macos-test",
            image: image,
            process: process
        )
        config.platform = .init(arch: "arm64", os: "darwin")
        config.runtimeHandler = "container-runtime-macos"
        config.macosGuest = .init(
            snapshotEnabled: true,
            guiEnabled: false,
            agentPort: 27000,
            networkBackend: .vmnetShared
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)

        #expect(decoded.macosGuest == config.macosGuest)
        #expect(decoded.runtimeHandler == "container-runtime-macos")
    }

    @Test
    func decodeLegacyMacOSGuestOptionsWithoutNetworkBackendDefaultsToNAT() throws {
        let imageJSON = """
            {
              "reference": "example/macos:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:test",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/echo",
            arguments: ["hello"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(
            id: "macos-test",
            image: image,
            process: process
        )
        config.platform = .init(arch: "arm64", os: "darwin")
        config.runtimeHandler = "container-runtime-macos"
        config.macosGuest = .init(snapshotEnabled: true, guiEnabled: false, agentPort: 27000)

        let encoded = try JSONEncoder().encode(config)
        var container = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var macosGuest = try #require(container["macosGuest"] as? [String: Any])
        macosGuest.removeValue(forKey: "networkBackend")
        container["macosGuest"] = macosGuest

        let legacyData = try JSONSerialization.data(withJSONObject: container)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: legacyData)

        #expect(decoded.macosGuest?.networkBackend == .virtualizationNAT)
    }

    @Test
    func macOSGuestNetworkRequestsFallBackToBuiltinDefaultNetwork() throws {
        let imageJSON = """
            {
              "reference": "example/macos:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:test",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/echo",
            arguments: ["hello"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(
            id: "macos-test",
            image: image,
            process: process
        )
        config.macosGuest = .init(
            snapshotEnabled: false,
            guiEnabled: false,
            agentPort: 27000,
            networkBackend: .vmnetShared
        )

        let requests = config.macOSGuestNetworkRequests()

        #expect(requests == [
            MacOSGuestNetworkRequest(
                network: MacOSGuestNetworkRequest.defaultNetworkID,
                hostname: "macos-test",
                macAddress: nil
            )
        ])
    }

    @Test
    func macOSGuestNetworkRequestsPreserveExplicitAttachments() throws {
        let imageJSON = """
            {
              "reference": "example/macos:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:test",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/echo",
            arguments: ["hello"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(
            id: "macos-test",
            image: image,
            process: process
        )
        let macAddress = try MACAddress("02:42:ac:11:00:02")
        config.networks = [
            AttachmentConfiguration(
                network: "sandbox-net",
                options: AttachmentOptions(hostname: "sandbox-host", macAddress: macAddress)
            )
        ]

        let requests = config.macOSGuestNetworkRequests()

        #expect(requests == [
            MacOSGuestNetworkRequest(
                network: "sandbox-net",
                hostname: "sandbox-host",
                macAddress: macAddress
            )
        ])
    }

    @Test
    func decodeLegacyConfigurationWithoutMacOSGuestField() throws {
        let imageJSON = """
            {
              "reference": "example/legacy:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:legacy",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        let config = ContainerConfiguration(id: "legacy", image: image, process: process)
        let encoded = try JSONEncoder().encode(config)

        var container = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        container.removeValue(forKey: "macosGuest")
        container.removeValue(forKey: "runtimeHandler")

        let legacyData = try JSONSerialization.data(withJSONObject: container)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: legacyData)
        #expect(decoded.macosGuest == nil)
        #expect(decoded.runtimeHandler == "container-runtime-linux")
    }

    @Test
    func macOSGuestReportedNetworkAttachmentsIncludeConfiguredDNS() throws {
        let imageJSON = """
            {
              "reference": "example/macos:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:test",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/echo",
            arguments: ["hello"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(
            id: "macos-test",
            image: image,
            process: process
        )
        config.dns = .init(
            nameservers: ["9.9.9.9"],
            domain: "example.internal",
            searchDomains: ["svc.example.internal"],
            options: ["ndots:2"]
        )

        let reported = config.macOSGuestReportedNetworkAttachments([
            try makeAttachment(address: "192.168.64.2", gateway: "192.168.64.1")
        ])

        let dns = try #require(reported.first?.dns)
        #expect(dns == .init(
            nameservers: ["9.9.9.9"],
            domain: "example.internal",
            searchDomains: ["svc.example.internal"],
            options: ["ndots:2"]
        ))
    }

    @Test
    func macOSGuestReportedNetworkAttachmentsUseGatewayAsDefaultNameserver() throws {
        let imageJSON = """
            {
              "reference": "example/macos:latest",
              "descriptor": {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:test",
                "size": 1
              }
            }
            """
        let image = try JSONDecoder().decode(ImageDescription.self, from: Data(imageJSON.utf8))
        let process = ProcessConfiguration(
            executable: "/bin/echo",
            arguments: ["hello"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(
            id: "macos-test",
            image: image,
            process: process
        )
        config.dns = .init(nameservers: [], domain: nil, searchDomains: [], options: [])

        let reported = config.macOSGuestReportedNetworkAttachments([
            try makeAttachment(address: "192.168.64.2", gateway: "192.168.64.1"),
            try makeAttachment(address: "192.168.65.2", gateway: "192.168.65.1"),
            try makeAttachment(address: "192.168.66.2", gateway: "192.168.64.1"),
        ])

        let dns = try #require(reported.first?.dns)
        #expect(dns.nameservers == ["192.168.64.1", "192.168.65.1"])
    }
}

private func makeAttachment(address: String, gateway: String) throws -> ContainerResource.Attachment {
    ContainerResource.Attachment(
        network: "default",
        hostname: "macos-test",
        ipv4Address: try CIDRv4(
            IPv4Address(address),
            prefix: Prefix(length: 24)!
        ),
        ipv4Gateway: try IPv4Address(gateway),
        ipv6Address: nil,
        macAddress: nil
    )
}
