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

import ContainerResource
import CryptoKit
import Darwin
import Foundation
import IOKit
import Logging
import RuntimeMacOSSidecarShared
@preconcurrency import Virtualization

struct SidecarRPCError: Error, Sendable {
    let code: String
    let message: String
    let details: String?
    let metadata: [String: String]?

    init(code: String, message: String, details: String? = nil, metadata: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
        self.metadata = metadata
    }
}

struct MacOSVMLifecycleCoordinator: Sendable {
    enum Operation: String, Sendable {
        case start
        case pause
        case resume
        case save
        case restore
        case stop
    }

    private(set) var state: MacOSVMRuntimeState = .created
    private(set) var activeStateID: String?
    private var inFlight: (operation: Operation, previous: MacOSVMRuntimeState, stateID: String?)?

    /// Returns false when the requested operation is already satisfied.
    mutating func begin(_ operation: Operation, stateID: String? = nil) throws -> Bool {
        try ensureNoOperationInProgress()

        let next: MacOSVMRuntimeState
        switch (operation, state) {
        case (.start, .running), (.pause, .paused), (.resume, .running), (.stop, .stopped):
            return false
        case (.restore, .paused) where activeStateID == stateID:
            return false
        case (.start, .created), (.start, .stopped):
            next = .starting
        case (.pause, .running):
            next = .pausing
        case (.resume, .paused):
            next = .resuming
        case (.save, .paused):
            next = .saving
        case (.restore, .created), (.restore, .stopped):
            next = .restoring
        case (.stop, .created):
            state = .stopped
            return false
        case (.stop, .running), (.stop, .paused), (.stop, .failed):
            next = .stopping
        default:
            throw SidecarRPCError(
                code: "invalidLifecycleState",
                message: "cannot \(operation.rawValue) VM while lifecycle state is \(state.rawValue)",
                metadata: ["lifecycleState": state.rawValue, "operation": operation.rawValue]
            )
        }

        inFlight = (operation, state, stateID)
        state = next
        return true
    }

    func ensureNoOperationInProgress() throws {
        if let inFlight {
            throw SidecarRPCError(
                code: "operationInProgress",
                message: "VM operation \(inFlight.operation.rawValue) is in progress",
                metadata: ["lifecycleState": state.rawValue, "operation": inFlight.operation.rawValue]
            )
        }
    }

    mutating func complete(_ operation: Operation, succeeded: Bool) {
        guard let inFlight, inFlight.operation == operation else {
            state = .failed
            self.inFlight = nil
            return
        }
        defer { self.inFlight = nil }

        guard succeeded else {
            state = inFlight.previous
            return
        }
        switch operation {
        case .start, .resume:
            state = .running
            if operation == .start { activeStateID = nil }
        case .pause, .save:
            state = .paused
        case .restore:
            state = .paused
            activeStateID = inFlight.stateID
        case .stop:
            state = .stopped
            activeStateID = nil
        }
    }

}

struct MacOSMachineStateStore: Sendable {
    struct Reservation: Sendable {
        let directoryURL: URL
        let stateURL: URL
    }

    struct StoredState: Sendable {
        let stateURL: URL
        let compatibility: MacOSMachineStateCompatibilityDescription
    }

    private let rootURL: URL
    private let statesURL: URL

    init(runtimeRootURL: URL) {
        rootURL = runtimeRootURL.standardizedFileURL
        statesURL = rootURL.appendingPathComponent("MachineStates", isDirectory: true)
    }

    func reserve(stateID: String) throws -> Reservation {
        try Self.validateStateID(stateID)
        try validateRuntimeRoot()
        try createPrivateDirectory(statesURL)

        let finalURL = statesURL.appendingPathComponent(stateID, isDirectory: true)
        var finalValue = stat()
        if lstat(finalURL.path, &finalValue) == 0 {
            throw SidecarRPCError(code: "machineStateAlreadyExists", message: "machine state \(stateID) already exists")
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: false)
        guard chmod(finalURL.path, mode_t(S_IRWXU)) == 0 else {
            try? FileManager.default.removeItem(at: finalURL)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Reservation(
            directoryURL: finalURL,
            stateURL: finalURL.appendingPathComponent("machine-state.vzstate")
        )
    }

    func commit(_ reservation: Reservation, compatibility: MacOSMachineStateCompatibilityDescription) throws {
        try requireDirectory(statesURL)
        try requireDirectory(reservation.directoryURL)
        try requireRegularFile(reservation.stateURL)
        guard chmod(reservation.stateURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // Virtualization.framework binds a saved machine state to the URL used by
        // saveMachineState. Keep that URL stable and publish the manifest last as
        // the atomic commit marker for readers.
        let manifestURL = reservation.directoryURL.appendingPathComponent("compatibility.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(compatibility).write(to: manifestURL, options: .atomic)
        guard chmod(manifestURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func abort(_ reservation: Reservation) {
        try? FileManager.default.removeItem(at: reservation.directoryURL)
    }

    func load(stateID: String) throws -> StoredState {
        try Self.validateStateID(stateID)
        try validateRuntimeRoot()
        do {
            try requireDirectory(statesURL)
        } catch let error as POSIXError where error.code == .ENOENT {
            throw SidecarRPCError(code: "machineStateNotFound", message: "machine state \(stateID) does not exist")
        }
        let directoryURL = statesURL.appendingPathComponent(stateID, isDirectory: true)
        do {
            try requireDirectory(directoryURL)
        } catch let error as POSIXError where error.code == .ENOENT {
            throw SidecarRPCError(code: "machineStateNotFound", message: "machine state \(stateID) does not exist")
        }
        let stateURL = directoryURL.appendingPathComponent("machine-state.vzstate")
        let manifestURL = directoryURL.appendingPathComponent("compatibility.json")
        do {
            try requireRegularFile(stateURL)
            try requireRegularFile(manifestURL)
        } catch let error as POSIXError where error.code == .ENOENT {
            throw SidecarRPCError(code: "machineStateIncomplete", message: "machine state \(stateID) is incomplete")
        }
        let compatibility = try JSONDecoder().decode(
            MacOSMachineStateCompatibilityDescription.self,
            from: Data(contentsOf: manifestURL, options: .uncached)
        )
        return StoredState(stateURL: stateURL, compatibility: compatibility)
    }

    static func validateStateID(_ value: String) throws {
        guard !value.isEmpty, value.count <= 128 else {
            throw SidecarRPCError(code: "invalidMachineStateID", message: "machine state id must contain 1 to 128 characters")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard value != ".", value != "..", value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SidecarRPCError(
                code: "invalidMachineStateID",
                message: "machine state id may contain only letters, digits, dot, underscore, and hyphen"
            )
        }
    }

    private func validateRuntimeRoot() throws {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
            throw SidecarRPCError(code: "unsafeMachineStatePath", message: "runtime root must be an absolute file path")
        }
        try requireDirectory(rootURL)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try requireDirectory(url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        guard chmod(url.path, mode_t(S_IRWXU)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func requireDirectory(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        guard (value.st_mode & S_IFMT) == S_IFDIR else {
            throw SidecarRPCError(code: "unsafeMachineStatePath", message: "expected directory at \(url.path)")
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw SidecarRPCError(code: "unsafeMachineStatePath", message: "expected regular file at \(url.path)")
        }
    }

    static func rejectSymbolicLinks(below rootURL: URL, through url: URL) throws {
        let root = rootURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(prefix) else {
            throw SidecarRPCError(code: "unsafeMachineStatePath", message: "managed path escapes the runtime root")
        }
        var rootValue = stat()
        guard lstat(root.path, &rootValue) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        if (rootValue.st_mode & S_IFMT) == S_IFLNK {
            throw SidecarRPCError(code: "unsafeMachineStatePath", message: "runtime root cannot be a symbolic link")
        }
        var current = root
        for component in candidate.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(component)
            var value = stat()
            if lstat(current.path, &value) != 0 {
                if errno == ENOENT { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if (value.st_mode & S_IFMT) == S_IFLNK {
                throw SidecarRPCError(code: "unsafeMachineStatePath", message: "symbolic links are not allowed in managed paths")
            }
        }
    }
}

enum MacOSMachineStateCompatibility {
    static func compare(
        saved: MacOSMachineStateCompatibilityDescription,
        current: MacOSMachineStateCompatibilityDescription
    ) -> [MacOSMachineStateUnsupportedReason] {
        var reasons: [MacOSMachineStateUnsupportedReason] = []
        if saved.schemaVersion != current.schemaVersion {
            reasons.append(.init(code: "schemaVersionMismatch", message: "compatibility schema version differs"))
        }
        if saved.runtimeProtocolVersion != current.runtimeProtocolVersion {
            reasons.append(.init(code: "runtimeProtocolVersionMismatch", message: "runtime protocol version differs"))
        }
        if saved.hostIdentifier != current.hostIdentifier {
            reasons.append(.init(code: "differentPhysicalHost", message: "machine state is bound to a different physical Mac"))
        }
        if saved.hostModel != current.hostModel {
            reasons.append(.init(code: "hostModelMismatch", message: "Mac model differs"))
        }
        if saved.hostBuild != current.hostBuild {
            reasons.append(.init(code: "hostBuildMismatch", message: "host macOS build differs"))
        }
        if saved.hardwareModelFingerprint != current.hardwareModelFingerprint {
            reasons.append(.init(code: "hardwareModelMismatch", message: "VM hardware model differs", configurationComponent: "platform.hardwareModel"))
        }
        if saved.machineIdentifierFingerprint != current.machineIdentifierFingerprint {
            reasons.append(.init(code: "machineIdentifierMismatch", message: "VM machine identifier differs", configurationComponent: "platform.machineIdentifier"))
        }
        if saved.configuration.fingerprint != current.configuration.fingerprint {
            reasons.append(.init(code: "configurationMismatch", message: "VM configuration differs", configurationComponent: "virtualMachineConfiguration"))
        }
        return reasons
    }
}

enum MacOSHostIdentity {
    static func value(forSysctl name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let content = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: content, as: UTF8.self)
    }

    static func hardwareUUID() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else {
            throw SidecarRPCError(code: "hostIdentityUnavailable", message: "IOPlatformExpertDevice is unavailable")
        }
        defer { IOObjectRelease(service) }
        guard
            let property = IORegistryEntryCreateCFProperty(
                service,
                "IOPlatformUUID" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String,
            !property.isEmpty
        else {
            throw SidecarRPCError(code: "hostIdentityUnavailable", message: "IOPlatformUUID is unavailable")
        }
        return property
    }
}

func sha256Fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum MacOSCompatibilityDescriptionBuilder {
    private struct FingerprintInput: Codable {
        let cpuCount: Int
        let memorySize: UInt64
        let networkBackend: String
        let networkDeviceMACAddresses: [String]
        let blockDevices: [ContainerConfiguration.MacOSGuestOptions.BlockDevice]
        let mounts: [Filesystem]
        let guiEnabled: Bool
        let agentPort: UInt32
    }

    static func make(
        containerConfig: ContainerConfiguration,
        hardwareModelData: Data,
        machineIdentifierData: Data,
        networkDeviceMACAddresses: [String],
        storageDescriptions: [MacOSMachineStateStorageDescription]
    ) throws -> MacOSMachineStateCompatibilityDescription {
        let cpuCount = max(
            Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            min(Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount), containerConfig.resources.cpus)
        )
        let memorySize = max(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(VZVirtualMachineConfiguration.maximumAllowedMemorySize, containerConfig.resources.memoryInBytes)
        )
        let options = containerConfig.macosGuest
        let input = FingerprintInput(
            cpuCount: cpuCount,
            memorySize: memorySize,
            networkBackend: (options?.networkBackend ?? .virtualizationNAT).rawValue,
            networkDeviceMACAddresses: networkDeviceMACAddresses,
            blockDevices: options?.blockDevices ?? [],
            mounts: containerConfig.mounts,
            guiEnabled: options?.guiEnabled ?? false,
            agentPort: options?.agentPort ?? 27_000
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configurationFingerprint = sha256Fingerprint(try encoder.encode(input))
        let directoryShareCount = try MacOSGuestMountMapping.hostPathShares(from: containerConfig.mounts).count
        return .init(
            createdAt: Date(),
            hostBuild: try MacOSHostIdentity.value(forSysctl: "kern.osversion"),
            hostModel: try MacOSHostIdentity.value(forSysctl: "hw.model"),
            hostIdentifier: try MacOSHostIdentity.hardwareUUID(),
            hardwareModelFingerprint: sha256Fingerprint(hardwareModelData),
            machineIdentifierFingerprint: sha256Fingerprint(machineIdentifierData),
            configuration: .init(
                cpuCount: cpuCount,
                memorySize: memorySize,
                bootLoader: "macOS",
                networkBackend: input.networkBackend,
                networkDeviceMACAddresses: input.networkDeviceMACAddresses,
                storageDevices: storageDescriptions,
                directoryShareCount: directoryShareCount,
                hasGraphics: true,
                hasVirtioSocket: true,
                fingerprint: configurationFingerprint
            )
        )
    }
}

final class MacOSNBDConnectionObserver: NSObject, VZNetworkBlockDeviceStorageDeviceAttachmentDelegate, @unchecked Sendable {
    private let identifier: String
    private let log: Logger
    private let lock = NSLock()
    private var connectionCount = 0
    private var terminalError: String?

    init(identifier: String, log: Logger) {
        self.identifier = identifier
        self.log = log
    }

    func attachmentWasConnected(_ attachment: VZNetworkBlockDeviceStorageDeviceAttachment) {
        lock.lock()
        connectionCount += 1
        let count = connectionCount
        lock.unlock()
        log.info(
            count == 1 ? "NBD attachment connected" : "NBD attachment reconnected",
            metadata: ["identifier": "\(identifier)", "connection_count": "\(count)"]
        )
    }

    func attachment(_ attachment: VZNetworkBlockDeviceStorageDeviceAttachment, didEncounterError error: any Error) {
        lock.lock()
        terminalError = String(describing: error)
        lock.unlock()
        log.error("NBD attachment entered terminal error state", metadata: ["identifier": "\(identifier)", "error": "\(error)"])
    }

    func snapshot() -> (connectionCount: Int, terminalError: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (connectionCount, terminalError)
    }
}

struct MacOSBlockDeviceBuildResult {
    let devices: [VZStorageDeviceConfiguration]
    let descriptions: [MacOSMachineStateStorageDescription]
    let observers: [MacOSNBDConnectionObserver]
}

enum MacOSBlockDeviceBuilder {
    static func validateConfiguration(
        rootURL: URL,
        options: ContainerConfiguration.MacOSGuestOptions?
    ) throws {
        var identifiers = Set<String>()
        for device in options?.blockDevices ?? [] {
            guard !device.identifier.isEmpty, identifiers.insert(device.identifier).inserted else {
                throw SidecarRPCError(code: "invalidStorageConfiguration", message: "block device identifiers must be non-empty and unique")
            }
            switch device.kind {
            case .runtimeDiskImage:
                _ = try managedDiskURL(rootURL: rootURL, relativePath: device.path)
            case .nbdUnixSocket:
                guard device.timeoutSeconds.isFinite, (0.1...300).contains(device.timeoutSeconds) else {
                    throw SidecarRPCError(code: "invalidStorageConfiguration", message: "NBD timeout must be between 0.1 and 300 seconds")
                }
                try validateUnixSocket(path: device.path)
                try probeUnixSocket(path: device.path)
            }
        }
    }

    static func build(
        rootURL: URL,
        options: ContainerConfiguration.MacOSGuestOptions?,
        log: Logger
    ) throws -> MacOSBlockDeviceBuildResult {
        let configured = options?.blockDevices ?? []
        try validateConfiguration(rootURL: rootURL, options: options)
        if configured.isEmpty {
            let diskURL = rootURL.appendingPathComponent("Disk.img")
            let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
            return .init(
                devices: [VZVirtioBlockDeviceConfiguration(attachment: attachment)],
                descriptions: [.init(kind: "runtimeDiskImage", identifier: "Disk.img", readOnly: false)],
                observers: []
            )
        }

        var devices: [VZStorageDeviceConfiguration] = []
        var descriptions: [MacOSMachineStateStorageDescription] = []
        var observers: [MacOSNBDConnectionObserver] = []
        for device in configured {
            switch device.kind {
            case .runtimeDiskImage:
                let url = try managedDiskURL(rootURL: rootURL, relativePath: device.path)
                let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: device.readOnly)
                devices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
                descriptions.append(.init(kind: device.kind.rawValue, identifier: device.identifier, readOnly: device.readOnly))
            case .nbdUnixSocket:
                let url = try makeNBDURL(socketPath: device.path, exportName: device.exportName)
                try VZNetworkBlockDeviceStorageDeviceAttachment.validate(url)
                let synchronizationMode: VZDiskSynchronizationMode =
                    device.synchronizationMode == .full ? .full : .none
                let attachment = try VZNetworkBlockDeviceStorageDeviceAttachment(
                    url: url,
                    timeout: device.timeoutSeconds,
                    isForcedReadOnly: device.readOnly,
                    synchronizationMode: synchronizationMode
                )
                let observer = MacOSNBDConnectionObserver(identifier: device.identifier, log: log)
                attachment.delegate = observer
                observers.append(observer)
                devices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
                descriptions.append(
                    .init(
                        kind: device.kind.rawValue,
                        identifier: device.identifier,
                        readOnly: device.readOnly,
                        synchronizationMode: device.synchronizationMode.rawValue
                    )
                )
            }
        }
        return .init(devices: devices, descriptions: descriptions, observers: observers)
    }

    static func managedDiskURL(rootURL: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "runtime disk image path must be relative")
        }
        let root = rootURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "runtime disk image path escapes the runtime directory")
        }
        try MacOSMachineStateStore.rejectSymbolicLinks(below: root, through: candidate)
        return candidate
    }

    static func makeNBDURL(socketPath: String, exportName: String?) throws -> URL {
        guard socketPath.hasPrefix("/") else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "NBD Unix socket path must be absolute")
        }
        var components = URLComponents()
        components.scheme = "nbd+unix"
        components.path = "/" + (exportName ?? "")
        components.queryItems = [URLQueryItem(name: "socket", value: socketPath)]
        guard let url = components.url else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "failed to construct NBD Unix socket URL")
        }
        return url
    }

    static func validateUnixSocket(path: String) throws {
        guard path.hasPrefix("/") else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "NBD Unix socket path must be absolute")
        }
        var value = stat()
        guard lstat(path, &value) == 0 else {
            throw SidecarRPCError(code: "storageUnavailable", message: "NBD Unix socket does not exist", details: path)
        }
        guard (value.st_mode & S_IFMT) == S_IFSOCK else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "NBD path is not a Unix socket", details: path)
        }
    }

    static func probeUnixSocket(path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SidecarRPCError(code: "invalidStorageConfiguration", message: "NBD Unix socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else {
            throw SidecarRPCError(
                code: "storageUnavailable",
                message: "failed to connect to NBD Unix socket",
                details: String(cString: strerror(errno))
            )
        }
    }
}
