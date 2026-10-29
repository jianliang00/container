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
import RuntimeMacOSSidecarShared
import Testing

@testable import container_runtime_macos

struct MacOSSandboxStopSequenceTests {
    @Test(arguments: [MacOSVMRuntimeState.paused, .stopped])
    func inactiveGuestStopsNativelyWithoutGuestRequests(state: MacOSVMRuntimeState) async throws {
        var calls: [String] = []
        await MacOSSandboxStopSequence.run(lifecycleState: state) {
            calls.append("guest")
        } stopVirtualMachine: {
            calls.append("native")
        }
        #expect(calls == ["native"])
    }

    @Test(arguments: [MacOSVMRuntimeState?.some(.running), nil])
    func runningAndLegacyGuestsRetainGracefulShutdown(state: MacOSVMRuntimeState?) async throws {
        var calls: [String] = []
        await MacOSSandboxStopSequence.run(lifecycleState: state) {
            calls.append("guest")
        } stopVirtualMachine: {
            calls.append("native")
        }
        #expect(calls == ["guest", "native"])
    }

    @Test(arguments: [MacOSVMRuntimeState.paused, .running])
    func failedNativeStopCannotReachResourceRelease(state: MacOSVMRuntimeState) async throws {
        enum StopFailure: Error { case stillRunning }
        var resourcesReleased = false
        do {
            try await MacOSSandboxStopSequence.run(lifecycleState: state) {
            } stopVirtualMachine: {
                throw StopFailure.stillRunning
            }
            resourcesReleased = true
            Issue.record("expected native stop verification failure")
        } catch StopFailure.stillRunning {
        }
        #expect(!resourcesReleased)
    }
}
#endif
