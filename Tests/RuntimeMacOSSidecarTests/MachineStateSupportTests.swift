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
import CryptoKit
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
    func processStartAdmissionIsMutuallyExclusiveWithPause() throws {
        var lifecycle = MacOSVMLifecycleCoordinator()
        #expect(try lifecycle.begin(.start))
        lifecycle.complete(.start, succeeded: true)

        let admission = try lifecycle.acquireProcessStartAdmission()
        do {
            _ = try lifecycle.begin(.pause)
            Issue.record("pause began while process start admission was held")
        } catch let error as SidecarRPCError {
            #expect(error.code == "operationInProgress")
        }
        lifecycle.releaseProcessStartAdmission(admission)

        #expect(try lifecycle.begin(.pause))
        #expect(throws: SidecarRPCError.self) {
            try lifecycle.acquireProcessStartAdmission()
        }
        lifecycle.complete(.pause, succeeded: true)
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
    func deletionIsRejectedOnlyWhileTheSameStateIsBeingSavedOrRestored() throws {
        var lifecycle = MacOSVMLifecycleCoordinator()
        #expect(try lifecycle.begin(.restore, stateID: "state-a"))
        #expect(throws: SidecarRPCError.self) {
            try lifecycle.ensureStateCanBeDeleted("state-a")
        }
        try lifecycle.ensureStateCanBeDeleted("state-b")
        lifecycle.complete(.restore, succeeded: true)
        #expect(throws: SidecarRPCError.self) {
            try lifecycle.ensureStateCanBeDeleted("state-a")
        }
        #expect(try lifecycle.begin(.resume))
        #expect(throws: SidecarRPCError.self) {
            try lifecycle.ensureStateCanBeDeleted("state-a")
        }
        lifecycle.complete(.resume, succeeded: true)
        try lifecycle.ensureStateCanBeDeleted("state-a")
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
    func savedManifestClosesOverExternalDiskGeneration() throws {
        try MacOSMachineStateStorageGeneration.validateIdempotentSave(
            saved: makeCompatibility(),
            current: makeCompatibility()
        )
        try MacOSMachineStateStorageGeneration.validateRestore(
            saved: makeCompatibility(),
            selectedSavedGeneration: nil
        )

        let saved = makeCompatibility(storageGeneration: 7)
        let sameWritableDisk = makeCompatibility(storageGeneration: 7)
        let successorWritableDisk = makeCompatibility(storageGeneration: 8)

        try MacOSMachineStateStorageGeneration.validateIdempotentSave(
            saved: saved,
            current: sameWritableDisk
        )
        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineStateStorageGeneration.validateIdempotentSave(
                saved: saved,
                current: successorWritableDisk
            )
        }
        try MacOSMachineStateStorageGeneration.validateRestore(
            saved: saved,
            selectedSavedGeneration: 7
        )
        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineStateStorageGeneration.validateRestore(
                saved: saved,
                selectedSavedGeneration: 8
            )
        }
    }

    @Test
    func durablePairIDMatchesControlPlaneWireVector() {
        let pairID = MacOSMachineStateStore.durablePairID(
            persistenceID: "workload-42",
            stateID: "snapshot-123",
            diskSnapshotRef: "macos/kross-workload-42-g7@snapshot-123",
            sourceStorageGeneration: 7,
            compatibilityClass: "macos-arm64-v1",
            adoptionManifestDigest: String(repeating: "a", count: 64)
        )
        #expect(pairID == "67d8972e0be4038fd3908cd0d4b3114c5a2fbdb6b4132ddfcc20bcdb0c881127")
    }

    @Test
    func durableStoreCommitsAndReadsBackExactPair() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = MacOSMachineStateStore(runtimeRootURL: root)
        let reservation = try store.reserve(stateID: "snapshot-123")
        try Data("machine-state".utf8).write(to: reservation.stateURL)
        let adoption = MacOSMachineStateAdoptionManifest(
            checkpointID: "snapshot-123",
            persistenceID: "workload-42",
            sourcePodUID: "source-pod",
            sourceStorageGeneration: 7,
            workloads: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let adoptionDigest = SHA256.hash(data: try encoder.encode(adoption))
            .map { String(format: "%02x", $0) }
            .joined()
        let snapshot = MacOSMachineStateDiskSnapshotReceipt(
            snapshotID: "snapshot-123",
            volumeID: "workload-42-g7",
            snapshotRef: "macos/kross-workload-42-g7@snapshot-123",
            storageGeneration: 7,
            operationID: "suspend-42",
            operationSequence: 9,
            ownerEpoch: 2
        )
        let pair = MacOSMachineStateDurablePair(
            pairID: MacOSMachineStateStore.durablePairID(
                persistenceID: adoption.persistenceID,
                stateID: adoption.checkpointID,
                diskSnapshotRef: snapshot.snapshotRef,
                sourceStorageGeneration: adoption.sourceStorageGeneration,
                compatibilityClass: "macos-arm64-v1",
                adoptionManifestDigest: adoptionDigest
            ),
            persistenceID: adoption.persistenceID,
            stateID: adoption.checkpointID,
            stateGeneration: adoption.sourceStorageGeneration,
            diskSnapshot: snapshot,
            compatibilityClass: "macos-arm64-v1",
            adoptionManifestDigest: adoptionDigest
        )

        let receipt = try store.commit(
            reservation,
            compatibility: makeCompatibility(storageGeneration: 7),
            adoption: adoption,
            pair: pair
        )
        let stored = try store.load(stateID: "snapshot-123")

        #expect(receipt.pair == pair)
        #expect(stored.receipt?.pair == pair)
        #expect(stored.receipt?.adoption == adoption)
        #expect(stored.receipt?.committed == true)
    }

    @Test
    func managedStoreKeepsStatePathStableAndUsesPrivatePermissions() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = MacOSMachineStateStore(runtimeRootURL: root)
        let reservation = try store.reserve(stateID: "state-1")
        try Data("machine-state".utf8).write(to: reservation.stateURL)
        let compatibility = makeCompatibility()

        try store.commit(reservation, compatibility: compatibility)
        let stored = try store.load(stateID: "state-1")
        #expect(stored.compatibility == compatibility)
        #expect(stored.directoryURL == reservation.directoryURL)
        #expect(stored.stateURL == reservation.stateURL)
        #expect(try permissions(stored.stateURL) == 0o600)
        #expect(try permissions(stored.stateURL.deletingLastPathComponent()) == 0o700)
    }

    @Test
    func persistentRootCreatesOnlyBindingChildAndRejectsUnsafeParent() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        #expect(chmod(parent.path, mode_t(0o700)) == 0)
        let bindingRoot = parent.appendingPathComponent("workload-42")

        try MacOSMachineStateStore.preparePersistentRoot(at: bindingRoot)
        #expect(try permissions(bindingRoot) == 0o700)
        try MacOSMachineStateStore.preparePersistentRoot(at: bindingRoot)

        #expect(chmod(parent.path, mode_t(0o777)) == 0)
        #expect(throws: SidecarRPCError.self) {
            try MacOSMachineStateStore.preparePersistentRoot(at: parent.appendingPathComponent("workload-43"))
        }
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
            _ = try MacOSMachineStateStore(runtimeRootURL: linkedRoot).reserve(stateID: "state")
            Issue.record("expected symbolic-link runtime root to be rejected")
        } catch let error as SidecarRPCError {
            #expect(error.code == "unsafeMachineStatePath")
        }

        let realParent = parent.appendingPathComponent("real-parent")
        let linkedParent = parent.appendingPathComponent("linked-parent")
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        let nestedRoot = linkedParent.appendingPathComponent("state")
        try FileManager.default.createDirectory(
            at: realParent.appendingPathComponent("state"),
            withIntermediateDirectories: false
        )
        do {
            _ = try MacOSMachineStateStore(runtimeRootURL: nestedRoot).reserve(stateID: "state")
            Issue.record("expected a symbolic-link ancestor to be rejected")
        } catch let error as SidecarRPCError {
            #expect(error.code == "unsafeMachineStatePath")
        }
    }

    @Test
    func managedStoreAbortRemovesIncompleteReservedDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = MacOSMachineStateStore(runtimeRootURL: root)
        let reservation = try store.reserve(stateID: "incomplete")
        try Data("partial".utf8).write(to: reservation.stateURL)

        store.abort(reservation)

        #expect(!FileManager.default.fileExists(atPath: reservation.directoryURL.path))
    }

    @Test
    func managedStoreDeleteIsIdempotentAndRemovesCommittedState() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = MacOSMachineStateStore(runtimeRootURL: root)
        let reservation = try store.reserve(stateID: "delete-me")
        try Data("machine-state".utf8).write(to: reservation.stateURL)
        try store.commit(reservation, compatibility: makeCompatibility())

        #expect(try store.delete(stateID: "delete-me"))
        #expect(try store.delete(stateID: "delete-me") == false)
        #expect(throws: SidecarRPCError.self) {
            _ = try store.load(stateID: "delete-me")
        }

        let incomplete = try store.reserve(stateID: "delete-incomplete")
        try Data("partial".utf8).write(to: incomplete.stateURL)
        #expect(try store.delete(stateID: "delete-incomplete"))
        #expect(try store.delete(stateID: "delete-incomplete") == false)
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

        _ = try store.reserve(stateID: "incomplete")
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
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "/private/var/run/vm-storage.sock")
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

    @Test
    func nbdSocketStartupWaitsForNodeLocalPublisher() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socketURL = URL(fileURLWithPath: "/tmp/container-ms-wait-\(UUID().uuidString.prefix(8)).sock")
        let publisherStarted = DispatchSemaphore(value: 0)
        let listenerStarted = DispatchSemaphore(value: 0)
        let listenerFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            publisherStarted.signal()
            Thread.sleep(forTimeInterval: 0.05)
            guard let listener = try? UnixSocketListener(path: socketURL.path, expectedConnections: 1) else {
                listenerFinished.signal()
                return
            }
            listenerStarted.signal()
            _ = listener.wait()
            listener.close()
            listenerFinished.signal()
        }
        defer { #expect(listenerFinished.wait(timeout: .now() + 5) == .success) }
        try #require(publisherStarted.wait(timeout: .now() + 5) == .success)

        let options = ContainerConfiguration.MacOSGuestOptions(
            snapshotEnabled: false,
            guiEnabled: false,
            agentPort: 27_000,
            blockDevices: [
                .init(
                    identifier: "root",
                    kind: .nbdUnixSocket,
                    path: socketURL.path,
                    timeoutSeconds: 1
                )
            ]
        )
        _ = try MacOSBlockDeviceBuilder.build(
            rootURL: root,
            options: options,
            log: Logger(label: "MachineStateSupportTests")
        )

        #expect(listenerStarted.wait(timeout: .now()) == .success)
    }

    @Test
    func nbdSocketStartupFailsAfterBoundedWait() throws {
        let socketPath = "/tmp/container-ms-missing-\(UUID().uuidString.prefix(8)).sock"
        let startedAt = DispatchTime.now().uptimeNanoseconds

        do {
            try MacOSBlockDeviceBuilder.waitForUnixSocket(path: socketPath, timeoutSeconds: 0.1)
            Issue.record("missing NBD socket unexpectedly became ready")
        } catch let error as SidecarRPCError {
            #expect(error.code == "storageUnavailable")
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        #expect(elapsed >= 0.09)
        #expect(elapsed < 1)
    }

    @Test
    func nbdSocketRejectsTraversalAndSymlinkedParentsBeforeConnecting() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        for path in [link.path + "/root.sock", real.path + "/../root.sock", real.path + "//root.sock"] {
            do {
                try MacOSBlockDeviceBuilder.waitForUnixSocket(path: path, timeoutSeconds: 0.1)
                Issue.record("unsafe NBD socket path was accepted")
            } catch let error as SidecarRPCError {
                #expect(error.code == "invalidStorageConfiguration")
            }
        }
    }
}

private func makeCompatibility(
    hostBuild: String = "24A1",
    hostIdentifier: String = "host-a",
    configurationFingerprint: String = "config-a",
    storageGeneration: UInt64? = nil
) -> MacOSMachineStateCompatibilityDescription {
    .init(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        hostBuild: hostBuild,
        hostModel: "MacTest1,1",
        hostIdentifier: hostIdentifier,
        hardwareModelFingerprint: "hardware",
        machineIdentifierFingerprint: "machine",
        storageGeneration: storageGeneration,
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
    let temporaryPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
    let canonicalPath = temporaryPath.hasPrefix("/var/") ? "/private\(temporaryPath)" : temporaryPath
    return URL(fileURLWithPath: canonicalPath, isDirectory: true)
        .appendingPathComponent("machine-state-tests-\(UUID().uuidString)")
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
