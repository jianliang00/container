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

public enum MacOSSidecarFSOperation: String, Codable, Sendable {
    case writeFile = "write_file"
    case mkdir
    case symlink
}

public enum MacOSSidecarFSEndAction: String, Codable, Sendable {
    case commit
    case abort
}

public struct MacOSSidecarFSBeginRequestPayload: Codable, Sendable {
    public let txID: String
    public let op: MacOSSidecarFSOperation
    public let path: String
    public let digest: String?
    public let mode: UInt32?
    public let uid: UInt32?
    public let gid: UInt32?
    public let mtime: Int64?
    public let linkTarget: String?
    public let overwrite: Bool
    public let inlineData: Data?
    public let autoCommit: Bool

    public init(
        txID: String,
        op: MacOSSidecarFSOperation,
        path: String,
        digest: String? = nil,
        mode: UInt32? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        mtime: Int64? = nil,
        linkTarget: String? = nil,
        overwrite: Bool = true,
        inlineData: Data? = nil,
        autoCommit: Bool = false
    ) {
        self.txID = txID
        self.op = op
        self.path = path
        self.digest = digest
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.mtime = mtime
        self.linkTarget = linkTarget
        self.overwrite = overwrite
        self.inlineData = inlineData
        self.autoCommit = autoCommit
    }
}

public struct MacOSSidecarFSChunkRequestPayload: Codable, Sendable {
    public let txID: String
    public let offset: UInt64
    public let data: Data

    public init(txID: String, offset: UInt64, data: Data) {
        self.txID = txID
        self.offset = offset
        self.data = data
    }
}

public struct MacOSSidecarFSEndRequestPayload: Codable, Sendable {
    public let txID: String
    public let action: MacOSSidecarFSEndAction
    public let digest: String?

    public init(txID: String, action: MacOSSidecarFSEndAction, digest: String? = nil) {
        self.txID = txID
        self.action = action
        self.digest = digest
    }
}
