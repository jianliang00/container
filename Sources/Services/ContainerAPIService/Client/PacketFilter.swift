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

import ContainerizationError
import ContainerizationExtras
import DNSServer
import Darwin
import Foundation
import SystemPackage

public struct PacketFilter: Sendable {
    public static let anchor = "com.apple.container"
    public static let defaultConfigPath = FilePath("/etc/pf.conf")
    public static let defaultAnchorsPath = FilePath("/etc/pf.anchors")
    static let advisoryLockPath = "/var/run/com.apple.container.pf.lock"

    private static let processMutationLock = NSLock()

    private let configPath: FilePath
    private let anchorsPath: FilePath
    private let mutationLockPath: String

    public init(configPath: FilePath = Self.defaultConfigPath, anchorsPath: FilePath = Self.defaultAnchorsPath) {
        self.init(
            configPath: configPath,
            anchorsPath: anchorsPath,
            advisoryLockPath: Self.advisoryLockPath
        )
    }

    init(configPath: FilePath, anchorsPath: FilePath, advisoryLockPath: String) {
        self.configPath = configPath
        self.anchorsPath = anchorsPath
        self.mutationLockPath = advisoryLockPath
    }

    public func createRedirectRule(from: IPAddress, to: IPAddress, domain: DNSName) throws {
        let inet = try pfAddressFamily(from: from, to: to)
        let redirectRule = "rdr \(inet) from any to \(from.description) -> \(to.description) # \(domain.pqdn)"

        try withMutationLock {
            let fm: FileManager = FileManager.default
            let anchorPath = self.anchorsPath.appending(Self.anchor)

            var content = ""
            if fm.fileExists(atPath: anchorPath.string) {
                content = try String(contentsOfFile: anchorPath.string, encoding: .utf8)
            } else {
                try addAnchorToConfigLocked()
            }

            var lines = content.components(separatedBy: .newlines)
            if !lines.contains(redirectRule) {
                lines.insert(redirectRule, at: lines.endIndex - 1)
            }

            try lines.joined(separator: "\n").write(toFile: anchorPath.string, atomically: true, encoding: .utf8)
        }
    }

    public func removeRedirectRule(from: IPAddress, to: IPAddress, domain: DNSName) throws {
        let inet = try pfAddressFamily(from: from, to: to)
        let redirectRule = "rdr \(inet) from any to \(from.description) -> \(to.description) # \(domain.pqdn)"

        try withMutationLock {
            let fm: FileManager = FileManager.default
            let anchorPath = self.anchorsPath.appending(Self.anchor)

            guard fm.fileExists(atPath: anchorPath.string) else {
                return
            }

            let content = try String(contentsOfFile: anchorPath.string, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let removedLines = lines.filter { $0 != redirectRule }

            if removedLines == [""] {
                try fm.removeItem(atPath: anchorPath.string)
                try removeAnchorFromConfigLocked()
            } else {
                try removedLines.joined(separator: "\n").write(
                    toFile: anchorPath.string,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    private func addAnchorToConfigLocked() throws {
        let fm: FileManager = FileManager.default

        let anchorPath = self.anchorsPath.appending(Self.anchor)

        /* PF requires strict ordering of anchors:
           scrub-anchor, nat-anchor, rdr-anchor, dummynet-anchor, anchor, load anchor
         */
        let anchorKeywords = ["scrub-anchor", "nat-anchor", "rdr-anchor", "dummynet-anchor", "anchor", "load anchor"]
        let loadAnchorText = "load anchor \"\(Self.anchor)\" from \"\(anchorPath.string)\""

        var content = ""
        if fm.fileExists(atPath: self.configPath.string) {
            content = try String(contentsOfFile: self.configPath.string, encoding: .utf8)
        }
        var lines = content.components(separatedBy: .newlines)

        for (i, keyword) in anchorKeywords[..<(anchorKeywords.endIndex - 1)].enumerated() {
            let anchorText = "\(keyword) \"\(Self.anchor)\""

            if lines.contains(where: { normalizedPFDirective($0) == anchorText }) {
                continue
            }

            let idx = lines.firstIndex { l in
                anchorKeywords[i...].map { k in l.starts(with: k) }.contains(true)
            }
            lines.insert(anchorText, at: idx ?? lines.endIndex - 1)
        }

        if !lines.contains(where: { normalizedPFDirective($0) == loadAnchorText }) {
            lines.insert(loadAnchorText, at: lines.endIndex - 1)
        }

        do {
            try lines.joined(separator: "\n").write(toFile: self.configPath.string, atomically: true, encoding: .utf8)
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to write \"\(self.configPath.string)\"")
        }
    }

    private func removeAnchorFromConfigLocked() throws {
        let fm: FileManager = FileManager.default

        guard fm.fileExists(atPath: configPath.string) else {
            return
        }

        let content = try String(contentsOfFile: configPath.string, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        let anchorPath = anchorsPath.appending(Self.anchor)
        let ownedDirectives = Set([
            "scrub-anchor \"\(Self.anchor)\"",
            "nat-anchor \"\(Self.anchor)\"",
            "rdr-anchor \"\(Self.anchor)\"",
            "dummynet-anchor \"\(Self.anchor)\"",
            "anchor \"\(Self.anchor)\"",
            "load anchor \"\(Self.anchor)\" from \"\(anchorPath.string)\"",
        ])
        let removedLines = lines.filter { !ownedDirectives.contains(normalizedPFDirective($0)) }

        do {
            try removedLines.joined(separator: "\n").write(toFile: configPath.string, atomically: true, encoding: .utf8)
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to write \"\(configPath.string)\"")
        }
    }

    public func reinitialize() throws {
        try withMutationLock {
            try reinitializeLocked()
        }
    }

    private func reinitializeLocked() throws {
        let null = FileHandle.nullDevice

        let checkProcess = Foundation.Process()
        var checkStatus: Int32
        checkProcess.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        checkProcess.arguments = ["-n", "-f", configPath.string]
        checkProcess.standardOutput = null
        checkProcess.standardError = null

        do {
            try checkProcess.run()
        } catch {
            throw ContainerizationError(.internalError, message: "pfctl rule check exec failed: \"\(error)\"")
        }

        checkProcess.waitUntilExit()
        checkStatus = checkProcess.terminationStatus
        guard checkStatus == 0 else {
            throw ContainerizationError(.internalError, message: "invalid pf config \"\(configPath.string)\"")
        }

        let reloadProcess = Foundation.Process()
        var reloadStatus: Int32

        reloadProcess.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        reloadProcess.arguments = ["-f", configPath.string]
        reloadProcess.standardOutput = null
        reloadProcess.standardError = null

        do {
            try reloadProcess.run()
        } catch {
            throw ContainerizationError(.internalError, message: "pfctl reload exec failed: \"\(error)\"")
        }
        reloadProcess.waitUntilExit()
        reloadStatus = reloadProcess.terminationStatus
        guard reloadStatus == 0 else {
            throw ContainerizationError(.invalidState, message: "pfctl -f \"\(configPath.string)\" failed with status \(reloadStatus)")
        }
    }

    func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }

        let descriptor = mutationLockPath.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw ContainerizationError(
                .invalidState,
                message: "failed to open PF advisory lock at \(mutationLockPath): \(posixErrorDescription())"
            )
        }
        defer { Darwin.close(descriptor) }

        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ContainerizationError(
                .invalidState,
                message: "failed to configure PF advisory lock at \(mutationLockPath): \(posixErrorDescription())"
            )
        }

        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while Darwin.fcntl(descriptor, F_SETLKW, &lock) != 0 {
            guard errno == EINTR else {
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to acquire PF advisory lock at \(mutationLockPath): \(posixErrorDescription())"
                )
            }
        }
        defer {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
        }

        return try operation()
    }

    private func normalizedPFDirective(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private func pfAddressFamily(from: IPAddress, to: IPAddress) throws -> String {
        switch (from, to) {
        case (.v4, .v4):
            return "inet"
        case (.v6, .v6):
            return "inet6"
        default:
            throw ContainerizationError(.invalidArgument, message: "protocol does not match: \(from) vs. \(to)")
        }
    }

    private func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}
