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

/// Thin facade for talking to already-installed, already-running container services.
///
/// `ContainerKit` does not install, register, or start helpers. Embedding code
/// should call ``health(timeout:)`` to verify service readiness before assuming
/// the runtime is available.
public struct ContainerKit: Sendable {
    let containerClient: ContainerClient

    public init() {
        self.containerClient = ContainerClient()
    }
}
