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

/// One instance per VM. The delegate writes on the VM queue; startup reads from
/// the service actor. Retain the first native error until that VM is discarded.
final class MacOSNetworkAttachmentHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var firstFailure: SidecarRPCError?

    @discardableResult
    func recordDisconnection(deviceIndex: Int?, error: Error) -> SidecarRPCError {
        let nativeError = error as NSError
        var metadata = [
            "errorDomain": String(nativeError.domain.prefix(256)),
            "errorCode": String(nativeError.code),
        ]
        if let deviceIndex {
            metadata["networkDeviceIndex"] = String(deviceIndex)
        }
        var details: [String] = []
        var current: NSError? = nativeError
        var visited = Set<ObjectIdentifier>()
        while let cause = current, details.count < 8, visited.insert(ObjectIdentifier(cause)).inserted {
            details.append("\(cause.domain.prefix(256))(\(cause.code)): \(cause.localizedDescription.prefix(512))")
            current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let underlying = nativeError.userInfo[NSUnderlyingErrorKey] as? NSError {
            metadata["underlyingErrorDomain"] = String(underlying.domain.prefix(256))
            metadata["underlyingErrorCode"] = String(underlying.code)
        }
        let failure = SidecarRPCError(
            code: "networkAttachmentDisconnected",
            message: "VM network attachment failed to start or disconnected",
            details: details.joined(separator: " <- "),
            metadata: metadata
        )
        lock.withLock {
            if firstFailure == nil {
                firstFailure = failure
            }
        }
        return failure
    }

    /// A later gateway timeout must not hide an earlier native attachment error.
    func failureOr(_ error: Error) -> Error {
        lock.withLock {
            if let firstFailure {
                return firstFailure
            }
            return error
        }
    }

    func validate(connectedAttachments: [Bool], expectedCount: Int) throws {
        try lock.withLock {
            if let firstFailure {
                throw firstFailure
            }
            guard connectedAttachments.count == expectedCount else {
                throw SidecarRPCError(
                    code: "networkAttachmentDisconnected",
                    message: "VM network device count does not match its configuration",
                    metadata: [
                        "expectedNetworkDeviceCount": String(expectedCount),
                        "observedNetworkDeviceCount": String(connectedAttachments.count),
                    ]
                )
            }
            if let index = connectedAttachments.firstIndex(of: false) {
                throw SidecarRPCError(
                    code: "networkAttachmentDisconnected",
                    message: "VM network device has no connected attachment",
                    metadata: ["networkDeviceIndex": String(index)]
                )
            }
        }
    }
}
