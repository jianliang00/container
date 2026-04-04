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
    public func listImages() async throws -> [Image] {
        try await ClientImage.list()
    }

    public func getImage(reference: String) async throws -> Image {
        try await ClientImage.get(reference: reference)
    }

    public func pullImage(reference: String) async throws -> Image {
        try await ClientImage.pull(reference: reference)
    }

    public func deleteImage(reference: String, garbageCollect: Bool = false) async throws {
        try await ClientImage.delete(reference: reference, garbageCollect: garbageCollect)
    }
}
