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

import Darwin
import Foundation
import Testing

@testable import ContainerCRIShimMacOS

@Suite(.serialized)
struct CRIShimMachineStateMappingTests {
    @Test
    func lexicalPathNormalizationDoesNotConsultFilesystem() {
        #expect(criLexicallyNormalizedAbsolutePath("/var/run/container/../nbd/root.sock") == "/var/run/nbd/root.sock")
        #expect(criLexicallyNormalizedAbsolutePath("/private//var/./run/container") == "/private/var/run/container")
        #expect(criLexicallyNormalizedAbsolutePath("../../relative") == nil)
        #expect(criLexicallyNormalizedAbsolutePath("/../../escape") == nil)
        #expect(criLexicallyNormalizedAbsolutePath("/safe\0unsafe") == nil)
    }

    @Test
    func absentOrExplicitlyDisabledAnnotationsPreserveLegacyConfiguration() throws {
        #expect(try makeCRIShimMachineStateMapping(annotations: [:], nodeConfig: nil) == .disabled)
        #expect(
            try makeCRIShimMachineStateMapping(
                annotations: [CRIShimMachineStateAnnotation.enabled: "false"],
                nodeConfig: nil
            ) == .disabled
        )
    }

    @Test
    func mapsStablePersistentPathsAndFullSynchronizationNBDDevices() throws {
        let roots = try MachineStateTestRoots()
        defer { roots.remove() }
        let listener = try MachineStateUnixListener(path: roots.nbdSocket.path, expectedConnections: 1)
        defer { listener.close() }

        let mapping = try makeCRIShimMachineStateMapping(
            annotations: [
                CRIShimMachineStateAnnotation.enabled: "true",
                CRIShimMachineStateAnnotation.persistenceID: "pod-uid-1",
                CRIShimMachineStateAnnotation.storageGeneration: "1",
                CRIShimMachineStateAnnotation.blockDevices: """
                [{"identifier":"root","unixSocket":"\(roots.nbdSocket.path)","exportName":"root-disk","timeoutSeconds":8}]
                """,
            ],
            nodeConfig: roots.config
        )

        #expect(listener.wait() == .success)
        #expect(mapping.machineState?.protocolVersion == 2)
        #expect(mapping.machineState?.persistenceID == "pod-uid-1")
        #expect(mapping.machineState?.restoreStateID == nil)
        #expect(mapping.machineState?.restoreStateGeneration == nil)
        #expect(mapping.machineState?.storageGeneration == 1)
        #expect(mapping.machineState?.storageDirectory == roots.storageRoot.appendingPathComponent("pod-uid-1").path)
        #expect(mapping.machineState?.controlSocketPath == roots.controlRoot.appendingPathComponent("pod-uid-1.sock").path)
        #expect(mapping.blockDevices.map(\.identifier) == ["root"])
        #expect(mapping.blockDevices[0].kind == .nbdUnixSocket)
        #expect(mapping.blockDevices[0].synchronizationMode == .full)
    }

    @Test
    func recreatedSandboxReusesPersistentDirectoryAndStableSocket() throws {
        let roots = try MachineStateTestRoots()
        defer { roots.remove() }
        let annotations = [
            CRIShimMachineStateAnnotation.enabled: "true",
            CRIShimMachineStateAnnotation.persistenceID: "stable-pod",
            CRIShimMachineStateAnnotation.storageGeneration: "1",
        ]

        let first = try makeCRIShimMachineStateMapping(annotations: annotations, nodeConfig: roots.config)
        let firstStorage = URL(fileURLWithPath: try #require(first.machineState?.storageDirectory))
        let marker = firstStorage.appendingPathComponent("saved-state-marker")
        try Data("preserved".utf8).write(to: marker)

        let recreated = try makeCRIShimMachineStateMapping(annotations: annotations, nodeConfig: roots.config)
        #expect(recreated.machineState?.storageDirectory == first.machineState?.storageDirectory)
        #expect(recreated.machineState?.controlSocketPath == first.machineState?.controlSocketPath)
        #expect(try Data(contentsOf: marker) == Data("preserved".utf8))
        #expect(try permissions(firstStorage) == 0o700)
        #expect(try permissions(roots.controlRoot) == 0o700)
        #expect(try owner(firstStorage) == geteuid())
        #expect(try owner(roots.controlRoot) == geteuid())
    }

    @Test
    func missingIntermediateDirectoriesArePrivateAndOwnedByRuntimeUser() throws {
        let roots = try MachineStateTestRoots()
        defer { roots.remove() }
        let storageNamespace = roots.root.appendingPathComponent("storage-namespace", isDirectory: true)
        let controlNamespace = roots.root.appendingPathComponent("control-namespace", isDirectory: true)
        let storageRoot = storageNamespace.appendingPathComponent("v1", isDirectory: true)
        let controlRoot = controlNamespace.appendingPathComponent("v1", isDirectory: true)
        let config = MachineStateConfig(
            enabled: true,
            storageRoot: storageRoot.path,
            controlSocketRoot: controlRoot.path,
            runtimeOwnerUID: UInt32(geteuid())
        )

        _ = try makeCRIShimMachineStateMapping(
            annotations: [
                CRIShimMachineStateAnnotation.enabled: "true",
                CRIShimMachineStateAnnotation.persistenceID: "pod-a",
                CRIShimMachineStateAnnotation.storageGeneration: "1",
            ],
            nodeConfig: config
        )

        for directory in [storageNamespace, storageRoot, controlNamespace, controlRoot] {
            #expect(try permissions(directory) == 0o700)
            #expect(try owner(directory) == geteuid())
        }
    }

    @Test
    func rejectsInvalidEnablementAndMapsRestoreGenerations() throws {
        let roots = try MachineStateTestRoots()
        defer { roots.remove() }

        #expect(throws: CRIShimError.self) {
            try makeCRIShimMachineStateMapping(
                annotations: [CRIShimMachineStateAnnotation.enabled: "TRUE"],
                nodeConfig: roots.config
            )
        }
        #expect(throws: CRIShimError.self) {
            try makeCRIShimMachineStateMapping(
                annotations: [CRIShimMachineStateAnnotation.persistenceID: "pod-a"],
                nodeConfig: roots.config
            )
        }
        #expect(throws: CRIShimError.self) {
            try makeCRIShimMachineStateMapping(
                annotations: [
                    CRIShimMachineStateAnnotation.enabled: "true",
                    CRIShimMachineStateAnnotation.persistenceID: "../escape",
                    CRIShimMachineStateAnnotation.storageGeneration: "1",
                ],
                nodeConfig: roots.config
            )
        }
        let restored = try makeCRIShimMachineStateMapping(
            annotations: [
                CRIShimMachineStateAnnotation.enabled: "true",
                CRIShimMachineStateAnnotation.persistenceID: "pod-a",
                CRIShimMachineStateAnnotation.restoreStateID: "state-a",
                CRIShimMachineStateAnnotation.restoreStateGeneration: "7",
                CRIShimMachineStateAnnotation.restorePairID: String(repeating: "a", count: 64),
                CRIShimMachineStateAnnotation.restoreManifestDigest: String(repeating: "b", count: 64),
                CRIShimMachineStateAnnotation.restoreRequestID: "restore-a",
                CRIShimMachineStateAnnotation.storageGeneration: "8",
            ],
            nodeConfig: roots.config
        )
        #expect(restored.machineState?.restoreStateID == "state-a")
        #expect(restored.machineState?.restoreStateGeneration == 7)
        #expect(restored.machineState?.pairID == String(repeating: "a", count: 64))
        #expect(restored.machineState?.adoptionManifestDigest == String(repeating: "b", count: 64))
        #expect(restored.machineState?.restoreRequestID == "restore-a")
        #expect(restored.machineState?.storageGeneration == 8)

        #expect(throws: CRIShimError.self) {
            try makeCRIShimMachineStateMapping(
                annotations: [
                    CRIShimMachineStateAnnotation.enabled: "true",
                    CRIShimMachineStateAnnotation.persistenceID: "pod-a",
                    CRIShimMachineStateAnnotation.restoreStateID: "state-a",
                    CRIShimMachineStateAnnotation.storageGeneration: "8",
                ],
                nodeConfig: roots.config
            )
        }
    }

    @Test
    func rejectsNBDOutsideAllowlistWrongRootOrderAndDisconnectedSocket() throws {
        let roots = try MachineStateTestRoots()
        defer { roots.remove() }
        let outsideSocket = roots.root.appendingPathComponent("outside.sock")
        let outsideListener = try MachineStateUnixListener(path: outsideSocket.path, expectedConnections: 0)
        defer { outsideListener.close() }

        #expect(throws: CRIShimError.self) {
            try mappingWithBlockDevices(
                "[{\"identifier\":\"root\",\"unixSocket\":\"\(outsideSocket.path)\"}]",
                roots: roots
            )
        }
        #expect(throws: CRIShimError.self) {
            try mappingWithBlockDevices(
                "[{\"identifier\":\"data\",\"unixSocket\":\"\(roots.nbdSocket.path)\"}]",
                roots: roots
            )
        }
        #expect(throws: CRIShimError.self) {
            try mappingWithBlockDevices(
                "[{\"identifier\":\"root\",\"unixSocket\":\"\(roots.nbdSocket.path)\"}]",
                roots: roots
            )
        }
        #expect(throws: CRIShimError.self) {
            try mappingWithBlockDevices(
                "[{\"identifier\":\"root\",\"unixSocket\":\"\(roots.nbdSocket.path)\",\"vendor\":\"unsupported\"}]",
                roots: roots
            )
        }
    }

    @Test
    func rejectsSymlinksInPersistentAndNBDPaths() throws {
        let roots = try MachineStateTestRoots()
        defer { roots.remove() }
        let realStorage = roots.root.appendingPathComponent("real-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: realStorage, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: roots.storageRoot, withDestinationURL: realStorage)
        #expect(throws: CRIShimError.self) {
            try makeCRIShimMachineStateMapping(
                annotations: [
                    CRIShimMachineStateAnnotation.enabled: "true",
                    CRIShimMachineStateAnnotation.persistenceID: "pod-a",
                    CRIShimMachineStateAnnotation.storageGeneration: "1",
                ],
                nodeConfig: roots.config
            )
        }

        let nbdRoots = try MachineStateTestRoots()
        defer { nbdRoots.remove() }
        let actualSocket = nbdRoots.root.appendingPathComponent("actual.sock")
        let listener = try MachineStateUnixListener(path: actualSocket.path, expectedConnections: 0)
        defer { listener.close() }
        try FileManager.default.createSymbolicLink(at: nbdRoots.nbdSocket, withDestinationURL: actualSocket)
        #expect(throws: CRIShimError.self) {
            try mappingWithBlockDevices(
                "[{\"identifier\":\"root\",\"unixSocket\":\"\(nbdRoots.nbdSocket.path)\"}]",
                roots: nbdRoots
            )
        }

        let intermediateRoots = try MachineStateTestRoots()
        defer { intermediateRoots.remove() }
        let realParent = intermediateRoots.root.appendingPathComponent("real-parent", isDirectory: true)
        let linkedParent = intermediateRoots.root.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        var linkedConfig = intermediateRoots.config
        linkedConfig.storageRoot = linkedParent.appendingPathComponent("state", isDirectory: true).path
        #expect(throws: CRIShimError.self) {
            try makeCRIShimMachineStateMapping(
                annotations: [
                    CRIShimMachineStateAnnotation.enabled: "true",
                    CRIShimMachineStateAnnotation.persistenceID: "pod-a",
                    CRIShimMachineStateAnnotation.storageGeneration: "1",
                ],
                nodeConfig: linkedConfig
            )
        }
    }
}

private func mappingWithBlockDevices(
    _ blockDevices: String,
    roots: MachineStateTestRoots
) throws -> CRIShimMachineStateMapping {
    try makeCRIShimMachineStateMapping(
        annotations: [
            CRIShimMachineStateAnnotation.enabled: "true",
            CRIShimMachineStateAnnotation.persistenceID: "pod-a",
            CRIShimMachineStateAnnotation.storageGeneration: "1",
            CRIShimMachineStateAnnotation.blockDevices: blockDevices,
        ],
        nodeConfig: roots.config
    )
}

private struct MachineStateTestRoots {
    let root: URL
    let storageRoot: URL
    let controlRoot: URL
    let nbdRoot: URL
    let nbdSocket: URL

    init() throws {
        let root = URL(fileURLWithPath: "/tmp/cms-\(UUID().uuidString)", isDirectory: true)
        let nbdRoot = root.appendingPathComponent("nbd", isDirectory: true)
        self.root = root
        self.storageRoot = root.appendingPathComponent("state", isDirectory: true)
        self.controlRoot = root.appendingPathComponent("control", isDirectory: true)
        self.nbdRoot = nbdRoot
        self.nbdSocket = nbdRoot.appendingPathComponent("root.sock")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: nbdRoot, withIntermediateDirectories: false)
    }

    var config: MachineStateConfig {
        .init(
            enabled: true,
            storageRoot: storageRoot.path,
            controlSocketRoot: controlRoot.path,
            runtimeOwnerUID: UInt32(geteuid()),
            nbdSocketAllowedRoots: [nbdRoot.path],
            leaseRoot: root.appendingPathComponent("leases", isDirectory: true).path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class MachineStateUnixListener: @unchecked Sendable {
    private let path: String
    private let listenFD: Int32
    private let done = DispatchSemaphore(value: 0)

    init(path: String, expectedConnections: Int) throws {
        self.path = path
        listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(listenFD)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, length)
            }
        }
        guard result == 0, Darwin.listen(listenFD, 4) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(listenFD)
            throw error
        }
        if expectedConnections == 0 {
            done.signal()
        } else {
            Thread.detachNewThread { [listenFD, done] in
                for _ in 0..<expectedConnections {
                    let client = Darwin.accept(listenFD, nil, nil)
                    if client >= 0 { Darwin.close(client) }
                }
                done.signal()
            }
        }
    }

    func wait() -> DispatchTimeoutResult {
        done.wait(timeout: .now() + 2)
    }

    func close() {
        _ = Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        _ = unlink(path)
    }
}

private func permissions(_ url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return UInt16((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0)
}

private func owner(_ url: URL) throws -> uid_t {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return value.st_uid
}
