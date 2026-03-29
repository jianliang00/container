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

public extension ContainerKitServices {
    func status() async throws -> ServiceStatus {
        let isRegistered = try dependencies.isServiceRegistered(Self.apiServerServiceLabel)
        guard isRegistered else {
            return ServiceStatus(isRegistered: false, health: nil)
        }

        let health = try? await dependencies.healthCheck(.seconds(10))
        return ServiceStatus(isRegistered: true, health: health)
    }

    func ensureRunning(timeout: Duration = .seconds(10)) async throws {
        let currentStatus = try await status()
        guard !currentStatus.isRegistered || currentStatus.health == nil else {
            return
        }

        if currentStatus.isRegistered {
            try? await stop()
        }
        try await start(timeout: timeout)
    }
}
