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
import RuntimeMacOSSidecarShared

/// Weak references keep the statistics index from extending workload lifetimes.
final class GuestProcessStatisticsRegistry: @unchecked Sendable {
    static let shared = GuestProcessStatisticsRegistry()
    private struct Entry { weak var session: SpawnedProcessSession? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func register(_ session: SpawnedProcessSession, id: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[id] = Entry(session: session)
    }

    func remove(_ session: SpawnedProcessSession, id: String) {
        lock.lock()
        defer { lock.unlock() }
        if entries[id]?.session == nil || entries[id]?.session === session { entries.removeValue(forKey: id) }
    }

    func statistics(id: String) throws -> GuestProcessResourceStats {
        lock.lock()
        let session = entries[id]?.session
        lock.unlock()
        guard let session else { throw POSIXError(.ESRCH) }
        return try session.resourceStatistics(id: id)
    }
}

/// The caller holds the session's exit lock, preventing root PID reuse while sampling.
struct GuestProcessTreeSampler {
    static func sample(rootPID: pid_t, id: String) throws -> GuestProcessResourceStats {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { throw POSIXError(.EIO) }
        // Reaping a child moves its CPU counters to its parent. Retry when that
        // happens during traversal so a child is not counted twice.
        for _ in 0..<3 {
            var visited = Set<pid_t>()
            do {
                let value = try collect(pid: rootPID, visited: &visited)
                return GuestProcessResourceStats(
                    executionID: id,
                    timestampNanoseconds: Int64(Date().timeIntervalSince1970 * 1_000_000_000),
                    cpuUsageNanoseconds: try cpuNanoseconds(value.cpu, timebase: timebase),
                    residentMemoryBytes: value.memory,
                    processCount: value.count)
            } catch let error as POSIXError where error.code == .EAGAIN {
                continue
            }
        }
        throw POSIXError(.EAGAIN)
    }

    // proc_pid_rusage reports CPU time in Mach ticks, including reaped-child
    // counters. Apple Silicon's timebase is not necessarily one nanosecond.
    static func cpuNanoseconds(_ ticks: UInt64, timebase: mach_timebase_info_data_t) throws -> UInt64 {
        guard timebase.numer > 0, timebase.denom > 0 else { throw POSIXError(.EINVAL) }
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        guard product.high < UInt64(timebase.denom) else { throw POSIXError(.EOVERFLOW) }
        return UInt64(timebase.denom).dividingFullWidth(product).quotient
    }

    private static func usage(_ pid: pid_t) throws -> rusage_info_v2 {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info
    }

    private static func children(_ pid: pid_t) throws -> [pid_t] {
        var capacity = 32
        while capacity <= 65536 {
            var pids = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let count = Int(pids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) })
            guard count >= 0, count != 0 || errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count < capacity { return Array(pids.prefix(count)) }
            capacity *= 2
        }
        throw POSIXError(.EOVERFLOW)
    }

    private static func collect(pid: pid_t, visited: inout Set<pid_t>) throws -> (cpu: UInt64, memory: UInt64, count: UInt64) {
        guard visited.insert(pid).inserted, visited.count <= 65536 else { throw POSIXError(.EAGAIN) }
        let before = try usage(pid)
        var cpu = before.ri_user_time + before.ri_system_time + before.ri_child_user_time + before.ri_child_system_time
        var memory = before.ri_resident_size
        var count: UInt64 = 1
        for child in try children(pid) {
            do {
                var info = proc_bsdinfo()
                let size = MemoryLayout<proc_bsdinfo>.size
                guard proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
                    info.pbi_ppid == UInt32(pid)
                else { throw POSIXError(.EAGAIN) }
                let value = try collect(pid: child, visited: &visited)
                cpu += value.cpu
                memory += value.memory
                count += value.count
            } catch let error as POSIXError where error.code == .ESRCH {
                throw POSIXError(.EAGAIN)
            }
        }
        let after = try usage(pid)
        guard before.ri_proc_start_abstime == after.ri_proc_start_abstime,
            before.ri_child_user_time == after.ri_child_user_time,
            before.ri_child_system_time == after.ri_child_system_time
        else { throw POSIXError(.EAGAIN) }
        return (cpu, memory, count)
    }
}
