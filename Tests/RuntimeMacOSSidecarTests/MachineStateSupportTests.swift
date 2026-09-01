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

#if os(macOS)
import ContainerResource
import Darwin
import Foundation
import Logging
import RuntimeMacOSSidecarShared
import Testing
import Virtualization

@testable import container_runtime_macos_sidecar

@Suite(.serialized)
struct MachineStateSupportTests {
    @Test
    func lifecycleEnforcesSaveStopExclusionAndIdempotency() throws {
        var lifecycle = MacOSVMLifecycleCoordinator()
        #expect(try lifecycle.begin(.start))
        lifecycle.complete(.start, succeeded: true)
        #expect(lifecycle.state == .running)
        #expect(try lifecycle.begin(.pause))
        lifecycle.complete(.pause, succeeded: true)
        #expect(lifecycle.state == .paused)
        #expect(try lifecycle.begin(.pause) == false)

        #expect(try lifecycle.begin(.save, stateID: "state-1"))
        do {
            try lifecycle.ensureNoOperationInProgress()
            Issue.record("expected stop to be rejected while save is in progress")
        } catch let error as SidecarRPCError {
            #expect(error.code == "operationInProgress")
        }
        lifecycle.complete(.save, succeeded: true)
        #expect(lifecycle.state == .paused)
        #expect(try lifecycle.begin(.stop))
        lifecycle.complete(.stop, succeeded: true)
        #expect(lifecycle.state == .stopped)
        #expect(try lifecycle.begin(.stop) == false)
    }

    @Test
    func restoreIsIdempotentOnlyForSameActiveState() throws {
        var lifecycle = MacOSVMLifecycleCoordinator()
        #expect(try lifecycle.begin(.restore, stateID: "state-a"))
        lifecycle.complete(.restore, succeeded: true)
        #expect(lifecycle.state == .paused)
        #expect(try lifecycle.begin(.restore, stateID: "state-a") == false)
        #expect(throws: SidecarRPCError.self) {
            try lifecycle.begin(.restore, stateID: "state-b")
        }
    }

    @Test
    func compatibilityRejectsDifferentHostBuildAndConfiguration() {
        let saved = makeCompatibility(hostBuild: "24A1", hostIdentifier: "host-a", configurationFingerprint: "config-a")
        let current = makeCompatibility(hostBuild: "24B2", hostIdentifier: "host-b", configurationFingerprint: "config-b")

        let reasons = MacOSMachineStateCompatibility.compare(saved: saved, current: current)
        #expect(reasons.map(\.code).contains("differentPhysicalHost"))
        #expect(reasons.map(\.code).contains("hostBuildMismatch"))
        #expect(reasons.map(\.code).contains("configurationMismatch"))
    }

    @Test
    func managedStorePublishesAtomicallyWithPrivatePermissions() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = MacOSMachineStateStore(runtimeRootURL: root)
        let staging = try store.createStaging(stateID: "state-1")
        try Data("machine-state".utf8).write(to: staging.stateURL)
        let compatibility = makeCompatibility()

        try store.commit(staging, compatibility: compatibility)
        let stored = try store.load(stateID: "state-1")
        #expect(stored.compatibility == compatibility)
        #expect(try permissions(stored.stateURL) == 0o600)
        #expect(try permissions(stored.stateURL.deletingLastPathComponent()) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: staging.directoryURL.path))
    }

    @Test
    func managedStoreRejectsTraversalAndSymbolicLinkRoot() throws {
        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineStateStore.validateStateID("../escape")
        }

        let parent = temporaryDirectory()
        let realRoot = parent.appendingPathComponent("real")
        let linkedRoot = parent.appendingPathComponent("linked")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

        do {
            _ = try MacOSMachineStateStore(runtimeRootURL: linkedRoot).createStaging(stateID: "state")
            Issue.record("expected symbolic-link runtime root to be rejected")
        } catch let error as SidecarRPCError {
            #expect(error.code == "unsafeMachineStatePath")
        }
    }

    @Test
    func managedStoreAbortRemovesIncompleteStagingDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = MacOSMachineStateStore(runtimeRootURL: root)
        let staging = try store.createStaging(stateID: "incomplete")
        try Data("partial".utf8).write(to: staging.stateURL)

        store.abort(staging)

        #expect(!FileManager.default.fileExists(atPath: staging.directoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: staging.finalURL.path))
    }

    @Test
    func managedStoreDistinguishesMissingAndIncompleteState() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = MacOSMachineStateStore(runtimeRootURL: root)

        do {
            _ = try store.load(stateID: "missing")
            Issue.record("expected missing state to fail")
        } catch let error as SidecarRPCError {
            #expect(error.code == "machineStateNotFound")
        }

        let staging = try store.createStaging(stateID: "incomplete")
        try FileManager.default.moveItem(at: staging.directoryURL, to: staging.finalURL)
        do {
            _ = try store.load(stateID: "incomplete")
            Issue.record("expected incomplete state to fail")
        } catch let error as SidecarRPCError {
            #expect(error.code == "machineStateIncomplete")
        }
    }

    @Test
    func blockDevicePathsRejectEscapeAndRemoteNBD() throws {
        let root = temporaryDirectory()
        #expect(throws: SidecarRPCError.self) {
            try MacOSBlockDeviceBuilder.managedDiskURL(rootURL: root, relativePath: "../Disk.img")
        }
        #expect(throws: SidecarRPCError.self) {
            try MacOSBlockDeviceBuilder.makeNBDURL(socketPath: "relative.sock", exportName: nil)
        }

        let url = try MacOSBlockDeviceBuilder.makeNBDURL(socketPath: "/var/run/vm-storage.sock", exportName: "root")
        #expect(url.scheme == "nbd+unix")
        #expect(url.host == nil)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "/var/run/vm-storage.sock")
    }

    @Test
    func nbdSocketIsProbedAndReconnectsAreObservable() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socketURL = URL(fileURLWithPath: "/tmp/container-ms-\(UUID().uuidString.prefix(8)).sock")
        let listener = try UnixSocketListener(path: socketURL.path, expectedConnections: 1)
        defer { listener.close() }

        let options = ContainerConfiguration.MacOSGuestOptions(
            snapshotEnabled: false,
            guiEnabled: false,
            agentPort: 27_000,
            blockDevices: [
                .init(identifier: "root", kind: .nbdUnixSocket, path: socketURL.path, exportName: "disk")
            ]
        )
        let result = try MacOSBlockDeviceBuilder.build(
            rootURL: root,
            options: options,
            log: Logger(label: "MachineStateSupportTests")
        )
        #expect(listener.wait() == .success)
        let observer = try #require(result.observers.first)
        let device = try #require(result.devices.first as? VZVirtioBlockDeviceConfiguration)
        let attachment = try #require(device.attachment as? VZNetworkBlockDeviceStorageDeviceAttachment)

        observer.attachmentWasConnected(attachment)
        observer.attachmentWasConnected(attachment)
        #expect(observer.snapshot().connectionCount == 2)
        #expect(observer.snapshot().terminalError == nil)
    }
}

private func makeCompatibility(
    hostBuild: String = "24A1",
    hostIdentifier: String = "host-a",
    configurationFingerprint: String = "config-a"
) -> MacOSMachineStateCompatibilityDescription {
    .init(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        hostBuild: hostBuild,
        hostModel: "MacTest1,1",
        hostIdentifier: hostIdentifier,
        hardwareModelFingerprint: "hardware",
        machineIdentifierFingerprint: "machine",
        configuration: .init(
            cpuCount: 4,
            memorySize: 8 * 1024 * 1024 * 1024,
            bootLoader: "macOS",
            networkBackend: "virtualizationNAT",
            storageDevices: [.init(kind: "runtimeDiskImage", identifier: "Disk.img", readOnly: false)],
            directoryShareCount: 0,
            hasGraphics: true,
            hasVirtioSocket: true,
            fingerprint: configurationFingerprint
        )
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("machine-state-tests-\(UUID().uuidString)")
}

private func permissions(_ url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return UInt16(try #require(attributes[.posixPermissions] as? NSNumber).uint16Value)
}

private final class UnixSocketListener: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let done = DispatchSemaphore(value: 0)

    init(path: String, expectedConnections: Int) throws {
        self.path = path
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard bindResult == 0, Darwin.listen(fd, 2) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        Thread.detachNewThread { [fd, done] in
            for _ in 0..<expectedConnections {
                let accepted = Darwin.accept(fd, nil, nil)
                if accepted >= 0 { Darwin.close(accepted) }
            }
            done.signal()
        }
    }

    func wait() -> DispatchTimeoutResult {
        done.wait(timeout: .now() + 2)
    }

    func close() {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        _ = unlink(path)
    }
}
#endif
