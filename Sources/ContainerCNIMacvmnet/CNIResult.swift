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

public struct CNIResult: Codable, Equatable, Sendable {
    public var cniVersion: String
    public var interfaces: [CNIInterface]?
    public var ips: [CNIIPConfig]?
    public var routes: [CNIRoute]?
    public var dns: CNIDNS?

    public init(
        cniVersion: String = CNISpec.version,
        interfaces: [CNIInterface]? = nil,
        ips: [CNIIPConfig]? = nil,
        routes: [CNIRoute]? = nil,
        dns: CNIDNS? = nil
    ) {
        self.cniVersion = cniVersion
        self.interfaces = interfaces
        self.ips = ips
        self.routes = routes
        self.dns = dns
    }
}

public struct CNIInterface: Codable, Equatable, Sendable {
    public var name: String
    public var mac: String?
    public var sandbox: String?

    public init(name: String, mac: String? = nil, sandbox: String? = nil) {
        self.name = name
        self.mac = mac
        self.sandbox = sandbox
    }
}

public struct CNIIPConfig: Codable, Equatable, Sendable {
    public var interface: Int?
    public var address: String
    public var gateway: String?

    public init(interface: Int? = nil, address: String, gateway: String? = nil) {
        self.interface = interface
        self.address = address
        self.gateway = gateway
    }
}

public struct CNIRoute: Codable, Equatable, Sendable {
    public var dst: String
    public var gw: String?
    public var mtu: Int?

    public init(dst: String, gw: String? = nil, mtu: Int? = nil) {
        self.dst = dst
        self.gw = gw
        self.mtu = mtu
    }
}

public struct CNIDNS: Codable, Equatable, Sendable {
    public var nameservers: [String]?
    public var domain: String?
    public var search: [String]?
    public var options: [String]?

    public init(nameservers: [String]? = nil, domain: String? = nil, search: [String]? = nil, options: [String]? = nil) {
        self.nameservers = nameservers
        self.domain = domain
        self.search = search
        self.options = options
    }
}
