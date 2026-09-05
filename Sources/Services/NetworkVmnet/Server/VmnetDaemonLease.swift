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
import Darwin
import Foundation
import Synchronization

struct VmnetDaemonIdentity: Equatable, Sendable {
    let pid: pid_t
    let startSeconds: Int64
    let startMicroseconds: Int64
}

protocol VmnetDaemonInspecting: Sendable {
    func current() throws -> VmnetDaemonIdentity?
    func isCurrent(_ identity: VmnetDaemonIdentity) throws -> Bool
}

/// Detects daemon replacement, not guest connectivity or native reservation health.
/// PID alone is insufficient because the kernel may reuse it.
struct SystemVmnetDaemonInspector: VmnetDaemonInspecting {
    let executablePath: String

    init(executablePath: String = "/usr/libexec/InternetSharing") {
        self.executablePath = executablePath
    }

    func current() throws -> VmnetDaemonIdentity? {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        var candidates: [VmnetDaemonIdentity] = []
        for var process in try Self.processes() {
            let command = withUnsafeBytes(of: &process.kp_proc.p_comm) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard process.kp_eproc.e_ucred.cr_uid == 0, command == name else { continue }
            if let identity = try inspect(pid: process.kp_proc.p_pid) {
                candidates.append(identity)
            }
        }
        guard candidates.count <= 1 else { throw Self.unavailable("ambiguous daemon processes") }
        return candidates.first
    }

    func isCurrent(_ identity: VmnetDaemonIdentity) throws -> Bool {
        try inspect(pid: identity.pid) == identity
    }

    private func inspect(pid: pid_t) throws -> VmnetDaemonIdentity? {
        guard let before = try Self.process(pid: pid), let identity = Self.identity(before) else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else {
            if errno == ESRCH { return nil }
            throw Self.unavailable("cannot inspect daemon executable")
        }
        let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard executable == executablePath else { return nil }
        // Bind the executable readback to the same kernel process incarnation.
        guard let after = try Self.process(pid: pid), Self.identity(after) == identity else { return nil }
        return identity
    }

    private static func identity(_ info: kinfo_proc) -> VmnetDaemonIdentity? {
        let process = info.kp_proc
        guard process.p_pid > 0, info.kp_eproc.e_ucred.cr_uid == 0,
            Int32(process.p_stat) != SZOMB, process.p_un.__p_starttime.tv_sec > 0
        else { return nil }
        return VmnetDaemonIdentity(
            pid: process.p_pid,
            startSeconds: Int64(process.p_un.__p_starttime.tv_sec),
            startMicroseconds: Int64(process.p_un.__p_starttime.tv_usec)
        )
    }

    private static func process(pid: pid_t) throws -> kinfo_proc? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            if errno == ESRCH { return nil }
            throw unavailable("cannot inspect daemon process")
        }
        if size == 0 { return nil }
        guard size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
            throw unavailable("incomplete daemon process information")
        }
        return info
    }

    private static func processes() throws -> [kinfo_proc] {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            throw unavailable("cannot size process inventory")
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = size / stride + 64
        guard capacity <= 131_072 else { throw unavailable("process inventory exceeds limit") }
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * stride
        let result = entries.withUnsafeMutableBytes {
            sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard result == 0, size <= capacity * stride, size % stride == 0 else {
            throw unavailable("cannot read complete process inventory")
        }
        return Array(entries.prefix(size / stride))
    }

    private static func unavailable(_ reason: String) -> ContainerizationError {
        ContainerizationError(.invalidState, message: "vmnet daemon identity unavailable: \(reason)")
    }
}

/// An invalidated lease never adopts a replacement daemon or discards a live VM's reference.
final class VmnetDaemonLease: Sendable {
    let identity: VmnetDaemonIdentity
    private let inspector: any VmnetDaemonInspecting
    private let invalidation = Mutex<String?>(nil)

    init(identity: VmnetDaemonIdentity, inspector: any VmnetDaemonInspecting) {
        self.identity = identity
        self.inspector = inspector
    }

    func validate() throws {
        try invalidation.withLock { reason in
            if let reason { throw Self.invalid(reason) }
            let failure: String
            do {
                if try inspector.isCurrent(identity) { return }
                failure = "daemon exited or was replaced"
            } catch {
                failure = "daemon identity inspection failed: \(error)"
            }
            reason = failure
            throw Self.invalid(failure)
        }
    }

    /// The first unpublished reservation may start an on-demand daemon. Discard
    /// only that startup reservation, then bracket the published create with an
    /// already-known identity. Never rebind an existing lease after invalidation.
    static func reserve<Resource>(
        inspector: any VmnetDaemonInspecting,
        create: () throws -> Resource
    ) throws -> (Resource, VmnetDaemonLease) {
        let identity: VmnetDaemonIdentity
        if let current = try inspector.current() {
            identity = current
        } else {
            identity = try bootstrapIdentity(inspector: inspector, create: create)
        }
        let lease = VmnetDaemonLease(identity: identity, inspector: inspector)
        try lease.validate()
        let resource = try create()
        try lease.validate()
        return (resource, lease)
    }

    private static func bootstrapIdentity<Resource>(
        inspector: any VmnetDaemonInspecting,
        create: () throws -> Resource
    ) throws -> VmnetDaemonIdentity {
        let unpublished = try create()
        return try withExtendedLifetime(unpublished) {
            guard let identity = try inspector.current() else {
                throw invalid("daemon identity missing after unpublished startup reservation")
            }
            return identity
        }
    }

    private static func invalid(_ reason: String) -> ContainerizationError {
        ContainerizationError(.invalidState, message: "vmnet reservation is fenced: \(reason)")
    }
}
