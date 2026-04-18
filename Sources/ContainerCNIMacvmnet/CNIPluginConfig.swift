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

public struct CNIPluginConfig: Codable, Equatable {
    public var cniVersion: String
    public var name: String
    public var type: String
    public var args: CNIJSONValue?
    public var ipam: CNIJSONValue?
    public var dns: CNIDNS?
    public var prevResult: CNIResult?
    public var extra: [String: CNIJSONValue]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cniVersion
        case name
        case type
        case args
        case ipam
        case dns
        case prevResult
    }

    public init(
        cniVersion: String,
        name: String,
        type: String,
        args: CNIJSONValue? = nil,
        ipam: CNIJSONValue? = nil,
        dns: CNIDNS? = nil,
        prevResult: CNIResult? = nil,
        extra: [String: CNIJSONValue] = [:]
    ) {
        self.cniVersion = cniVersion
        self.name = name
        self.type = type
        self.args = args
        self.ipam = ipam
        self.dns = dns
        self.prevResult = prevResult
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cniVersion = try container.decode(String.self, forKey: .cniVersion)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        args = try container.decodeIfPresent(CNIJSONValue.self, forKey: .args)
        ipam = try container.decodeIfPresent(CNIJSONValue.self, forKey: .ipam)
        dns = try container.decodeIfPresent(CNIDNS.self, forKey: .dns)
        prevResult = try container.decodeIfPresent(CNIResult.self, forKey: .prevResult)

        let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
        let extraContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var decodedExtra: [String: CNIJSONValue] = [:]
        for key in extraContainer.allKeys where !knownKeys.contains(key.stringValue) {
            decodedExtra[key.stringValue] = try extraContainer.decode(CNIJSONValue.self, forKey: key)
        }
        extra = decodedExtra
    }

    public var networkName: String {
        stringValue(for: "network") ?? CNISpec.defaultNetworkName
    }

    public var runtimeName: String {
        stringValue(for: "runtime") ?? CNISpec.defaultRuntimeName
    }

    public func stringValue(for key: String) -> String? {
        guard case .string(let value) = extra[key] else {
            return nil
        }
        return value
    }

    public func validAttachments() throws -> Set<MacvmnetAttachmentIdentity> {
        guard let value = extra["cni.dev/valid-attachments"] else {
            throw CNIError.invalidConfiguration("cni.dev/valid-attachments is required for GC")
        }

        guard case .array(let entries) = value else {
            throw CNIError.invalidConfiguration("cni.dev/valid-attachments must be an array")
        }

        return try Set(
            entries.enumerated().map { index, entry in
                guard case .object(let object) = entry else {
                    throw CNIError.invalidConfiguration("cni.dev/valid-attachments[\(index)] must be an object")
                }
                guard case .string(let containerID)? = object["containerID"], !containerID.isEmpty else {
                    throw CNIError.invalidConfiguration("cni.dev/valid-attachments[\(index)].containerID is required")
                }
                guard case .string(let ifName)? = object["ifname"], !ifName.isEmpty else {
                    throw CNIError.invalidConfiguration("cni.dev/valid-attachments[\(index)].ifname is required")
                }
                return MacvmnetAttachmentIdentity(containerID: containerID, ifName: ifName)
            })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cniVersion, forKey: .cniVersion)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(args, forKey: .args)
        try container.encodeIfPresent(ipam, forKey: .ipam)
        try container.encodeIfPresent(dns, forKey: .dns)
        try container.encodeIfPresent(prevResult, forKey: .prevResult)

        var extraContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extra {
            try extraContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    public func validate() throws {
        guard cniVersion == CNISpec.version else {
            throw CNIError.incompatibleCNIVersion(cniVersion)
        }
        guard type == CNISpec.pluginType else {
            throw CNIError.unsupportedPluginType(type)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CNIError.invalidConfiguration("CNI network name is required")
        }
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
