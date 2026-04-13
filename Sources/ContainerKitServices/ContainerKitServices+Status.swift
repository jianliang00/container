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
import ContainerPlugin
import Foundation

extension ContainerKitServices {
    public func status() async throws -> ServiceStatus {
        let isRegistered = try dependencies.isServiceRegistered(Self.apiServerServiceLabel)
        guard isRegistered else {
            return ServiceStatus(isRegistered: false, health: nil)
        }

        let health = try? await dependencies.healthCheck(.seconds(10))
        return ServiceStatus(isRegistered: true, health: health)
    }

    public func ensureRunning(
        timeout: Duration = .seconds(10),
        installDefaultKernel: Bool = false
    ) async throws {
        let currentStatus = try await status()
        if let health = currentStatus.health, owns(health) {
            if installDefaultKernel {
                try await ensureDefaultKernelInstalled()
            }
            return
        }

        if currentStatus.isRegistered {
            try? deregisterRegisteredServices()
        }
        try await start(timeout: timeout, installDefaultKernel: installDefaultKernel)

        let health = try await dependencies.healthCheck(.seconds(5))
        guard owns(health) else {
            throw NSError(
                domain: "ContainerKitServices",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: """
                    apiserver is running from an unexpected container installation.
                    expected appRoot: \(appRoot.path(percentEncoded: false))
                    actual appRoot: \(health.appRoot.path(percentEncoded: false))
                    expected installRoot: \(installation.installRoot.path(percentEncoded: false))
                    actual installRoot: \(health.installRoot.path(percentEncoded: false))
                    """
                ]
            )
        }
    }

    public func owns(_ health: SystemHealth) -> Bool {
        sameFileURL(health.appRoot, appRoot)
            && sameFileURL(health.installRoot, installation.installRoot)
    }

    private func sameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}
