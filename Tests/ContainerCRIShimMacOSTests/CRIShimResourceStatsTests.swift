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

import ContainerCRI
import ContainerResource
import Foundation
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimResourceStatsTests {
    private let container = CRIShimContainerMetadata(
        id: "cri-container", sandboxID: "cri-pod",
        runtimeWorkloadID: "runtime-workload", name: "worker", image: "example/worker", runtimeHandler: "macos",
        state: .running, createdAt: Date())
    private let pod = CRIShimSandboxMetadata(
        id: "cri-pod", runtimeHandler: "macos", sandboxImage: "example/sandbox",
        state: .ready, createdAt: Date(), updatedAt: Date())
    private var usage: ContainerStats {
        ContainerStats(
            id: "runtime-workload", memoryUsageBytes: 4096, memoryLimitBytes: 99999,
            cpuUsageUsec: 123456, networkRxBytes: nil, networkTxBytes: nil, blockReadBytes: nil,
            blockWriteBytes: nil, numProcesses: 2, timestampNanoseconds: 1_700_000_000_000_000_000)
    }

    @Test func mapsMeasuredUsageAndKeepsCRIIdentity() throws {
        let stats = try makeCRIContainerStats(container, usage: usage)
        #expect(stats.attributes.id == "cri-container")
        #expect(stats.attributes.metadata.name == "worker")
        #expect(stats.cpu.usageCoreNanoSeconds.value == 123_456_000)
        #expect(stats.memory.workingSetBytes.value == 4096)
        #expect(stats.memory.rssBytes.value == 4096)
        #expect(!stats.memory.hasAvailableBytes)
    }

    @Test func missingMeasurementsAreNotZeroUsage() {
        var incomplete = usage
        incomplete.cpuUsageUsec = nil
        #expect(throws: (any Error).self) { try makeCRIContainerStats(container, usage: incomplete) }
        incomplete = usage
        incomplete.timestampNanoseconds = nil
        #expect(throws: (any Error).self) { try makeCRIContainerStats(container, usage: incomplete) }
        incomplete = usage
        incomplete.memoryUsageBytes = nil
        #expect(throws: (any Error).self) { try makeCRIContainerStats(container, usage: incomplete) }
    }

    @Test func sumsCompletePodAndOmitsIncompletePodTotals() throws {
        let stats = try makeCRIContainerStats(container, usage: usage)
        let complete = makeCRIPodSandboxStats(pod, containers: [stats, stats], complete: true)
        #expect(complete.linux.cpu.usageCoreNanoSeconds.value == 246_912_000)
        #expect(complete.linux.memory.workingSetBytes.value == 8192)
        let partial = makeCRIPodSandboxStats(pod, containers: [stats], complete: false)
        #expect(partial.linux.containers.count == 1)
        #expect(!partial.linux.hasCpu)
        #expect(!partial.linux.hasMemory)
    }
}
