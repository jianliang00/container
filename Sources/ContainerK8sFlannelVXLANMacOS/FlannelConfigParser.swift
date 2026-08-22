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

public enum FlannelConfigParser {
    public static func parse(
        configMap: FlannelConfigMap,
        key: String = "net-conf.json",
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> FlannelNetworkConfig {
        guard let value = configMap.data?[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let identifier = [configMap.metadata.namespace, configMap.metadata.name]
                .compactMap { $0 }
                .joined(separator: "/")
            throw FlannelVXLANError.invalidNetworkConfig(
                "ConfigMap \(identifier.isEmpty ? "<unknown>" : identifier) does not contain \(key)"
            )
        }
        return try parse(Data(value.utf8), decoder: decoder)
    }

    public static func parse(_ value: String, decoder: JSONDecoder = JSONDecoder()) throws -> FlannelNetworkConfig {
        try parse(Data(value.utf8), decoder: decoder)
    }

    public static func parse(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> FlannelNetworkConfig {
        let raw: RawNetworkConfig
        do {
            raw = try decoder.decode(RawNetworkConfig.self, from: data)
        } catch {
            throw FlannelVXLANError.invalidNetworkConfig("net-conf.json is not valid JSON: \(error)")
        }

        guard raw.enableIPv4 ?? true else {
            throw FlannelVXLANError.invalidNetworkConfig("EnableIPv4 must be true")
        }
        guard let networkValue = raw.network,
            let network = FlannelIPv4.parseCIDR(networkValue)
        else {
            throw FlannelVXLANError.invalidNetworkConfig("Network must be a valid IPv4 CIDR")
        }
        let ipv6Network: FlannelIPv6.CIDR?
        if let ipv6NetworkValue = raw.ipv6Network {
            guard let parsed = FlannelIPv6.parseCIDR(ipv6NetworkValue) else {
                throw FlannelVXLANError.invalidNetworkConfig("IPv6Network must be a valid IPv6 CIDR")
            }
            ipv6Network = parsed
        } else {
            ipv6Network = nil
        }
        if raw.enableIPv6 ?? false, ipv6Network == nil {
            throw FlannelVXLANError.invalidNetworkConfig("IPv6Network is required when EnableIPv6 is true")
        }
        guard let rawBackend = raw.backend else {
            throw FlannelVXLANError.invalidNetworkConfig("Backend is required")
        }

        let type = rawBackend.type ?? "vxlan"
        guard type.lowercased() == "vxlan" else {
            throw FlannelVXLANError.invalidNetworkConfig("Backend.Type must be vxlan")
        }

        // Linux and Windows use different VXLAN defaults. Requiring both values
        // prevents a macOS VTEP from silently selecting the wrong wire protocol.
        guard let vni = rawBackend.vni else {
            throw FlannelVXLANError.invalidNetworkConfig("Backend.VNI must be explicit for cross-platform VXLAN")
        }
        guard (1...16_777_215).contains(vni) else {
            throw FlannelVXLANError.invalidNetworkConfig("Backend.VNI must be a non-zero 24-bit value")
        }
        guard let port = rawBackend.port else {
            throw FlannelVXLANError.invalidNetworkConfig("Backend.Port must be explicit for cross-platform VXLAN")
        }
        guard (1...65_535).contains(port) else {
            throw FlannelVXLANError.invalidNetworkConfig("Backend.Port must be between 1 and 65535")
        }
        if let mtu = rawBackend.mtu, mtu <= FlannelVXLANBackendConfig.encapsulationOverhead {
            throw FlannelVXLANError.invalidNetworkConfig("Backend.MTU must be greater than 50")
        }

        let backend = FlannelVXLANBackendConfig(
            type: "vxlan",
            vni: vni,
            port: port,
            mtu: rawBackend.mtu,
            directRouting: rawBackend.directRouting ?? false,
            gbp: rawBackend.gbp ?? false,
            learning: rawBackend.learning ?? false
        )
        return FlannelNetworkConfig(
            network: network.string,
            ipv6Network: ipv6Network?.string,
            enableIPv4: true,
            enableIPv6: raw.enableIPv6 ?? false,
            backend: backend
        )
    }
}

private struct RawNetworkConfig: Decodable {
    var network: String?
    var ipv6Network: String?
    var enableIPv4: Bool?
    var enableIPv6: Bool?
    var backend: RawBackendConfig?

    enum CodingKeys: String, CodingKey {
        case network = "Network"
        case ipv6Network = "IPv6Network"
        case enableIPv4 = "EnableIPv4"
        case enableIPv6 = "EnableIPv6"
        case backend = "Backend"
    }
}

private struct RawBackendConfig: Decodable {
    var type: String?
    var vni: Int?
    var port: Int?
    var mtu: Int?
    var directRouting: Bool?
    var gbp: Bool?
    var learning: Bool?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case vni = "VNI"
        case port = "Port"
        case mtu = "MTU"
        case directRouting = "DirectRouting"
        case gbp = "GBP"
        case learning = "Learning"
    }
}
