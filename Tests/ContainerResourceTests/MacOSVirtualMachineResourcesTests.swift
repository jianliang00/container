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

import Testing
import Virtualization

@testable import ContainerResource

struct MacOSVirtualMachineResourcesTests {
    @Test
    func alignsMemoryWithoutClampingCapacity() throws {
        let bytes: UInt64 = 16_384_000_000
        let result = try MacOSVirtualMachineResources(cpus: 8, memoryInBytes: bytes)
        #expect(result.cpus == 8)
        #expect(result.memoryInBytes >= bytes)
        #expect(result.memoryInBytes - bytes < 1024 * 1024)
        #expect(result.memoryInBytes % (1024 * 1024) == 0)
        #expect(try MacOSVirtualMachineResources(cpus: result.cpus, memoryInBytes: result.memoryInBytes) == result)
    }

    @Test
    func rejectsUnsupportedHardwareInsteadOfClamping() {
        let minimum = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let maximum = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        for cpu in [0, minimum - 1, maximum + 1, Int.max] {
            #expect(throws: MacOSVirtualMachineResources.ValidationError.self) {
                try MacOSVirtualMachineResources(cpus: cpu, memoryInBytes: 8 * 1024 * 1024 * 1024)
            }
        }
        for memory: UInt64 in [
            0, 1, VZVirtualMachineConfiguration.minimumAllowedMemorySize - 1,
            VZVirtualMachineConfiguration.maximumAllowedMemorySize + 1, UInt64.max,
        ] {
            #expect(throws: MacOSVirtualMachineResources.ValidationError.self) {
                try MacOSVirtualMachineResources(cpus: 4, memoryInBytes: memory)
            }
        }
    }
}
