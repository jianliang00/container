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

import ArgumentParser
import ContainerAPIClient
import ContainerSandboxServiceClient
import ContainerizationError
import Foundation
import RuntimeMacOSSidecarShared

extension Application {
    public struct ContainerCopy: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "cp",
            abstract: "Copy files between a container and the local filesystem"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Source path (use CONTAINER:PATH for container paths)")
        var src: String

        @Argument(help: "Destination path (use CONTAINER:PATH for container paths)")
        var dst: String

        public func run() async throws {
            let (srcContainer, srcPath) = parsePath(src)
            let (dstContainer, dstPath) = parsePath(dst)

            guard (srcContainer == nil) != (dstContainer == nil) else {
                guard srcContainer != nil && dstContainer != nil else {
                    throw ContainerizationError(.invalidArgument, message: "source or destination must be a container path (CONTAINER:PATH)")
                }
                throw ContainerizationError(.invalidArgument, message: "cannot copy between two containers")
            }

            let client = ContainerClient()

            if let containerID = dstContainer {
                // Host -> Container
                let container = try await client.get(id: containerID)
                try Application.ensureRunning(container: container)
                guard container.configuration.macosGuest != nil else {
                    throw ContainerizationError(.unsupported, message: "container cp is only supported for macOS containers")
                }
                let runtime = container.configuration.runtimeHandler
                let sandboxClient = try await SandboxClient.create(id: container.id, runtime: runtime)
                let srcURL = URL(fileURLWithPath: srcPath)
                try await copyHostToContainer(srcURL: srcURL, dstPath: dstPath, sandboxClient: sandboxClient)
            } else {
                // Container -> Host
                let containerID = srcContainer!
                let container = try await client.get(id: containerID)
                try Application.ensureRunning(container: container)
                guard container.configuration.macosGuest != nil else {
                    throw ContainerizationError(.unsupported, message: "container cp is only supported for macOS containers")
                }
                let runtime = container.configuration.runtimeHandler
                let sandboxClient = try await SandboxClient.create(id: container.id, runtime: runtime)
                let dstURL = URL(fileURLWithPath: dstPath)
                try await copyContainerToHost(srcPath: srcPath, dstURL: dstURL, sandboxClient: sandboxClient)
            }
        }

        // Parse "container:path" or "localpath"
        private func parsePath(_ s: String) -> (containerID: String?, path: String) {
            let parts = s.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let maybeID = String(parts[0])
                // Container ID does not contain '/'
                if !maybeID.contains("/") && !maybeID.isEmpty {
                    return (maybeID, String(parts[1]))
                }
            }
            return (nil, s)
        }

        // MARK: - Host to Container

        private func copyHostToContainer(
            srcURL: URL,
            dstPath: String,
            sandboxClient: SandboxClient
        ) async throws {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: srcURL.path, isDirectory: &isDirectory) else {
                throw ContainerizationError(.notFound, message: "source path not found: \(srcURL.path)")
            }

            if isDirectory.boolValue {
                try await copyDirectoryHostToContainer(srcURL: srcURL, dstPath: dstPath, sandboxClient: sandboxClient)
            } else {
                // Check if it's a symlink
                let attrs = try FileManager.default.attributesOfItem(atPath: srcURL.path)
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: srcURL.path)
                    let mtime = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
                    let options = MacOSSidecarFileTransfer.WriteOptions(mtime: mtime)
                    try await MacOSSidecarFileTransfer.createSymbolicLink(
                        at: dstPath,
                        target: target,
                        options: options,
                        begin: { payload in try await sandboxClient.fsBegin(payload) }
                    )
                } else {
                    try await copySingleFileHostToContainer(srcURL: srcURL, dstPath: dstPath, sandboxClient: sandboxClient)
                }
            }
        }

        private func copySingleFileHostToContainer(
            srcURL: URL,
            dstPath: String,
            sandboxClient: SandboxClient
        ) async throws {
            let attrs = try FileManager.default.attributesOfItem(atPath: srcURL.path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.uint32Value
            let mtime = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }

            let options = MacOSSidecarFileTransfer.WriteOptions(mode: mode, mtime: mtime)
            try await MacOSSidecarFileTransfer.writeFile(
                from: srcURL,
                to: dstPath,
                options: options,
                begin: { payload in try await sandboxClient.fsBegin(payload) },
                chunk: { payload in try await sandboxClient.fsChunk(payload) },
                end: { payload in try await sandboxClient.fsEnd(payload) }
            )
        }

        private func copyDirectoryHostToContainer(
            srcURL: URL,
            dstPath: String,
            sandboxClient: SandboxClient
        ) async throws {
            let attrs = try FileManager.default.attributesOfItem(atPath: srcURL.path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.uint32Value
            let mtime = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
            let options = MacOSSidecarFileTransfer.WriteOptions(mode: mode, mtime: mtime)

            try await MacOSSidecarFileTransfer.createDirectory(
                at: dstPath,
                options: options,
                begin: { payload in try await sandboxClient.fsBegin(payload) }
            )

            let contents = try FileManager.default.contentsOfDirectory(atPath: srcURL.path)
            for name in contents {
                let childSrc = srcURL.appendingPathComponent(name)
                let childDst = dstPath.hasSuffix("/") ? "\(dstPath)\(name)" : "\(dstPath)/\(name)"

                let childAttrs = try FileManager.default.attributesOfItem(atPath: childSrc.path)
                if childAttrs[.type] as? FileAttributeType == .typeSymbolicLink {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: childSrc.path)
                    let symlinkMtime = (childAttrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
                    let symlinkOptions = MacOSSidecarFileTransfer.WriteOptions(mtime: symlinkMtime)
                    try await MacOSSidecarFileTransfer.createSymbolicLink(
                        at: childDst,
                        target: target,
                        options: symlinkOptions,
                        begin: { payload in try await sandboxClient.fsBegin(payload) }
                    )
                } else {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: childSrc.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        try await copyDirectoryHostToContainer(srcURL: childSrc, dstPath: childDst, sandboxClient: sandboxClient)
                    } else {
                        try await copySingleFileHostToContainer(srcURL: childSrc, dstPath: childDst, sandboxClient: sandboxClient)
                    }
                }
            }
        }

        // MARK: - Container to Host

        private func copyContainerToHost(
            srcPath: String,
            dstURL: URL,
            sandboxClient: SandboxClient
        ) async throws {
            let txID = UUID().uuidString
            let meta = try await sandboxClient.fsReadBegin(
                MacOSSidecarFSReadBeginRequestPayload(txID: txID, path: srcPath)
            )

            do {
                switch meta.fileType {
                case .file:
                    try await copyFileContainerToHost(txID: txID, meta: meta, dstURL: dstURL, sandboxClient: sandboxClient)
                    try await sandboxClient.fsReadEnd(txID: txID)
                case .directory:
                    // For directory, we don't need the read session - close it and use fsListDir
                    try await sandboxClient.fsReadEnd(txID: txID)
                    try await copyDirectoryContainerToHost(srcPath: srcPath, dstURL: dstURL, sandboxClient: sandboxClient)
                case .symlink:
                    try await sandboxClient.fsReadEnd(txID: txID)
                    guard let target = meta.linkTarget else {
                        throw ContainerizationError(.internalError, message: "symlink target missing for \(srcPath)")
                    }
                    let parent = dstURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dstURL)
                    try FileManager.default.createSymbolicLink(atPath: dstURL.path, withDestinationPath: target)
                }
            } catch {
                // Best-effort cleanup: ignore error from fsReadEnd
                try? await sandboxClient.fsReadEnd(txID: txID)
                throw error
            }
        }

        private func copyFileContainerToHost(
            txID: String,
            meta: MacOSSidecarFSReadBeginResponsePayload,
            dstURL: URL,
            sandboxClient: SandboxClient
        ) async throws {
            let parent = dstURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            let chunkSize = 256 * 1024
            FileManager.default.createFile(atPath: dstURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: dstURL)
            defer { try? fileHandle.close() }
            try fileHandle.truncate(atOffset: 0)

            var offset: UInt64 = 0
            while true {
                let data = try await sandboxClient.fsReadChunk(
                    MacOSSidecarFSReadChunkRequestPayload(txID: txID, offset: offset, maxLength: chunkSize)
                )
                guard let data, !data.isEmpty else { break }
                try fileHandle.write(contentsOf: data)
                offset += UInt64(data.count)
            }

            if let mode = meta.mode {
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: dstURL.path)
            }
            if let mtime = meta.mtime {
                let date = Date(timeIntervalSince1970: TimeInterval(mtime))
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dstURL.path)
            }
        }

        private func copyDirectoryContainerToHost(
            srcPath: String,
            dstURL: URL,
            sandboxClient: SandboxClient
        ) async throws {
            try FileManager.default.createDirectory(at: dstURL, withIntermediateDirectories: true)

            let txID = UUID().uuidString
            let entries = try await sandboxClient.fsListDir(
                MacOSSidecarFSListDirRequestPayload(txID: txID, path: srcPath)
            )

            for entry in entries {
                let childSrc = srcPath.hasSuffix("/") ? "\(srcPath)\(entry.name)" : "\(srcPath)/\(entry.name)"
                let childDst = dstURL.appendingPathComponent(entry.name)
                switch entry.fileType {
                case .file:
                    let fileTxID = UUID().uuidString
                    let fileMeta = try await sandboxClient.fsReadBegin(
                        MacOSSidecarFSReadBeginRequestPayload(txID: fileTxID, path: childSrc)
                    )
                    do {
                        try await copyFileContainerToHost(txID: fileTxID, meta: fileMeta, dstURL: childDst, sandboxClient: sandboxClient)
                        try await sandboxClient.fsReadEnd(txID: fileTxID)
                    } catch {
                        try? await sandboxClient.fsReadEnd(txID: fileTxID)
                        throw error
                    }
                case .directory:
                    try await copyDirectoryContainerToHost(srcPath: childSrc, dstURL: childDst, sandboxClient: sandboxClient)
                case .symlink:
                    if let target = entry.linkTarget {
                        try? FileManager.default.removeItem(at: childDst)
                        try FileManager.default.createSymbolicLink(atPath: childDst.path, withDestinationPath: target)
                    }
                }
            }
        }
    }
}
