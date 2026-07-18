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
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import Foundation
import RuntimeMacOSSidecarShared
import SystemPackage

extension Application {
    public struct ContainerCopy: AsyncLoggableCommand {
        enum PathRef {
            case local(String)
            case container(id: String, path: String)
        }

        static func parsePathRef(_ ref: String) throws -> PathRef {
            let parts = ref.components(separatedBy: ":")
            switch parts.count {
            case 1:
                return .local(ref)
            case 2 where !parts[0].isEmpty && parts[1].starts(with: "/"):
                return .container(id: parts[0], path: parts[1])
            default:
                throw ContainerizationError(.invalidArgument, message: "invalid path given: \(ref)")
            }
        }

        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "copy",
            abstract: "Copy files/folders between a container and the local filesystem",
            aliases: ["cp"])

        @OptionGroup()
        public var logOptions: Flags.Logging

        @Argument(help: "Source path (container:path or local path)")
        var source: String

        @Argument(help: "Destination path (container:path or local path)")
        var destination: String

        public func run() async throws {
            let client = ContainerClient()
            let srcRef = try Self.parsePathRef(source)
            let dstRef = try Self.parsePathRef(destination)

            switch (srcRef, dstRef) {
            case (.container(let id, let path), .local(let localPath)):
                let container = try await client.get(id: id)
                try Application.ensureRunning(container: container)

                let srcPath = FilePath(path)
                let destPath = FilePath(
                    URL(fileURLWithPath: localPath, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false))
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: destPath.string, isDirectory: &isDirectory)

                var finalDestPath = destPath
                if exists && isDirectory.boolValue {
                    guard let lastComponent = srcPath.lastComponent else {
                        throw ContainerizationError(.invalidArgument, message: "source path has no last component: \(path)")
                    }
                    finalDestPath = destPath.appending(lastComponent)
                    try await copyOut(
                        client: client,
                        container: container,
                        source: path,
                        destination: finalDestPath.string
                    )
                } else if localPath.hasSuffix("/") {
                    try await copyOut(
                        client: client,
                        container: container,
                        source: path,
                        destination: destPath.string
                    )
                    var resultIsDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: destPath.string, isDirectory: &resultIsDir),
                        !resultIsDir.boolValue
                    {
                        try? FileManager.default.removeItem(atPath: destPath.string)
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "destination is not a directory: \(localPath)")
                    }
                } else {
                    try await copyOut(
                        client: client,
                        container: container,
                        source: path,
                        destination: destPath.string
                    )
                }
                print(finalDestPath.string)

            case (.local(let localPath), .container(let id, let path)):
                let container = try await client.get(id: id)
                try Application.ensureRunning(container: container)

                let srcPath = FilePath(
                    URL(fileURLWithPath: localPath, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false))
                var isDirectory: ObjCBool = false

                guard let lastComponent = srcPath.lastComponent else {
                    throw ContainerizationError(.invalidArgument, message: "source path has no last component: \(localPath)")
                }

                guard FileManager.default.fileExists(atPath: srcPath.string, isDirectory: &isDirectory) else {
                    throw ContainerizationError(.notFound, message: "source path does not exist: \(localPath)")
                }
                if localPath.hasSuffix("/") && !isDirectory.boolValue {
                    throw ContainerizationError(.invalidArgument, message: "source path is not a directory: \(localPath)")
                }

                try await copyIn(
                    client: client,
                    container: container,
                    source: srcPath.string,
                    destination: path,
                    sourceName: lastComponent.string
                )
                let printedDest = path.hasSuffix("/") ? "\(id):\(path)\(lastComponent.string)" : "\(id):\(path)"
                print(printedDest)

            case (.container, .container):
                throw ContainerizationError(.invalidArgument, message: "copying between containers is not supported")
            case (.local, .local):
                throw ContainerizationError(
                    .invalidArgument,
                    message: "one of source or destination must be a container reference (container_id:path)")
            }
        }

        private func copyIn(
            client: ContainerClient,
            container: ContainerSnapshot,
            source: String,
            destination: String,
            sourceName: String
        ) async throws {
            guard container.configuration.macosGuest != nil else {
                try await client.copyIn(
                    id: container.id,
                    source: source,
                    destination: destination,
                    createParents: true
                )
                return
            }

            let runtimeClient = try await RuntimeClient.create(
                id: container.id,
                runtime: container.configuration.runtimeHandler
            )
            let resolvedDestination = try await macOSCopyInDestination(
                destination,
                sourceName: sourceName,
                runtimeClient: runtimeClient
            )
            try await copyHostToContainer(
                srcURL: URL(fileURLWithPath: source),
                dstPath: resolvedDestination,
                runtimeClient: runtimeClient
            )
        }

        private func copyOut(
            client: ContainerClient,
            container: ContainerSnapshot,
            source: String,
            destination: String
        ) async throws {
            guard container.configuration.macosGuest != nil else {
                try await client.copyOut(
                    id: container.id,
                    source: source,
                    destination: destination
                )
                return
            }

            let runtimeClient = try await RuntimeClient.create(
                id: container.id,
                runtime: container.configuration.runtimeHandler
            )
            try await copyContainerToHost(
                srcPath: source,
                dstURL: URL(fileURLWithPath: destination),
                runtimeClient: runtimeClient
            )
        }

        private func macOSCopyInDestination(
            _ destination: String,
            sourceName: String,
            runtimeClient: RuntimeClient
        ) async throws -> String {
            if destination.hasSuffix("/") {
                return "\(destination)\(sourceName)"
            }

            let txID = UUID().uuidString
            let metadata: MacOSSidecarFSReadBeginResponsePayload
            do {
                metadata = try await runtimeClient.fsReadBegin(
                    MacOSSidecarFSReadBeginRequestPayload(txID: txID, path: destination)
                )
            } catch {
                // This is only a best-effort probe to preserve directory destination
                // semantics. The write path below will return the authoritative error.
                return destination
            }
            try await runtimeClient.fsReadEnd(txID: txID)

            guard metadata.fileType == .directory else {
                return destination
            }
            return "\(destination)/\(sourceName)"
        }

        // MARK: - Host to Container

        private func copyHostToContainer(
            srcURL: URL,
            dstPath: String,
            runtimeClient: RuntimeClient
        ) async throws {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: srcURL.path, isDirectory: &isDirectory) else {
                throw ContainerizationError(.notFound, message: "source path not found: \(srcURL.path)")
            }

            if isDirectory.boolValue {
                try await copyDirectoryHostToContainer(
                    srcURL: srcURL,
                    dstPath: dstPath,
                    runtimeClient: runtimeClient
                )
                return
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: srcURL.path)
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: srcURL.path)
                let mtime = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
                let options = MacOSSidecarFileTransfer.WriteOptions(mtime: mtime)
                try await MacOSSidecarFileTransfer.createSymbolicLink(
                    at: dstPath,
                    target: target,
                    options: options,
                    begin: { payload in try await runtimeClient.fsBegin(payload) }
                )
            } else {
                try await copySingleFileHostToContainer(
                    srcURL: srcURL,
                    dstPath: dstPath,
                    runtimeClient: runtimeClient
                )
            }
        }

        private func copySingleFileHostToContainer(
            srcURL: URL,
            dstPath: String,
            runtimeClient: RuntimeClient
        ) async throws {
            let attrs = try FileManager.default.attributesOfItem(atPath: srcURL.path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.uint32Value
            let mtime = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }

            let options = MacOSSidecarFileTransfer.WriteOptions(mode: mode, mtime: mtime)
            try await MacOSSidecarFileTransfer.writeFile(
                from: srcURL,
                to: dstPath,
                options: options,
                begin: { payload in try await runtimeClient.fsBegin(payload) },
                chunk: { payload in try await runtimeClient.fsChunk(payload) },
                end: { payload in try await runtimeClient.fsEnd(payload) }
            )
        }

        private func copyDirectoryHostToContainer(
            srcURL: URL,
            dstPath: String,
            runtimeClient: RuntimeClient
        ) async throws {
            let attrs = try FileManager.default.attributesOfItem(atPath: srcURL.path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.uint32Value
            let mtime = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
            let options = MacOSSidecarFileTransfer.WriteOptions(mode: mode, mtime: mtime)

            try await MacOSSidecarFileTransfer.createDirectory(
                at: dstPath,
                options: options,
                begin: { payload in try await runtimeClient.fsBegin(payload) }
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
                        begin: { payload in try await runtimeClient.fsBegin(payload) }
                    )
                } else {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: childSrc.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        try await copyDirectoryHostToContainer(
                            srcURL: childSrc,
                            dstPath: childDst,
                            runtimeClient: runtimeClient
                        )
                    } else {
                        try await copySingleFileHostToContainer(
                            srcURL: childSrc,
                            dstPath: childDst,
                            runtimeClient: runtimeClient
                        )
                    }
                }
            }
        }

        // MARK: - Container to Host

        private func copyContainerToHost(
            srcPath: String,
            dstURL: URL,
            runtimeClient: RuntimeClient
        ) async throws {
            let txID = UUID().uuidString
            let meta = try await runtimeClient.fsReadBegin(
                MacOSSidecarFSReadBeginRequestPayload(txID: txID, path: srcPath)
            )

            do {
                switch meta.fileType {
                case .file:
                    try await copyFileContainerToHost(
                        txID: txID,
                        meta: meta,
                        dstURL: dstURL,
                        runtimeClient: runtimeClient
                    )
                    try await runtimeClient.fsReadEnd(txID: txID)
                case .directory:
                    try await runtimeClient.fsReadEnd(txID: txID)
                    try await copyDirectoryContainerToHost(
                        srcPath: srcPath,
                        dstURL: dstURL,
                        runtimeClient: runtimeClient
                    )
                case .symlink:
                    try await runtimeClient.fsReadEnd(txID: txID)
                    guard let target = meta.linkTarget else {
                        throw ContainerizationError(.internalError, message: "symlink target missing for \(srcPath)")
                    }
                    let parent = dstURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dstURL)
                    try FileManager.default.createSymbolicLink(atPath: dstURL.path, withDestinationPath: target)
                }
            } catch {
                try? await runtimeClient.fsReadEnd(txID: txID)
                throw error
            }
        }

        private func copyFileContainerToHost(
            txID: String,
            meta: MacOSSidecarFSReadBeginResponsePayload,
            dstURL: URL,
            runtimeClient: RuntimeClient
        ) async throws {
            let parent = dstURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            let chunkSize = 256 * 1024
            _ = FileManager.default.createFile(atPath: dstURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: dstURL)
            defer { try? fileHandle.close() }
            try fileHandle.truncate(atOffset: 0)

            var offset: UInt64 = 0
            while true {
                let data = try await runtimeClient.fsReadChunk(
                    MacOSSidecarFSReadChunkRequestPayload(txID: txID, offset: offset, maxLength: chunkSize)
                )
                guard let data, !data.isEmpty else { break }
                try fileHandle.write(contentsOf: data)
                offset += UInt64(data.count)
            }

            if let mode = meta.mode {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)],
                    ofItemAtPath: dstURL.path
                )
            }
            if let mtime = meta.mtime {
                let date = Date(timeIntervalSince1970: TimeInterval(mtime))
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dstURL.path)
            }
        }

        private func copyDirectoryContainerToHost(
            srcPath: String,
            dstURL: URL,
            runtimeClient: RuntimeClient
        ) async throws {
            try FileManager.default.createDirectory(at: dstURL, withIntermediateDirectories: true)

            let entries = try await runtimeClient.fsListDir(
                MacOSSidecarFSListDirRequestPayload(txID: UUID().uuidString, path: srcPath)
            )

            for entry in entries {
                let childSrc = srcPath.hasSuffix("/") ? "\(srcPath)\(entry.name)" : "\(srcPath)/\(entry.name)"
                let childDst = dstURL.appendingPathComponent(entry.name)
                switch entry.fileType {
                case .file:
                    let fileTxID = UUID().uuidString
                    let fileMeta = try await runtimeClient.fsReadBegin(
                        MacOSSidecarFSReadBeginRequestPayload(txID: fileTxID, path: childSrc)
                    )
                    do {
                        try await copyFileContainerToHost(
                            txID: fileTxID,
                            meta: fileMeta,
                            dstURL: childDst,
                            runtimeClient: runtimeClient
                        )
                        try await runtimeClient.fsReadEnd(txID: fileTxID)
                    } catch {
                        try? await runtimeClient.fsReadEnd(txID: fileTxID)
                        throw error
                    }
                case .directory:
                    try await copyDirectoryContainerToHost(
                        srcPath: childSrc,
                        dstURL: childDst,
                        runtimeClient: runtimeClient
                    )
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
