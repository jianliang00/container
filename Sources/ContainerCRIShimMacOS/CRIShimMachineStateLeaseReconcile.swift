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

import ContainerKit
import Foundation

struct CRIShimMachineStateLeaseReconcileResult: Equatable, Sendable {
    var released: [CRIShimMachineStateLease]
    var retainedForMetadata: [CRIShimMachineStateLease]
    var retainedForRuntime: [CRIShimMachineStateLease]
    var retainedForUncertainRuntime: [CRIShimMachineStateLease]

    init(
        released: [CRIShimMachineStateLease] = [],
        retainedForMetadata: [CRIShimMachineStateLease] = [],
        retainedForRuntime: [CRIShimMachineStateLease] = [],
        retainedForUncertainRuntime: [CRIShimMachineStateLease] = []
    ) {
        self.released = released
        self.retainedForMetadata = retainedForMetadata
        self.retainedForRuntime = retainedForRuntime
        self.retainedForUncertainRuntime = retainedForUncertainRuntime
    }
}

struct CRIShimMachineStateLeaseReconciler {
    @discardableResult
    func reconcile(
        policy: MachineStateConfig,
        metadataStore: CRIShimMetadataStore,
        runtimeSnapshots: [SandboxSnapshot],
        leases requestedLeases: [CRIShimMachineStateLease]? = nil
    ) throws -> CRIShimMachineStateLeaseReconcileResult {
        let leases = try requestedLeases ?? CRIShimMachineStateLeaseStore.list(policy: policy)
        guard !leases.isEmpty else {
            return CRIShimMachineStateLeaseReconcileResult()
        }

        let metadataSandboxIDs = Set(try metadataStore.listSandboxes().map(\.id))
        let identifiedRuntimeSandboxIDs = Set(runtimeSnapshots.compactMap(\.criShimSandboxID))
        let hasUnidentifiedRuntime = runtimeSnapshots.contains { $0.criShimSandboxID == nil }
        var result = CRIShimMachineStateLeaseReconcileResult()

        for lease in leases.sorted(by: { $0.persistenceID < $1.persistenceID }) {
            if metadataSandboxIDs.contains(lease.sandboxID) {
                result.retainedForMetadata.append(lease)
                continue
            }
            if identifiedRuntimeSandboxIDs.contains(lease.sandboxID) {
                result.retainedForRuntime.append(lease)
                continue
            }
            guard !hasUnidentifiedRuntime else {
                result.retainedForUncertainRuntime.append(lease)
                continue
            }
            guard lease.admissionState == .reserved || lease.admissionState == .runtimeDeletionConfirmed else {
                result.retainedForUncertainRuntime.append(lease)
                continue
            }
            try CRIShimMachineStateLeaseStore.release(policy: policy, expected: lease)
            result.released.append(lease)
        }
        return result
    }
}

func validateMachineStateLeaseCoverage(
    metadataStore: CRIShimMetadataStore,
    runtimeSnapshots: [SandboxSnapshot],
    leases: [CRIShimMachineStateLease]
) throws {
    let leasesByPersistenceID = Dictionary(
        leases.map { ($0.persistenceID, $0) },
        uniquingKeysWith: { _, new in new }
    )
    var metadataBySandboxID = Dictionary(
        uniqueKeysWithValues: try metadataStore.listSandboxes().map { ($0.id, $0) }
    )
    for snapshot in runtimeSnapshots {
        let runtimeMetadata = snapshot.configuration.flatMap({
            decodeCRIShimCoreSandboxMetadataLabel($0.labels)
        })
        if snapshot.configuration?.macosGuest?.machineState != nil, runtimeMetadata == nil {
            throw CRIShimError.unavailable(
                "machine-state runtime has no verifiable durable lease identity"
            )
        }
        guard let runtimeMetadata else {
            continue
        }
        metadataBySandboxID[runtimeMetadata.id] = runtimeMetadata
    }

    for metadata in metadataBySandboxID.values {
        guard metadata.annotations[CRIShimMachineStateAnnotation.enabled] == "true" else {
            continue
        }
        let values = try decodeEnabledMachineStateAnnotationValues(metadata.annotations)
        guard let podUID = metadata.podUID?.trimmed, !podUID.isEmpty else {
            throw CRIShimError.unavailable(
                "machine-state sandbox metadata has incomplete lease ownership"
            )
        }
        let expected = CRIShimMachineStateLease(
            persistenceID: values.persistenceID,
            podUID: podUID,
            sandboxID: metadata.id,
            runtimeSandboxID: metadata.runtimeSandboxID,
            restoreStateID: values.restoreStateID,
            restoreStateGeneration: values.restoreStateGeneration,
            storageGeneration: values.storageGeneration
        )
        guard let lease = leasesByPersistenceID[values.persistenceID],
            lease.hasSameBinding(as: expected)
        else {
            throw CRIShimError.unavailable(
                "machine-state sandbox has no matching durable lease"
            )
        }
    }
}
