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

public enum CNIError: Error, Equatable, LocalizedError {
    case missingEnvironment(String)
    case invalidCommand(String)
    case invalidArguments(String)
    case invalidPath(String)
    case invalidSandboxURI(String)
    case invalidConfiguration(String)
    case incompatibleCNIVersion(String)
    case unsupportedPluginType(String)
    case backendUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingEnvironment(let name):
            "missing CNI environment variable \(name)"
        case .invalidCommand(let value):
            "invalid CNI_COMMAND \(value)"
        case .invalidArguments(let value):
            "invalid CNI_ARGS \(value)"
        case .invalidPath(let value):
            "invalid CNI_PATH \(value)"
        case .invalidSandboxURI(let value):
            "invalid CNI_NETNS sandbox URI \(value)"
        case .invalidConfiguration(let value):
            value
        case .incompatibleCNIVersion(let value):
            "incompatible CNI version \(value); supported version is \(CNISpec.version)"
        case .unsupportedPluginType(let value):
            "unsupported CNI plugin type \(value); expected \(CNISpec.pluginType)"
        case .backendUnavailable(let value):
            value
        }
    }

    public var cniCode: Int {
        switch self {
        case .incompatibleCNIVersion:
            1
        case .missingEnvironment, .invalidCommand, .invalidArguments, .invalidPath, .invalidSandboxURI:
            4
        case .invalidConfiguration, .unsupportedPluginType:
            7
        case .backendUnavailable:
            100
        }
    }
}

public struct CNIErrorResponse: Codable, Equatable {
    public var cniVersion: String
    public var code: Int
    public var msg: String
    public var details: String?

    public init(cniVersion: String = CNISpec.version, code: Int, msg: String, details: String? = nil) {
        self.cniVersion = cniVersion
        self.code = code
        self.msg = msg
        self.details = details
    }

    public init(error: Error, cniVersion: String = CNISpec.version) {
        switch error {
        case let cniError as CNIError:
            self.init(
                cniVersion: cniVersion,
                code: cniError.cniCode,
                msg: cniError.errorDescription ?? "CNI plugin error"
            )
        case let decodingError as DecodingError:
            self.init(
                cniVersion: cniVersion,
                code: 6,
                msg: "failed to decode CNI network configuration",
                details: String(describing: decodingError)
            )
        default:
            self.init(
                cniVersion: cniVersion,
                code: 100,
                msg: "CNI plugin error",
                details: String(describing: error)
            )
        }
    }
}
