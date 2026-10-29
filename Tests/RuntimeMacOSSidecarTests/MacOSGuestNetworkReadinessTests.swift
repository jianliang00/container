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

@testable import container_runtime_macos_sidecar

struct MacOSGuestNetworkReadinessTests {
    private static let first = "02:42:ac:11:00:02"
    private static let second = "02:42:ac:11:00:03"
    private static let unrelated = "anpi0: flags=8863<UP> mtu 1500\n\tether f6:39:a8:db:b8:a8\n\tinet 10.2.3.4"

    private static func inventory(_ mac: String, interface: String = "en0") -> String {
        "\(interface): flags=8863<UP> mtu 1500\n\tether \(mac)"
    }

    private actor Probe {
        var outputs: [String]
        var budgets: [TimeInterval] = []
        init(_ outputs: [String]) { self.outputs = outputs }
        func observe(_ budget: TimeInterval) -> String {
            budgets.append(budget)
            return outputs.count > 1 ? outputs.removeFirst() : outputs[0]
        }
    }

    @Test
    func waitsForEveryRequestedMACWithoutSelectingUnrelatedInterface() async throws {
        let probe = Probe([
            Self.unrelated,
            Self.inventory(Self.first.uppercased()),
            Self.inventory(Self.first) + "\n" + Self.inventory(Self.second, interface: "en7"),
        ])
        try await MacOSGuestNetworkReadiness.wait(
            expectedMACAddresses: [Self.first, Self.second.uppercased()],
            timeoutSeconds: 1, pollIntervalSeconds: 0.001,
            observe: { await probe.observe($0) }
        )
        let budgets = await probe.budgets
        #expect(budgets.count == 3)
        #expect(budgets.allSatisfy { $0 > 0 && $0 <= 1 })
        #expect(zip(budgets, budgets.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test
    func missingMACFailsWithBoundedIdentityOnlyDiagnostic() async {
        let probe = Probe([Self.unrelated])
        do {
            try await MacOSGuestNetworkReadiness.wait(
                expectedMACAddresses: [Self.first], timeoutSeconds: 0.03, pollIntervalSeconds: 0.005,
                observe: { await probe.observe($0) }
            )
            Issue.record("missing interface was accepted")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
            #expect(error.message.contains(Self.first))
            #expect(error.message.contains("anpi0=f6:39:a8:db:b8:a8"))
            #expect(!error.message.contains("10.2.3.4"))
        } catch { Issue.record("unexpected error: \(error)") }
        #expect(await probe.budgets.count >= 1)
    }

    @Test
    func transportFailureIsNotRetried() async {
        let probe = Probe([Self.unrelated])
        await #expect(throws: POSIXError(.ECONNRESET)) {
            try await MacOSGuestNetworkReadiness.wait(expectedMACAddresses: [Self.first]) { budget in
                _ = await probe.observe(budget)
                throw POSIXError(.ECONNRESET)
            }
        }
        #expect(await probe.budgets.count == 1)
    }

    @Test
    func observationFinishingAfterDeadlineCannotSucceed() async {
        await #expect(throws: (any Error).self) {
            try await MacOSGuestNetworkReadiness.wait(expectedMACAddresses: [Self.first], timeoutSeconds: 0.01) { _ in
                try await Task.sleep(for: .milliseconds(30))
                return Self.inventory(Self.first)
            }
        }
    }

    @Test
    func emptyNetworkDoesNotProbe() async throws {
        let probe = Probe([Self.unrelated])
        try await MacOSGuestNetworkReadiness.wait(expectedMACAddresses: [], observe: { await probe.observe($0) })
        #expect(await probe.budgets.isEmpty)
    }

    @Test
    func cancellationCannotAcceptEvenAMatchingInventory() async {
        let task = Task {
            try await MacOSGuestNetworkReadiness.wait(expectedMACAddresses: [Self.first]) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Self.inventory(Self.first)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
