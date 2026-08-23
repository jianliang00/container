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

import Foundation
import Testing

@testable import ContainerResource

struct VMNetRecoveryStateTests {
    @Test
    func admissionRequiresPersistedStateFromCurrentBoot() throws {
        try withStore { store in
            #expect(throws: VMNetRecoveryStateError.stateMissing(networkName: "kubernetes-pod")) {
                try store.requireHealthy(
                    networkName: "kubernetes-pod",
                    expectedBootSessionID: "boot-a"
                )
            }

            _ = try store.recordHealthyObservation(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a",
                now: timestamp(0)
            )
            try store.requireHealthy(
                networkName: "kubernetes-pod",
                expectedNetworkInstanceID: "instance-a",
                expectedBootSessionID: "boot-a"
            )

            #expect(
                throws: VMNetRecoveryStateError.bootSessionMismatch(
                    expected: "boot-b",
                    actual: "boot-a"
                )
            ) {
                try store.requireHealthy(
                    networkName: "kubernetes-pod",
                    expectedBootSessionID: "boot-b"
                )
            }
        }
    }

    @Test
    func fenceIsDurableAndBlocksAdmission() throws {
        try withStore { store in
            _ = try store.recordHealthyObservation(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a",
                now: timestamp(0)
            )
            let fenced = try store.recordFence(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                failureReason: "helper disconnected",
                bootSessionID: "boot-a",
                attemptWindow: 3600,
                now: timestamp(10)
            )

            #expect(fenced.phase == .fenced)
            #expect(fenced.failureReason == "helper disconnected")
            #expect(try store.load()?.phase == .fenced)
            #expect(
                throws: VMNetRecoveryStateError.admissionFenced(
                    networkName: "kubernetes-pod",
                    phase: .fenced
                )
            ) {
                try store.requireHealthy(
                    networkName: "kubernetes-pod",
                    expectedBootSessionID: "boot-a"
                )
            }
        }
    }

    @Test
    func networkInstanceChangeWithoutRebootCreatesFence() throws {
        try withStore { store in
            _ = try store.recordHealthyObservation(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a",
                now: timestamp(0)
            )
            let state = try store.recordHealthyObservation(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-b",
                bootSessionID: "boot-a",
                now: timestamp(5)
            )

            #expect(state.phase == .fenced)
            #expect(state.networkInstanceID == "instance-b")
            #expect(state.failureReason == "vmnet network instance changed without host reboot")
        }
    }

    @Test
    func delayedDisconnectFromOldInstanceCannotFenceNewHealthyInstance() throws {
        try withStore { store in
            _ = try store.recordHealthyObservation(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-new",
                bootSessionID: "boot-b",
                now: timestamp(0)
            )
            let state = try store.recordFence(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-old",
                failureReason: "delayed disconnect",
                bootSessionID: "boot-b",
                attemptWindow: 3600,
                now: timestamp(10)
            )

            #expect(state.phase == .healthy)
            #expect(state.networkInstanceID == "instance-new")
        }
    }

    @Test
    func rebootAttemptBudgetSurvivesSuccessfulRecovery() throws {
        try withStore { store in
            _ = try store.recordHealthyObservation(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                bootSessionID: "boot-a",
                now: timestamp(0)
            )
            _ = try store.recordFence(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                failureReason: "first failure",
                bootSessionID: "boot-a",
                attemptWindow: 3600,
                now: timestamp(10)
            )
            _ = try store.requestReboot(
                networkName: "kubernetes-pod",
                currentBootSessionID: "boot-a",
                maxAttempts: 1,
                minimumInterval: 0,
                maximumRequestAge: 900,
                now: timestamp(20)
            )
            _ = try store.beginVerification(
                networkName: "kubernetes-pod",
                currentBootSessionID: "boot-b",
                now: timestamp(30)
            )
            _ = try store.completeVerification(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-b",
                currentBootSessionID: "boot-b",
                now: timestamp(40)
            )
            let secondFence = try store.recordFence(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-b",
                failureReason: "second failure",
                bootSessionID: "boot-b",
                attemptWindow: 3600,
                now: timestamp(50)
            )

            #expect(secondFence.rebootAttempts == 1)
            #expect(throws: VMNetRecoveryStateError.rebootAttemptBudgetExhausted) {
                _ = try store.requestReboot(
                    networkName: "kubernetes-pod",
                    currentBootSessionID: "boot-b",
                    maxAttempts: 1,
                    minimumInterval: 0,
                    maximumRequestAge: 900,
                    now: timestamp(60)
                )
            }
        }
    }

    @Test
    func verificationRequiresNewBootAndNewNetworkInstance() throws {
        try withStore { store in
            _ = try store.recordFence(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                failureReason: "failure",
                bootSessionID: "boot-a",
                attemptWindow: 3600,
                now: timestamp(0)
            )

            #expect(throws: VMNetRecoveryStateError.bootSessionDidNotChange) {
                _ = try store.beginVerification(
                    networkName: "kubernetes-pod",
                    currentBootSessionID: "boot-a",
                    now: timestamp(10)
                )
            }
            _ = try store.beginVerification(
                networkName: "kubernetes-pod",
                currentBootSessionID: "boot-b",
                now: timestamp(10)
            )
            #expect(
                throws: VMNetRecoveryStateError.staleNetworkInstance(
                    expected: "a new network instance",
                    actual: "instance-a"
                )
            ) {
                _ = try store.completeVerification(
                    networkName: "kubernetes-pod",
                    networkInstanceID: "instance-a",
                    currentBootSessionID: "boot-b",
                    now: timestamp(20)
                )
            }
        }
    }

    @Test
    func corruptStateFailsClosed() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("recovery.json")
        let store = VMNetRecoveryStateStore(stateURL: stateURL)
        _ = try store.recordHealthyObservation(
            networkName: "kubernetes-pod",
            networkInstanceID: "instance-a",
            bootSessionID: "boot-a"
        )
        try Data("not-json".utf8).write(to: stateURL)

        #expect(throws: (any Error).self) {
            try store.requireHealthy(networkName: "kubernetes-pod")
        }
    }

    @Test
    func unprivilegedFenceRequestIsSingleWriterBoundedAndFailClosed() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let requestURL = root.appendingPathComponent("requests/fence.json")
        try FileManager.default.createDirectory(
            at: requestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = VMNetRecoveryRequestStore(requestURL: requestURL)

        #expect(
            try store.submit(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-a",
                failureReason: "helper disconnected",
                bootSessionID: "boot-a",
                now: timestamp(10)
            )
        )
        #expect(
            try !store.submit(
                networkName: "kubernetes-pod",
                networkInstanceID: "instance-b",
                failureReason: "duplicate",
                bootSessionID: "boot-a",
                now: timestamp(20)
            )
        )
        #expect(try store.hasPendingRequest())
        #expect(throws: VMNetRecoveryStateError.admissionFenced(networkName: "kubernetes-pod", phase: .fenced)) {
            try store.requireNoPendingRequest(networkName: "kubernetes-pod")
        }

        let request = try #require(try store.load(expectedWriterUID: Int(geteuid())))
        #expect(request.networkInstanceID == "instance-a")
        #expect(request.failureReason == "helper disconnected")
        #expect(
            throws: VMNetRecoveryStateError.requestWriterMismatch(
                expected: UInt32(geteuid()) &+ 1,
                actual: UInt32(geteuid())
            )
        ) {
            _ = try store.load(expectedWriterUID: Int(UInt32(geteuid()) &+ 1))
        }

        try store.remove()
        #expect(try !store.hasPendingRequest())
    }
}

private func withStore(_ body: (VMNetRecoveryStateStore) throws -> Void) throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try body(VMNetRecoveryStateStore(stateURL: root.appendingPathComponent("recovery.json")))
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("VMNetRecoveryStateTests-\(UUID().uuidString)", isDirectory: true)
}

private func timestamp(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
}
