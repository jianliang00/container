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

public enum MacOSKubeadmContainerSystemOperation: String, Codable, Sendable {
    case start
    case stop
}

struct MacOSKubeadmContainerSystemCompletion: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var operationID: String
    var userID: Int
    var operation: MacOSKubeadmContainerSystemOperation
    var actualUserID: Int
    var managerUserID: Int
    var managerName: String
    var status: Int32
    var error: String? = nil
}

public enum MacOSKubeadmContainerSystem {
    public static let bootstrapLaunchdLabel = "com.apple.container.macos-node-bootstrap"
    public static let bootstrapLaunchdPlistPath = "/Library/LaunchDaemons/\(bootstrapLaunchdLabel).plist"
    static let operationLaunchdLabelPrefix = "com.apple.container-macos-kubeadm.operation"
    static let legacyGUIOperationLaunchdLabelPrefix = "com.apple.container-macos-kubeadm.legacy-gui-operation"
    static let startCommandTimeout: TimeInterval = 14 * 60
    static let stopCommandTimeout: TimeInterval = 80
    static let startCompletionTimeout: TimeInterval = 15 * 60
    static let stopCompletionTimeout: TimeInterval = 90

    static func operationLaunchdLabel(userID: Int) -> String {
        "\(operationLaunchdLabelPrefix).\(userID)"
    }

    static func legacyGUIOperationLaunchdLabel(userID: Int) -> String {
        "\(legacyGUIOperationLaunchdLabelPrefix).\(userID)"
    }

    static func commandTimeout(for operation: MacOSKubeadmContainerSystemOperation) -> TimeInterval {
        switch operation {
        case .start:
            startCommandTimeout
        case .stop:
            stopCommandTimeout
        }
    }

    public static func validateExistingConfiguration(
        requestedUserID: Int,
        bootstrapPlistPath: String,
        criShimPlistPath: String,
        flannelConfigurationPath: String,
        fileManager: FileManager = .default,
        requireLocalUser: Bool = true,
        userExists: (uid_t) -> Bool = { getpwuid($0) != nil }
    ) throws {
        try validate(userID: requestedUserID)

        var configuredUsers: [(source: String, userID: Int)] = []
        if fileManager.fileExists(atPath: bootstrapPlistPath) {
            configuredUsers.append(
                (
                    source: bootstrapPlistPath,
                    userID: try userID(
                        fromPlist: bootstrapPlistPath,
                        marker: "--container-service-user"
                    )
                )
            )
        }
        if fileManager.fileExists(atPath: criShimPlistPath) {
            configuredUsers.append(
                (
                    source: criShimPlistPath,
                    userID: try userID(fromPlist: criShimPlistPath, marker: "asuser")
                )
            )
        }
        if fileManager.fileExists(atPath: flannelConfigurationPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: flannelConfigurationPath))
                let configuration = try JSONDecoder().decode(PersistedFlannelConfiguration.self, from: data)
                configuredUsers.append(
                    (source: flannelConfigurationPath, userID: configuration.containerServiceUserID)
                )
            } catch {
                throw MacOSKubeadmError.preflightFailed(
                    "cannot read existing container service user from \(flannelConfigurationPath): \(error)"
                )
            }
        }

        let uniqueUsers = Set(configuredUsers.map(\.userID))
        guard uniqueUsers.count <= 1 else {
            let sources = configuredUsers.map { "\($0.source)=\($0.userID)" }.joined(separator: ", ")
            throw MacOSKubeadmError.preflightFailed(
                "existing container service user configuration is inconsistent (\(sources)); reset the node before joining"
            )
        }
        if let existingUserID = uniqueUsers.first, existingUserID != requestedUserID {
            throw MacOSKubeadmError.preflightFailed(
                "existing container service user uid \(existingUserID) differs from requested uid \(requestedUserID); rerun with --container-service-user \(existingUserID) or reset the node before changing users"
            )
        }
        guard
            !requireLocalUser
                || (uid_t(exactly: requestedUserID).map(userExists) ?? false)
        else {
            throw MacOSKubeadmError.preflightFailed(
                "container service user uid \(requestedUserID) does not identify a local account"
            )
        }
    }

    public static func command(userID: Int, subcommand: String) throws -> [String] {
        try validate(userID: userID)
        if subcommand == "status" {
            let containerCommand = ["/usr/local/bin/container", "system", subcommand]
            if userID == 0 {
                return ["/bin/launchctl", "asuser", "0"] + containerCommand
            }
            return [
                "/bin/launchctl",
                "asuser",
                "\(userID)",
                "/usr/bin/sudo",
                "-H",
                "-u",
                "#\(userID)",
            ] + containerCommand
        }
        guard let operation = MacOSKubeadmContainerSystemOperation(rawValue: subcommand) else {
            throw MacOSKubeadmError.invalidInput("unsupported container system subcommand: \(subcommand)")
        }

        return [
            "/usr/local/bin/container-macos-kubeadm",
            operation == .start ? "start-container-system" : "stop-container-system",
            "--container-service-user",
            "\(userID)",
        ]
    }

    static func validate(userID: Int) throws {
        guard userID >= 0 else {
            throw MacOSKubeadmError.invalidInput("--container-service-user must be a non-negative uid")
        }
        guard uid_t(exactly: userID) != nil else {
            throw MacOSKubeadmError.invalidInput(
                "--container-service-user exceeds the maximum uid \(uid_t.max)"
            )
        }
    }

    private static func userID(fromPlist path: String, marker: String) throws -> Int {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let object = propertyList as? [String: Any],
                let arguments = object["ProgramArguments"] as? [String],
                let markerIndex = arguments.firstIndex(of: marker),
                arguments.indices.contains(arguments.index(after: markerIndex)),
                let userID = Int(arguments[arguments.index(after: markerIndex)]),
                userID >= 0
            else {
                throw MacOSKubeadmError.preflightFailed(
                    "existing launchd plist does not identify a valid container service user: \(path)"
                )
            }
            return userID
        } catch let error as MacOSKubeadmError {
            throw error
        } catch {
            throw MacOSKubeadmError.preflightFailed(
                "cannot read existing container service user from \(path): \(error)"
            )
        }
    }

    private struct PersistedFlannelConfiguration: Decodable {
        var containerServiceUserID: Int

        private enum CodingKeys: String, CodingKey {
            case containerServiceUserID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            containerServiceUserID = try container.decodeIfPresent(Int.self, forKey: .containerServiceUserID) ?? 0
        }
    }
}

struct MacOSKubeadmLaunchctlResult: Equatable {
    var status: Int32
    var output: String
}

struct MacOSKubeadmContainerSystemUser: Equatable {
    var name: String
    var homeDirectory: String
}

struct MacOSKubeadmContainerSystemOperationDependencies {
    private static let maximumCapturedOutputSize = 64 * 1024

    var effectiveUserID: () -> uid_t
    var user: (uid_t) -> MacOSKubeadmContainerSystemUser?
    var launchctl: ([String]) throws -> MacOSKubeadmLaunchctlResult
    var setOwner: (Int32, uid_t) throws -> uid_t
    var operationID: () -> String
    var monotonicTime: () -> TimeInterval
    var sleep: (TimeInterval) -> Void
    var operationRoot: String
    var operationRootOwnerID: uid_t
    var completionTimeout: (MacOSKubeadmContainerSystemOperation) -> TimeInterval
    var cleanupTimeout: TimeInterval
    var pollInterval: TimeInterval

    static var live: Self {
        Self(
            effectiveUserID: { geteuid() },
            user: { userID in
                resolveUser(userID)
            },
            launchctl: { arguments in
                try runProcess(["/bin/launchctl"] + arguments, timeout: 10)
            },
            setOwner: { descriptor, userID in
                guard fchown(descriptor, userID, gid_t.max) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return userID
            },
            operationID: { UUID().uuidString.lowercased() },
            monotonicTime: { ProcessInfo.processInfo.systemUptime },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            operationRoot: "/var/db/container-macos-kubeadm-operations",
            operationRootOwnerID: 0,
            completionTimeout: { operation in
                switch operation {
                case .start:
                    MacOSKubeadmContainerSystem.startCompletionTimeout
                case .stop:
                    MacOSKubeadmContainerSystem.stopCompletionTimeout
                }
            },
            cleanupTimeout: 5,
            pollInterval: 0.1
        )
    }

    fileprivate static func runProcess(
        _ arguments: [String],
        timeout: TimeInterval?
    ) throws -> MacOSKubeadmLaunchctlResult {
        guard let executable = arguments.first else {
            throw MacOSKubeadmError.invalidInput("empty command")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())

        let outputDescriptor = try makeAnonymousOutputFile()
        defer { close(outputDescriptor) }
        let outputHandle = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false)
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let exited = DispatchSemaphore(value: 0)
        if timeout != nil {
            process.terminationHandler = { _ in exited.signal() }
        }
        try process.run()
        if let timeout {
            guard exited.wait(timeout: .now() + timeout) == .success else {
                process.terminate()
                if exited.wait(timeout: .now() + 2) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                let output = (try? capturedOutput(from: outputDescriptor)) ?? ""
                let details = output.isEmpty ? "" : ", output: \(output)"
                throw MacOSKubeadmError.timedOut(
                    "command did not exit within \(Int(timeout)) seconds: \(arguments.joined(separator: " "))\(details)"
                )
            }
        } else {
            process.waitUntilExit()
        }
        return MacOSKubeadmLaunchctlResult(
            status: process.terminationStatus,
            output: try capturedOutput(from: outputDescriptor)
        )
    }

    private static func makeAnonymousOutputFile() throws -> Int32 {
        var template = Array("/var/tmp/container-macos-kubeadm-output.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { storage in
            mkstemp(storage.baseAddress!)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let path = String(
            decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard unlink(path) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func capturedOutput(from descriptor: Int32) throws -> String {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let limit = off_t(maximumCapturedOutputSize)
        let start = max(0, metadata.st_size - limit)
        guard lseek(descriptor, start, SEEK_SET) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var data = Data(count: Int(min(metadata.st_size, limit)))
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let address = buffer.baseAddress else {
                return 0
            }
            var total = 0
            while total < buffer.count {
                let result = Darwin.read(
                    descriptor,
                    address.advanced(by: total),
                    buffer.count - total
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard result > 0 else {
                    break
                }
                total += result
            }
            return total
        }
        data.count = count
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return start > 0 ? "[earlier output truncated]\n\(output)" : output
    }

    private static func resolveUser(_ userID: uid_t) -> MacOSKubeadmContainerSystemUser? {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let configuredSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = configuredSize > 0 ? Int(configuredSize) : 16 * 1024
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let status = buffer.withUnsafeMutableBufferPointer { storage in
            getpwuid_r(
                userID,
                &record,
                storage.baseAddress,
                storage.count,
                &result
            )
        }
        guard status == 0, result != nil else {
            return nil
        }
        return MacOSKubeadmContainerSystemUser(
            name: String(cString: record.pw_name),
            homeDirectory: String(cString: record.pw_dir)
        )
    }

    fileprivate static func runSuccessfulProcess(
        _ arguments: [String],
        timeout: TimeInterval?
    ) throws -> String {
        let result = try runProcess(arguments, timeout: timeout)
        guard result.status == 0 else {
            throw MacOSKubeadmError.commandFailed(
                command: MacOSKubeadmAction.runCommand(arguments: arguments, bestEffort: false).safeDescription,
                status: result.status,
                output: result.output
            )
        }
        return result.output
    }

    fileprivate static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var address = buffer.baseAddress else {
                return
            }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                remaining -= written
                address = address.advanced(by: written)
            }
        }
    }
}

public struct MacOSKubeadmContainerSystemOperationRunner {
    private enum OperationAgentState {
        case active
        case exited(Int32?)
    }

    private static let launchctlDomainNotFoundStatus: Int32 = 112
    private static let launchctlServiceNotFoundStatus: Int32 = 113
    private static let maximumCompletionSize = 64 * 1024
    private let dependencies: MacOSKubeadmContainerSystemOperationDependencies

    public init() {
        self.init(dependencies: .live)
    }

    init(dependencies: MacOSKubeadmContainerSystemOperationDependencies) {
        self.dependencies = dependencies
    }

    public func run(
        userID: Int,
        operation: MacOSKubeadmContainerSystemOperation,
        log: MacOSKubeadmLog
    ) throws {
        try MacOSKubeadmContainerSystem.validate(userID: userID)
        guard dependencies.effectiveUserID() == 0 else {
            throw MacOSKubeadmError.preflightFailed("container system dispatcher must run as root")
        }

        guard let targetUser = dependencies.user(uid_t(userID)) else {
            throw MacOSKubeadmError.preflightFailed(
                "container service user uid \(userID) does not identify a local account"
            )
        }
        if userID == 0 {
            try runInSystemDomain(user: targetUser, operation: operation)
            return
        }
        try runInManagedDomains(
            userID: userID,
            user: targetUser,
            operation: operation,
            log: log
        )
    }

    public func cleanupAll(log: MacOSKubeadmLog) throws {
        guard dependencies.effectiveUserID() == 0 else {
            throw MacOSKubeadmError.preflightFailed(
                "container system operation cleanup must run as root"
            )
        }
        let operationRootDescriptor = try openOperationRoot()
        defer { close(operationRootDescriptor) }
        let globalLockDescriptor = try acquireOperationLock(
            name: ".global.lock",
            busyMessage: "another container system operation is still running",
            operationRootDescriptor: operationRootDescriptor
        )
        defer { releaseOperationLock(globalLockDescriptor) }

        for userID in try operationUserIDs() {
            log.debug("cleaning container system operation state for uid \(userID)")
            let userLockDescriptor = try acquireOperationLock(
                name: "\(userID).lock",
                busyMessage: "another container system operation for uid \(userID) is still running",
                operationRootDescriptor: operationRootDescriptor
            )
            do {
                if userID == 0 {
                    try recoverPreviousOperation(
                        serviceTarget: "system/\(MacOSKubeadmContainerSystem.operationLaunchdLabel(userID: userID))",
                        artifactNames: operationArtifactNames(userID: userID, suffix: "system"),
                        operationRootDescriptor: operationRootDescriptor
                    )
                } else {
                    try recoverPreviousOperation(
                        serviceTarget: "user/\(userID)/\(MacOSKubeadmContainerSystem.operationLaunchdLabel(userID: userID))",
                        artifactNames: operationArtifactNames(userID: userID, suffix: "background"),
                        operationRootDescriptor: operationRootDescriptor
                    )
                    try recoverPreviousOperation(
                        serviceTarget: "gui/\(userID)/\(MacOSKubeadmContainerSystem.legacyGUIOperationLaunchdLabel(userID: userID))",
                        artifactNames: operationArtifactNames(userID: userID, suffix: "legacy-gui"),
                        operationRootDescriptor: operationRootDescriptor
                    )
                }
            } catch {
                releaseOperationLock(userLockDescriptor)
                throw error
            }
            releaseOperationLock(userLockDescriptor)
            try removeArtifact(
                name: "\(userID).lock",
                operationRootDescriptor: operationRootDescriptor
            )
        }
    }

    private func operationUserIDs() throws -> [Int] {
        let names = try FileManager.default.contentsOfDirectory(atPath: dependencies.operationRoot)
        var userIDs = Set<Int>()
        for name in names where name != ".global.lock" {
            guard let separator = name.firstIndex(of: "."),
                let userID = Int(name[..<separator]),
                userID >= 0,
                uid_t(exactly: userID) != nil
            else {
                throw MacOSKubeadmError.preflightFailed(
                    "unexpected container system operation artifact: \(name)"
                )
            }
            let suffix = String(name[name.index(after: separator)...])
            let allowedSuffixes: Set<String> =
                userID == 0
                ? ["lock", "system.plist", "system.completion.json"]
                : [
                    "lock",
                    "background.plist",
                    "background.completion.json",
                    "legacy-gui.plist",
                    "legacy-gui.completion.json",
                ]
            guard allowedSuffixes.contains(suffix) else {
                throw MacOSKubeadmError.preflightFailed(
                    "unexpected container system operation artifact: \(name)"
                )
            }
            userIDs.insert(userID)
        }
        return userIDs.sorted()
    }

    private func operationArtifactNames(userID: Int, suffix: String) -> [String] {
        [
            "\(userID).\(suffix).plist",
            "\(userID).\(suffix).completion.json",
        ]
    }

    private func runInSystemDomain(
        user: MacOSKubeadmContainerSystemUser,
        operation: MacOSKubeadmContainerSystemOperation
    ) throws {
        let userID = 0
        let domain = "system"
        let label = MacOSKubeadmContainerSystem.operationLaunchdLabel(userID: userID)
        let serviceTarget = "\(domain)/\(label)"
        let artifactStem = "\(userID).system"
        let artifacts = [
            "\(artifactStem).plist",
            "\(artifactStem).completion.json",
        ]
        let operationRootDescriptor = try openOperationRoot()
        defer { close(operationRootDescriptor) }
        let globalLockDescriptor = try acquireOperationLock(
            name: ".global.lock",
            busyMessage: "another container system operation is still running",
            operationRootDescriptor: operationRootDescriptor
        )
        defer { releaseOperationLock(globalLockDescriptor) }
        let lockDescriptor = try acquireOperationLock(
            name: "\(userID).lock",
            busyMessage: "another container system operation for uid \(userID) is still running",
            operationRootDescriptor: operationRootDescriptor
        )
        defer { releaseOperationLock(lockDescriptor) }

        try recoverPreviousOperation(
            serviceTarget: serviceTarget,
            artifactNames: artifacts,
            operationRootDescriptor: operationRootDescriptor
        )
        try dispatchOperation(
            userID: userID,
            user: user,
            domain: domain,
            managerName: "System",
            label: label,
            artifactStem: artifactStem,
            operation: operation,
            operationRootDescriptor: operationRootDescriptor
        )
    }

    private func runInManagedDomains(
        userID: Int,
        user: MacOSKubeadmContainerSystemUser,
        operation: MacOSKubeadmContainerSystemOperation,
        log: MacOSKubeadmLog
    ) throws {
        let backgroundDomain = "user/\(userID)"
        let backgroundLabel = MacOSKubeadmContainerSystem.operationLaunchdLabel(userID: userID)
        let backgroundServiceTarget = "\(backgroundDomain)/\(backgroundLabel)"
        let backgroundArtifactStem = "\(userID).background"
        let backgroundArtifacts = [
            "\(backgroundArtifactStem).plist",
            "\(backgroundArtifactStem).completion.json",
        ]
        let guiDomain = "gui/\(userID)"
        let guiLabel = MacOSKubeadmContainerSystem.legacyGUIOperationLaunchdLabel(userID: userID)
        let guiServiceTarget = "\(guiDomain)/\(guiLabel)"
        let guiArtifactStem = "\(userID).legacy-gui"
        let guiArtifacts = [
            "\(guiArtifactStem).plist",
            "\(guiArtifactStem).completion.json",
        ]

        let operationRootDescriptor = try openOperationRoot()
        defer { close(operationRootDescriptor) }
        let globalLockDescriptor = try acquireOperationLock(
            name: ".global.lock",
            busyMessage: "another container system operation is still running",
            operationRootDescriptor: operationRootDescriptor
        )
        defer { releaseOperationLock(globalLockDescriptor) }
        let lockDescriptor = try acquireOperationLock(
            name: "\(userID).lock",
            busyMessage: "another container system operation for uid \(userID) is still running",
            operationRootDescriptor: operationRootDescriptor
        )
        defer { releaseOperationLock(lockDescriptor) }

        try ensureUserDomain(backgroundDomain, log: log)
        try recoverPreviousOperation(
            serviceTarget: backgroundServiceTarget,
            artifactNames: backgroundArtifacts,
            operationRootDescriptor: operationRootDescriptor
        )

        if try domainExists(guiDomain) {
            try recoverPreviousOperation(
                serviceTarget: guiServiceTarget,
                artifactNames: guiArtifacts,
                operationRootDescriptor: operationRootDescriptor
            )
        } else {
            for name in guiArtifacts {
                try removeArtifact(
                    name: name,
                    operationRootDescriptor: operationRootDescriptor
                )
            }
        }
        if try domainExists(guiDomain) {
            try dispatchOperation(
                userID: userID,
                user: user,
                domain: guiDomain,
                managerName: "Aqua",
                label: guiLabel,
                artifactStem: guiArtifactStem,
                operation: .stop,
                operationRootDescriptor: operationRootDescriptor
            )
        }
        try dispatchOperation(
            userID: userID,
            user: user,
            domain: backgroundDomain,
            managerName: "Background",
            label: backgroundLabel,
            artifactStem: backgroundArtifactStem,
            operation: operation,
            operationRootDescriptor: operationRootDescriptor
        )
    }

    private func dispatchOperation(
        userID: Int,
        user: MacOSKubeadmContainerSystemUser,
        domain: String,
        managerName: String,
        label: String,
        artifactStem: String,
        operation: MacOSKubeadmContainerSystemOperation,
        operationRootDescriptor: Int32
    ) throws {
        let operationID = dependencies.operationID()
        guard isValidOperationID(operationID) else {
            throw MacOSKubeadmError.preflightFailed("container system operation id is invalid")
        }

        let serviceTarget = "\(domain)/\(label)"
        let plistName = "\(artifactStem).plist"
        let completionName = "\(artifactStem).completion.json"
        let plistPath = "\(dependencies.operationRoot)/\(plistName)"
        let completionPath = "\(dependencies.operationRoot)/\(completionName)"
        var bootstrapAttempted = false
        var completionCreated = false
        var plistCreated = false
        var primaryError: Error?

        do {
            let completionOwnerID = try createExclusiveFile(
                name: completionName,
                operationRootDescriptor: operationRootDescriptor,
                mode: 0o600,
                ownerID: uid_t(userID),
                contents: Data()
            )
            completionCreated = true
            let plist = MacOSKubeadmRenderer.containerSystemOperationPlist(
                label: label,
                containerServiceUserID: userID,
                userName: user.name,
                homeDirectory: user.homeDirectory,
                operation: operation,
                operationID: operationID,
                completionPath: completionPath,
                sessionType: managerName
            )
            _ = try createExclusiveFile(
                name: plistName,
                operationRootDescriptor: operationRootDescriptor,
                mode: 0o644,
                ownerID: dependencies.operationRootOwnerID,
                contents: Data(plist.utf8)
            )
            plistCreated = true

            bootstrapAttempted = true
            let bootstrap = try dependencies.launchctl(["bootstrap", domain, plistPath])
            if bootstrap.status != 0 {
                let loaded = try dependencies.launchctl(["print", serviceTarget])
                guard loaded.status == 0 else {
                    throw launchctlFailure(
                        arguments: ["bootstrap", domain, plistPath],
                        result: bootstrap
                    )
                }
            }
            let completion = try waitForCompletion(
                name: completionName,
                operationRootDescriptor: operationRootDescriptor,
                ownerID: completionOwnerID,
                serviceTarget: serviceTarget,
                operationID: operationID,
                userID: userID,
                operation: operation,
                managerName: managerName
            )
            guard completion.status == 0 else {
                throw MacOSKubeadmError.commandFailed(
                    command: "container system \(operation.rawValue) in \(domain) \(managerName) domain",
                    status: completion.status,
                    output: completion.error ?? "operation failed without an error message"
                )
            }
        } catch {
            primaryError = error
        }

        let cleanupError = cleanup(
            serviceTarget: serviceTarget,
            bootstrapAttempted: bootstrapAttempted,
            paths: [
                (name: plistName, created: plistCreated),
                (name: completionName, created: completionCreated),
            ],
            operationRootDescriptor: operationRootDescriptor
        )
        if let primaryError, let cleanupError {
            throw MacOSKubeadmError.preflightFailed(
                "\(primaryError); container system operation cleanup failed: \(cleanupError)"
            )
        }
        if let primaryError {
            throw primaryError
        }
        if let cleanupError {
            throw cleanupError
        }
    }

    private func openOperationRoot() throws -> Int32 {
        if mkdir(dependencies.operationRoot, 0o711) != 0, errno != EEXIST {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let descriptor = open(dependencies.operationRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            throw error
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
            metadata.st_uid == dependencies.operationRootOwnerID,
            metadata.st_mode & 0o022 == 0
        else {
            let error = MacOSKubeadmError.preflightFailed(
                "container system operation root must be an owner-controlled directory: \(dependencies.operationRoot)"
            )
            close(descriptor)
            throw error
        }
        guard fchmod(descriptor, 0o711) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            throw error
        }
        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private func acquireOperationLock(
        name: String,
        busyMessage: String,
        operationRootDescriptor: Int32
    ) throws -> Int32 {
        let descriptor = openat(
            operationRootDescriptor,
            name,
            O_CREAT | O_RDWR | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            throw error
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_uid == dependencies.operationRootOwnerID,
            metadata.st_nlink == 1
        else {
            let error = MacOSKubeadmError.preflightFailed(
                "container system operation lock is not an owner-controlled regular file: \(name)"
            )
            close(descriptor)
            throw error
        }
        guard fchmod(descriptor, 0o600) == 0,
            Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
        else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            throw error
        }

        let deadline = dependencies.monotonicTime() + dependencies.cleanupTimeout
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while Darwin.fcntl(descriptor, F_SETLK, &lock) != 0 {
            if errno == EINTR {
                continue
            }
            guard errno == EACCES || errno == EAGAIN else {
                let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                close(descriptor)
                throw error
            }
            guard dependencies.monotonicTime() < deadline else {
                close(descriptor)
                throw MacOSKubeadmError.timedOut(busyMessage)
            }
            dependencies.sleep(dependencies.pollInterval)
        }
        return descriptor
    }

    private func releaseOperationLock(_ descriptor: Int32) {
        var lock = Darwin.flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        close(descriptor)
    }

    private func recoverPreviousOperation(
        serviceTarget: String,
        artifactNames: [String],
        operationRootDescriptor: Int32
    ) throws {
        let existing = try dependencies.launchctl(["print", serviceTarget])
        switch existing.status {
        case 0:
            let bootout = try dependencies.launchctl(["bootout", serviceTarget])
            if let error = waitForServiceRemoval(serviceTarget) {
                let output = bootout.output.isEmpty ? "" : ", output: \(bootout.output)"
                throw MacOSKubeadmError.preflightFailed(
                    "cannot remove previous container system operation: launchctl bootout status \(bootout.status)\(output); \(error)"
                )
            }
        case Self.launchctlDomainNotFoundStatus, Self.launchctlServiceNotFoundStatus:
            break
        default:
            throw MacOSKubeadmError.preflightFailed(
                "cannot inspect previous container system operation: launchctl status \(existing.status), output: \(existing.output)"
            )
        }

        for name in artifactNames {
            try removeArtifact(name: name, operationRootDescriptor: operationRootDescriptor)
        }
    }

    private func createExclusiveFile(
        name: String,
        operationRootDescriptor: Int32,
        mode: mode_t,
        ownerID: uid_t,
        contents: Data
    ) throws -> uid_t {
        let descriptor = openat(
            operationRootDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard (metadata.st_mode & S_IFMT) == S_IFREG,
                metadata.st_uid == dependencies.operationRootOwnerID,
                metadata.st_nlink == 1
            else {
                throw MacOSKubeadmError.preflightFailed(
                    "container system operation artifact is not an owner-controlled regular file: \(name)"
                )
            }
            guard fchmod(descriptor, mode) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let establishedOwnerID = try dependencies.setOwner(descriptor, ownerID)
            guard fstat(descriptor, &metadata) == 0, metadata.st_uid == establishedOwnerID else {
                throw MacOSKubeadmError.preflightFailed(
                    "container system operation artifact owner could not be established: \(name)"
                )
            }
            try MacOSKubeadmContainerSystemOperationDependencies.writeAll(contents, to: descriptor)
            return establishedOwnerID
        } catch {
            _ = unlinkat(operationRootDescriptor, name, 0)
            throw error
        }
    }

    private func ensureUserDomain(_ domain: String, log: MacOSKubeadmLog) throws {
        let initial = try dependencies.launchctl(["print", domain])
        switch initial.status {
        case 0:
            return
        case Self.launchctlDomainNotFoundStatus:
            break
        default:
            throw MacOSKubeadmError.preflightFailed(
                "cannot inspect launchd domain \(domain): status \(initial.status), output: \(initial.output)"
            )
        }

        let bootstrap = try dependencies.launchctl(["bootstrap", domain])
        if bootstrap.status != 0, !bootstrap.output.isEmpty {
            log.debug(bootstrap.output)
        }
        let verified = try dependencies.launchctl(["print", domain])
        guard verified.status == 0 else {
            throw MacOSKubeadmError.preflightFailed(
                "cannot establish launchd domain \(domain): bootstrap status \(bootstrap.status), verification status \(verified.status)"
            )
        }
    }

    private func domainExists(_ domain: String) throws -> Bool {
        let result = try dependencies.launchctl(["print", domain])
        switch result.status {
        case 0:
            return true
        case Self.launchctlDomainNotFoundStatus:
            return false
        default:
            throw MacOSKubeadmError.preflightFailed(
                "cannot inspect launchd domain \(domain): status \(result.status), output: \(result.output)"
            )
        }
    }

    private func waitForCompletion(
        name: String,
        operationRootDescriptor: Int32,
        ownerID: uid_t,
        serviceTarget: String,
        operationID: String,
        userID: Int,
        operation: MacOSKubeadmContainerSystemOperation,
        managerName: String
    ) throws -> MacOSKubeadmContainerSystemCompletion {
        let timeout = dependencies.completionTimeout(operation)
        let deadline = dependencies.monotonicTime() + timeout
        while dependencies.monotonicTime() < deadline {
            switch try operationAgentState(serviceTarget) {
            case .active:
                dependencies.sleep(dependencies.pollInterval)
                continue
            case .exited(let exitCode):
                let data = try readCompletion(
                    name: name,
                    operationRootDescriptor: operationRootDescriptor,
                    ownerID: ownerID
                )
                guard !data.isEmpty,
                    let completion = try? JSONDecoder().decode(
                        MacOSKubeadmContainerSystemCompletion.self,
                        from: data
                    )
                else {
                    throw MacOSKubeadmError.preflightFailed(
                        "container system operation agent exited before writing a valid completion"
                    )
                }
                guard completion.schemaVersion == MacOSKubeadmContainerSystemCompletion.currentSchemaVersion,
                    completion.operationID == operationID,
                    completion.userID == userID,
                    completion.operation == operation,
                    completion.actualUserID == userID,
                    completion.managerUserID == userID,
                    completion.managerName == managerName
                else {
                    throw MacOSKubeadmError.preflightFailed(
                        "container system operation completion does not match the requested \(managerName) launchd context"
                    )
                }
                if completion.status == 0, exitCode != 0 {
                    let renderedExitCode = exitCode.map(String.init) ?? "signal or unknown"
                    throw MacOSKubeadmError.preflightFailed(
                        "container system operation reported success but its launchd agent exited with \(renderedExitCode)"
                    )
                }
                return completion
            }
        }
        throw MacOSKubeadmError.timedOut(
            "container system \(operation.rawValue) did not complete within \(Int(timeout)) seconds"
        )
    }

    private func operationAgentState(_ serviceTarget: String) throws -> OperationAgentState {
        let result = try dependencies.launchctl(["print", serviceTarget])
        switch result.status {
        case 0:
            guard result.output.contains("state = not running") else {
                return .active
            }
            if let exitCode = launchctlInteger(field: "last exit code", output: result.output) {
                return .exited(exitCode)
            }
            if result.output.contains("job state = exited")
                || (launchctlInteger(field: "runs", output: result.output) ?? 0) > 0
            {
                return .exited(nil)
            }
            return .active
        case Self.launchctlDomainNotFoundStatus, Self.launchctlServiceNotFoundStatus:
            throw MacOSKubeadmError.preflightFailed(
                "container system operation agent disappeared before writing a valid completion"
            )
        default:
            throw MacOSKubeadmError.preflightFailed(
                "cannot inspect container system operation agent: launchctl status \(result.status), output: \(result.output)"
            )
        }
    }

    private func launchctlInteger(field: String, output: String) -> Int32? {
        let prefix = "\(field) = "
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .flatMap { Int32($0.dropFirst(prefix.count)) }
    }

    private func cleanup(
        serviceTarget: String,
        bootstrapAttempted: Bool,
        paths: [(name: String, created: Bool)],
        operationRootDescriptor: Int32
    ) -> Error? {
        var errors: [String] = []
        var serviceIsAbsent = !bootstrapAttempted
        if bootstrapAttempted {
            do {
                let bootout = try dependencies.launchctl(["bootout", serviceTarget])
                if let error = waitForServiceRemoval(serviceTarget) {
                    let output = bootout.output.isEmpty ? "" : ", output: \(bootout.output)"
                    errors.append(
                        "launchctl bootout status \(bootout.status)\(output); \(error)"
                    )
                } else {
                    serviceIsAbsent = true
                }
            } catch {
                errors.append(String(describing: error))
            }
        }

        if serviceIsAbsent {
            for item in paths where item.created {
                do {
                    try removeArtifact(
                        name: item.name,
                        operationRootDescriptor: operationRootDescriptor
                    )
                } catch {
                    errors.append("cannot remove \(item.name): \(error)")
                }
            }
        } else {
            errors.append("operation agent remains loaded; preserving its plist and completion file")
        }
        guard !errors.isEmpty else {
            return nil
        }
        return MacOSKubeadmError.preflightFailed(errors.joined(separator: "; "))
    }

    private func waitForServiceRemoval(_ serviceTarget: String) -> Error? {
        let deadline = dependencies.monotonicTime() + dependencies.cleanupTimeout
        while dependencies.monotonicTime() < deadline {
            do {
                let result = try dependencies.launchctl(["print", serviceTarget])
                if result.status == Self.launchctlDomainNotFoundStatus
                    || result.status == Self.launchctlServiceNotFoundStatus
                {
                    return nil
                }
                if result.status != 0 {
                    return MacOSKubeadmError.preflightFailed(
                        "cannot verify operation agent removal: launchctl status \(result.status), output: \(result.output)"
                    )
                }
            } catch {
                return error
            }
            dependencies.sleep(dependencies.pollInterval)
        }
        return MacOSKubeadmError.timedOut("launchd service did not disappear: \(serviceTarget)")
    }

    private func isValidOperationID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { byte in
                (byte >= 97 && byte <= 122)
                    || (byte >= 65 && byte <= 90)
                    || (byte >= 48 && byte <= 57)
                    || byte == 45
            }
    }

    private func readCompletion(
        name: String,
        operationRootDescriptor: Int32,
        ownerID: uid_t
    ) throws -> Data {
        let descriptor = openat(operationRootDescriptor, name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_uid == ownerID else {
            throw MacOSKubeadmError.preflightFailed(
                "container system completion path is not a regular file owned by uid \(ownerID)"
            )
        }
        guard metadata.st_size <= Self.maximumCompletionSize else {
            throw MacOSKubeadmError.preflightFailed("container system completion exceeds the size limit")
        }
        guard metadata.st_size > 0 else {
            return Data()
        }

        var data = Data(count: Int(metadata.st_size))
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let address = buffer.baseAddress else {
                return 0
            }
            var total = 0
            while total < buffer.count {
                let result = Darwin.read(
                    descriptor,
                    address.advanced(by: total),
                    buffer.count - total
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard result > 0 else {
                    break
                }
                total += result
            }
            return total
        }
        data.count = count
        return data
    }

    private func removeArtifact(
        name: String,
        operationRootDescriptor: Int32
    ) throws {
        if unlinkat(operationRootDescriptor, name, 0) == 0 || errno == ENOENT {
            return
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func launchctlFailure(
        arguments: [String],
        result: MacOSKubeadmLaunchctlResult
    ) -> MacOSKubeadmError {
        MacOSKubeadmError.commandFailed(
            command: (["/bin/launchctl"] + arguments).joined(separator: " "),
            status: result.status,
            output: result.output
        )
    }
}

struct MacOSKubeadmContainerSystemExecutorDependencies {
    var effectiveUserID: () -> uid_t
    var managerName: () throws -> String
    var managerUserID: () throws -> Int
    var runCommand: ([String]) throws -> String
    var managedServices: () throws -> [String]
    var serviceIsLoaded: (String) throws -> Bool
    var writeCompletion: (MacOSKubeadmContainerSystemCompletion, String) throws -> Void

    static var live: Self {
        Self(
            effectiveUserID: { geteuid() },
            managerName: {
                try MacOSKubeadmProcess.runCapturing(arguments: ["/bin/launchctl", "managername"])
            },
            managerUserID: {
                let output = try MacOSKubeadmProcess.runCapturing(arguments: ["/bin/launchctl", "manageruid"])
                guard let userID = Int(output) else {
                    throw MacOSKubeadmError.preflightFailed(
                        "launchctl manageruid returned an invalid uid: \(output)"
                    )
                }
                return userID
            },
            runCommand: { arguments in
                guard let value = arguments.last,
                    let operation = MacOSKubeadmContainerSystemOperation(rawValue: value)
                else {
                    throw MacOSKubeadmError.invalidInput("container system operation is missing")
                }
                return try MacOSKubeadmContainerSystemOperationDependencies.runSuccessfulProcess(
                    arguments,
                    timeout: MacOSKubeadmContainerSystem.commandTimeout(for: operation)
                )
            },
            managedServices: {
                let output = try MacOSKubeadmContainerSystemOperationDependencies.runSuccessfulProcess(
                    ["/bin/launchctl", "list"],
                    timeout: 10
                )
                return output.split(whereSeparator: \.isNewline)
                    .compactMap { line -> String? in
                        let fields = line.split(whereSeparator: \.isWhitespace)
                        guard fields.count >= 3 else {
                            return nil
                        }
                        return String(fields[2])
                    }
                    .filter { $0.hasPrefix("com.apple.container.") }
                    .sorted()
            },
            serviceIsLoaded: { serviceTarget in
                let result = try MacOSKubeadmContainerSystemOperationDependencies.runProcess(
                    ["/bin/launchctl", "print", serviceTarget],
                    timeout: 10
                )
                switch result.status {
                case 0:
                    return true
                case 112, 113:
                    return false
                default:
                    throw MacOSKubeadmError.commandFailed(
                        command: "/bin/launchctl print \(serviceTarget)",
                        status: result.status,
                        output: result.output
                    )
                }
            },
            writeCompletion: { completion, path in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(completion)
                try writeCompletionData(data, path: path)
            }
        )
    }

    private static func writeCompletionData(_ data: Data, path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_uid == geteuid() else {
            throw MacOSKubeadmError.preflightFailed(
                "container system completion path is not a regular file owned by the executor"
            )
        }

        let descriptor = open(path, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }

        try MacOSKubeadmContainerSystemOperationDependencies.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

public struct MacOSKubeadmContainerSystemExecutor {
    private let dependencies: MacOSKubeadmContainerSystemExecutorDependencies

    public init() {
        self.init(dependencies: .live)
    }

    init(dependencies: MacOSKubeadmContainerSystemExecutorDependencies) {
        self.dependencies = dependencies
    }

    public func run(
        userID: Int,
        operation: MacOSKubeadmContainerSystemOperation,
        operationID: String,
        completionPath: String,
        expectedManagerName: String = "Background",
        log: MacOSKubeadmLog
    ) throws {
        var managerName = "unknown"
        var actualUserID = Int(dependencies.effectiveUserID())
        var managerUserID = -1
        do {
            try MacOSKubeadmContainerSystem.validate(userID: userID)
            guard ["System", "Background", "Aqua"].contains(expectedManagerName) else {
                throw MacOSKubeadmError.invalidInput(
                    "container system executor session must be System, Background, or Aqua"
                )
            }
            if expectedManagerName == "Aqua", operation != .stop {
                throw MacOSKubeadmError.invalidInput(
                    "the Aqua migration executor only supports container system stop"
                )
            }
            if (expectedManagerName == "System") != (userID == 0) {
                throw MacOSKubeadmError.invalidInput(
                    "the System launchd executor requires uid 0 and non-root users require a user domain"
                )
            }
            managerName = try dependencies.managerName()
            actualUserID = Int(dependencies.effectiveUserID())
            managerUserID = try dependencies.managerUserID()
            guard actualUserID == userID,
                managerUserID == userID,
                managerName == expectedManagerName
            else {
                throw MacOSKubeadmError.preflightFailed(
                    "container system executor requires uid \(userID) in the \(expectedManagerName) launchd domain; actual uid \(actualUserID), manager uid \(managerUserID), manager \(managerName)"
                )
            }

            let output = try dependencies.runCommand([
                "/usr/local/bin/container",
                "system",
                operation.rawValue,
            ])
            if !output.isEmpty {
                log.debug(output)
            }
            if operation == .stop {
                let serviceDomain = try serviceDomain(
                    managerName: managerName,
                    userID: userID
                )
                let candidates = try dependencies.managedServices()
                let remaining = try candidates.filter { label in
                    try dependencies.serviceIsLoaded("\(serviceDomain)/\(label)")
                }
                guard remaining.isEmpty else {
                    throw MacOSKubeadmError.preflightFailed(
                        "container system stop left managed launchd services loaded in \(serviceDomain): \(remaining.joined(separator: ", "))"
                    )
                }
            }
            try dependencies.writeCompletion(
                MacOSKubeadmContainerSystemCompletion(
                    operationID: operationID,
                    userID: userID,
                    operation: operation,
                    actualUserID: actualUserID,
                    managerUserID: managerUserID,
                    managerName: managerName,
                    status: 0
                ),
                completionPath
            )
        } catch {
            let status: Int32
            if case MacOSKubeadmError.commandFailed(_, let commandStatus, _) = error {
                status = commandStatus
            } else {
                status = 1
            }
            let errorMessage = String(String(describing: error).prefix(4096))
            try? dependencies.writeCompletion(
                MacOSKubeadmContainerSystemCompletion(
                    operationID: operationID,
                    userID: userID,
                    operation: operation,
                    actualUserID: actualUserID,
                    managerUserID: managerUserID,
                    managerName: managerName,
                    status: status,
                    error: errorMessage
                ),
                completionPath
            )
            throw error
        }
    }

    private func serviceDomain(managerName: String, userID: Int) throws -> String {
        switch managerName {
        case "System":
            return "system"
        case "Background":
            return "user/\(userID)"
        case "Aqua":
            return "gui/\(userID)"
        default:
            throw MacOSKubeadmError.invalidInput(
                "unsupported launchd manager for container system verification: \(managerName)"
            )
        }
    }
}
