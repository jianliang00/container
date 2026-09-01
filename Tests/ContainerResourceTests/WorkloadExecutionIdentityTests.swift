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

struct WorkloadExecutionIdentityTests {
    private let fingerprint = "sha256:" + String(repeating: "a", count: 64)
    private let incarnation = "sha256:" + String(repeating: "b", count: 64)

    @Test
    func workloadConfigurationRoundTripsStableExecutionIdentity() throws {
        let executionID = "execution-018f4c2a"
        let binding = try WorkloadExecutionIdentity.RestoreBinding(
            executionID: executionID,
            generation: 3
        )
        let identity = try WorkloadExecutionIdentity(
            executionID: executionID,
            launchFingerprint: fingerprint,
            incarnation: incarnation,
            restoreBinding: binding
        )
        let configuration = WorkloadConfiguration(
            id: "transient-container-9",
            processConfiguration: makeProcessConfiguration(),
            executionIdentity: identity
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(WorkloadConfiguration.self, from: data)

        #expect(decoded.id == "transient-container-9")
        #expect(decoded.executionIdentity == identity)
        #expect(decoded.executionIdentity?.executionID != decoded.id)
        #expect(decoded.executionIdentity?.incarnation == incarnation)
        #expect(decoded.executionIdentity?.restoreBinding?.generation == 3)
    }

    @Test
    func workloadConfigurationDecodesLegacySchemaWithoutExecutionIdentity() throws {
        let configuration = WorkloadConfiguration(
            id: "legacy-workload",
            processConfiguration: makeProcessConfiguration()
        )
        let encoded = try JSONEncoder().encode(configuration)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "executionIdentity")

        let legacyJSON = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WorkloadConfiguration.self, from: legacyJSON)

        #expect(decoded.persistedSchemaVersion == 1)
        #expect(decoded.executionIdentity == nil)
    }

    @Test
    func rejectsNonCanonicalIdentityAndFingerprintInputsWithoutEchoingValues() throws {
        #expect(throws: WorkloadExecutionIdentity.ValidationError.invalidExecutionID) {
            try WorkloadExecutionIdentity(
                executionID: "../runtime-object",
                launchFingerprint: fingerprint
            )
        }

        let sensitiveLookingInput = "sha256:TOP-SECRET"
        do {
            _ = try WorkloadExecutionIdentity(
                executionID: "execution-1",
                launchFingerprint: sensitiveLookingInput
            )
            Issue.record("expected a non-canonical launch fingerprint to be rejected")
        } catch let error as WorkloadExecutionIdentity.ValidationError {
            #expect(error == .invalidLaunchFingerprint)
            #expect(!error.localizedDescription.contains(sensitiveLookingInput))
        }

        #expect(throws: WorkloadExecutionIdentity.ValidationError.invalidIncarnation) {
            try WorkloadExecutionIdentity(
                executionID: "execution-1",
                launchFingerprint: fingerprint,
                incarnation: "sha256:NOT-CANONICAL"
            )
        }
    }

    @Test
    func rejectsInvalidRestoreGeneration() {
        #expect(throws: WorkloadExecutionIdentity.ValidationError.invalidRestoreGeneration) {
            try WorkloadExecutionIdentity.RestoreBinding(
                executionID: "execution-1",
                generation: 0
            )
        }
    }

    @Test
    func rejectsRestoreBindingForDifferentExecution() throws {
        let binding = try WorkloadExecutionIdentity.RestoreBinding(
            executionID: "execution-2",
            generation: 1
        )

        #expect(throws: WorkloadExecutionIdentity.ValidationError.conflictingRestoreExecutionID) {
            try WorkloadExecutionIdentity(
                executionID: "execution-1",
                launchFingerprint: fingerprint,
                restoreBinding: binding
            )
        }
    }

    @Test
    func decodingRejectsConflictingRestoreBinding() throws {
        let json = """
            {
              "schemaVersion": 1,
              "executionID": "execution-1",
              "launchFingerprint": "\(fingerprint)",
              "restoreBinding": {
                "executionID": "execution-2",
                "generation": 2
              }
            }
            """

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WorkloadExecutionIdentity.self, from: Data(json.utf8))
        }
    }

    private func makeProcessConfiguration() -> ProcessConfiguration {
        ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "echo ready"],
            environment: ["MODE=test"],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
    }
}
