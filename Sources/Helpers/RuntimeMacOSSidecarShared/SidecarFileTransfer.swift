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

import CryptoKit
import Foundation

public enum MacOSSidecarFileTransfer {
    public struct WriteOptions: Sendable, Equatable {
        public var mode: UInt32?
        public var uid: UInt32?
        public var gid: UInt32?
        public var mtime: Int64?
        public var overwrite: Bool

        public init(
            mode: UInt32? = nil,
            uid: UInt32? = nil,
            gid: UInt32? = nil,
            mtime: Int64? = nil,
            overwrite: Bool = true
        ) {
            self.mode = mode
            self.uid = uid
            self.gid = gid
            self.mtime = mtime
            self.overwrite = overwrite
        }
    }

    public typealias BeginHandler = @Sendable (MacOSSidecarFSBeginRequestPayload) async throws -> Void
    public typealias ChunkHandler = @Sendable (MacOSSidecarFSChunkRequestPayload) async throws -> Void
    public typealias EndHandler = @Sendable (MacOSSidecarFSEndRequestPayload) async throws -> Void

    public static func createDirectory(
        at path: String,
        options: WriteOptions = .init(),
        begin: BeginHandler
    ) async throws {
        try await begin(
            .init(
                txID: UUID().uuidString,
                op: .mkdir,
                path: path,
                mode: options.mode,
                uid: options.uid,
                gid: options.gid,
                mtime: options.mtime,
                overwrite: options.overwrite,
                autoCommit: true
            )
        )
    }

    public static func createSymbolicLink(
        at path: String,
        target: String,
        options: WriteOptions = .init(),
        begin: BeginHandler
    ) async throws {
        try await begin(
            .init(
                txID: UUID().uuidString,
                op: .symlink,
                path: path,
                mode: options.mode,
                uid: options.uid,
                gid: options.gid,
                mtime: options.mtime,
                linkTarget: target,
                overwrite: options.overwrite,
                autoCommit: true
            )
        )
    }

    public static func writeFile(
        from sourceURL: URL,
        to path: String,
        options: WriteOptions = .init(),
        inlineDataLimit: Int = 256 * 1024,
        chunkSize: Int = 256 * 1024,
        begin: BeginHandler,
        chunk: ChunkHandler,
        end: EndHandler
    ) async throws {
        let fileSize = try fileSize(at: sourceURL)

        if fileSize <= UInt64(inlineDataLimit) {
            let data = try Data(contentsOf: sourceURL)
            let digest = sha256Hex(of: data)
            try await begin(
                .init(
                    txID: UUID().uuidString,
                    op: .writeFile,
                    path: path,
                    digest: "sha256:\(digest)",
                    mode: options.mode,
                    uid: options.uid,
                    gid: options.gid,
                    mtime: options.mtime,
                    overwrite: options.overwrite,
                    inlineData: data,
                    autoCommit: true
                )
            )
            return
        }

        let txID = UUID().uuidString
        try await begin(
            .init(
                txID: txID,
                op: .writeFile,
                path: path,
                mode: options.mode,
                uid: options.uid,
                gid: options.gid,
                mtime: options.mtime,
                overwrite: options.overwrite,
                autoCommit: false
            )
        )

        var shouldAbort = true
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer {
                try? handle.close()
            }

            var hasher = SHA256()
            var offset: UInt64 = 0
            while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
                hasher.update(data: data)
                try await chunk(.init(txID: txID, offset: offset, data: data))
                offset += UInt64(data.count)
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            try await end(.init(txID: txID, action: .commit, digest: "sha256:\(digest)"))
            shouldAbort = false
        } catch {
            if shouldAbort {
                try? await end(.init(txID: txID, action: .abort))
            }
            throw error
        }
    }

    private static func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
