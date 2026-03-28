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
    /// Identifier of the sandbox.
    public var id: String
    /// Image used to provision the sandbox.
    public var image: ImageDescription
    /// External mounts made available at sandbox scope.
    public var mounts: [Filesystem] = []
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

    public init(
        id: String,
        image: ImageDescription,
        mounts: [Filesystem] = [],
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
        self.id = id
        self.image = image
        self.mounts = mounts
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
}
