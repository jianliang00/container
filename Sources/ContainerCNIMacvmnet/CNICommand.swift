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

public enum CNICommand: String, Codable, Equatable, CaseIterable {
    case add = "ADD"
    case check = "CHECK"
    case delete = "DEL"
    case status = "STATUS"
    case version = "VERSION"
    case garbageCollect = "GC"
}

public struct CNIVersionResult: Codable, Equatable {
    public var cniVersion: String
    public var supportedVersions: [String]

    public init(cniVersion: String = CNISpec.version, supportedVersions: [String] = [CNISpec.version]) {
        self.cniVersion = cniVersion
        self.supportedVersions = supportedVersions
    }
}

public enum CNISpec {
    public static let version = "1.1.0"
    public static let pluginType = "macvmnet"
    public static let defaultNetworkName = "default"
}
