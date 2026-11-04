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

import ContainerResource

// These annotations are computed by Darwin kubelet from the Pod spec.
enum CRIShimPodResourceAnnotation {
    static let version = "io.kubernetes.cri.macos/pod-sandbox-config-version"
    static let cpuMillis = "io.kubernetes.cri.macos/cpu-millis"
    static let memoryBytes = "io.kubernetes.cri.macos/memory-bytes"
}

func resolveCRIShimPodResources(annotations: [String: String], defaults: RuntimeResources) throws -> MacOSVirtualMachineResources {
    let version = annotations[CRIShimPodResourceAnnotation.version]
    let cpu = annotations[CRIShimPodResourceAnnotation.cpuMillis]
    let memory = annotations[CRIShimPodResourceAnnotation.memoryBytes]
    switch version {
    case "v1alpha2": break
    case nil, "v1alpha1":
        guard cpu == nil && memory == nil else {
            throw CRIShimError.invalidArgument("macOS resource annotations require pod-sandbox-config-version=v1alpha2")
        }
    default:
        throw CRIShimError.invalidArgument("unsupported macOS sandbox contract: \(version ?? "")")
    }
    var cpus = defaults.cpus ?? RuntimeResources.defaultMacOSCPUCount
    var bytes = defaults.memoryInBytes ?? RuntimeResources.defaultMacOSMemoryInBytes
    if let cpu {
        let millis = try positiveResourceInteger(cpu, field: CRIShimPodResourceAnnotation.cpuMillis)
        // Integer division avoids overflowing when rounding fractional CPUs up.
        let count = millis / 1000 + (millis % 1000 == 0 ? 0 : 1)
        guard let value = Int(exactly: count) else { throw CRIShimError.invalidArgument("VM CPU count overflows") }
        cpus = value
    }
    if let memory { bytes = try positiveResourceInteger(memory, field: CRIShimPodResourceAnnotation.memoryBytes) }
    do {
        return try MacOSVirtualMachineResources(cpus: cpus, memoryInBytes: bytes)
    } catch {
        throw CRIShimError.invalidArgument(String(describing: error))
    }
}

private func positiveResourceInteger(_ text: String, field: String) throws -> UInt64 {
    guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        let value = UInt64(text), value > 0, value <= UInt64(Int64.max)
    else { throw CRIShimError.invalidArgument("\(field) must be a positive signed 64-bit decimal integer") }
    return value
}

func validateCRIShimReusedPodResources(requested: MacOSVirtualMachineResources, snapshot: SandboxSnapshot) throws {
    guard let configuration = snapshot.configuration else {
        throw CRIShimError.unavailable("cannot verify existing VM resources; recreate the pod sandbox")
    }
    let actual = try MacOSVirtualMachineResources(
        cpus: configuration.resources.cpus, memoryInBytes: configuration.resources.memoryInBytes)
    guard actual == requested else {
        throw CRIShimError.invalidArgument("existing VM resources differ from the Pod request; recreate the pod sandbox to change CPU or memory")
    }
}
