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

import ContainerAPIClient
import Foundation

extension ContainerKit {
    public func listVolumes() async throws -> [Volume] {
        try await ClientVolume.list()
    }

    public func createVolume(
        name: String,
        driver: String = "local",
        driverOptions: [String: String] = [:],
        labels: [String: String] = [:]
    ) async throws -> Volume {
        try await ClientVolume.create(
            name: name,
            driver: driver,
            driverOpts: driverOptions,
            labels: labels
        )
    }

    public func inspectVolume(_ name: String) async throws -> Volume {
        try await ClientVolume.inspect(name)
    }

    public func deleteVolume(name: String) async throws {
        try await ClientVolume.delete(name: name)
    }

    public func volumeDiskUsage(name: String) async throws -> UInt64 {
        try await ClientVolume.volumeDiskUsage(name: name)
    }
}
