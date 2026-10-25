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

import Darwin
import Foundation

/// Reads at most one chunk ahead of the async consumer. In particular, EOF
/// cannot overtake a data chunk while the runtime actor is busy starting a process.
final class AttachmentInputPump: @unchecked Sendable {
    let id = UUID()
    private let fileHandle: FileHandle
    private let forward: @Sendable (UUID, Data) async -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var generation: UInt64 = 0

    init(
        fileHandle: FileHandle,
        forward: @escaping @Sendable (UUID, Data) async -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.fileHandle = fileHandle
        self.forward = forward
        self.onFailure = onFailure
    }

    deinit { stop() }

    func start() {
        lock.withLock {
            guard !stopped else { return }
            generation += 1
            let armedGeneration = generation
            fileHandle.readabilityHandler = { [weak self] _ in
                self?.read(generation: armedGeneration)
            }
        }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            generation += 1
            fileHandle.readabilityHandler = nil
        }
    }

    private func read(generation armedGeneration: UInt64) {
        let result: Result<Data, Error>? = lock.withLock {
            guard !stopped, generation == armedGeneration else { return nil }
            // Claim this notification before reading. Stale callbacks cannot
            // consume a second chunk, including after the handler is rearmed.
            generation += 1
            fileHandle.readabilityHandler = nil
            return Result {
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = Darwin.read(fileHandle.fileDescriptor, &bytes, bytes.count)
                    if count >= 0 { return Data(bytes.prefix(count)) }
                    if errno != EINTR {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
        }
        guard let result else { return }
        switch result {
        case .success(let data):
            Task {
                guard !lock.withLock({ stopped }) else { return }
                await forward(id, data)
                if data.isEmpty {
                    stop()
                } else {
                    start()
                }
            }
        case .failure(let error):
            stop()
            onFailure(error)
        }
    }
}
