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
import Foundation
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimRuntimeCleanupDomainTests {
    @Test(arguments: [UInt32(501), 502, 0])
    func rootShimUsesBoundOwnerForBothRemovalAndStrictConfirmation(ownerUID: UInt32) async throws {
        // A root shim running through asuser can observe Aqua with getuid()==0.
        // The inherited session must not determine a bound runtime's domain.
        let recorder = LaunchdRecorder(legacyDomain: "gui/0")
        var manager = ContainerKitCRIShimRuntimeManager()
        manager.launchd = recorder.operations
        try await manager.removeSandboxRuntimeService(id: "binding", machineStateOwnerUID: ownerUID)
        try await manager.removeMachineStateSidecar(sandboxID: "binding", persistenceID: "binding", effectiveUserID: ownerUID)
        try await manager.confirmSandboxRuntimeRemoved(id: "binding", machineStatePersistenceID: "binding", machineStateOwnerUID: ownerUID)

        let domain = ownerUID == 0 ? "user/0" : "gui/\(ownerUID)"
        let expected = [
            "\(domain)/com.apple.container.container-runtime-macos.binding",
            "\(domain)/com.apple.container.runtime.container-runtime-macos-sidecar.state.binding",
        ]
        #expect(recorder.calls.removals == expected)
        #expect(recorder.calls.confirmations == expected)
        #expect(recorder.calls.domainReads == 0)
    }

    @Test
    func incompleteOrInvalidOwnerBindingFailsBeforeAnyLaunchdOperation() async throws {
        let recorder = LaunchdRecorder(legacyDomain: "gui/0")
        var manager = ContainerKitCRIShimRuntimeManager()
        manager.launchd = recorder.operations
        let bindings: [(String?, UInt32?)] = [("binding", nil), (nil, 501), ("binding", .max), ("../binding", 501)]
        for (persistenceID, ownerUID) in bindings {
            do {
                try await manager.confirmSandboxRuntimeRemoved(id: "binding", machineStatePersistenceID: persistenceID, machineStateOwnerUID: ownerUID)
                Issue.record("incomplete or invalid owner binding was accepted")
            } catch {
                #expect(CRIShimErrorMapper.disposition(for: error).kind == .invalidArgument)
            }
        }
        await #expect(throws: CRIShimError.self) {
            try await manager.removeSandboxRuntimeService(id: "binding", machineStateOwnerUID: .max)
        }
        #expect(recorder.calls.removals.isEmpty)
        #expect(recorder.calls.confirmations.isEmpty)
        #expect(recorder.calls.domainReads == 0)
    }

    @Test(arguments: [Int32(125), 1, 5])
    func launchdDomainPermissionAndTransportErrorsAreNotAbsence(status: Int32) async throws {
        let failure = ContainerizationError(.internalError, message: "launchctl failed with status \(status)")
        let recorder = LaunchdRecorder(legacyDomain: "gui/0", failure: failure)
        var manager = ContainerKitCRIShimRuntimeManager()
        manager.launchd = recorder.operations
        do {
            try await manager.removeSandboxRuntimeService(id: "binding", machineStateOwnerUID: 501)
            Issue.record("launchd removal error was swallowed")
        } catch let error as ContainerizationError {
            #expect(error == failure)
        }
        do {
            try await manager.confirmSandboxRuntimeRemoved(id: "binding", machineStatePersistenceID: "binding", machineStateOwnerUID: 501)
            Issue.record("launchd confirmation error was treated as absence")
        } catch let error as ContainerizationError {
            #expect(error == failure)
        }
        #expect(recorder.calls.removals == ["gui/501/com.apple.container.container-runtime-macos.binding"])
        #expect(recorder.calls.confirmations == recorder.calls.removals)
        #expect(recorder.calls.domainReads == 0)
    }

    @Test(arguments: [false, true])
    func strictConfirmationRejectsEitherRemainingService(sidecarRemains: Bool) async throws {
        let runtime = "gui/501/com.apple.container.container-runtime-macos.binding"
        let sidecar = "gui/501/com.apple.container.runtime.container-runtime-macos-sidecar.state.binding"
        let recorder = LaunchdRecorder(legacyDomain: "gui/0", registeredLabel: sidecarRemains ? sidecar : runtime)
        var manager = ContainerKitCRIShimRuntimeManager()
        manager.launchd = recorder.operations
        do {
            try await manager.confirmSandboxRuntimeRemoved(id: "binding", machineStatePersistenceID: "binding", machineStateOwnerUID: 501)
            Issue.record("remaining runtime service was treated as absent")
        } catch {
            #expect(CRIShimErrorMapper.disposition(for: error).kind == .unavailable)
        }
        #expect(recorder.calls.confirmations == (sidecarRemains ? [runtime, sidecar] : [runtime]))
        #expect(recorder.calls.domainReads == 0)
    }

    @Test(arguments: ["system", "user/501", "gui/0"])
    func ordinaryRuntimeStillUsesCallerDomain(domain: String) async throws {
        let recorder = LaunchdRecorder(legacyDomain: domain)
        var manager = ContainerKitCRIShimRuntimeManager()
        manager.launchd = recorder.operations
        try await manager.removeSandboxRuntimeService(id: "ordinary")
        try await manager.confirmSandboxRuntimeRemoved(id: "ordinary", machineStatePersistenceID: nil, machineStateOwnerUID: nil)
        #expect(recorder.calls.removals == ["\(domain)/com.apple.container.container-runtime-macos.ordinary"])
        #expect(recorder.calls.confirmations == recorder.calls.removals)
        #expect(recorder.calls.domainReads == 2)
    }
}

private final class LaunchdRecorder: @unchecked Sendable {
    struct Calls {
        var domainReads = 0
        var removals: [String] = []
        var confirmations: [String] = []
    }

    private let lock = NSLock()
    private var recordedCalls = Calls()
    private let legacyDomain: String
    private let failure: ContainerizationError?
    private let registeredLabel: String?

    init(legacyDomain: String, failure: ContainerizationError? = nil, registeredLabel: String? = nil) {
        self.legacyDomain = legacyDomain
        self.failure = failure
        self.registeredLabel = registeredLabel
    }

    var calls: Calls { lock.withLock { recordedCalls } }

    var operations: CRIShimLaunchdOperations {
        .init(
            domainString: {
                self.lock.withLock { self.recordedCalls.domainReads += 1 }
                return self.legacyDomain
            },
            deregister: { label in
                self.lock.withLock { self.recordedCalls.removals.append(label) }
                if let failure = self.failure { throw failure }
            },
            isRegisteredStrict: { label in
                self.lock.withLock { self.recordedCalls.confirmations.append(label) }
                if let failure = self.failure { throw failure }
                return label == self.registeredLabel
            }
        )
    }
}
