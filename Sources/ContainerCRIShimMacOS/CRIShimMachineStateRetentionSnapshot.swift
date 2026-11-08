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
import RuntimeMacOSSidecarShared

// ListPodSandbox may become empty before RemovePodSandbox releases its durable
// lease. External state GC must also observe that the lease no longer retains
// the binding. Failure to read a complete lease inventory omits this proof.
struct CRIShimMachineStateRetentionSnapshot: Encodable {
    static let infoKey = "container.macos.machine-state.retention.v1"
    let schemaVersion = 1
    let retainedPersistenceIDs: [String]

    init(policy: MachineStateConfig) throws {
        retainedPersistenceIDs = try CRIShimMachineStateLeaseStore.list(policy: policy)
            .map(\.persistenceID).sorted()
    }
}

struct CRIShimLocalDiskCapabilities: Encodable {
    static let infoKey = "container.macos.local-disk.v1"
    let schemaVersion = 1
    let bundleImport = true
    let activeIdentityImport = true
    let enabled: Bool
}

/// Native selection is admitted independently from the existing RAW disk path.
struct CRIShimNativeASIFCapabilities: Encodable {
    static let infoKey = "container.macos.native-asif.v1"
    static var hostSupported: Bool { MacOSNativeDisk.available }

    let schemaVersion = 1
    let bundleImport = true
    let initialCreation = true
    let memoryRestore = false
    let hostSupported: Bool
    let enabled: Bool

    init(policy: MachineStateConfig?, hostSupported: Bool = Self.hostSupported) {
        self.hostSupported = hostSupported
        enabled = hostSupported && policy?.enabled == true && policy?.localDiskEnabled == true && policy?.nativeASIFEnabled == true
    }
}
