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
    func stop() async throws {
        let launchdDomainString = try ServiceManager.getDomainString()
        let fullAPIServerLabel = "\(launchdDomainString)/\(Self.apiServerServiceLabel)"
        let isHealthy = (try? await kit.health(timeout: .seconds(5))) != nil

        if isHealthy {
            await stopRunningContainers()

            for _ in 0..<Self.shutdownTimeoutSeconds {
                let runningContainers = (try? await kit.listContainers())?.filter { $0.status.rawValue == "running" } ?? []
                guard !runningContainers.isEmpty else {
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }

            try? ServiceManager.deregister(fullServiceLabel: fullAPIServerLabel)
        }

        try ServiceManager.enumerate()
            .filter { $0.hasPrefix("com.apple.container.") }
            .filter { $0 != Self.apiServerServiceLabel }
            .map { "\(launchdDomainString)/\($0)" }
            .forEach {
                try? ServiceManager.deregister(fullServiceLabel: $0)
            }
    }
}

extension ContainerKitServices {
    func stopRunningContainers() async {
        guard let containers = try? await kit.listContainers() else {
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for container in containers where container.status.rawValue == "running" {
                group.addTask {
                    try? await kit.stopContainer(
                        id: container.id,
                        options: ContainerStopOptions(
                            timeoutInSeconds: Self.stopTimeoutSeconds,
                            signal: ContainerStopOptions.default.signal
                        )
                    )
                }
            }
        }
    }
}
