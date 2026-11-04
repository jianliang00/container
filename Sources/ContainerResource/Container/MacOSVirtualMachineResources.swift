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

import Virtualization

/// The effective hardware configuration shared by VM creation and saved-state compatibility.
public struct MacOSVirtualMachineResources: Equatable, Sendable {
    public let cpus: Int
    public let memoryInBytes: UInt64

    public init(cpus: Int, memoryInBytes: UInt64) throws {
        let cpuRange = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)...Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        guard cpuRange.contains(cpus) else {
            throw ValidationError("VM CPU count \(cpus) is outside supported range \(cpuRange)")
        }
        // Virtualization requires a multiple of 1 MiB. Round up without losing
        // any of the requested capacity or allowing integer overflow.
        let alignment: UInt64 = 1024 * 1024
        let (rounded, overflow) = memoryInBytes.addingReportingOverflow(alignment - 1)
        guard !overflow else { throw ValidationError("VM memory size overflows after alignment") }
        let aligned = rounded / alignment * alignment
        let memoryRange = VZVirtualMachineConfiguration.minimumAllowedMemorySize...VZVirtualMachineConfiguration.maximumAllowedMemorySize
        guard memoryInBytes >= memoryRange.lowerBound, memoryRange.contains(aligned) else {
            throw ValidationError("VM memory \(memoryInBytes) bytes is outside supported range \(memoryRange)")
        }
        self.cpus = cpus
        self.memoryInBytes = aligned
    }

    public struct ValidationError: Error, CustomStringConvertible, Sendable {
        public let description: String
        init(_ description: String) { self.description = description }
    }
}
