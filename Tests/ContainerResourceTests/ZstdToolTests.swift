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
import Testing

@testable import ContainerResource

struct ZstdToolTests {
    @Test
    func prefersExplicitOverride() throws {
        let url = try ZstdTool.resolveExecutableURL(
            env: [ZstdTool.overrideEnvironmentKey: "/custom/zstd"],
            isExecutable: { $0 == "/custom/zstd" }
        )

        #expect(url.path == "/custom/zstd")
    }

    @Test
    func fallsBackToHomebrewPathWhenPathIsMissing() throws {
        let url = try ZstdTool.resolveExecutableURL(
            env: [:],
            isExecutable: { $0 == "/opt/homebrew/bin/zstd" }
        )

        #expect(url.path == "/opt/homebrew/bin/zstd")
    }

    @Test
    func resolvesFromPathBeforeFallbacks() throws {
        let url = try ZstdTool.resolveExecutableURL(
            env: ["PATH": "/tmp/bin:/usr/bin"],
            isExecutable: { $0 == "/tmp/bin/zstd" }
        )

        #expect(url.path == "/tmp/bin/zstd")
    }
}
