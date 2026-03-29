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

import ContainerizationOCI

/// Configuration for a sandbox VM and the resources it owns.
public struct SandboxConfiguration: Sendable, Codable {
    public static let schemaVersion = 1

    /// Persisted schema version for sandbox state.
    public var persistedSchemaVersion: Int
    /// Identifier of the sandbox.
    public var id: String
    /// Image used to provision the sandbox.
    public var image: ImageDescription
    /// External mounts made available at sandbox scope.
    public var mounts: [Filesystem] = []
    /// Read-only files injected into the guest at sandbox scope.
    public var readOnlyFiles: [ReadOnlyFileInjection] = []
    /// Ports published from the sandbox to the host.
    public var publishedPorts: [PublishPort] = []
    /// Sockets published from the sandbox to the host.
    public var publishedSockets: [PublishSocket] = []
    /// Key/value labels attached to the sandbox.
    public var labels: [String: String] = [:]
    /// System controls applied to the sandbox.
    public var sysctls: [String: String] = [:]
    /// Network attachments requested for the sandbox.
    public var networks: [AttachmentConfiguration] = []
    /// DNS configuration applied to the sandbox.
    public var dns: ContainerConfiguration.DNSConfiguration?
    /// Whether to enable rosetta x86-64 translation for the sandbox.
    public var rosetta = false
    /// Platform for the sandbox image.
    public var platform: ContainerizationOCI.Platform = .current
    /// Resource values for the sandbox.
    public var resources: ContainerConfiguration.Resources = .init()
    /// Name of the runtime that supports the sandbox.
    public var runtimeHandler = "container-runtime-linux"
    /// Whether to expose virtualization support in the sandbox.
    public var virtualization = false
    /// Whether to forward the host SSH agent socket into the sandbox.
    public var ssh = false
    /// Whether the sandbox root filesystem is read-only.
    public var readOnly = false
    /// macOS guest runtime options for the sandbox.
    public var macosGuest: ContainerConfiguration.MacOSGuestOptions?

    enum CodingKeys: String, CodingKey {
        case persistedSchemaVersion = "schemaVersion"
        case id
        case image
        case mounts
        case readOnlyFiles
        case publishedPorts
        case publishedSockets
        case labels
        case sysctls
        case networks
        case dns
        case rosetta
        case platform
        case resources
        case runtimeHandler
        case virtualization
        case ssh
        case readOnly
        case macosGuest
    }

    public init(
        id: String,
        image: ImageDescription,
        mounts: [Filesystem] = [],
        readOnlyFiles: [ReadOnlyFileInjection] = [],
        publishedPorts: [PublishPort] = [],
        publishedSockets: [PublishSocket] = [],
        labels: [String: String] = [:],
        sysctls: [String: String] = [:],
        networks: [AttachmentConfiguration] = [],
        dns: ContainerConfiguration.DNSConfiguration? = nil,
        rosetta: Bool = false,
        platform: ContainerizationOCI.Platform = .current,
        resources: ContainerConfiguration.Resources = .init(),
        runtimeHandler: String = "container-runtime-linux",
        virtualization: Bool = false,
        ssh: Bool = false,
        readOnly: Bool = false,
        macosGuest: ContainerConfiguration.MacOSGuestOptions? = nil
    ) {
        self.persistedSchemaVersion = Self.schemaVersion
        self.id = id
        self.image = image
        self.mounts = mounts
        self.readOnlyFiles = readOnlyFiles
        self.publishedPorts = publishedPorts
        self.publishedSockets = publishedSockets
        self.labels = labels
        self.sysctls = sysctls
        self.networks = networks
        self.dns = dns
        self.rosetta = rosetta
        self.platform = platform
        self.resources = resources
        self.runtimeHandler = runtimeHandler
        self.virtualization = virtualization
        self.ssh = ssh
        self.readOnly = readOnly
        self.macosGuest = macosGuest
    }

    public init(containerConfiguration: ContainerConfiguration) {
        self.init(
            id: containerConfiguration.id,
            image: containerConfiguration.image,
            mounts: containerConfiguration.mounts,
            readOnlyFiles: containerConfiguration.readOnlyFiles,
            publishedPorts: containerConfiguration.publishedPorts,
            publishedSockets: containerConfiguration.publishedSockets,
            labels: containerConfiguration.labels,
            sysctls: containerConfiguration.sysctls,
            networks: containerConfiguration.networks,
            dns: containerConfiguration.dns,
            rosetta: containerConfiguration.rosetta,
            platform: containerConfiguration.platform,
            resources: containerConfiguration.resources,
            runtimeHandler: containerConfiguration.runtimeHandler,
            virtualization: containerConfiguration.virtualization,
            ssh: containerConfiguration.ssh,
            readOnly: containerConfiguration.readOnly,
            macosGuest: containerConfiguration.macosGuest
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .persistedSchemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .persistedSchemaVersion,
                in: container,
                debugDescription: "unsupported SandboxConfiguration schemaVersion \(schemaVersion)"
            )
        }
        self.persistedSchemaVersion = schemaVersion
        self.id = try container.decode(String.self, forKey: .id)
        self.image = try container.decode(ImageDescription.self, forKey: .image)
        self.mounts = try container.decodeIfPresent([Filesystem].self, forKey: .mounts) ?? []
        self.readOnlyFiles = try container.decodeIfPresent([ReadOnlyFileInjection].self, forKey: .readOnlyFiles) ?? []
        self.publishedPorts = try container.decodeIfPresent([PublishPort].self, forKey: .publishedPorts) ?? []
        self.publishedSockets = try container.decodeIfPresent([PublishSocket].self, forKey: .publishedSockets) ?? []
        self.labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        self.sysctls = try container.decodeIfPresent([String: String].self, forKey: .sysctls) ?? [:]
        self.networks = try container.decodeIfPresent([AttachmentConfiguration].self, forKey: .networks) ?? []
        self.dns = try container.decodeIfPresent(ContainerConfiguration.DNSConfiguration.self, forKey: .dns)
        self.rosetta = try container.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        self.platform = try container.decodeIfPresent(ContainerizationOCI.Platform.self, forKey: .platform) ?? .current
        self.resources = try container.decodeIfPresent(ContainerConfiguration.Resources.self, forKey: .resources) ?? .init()
        self.runtimeHandler = try container.decodeIfPresent(String.self, forKey: .runtimeHandler) ?? "container-runtime-linux"
        self.virtualization = try container.decodeIfPresent(Bool.self, forKey: .virtualization) ?? false
        self.ssh = try container.decodeIfPresent(Bool.self, forKey: .ssh) ?? false
        self.readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        self.macosGuest = try container.decodeIfPresent(ContainerConfiguration.MacOSGuestOptions.self, forKey: .macosGuest)
    }
}
