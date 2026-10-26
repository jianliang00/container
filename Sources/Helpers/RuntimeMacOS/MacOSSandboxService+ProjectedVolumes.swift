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
import CryptoKit
import Foundation
import RuntimeMacOSSidecarShared

extension MacOSSandboxService {
    func startProjectedVolumeUpdates(_ shares: [MacOSGuestMountMapping.HostPathShare]) {
        guard !shares.isEmpty, projectedVolumeTask == nil else { return }
        projectedVolumeTask = Task { [weak self] in
            // Poll only the AtomicWriter link. This coalesces bursts and also detects updates missed during reconnects.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refreshProjectedVolumes(shares)
            }
        }
    }

    private func refreshProjectedVolumes(_ shares: [MacOSGuestMountMapping.HostPathShare]) {
        try? reconcileProjectedVolumes(shares, failOnError: false)
    }

    func reconcileProjectedVolumes(_ shares: [MacOSGuestMountMapping.HostPathShare], failOnError: Bool) throws {
        for share in shares {
            do {
                let source = URL(fileURLWithPath: share.source)
                let generation = try ProjectedVolumeSnapshot.generation(at: source)
                guard projectedVolumeGenerations[share.guestPath] != generation else { continue }
                let snapshot = try ProjectedVolumeSnapshot.capture(at: source)
                let data = try JSONEncoder().encode(snapshot)
                let txID = UUID().uuidString
                try sendFSBegin(.init(txID: txID, op: .projectedVolume, path: share.guestPath))
                do {
                    for offset in stride(from: 0, to: data.count, by: 256 * 1024) {
                        try sendFSChunk(.init(txID: txID, offset: UInt64(offset), data: data.subdata(in: offset..<min(offset + 256 * 1024, data.count))))
                    }
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    try sendFSEnd(.init(txID: txID, action: .commit, digest: "sha256:" + digest))
                } catch {
                    try? sendFSEnd(.init(txID: txID, action: .abort))
                    throw error
                }
                projectedVolumeGenerations[share.guestPath] = snapshot.generation
                projectedVolumeFailures.remove(share.guestPath)
                writeContainerLog(Data("projected volume updated: \(share.guestPath) generation=\(snapshot.generation)\n".utf8))
            } catch {
                // Keep serving the last complete generation. Log transitions, not every retry; never log payloads.
                if projectedVolumeFailures.insert(share.guestPath).inserted {
                    writeContainerLog(Data("projected volume update pending: \(share.guestPath)\n".utf8))
                }
                if failOnError { throw error }
            }
        }
    }
}
